// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";

import {MockToken} from "./mocks/MockToken.sol";
import {MockVaultStrategy} from "./mocks/MockVaultStrategy.sol";

import {Test} from "@forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LeveragedAeroVault unit tests
 * @notice Fork-free unit suite (runs under `make test-unit` / `make leveraged-aero-vault`) for the
 *         vanilla share ledger the vendored leveraged-Aero strategy binds to. The strategy itself is
 *         stubbed by {MockVaultStrategy} — the vault's own surface (decimals offset, share hooks,
 *         fee-config hops, lifecycle, settled exit, rescue) is what is under test.
 */
contract LeveragedAeroVaultUnitTest is Test {
    // ---- events mirrored from LeveragedAeroVault (for vm.expectEmit) ----
    event StrategySet(address indexed strategy);
    event OpenDepositsUpdated(bool open);
    event FeeConfigUpdated(address indexed feeConfig);
    event StrategyActivated(address indexed strategy, uint256 seedAmount);
    event StrategySettled(address indexed strategy);
    event SettledRedeem(address indexed owner, uint256 shares, uint256 assetsOut);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    address public owner = makeAddr("owner");
    address public thirdParty = makeAddr("thirdParty");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public feeConfig = makeAddr("feeConfig");

    MockToken public usdc;
    MockToken public stray;
    LeveragedAeroVault public vault;
    MockVaultStrategy public strategy;

    uint256 internal constant SEED = 10_000e6; // 10k USDC

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        stray = new MockToken("Stray", "STRAY", 18);
        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        strategy = new MockVaultStrategy(address(vault), address(usdc));
    }

    // ==================== HELPERS ====================

    function _bind() internal {
        vm.prank(owner);
        vault.setStrategy(address(strategy));
    }

    function _openDeposits() internal {
        vm.prank(owner);
        vault.setOpenDeposits(true);
    }

    /// @dev Binds the strategy, opens deposits, and mints `shares` to `to` through the strategy hook.
    function _bindAndMint(address to, uint256 shares) internal {
        if (vault.strategy() == address(0)) _bind();
        if (!vault.depositsOpen()) _openDeposits();
        strategy.mintShares(to, shares);
    }

    /// @dev Funds `owner` with `amount` USDC and approves the vault to pull it for the seed.
    function _fundOwner(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.prank(owner);
        usdc.approve(address(vault), amount);
    }

    // ==================== CONSTRUCTION ====================

    function testConstructorWiring() public view {
        assertEq(vault.asset(), address(usdc), "asset");
        assertEq(vault.owner(), owner, "owner");
        assertEq(vault.name(), "Leveraged Aero Vault", "name");
        assertEq(vault.symbol(), "lvAERO", "symbol");
        assertEq(vault.strategy(), address(0), "strategy unset");
        assertFalse(vault.depositsOpen(), "deposits closed by default");
        assertFalse(vault.settled(), "not settled");
        assertEq(vault.feeConfig(), address(0), "fee config unset");
    }

    function testConstructorZeroAssetReverts() public {
        vm.expectRevert("LAV: invalid asset");
        new LeveragedAeroVault(address(0), owner, "n", "s");
    }

    function testConstructorZeroOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LeveragedAeroVault(address(usdc), address(0), "n", "s");
    }

    // ==================== DECIMALS ====================

    function testDecimalsIsAssetPlusSix() public view {
        assertEq(vault.decimals(), 12, "6dp asset -> 12dp shares");
    }

    function testDecimalsTracksAssetDecimals() public {
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18);
        LeveragedAeroVault wethVault = new LeveragedAeroVault(address(weth), owner, "n", "s");
        assertEq(wethVault.decimals(), 24, "18dp asset -> 24dp shares");
    }

    // ==================== SET STRATEGY ====================

    function testSetStrategy() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit StrategySet(address(strategy));

        vm.prank(owner);
        vault.setStrategy(address(strategy));

        assertEq(vault.strategy(), address(strategy), "strategy");
    }

    function testSetStrategyOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.setStrategy(address(strategy));
    }

    function testSetStrategyIsSetOnce() public {
        _bind();

        vm.prank(owner);
        vm.expectRevert("LAV: strategy already set");
        vault.setStrategy(makeAddr("otherStrategy"));
    }

    function testSetStrategyZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert("LAV: invalid strategy");
        vault.setStrategy(address(0));
    }

    /// @dev A clone initialized against ANOTHER vault must not be bindable here: it would hand this
    ///      ledger's mint/burn hooks to a contract pricing a different book.
    function testSetStrategyRejectsForeignVaultBinding() public {
        LeveragedAeroVault otherVault = new LeveragedAeroVault(address(usdc), owner, "other", "OTH");
        MockVaultStrategy foreign = new MockVaultStrategy(address(otherVault), address(usdc));

        vm.prank(owner);
        vm.expectRevert("LAV: strategy not bound to this vault");
        vault.setStrategy(address(foreign));
    }

    // ==================== CLONE AND BIND ====================

    function testCloneAndBindHappyPath() public {
        vm.expectEmit(false, false, false, false, address(vault));
        emit StrategySet(address(0)); // topic-only check; the clone address is asserted below

        vm.prank(owner);
        address clone = vault.cloneAndBind(address(strategy), thirdParty, "");

        assertEq(vault.strategy(), clone, "bound to the fresh clone");
        assertEq(MockVaultStrategy(clone).vault(), address(vault), "clone initialized against this vault");
        assertEq(MockVaultStrategy(clone).proposer(), thirdParty, "proposer wired atomically");
        assertTrue(clone != address(strategy), "a clone, not the template");
    }

    /// @dev The bound clone is immediately usable — no second wiring transaction, no window in which
    ///      the vault points at an un-initialized strategy.
    function testCloneAndBindProducesAUsableStrategy() public {
        vm.startPrank(owner);
        address clone = vault.cloneAndBind(address(strategy), thirdParty, "");
        vault.setOpenDeposits(true);
        vm.stopPrank();

        MockVaultStrategy(clone).mintShares(alice, 5e12);
        assertEq(vault.balanceOf(alice), 5e12, "the bound clone can mint");
    }

    function testCloneAndBindOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.cloneAndBind(address(strategy), thirdParty, "");
    }

    /// @dev `_bind` guards BOTH entrypoints: a template whose `initialize` ignores the vault argument
    ///      still cannot slip a foreign binding through the atomic path.
    function testCloneAndBindRejectsForeignVaultBinding() public {
        MisboundStrategyStub stub = new MisboundStrategyStub(makeAddr("someOtherVault"));

        vm.prank(owner);
        vm.expectRevert("LAV: strategy not bound to this vault");
        vault.cloneAndBind(address(stub), thirdParty, "");
    }

    /// @dev Set-once holds across the two paths in both orders.
    function testBindIsSetOnceAcrossBothPaths() public {
        vm.startPrank(owner);
        vault.cloneAndBind(address(strategy), thirdParty, "");

        vm.expectRevert("LAV: strategy already set");
        vault.cloneAndBind(address(strategy), thirdParty, "");

        vm.expectRevert("LAV: strategy already set");
        vault.setStrategy(address(strategy));
        vm.stopPrank();
    }

    function testSetStrategyThenCloneAndBindReverts() public {
        _bind();

        vm.prank(owner);
        vm.expectRevert("LAV: strategy already set");
        vault.cloneAndBind(address(strategy), thirdParty, "");
    }

    // ==================== STRATEGY MINT ====================

    function testStrategyMint() public {
        _bindAndMint(alice, 1_000e12);

        assertEq(vault.balanceOf(alice), 1_000e12, "alice shares");
        assertEq(vault.totalSupply(), 1_000e12, "supply");
    }

    function testStrategyMintOnlyStrategy() public {
        _bind();
        _openDeposits();

        vm.prank(thirdParty);
        vm.expectRevert("LAV: only strategy");
        vault.strategyMint(thirdParty, 1e12);
    }

    function testStrategyMintOnlyStrategyEvenForOwner() public {
        _bind();
        _openDeposits();

        vm.prank(owner);
        vm.expectRevert("LAV: only strategy");
        vault.strategyMint(owner, 1e12);
    }

    function testStrategyMintRequiresOpenDeposits() public {
        _bind();

        vm.expectRevert("LAV: deposits closed");
        strategy.mintShares(alice, 1e12);
    }

    function testStrategyMintRevertsAfterDepositsReclosed() public {
        _bindAndMint(alice, 1e12);

        vm.prank(owner);
        vault.setOpenDeposits(false);

        vm.expectRevert("LAV: deposits closed");
        strategy.mintShares(alice, 1e12);
    }

    function testSetOpenDepositsOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.setOpenDeposits(true);
    }

    function testSetOpenDepositsEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit OpenDepositsUpdated(true);

        vm.prank(owner);
        vault.setOpenDeposits(true);
        assertTrue(vault.depositsOpen(), "open");
    }

    // ==================== STRATEGY BURN ====================

    function testStrategyBurnBurnsOwnBalance() public {
        _bindAndMint(alice, 1_000e12);

        // Alice approves + the strategy pulls the shares, exactly as `redeem` does.
        vm.prank(alice);
        vault.approve(address(strategy), 400e12);
        strategy.pullShares(alice, 400e12);
        assertEq(vault.balanceOf(address(strategy)), 400e12, "escrowed");

        strategy.burnShares(400e12);

        assertEq(vault.balanceOf(address(strategy)), 0, "burned");
        assertEq(vault.balanceOf(alice), 600e12, "alice remainder");
        assertEq(vault.totalSupply(), 600e12, "supply");
    }

    function testStrategyBurnOnlyStrategy() public {
        _bindAndMint(thirdParty, 1e12);

        vm.prank(thirdParty);
        vm.expectRevert("LAV: only strategy");
        vault.strategyBurn(1e12);
    }

    /// @dev Exits must survive a deposit freeze: burn is deliberately NOT gated on `depositsOpen`.
    function testStrategyBurnWorksWhenDepositsClosed() public {
        _bindAndMint(alice, 1_000e12);

        vm.prank(alice);
        vault.approve(address(strategy), 1_000e12);
        strategy.pullShares(alice, 1_000e12);

        vm.prank(owner);
        vault.setOpenDeposits(false);

        strategy.burnShares(1_000e12);
        assertEq(vault.totalSupply(), 0, "supply");
    }

    function testStrategyBurnCannotBurnThirdPartyShares() public {
        _bindAndMint(alice, 1_000e12);

        // The strategy holds nothing, so a burn hits ERC20InsufficientBalance rather than
        // touching alice's balance.
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", address(strategy), 0, 1e12)
        );
        strategy.burnShares(1e12);
        assertEq(vault.balanceOf(alice), 1_000e12, "alice untouched");
    }

    // ==================== FEE CONFIG ====================

    function testFeeConfigUnsetShortCircuits() public view {
        assertEq(vault.factory(), address(0), "factory hop off");
        assertEq(vault.protocolConfig(), address(0), "config off");
    }

    function testFeeConfigSetPointsFactoryAtSelf() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit FeeConfigUpdated(feeConfig);

        vm.prank(owner);
        vault.setFeeConfig(feeConfig);

        assertEq(vault.factory(), address(vault), "factory hop -> self");
        assertEq(vault.protocolConfig(), feeConfig, "config");
    }

    function testFeeConfigCanBeCleared() public {
        vm.startPrank(owner);
        vault.setFeeConfig(feeConfig);
        vault.setFeeConfig(address(0));
        vm.stopPrank();

        assertEq(vault.factory(), address(0), "factory hop off again");
        assertEq(vault.protocolConfig(), address(0), "config cleared");
    }

    function testSetFeeConfigOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.setFeeConfig(feeConfig);
    }

    // ==================== ACTIVATE ====================

    function testActivateStrategySeedsAndExecutes() public {
        _bind();
        _fundOwner(SEED);

        vm.expectEmit(true, false, false, true, address(vault));
        emit StrategyActivated(address(strategy), SEED);

        vm.prank(owner);
        vault.activateStrategy(SEED);

        assertEq(usdc.balanceOf(address(strategy)), SEED, "seed landed on strategy");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault never custodies the seed");
        assertEq(strategy.seedReceived(), SEED, "strategy saw the seed at execute()");
        assertEq(uint256(strategy.phase()), uint256(MockVaultStrategy.Phase.Executed), "executed");
        assertEq(vault.balanceOf(owner), SEED * 1e6, "seeder minted the genesis shares");
        assertEq(vault.totalSupply(), SEED * 1e6, "supply == the genesis mint");
    }

    /// @dev The genesis rate is the decimals offset, not a magic 1e6: an 18dp asset must mint
    ///      `seed x 1e6` in 24dp share units by the same rule.
    function testActivateStrategyMintsAtTheDecimalsOffset() public {
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18);
        LeveragedAeroVault wethVault = new LeveragedAeroVault(address(weth), owner, "n", "s");
        MockVaultStrategy wethStrategy = new MockVaultStrategy(address(wethVault), address(weth));

        weth.mint(owner, 5e18);
        vm.startPrank(owner);
        weth.approve(address(wethVault), 5e18);
        wethVault.setStrategy(address(wethStrategy));
        wethVault.activateStrategy(5e18);
        vm.stopPrank();

        assertEq(wethVault.decimals(), 24, "24dp shares");
        assertEq(wethVault.balanceOf(owner), 5e18 * 1e6, "seed x 10 ** (24 - 18)");
    }

    /// @dev A zero seed mints nothing — no phantom supply, and the strategy still executes.
    function testActivateStrategyZeroSeedMintsNoShares() public {
        _bind();

        vm.prank(owner);
        vault.activateStrategy(0);

        assertEq(vault.totalSupply(), 0, "no shares for a zero seed");
    }

    /// @dev The mint is gated on `execute()` succeeding: a strategy that reverts on activation must
    ///      leave no shares behind. Executing twice reverts inside the mock strategy.
    function testActivateStrategyMintsNothingWhenExecuteReverts() public {
        _bind();
        _fundOwner(SEED);

        vm.startPrank(owner);
        vault.activateStrategy(SEED);
        uint256 supplyAfterFirst = vault.totalSupply();
        vm.expectRevert("MockStrategy: already executed");
        vault.activateStrategy(0);
        vm.stopPrank();

        assertEq(vault.totalSupply(), supplyAfterFirst, "no shares from the reverted activation");
    }

    /// @dev The seed mint bypasses {depositsOpen} on purpose — it is the owner's own capital going in
    ///      at a fixed rate, not LP issuance, and activation must not require opening the gate first.
    function testActivateStrategyMintsWhileDepositsClosed() public {
        _bind();
        _fundOwner(SEED);
        assertFalse(vault.depositsOpen(), "deposits closed");

        vm.prank(owner);
        vault.activateStrategy(SEED);

        assertEq(vault.balanceOf(owner), SEED * 1e6, "genesis mint is not gated on depositsOpen");
    }

    /**
     * @dev The reviewer's worked example, end to end: seed 1000 USDC, then a 1000 USDC depositor
     *      priced through the REAL strategy formula (`assets x (supply + 1e6) / (nav + 1)`, nav read
     *      pre-pull) must end up with an EQUAL claim — no value transfer from seeder to first
     *      depositor. Before the genesis mint the depositor minted against `supply == 0` and a
     *      nonzero NAV, taking ~100% of a book they half funded.
     */
    function testGenesisMintMakesTheFirstDepositorFair() public {
        _bind();
        _openDeposits();
        _fundOwner(1_000e6);

        vm.prank(owner);
        vault.activateStrategy(1_000e6);

        uint256 seedShares = vault.balanceOf(owner);
        assertEq(seedShares, 1_000e6 * 1e6, "seeder holds the genesis shares");

        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(strategy), 1_000e6);
        uint256 aliceShares = strategy.depositPriced(1_000e6);
        vm.stopPrank();

        // Equal capital in at an unchanged per-share price => equal shares out.
        assertEq(aliceShares, seedShares, "equal deposit mints an equal claim");
        assertEq(vault.totalSupply(), 2 * seedShares, "supply doubled");

        // And an equal claim on the book: NAV is 2000 USDC, each side owns half.
        uint256 nav = usdc.balanceOf(address(strategy));
        assertEq(nav, 2_000e6, "book NAV");
        assertEq((aliceShares * nav) / vault.totalSupply(), 1_000e6, "alice's pro-rata claim");
        assertEq((seedShares * nav) / vault.totalSupply(), 1_000e6, "seeder's pro-rata claim");
    }

    /// @dev A second depositor arriving at an UNCHANGED per-share price mints proportionally — the
    ///      genesis mint keeps supply and NAV in step for every later deposit, not just the first.
    function testSubsequentDepositorMintsProRataAtUnchangedNav() public {
        _bind();
        _openDeposits();
        _fundOwner(1_000e6);
        vm.prank(owner);
        vault.activateStrategy(1_000e6);

        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(strategy), 1_000e6);
        strategy.depositPriced(1_000e6);
        vm.stopPrank();

        // Bob puts in half as much at the same price => half the shares.
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(strategy), 500e6);
        uint256 bobShares = strategy.depositPriced(500e6);
        vm.stopPrank();

        assertApproxEqRel(bobShares, vault.balanceOf(alice) / 2, 1e12, "half the capital, half the shares");

        uint256 nav = usdc.balanceOf(address(strategy));
        assertEq(nav, 2_500e6, "book NAV");
        assertApproxEqRel((bobShares * nav) / vault.totalSupply(), 500e6, 1e12, "bob's claim == his capital");
    }

    function testActivateStrategyOnlyOwner() public {
        _bind();
        usdc.mint(thirdParty, SEED);
        vm.prank(thirdParty);
        usdc.approve(address(vault), SEED);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.activateStrategy(SEED);
    }

    function testActivateStrategyRequiresStrategySet() public {
        _fundOwner(SEED);

        vm.prank(owner);
        vm.expectRevert("LAV: strategy not set");
        vault.activateStrategy(SEED);
    }

    /// @dev The vault imposes no seed floor: a zero seed is forwarded and the STRATEGY decides. The
    ///      real strategy reverts `ExecuteZeroBalance`; this mock records a zero seed instead.
    function testActivateStrategyZeroSeedIsForwardedToStrategy() public {
        _bind();

        vm.prank(owner);
        vault.activateStrategy(0);

        assertEq(strategy.seedReceived(), 0, "zero seed observed by strategy");
        assertEq(uint256(strategy.phase()), uint256(MockVaultStrategy.Phase.Executed), "executed");
    }

    function testActivateStrategyTwiceReverts() public {
        _bind();
        _fundOwner(SEED);

        vm.startPrank(owner);
        vault.activateStrategy(SEED);
        vm.expectRevert("MockStrategy: already executed");
        vault.activateStrategy(0);
        vm.stopPrank();
    }

    // ==================== SETTLE ====================

    function testSettleStrategyPullsRealizedAssets() public {
        _bind();
        _fundOwner(SEED);
        vm.prank(owner);
        vault.activateStrategy(SEED);

        // Simulate a profitable book: the strategy ends with more than it was seeded.
        usdc.mint(address(strategy), 1_000e6);

        vm.expectEmit(true, false, false, false, address(vault));
        emit StrategySettled(address(strategy));

        vm.prank(owner);
        vault.settleStrategy();

        assertTrue(vault.settled(), "settled");
        assertEq(usdc.balanceOf(address(vault)), SEED + 1_000e6, "realized assets in vault");
        assertEq(usdc.balanceOf(address(strategy)), 0, "strategy flat");
    }

    function testSettleStrategyOnlyOwner() public {
        _bind();
        _fundOwner(SEED);
        vm.prank(owner);
        vault.activateStrategy(SEED);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.settleStrategy();
    }

    function testSettleStrategyRequiresStrategySet() public {
        vm.prank(owner);
        vm.expectRevert("LAV: strategy not set");
        vault.settleStrategy();
    }

    /// @dev The vault imposes no lifecycle ordering of its own — the STRATEGY's state machine does.
    ///      Settling a bound-but-never-activated strategy bounces there, and {settled} stays false.
    function testSettleStrategyBeforeActivateReverts() public {
        _bind();

        vm.prank(owner);
        vm.expectRevert("MockStrategy: not executed");
        vault.settleStrategy();

        assertFalse(vault.settled(), "settled flag untouched");
    }

    /// @dev Settlement is one-way: the strategy rejects the second `settle()`, so {settled} can never
    ///      be re-armed and there is no path back to an active book.
    function testSettleStrategyTwiceReverts() public {
        _bind();
        vm.startPrank(owner);
        vault.activateStrategy(0);
        vault.settleStrategy();

        vm.expectRevert("MockStrategy: not executed");
        vault.settleStrategy();
        vm.stopPrank();

        assertTrue(vault.settled(), "still settled");
    }

    // ==================== REDEEM SETTLED ====================

    /// @dev Sets up 1e12 (alice) + 2e12 (bob) shares against a 1000 USDC settled pot.
    /// @dev Activated with a ZERO seed deliberately: {activateStrategy} mints the seeder
    ///      `seedAmount x 1e6` genesis shares, and any nonzero seed here would swamp the 1:2 split
    ///      these pro-rata assertions are about. The genesis mint has its own tests below.
    function _settledBook() internal {
        _bindAndMint(alice, 1e12);
        strategy.mintShares(bob, 2e12);

        vm.prank(owner);
        vault.activateStrategy(0);

        // Fund the strategy so it settles with exactly 1000 USDC of realized assets.
        deal(address(usdc), address(strategy), 1_000e6);

        vm.prank(owner);
        vault.settleStrategy();
    }

    function testRedeemSettledProRataRoundsDown() public {
        _settledBook();
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "pot");

        // alice: 1e12 / 3e12 of 1000e6 = 333.333333... -> 333333333 (floors, stayers keep the dust)
        vm.expectEmit(true, false, false, true, address(vault));
        emit SettledRedeem(alice, 1e12, 333_333_333);

        vm.prank(alice);
        uint256 aliceOut = vault.redeemSettled(1e12);

        assertEq(aliceOut, 333_333_333, "alice payout floors down");
        assertEq(usdc.balanceOf(alice), 333_333_333, "alice paid");
        assertEq(vault.balanceOf(alice), 0, "alice burned");
        assertEq(vault.totalSupply(), 2e12, "supply after alice");

        // bob then takes the whole remainder, including the wei alice's rounding left behind.
        vm.prank(bob);
        uint256 bobOut = vault.redeemSettled(2e12);

        assertEq(bobOut, 666_666_667, "bob absorbs the rounding residual");
        assertEq(aliceOut + bobOut, 1_000e6, "pot fully distributed");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault drained");
        assertEq(vault.totalSupply(), 0, "supply zero");
    }

    function testRedeemSettledPartial() public {
        _settledBook();

        vm.prank(bob);
        uint256 out = vault.redeemSettled(1e12);

        // 1e12 / 3e12 of 1000e6
        assertEq(out, 333_333_333, "partial payout");
        assertEq(vault.balanceOf(bob), 1e12, "bob keeps the rest");
        assertEq(vault.totalSupply(), 2e12, "supply");
    }

    function testRedeemSettledBeforeSettleReverts() public {
        _bindAndMint(alice, 1e12);

        vm.prank(alice);
        vm.expectRevert("LAV: not settled");
        vault.redeemSettled(1e12);
    }

    function testRedeemSettledZeroSharesReverts() public {
        _settledBook();

        vm.prank(alice);
        vm.expectRevert("LAV: zero shares");
        vault.redeemSettled(0);
    }

    function testRedeemSettledWithoutSharesReverts() public {
        _settledBook();

        vm.prank(thirdParty);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", thirdParty, 0, 1e12)
        );
        vault.redeemSettled(1e12);
    }

    function testRedeemSettledEmptyPotBurnsForZero() public {
        _bindAndMint(alice, 1e12);
        _fundOwner(0);
        vm.startPrank(owner);
        vault.activateStrategy(0);
        vault.settleStrategy();
        vm.stopPrank();

        vm.prank(alice);
        uint256 out = vault.redeemSettled(1e12);

        assertEq(out, 0, "nothing to pay");
        assertEq(vault.totalSupply(), 0, "shares burned anyway");
    }

    /// @dev Once the last holder has exited, the pro-rata divisor is 0 — the guard must fire with a
    ///      typed message rather than a division panic.
    function testRedeemSettledWithZeroSupplyReverts() public {
        _settledBook();

        vm.prank(alice);
        vault.redeemSettled(1e12);
        vm.prank(bob);
        vault.redeemSettled(2e12);
        assertEq(vault.totalSupply(), 0, "book empty");

        vm.prank(alice);
        vm.expectRevert("LAV: no shares outstanding");
        vault.redeemSettled(1e12);
    }

    // ==================== RESCUE ====================

    function testRescueNonAssetToken() public {
        _bindAndMint(alice, 1e12); // shares outstanding: still rescuable
        stray.mint(address(vault), 5e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Rescued(address(stray), thirdParty, 5e18);

        vm.prank(owner);
        vault.rescueERC20(address(stray), thirdParty, 5e18);

        assertEq(stray.balanceOf(thirdParty), 5e18, "rescued");
    }

    function testRescueAssetBlockedWhileSharesOutstanding() public {
        _bindAndMint(alice, 1e12);
        usdc.mint(address(vault), 1_000e6);

        vm.prank(owner);
        vm.expectRevert("LAV: asset reserved for redemptions");
        vault.rescueERC20(address(usdc), thirdParty, 1_000e6);
    }

    function testRescueAssetAllowedWhenNoSharesOutstanding() public {
        usdc.mint(address(vault), 1_000e6);

        vm.prank(owner);
        vault.rescueERC20(address(usdc), thirdParty, 1_000e6);

        assertEq(usdc.balanceOf(thirdParty), 1_000e6, "asset rescued");
    }

    function testRescueAssetAllowedAfterEveryoneExits() public {
        _settledBook();

        vm.prank(alice);
        vault.redeemSettled(1e12);
        vm.prank(bob);
        vault.redeemSettled(2e12);

        // Dust arriving after the last exit is reclaimable.
        usdc.mint(address(vault), 7);
        vm.prank(owner);
        vault.rescueERC20(address(usdc), thirdParty, 7);

        assertEq(usdc.balanceOf(thirdParty), 7, "dust rescued");
    }

    function testRescueOnlyOwner() public {
        stray.mint(address(vault), 1e18);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.rescueERC20(address(stray), thirdParty, 1e18);
    }

    function testRescueZeroRecipientReverts() public {
        stray.mint(address(vault), 1e18);

        vm.prank(owner);
        vm.expectRevert("LAV: invalid recipient");
        vault.rescueERC20(address(stray), address(0), 1e18);
    }

    /**
     * @dev The vault's OWN share token is never rescuable. The strategy custodies live shares
     *      (`requestRedeem` escrows, and the shares it pulls mid-`redeem`); paired with the
     *      strategy's `rescueToVault`, an unguarded rescue would let the owner exfiltrate every
     *      escrowed depositor claim as
     *      `strategy.rescueToVault(vault) -> vault.rescueERC20(vault, attacker)`.
     */
    function testRescueVaultSharesReverts() public {
        _bindAndMint(alice, 1_000e12);

        // Shares parked on the vault itself, exactly as a `rescueToVault(vault)` sweep would leave them.
        vm.prank(alice);
        vault.transfer(address(vault), 400e12);
        assertEq(vault.balanceOf(address(vault)), 400e12, "shares sitting on the vault");

        vm.prank(owner);
        vm.expectRevert("LAV: cannot rescue shares");
        vault.rescueERC20(address(vault), thirdParty, 400e12);

        assertEq(vault.balanceOf(thirdParty), 0, "not exfiltrated");
    }

    /// @dev The share guard is unconditional — it does NOT relax once the book is settled and the
    ///      supply is what backs the {redeemSettled} pot.
    function testRescueVaultSharesRevertsAfterSettle() public {
        _settledBook();

        vm.prank(alice);
        vault.transfer(address(vault), 1e12);

        vm.prank(owner);
        vm.expectRevert("LAV: cannot rescue shares");
        vault.rescueERC20(address(vault), thirdParty, 1e12);
    }

    /// @dev Post-settle the asset balance IS the redemption pot — the gate must still hold while a
    ///      single share is outstanding.
    function testRescueAssetBlockedPostSettleWhileSharesOutstanding() public {
        _settledBook();
        assertTrue(vault.settled(), "settled");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "pot");

        vm.prank(owner);
        vm.expectRevert("LAV: asset reserved for redemptions");
        vault.rescueERC20(address(usdc), thirdParty, 1_000e6);

        // Still blocked with only a partial exit taken.
        vm.prank(alice);
        vault.redeemSettled(1e12);

        vm.prank(owner);
        vm.expectRevert("LAV: asset reserved for redemptions");
        vault.rescueERC20(address(usdc), thirdParty, 1);
    }

    // ==================== OWNERSHIP ====================

    /// @dev Ownable2Step: the strategy's `rescueToVault` reads `Ownable(vault).owner()`, so a
    ///      nomination alone must NOT move that authority.
    function testOwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(thirdParty);
        assertEq(vault.owner(), owner, "owner unchanged until accepted");
        assertEq(vault.pendingOwner(), thirdParty, "pending owner");

        vm.prank(thirdParty);
        vault.acceptOwnership();
        assertEq(vault.owner(), thirdParty, "owner moved");
    }

    function testTransferOwnershipOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.transferOwnership(thirdParty);
    }

    /// @dev Only the NOMINEE may accept — a bystander (or the incumbent) cannot complete the handover.
    function testAcceptOwnershipOnlyPendingOwner() public {
        vm.prank(owner);
        vault.transferOwnership(thirdParty);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.acceptOwnership();

        assertEq(vault.owner(), owner, "owner unmoved");
    }

    function testAcceptOwnershipWithNoPendingNomineeReverts() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.acceptOwnership();
    }

    /// @dev A superseding nomination replaces the previous one — the stale nominee loses the claim.
    function testTransferOwnershipOverwritesPendingNominee() public {
        vm.startPrank(owner);
        vault.transferOwnership(thirdParty);
        vault.transferOwnership(alice);
        vm.stopPrank();

        assertEq(vault.pendingOwner(), alice, "latest nominee");

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.acceptOwnership();
    }

    /// @dev Renouncing is disabled: the owner is the only lifecycle driver (activate / settle) and the
    ///      strategy's rescue authority, so an ownerless vault would strand the book.
    function testRenounceOwnershipReverts() public {
        vm.prank(owner);
        vm.expectRevert("LAV: renounce disabled");
        vault.renounceOwnership();

        assertEq(vault.owner(), owner, "owner retained");
    }

    /// @dev Disabled for everyone, not just gated on the owner.
    function testRenounceOwnershipRevertsForNonOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert("LAV: renounce disabled");
        vault.renounceOwnership();
    }

    // ==================== PER-ACCOUNT SHARE CAP ====================

    /// @dev The cap defaults to 0 == UNLIMITED, so a fresh deployment is never bricked before the
    ///      owner acts. The freeze case is `setOpenDeposits(false)`, which is a separate switch.
    function testMaxSharesPerAccountDefaultsToUnlimited() public view {
        assertEq(vault.maxSharesPerAccount(), 0, "0 == unlimited on a fresh deploy");
    }

    function testSetMaxSharesPerAccountByOwner() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit LeveragedAeroVault.MaxSharesPerAccountSet(30_000e12);
        vm.prank(owner);
        vault.setMaxSharesPerAccount(30_000e12);
        assertEq(vault.maxSharesPerAccount(), 30_000e12, "cap stored");

        // Re-settable, including back to unlimited (the one-transaction rollback).
        vm.prank(owner);
        vault.setMaxSharesPerAccount(0);
        assertEq(vault.maxSharesPerAccount(), 0, "cap cleared");
    }

    function testSetMaxSharesPerAccountRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vm.prank(thirdParty);
        vault.setMaxSharesPerAccount(1);
        assertEq(vault.maxSharesPerAccount(), 0, "unchanged");
    }

    /// @dev The ops conversion: shares a given USDC amount would mint at current pricing. This is the
    ///      ONLY sanctioned way to derive the `setMaxSharesPerAccount` argument — shares are 12dp
    ///      against a 6dp asset, so hand-computing it invites an off-by-1e6.
    function testPreviewSharesForAssetsAtPar() public {
        _bind();
        // Empty book: supply 0, nav 0 -> shares = assets * 1e6, the 6-decimal step `decimals()` documents.
        assertEq(vault.previewSharesForAssets(1_000e6), 1_000e12, "par pricing on an empty book");
    }

    /// @dev The drift the design accepts: as the book earns, each dollar buys FEWER shares, so a fixed
    ///      share cap admits MORE dollars over time. Pinned here so the behaviour is a decision on
    ///      record rather than a surprise.
    function testPreviewSharesForAssetsFallsAsNavGrows() public {
        _bindAndMint(alice, 1_000e12);
        strategy.setNav(1_000e6);
        uint256 atPar = vault.previewSharesForAssets(1_000e6);

        strategy.setNav(1_200e6); // +20% NAV, supply unchanged
        uint256 afterGain = vault.previewSharesForAssets(1_000e6);

        assertLt(afterGain, atPar, "a richer book mints fewer shares per dollar");
    }

    /// @dev Fail-closed, exactly like a real deposit: the preview is a preview OF a deposit, so a
    ///      strategy that cannot price itself must not hand back a number an operator would act on.
    function testPreviewSharesForAssetsRevertsWhenNavUnpriceable() public {
        _bind();
        strategy.setNavReverts(true);
        vm.expectRevert("MockStrategy: nav unpriceable");
        vault.previewSharesForAssets(1_000e6);
    }

    function testPreviewSharesForAssetsRevertsBeforeStrategyIsBound() public {
        vm.expectRevert("LAV: strategy unset");
        vault.previewSharesForAssets(1_000e6);
    }
}

/**
 * @title MisboundStrategyStub
 * @notice A deliberately misbehaving strategy template: its `initialize` IGNORES the vault argument
 *         and it keeps reporting a foreign vault. Proves `LeveragedAeroVault._bind` guards the
 *         atomic {LeveragedAeroVault.cloneAndBind} path too, not just {setStrategy}.
 */
contract MisboundStrategyStub {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function initialize(address, address, bytes calldata) external {}
}
