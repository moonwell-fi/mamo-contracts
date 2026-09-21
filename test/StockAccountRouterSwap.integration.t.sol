// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {IPool} from "@interfaces/IPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The stocks CL factory's pool lookup, kept out of the production interfaces because the
///      strategy never resolves a pool itself: it passes the tick spacing and lets the router do it.
interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @dev The router's own factory, read only to prove the venue the strategy swaps on.
interface ISwapRouterFactory {
    function factory() external view returns (address);
}

/// @notice The withdrawal sell path against the live Aerodrome Slipstream router, pool and token on a
///         PINNED Base fork. Every other suite routes sells through `MockSwapRouter`, which pays the
///         reference price exactly; this one lets a real pool answer.
/// @dev cbBTC is the only launch-list token that can be swapped here at all: the tokenized stocks are
///      node-native precompiles whose code is a single reserved byte, so revm cannot execute them.
/// @dev Self-forks in setUp, so it must run without `--fork-url` (see the stock-price-checker note in
///      the Makefile).
contract StockAccountRouterSwapIntegrationTest is Test {
    uint256 internal constant PINNED_BLOCK = 51_181_271;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant CBBTC_USDC_POOL = 0x160D7E9d948B16c163332a277b393c288408eb12;
    address internal constant AERODROME_STOCKS_SWAP_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address internal constant AERODROME_STOCKS_CL_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address internal constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant CHAINLINK_SWAP_CHECKER_PROXY = 0x5A8F10be44E25Bb21492C5f46DA94cDb1f0b2fF6;
    address internal constant COWSWAP_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    /// @dev The staleness bounds of `DeployStockAccounts`: the launch list's cbBTC heartbeat, and the
    ///      USDC/USD hop deliberately above its nominal 86,400.
    uint256 internal constant BTC_USD_HEARTBEAT = 3600;
    uint256 internal constant USDC_USD_HEARTBEAT = 90_000;

    uint16 internal constant MANAGEMENT_FEE_BPS = 100;
    uint16 internal constant MAX_BACKEND_SLIPPAGE_BPS = 100;
    uint16 internal constant MAX_WITHDRAW_SLIPPAGE_BPS = 500;
    uint256 internal constant MAX_STRATEGY_DEPOSIT = 25_000e6;
    uint256 internal constant MIN_STRATEGY_DEPOSIT = 100e6;
    uint32 internal constant TWAP_WINDOW = 180;
    uint16 internal constant TOTAL_BPS = 10_000;

    uint256 internal constant IDLE_USDC = 5_000e6;
    uint256 internal constant CBBTC_POSITION = 0.2e8;
    uint256 internal constant WITHDRAW_AMOUNT = 12_000e6;
    uint16 internal constant TOLERANCE_BPS = 100;

    /// @dev Sized so the sell is ~10 cbBTC, where the pool's own impact clears 100 bps on its own.
    uint256 internal constant IMPACT_POSITION = 10e8;
    uint16 internal constant IMPACT_TOO_TIGHT_BPS = 100;
    uint16 internal constant IMPACT_WIDE_ENOUGH_BPS = 200;
    /// @dev Leaves the requested amount reachable out of a fill that comes in under the reference.
    uint16 internal constant IMPACT_REQUEST_BPS = 9_700;

    address internal admin = makeAddr("admin");
    address internal backend = makeAddr("backend");
    address internal guardian = makeAddr("guardian");
    address internal orderSigner = makeAddr("orderSigner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal user = makeAddr("user");
    address internal funder = makeAddr("funder");

    StockAccountRegistry internal stockRegistry;
    StockAccountPriceChecker internal priceChecker;
    MamoStrategyRegistry internal mamoRegistry;
    StockAccountStrategy internal strategy;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        _configureExistingChecker();

        stockRegistry = new StockAccountRegistry(
            StockAccountRegistry.Config({
                admin: admin,
                aerodromeRouter: ISwapRouter(AERODROME_STOCKS_SWAP_ROUTER),
                asset: USDC,
                guardian: guardian,
                managementFeeBps: MANAGEMENT_FEE_BPS,
                maxBackendSlippageBps: MAX_BACKEND_SLIPPAGE_BPS,
                maxDeviationBps: 1000,
                maxPositions: 10,
                maxStrategyDeposit: MAX_STRATEGY_DEPOSIT,
                maxWithdrawSlippageBps: MAX_WITHDRAW_SLIPPAGE_BPS,
                minStrategyDeposit: MIN_STRATEGY_DEPOSIT,
                minTargetBps: 500,
                orderSigner: orderSigner,
                priceChecker: ISlippagePriceChecker(address(this)),
                twapWindow: TWAP_WINDOW
            })
        );

        priceChecker =
            new StockAccountPriceChecker(stockRegistry, USDC, ISlippagePriceChecker(CHAINLINK_SWAP_CHECKER_PROXY));

        vm.prank(admin);
        stockRegistry.setPriceChecker(priceChecker);

        vm.prank(admin);
        stockRegistry.listToken(
            CBBTC,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.Chainlink,
                pool: CBBTC_USDC_POOL,
                chainlinkFeed: CHAINLINK_BTC_USD
            })
        );

        mamoRegistry = new MamoStrategyRegistry(admin, backend, guardian);

        StockAccountStrategy implementation = new StockAccountStrategy();
        vm.prank(admin);
        uint256 strategyTypeId = mamoRegistry.whitelistImplementation(address(implementation), 0);

        IStockAccountStrategy.BasketEntry[] memory entries = new IStockAccountStrategy.BasketEntry[](1);
        entries[0] = IStockAccountStrategy.BasketEntry({token: CBBTC, targetBps: TOTAL_BPS});

        strategy = StockAccountStrategy(
            payable(
                address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            StockAccountStrategy.initialize,
                            (
                                StockAccountStrategy.InitParams({
                                    asset: USDC,
                                    cashTargetBps: 0,
                                    cowSettlement: COWSWAP_SETTLEMENT,
                                    entries: entries,
                                    feeRecipient: feeRecipient,
                                    mamoStrategyRegistry: address(mamoRegistry),
                                    owner: user,
                                    stockRegistry: address(stockRegistry),
                                    strategyTypeId: strategyTypeId
                                })
                            )
                        )
                    )
                )
            )
        );

        vm.prank(backend);
        mamoRegistry.addStrategy(user, address(strategy));
    }

    /// @dev The cbBTC -> USDC pair the launch list needs is not configured on the live checker, so the
    ///      test adds it as `DeployStockAccounts` does: the BTC/USD feed forward, USDC/USD reversed.
    function _configureExistingChecker() internal {
        ISlippagePriceChecker existing = ISlippagePriceChecker(CHAINLINK_SWAP_CHECKER_PROXY);
        assertEq(existing.tokenPairOracleInformation(CBBTC, USDC).length, 0, "pair already configured");

        ISlippagePriceChecker.TokenFeedConfiguration[] memory cfgs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](2);
        cfgs[0] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: CHAINLINK_BTC_USD,
            reverse: false,
            heartbeat: BTC_USD_HEARTBEAT
        });
        cfgs[1] = ISlippagePriceChecker.TokenFeedConfiguration({
            chainlinkFeed: CHAINLINK_USDC_USD,
            reverse: true,
            heartbeat: USDC_USD_HEARTBEAT
        });

        address owner = IERC5313(CHAINLINK_SWAP_CHECKER_PROXY).owner();
        vm.prank(owner);
        existing.addTokenConfiguration(CBBTC, USDC, cfgs);
        vm.prank(owner);
        existing.setMaxTimePriceValid(CBBTC, BTC_USD_HEARTBEAT);
    }

    function _fundAccount() internal {
        _deal(USDC, funder, IDLE_USDC);
        vm.prank(funder);
        IERC20(USDC).approve(address(strategy), IDLE_USDC);
        vm.prank(funder);
        strategy.deposit(IDLE_USDC);

        _deal(CBBTC, funder, CBBTC_POSITION);
        vm.prank(funder);
        IERC20(CBBTC).approve(address(strategy), CBBTC_POSITION);
        vm.prank(funder);
        strategy.depositToken(CBBTC, CBBTC_POSITION);
    }

    /// @dev `deal` writes a balance slot it guessed; a token that computes balances some other way would
    ///      silently leave the account empty and make every assertion below vacuous.
    function _deal(address token, address to, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(to);
        deal(token, to, before + amount);
        assertEq(IERC20(token).balanceOf(to), before + amount, "deal did not land");
    }

    function test_fork_launchListPoolIsTheOneTheRouterResolves() public view {
        int24 tickSpacing = IPool(CBBTC_USDC_POOL).tickSpacing();

        assertEq(
            ICLFactory(AERODROME_STOCKS_CL_FACTORY).getPool(USDC, CBBTC, tickSpacing),
            CBBTC_USDC_POOL,
            "listed pool is not the stocks-factory pool for its own tick spacing"
        );
        assertEq(
            ISwapRouterFactory(AERODROME_STOCKS_SWAP_ROUTER).factory(),
            AERODROME_STOCKS_CL_FACTORY,
            "router resolves pools on another factory"
        );
        assertEq(ICLPool(CBBTC_USDC_POOL).token0(), USDC, "token0");
        assertEq(ICLPool(CBBTC_USDC_POOL).token1(), CBBTC, "token1");
    }

    function test_fork_withdrawSellsCbbtcOnTheRealPool() public {
        _fundAccount();

        (,, uint256 referenceValue, uint256 minProceeds) = strategy.previewWithdraw(WITHDRAW_AMOUNT, TOLERANCE_BPS);
        assertGt(minProceeds, 0, "vacuous: nothing planned to sell");

        uint256 poolCbbtcBefore = IERC20(CBBTC).balanceOf(CBBTC_USDC_POOL);
        uint256 strategyUsdcBefore = IERC20(USDC).balanceOf(address(strategy));
        (uint160 sqrtPriceBefore,,,,,) = ICLPool(CBBTC_USDC_POOL).slot0();

        vm.prank(user);
        strategy.withdraw(WITHDRAW_AMOUNT, TOLERANCE_BPS);

        uint256 sold = CBBTC_POSITION - IERC20(CBBTC).balanceOf(address(strategy));
        uint256 proceeds = IERC20(USDC).balanceOf(address(strategy)) + WITHDRAW_AMOUNT - strategyUsdcBefore;
        (uint160 sqrtPriceAfter,,,,,) = ICLPool(CBBTC_USDC_POOL).slot0();

        assertGe(IERC20(USDC).balanceOf(user), WITHDRAW_AMOUNT, "owner short of the requested amount");
        assertGt(sold, 0, "vacuous: nothing sold");
        assertEq(IERC20(CBBTC).balanceOf(CBBTC_USDC_POOL) - poolCbbtcBefore, sold, "the real pool did not take it");
        assertGt(sqrtPriceAfter, sqrtPriceBefore, "the real pool did not move");

        assertGe(proceeds, minProceeds, "fill came in under the floor the contract enforced");
        assertLt(proceeds, referenceValue, "vacuous: the real pool paid the reference exactly");
    }

    function test_fork_previewWithdrawMatchesTheExecutedWithdrawal() public {
        _fundAccount();

        (address[] memory tokens, uint256[] memory amounts, uint256 referenceValue, uint256 minProceeds) =
            strategy.previewWithdraw(WITHDRAW_AMOUNT, TOLERANCE_BPS);

        assertEq(tokens.length, 1, "leg count");
        assertEq(tokens[0], CBBTC, "leg token");
        assertEq(minProceeds, (referenceValue * (TOTAL_BPS - TOLERANCE_BPS)) / TOTAL_BPS, "floor vs reference");
        assertEq(
            referenceValue,
            priceChecker.getExpectedOut(amounts[0], CBBTC, USDC),
            "reference is not the checker's quote for the planned leg"
        );

        uint256 strategyUsdcBefore = IERC20(USDC).balanceOf(address(strategy));

        vm.recordLogs();
        vm.prank(user);
        strategy.withdraw(WITHDRAW_AMOUNT, TOLERANCE_BPS);

        uint256 sold = CBBTC_POSITION - IERC20(CBBTC).balanceOf(address(strategy));
        uint256 proceeds = IERC20(USDC).balanceOf(address(strategy)) + WITHDRAW_AMOUNT - strategyUsdcBefore;

        assertEq(sold, amounts[0], "sold a different amount than previewed");
        assertEq(proceeds, _withdrawEventSold(), "the reported sale is not the realised proceeds");
        assertGe(proceeds, minProceeds, "realised proceeds under the previewed floor");
    }

    function test_fork_withdrawRevertsWhenToleranceIsBelowPoolImpact() public {
        _deal(CBBTC, address(strategy), IMPACT_POSITION);
        uint256 requested = (priceChecker.getExpectedOut(IMPACT_POSITION, CBBTC, USDC) * IMPACT_REQUEST_BPS) / TOTAL_BPS;

        (,,, uint256 tightFloor) = strategy.previewWithdraw(requested, IMPACT_TOO_TIGHT_BPS);
        assertGt(tightFloor, 0, "vacuous: nothing planned to sell");

        uint256 snapshot = vm.snapshotState();

        vm.prank(user);
        vm.expectRevert(bytes("Too little received"));
        strategy.withdraw(requested, IMPACT_TOO_TIGHT_BPS);

        vm.revertToState(snapshot);

        (, uint256[] memory amounts, uint256 referenceValue,) =
            strategy.previewWithdraw(requested, IMPACT_WIDE_ENOUGH_BPS);

        vm.prank(user);
        strategy.withdraw(requested, IMPACT_WIDE_ENOUGH_BPS);

        uint256 sold = IMPACT_POSITION - IERC20(CBBTC).balanceOf(address(strategy));
        uint256 proceeds = IERC20(USDC).balanceOf(address(strategy)) + requested;

        assertGe(IERC20(USDC).balanceOf(user), requested, "owner short of the requested amount");
        assertEq(sold, amounts[0], "sold a different amount than previewed");
        assertLt(
            proceeds * TOTAL_BPS,
            referenceValue * (TOTAL_BPS - IMPACT_TOO_TIGHT_BPS),
            "vacuous: a sell this size clears the tighter floor, so impact is not what rejected it"
        );
    }

    function test_fork_withdrawAllSellsTheWholePositionOnTheRealPool() public {
        _fundAccount();

        uint256 referenceValue = priceChecker.getExpectedOut(CBBTC_POSITION, CBBTC, USDC);

        vm.prank(user);
        strategy.withdrawAll(TOLERANCE_BPS);

        assertEq(IERC20(CBBTC).balanceOf(address(strategy)), 0, "position left behind");
        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0, "asset left behind");

        uint256 received = IERC20(USDC).balanceOf(user);
        assertGe(received, IDLE_USDC + (referenceValue * (TOTAL_BPS - TOLERANCE_BPS)) / TOTAL_BPS, "under the floor");
        assertLt(received, IDLE_USDC + referenceValue, "vacuous: the real pool paid the reference exactly");
    }

    function test_fork_withdrawAllInKindMovesTheRealBalances() public {
        _fundAccount();

        uint256 idle = IERC20(USDC).balanceOf(address(strategy));

        vm.prank(user);
        strategy.withdrawAllInKind();

        assertEq(IERC20(USDC).balanceOf(address(strategy)), 0, "asset left behind");
        assertEq(IERC20(CBBTC).balanceOf(address(strategy)), 0, "position left behind");
        assertEq(IERC20(USDC).balanceOf(user), idle, "owner asset");
        assertEq(IERC20(CBBTC).balanceOf(user), CBBTC_POSITION, "owner position");
    }

    /// @dev The `sold` field of the single `Withdraw` event in the last recorded logs.
    function _withdrawEventSold() internal returns (uint256 sold) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IStockAccountStrategy.Withdraw.selector;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(strategy) && logs[i].topics[0] == topic) {
                (, sold) = abi.decode(logs[i].data, (uint256, uint256));
                return sold;
            }
        }

        revert("no Withdraw event");
    }
}
