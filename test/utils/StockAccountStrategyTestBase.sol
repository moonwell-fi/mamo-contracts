// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {MockERC20} from "@test/MockERC20.sol";
import {MockGPv2Settlement} from "@test/mocks/MockGPv2Settlement.sol";
import {MockPriceChecker} from "@test/mocks/MockPriceChecker.sol";
import {MockStockAccountRegistry} from "@test/mocks/MockStockAccountRegistry.sol";

abstract contract StockAccountStrategyTestBase is Test {
    bytes32 public constant SEPARATOR = keccak256("cow-domain-separator");
    uint256 public constant CAP = 25_000e18;

    MamoStrategyRegistry public registry;
    MockStockAccountRegistry public stockRegistry;
    MockPriceChecker public priceChecker;
    MockGPv2Settlement public settlement;

    MockERC20 public usdc;
    MockERC20 public nvda;
    MockERC20 public aapl;

    StockAccountStrategy public implementation;
    StockAccountStrategy public strategy;

    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public relayer = makeAddr("relayer");
    address public user = makeAddr("user");
    address public funder = makeAddr("funder");

    uint256 public strategyTypeId;

    function setUp() public {
        registry = new MamoStrategyRegistry(admin, backend, guardian);

        usdc = new MockERC20("USD Coin", "USDC");
        nvda = new MockERC20("NVDA Coin", "NVDAc");
        aapl = new MockERC20("AAPL Coin", "AAPLc");

        priceChecker = new MockPriceChecker();
        priceChecker.setRate(address(nvda), address(usdc), 200e18);
        priceChecker.setRate(address(aapl), address(usdc), 100e18);

        settlement = new MockGPv2Settlement(SEPARATOR, relayer);

        stockRegistry = new MockStockAccountRegistry();
        stockRegistry.setMaxPositions(10);
        stockRegistry.setMinTargetBps(100);
        stockRegistry.setMaxDeviationBps(1000);
        stockRegistry.setMaxStrategyDeposit(CAP);
        stockRegistry.setMaxBackendSlippageBps(100);
        stockRegistry.setPriceChecker(priceChecker);
        _listActive(address(nvda));
        _listActive(address(aapl));

        implementation = new StockAccountStrategy();

        vm.prank(admin);
        strategyTypeId = registry.whitelistImplementation(address(implementation), 0);

        strategy = StockAccountStrategy(payable(_deployProxy(_defaultParams())));

        vm.prank(backend);
        registry.addStrategy(user, address(strategy));
    }

    function _listActive(address token) internal {
        stockRegistry.setTokenConfig(
            token,
            IStockAccountRegistry.TokenConfig({
                status: IStockAccountRegistry.TokenStatus.Active,
                source: IStockAccountRegistry.PriceSource.PoolTwap,
                pool: address(0),
                chainlinkFeed: address(0)
            })
        );
    }

    function _entries(address tokenA, uint16 bpsA, address tokenB, uint16 bpsB)
        internal
        pure
        returns (IStockAccountStrategy.BasketEntry[] memory entries)
    {
        entries = new IStockAccountStrategy.BasketEntry[](2);
        entries[0] = IStockAccountStrategy.BasketEntry({token: tokenA, targetBps: bpsA});
        entries[1] = IStockAccountStrategy.BasketEntry({token: tokenB, targetBps: bpsB});
    }

    function _entries(address token, uint16 bps)
        internal
        pure
        returns (IStockAccountStrategy.BasketEntry[] memory entries)
    {
        entries = new IStockAccountStrategy.BasketEntry[](1);
        entries[0] = IStockAccountStrategy.BasketEntry({token: token, targetBps: bps});
    }

    function _defaultParams() internal view returns (StockAccountStrategy.InitParams memory) {
        return StockAccountStrategy.InitParams({
            asset: address(usdc),
            cashTargetBps: 0,
            cowSettlement: address(settlement),
            entries: _entries(address(nvda), 5000, address(aapl), 5000),
            mamoStrategyRegistry: address(registry),
            owner: user,
            stockRegistry: address(stockRegistry),
            strategyTypeId: strategyTypeId
        });
    }

    function _deployProxy(StockAccountStrategy.InitParams memory params) internal returns (address) {
        return address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(StockAccountStrategy.initialize, (params)))
        );
    }

    function _fundUsdc(address to, uint256 amount) internal {
        usdc.mint(to, amount);
        vm.prank(to);
        usdc.approve(address(strategy), amount);
    }

    function _fundToken(MockERC20 token, address to, uint256 amount) internal {
        token.mint(to, amount);
        vm.prank(to);
        token.approve(address(strategy), amount);
    }
}
