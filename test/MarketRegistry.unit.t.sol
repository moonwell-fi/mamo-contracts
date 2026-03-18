// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MarketRegistry} from "@contracts/MarketRegistry.sol";

import {Test} from "@forge-std/Test.sol";

import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MarketRegistryTest is Test {
    MarketRegistry public registry;

    address public admin;
    address public backend;
    address public guardian;

    address public mToken = makeAddr("mToken");
    address public vault = makeAddr("vault");
    address public asset = makeAddr("asset");

    event MarketAdded(address indexed asset, address indexed target, MarketType marketType);
    event MarketDeactivated(address indexed asset, address indexed target);
    event MarketReactivated(address indexed asset, address indexed target);

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
        emit MarketAdded(asset, mToken, MarketType.MTOKEN);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);

        assertEq(registry.getMarketCount(asset), 1);

        RegistryMarket memory market = registry.getMarket(asset, mToken);
        assertEq(market.target, mToken);
        assertEq(uint256(market.marketType), uint256(MarketType.MTOKEN));
        assertTrue(market.active);
    }

    function testAddMultipleMarkets() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.addMarket(asset, vault, MarketType.ERC4626);
        vm.stopPrank();

        assertEq(registry.getMarketCount(asset), 2);

        RegistryMarket[] memory markets = registry.getMarkets(asset);
        assertEq(markets.length, 2);
        assertEq(markets[0].target, mToken);
        assertEq(markets[1].target, vault);
    }

    function testRevertAddMarketDuplicate() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);

        vm.expectRevert("Market already registered");
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        vm.stopPrank();
    }

    function testRevertAddMarketTooMany() public {
        vm.startPrank(backend);
        for (uint256 i = 0; i < 10; i++) {
            registry.addMarket(asset, address(uint160(100 + i)), MarketType.MTOKEN);
        }

        vm.expectRevert("Too many markets");
        registry.addMarket(asset, makeAddr("extra"), MarketType.MTOKEN);
        vm.stopPrank();
    }

    function testRevertAddMarketZeroTarget() public {
        vm.prank(backend);
        vm.expectRevert("Invalid market target");
        registry.addMarket(asset, address(0), MarketType.MTOKEN);
    }

    function testRevertAddMarketZeroAsset() public {
        vm.prank(backend);
        vm.expectRevert("Invalid asset address");
        registry.addMarket(address(0), mToken, MarketType.MTOKEN);
    }

    function testRevertAddMarketNotBackend() public {
        bytes32 backendRole = registry.BACKEND_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, backendRole)
        );
        vm.prank(admin);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
    }

    function testAddMarketDifferentAssets() public {
        address assetA = makeAddr("assetA");
        address assetB = makeAddr("assetB");

        vm.startPrank(backend);
        registry.addMarket(assetA, mToken, MarketType.MTOKEN);
        registry.addMarket(assetB, mToken, MarketType.MTOKEN);
        vm.stopPrank();

        assertEq(registry.getMarketCount(assetA), 1);
        assertEq(registry.getMarketCount(assetB), 1);
    }

    // ==================== DEACTIVATE MARKET TESTS ====================

    function testDeactivateMarket() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);

        vm.expectEmit(true, true, false, true);
        emit MarketDeactivated(asset, mToken);
        registry.deactivateMarket(asset, mToken);
        vm.stopPrank();

        assertFalse(registry.isMarketActive(asset, mToken));
    }

    function testRevertDeactivateMarketNotRegistered() public {
        vm.prank(backend);
        vm.expectRevert("Market not registered");
        registry.deactivateMarket(asset, mToken);
    }

    function testRevertDeactivateMarketAlreadyInactive() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.deactivateMarket(asset, mToken);

        vm.expectRevert("Market already inactive");
        registry.deactivateMarket(asset, mToken);
        vm.stopPrank();
    }

    function testRevertDeactivateMarketNotBackend() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        vm.stopPrank();

        bytes32 backendRole = registry.BACKEND_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, backendRole)
        );
        vm.prank(admin);
        registry.deactivateMarket(asset, mToken);
    }

    function testDeactivateDoesNotAffectOtherMarkets() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.addMarket(asset, vault, MarketType.ERC4626);
        registry.deactivateMarket(asset, mToken);
        vm.stopPrank();

        assertFalse(registry.isMarketActive(asset, mToken));
        assertTrue(registry.isMarketActive(asset, vault));
    }

    // ==================== REACTIVATE MARKET TESTS ====================

    function testReactivateMarket() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.deactivateMarket(asset, mToken);

        assertFalse(registry.isMarketActive(asset, mToken));

        vm.expectEmit(true, true, false, true);
        emit MarketReactivated(asset, mToken);
        registry.reactivateMarket(asset, mToken);
        vm.stopPrank();

        assertTrue(registry.isMarketActive(asset, mToken));
    }

    function testRevertReactivateMarketNotRegistered() public {
        vm.prank(backend);
        vm.expectRevert("Market not registered");
        registry.reactivateMarket(asset, mToken);
    }

    function testRevertReactivateMarketAlreadyActive() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);

        vm.expectRevert("Market already active");
        registry.reactivateMarket(asset, mToken);
        vm.stopPrank();
    }

    function testRevertReactivateMarketNotBackend() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.deactivateMarket(asset, mToken);
        vm.stopPrank();

        bytes32 backendRole = registry.BACKEND_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, backendRole)
        );
        vm.prank(admin);
        registry.reactivateMarket(asset, mToken);
    }

    function testReactivateMarketBlockedWhenPaused() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.deactivateMarket(asset, mToken);
        vm.stopPrank();

        vm.prank(guardian);
        registry.pause();

        vm.prank(backend);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.reactivateMarket(asset, mToken);
    }

    function testDeactivateAndReactivateCycle() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);

        registry.deactivateMarket(asset, mToken);
        assertFalse(registry.isMarketActive(asset, mToken));

        registry.reactivateMarket(asset, mToken);
        assertTrue(registry.isMarketActive(asset, mToken));

        registry.deactivateMarket(asset, mToken);
        assertFalse(registry.isMarketActive(asset, mToken));
        vm.stopPrank();

        // Count should still be 1 (no new entries)
        assertEq(registry.getMarketCount(asset), 1);
    }

    function testReactivateDoesNotAffectOtherMarkets() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.addMarket(asset, vault, MarketType.ERC4626);

        registry.deactivateMarket(asset, mToken);
        registry.deactivateMarket(asset, vault);

        // Reactivate only mToken
        registry.reactivateMarket(asset, mToken);
        vm.stopPrank();

        assertTrue(registry.isMarketActive(asset, mToken));
        assertFalse(registry.isMarketActive(asset, vault));
    }

    // ==================== VIEW FUNCTION TESTS ====================

    function testGetMarketsEmpty() public view {
        RegistryMarket[] memory markets = registry.getMarkets(asset);
        assertEq(markets.length, 0);
    }

    function testGetMarketCountEmpty() public view {
        assertEq(registry.getMarketCount(asset), 0);
    }

    function testRevertIsMarketActiveNotRegistered() public {
        vm.expectRevert("Market not registered");
        registry.isMarketActive(asset, mToken);
    }

    function testRevertGetMarketNotRegistered() public {
        vm.expectRevert("Market not registered");
        registry.getMarket(asset, mToken);
    }

    function testGetMarketsPreservesOrder() public {
        address market1 = makeAddr("market1");
        address market2 = makeAddr("market2");
        address market3 = makeAddr("market3");

        vm.startPrank(backend);
        registry.addMarket(asset, market1, MarketType.MTOKEN);
        registry.addMarket(asset, market2, MarketType.ERC4626);
        registry.addMarket(asset, market3, MarketType.MTOKEN);
        vm.stopPrank();

        RegistryMarket[] memory markets = registry.getMarkets(asset);
        assertEq(markets[0].target, market1);
        assertEq(markets[1].target, market2);
        assertEq(markets[2].target, market3);
    }

    // ==================== PAUSE TESTS ====================

    function testPauseBlocksAddMarket() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(backend);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
    }

    function testPauseBlocksDeactivateMarket() public {
        vm.prank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);

        vm.prank(guardian);
        registry.pause();

        vm.prank(backend);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.deactivateMarket(asset, mToken);
    }

    function testUnpauseRestoresOperations() public {
        vm.prank(guardian);
        registry.pause();

        vm.prank(guardian);
        registry.unpause();

        vm.prank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        assertEq(registry.getMarketCount(asset), 1);
    }

    function testRevertPauseNotGuardian() public {
        bytes32 guardianRole = registry.GUARDIAN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, backend, guardianRole)
        );
        vm.prank(backend);
        registry.pause();
    }

    function testRevertUnpauseNotGuardian() public {
        vm.prank(guardian);
        registry.pause();

        bytes32 guardianRole = registry.GUARDIAN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, backend, guardianRole)
        );
        vm.prank(backend);
        registry.unpause();
    }

    function testViewFunctionsWorkWhilePaused() public {
        vm.prank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);

        vm.prank(guardian);
        registry.pause();

        // View functions should still work
        assertEq(registry.getMarketCount(asset), 1);
        assertTrue(registry.isMarketActive(asset, mToken));
        registry.getMarkets(asset);
        registry.getMarket(asset, mToken);
    }

    // ==================== EDGE CASE TESTS ====================

    function testZeroMarketsReturnsEmptyArray() public view {
        RegistryMarket[] memory markets = registry.getMarkets(asset);
        assertEq(markets.length, 0);
        assertEq(registry.getMarketCount(asset), 0);
    }

    function testAllMarketsDeactivated() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.addMarket(asset, vault, MarketType.ERC4626);

        registry.deactivateMarket(asset, mToken);
        registry.deactivateMarket(asset, vault);
        vm.stopPrank();

        // Count stays the same (append-only), but both are inactive
        assertEq(registry.getMarketCount(asset), 2);
        assertFalse(registry.isMarketActive(asset, mToken));
        assertFalse(registry.isMarketActive(asset, vault));

        RegistryMarket[] memory markets = registry.getMarkets(asset);
        assertFalse(markets[0].active);
        assertFalse(markets[1].active);
    }

    function testMaxMarketsGas() public {
        vm.startPrank(backend);
        for (uint256 i = 0; i < 10; i++) {
            registry.addMarket(asset, address(uint160(100 + i)), MarketType.MTOKEN);
        }
        vm.stopPrank();

        // Verify all 10 markets are accessible
        RegistryMarket[] memory markets = registry.getMarkets(asset);
        assertEq(markets.length, 10);

        // Verify getMarketCount
        assertEq(registry.getMarketCount(asset), 10);
    }

    function testInvalidEnumValueRevertsAtAbiLevel() public {
        // Solidity 0.8+ validates enum values at ABI decoding level
        // Passing an out-of-range uint (e.g. 2 for a 2-variant enum) reverts automatically
        vm.prank(backend);
        (bool success,) =
            address(registry).call(abi.encodeWithSelector(MarketRegistry.addMarket.selector, asset, mToken, uint8(99)));
        assertFalse(success, "Should revert for invalid enum value");
    }

    function testDeactivateAndQueryMarketState() public {
        vm.startPrank(backend);
        registry.addMarket(asset, mToken, MarketType.MTOKEN);
        registry.deactivateMarket(asset, mToken);
        vm.stopPrank();

        // getMarket should still return the market (it exists, just inactive)
        RegistryMarket memory market = registry.getMarket(asset, mToken);
        assertEq(market.target, mToken);
        assertFalse(market.active);
    }

    function testMultipleAssetsIndependent() public {
        address assetA = makeAddr("assetA");
        address assetB = makeAddr("assetB");

        vm.startPrank(backend);
        registry.addMarket(assetA, mToken, MarketType.MTOKEN);
        registry.addMarket(assetB, vault, MarketType.ERC4626);

        // Deactivating in assetA doesn't affect assetB
        registry.deactivateMarket(assetA, mToken);
        vm.stopPrank();

        assertFalse(registry.isMarketActive(assetA, mToken));
        assertTrue(registry.isMarketActive(assetB, vault));

        // assetB still has 1 market, assetA still has 1 (just inactive)
        assertEq(registry.getMarketCount(assetA), 1);
        assertEq(registry.getMarketCount(assetB), 1);
    }
}
