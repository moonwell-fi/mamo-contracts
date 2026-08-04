// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console} from "@forge-std/Test.sol";

import {MamoVaultConfig} from "@contracts/robinhood/MamoVaultConfig.sol";
import {MorphoVaultsStrategy} from "@contracts/robinhood/MorphoVaultsStrategy.sol";

import {MockMerkleDistributor, MockSlippagePriceChecker, MockStrategyRegistry} from "./mocks/RobinhoodMocks.sol";
import {IMorphoVaultV2} from "./vendor/IMorphoVaultV2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title RobinhoodForkIntegrationTest
 * @notice The real fork suite for the Robinhood Chain MVP: verifies the spec's on-chain ground truths
 *         and runs `MorphoVaultsStrategy` end to end against the REAL Steakhouse USDG Vault V2.
 *
 * @dev WHY THIS IS ENV-GATED
 *      Every test here needs an RPC connection to Robinhood Chain (chain ID 4663). The sandboxed
 *      environment this suite was authored in has an egress policy that 403s all chain RPC endpoints,
 *      so the suite cannot run there and would otherwise fail CI for an environmental reason. It
 *      therefore skips itself unless an RPC is available, and lights up untouched the moment one is —
 *      locally, in a CI job with the secret set, or once the sandbox allowlists
 *      `rpc.mainnet.chain.robinhood.com`.
 *
 *      HOW TO RUN
 *          export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
 *          forge test --match-path "test/RobinhoodFork.integration.t.sol" -vv
 *
 *      It also picks up an already-active fork, so this works too:
 *          forge test --fork-url https://rpc.mainnet.chain.robinhood.com \
 *              --match-path "test/RobinhoodFork.integration.t.sol" -vv
 *
 *      Optional: `ROBINHOOD_USDG_WHALE` — a USDG holder to source test funds from, used only if
 *      `deal()` cannot rewrite Paxos' balance storage.
 *
 *      WHAT IT VERIFIES
 *      1. `docs/ROBINHOOD_CHAIN_SPEC.md` §6 checklist items 1 and 2, which were sourced from SDKs and
 *         documentation rather than the chain: USDG's decimals, the Steakhouse vault's ERC-4626
 *         surface and Vault V2 identity (`max*` views returning zero), its gate configuration, and
 *         that the Uniswap SwapRouter02 address holds code.
 *      2. The go/no-go: whether a third-party contract - a Mamo per-user strategy - can actually take
 *         shares of the Earn vault, or whether `receiveSharesGate` locks it out.
 *      3. A full deposit -> getTotalBalance -> withdraw -> withdrawAll cycle against the live vault,
 *         which is the only way to observe real liquidity behaviour: these vaults route through an
 *         adapter into Morpho Blue markets, so an exit can be constrained in ways no local deployment
 *         reproduces. `test/MorphoVaultsStrategyVaultV2.integration.t.sol` covers everything else
 *         against real Vault V2 bytecode without needing an RPC.
 */
