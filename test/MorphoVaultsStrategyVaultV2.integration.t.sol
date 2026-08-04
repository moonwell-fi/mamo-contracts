// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {MamoVaultConfig} from "@contracts/robinhood/MamoVaultConfig.sol";
import {MorphoVaultsStrategy} from "@contracts/robinhood/MorphoVaultsStrategy.sol";

import {MockERC20} from "./MockERC20.sol";
import {
    MockMerkleDistributor,
    MockSlippagePriceChecker,
    MockStrategyRegistry,
    MockSwapRouter
} from "./mocks/RobinhoodMocks.sol";
import {
    CannotReceiveShares, CannotSendShares, IMorphoVaultV2, IMorphoWhitelistGate
} from "./vendor/IMorphoVaultV2.sol";
import {MorphoVaultV2Deployer, MorphoWhitelistGateDeployer} from "./vendor/MorphoVaultV2Bytecode.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MorphoVaultsStrategyVaultV2IntegrationTest
 * @notice Integration tests for `MorphoVaultsStrategy` against REAL Morpho Vault V2 bytecode.
 *
 * @dev WHY THIS FILE EXISTS
 *      Robinhood Chain's Morpho deployment is Vaults V2, not MetaMorpho V1/V1.1. `MorphoVaultsStrategy`
 *      was written against V2's documented quirks but only ever exercised against a plain OpenZeppelin
 *      ERC4626 mock (`test/MorphoVaultsStrategy.unit.t.sol`), which shares almost none of V2's actual
 *      accounting. This suite deploys Morpho's own compiled `VaultV2` creation bytecode
 *      (see `test/vendor/MorphoVaultV2Bytecode.sol` for provenance and regeneration steps) into the
 *      local EVM and re-runs the MVP flows against it, with a 6-decimal underlying so the decimal
 *      profile matches mainnet USDG.
 *
 *      It deliberately runs WITHOUT `--fork-url`: the intent was a fork of Robinhood Chain, but this
 *      environment's egress policy blocks every chain RPC. Running the real vault bytecode locally is
 *      the closest available substitute, and unlike a fork it also runs in CI. The complementary fork
 *      suite is `test/RobinhoodFork.integration.t.sol`, which lights up when `ROBINHOOD_RPC_URL` is set.
 *
 *      HOW TO RUN
 *          forge test --ffi --match-path "test/MorphoVaultsStrategyVaultV2.integration.t.sol" -vv
 *
 *      WHAT IS REAL AND WHAT IS NOT
 *      Real: `VaultV2` (share accounting, `max*` views, decimal offset, virtual shares, interest
 *      accrual and its `maxRate` clamp, performance fees, all four gates) and Morpho's reference
 *      `WhitelistReceiveSharesGate` periphery contract.
 *      Not real: the venue behind the vault. On Robinhood Chain a Steakhouse USDG vault routes through
 *      a `MorphoMarketV1AdapterV2` into Morpho Blue markets; wiring that up needs Morpho Blue, an IRM
 *      and a full market, which the strategy never touches (it only ever calls the ERC4626 surface).
 *      These vaults therefore run adapter-less, holding idle assets — a configuration V2 supports
 *      natively (`liquidityAdapter == address(0)` in `enter`/`exit`). Yield is produced through V2's
 *      genuine accrual path: `accrueInterestView` takes `min(realAssets, _totalAssets * (1 + elapsed *
 *      maxRate))`, so an asset donation plus elapsed time moves the share price through exactly the
 *      same code an adapter's reported interest would. The one thing that is not exercised is
 *      illiquidity: an adapter-backed vault can fail to source assets on exit, which would surface as a
 *      revert inside `VaultV2.exit`. `MorphoVaultsStrategy.withdraw` treats a vault's whole
 *      `convertToAssets(balanceOf)` as available and would revert rather than route around a
 *      temporarily illiquid venue. That is called out in `testWithdrawTreatsFullShareValueAsAvailable`.
 *
 *      ISOLATE MODE
 *      The suite runs with `isolate = true` so every top-level call is its own transaction, as it would
 *      be on chain. This is not cosmetic: V2 caches `firstTotalAssets` in TRANSIENT storage to accrue
 *      interest at most once per transaction. Without isolation, Foundry runs a whole test body as a
 *      single transaction and the vault's share price freezes after the first interaction — which
 *      silently turns every yield assertion into a no-op. Morpho's own suite marks its accrual tests the
 *      same way.
 */
