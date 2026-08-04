// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {StockBasketStrategy} from "@contracts/robinhood/StockBasketStrategy.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockERC4626, MockSlippagePriceChecker, MockStrategyRegistry, MockSwapRouter} from "./mocks/RobinhoodMocks.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StockBasketStrategyUnitTest is Test {
    uint256 public constant STRATEGY_TYPE_ID = 2;
    uint256 public constant SLIPPAGE_BPS = 100; // 1%
    uint256 public constant MAX_STOCK_BPS = 7000; // equity exposure mandate: max 70%
    uint24 public constant POOL_FEE = 3000;

    address public backend = makeAddr("backend");
    address public user = makeAddr("user");

    MockERC20 public usdg;
    MockERC20 public nvda;
    MockERC20 public aapl;
    MockERC4626 public sleeve;
    MockStrategyRegistry public registry;
    MockSlippagePriceChecker public priceChecker;
    MockSwapRouter public router;
    StockBasketStrategy public strategy;

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG");
        nvda = new MockERC20("NVIDIA Stock Token", "NVDAt");
        aapl = new MockERC20("Apple Stock Token", "AAPLt");

        sleeve = new MockERC4626(IERC20(address(usdg)), "USDG Sleeve", "sUSDG");
        registry = new MockStrategyRegistry(backend);
        priceChecker = new MockSlippagePriceChecker();
        router = new MockSwapRouter();

        // oracle: NVDA = 180 USDG, AAPL = 220 USDG; router executes at oracle parity by default
        _setPrice(address(nvda), 180e18);
        _setPrice(address(aapl), 220e18);

        strategy = StockBasketStrategy(payable(_deployStrategy(user)));

        usdg.mint(user, 1_000_000e18);
        vm.prank(user);
        usdg.approve(address(strategy), type(uint256).max);
    }

    function _setPrice(address stock, uint256 usdgPerToken) internal {
        priceChecker.setRate(stock, address(usdg), usdgPerToken);
        priceChecker.setRate(address(usdg), stock, 1e36 / usdgPerToken);
        router.setExecRate(stock, address(usdg), usdgPerToken);
        router.setExecRate(address(usdg), stock, 1e36 / usdgPerToken);
    }

    function _initParams(address owner) internal view returns (StockBasketStrategy.InitParams memory params) {
        address[] memory stocks = new address[](2);
        stocks[0] = address(nvda);
        stocks[1] = address(aapl);
        // 30% NVDA, 20% AAPL, implied 50% yield sleeve
        uint256[] memory weights = new uint256[](2);
        weights[0] = 3000;
        weights[1] = 2000;

        params = StockBasketStrategy.InitParams({
            mamoStrategyRegistry: address(registry),
            token: address(usdg),
            yieldVault: address(sleeve),
            slippagePriceChecker: address(priceChecker),
            dexRouter: address(router),
            strategyTypeId: STRATEGY_TYPE_ID,
            owner: owner,
            allowedSlippageInBps: SLIPPAGE_BPS,
            maxTotalStockBps: MAX_STOCK_BPS,
            poolFee: POOL_FEE,
            stockTokens: stocks,
            stockWeightsBps: weights
        });
    }

    function _deployStrategy(address owner) internal returns (address) {
        StockBasketStrategy implementation = new StockBasketStrategy();
        bytes memory initData = abi.encodeCall(StockBasketStrategy.initialize, (_initParams(owner)));
        return address(new ERC1967Proxy(address(implementation), initData));
    }

    // ==================== INITIALIZATION ====================

    function testInitializeSetsState() public view {
        assertEq(address(strategy.token()), address(usdg));
        assertEq(address(strategy.yieldVault()), address(sleeve));
        assertEq(strategy.owner(), user);
        assertEq(strategy.maxTotalStockBps(), MAX_STOCK_BPS);

        (address[] memory stocks, uint256[] memory weights) = strategy.getBasket();
        assertEq(stocks.length, 2);
        assertEq(stocks[0], address(nvda));
        assertEq(weights[0], 3000);
        assertEq(weights[1], 2000);
    }

    function testInitializeRevertsWhenWeightsExceedMandate() public {
        StockBasketStrategy implementation = new StockBasketStrategy();
        StockBasketStrategy.InitParams memory params = _initParams(user);
        params.stockWeightsBps[0] = 6000; // 6000 + 2000 > 7000 mandate

        vm.expectRevert("Stock allocation exceeds mandate");
        new ERC1967Proxy(address(implementation), abi.encodeCall(StockBasketStrategy.initialize, (params)));
    }

    // ==================== DEPOSIT & REBALANCE ====================

    function testDepositLandsInYieldSleeve() public {
        vm.prank(user);
        strategy.deposit(10_000e18);

        assertApproxEqAbs(sleeve.convertToAssets(sleeve.balanceOf(address(strategy))), 10_000e18, 1);
        assertEq(nvda.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(strategy.getTotalBalance(), 10_000e18, 1);
    }

    function testRebalanceBuysBasketToTargets() public {
        vm.prank(user);
        strategy.deposit(10_000e18);

        vm.prank(backend);
        strategy.rebalance(1e18);

        // 30% NVDA @ 180 → ~16.67 NVDA, 20% AAPL @ 220 → ~9.09 AAPL, 50% stays earning
        assertApproxEqRel(nvda.balanceOf(address(strategy)), uint256(3000e18) / 180, 0.01e18);
        assertApproxEqRel(aapl.balanceOf(address(strategy)), uint256(2000e18) / 220, 0.01e18);
        assertApproxEqRel(sleeve.convertToAssets(sleeve.balanceOf(address(strategy))), 5000e18, 0.01e18);
        // NAV preserved through the trades (router executes at oracle parity)
        assertApproxEqRel(strategy.getTotalBalance(), 10_000e18, 0.001e18);
    }

    function testRebalanceSellsWinnerAfterPriceMove() public {
        vm.prank(user);
        strategy.deposit(10_000e18);
        vm.prank(backend);
        strategy.rebalance(1e18);

        // NVDA doubles: basket is now overweight NVDA
        _setPrice(address(nvda), 360e18);

        uint256 navAfterMove = strategy.getTotalBalance();
        assertApproxEqRel(navAfterMove, 13_000e18, 0.01e18); // 3000 NVDA value doubled

        uint256 nvdaBefore = nvda.balanceOf(address(strategy));

        vm.prank(backend);
        strategy.rebalance(1e18);

        // rebalance trims NVDA back toward 30% of the (larger) NAV
        uint256 nvdaAfter = nvda.balanceOf(address(strategy));
        assertLt(nvdaAfter, nvdaBefore);

        uint256 nvdaValue = priceChecker.getExpectedOut(nvdaAfter, address(nvda), address(usdg));
        assertApproxEqRel(nvdaValue, (navAfterMove * 3000) / 10000, 0.02e18);
    }

    function testSetStockWeightsRespectsMandate() public {
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 5000;
        newWeights[1] = 2500;

        vm.prank(backend);
        vm.expectRevert("Stock allocation exceeds mandate");
        strategy.setStockWeights(newWeights);

        newWeights[0] = 4000;
        newWeights[1] = 3000;
        vm.prank(backend);
        strategy.setStockWeights(newWeights);

        (, uint256[] memory weights) = strategy.getBasket();
        assertEq(weights[0], 4000);
    }

    function testSetStockWeightsOnlyBackend() public {
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 1000;
        newWeights[1] = 1000;

        vm.prank(user);
        vm.expectRevert("Not backend");
        strategy.setStockWeights(newWeights);
    }

    function testRebalanceOnlyBackend() public {
        vm.prank(user);
        vm.expectRevert("Not backend");
        strategy.rebalance(1e18);
    }

    // ==================== WITHDRAWALS ====================

    function testWithdrawFromSleeveOnlyWhenSufficient() public {
        vm.prank(user);
        strategy.deposit(10_000e18);
        vm.prank(backend);
        strategy.rebalance(1e18);

        uint256 nvdaBefore = nvda.balanceOf(address(strategy));
        uint256 balanceBefore = usdg.balanceOf(user);

        // 3000 < ~5000 sleeve: no stock should be touched
        vm.prank(user);
        strategy.withdraw(3000e18);

        assertEq(usdg.balanceOf(user) - balanceBefore, 3000e18);
        assertEq(nvda.balanceOf(address(strategy)), nvdaBefore);
    }

    function testWithdrawSellsStocksWhenSleeveInsufficient() public {
        vm.prank(user);
        strategy.deposit(10_000e18);
        vm.prank(backend);
        strategy.rebalance(1e18);

        uint256 nvdaBefore = nvda.balanceOf(address(strategy));
        uint256 balanceBefore = usdg.balanceOf(user);

        // 8000 > ~5000 sleeve: stocks must be sold pro-rata
        vm.prank(user);
        strategy.withdraw(8000e18);

        assertEq(usdg.balanceOf(user) - balanceBefore, 8000e18);
        assertLt(nvda.balanceOf(address(strategy)), nvdaBefore);
    }

    function testWithdrawAllExitsEverything() public {
        vm.prank(user);
        strategy.deposit(10_000e18);
        vm.prank(backend);
        strategy.rebalance(1e18);

        uint256 balanceBefore = usdg.balanceOf(user);

        vm.prank(user);
        strategy.withdrawAll();

        // full exit at oracle parity: NAV round-trips minus rounding dust
        assertApproxEqRel(usdg.balanceOf(user) - balanceBefore, 10_000e18, 0.001e18);
        assertEq(nvda.balanceOf(address(strategy)), 0);
        assertEq(aapl.balanceOf(address(strategy)), 0);
        assertEq(sleeve.balanceOf(address(strategy)), 0);
    }

    function testWithdrawRevertsWhenPoolDeviatesFromOracle() public {
        vm.prank(user);
        strategy.deposit(10_000e18);
        vm.prank(backend);
        strategy.rebalance(1e18);

        // pool now fills NVDA sales 3% below oracle — beyond the 1% slippage bound
        router.setExecRate(address(nvda), address(usdg), 174.6e18);
        router.setExecRate(address(aapl), address(usdg), 213.4e18);

        vm.prank(user);
        vm.expectRevert("Too little received");
        strategy.withdraw(8000e18);

        // sleeve-covered withdrawals still work fine
        vm.prank(user);
        strategy.withdraw(3000e18);
    }

    // ==================== NAV & YIELD ====================

    function testSleeveYieldAccruesToNav() public {
        vm.prank(user);
        strategy.deposit(10_000e18);
        vm.prank(backend);
        strategy.rebalance(1e18);

        // 10% yield on the ~5000 USDG sleeve
        usdg.mint(address(sleeve), 500e18);

        assertApproxEqRel(strategy.getTotalBalance(), 10_500e18, 0.001e18);
    }

    function testNavTracksStockPrices() public {
        vm.prank(user);
        strategy.deposit(10_000e18);
        vm.prank(backend);
        strategy.rebalance(1e18);

        // AAPL -50%: 2000 of AAPL value halves
        _setPrice(address(aapl), 110e18);

        assertApproxEqRel(strategy.getTotalBalance(), 9_000e18, 0.01e18);
    }
}
