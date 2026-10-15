// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoStakingRegistryV2} from "@contracts/MamoStakingRegistryV2.sol";
import {MamoStakingStrategyV2} from "@contracts/MamoStakingStrategyV2.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockPriceChecker} from "./mocks/MockPriceChecker.sol";
import {MockStockAccountRegistry} from "./mocks/MockStockAccountRegistry.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract MockHopPool {
    address public token0;
    address public token1;
    int24 public tickSpacing = 100;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract MockStrategyRegistry {
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");
    mapping(address => mapping(address => bool)) public isUserStrategy;

    function register(address user, address strategy) external {
        isUserStrategy[user][strategy] = true;
    }
}

contract MockStockAccount {
    address public owner;
    bool public fail;

    constructor(address owner_) {
        owner = owner_;
    }

    function setFail(bool fail_) external {
        fail = fail_;
    }

    function depositToken(address token, uint256 amount) external {
        require(!fail, "AccountAtCap");
        MockERC20Decimals(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract MockStockPriceChecker is MockPriceChecker {
    address public registry;

    constructor(address registry_) {
        registry = registry_;
    }
}

contract MockMultiMarketStrategy {
    address public owner;
    address public token;

    constructor(address owner_, address token_) {
        owner = owner_;
        token = token_;
    }

    function deposit(uint256) external pure {
        revert("Deposit failed");
    }
}

contract MamoStakingStrategyV2UnitTest is Test {
    address internal admin = makeAddr("admin");
    address internal backend = makeAddr("backend");
    address internal user = makeAddr("user");

    MockERC20Decimals internal mamo = new MockERC20Decimals("MAMO", 18);
    MockERC20Decimals internal cbBtc = new MockERC20Decimals("cbBTC", 8);
    MockERC20Decimals internal stock = new MockERC20Decimals("NVDAc", 8);
    MockERC20Decimals internal usdc = new MockERC20Decimals("USDC", 6);

    MockSwapRouter internal router = new MockSwapRouter();
    MockSwapRouter internal stockRouter = new MockSwapRouter();
    MockPriceChecker internal checker = new MockPriceChecker();
    MockStockAccountRegistry internal stockRegistry = new MockStockAccountRegistry();
    MockStockPriceChecker internal stockChecker = new MockStockPriceChecker(address(stockRegistry));
    MockStrategyRegistry internal strategyRegistry = new MockStrategyRegistry();
    MockStockAccount internal stockAccount = new MockStockAccount(user);

    MamoStakingRegistryV2 internal registry;
    MamoStakingStrategyV2 internal strategy;
    IMultiRewards internal multiRewards;
    MockHopPool internal stockUsdc;

    function setUp() public {
        multiRewards = IMultiRewards(vm.deployCode("MultiRewards.sol:MultiRewards", abi.encode(admin, address(mamo))));

        registry = new MamoStakingRegistryV2(
            admin, backend, admin, address(mamo), address(router), address(1), address(checker), 100
        );

        MamoStakingStrategyV2 impl = new MamoStakingStrategyV2();
        strategy = MamoStakingStrategyV2(
            payable(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        MamoStakingStrategyV2.initialize,
                        (
                            MamoStakingStrategyV2.InitParams({
                                mamoStrategyRegistry: address(strategyRegistry),
                                stakingRegistry: address(registry),
                                multiRewards: address(multiRewards),
                                mamoToken: address(mamo),
                                strategyTypeId: 1,
                                owner: user
                            })
                        )
                    )
                )
            )
        );
        strategyRegistry.register(user, address(stockAccount));

        stockUsdc = new MockHopPool(address(usdc), address(stock));
        _listStock(IStockAccountRegistry.TokenStatus.Active, address(stockUsdc));
        MockHopPool usdcMamo = new MockHopPool(address(mamo), address(usdc));

        vm.startPrank(backend);
        registry.addRewardToken(address(cbBtc), address(new MockHopPool(address(cbBtc), address(mamo))));
        registry.addRewardToken(address(stock), address(stockUsdc));
        vm.stopPrank();

        MamoStakingRegistryV2.Hop[] memory route = new MamoStakingRegistryV2.Hop[](2);
        route[0] = MamoStakingRegistryV2.Hop(address(stockUsdc), stockRouter, stockChecker);
        // Unset router and checker: the registry's global ones
        route[1] =
            MamoStakingRegistryV2.Hop(address(usdcMamo), ISwapRouter(address(0)), ISlippagePriceChecker(address(0)));
        vm.prank(admin);
        registry.setRoute(address(stock), route);

        // 1 NVDAc = 200 USDC, 1 USDC = 10 MAMO, 1 cbBTC = 1M MAMO, paid at exactly the checker price
        _setRate(stockRouter, stockChecker, address(stock), address(usdc), 2e18);
        _setRate(router, checker, address(usdc), address(mamo), 1e31);
        _setRate(router, checker, address(cbBtc), address(mamo), 1e34);
        usdc.mint(address(stockRouter), 1e12);
        mamo.mint(address(router), 1e30);

        mamo.mint(user, 1e18);
        vm.startPrank(user);
        mamo.approve(address(strategy), 1e18);
        strategy.deposit(1e18);
        vm.stopPrank();
    }

    function test_compound_swapsAlongTheRouteAndTheSinglePool() public {
        stock.mint(address(strategy), 1e8);
        cbBtc.mint(address(strategy), 1e6);

        vm.prank(backend);
        strategy.compound(block.timestamp + 10 minutes);

        assertEq(multiRewards.balanceOf(address(strategy)), 1e18 + 2_000e18 + 10_000e18);
        assertEq(stock.balanceOf(address(strategy)), 0);
        assertEq(usdc.balanceOf(address(strategy)), 0, "no intermediate token left behind");
    }

    function test_compound_floorsTheWholeRouteAndHoldsATokenThatFails() public {
        // Each hop pays 0.6% under the oracle: within 1% per hop, but 1.2% over the whole route
        stockRouter.setRate(address(stock), address(usdc), 1.988e18);
        router.setRate(address(usdc), address(mamo), 0.994e31);
        stock.mint(address(strategy), 1e8);
        cbBtc.mint(address(strategy), 1e6);

        vm.expectEmit(address(strategy));
        emit MamoStakingStrategyV2.CompoundRewardTokenHeld(address(stock), 1e8);
        vm.prank(backend);
        strategy.compound(block.timestamp + 10 minutes);

        assertEq(stock.balanceOf(address(strategy)), 1e8, "held");
        assertEq(multiRewards.balanceOf(address(strategy)), 1e18 + 10_000e18, "cbBTC still compounds");
    }

    function test_reinvest_depositsStockRewardsIntoTheStockAccount() public {
        stock.mint(address(strategy), 1e8);

        vm.prank(backend);
        strategy.reinvest(_destinations(address(0), address(stockAccount)));

        assertEq(stock.balanceOf(address(stockAccount)), 1e8);
    }

    function test_reinvest_holdsTheRewardWhenTheDepositFailsOrHasNoDestination() public {
        stock.mint(address(strategy), 1e8);
        cbBtc.mint(address(strategy), 1e6);
        mamo.mint(address(strategy), 5e18);
        stockAccount.setFail(true);

        vm.expectEmit(address(strategy));
        emit MamoStakingStrategyV2.ReinvestRewardTokenHeld(address(stock), 1e8);
        vm.prank(backend);
        strategy.reinvest(_destinations(address(0), address(stockAccount)));

        assertEq(stock.balanceOf(address(strategy)), 1e8);
        assertEq(stock.allowance(address(strategy), address(stockAccount)), 0);
        assertEq(cbBtc.balanceOf(address(strategy)), 1e6);
        assertEq(multiRewards.balanceOf(address(strategy)), 6e18, "MAMO is still restaked");
    }

    function test_reinvest_holdsTheRewardWhenAMultiMarketDepositFails() public {
        MockMultiMarketStrategy cbBtcStrategy = new MockMultiMarketStrategy(user, address(cbBtc));
        strategyRegistry.register(user, address(cbBtcStrategy));
        stock.mint(address(strategy), 1e8);
        cbBtc.mint(address(strategy), 1e6);

        vm.expectEmit(address(strategy));
        emit MamoStakingStrategyV2.ReinvestRewardTokenHeld(address(cbBtc), 1e6);
        vm.prank(backend);
        strategy.reinvest(_destinations(address(cbBtcStrategy), address(stockAccount)));

        assertEq(cbBtc.balanceOf(address(strategy)), 1e6);
        assertEq(cbBtc.allowance(address(strategy), address(cbBtcStrategy)), 0);
        assertEq(stock.balanceOf(address(stockAccount)), 1e8, "the next destination still gets its deposit");
    }

    function test_initialize_crossChecksTheRegistryAndMultiRewards() public {
        MockERC20Decimals otherMamo = new MockERC20Decimals("MAMO2", 18);
        MamoStakingStrategyV2 impl = new MamoStakingStrategyV2();
        MamoStakingStrategyV2.InitParams memory params = MamoStakingStrategyV2.InitParams({
            mamoStrategyRegistry: address(strategyRegistry),
            stakingRegistry: address(registry),
            multiRewards: address(multiRewards),
            mamoToken: address(otherMamo),
            strategyTypeId: 1,
            owner: user
        });

        vm.expectRevert("Staking registry MAMO token mismatch");
        new ERC1967Proxy(address(impl), abi.encodeCall(MamoStakingStrategyV2.initialize, (params)));

        params.stakingRegistry = address(
            new MamoStakingRegistryV2(
                admin, backend, admin, address(otherMamo), address(router), address(1), address(checker), 100
            )
        );
        vm.expectRevert("MultiRewards token mismatch");
        new ERC1967Proxy(address(impl), abi.encodeCall(MamoStakingStrategyV2.initialize, (params)));

        params.stakingRegistry = makeAddr("eoa");
        vm.etch(params.stakingRegistry, ""); // the label's address carries delegated code on a Base fork
        vm.expectRevert("Staking registry not a contract");
        new ERC1967Proxy(address(impl), abi.encodeCall(MamoStakingStrategyV2.initialize, (params)));
    }

    function test_compoundAndReinvest_holdTheMamoWhileMultiRewardsIsPaused() public {
        vm.prank(admin);
        multiRewards.setPaused(true);
        cbBtc.mint(address(strategy), 1e6);

        mamo.mint(user, 1e18);
        vm.startPrank(user);
        mamo.approve(address(strategy), 1e18);
        vm.expectRevert("This action cannot be performed while the contract is paused");
        strategy.deposit(1e18);
        vm.stopPrank();

        vm.expectEmit(address(strategy));
        emit MamoStakingStrategyV2.MamoHeld(10_000e18);
        vm.prank(backend);
        strategy.compound(block.timestamp + 10 minutes);

        vm.expectEmit(address(strategy));
        emit MamoStakingStrategyV2.MamoHeld(10_000e18);
        vm.prank(backend);
        strategy.reinvest(_destinations(address(0), address(0)));
        assertEq(mamo.balanceOf(address(strategy)), 10_000e18, "held on the account");

        vm.prank(admin);
        multiRewards.setPaused(false);
        vm.prank(backend);
        strategy.compound(block.timestamp + 10 minutes);
        assertEq(multiRewards.balanceOf(address(strategy)), 1e18 + 10_000e18, "staked by the next compound");
    }

    function test_compound_holdsAStockThatIsHaltedOrUnlisted() public {
        stock.mint(address(strategy), 1e8);
        cbBtc.mint(address(strategy), 1e6);
        _listStock(IStockAccountRegistry.TokenStatus.None, address(stockUsdc));
        vm.prank(address(strategy));
        vm.expectRevert("Stock not sellable");
        strategy.compoundRewardToken(address(stock), address(stockUsdc), 1e8, block.timestamp);

        _listStock(IStockAccountRegistry.TokenStatus.Halted, address(stockUsdc));
        vm.prank(address(strategy));
        vm.expectRevert("Stock not sellable");
        strategy.compoundRewardToken(address(stock), address(stockUsdc), 1e8, block.timestamp);

        vm.expectEmit(address(strategy));
        emit MamoStakingStrategyV2.CompoundRewardTokenHeld(address(stock), 1e8);
        vm.prank(backend);
        strategy.compound(block.timestamp + 10 minutes);
        assertEq(stock.balanceOf(address(strategy)), 1e8, "held");
        assertEq(multiRewards.balanceOf(address(strategy)), 1e18 + 10_000e18, "cbBTC still compounds");

        // A sell-only stock is still sold
        _listStock(IStockAccountRegistry.TokenStatus.SellOnly, address(stockUsdc));
        vm.prank(backend);
        strategy.compound(block.timestamp + 10 minutes);
        assertEq(stock.balanceOf(address(strategy)), 0);
    }

    function test_setRoute_validatesTheRoute() public {
        MamoStakingRegistryV2.Hop[] memory route = new MamoStakingRegistryV2.Hop[](1);
        route[0] = MamoStakingRegistryV2.Hop(address(stockUsdc), stockRouter, stockChecker);

        vm.startPrank(admin);
        vm.expectRevert("Route must end in MAMO");
        registry.setRoute(address(stock), route);

        vm.expectRevert("Token not in pool");
        registry.setRoute(address(cbBtc), route);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.setRoute(address(stock), new MamoStakingRegistryV2.Hop[](0));

        vm.prank(backend);
        registry.removeRewardToken(address(stock));
        assertEq(registry.getRoute(address(stock)).length, 2, "only the admin changes a route");
    }

    function _listStock(IStockAccountRegistry.TokenStatus status, address pool) internal {
        stockRegistry.setTokenConfig(
            address(stock),
            IStockAccountRegistry.TokenConfig(status, IStockAccountRegistry.PriceSource.PoolTwap, pool, address(0))
        );
    }

    function _setRate(MockSwapRouter r, MockPriceChecker c, address tokenIn, address tokenOut, uint256 rate) internal {
        r.setRate(tokenIn, tokenOut, rate);
        c.setRate(tokenIn, tokenOut, rate);
    }

    function _destinations(address cbBtcDestination, address stockDestination)
        internal
        pure
        returns (address[] memory destinations)
    {
        destinations = new address[](2);
        destinations[0] = cbBtcDestination;
        destinations[1] = stockDestination;
    }
}