/// forge-config: default.isolate = true
contract MorphoVaultsStrategyVaultV2IntegrationTest is Test {
    /// @dev 200% APR, `MAX_MAX_RATE` from vault-v2 `src/libraries/ConstantsLib.sol`
    uint256 internal constant MAX_MAX_RATE = 200e16 / uint256(365 days);
    uint256 internal constant WAD = 1e18;

    uint256 public constant SUPPLY_CAP = 1_000_000e6;
    uint256 public constant STRATEGY_TYPE_ID = 1;
    uint256 public constant SLIPPAGE_BPS = 100; // 1%
    uint256 public constant COMPOUND_FEE_BPS = 500; // 5%

    address public admin = makeAddr("adminMultisig");
    address public backend = makeAddr("backend");
    address public user = makeAddr("user");
    address public feeRecipient = makeAddr("feeRecipient");
    address public curator = makeAddr("curator");
    address public allocator = makeAddr("allocator");
    address public vaultOwner = makeAddr("vaultOwner");

    MorphoVaultV2Deployer public vaultDeployer;
    MorphoWhitelistGateDeployer public gateDeployer;

    MockERC20Decimals public usdg; // 6 decimals, like mainnet USDG
    MockERC20 public morphoToken; // 18 decimals reward token

    IMorphoVaultV2 public vaultA;
    IMorphoVaultV2 public vaultB;
    IMorphoVaultV2 public vaultC;

    MockStrategyRegistry public registry;
    MockSlippagePriceChecker public priceChecker;
    MockSwapRouter public router;
    MockMerkleDistributor public distributor;
    MamoVaultConfig public config;
    MorphoVaultsStrategy public strategy;

    function setUp() public {
        vaultDeployer = new MorphoVaultV2Deployer();
        gateDeployer = new MorphoWhitelistGateDeployer();

        usdg = new MockERC20Decimals("Global Dollar", "USDG", 6);
        morphoToken = new MockERC20("Morpho", "MORPHO");

        vaultA = _deployVault("Steakhouse USDG", "steakUSDG");
        vaultB = _deployVault("Steakhouse Turbo USDG", "turboUSDG");
        vaultC = _deployVault("Grove USDG", "groveUSDG");

        registry = new MockStrategyRegistry(backend);
        priceChecker = new MockSlippagePriceChecker();
        router = new MockSwapRouter();
        distributor = new MockMerkleDistributor();

        config = new MamoVaultConfig(address(usdg), address(registry), admin, SUPPLY_CAP);

        vm.startPrank(admin);
        config.addVault(address(vaultA));
        config.addVault(address(vaultB));
        config.addVault(address(vaultC));
        vm.stopPrank();

        priceChecker.setRewardToken(address(morphoToken), true);
        // oracle: 1 MORPHO (18dp) = 2 USDG (6dp); pool executes at parity with the oracle by default
        priceChecker.setRate(address(morphoToken), address(usdg), 2e6);
        router.setExecRate(address(morphoToken), address(usdg), 2e6);

        strategy = MorphoVaultsStrategy(payable(_deployStrategy(user)));
        registry.setUserStrategy(user, address(strategy), true);

        usdg.mint(user, 10_000_000e6);
        vm.prank(user);
        usdg.approve(address(strategy), type(uint256).max);
    }

    // ==================== HARNESS ====================

    /// @dev Deploys real VaultV2 bytecode and puts it in the state a curated vault would be in:
    ///      owner -> curator -> allocator, with the allocator holding `setMaxRate`.
    function _deployVault(string memory name_, string memory symbol_) internal returns (IMorphoVaultV2 vault) {
        vault = IMorphoVaultV2(vaultDeployer.deploy(vaultOwner, address(usdg)));

        vm.startPrank(vaultOwner);
        vault.setCurator(curator);
        vault.setName(name_);
        vault.setSymbol(symbol_);
        vm.stopPrank();

        _curate(vault, abi.encodeCall(IMorphoVaultV2.setIsAllocator, (allocator, true)));

        vm.label(address(vault), name_);
    }

    /// @dev Executes a curator-timelocked call. Timelocks default to zero at deployment, so submit and
    ///      execute are atomic; the executing call itself is permissionless by design.
    function _curate(IMorphoVaultV2 vault, bytes memory data) internal {
        vm.prank(curator);
        vault.submit(data);

        (bool success, bytes memory ret) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(32, ret), mload(ret))
            }
        }
    }

    function _defaultVaults() internal view returns (address[] memory vaults, uint256[] memory weights) {
        vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
        weights = new uint256[](2);
        weights[0] = 6000;
        weights[1] = 4000;
    }

    function _initParams(address owner) internal view returns (MorphoVaultsStrategy.InitParams memory params) {
        (address[] memory vaults, uint256[] memory weights) = _defaultVaults();
        params = MorphoVaultsStrategy.InitParams({
            mamoStrategyRegistry: address(registry),
            token: address(usdg),
            vaultConfig: address(config),
            slippagePriceChecker: address(priceChecker),
            dexRouter: address(router),
            merkleDistributor: address(distributor),
            feeRecipient: feeRecipient,
            strategyTypeId: STRATEGY_TYPE_ID,
            owner: owner,
            allowedSlippageInBps: SLIPPAGE_BPS,
            compoundFee: COMPOUND_FEE_BPS,
            vaults: vaults,
            weightsBps: weights
        });
    }

    function _deployStrategy(address owner) internal returns (address) {
        MorphoVaultsStrategy implementation = new MorphoVaultsStrategy();
        bytes memory initData = abi.encodeCall(MorphoVaultsStrategy.initialize, (_initParams(owner)));
        return address(new ERC1967Proxy(address(implementation), initData));
    }

    /// @dev Produces real V2 interest: `accrueInterestView` distributes `min(realAssets, maxTotalAssets)`,
    ///      so a donation is only recognised as the `maxRate` budget accrues over time.
    function _accrueYield(IMorphoVaultV2 vault, uint256 donation, uint256 elapsed) internal {
        vm.prank(allocator);
        vault.setMaxRate(MAX_MAX_RATE);

        usdg.mint(address(vault), donation);
        skip(elapsed);
    }

    // ==================== VAULT V2 GROUND TRUTHS ====================

    /// @notice The load-bearing V2 quirk: every max* view is hardcoded to zero.
    /// @dev A strategy that sized deposits/withdrawals off `maxDeposit`/`maxWithdraw` (as the Base
    ///      `ERC20MoonwellMorphoStrategy` does) would treat every V2 vault as full and empty at once.
    function testRealVaultV2MaxFunctionsAllReturnZero() public view {
        assertEq(vaultA.maxDeposit(address(strategy)), 0, "maxDeposit should be 0");
        assertEq(vaultA.maxMint(address(strategy)), 0, "maxMint should be 0");
        assertEq(vaultA.maxWithdraw(address(strategy)), 0, "maxWithdraw should be 0");
        assertEq(vaultA.maxRedeem(address(strategy)), 0, "maxRedeem should be 0");
    }

    /// @notice V2 derives a decimal offset from the asset: a 6dp asset yields 18dp shares.
    function testRealVaultV2DecimalOffsetForSixDecimalAsset() public view {
        assertEq(usdg.decimals(), 6, "USDG should be 6dp");
        assertEq(vaultA.decimals(), 18, "vault shares should be 18dp");
        assertEq(vaultA.virtualShares(), 1e12, "virtualShares should be 10 ** (18 - 6)");
        assertEq(vaultA.asset(), address(usdg), "asset mismatch");
    }

    /// @notice No gates are configured at deployment, so a fresh V2 vault is open to any contract.
    function testFreshVaultHasNoGates() public view {
        assertEq(vaultA.receiveSharesGate(), address(0), "receiveSharesGate should default to 0");
        assertEq(vaultA.sendSharesGate(), address(0), "sendSharesGate should default to 0");
        assertEq(vaultA.receiveAssetsGate(), address(0), "receiveAssetsGate should default to 0");
        assertEq(vaultA.sendAssetsGate(), address(0), "sendAssetsGate should default to 0");
        assertTrue(vaultA.canReceiveShares(address(strategy)), "ungated vault should accept the strategy");
    }

    // ==================== DEPOSITS ====================

    function testDepositSplitsAcrossTwoRealVaults() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        assertEq(vaultA.convertToAssets(vaultA.balanceOf(address(strategy))), 600e6, "vault A leg");
        assertEq(vaultB.convertToAssets(vaultB.balanceOf(address(strategy))), 400e6, "vault B leg");
        assertEq(strategy.getTotalBalance(), 1000e6, "total balance");
        assertEq(config.totalDeposited(), 1000e6, "tracked principal");

        // real V2 share math: an empty vault mints assets * virtualShares
        assertEq(vaultA.balanceOf(address(strategy)), 600e6 * 1e12, "vault A shares");
        assertEq(usdg.balanceOf(address(vaultA)), 600e6, "vault A holds the assets idle");
    }

    function testDepositIdleTokensIntoRealVaults() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        // rewards land as idle balance and are not metered against the cap
        usdg.mint(address(strategy), 250e6);

        strategy.depositIdleTokens();

        assertEq(strategy.getTotalBalance(), 1250e6, "total balance after idle sweep");
        assertEq(config.totalDeposited(), 1000e6, "idle sweep must not consume cap");
        assertEq(vaultA.convertToAssets(vaultA.balanceOf(address(strategy))), 750e6, "vault A leg");
        assertEq(vaultB.convertToAssets(vaultB.balanceOf(address(strategy))), 500e6, "vault B leg");
    }

    function testSupplyCapAccountingAgainstRealVaults() public {
        vm.prank(user);
        vm.expectRevert("Supply cap exceeded");
        strategy.deposit(SUPPLY_CAP + 1);

        vm.prank(user);
        strategy.deposit(SUPPLY_CAP);
        assertEq(config.remainingCapacity(), 0, "cap consumed");
        assertEq(strategy.getTotalBalance(), SUPPLY_CAP, "principal parked in real vaults");

        vm.prank(user);
        strategy.withdraw(400_000e6);
        assertEq(config.remainingCapacity(), 400_000e6, "withdraw frees capacity");

        vm.prank(user);
        strategy.deposit(400_000e6);
        assertEq(config.remainingCapacity(), 0, "capacity reusable");
    }

    // ==================== WITHDRAWALS ====================
    // These exercise the load-bearing fix: V2's maxWithdraw is 0, so `MorphoVaultsStrategy.withdraw`
    // derives available liquidity from `convertToAssets(balanceOf(strategy))` instead.

    function testWithdrawPartialFromRealVaults() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdraw(700e6);

        assertEq(usdg.balanceOf(user) - balanceBefore, 700e6, "user received the full amount");
        assertEq(strategy.getTotalBalance(), 300e6, "remainder still invested");
        // 600 came out of vault A (drained), the remaining 100 out of vault B
        assertEq(vaultA.balanceOf(address(strategy)), 0, "vault A drained first");
        assertEq(vaultB.convertToAssets(vaultB.balanceOf(address(strategy))), 300e6, "vault B partially drained");
    }

    function testWithdrawAllFromRealVaults() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdrawAll();

        assertEq(usdg.balanceOf(user) - balanceBefore, 1000e6, "full principal returned");
        assertEq(strategy.getTotalBalance(), 0, "position empty");
        assertEq(vaultA.balanceOf(address(strategy)), 0, "vault A shares burned");
        assertEq(vaultB.balanceOf(address(strategy)), 0, "vault B shares burned");
        assertEq(config.totalDeposited(), 0, "cap fully freed");
    }

    /// @notice Withdrawing the exact reported balance is the rounding boundary: `convertToAssets`
    ///         rounds down while V2's `previewWithdraw` rounds up, so a naive strategy could ask for one
    ///         wei more of shares than it owns and revert inside the vault.
    function testWithdrawExactTotalBalanceIsSafeAtTheRoundingBoundary() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        _accrueYield(vaultA, 61e6, 30 days);
        _accrueYield(vaultB, 37e6, 30 days);

        uint256 total = strategy.getTotalBalance();
        assertGt(total, 1000e6, "yield should have accrued");

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdraw(total);

        assertEq(usdg.balanceOf(user) - balanceBefore, total, "exact-balance withdrawal succeeds");
    }

    function testWithdrawRevertsOverReportedBalance() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        vm.prank(user);
        vm.expectRevert("Withdrawal amount exceeds available balance in strategy");
        strategy.withdraw(1000e6 + 1);
    }

    /// @notice Documents a real-venue limitation this local setup cannot otherwise reach.
    /// @dev `withdraw` treats `convertToAssets(balanceOf)` as available liquidity. That is exactly right
    ///      for an adapter-less vault (everything is idle) and for a liquid adapter, but an
    ///      adapter-backed V2 vault whose underlying market is drawn down will revert inside
    ///      `VaultV2.exit` rather than let the strategy skip to the next vault. Here the equivalence is
    ///      asserted directly: reported availability equals what the vault can actually pay out.
    function testWithdrawTreatsFullShareValueAsAvailable() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        uint256 reportedA = vaultA.convertToAssets(vaultA.balanceOf(address(strategy)));
        assertEq(reportedA, usdg.balanceOf(address(vaultA)), "adapter-less vault is fully liquid");

        vm.prank(user);
        strategy.withdraw(reportedA);

        assertEq(vaultA.balanceOf(address(strategy)), 0, "vault A fully exited in one hop");
    }

    function testFuzzDepositWithdrawRoundTripAgainstRealVaults(uint256 amount) public {
        amount = bound(amount, 1e6, SUPPLY_CAP);

        vm.prank(user);
        strategy.deposit(amount);

        // weight split truncates, so the strategy may retain a wei or two of idle dust
        assertApproxEqAbs(strategy.getTotalBalance(), amount, 2, "balance preserved through real vaults");

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdrawAll();

        assertApproxEqAbs(usdg.balanceOf(user) - balanceBefore, amount, 2, "round trip preserves principal");
        assertEq(strategy.getTotalBalance(), 0, "position empty");
    }

    /// @notice Fuzzes the exact-balance withdrawal against real V2 share math after interest has
    ///         accrued and performance-fee shares have diluted the position. `getTotalBalance` sums
    ///         `convertToAssets` (rounds down) while the vault prices the withdrawal with
    ///         `previewWithdraw` (rounds up); this proves the two never cross.
    function testFuzzWithdrawExactBalanceAfterYield(uint256 amount, uint256 donation, uint256 elapsed) public {
        amount = bound(amount, 1e6, SUPPLY_CAP);
        donation = bound(donation, 0, amount);
        elapsed = bound(elapsed, 1, 365 days);

        _curate(vaultA, abi.encodeCall(IMorphoVaultV2.setPerformanceFeeRecipient, (makeAddr("vaultFees"))));
        _curate(vaultA, abi.encodeCall(IMorphoVaultV2.setPerformanceFee, (0.1e18)));

        vm.prank(user);
        strategy.deposit(amount);

        _accrueYield(vaultA, donation, elapsed);
        _accrueYield(vaultB, donation / 2, elapsed);

        uint256 total = strategy.getTotalBalance();
        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdraw(total);

        assertEq(usdg.balanceOf(user) - balanceBefore, total, "exact-balance withdrawal always settles");
        assertEq(strategy.getTotalBalance(), 0, "position fully drained");
    }

    // ==================== REBALANCING ====================

    function testUpdatePositionRebalancesBetweenRealVaults() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        address[] memory newVaults = new address[](2);
        newVaults[0] = address(vaultB);
        newVaults[1] = address(vaultC);
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 2500;
        newWeights[1] = 7500;

        vm.prank(backend);
        strategy.updatePosition(newVaults, newWeights);

        assertEq(vaultA.balanceOf(address(strategy)), 0, "vault A exited");
        assertEq(vaultB.convertToAssets(vaultB.balanceOf(address(strategy))), 250e6, "vault B leg");
        assertEq(vaultC.convertToAssets(vaultC.balanceOf(address(strategy))), 750e6, "vault C leg");
        assertEq(strategy.getTotalBalance(), 1000e6, "no value lost in the rebalance");
    }

    /// @notice A rebalance out of a vault that has accrued interest must carry the yield with it.
    function testUpdatePositionCarriesAccruedYield() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        _accrueYield(vaultA, 60e6, 30 days);

        uint256 totalBefore = strategy.getTotalBalance();
        assertApproxEqAbs(totalBefore, 1060e6, 1, "yield visible before rebalance");

        address[] memory newVaults = new address[](1);
        newVaults[0] = address(vaultC);
        uint256[] memory newWeights = new uint256[](1);
        newWeights[0] = 10000;

        vm.prank(backend);
        strategy.updatePosition(newVaults, newWeights);

        assertApproxEqAbs(strategy.getTotalBalance(), totalBefore, 1, "yield survives the rebalance");
        assertApproxEqAbs(
            vaultC.convertToAssets(vaultC.balanceOf(address(strategy))), totalBefore, 1, "all value in vault C"
        );
    }

    function testUpdatePositionRevertsForNonAllowlistedRealVault() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        IMorphoVaultV2 rogue = _deployVault("Rogue USDG", "rogueUSDG");

        address[] memory newVaults = new address[](1);
        newVaults[0] = address(rogue);
        uint256[] memory newWeights = new uint256[](1);
        newWeights[0] = 10000;

        vm.prank(backend);
        vm.expectRevert("Vault not allowlisted");
        strategy.updatePosition(newVaults, newWeights);
    }

    // ==================== YIELD ACCRUAL (REAL V2 SEMANTICS) ====================

    /// @notice THE headline mock-vs-real difference. Against an OpenZeppelin ERC4626 mock, sending
    ///         underlying straight to the vault raises the share price immediately. Real Vault V2
    ///         clamps recognised assets to `_totalAssets * (1 + elapsed * maxRate)`, and `maxRate`
    ///         defaults to zero — so with no allocator action the donation is invisible forever.
    function testDonationIsInvisibleUntilMaxRateAndTimeElapse() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        assertEq(vaultA.maxRate(), 0, "maxRate defaults to zero");

        usdg.mint(address(vaultA), 60e6);
        assertEq(strategy.getTotalBalance(), 1000e6, "donation invisible with maxRate == 0");

        skip(30 days);
        assertEq(strategy.getTotalBalance(), 1000e6, "still invisible: time alone does nothing");

        vm.prank(allocator);
        vaultA.setMaxRate(MAX_MAX_RATE);
        assertEq(strategy.getTotalBalance(), 1000e6, "still invisible: rate alone does nothing");

        skip(30 days);
        assertApproxEqAbs(strategy.getTotalBalance(), 1060e6, 1, "donation distributed once the rate budget accrues");
    }

    /// @notice Interest is rate-limited, not instantaneous: a donation larger than the elapsed
    ///         `maxRate` budget is recognised only up to that budget.
    function testInterestIsClampedByMaxRateBudget() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        vm.prank(allocator);
        vaultA.setMaxRate(MAX_MAX_RATE);

        // 600 USDG sits in vault A; donate 600 (a 100% jump) but only let one day elapse
        usdg.mint(address(vaultA), 600e6);
        skip(1 days);

        // budget = 600e6 * 1 day * MAX_MAX_RATE / WAD, i.e. 200% APR for one day
        uint256 budget = (600e6 * uint256(1 days) * MAX_MAX_RATE) / WAD;
        assertApproxEqAbs(strategy.getTotalBalance(), 1000e6 + budget, 1, "recognised interest capped at the budget");
        assertLt(strategy.getTotalBalance(), 1600e6, "donation not recognised in full");

        // the rest is recognised as more time passes
        skip(365 days);
        assertApproxEqAbs(strategy.getTotalBalance(), 1600e6, 1, "full donation eventually distributed");
    }

    function testYieldAccrualIncreasesTotalBalanceAcrossBothVaults() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        _accrueYield(vaultA, 60e6, 30 days);
        _accrueYield(vaultB, 20e6, 30 days);

        assertApproxEqAbs(strategy.getTotalBalance(), 1080e6, 2, "yield from both legs");

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdrawAll();

        assertApproxEqAbs(usdg.balanceOf(user) - balanceBefore, 1080e6, 2, "yield withdrawable");
        // yield is not principal: the cap meter only ever frees what was deposited
        assertEq(config.totalDeposited(), 0, "cap meter clamped down to tracked principal");
    }

    /// @notice A curated V2 vault charges a performance fee in shares, diluting the strategy's position.
    function testPerformanceFeeDilutesStrategyPosition() public {
        address vaultFeeRecipient = makeAddr("vaultFeeRecipient");

        _curate(vaultA, abi.encodeCall(IMorphoVaultV2.setPerformanceFeeRecipient, (vaultFeeRecipient)));
        _curate(vaultA, abi.encodeCall(IMorphoVaultV2.setPerformanceFee, (0.1e18))); // 10%

        vm.prank(user);
        strategy.deposit(1000e6);

        _accrueYield(vaultA, 60e6, 30 days);

        // 60 USDG of interest, 10% of which is owed as shares to the vault's fee recipient
        assertApproxEqAbs(strategy.getTotalBalance(), 1054e6, 2, "strategy keeps 90% of the interest");

        // the shares themselves are only minted when interest is accrued in a state-changing call
        assertEq(vaultA.balanceOf(vaultFeeRecipient), 0, "fee shares not minted by view calls");
        vaultA.accrueInterest();
        assertGt(vaultA.balanceOf(vaultFeeRecipient), 0, "vault fee recipient paid in shares on accrual");
        assertApproxEqAbs(strategy.getTotalBalance(), 1054e6, 2, "share price unchanged by the minting itself");

        vm.prank(user);
        strategy.withdrawAll();
        assertEq(strategy.getTotalBalance(), 0, "exit still clean with fee shares outstanding");
    }

    // ==================== GATES (THE #1 GO/NO-GO CHECK) ====================

    /// @notice Spec §6 item 1: if a Steakhouse vault sets a receive-shares gate, every Mamo strategy
    ///         contract is locked out until the curator whitelists it. This is the go/no-go read.
    function testReceiveSharesGateBlocksStrategyDeposit() public {
        address gate = gateDeployer.deploy(admin);
        _curate(vaultA, abi.encodeCall(IMorphoVaultV2.setReceiveSharesGate, (gate)));

        assertFalse(vaultA.canReceiveShares(address(strategy)), "strategy not whitelisted");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CannotReceiveShares.selector));
        strategy.deposit(1000e6);
    }

    /// @notice ...and the mitigation: the curator whitelists the per-user strategy address.
    function testReceiveSharesGateAllowsWhitelistedStrategy() public {
        address gate = gateDeployer.deploy(admin);
        _curate(vaultA, abi.encodeCall(IMorphoVaultV2.setReceiveSharesGate, (gate)));

        vm.startPrank(admin);
        IMorphoWhitelistGate(gate).setIsWhitelister(admin, true);
        IMorphoWhitelistGate(gate).setIsWhitelisted(address(strategy), true);
        vm.stopPrank();

        assertTrue(vaultA.canReceiveShares(address(strategy)), "strategy whitelisted");

        vm.prank(user);
        strategy.deposit(1000e6);

        assertEq(strategy.getTotalBalance(), 1000e6, "gated vault accepts a whitelisted strategy");

        // and the position remains exitable
        vm.prank(user);
        strategy.withdrawAll();
        assertEq(strategy.getTotalBalance(), 0, "exit unaffected by a receive-shares gate");
    }

    /// @notice The exit-side risk: a send-shares gate can trap an already-funded position. Worth
    ///         monitoring per vault, because it converts a venue change into a stranded position.
    function testSendSharesGateCanTrapAnExistingPosition() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        DenyShareTransferGate gate = new DenyShareTransferGate();
        _curate(vaultA, abi.encodeCall(IMorphoVaultV2.setSendSharesGate, (address(gate))));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CannotSendShares.selector));
        strategy.withdrawAll();

        // the backend cannot rotate out of the vault either
        (address[] memory vaults, uint256[] memory weights) = _defaultVaults();
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CannotSendShares.selector));
        strategy.updatePosition(vaults, weights);
    }

    // ==================== COMPOUNDING ====================

    function testCompoundRewardsRedepositsIntoRealVaults() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        // 100 MORPHO from a Merkl claim; oracle says 1 MORPHO = 2 USDG
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(morphoToken);
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 100e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        vm.prank(backend);
        strategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        assertEq(morphoToken.balanceOf(address(strategy)), 100e18, "rewards claimed");

        vm.prank(backend);
        strategy.compoundRewards(address(morphoToken), 3000, 0);

        // 200 USDG out, 5% fee = 10 USDG, 190 USDG redeposited across the real vaults
        assertEq(usdg.balanceOf(feeRecipient), 10e6, "compound fee skimmed");
        assertEq(strategy.getTotalBalance(), 1190e6, "compounded into the vaults");
        assertEq(config.totalDeposited(), 1000e6, "compounded yield exempt from the cap");
        assertEq(vaultA.convertToAssets(vaultA.balanceOf(address(strategy))), 714e6, "vault A leg");
        assertEq(vaultB.convertToAssets(vaultB.balanceOf(address(strategy))), 476e6, "vault B leg");
    }

    function testCompoundRewardsRevertsWhenPoolPriceBreachesOracleFloor() public {
        vm.prank(user);
        strategy.deposit(1000e6);

        morphoToken.mint(address(strategy), 100e18);

        // pool executes 2% below oracle, outside the 1% slippage bound
        router.setExecRate(address(morphoToken), address(usdg), 1.96e6);

        vm.prank(backend);
        vm.expectRevert("Too little received");
        strategy.compoundRewards(address(morphoToken), 3000, 0);
    }
}

/// @notice ERC20 with configurable decimals so tests can match mainnet USDG's 6dp profile.
/// @dev Exposes `mint(address,uint256)` with the same signature as `MockERC20`, so the shared
///      Robinhood mocks (swap router, Merkl distributor) can mint it.
contract MockERC20Decimals is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal send-shares gate that denies everyone, used to exercise VaultV2's exit gating.
/// @dev Morpho's own periphery only ships receive-shares and send-assets whitelist gates; the vault's
///      `sendSharesGate` hook is real, this stub only supplies the boolean it reads.
contract DenyShareTransferGate {
    function canSendShares(address) external pure returns (bool) {
        return false;
    }
}
