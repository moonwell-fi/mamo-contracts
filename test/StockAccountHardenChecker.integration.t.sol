// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RepointStockDropChecker} from "../multisig/f-mamo/007_RepointStockDropChecker.sol";
import {HardenStockPriceChecker} from "../multisig/mamo-multisig/023_HardenStockPriceChecker.sol";

import {MamoStakingRegistryV2} from "@contracts/MamoStakingRegistryV2.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";
import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

/**
 * @title StockAccountHardenCheckerTest
 * @notice Base-fork rehearsal of multisig proposal 023, then the MOO-1164 drain replayed on a live account
 *         before and after it. Self-forks at a pinned block (no --fork-url, same op-revm reason as 021).
 */
contract StockAccountHardenCheckerTest is Test {
    /// @dev After ANTc was listed (59,618,114) on the live V2 registry
    uint256 internal constant PINNED_BLOCK = 61_320_000;

    /// @dev 7702-delegated on Base; cleared so the rehearsal can broadcast from it
    address internal constant DEPLOYER_EOA = 0xDca82E03057329f53Ed4173429D46B0511E46Fb8;
    address internal constant ANTC = 0xb20000000000000000000016e38FD364d271Ba28;
    address internal constant ANTC_POOL = 0x599C4225FE90214795a0be228D20d7680f8CED15;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    /// @dev The live v2 account the drain was simulated on in MOO-1164
    address internal constant ACCOUNT = 0x67C1887C3dfD73daaf12Df38b6cae829972b53d6;
    /// @dev Floored mean tick and zero-liquidity seconds of the ANTc window at block 59,592,800
    int24 internal constant SWEPT_TICK = -478_551;
    uint160 internal constant SWEPT_ZERO_SECONDS = 103;
    uint32 internal constant WINDOW = 180;
    uint32 internal constant BASELINE_WINDOW = 1800;
    /// @dev ANTc's 180 s mean tick at the clean block 59,591,200
    int24 internal constant CLEAN_TICK = -650;

    /// @dev MUc has the thinnest full-range floor of the listed pools (liquidityGross 2,215,419 at both ends)
    address internal constant MUC = 0xb200000000000000000000Fd2f87532B90095211;
    address internal constant MUC_POOL = 0x41e21950362B1014bC629252ecFFF8fcA5F1646C;
    uint128 internal constant MUC_FLOOR = 2_215_419;
    /// @dev The pool's and the account's real MUc balances at the pin; the etched stand-in starts empty
    uint256 internal constant POOL_MUC = 54_747_726_025;
    uint256 internal constant ACCOUNT_MUC = 1_288_338_950;

    HardenStockPriceChecker internal proposal;
    Addresses internal addresses;
    StockAccountRegistry internal registry;
    IERC20 internal usdc;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        vm.etch(DEPLOYER_EOA, "");
        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));
        addresses.changeAddress("DEPLOYER_EOA", makeAddr("hardenCheckerDeployer"), false);

        registry = StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY"));
        usdc = IERC20(addresses.getAddress("USDC"));
        proposal = new HardenStockPriceChecker();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
        proposal.deploy();
        proposal.preBuildMock();
    }

    function test_hardenStockPriceChecker() public {
        address checker = addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER");

        proposal.build();
        proposal.simulate();
        proposal.validate();

        (address[] memory targets, uint256[] memory values, bytes[] memory args) = proposal.getProposalActions();
        assertEq(targets.length, 1, "one action");
        assertEq(targets[0], address(registry), "target");
        assertEq(values[0], 0, "no ETH");
        assertEq(args[0], abi.encodeWithSignature("setPriceChecker(address)", checker), "calldata");
    }

    /// @notice f-mamo/007 after 023: each of the 12 stock-drop routes moves its stock hop onto the hardened checker
    function test_repointStockDropChecker() public {
        address old = addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER_PRE_023");
        address checker = addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER");
        proposal.build();
        proposal.simulate();
        proposal.validate();

        RepointStockDropChecker repoint = new RepointStockDropChecker();
        repoint.setPrimaryForkId(vm.activeFork());
        repoint.setAddresses(addresses);
        repoint.deploy();
        repoint.preBuildMock();
        repoint.build();

        MamoStakingRegistryV2 staking = MamoStakingRegistryV2(addresses.getAddress("MAMO_STAKING_REGISTRY_V2"));
        (address[] memory targets, uint256[] memory values, bytes[] memory args) = repoint.getProposalActions();
        assertEq(targets.length, 12, "one setRoute per stock");
        for (uint256 i = 0; i < targets.length; i++) {
            assertEq(targets[i], address(staking), "target");
            assertEq(values[i], 0, "no ETH");
            assertEq(bytes4(args[i]), MamoStakingRegistryV2.setRoute.selector, "selector");
        }

        repoint.simulate();
        repoint.validate();

        MamoStakingRegistryV2.Hop[] memory route = staking.getRoute(MUC);
        assertEq(route[0].pool, MUC_POOL, "MUc hop pool");
        assertEq(address(route[0].checker), checker, "MUc hop on the hardened checker");
        MamoStakingRegistryV2.RewardToken[] memory tokens = staking.getRewardTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            route = staking.getRoute(tokens[i].token);
            for (uint256 j = 0; j < route.length; j++) {
                assertTrue(address(route[j].checker) != old, "no hop left on the pre-023 checker");
            }
        }
    }

    /// @notice A dust ANTc balance in the swept window drains the account under the live checker, and moves
    ///         nothing once 023 has executed.
    function test_sweptAntcWindow_drainsBeforeAndNothingAfter() public {
        MockERC20Decimals(ANTC).mint(ACCOUNT, 1);
        MockERC20Decimals(NVDAC).mint(ACCOUNT, 10e8);
        deal(address(usdc), ACCOUNT, 1_000e6);

        address feeRecipient = registry.feeRecipient();
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        uint256 snap = vm.snapshotState();

        _mockSweptWindow();
        IStockAccountStrategy(ACCOUNT).payFeesFromAny();
        assertEq(usdc.balanceOf(ACCOUNT), 0, "live checker: all USDC taken");
        assertEq(IERC20(NVDAC).balanceOf(ACCOUNT), 0, "live checker: every held stock taken");
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore + 1_000e6, "live checker: USDC sent as fee");

        vm.revertToState(snap);
        vm.clearMockedCalls();
        // setPriceChecker re-probes every listed token, so 023 executes in a clean window
        proposal.build();
        proposal.simulate();
        _mockSweptWindow();

        ISlippagePriceChecker checker = registry.priceChecker();
        vm.expectRevert(
            abi.encodeWithSelector(StockAccountPriceChecker.ZeroLiquidityInWindow.selector, ANTC_POOL, WINDOW)
        );
        checker.getExpectedOut(1e8, ANTC, address(usdc));

        IStockAccountStrategy(ACCOUNT).payFeesFromAny();
        assertEq(usdc.balanceOf(ACCOUNT), 1_000e6, "hardened: USDC untouched");
        assertEq(IERC20(NVDAC).balanceOf(ACCOUNT), 10e8, "hardened: stocks untouched");
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore, "hardened: no fee while the valuation is partial");
    }

    /// @dev `observe` answers as the ANTc pool did at block 59,592,800, for the live checker's `[180, 0]` and the
    ///      hardened one's `[1980, 180, 0]` (a clean baseline before the swept window)
    function _mockSweptWindow() internal {
        uint32[] memory live = new uint32[](2);
        live[0] = WINDOW;
        int56[] memory cum = new int56[](2);
        cum[1] = int56(SWEPT_TICK) * int56(uint56(WINDOW));
        uint160[] memory spl = new uint160[](2);
        spl[1] = SWEPT_ZERO_SECONDS << 128;
        vm.mockCall(ANTC_POOL, abi.encodeCall(ICLPool.observe, (live)), abi.encode(cum, spl));

        uint32[] memory hardened = new uint32[](3);
        hardened[0] = WINDOW + BASELINE_WINDOW;
        hardened[1] = WINDOW;
        int56[] memory cum3 = new int56[](3);
        cum3[1] = int56(CLEAN_TICK) * int56(uint56(BASELINE_WINDOW));
        cum3[2] = cum3[1] + int56(SWEPT_TICK) * int56(uint56(WINDOW));
        uint160[] memory spl3 = new uint160[](3);
        spl3[2] = SWEPT_ZERO_SECONDS << 128;
        vm.mockCall(ANTC_POOL, abi.encodeCall(ICLPool.observe, (hardened)), abi.encode(cum3, spl3));
    }

    // ==================== a pool with a full-range floor (every listed pool today) ====================

    function uniswapV3SwapCallback(int256 usdcIn, int256, bytes calldata) external {
        if (usdcIn > 0) usdc.transfer(msg.sender, uint256(usdcIn));
    }

    function _buyMuc(uint256 maxUsdc, int24 limitTick) internal {
        ICLPoolSwap(MUC_POOL).swap(address(this), true, int256(maxUsdc), TickMath.getSqrtRatioAtTick(limitTick), "");
    }

    /// @dev Buys out the concentrated range so only the full-range floor is left, as ANTc was on 2026-11-19
    function _sellOutMainRange() internal returns (int24 edge) {
        MockERC20Decimals(MUC).mint(MUC_POOL, POOL_MUC);
        deal(address(usdc), address(this), 10_000_000e6);
        (, int24 tick,,,,) = ICLPool(MUC_POOL).slot0();
        while (ICLPool(MUC_POOL).liquidity() != MUC_FLOOR) {
            tick -= 500;
            _buyMuc(50_000_000e6, tick);
        }
        (, edge,,,,) = ICLPool(MUC_POOL).slot0();
    }

    /// @notice Liquidity never reads zero on a floored pool; pushed along the floor and rested a window, the live
    ///         checker prices MUc ~23,000x and the fee takes the account. 023's checker refuses the same window.
    function test_floorPool_pushedWindow_drainsBeforeAndIsRefusedAfter() public {
        MockERC20Decimals(MUC).mint(ACCOUNT, ACCOUNT_MUC);
        MockERC20Decimals(NVDAC).mint(ACCOUNT, 10e8);
        deal(address(usdc), ACCOUNT, 1_000e6);
        address feeRecipient = registry.feeRecipient();
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        uint256 snap = vm.snapshotState();

        _buyMuc(50_000_000e6, _sellOutMainRange() - 90_000);
        vm.warp(block.timestamp + WINDOW);
        IStockAccountStrategy(ACCOUNT).payFeesFromAny();
        assertEq(usdc.balanceOf(ACCOUNT), 0, "live checker: all USDC taken");

        vm.revertToState(snap);
        proposal.build();
        proposal.simulate();
        ISlippagePriceChecker checker = registry.priceChecker();

        _buyMuc(50_000_000e6, _sellOutMainRange() - 90_000);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockAccountPriceChecker.TwapDeviatesFromBaseline.selector, MUC_POOL, int24(-120_074), int24(-19_574)
            )
        );
        checker.getExpectedOut(1e8, MUC, address(usdc));

        IStockAccountStrategy(ACCOUNT).payFeesFromAny();
        assertEq(usdc.balanceOf(ACCOUNT), 1_000e6, "hardened: USDC untouched");
        assertEq(IERC20(NVDAC).balanceOf(ACCOUNT), 10e8, "hardened: stocks untouched");
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore, "hardened: no fee while the valuation is partial");
    }

    /// @notice The organic 11-19 pattern on a floored pool: a stray 120 USDC buy after the range sold out. Two
    ///         seconds of it stay inside the bound; by 23 s (the day's longest gap) it is refused.
    function test_floorPool_strayBuy_refusedWithinTheDaysLongestGap() public {
        proposal.build();
        proposal.simulate();
        ISlippagePriceChecker checker = registry.priceChecker();
        uint256 clean = checker.getExpectedOut(1e8, MUC, address(usdc));

        _sellOutMainRange();
        _buyMuc(120e6, -887_000);
        uint256 t0 = block.timestamp;

        vm.warp(t0 + 2);
        assertLt(checker.getExpectedOut(1e8, MUC, address(usdc)), (clean * 110) / 100, "2 s: within 10%");

        vm.warp(t0 + 23);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockAccountPriceChecker.TwapDeviatesFromBaseline.selector, MUC_POOL, int24(-28_169), int24(-19_567)
            )
        );
        checker.getExpectedOut(1e8, MUC, address(usdc));
    }
}

interface ICLPoolSwap {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256, int256);
}