contract RobinhoodForkIntegrationTest is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    /// @dev Paxos-issued Global Dollar, the chain's dominant stablecoin (spec §1, 6 decimals, no permit)
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev The Steakhouse USDG vault behind Robinhood Earn (spec §1, Morpho Vaults V2)
    address internal constant STEAKHOUSE_USDG_VAULT = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;

    /// @dev Uniswap SwapRouter02, the CoW replacement for reward compounding (spec §1)
    address internal constant UNISWAP_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    uint256 public constant SUPPLY_CAP = 1_000_000e6;
    uint256 public constant STRATEGY_TYPE_ID = 1;
    uint256 public constant DEPOSIT_AMOUNT = 100e6; // 100 USDG, small enough not to move the vault

    address public admin = makeAddr("adminMultisig");
    address public backend = makeAddr("backend");
    address public user = makeAddr("user");
    address public feeRecipient = makeAddr("feeRecipient");

    bool public forkEnabled;

    MockStrategyRegistry public registry;
    MockSlippagePriceChecker public priceChecker;
    MockMerkleDistributor public distributor;
    MamoVaultConfig public config;
    MorphoVaultsStrategy public strategy;

    /// @dev Skips the body (marking the test skipped) when no Robinhood Chain RPC is reachable.
    modifier onlyFork() {
        if (!forkEnabled) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));

        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
            forkEnabled = true;
        } else if (block.chainid == ROBINHOOD_CHAIN_ID) {
            // already forked via --fork-url
            forkEnabled = true;
        } else {
            console.log("RobinhoodFork: ROBINHOOD_RPC_URL not set and no 4663 fork active - skipping suite");
            return;
        }

        assertEq(block.chainid, ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (expected chain id 4663)");

        registry = new MockStrategyRegistry(backend);
        priceChecker = new MockSlippagePriceChecker();
        distributor = new MockMerkleDistributor();

        config = new MamoVaultConfig(USDG, address(registry), admin, SUPPLY_CAP);

        vm.prank(admin);
        config.addVault(STEAKHOUSE_USDG_VAULT);

        strategy = MorphoVaultsStrategy(payable(_deployStrategy(user)));
        registry.setUserStrategy(user, address(strategy), true);
    }

    // ==================== SPEC GROUND TRUTHS ====================

    /// @notice Spec §1: USDG is 6 decimals. Every amount in the port depends on this.
    function testForkUsdgIsSixDecimals() public onlyFork {
        assertGt(USDG.code.length, 0, "USDG has no code at the documented address");
        assertEq(IERC20Metadata(USDG).decimals(), 6, "USDG decimals should be 6");

        console.log("USDG symbol:      %s", IERC20Metadata(USDG).symbol());
        console.log("USDG decimals:    %s", vm.toString(IERC20Metadata(USDG).decimals()));
        console.log("USDG totalSupply: %s", vm.toString(IERC20(USDG).totalSupply()));

        // spec §1 also claims no EIP-2612 permit; report rather than assert
        (bool hasPermit,) = _tryStaticCall(USDG, abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        console.log("USDG exposes DOMAIN_SEPARATOR (EIP-2612):", hasPermit);
    }

    /// @notice Spec §1: the Steakhouse Earn vault is an ERC-4626 on USDG.
    function testForkSteakhouseVaultIsErc4626OnUsdg() public onlyFork {
        assertGt(STEAKHOUSE_USDG_VAULT.code.length, 0, "Steakhouse vault has no code at the documented address");

        IMorphoVaultV2 vault = IMorphoVaultV2(STEAKHOUSE_USDG_VAULT);
        assertEq(vault.asset(), USDG, "Steakhouse vault asset should be USDG");

        console.log("Vault name:        %s", vault.name());
        console.log("Vault symbol:      %s", vault.symbol());
        console.log("Vault decimals:    %s", vm.toString(vault.decimals()));
        console.log("Vault totalAssets: %s", vm.toString(vault.totalAssets()));
        console.log("Vault totalSupply: %s", vm.toString(vault.totalSupply()));
    }

    /// @notice Spec §1: Vault V2 hardcodes every max* view to zero. This is the single behaviour that
    ///         forced `MorphoVaultsStrategy` to derive liquidity from `convertToAssets(balanceOf)`.
    function testForkSteakhouseVaultHasVaultV2MaxSemantics() public onlyFork {
        IMorphoVaultV2 vault = IMorphoVaultV2(STEAKHOUSE_USDG_VAULT);

        assertEq(vault.maxDeposit(address(strategy)), 0, "maxDeposit should be 0 (Vault V2 semantics)");
        assertEq(vault.maxWithdraw(address(strategy)), 0, "maxWithdraw should be 0 (Vault V2 semantics)");
        assertEq(vault.maxMint(address(strategy)), 0, "maxMint should be 0 (Vault V2 semantics)");
        assertEq(vault.maxRedeem(address(strategy)), 0, "maxRedeem should be 0 (Vault V2 semantics)");

        // 18 - assetDecimals decimal offset is the other V2 tell
        assertEq(vault.virtualShares(), 1e12, "virtualShares should be 10 ** (18 - 6)");
    }

    /// @notice Spec §6 item 1, the read that can reshape the whole chassis: are the vault's gates set?
    function testForkSteakhouseVaultGateConfiguration() public onlyFork {
        _reportGates(STEAKHOUSE_USDG_VAULT);

        (bool ok, address receiveSharesGate) = _tryReadAddress(STEAKHOUSE_USDG_VAULT, "receiveSharesGate()");
        assertTrue(ok, "vault does not expose receiveSharesGate() - not a Vault V2?");

        if (receiveSharesGate == address(0)) {
            console.log("GO: no receive-shares gate, any contract can hold shares of this vault");
        } else {
            (bool canOk, bytes memory ret) = _tryStaticCall(
                STEAKHOUSE_USDG_VAULT, abi.encodeWithSignature("canReceiveShares(address)", address(strategy))
            );
            bool allowed = canOk && ret.length == 32 && abi.decode(ret, (bool));
            console.log("NO-GO RISK: receive-shares gate is set; strategy currently allowed:", allowed);
        }
    }

    /// @notice Spec §1: Uniswap SwapRouter02 is the compounding venue (no CoW Protocol on this chain).
    function testForkUniswapSwapRouterHasCode() public onlyFork {
        assertGt(UNISWAP_SWAP_ROUTER_02.code.length, 0, "SwapRouter02 has no code at the documented address");
        console.log("SwapRouter02 code size: %s", vm.toString(UNISWAP_SWAP_ROUTER_02.code.length));
    }

    // ==================== END TO END AGAINST THE LIVE VAULT ====================

    /// @notice Full MVP cycle against the real Steakhouse vault: deposit, read the balance back,
    ///         withdraw part of it, then exit completely.
    function testForkDepositGetBalanceWithdrawEndToEnd() public onlyFork {
        if (!_fundUser(DEPOSIT_AMOUNT)) {
            console.log("Could not source USDG for the test user - set ROBINHOOD_USDG_WHALE and rerun");
            vm.skip(true);
            return;
        }

        vm.prank(user);
        IERC20(USDG).approve(address(strategy), type(uint256).max);

        if (_strategyIsGatedOut()) {
            console.log("GO/NO-GO FAILED: the Steakhouse vault's receive-shares gate blocks this strategy.");
            console.log("The chassis needs whitelisted strategy addresses or different target vaults.");
            vm.prank(user);
            vm.expectRevert();
            strategy.deposit(DEPOSIT_AMOUNT);
            return;
        }

        // --- deposit ---
        vm.prank(user);
        strategy.deposit(DEPOSIT_AMOUNT);

        uint256 totalAfterDeposit = strategy.getTotalBalance();
        console.log("getTotalBalance after deposit: %s", vm.toString(totalAfterDeposit));

        // Vault V2 rounds share issuance down; a couple of wei of drift is expected, not a loss
        assertApproxEqAbs(totalAfterDeposit, DEPOSIT_AMOUNT, 2, "balance should track the deposit");
        assertEq(config.totalDeposited(), DEPOSIT_AMOUNT, "principal metered against the supply cap");
        assertGt(
            IERC20(STEAKHOUSE_USDG_VAULT).balanceOf(address(strategy)), 0, "strategy should hold real vault shares"
        );

        // --- partial withdraw ---
        uint256 half = DEPOSIT_AMOUNT / 2;
        uint256 balanceBefore = IERC20(USDG).balanceOf(user);

        vm.prank(user);
        strategy.withdraw(half);

        assertEq(IERC20(USDG).balanceOf(user) - balanceBefore, half, "partial withdrawal should pay out in full");
        assertApproxEqAbs(strategy.getTotalBalance(), DEPOSIT_AMOUNT - half, 2, "remainder still invested");

        // --- full exit ---
        uint256 remaining = strategy.getTotalBalance();
        balanceBefore = IERC20(USDG).balanceOf(user);

        vm.prank(user);
        strategy.withdrawAll();

        assertApproxEqAbs(
            IERC20(USDG).balanceOf(user) - balanceBefore, remaining, 2, "full exit should return the remainder"
        );
        assertEq(strategy.getTotalBalance(), 0, "position fully closed");
        assertEq(config.totalDeposited(), 0, "supply cap capacity freed");
    }

    /// @notice The strategy must never rely on the max* views; this asserts the live vault would in
    ///         fact report a funded position as having zero withdrawable assets.
    function testForkFundedPositionStillReportsZeroMaxWithdraw() public onlyFork {
        if (!_fundUser(DEPOSIT_AMOUNT) || _strategyIsGatedOut()) {
            vm.skip(true);
            return;
        }

        vm.startPrank(user);
        IERC20(USDG).approve(address(strategy), type(uint256).max);
        strategy.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        IMorphoVaultV2 vault = IMorphoVaultV2(STEAKHOUSE_USDG_VAULT);
        assertEq(vault.maxWithdraw(address(strategy)), 0, "funded position still reports maxWithdraw == 0");
        assertGt(
            vault.convertToAssets(vault.balanceOf(address(strategy))),
            0,
            "convertToAssets(balanceOf) is the only usable liquidity signal"
        );
    }

    // ==================== HELPERS ====================

    function _deployStrategy(address owner) internal returns (address) {
        address[] memory vaults = new address[](1);
        vaults[0] = STEAKHOUSE_USDG_VAULT;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        MorphoVaultsStrategy.InitParams memory params = MorphoVaultsStrategy.InitParams({
            mamoStrategyRegistry: address(registry),
            token: USDG,
            vaultConfig: address(config),
            slippagePriceChecker: address(priceChecker),
            dexRouter: UNISWAP_SWAP_ROUTER_02,
            merkleDistributor: address(distributor),
            feeRecipient: feeRecipient,
            strategyTypeId: STRATEGY_TYPE_ID,
            owner: owner,
            allowedSlippageInBps: 100,
            compoundFee: 500,
            vaults: vaults,
            weightsBps: weights
        });

        MorphoVaultsStrategy implementation = new MorphoVaultsStrategy();
        return address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(MorphoVaultsStrategy.initialize, (params)))
        );
    }

    /// @dev USDG is a Paxos-issued upgradeable token, so `deal`'s storage probe can miss. Falls back to
    ///      transferring from a holder supplied via `ROBINHOOD_USDG_WHALE`.
    function _fundUser(uint256 amount) internal returns (bool) {
        try this.dealExternal(USDG, user, amount) {
            if (IERC20(USDG).balanceOf(user) >= amount) return true;
        } catch {
            console.log("deal() could not rewrite USDG balance storage; trying ROBINHOOD_USDG_WHALE");
        }

        address whale = vm.envOr("ROBINHOOD_USDG_WHALE", address(0));
        if (whale != address(0) && IERC20(USDG).balanceOf(whale) >= amount) {
            vm.prank(whale);
            IERC20(USDG).transfer(user, amount);
            return IERC20(USDG).balanceOf(user) >= amount;
        }

        return false;
    }

    /// @dev `deal` is internal to StdCheats; this wrapper makes it try/catch-able.
    function dealExternal(address token, address to, uint256 give) external {
        deal(token, to, give);
    }

    function _strategyIsGatedOut() internal view returns (bool) {
        (bool ok, bytes memory ret) = _tryStaticCall(
            STEAKHOUSE_USDG_VAULT, abi.encodeWithSignature("canReceiveShares(address)", address(strategy))
        );
        if (!ok || ret.length != 32) return false;
        return !abi.decode(ret, (bool));
    }

    function _reportGates(address vault) internal view {
        string[4] memory getters =
            ["receiveSharesGate()", "sendSharesGate()", "receiveAssetsGate()", "sendAssetsGate()"];

        for (uint256 i = 0; i < getters.length; i++) {
            (bool ok, address gate) = _tryReadAddress(vault, getters[i]);
            if (ok) {
                console.log("%s %s", getters[i], vm.toString(gate));
            } else {
                console.log("%s not exposed", getters[i]);
            }
        }
    }

    function _tryReadAddress(address target, string memory signature) internal view returns (bool, address) {
        (bool ok, bytes memory ret) = _tryStaticCall(target, abi.encodeWithSignature(signature));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }

    function _tryStaticCall(address target, bytes memory data) internal view returns (bool, bytes memory) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        return (ok, ret);
    }
}
