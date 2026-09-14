// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/// @notice Live NVDAc/USDC Aerodrome Slipstream pool on a PINNED Base fork. Self-forks in setUp
///         (no --fork-url on the CLI, see the lp-auto-balancer-v2 Makefile note).
contract StockAccountPriceCheckerIntegrationTest is Test {
    uint256 internal constant PINNED_BLOCK = 51_181_271;
    uint32 internal constant WINDOW = 180;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C; // 8 dec, pool token1
    address internal constant NVDAC_USDC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9; // tick spacing 10
    address internal constant AERODROME_CL_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;

    address internal admin = makeAddr("admin");
    StockAccountRegistry internal registry;
    StockAccountPriceChecker internal checker;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);
        // B20 tokens are node-native on Base (on-chain code is the single byte 0xef); revm cannot
        // execute them, so stand in an 8-decimal ERC20 for the only call the checker makes (decimals()).
        vm.etch(NVDAC, address(new MockERC20Decimals("NVDAc", 8)).code);
        assertEq(MockERC20Decimals(NVDAC).decimals(), 8);

        // The checker takes the registry as an immutable, so the registry is built first against a
        // code-bearing stand-in (this test contract) and repointed once the real checker exists.
        registry = new StockAccountRegistry(
            StockAccountRegistry.Config({
                admin: admin,
                aerodromeRouter: ISwapRouter(AERODROME_CL_ROUTER),
                guardian: admin,
                maxBackendSlippageBps: 100,
                maxDeviationBps: 1000,
                maxPositions: 10,
                maxStrategyDeposit: 25_000e6,
                maxWithdrawSlippageBps: 500,
                minStrategyDeposit: 100e6,
                minTargetBps: 100,
                priceChecker: ISlippagePriceChecker(address(this)),
                requiredAppDataHash: bytes32(0),
                twapWindow: WINDOW
            })
        );
        checker = new StockAccountPriceChecker(registry, USDC);
        vm.prank(admin);
        registry.setPriceChecker(checker);
        assertEq(address(registry.priceChecker()), address(checker));

        vm.prank(admin);
        registry.listToken(
            NVDAC,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: NVDAC_USDC_POOL,
                chainlinkFeed: address(0)
            })
        );
    }

    /// @dev USDC raw per 1 NVDAc from the pool's current sqrt price (token1 -> token0).
    function _spotUsdcPerNvdac() internal view returns (uint256) {
        (uint160 sqrtP,,,,,) = ICLPool(NVDAC_USDC_POOL).slot0();
        uint256 ratioX192 = uint256(sqrtP) * sqrtP;
        return Math.mulDiv(1 << 192, 1e8, ratioX192);
    }

    function test_fork_referenceTracksLiveSpot() public view {
        uint256 twapOut = checker.getExpectedOut(1e8, NVDAC, USDC);
        uint256 spot = _spotUsdcPerNvdac();
        assertGt(twapOut, 0, "vacuous: zero quote");
        assertGt(spot, 100e6, "vacuous: spot below $100");
        assertApproxEqRel(twapOut, spot, 0.05e18, "twap vs spot > 5%");
    }

    function test_fork_bothDirectionsRoundTrip() public view {
        uint256 usdcOut = checker.getExpectedOut(10e8, NVDAC, USDC);
        uint256 back = checker.getExpectedOut(usdcOut, USDC, NVDAC);
        assertGt(usdcOut, 1_000e6);
        assertApproxEqAbs(back, 10e8, 10);
    }

    function test_fork_checkPriceAcceptsFairAndRejectsBelowTolerance() public view {
        uint256 amountIn = 3e8;
        uint256 expected = checker.getExpectedOut(amountIn, NVDAC, USDC);
        uint256 floor = (expected * 9_900) / 10_000;
        assertTrue(checker.checkPrice(amountIn, NVDAC, USDC, floor, 100));
        assertFalse(checker.checkPrice(amountIn, NVDAC, USDC, floor - 1, 100));
    }

    function test_fork_windowLongerThanHistoryReverts() public {
        vm.prank(admin);
        registry.setTwapWindow(type(uint32).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                StockAccountPriceChecker.InsufficientObservations.selector, NVDAC_USDC_POOL, type(uint32).max
            )
        );
        checker.getExpectedOut(1e8, NVDAC, USDC);
    }
}
