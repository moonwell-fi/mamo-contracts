// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MarketRegistry} from "@contracts/MarketRegistry.sol";

import {Test} from "@forge-std/Test.sol";
import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";

contract MarketRegistryTest is Test {
    MarketRegistry public registry;

    address public admin;
    address public backend;
    address public guardian;

    address public mToken = makeAddr("mToken");
    address public vault = makeAddr("vault");
    uint256 public strategyTypeId = 1;

    event MarketAdded(uint256 indexed strategyTypeId, address indexed target, MarketType marketType);
    event MarketDeactivated(uint256 indexed strategyTypeId, address indexed target);

    function setUp() public {
        admin = makeAddr("admin");
        backend = makeAddr("backend");
        guardian = makeAddr("guardian");

        registry = new MarketRegistry(admin, backend, guardian);
    }

    // ==================== CONSTRUCTOR TESTS ====================

    function testConstructorSetsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.BACKEND_ROLE(), backend));
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), guardian));
    }

    function testRevertConstructorZeroAdmin() public {
        vm.expectRevert("Invalid admin address");
        new MarketRegistry(address(0), backend, guardian);
    }

    function testRevertConstructorZeroBackend() public {
        vm.expectRevert("Invalid backend address");
        new MarketRegistry(admin, address(0), guardian);
    }

    function testRevertConstructorZeroGuardian() public {
        vm.expectRevert("Invalid guardian address");
        new MarketRegistry(admin, backend, address(0));
    }

    // ==================== ADD MARKET TESTS ====================

    function testAddMarket() public {
        vm.prank(backend);
        vm.expectEmit(true, true, false, true);
        emit MarketAdded(strategyTypeId, mToken, MarketType.MOONWELL);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);

        assertEq(registry.getMarketCount(strategyTypeId), 1);

        RegistryMarket memory market = registry.getMarket(strategyTypeId, mToken);
        assertEq(market.target, mToken);
        assertEq(uint256(market.marketType), uint256(MarketType.MOONWELL));
        assertTrue(market.active);
    }

    function testAddMultipleMarkets() public {
        vm.startPrank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
        registry.addMarket(strategyTypeId, vault, MarketType.ERC4626);
        vm.stopPrank();

        assertEq(registry.getMarketCount(strategyTypeId), 2);

        RegistryMarket[] memory markets = registry.getMarkets(strategyTypeId);
        assertEq(markets.length, 2);
        assertEq(markets[0].target, mToken);
        assertEq(markets[1].target, vault);
    }

    function testRevertAddMarketDuplicate() public {
        vm.startPrank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);

        vm.expectRevert("Market already registered");
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
        vm.stopPrank();
    }

    function testRevertAddMarketTooMany() public {
        vm.startPrank(backend);
        for (uint256 i = 0; i < 10; i++) {
            registry.addMarket(strategyTypeId, address(uint160(100 + i)), MarketType.MOONWELL);
        }

        vm.expectRevert("Too many markets");
        registry.addMarket(strategyTypeId, makeAddr("extra"), MarketType.MOONWELL);
        vm.stopPrank();
    }

    function testRevertAddMarketZeroTarget() public {
        vm.prank(backend);
        vm.expectRevert("Invalid market target");
        registry.addMarket(strategyTypeId, address(0), MarketType.MOONWELL);
    }

    function testRevertAddMarketZeroStrategyTypeId() public {
        vm.prank(backend);
        vm.expectRevert("Invalid strategy type id");
        registry.addMarket(0, mToken, MarketType.MOONWELL);
    }

    function testRevertAddMarketNotBackend() public {
        vm.prank(admin);
        vm.expectRevert();
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
    }

    function testAddMarketDifferentStrategyTypes() public {
        vm.startPrank(backend);
        registry.addMarket(1, mToken, MarketType.MOONWELL);
        registry.addMarket(2, mToken, MarketType.MOONWELL);
        vm.stopPrank();

        assertEq(registry.getMarketCount(1), 1);
        assertEq(registry.getMarketCount(2), 1);
    }

    // ==================== DEACTIVATE MARKET TESTS ====================

    function testDeactivateMarket() public {
        vm.startPrank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);

        vm.expectEmit(true, true, false, true);
        emit MarketDeactivated(strategyTypeId, mToken);
        registry.deactivateMarket(strategyTypeId, mToken);
        vm.stopPrank();

        assertFalse(registry.isMarketActive(strategyTypeId, mToken));
    }

    function testRevertDeactivateMarketNotRegistered() public {
        vm.prank(backend);
        vm.expectRevert("Market not registered");
        registry.deactivateMarket(strategyTypeId, mToken);
    }

    function testRevertDeactivateMarketAlreadyInactive() public {
        vm.startPrank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
        registry.deactivateMarket(strategyTypeId, mToken);

        vm.expectRevert("Market already inactive");
        registry.deactivateMarket(strategyTypeId, mToken);
        vm.stopPrank();
    }

    function testRevertDeactivateMarketNotBackend() public {
        vm.startPrank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert();
        registry.deactivateMarket(strategyTypeId, mToken);
    }

    function testDeactivateDoesNotAffectOtherMarkets() public {
        vm.startPrank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
        registry.addMarket(strategyTypeId, vault, MarketType.ERC4626);
        registry.deactivateMarket(strategyTypeId, mToken);
        vm.stopPrank();

        assertFalse(registry.isMarketActive(strategyTypeId, mToken));
        assertTrue(registry.isMarketActive(strategyTypeId, vault));
    }

    // ==================== VIEW FUNCTION TESTS ====================

    function testGetMarketsEmpty() public view {
        RegistryMarket[] memory markets = registry.getMarkets(strategyTypeId);
        assertEq(markets.length, 0);
    }

    function testGetMarketCountEmpty() public view {
        assertEq(registry.getMarketCount(strategyTypeId), 0);
    }

    function testRevertIsMarketActiveNotRegistered() public {
        vm.expectRevert("Market not registered");
        registry.isMarketActive(strategyTypeId, mToken);
    }

    function testRevertGetMarketNotRegistered() public {
        vm.expectRevert("Market not registered");
        registry.getMarket(strategyTypeId, mToken);
    }

    function testGetMarketsPreservesOrder() public {
        address market1 = makeAddr("market1");
        address market2 = makeAddr("market2");
        address market3 = makeAddr("market3");

        vm.startPrank(backend);
        registry.addMarket(strategyTypeId, market1, MarketType.MOONWELL);
        registry.addMarket(strategyTypeId, market2, MarketType.ERC4626);
        registry.addMarket(strategyTypeId, market3, MarketType.MOONWELL);
        vm.stopPrank();

        RegistryMarket[] memory markets = registry.getMarkets(strategyTypeId);
        assertEq(markets[0].target, market1);
        assertEq(markets[1].target, market2);
        assertEq(markets[2].target, market3);
    }

    // ==================== PAUSE TESTS ====================

    function testPauseBlocksAddMarket() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(backend);
        vm.expectRevert();
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
    }

    function testPauseBlocksDeactivateMarket() public {
        vm.prank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);

        vm.prank(guardian);
        registry.pause();

        vm.prank(backend);
        vm.expectRevert();
        registry.deactivateMarket(strategyTypeId, mToken);
    }

    function testUnpauseRestoresOperations() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(guardian);
        registry.unpause();

        vm.prank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);
        assertEq(registry.getMarketCount(strategyTypeId), 1);
    }

    function testRevertPauseNotGuardian() public {
        vm.prank(backend);
        vm.expectRevert();
        registry.pause();
    }

    function testRevertUnpauseNotGuardian() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(backend);
        vm.expectRevert();
        registry.unpause();
    }

    function testViewFunctionsWorkWhilePaused() public {
        vm.prank(backend);
        registry.addMarket(strategyTypeId, mToken, MarketType.MOONWELL);

        vm.prank(guardian);
        registry.pause();

        // View functions should still work
        assertEq(registry.getMarketCount(strategyTypeId), 1);
        assertTrue(registry.isMarketActive(strategyTypeId, mToken));
        registry.getMarkets(strategyTypeId);
        registry.getMarket(strategyTypeId, mToken);
    }
}
