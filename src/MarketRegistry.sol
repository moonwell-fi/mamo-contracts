// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MarketRegistry
 * @notice Centralized registry for market definitions per asset address
 * @dev Markets are append-only (indices are stable for enumeration). Deactivation is a soft-delete.
 *      External API is address-based. Internal array provides enumeration for strategies.
 *      Same access control pattern as MamoStrategyRegistry.
 */
contract MarketRegistry is IMarketRegistry, AccessControlEnumerable, Pausable {
    /// @notice Role identifier for guardians who can pause/unpause
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Role identifier for the backend that can manage markets
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Maximum number of markets per asset
    uint256 public constant MAX_MARKETS = 10;

    /// @notice Markets per asset address (append-only array for enumeration)
    mapping(address => RegistryMarket[]) private _markets;

    /// @notice Address-to-index lookup: asset => target => array index + 1 (0 means not registered)
    mapping(address => mapping(address => uint256)) private _marketIndex;

    // Events
    event MarketAdded(address indexed asset, address indexed target, MarketType marketType);
    event MarketDeactivated(address indexed asset, address indexed target);

    constructor(address admin, address backend, address guardian) {
        require(admin != address(0), "Invalid admin address");
        require(backend != address(0), "Invalid backend address");
        require(guardian != address(0), "Invalid guardian address");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ==================== BACKEND FUNCTIONS ====================

    /// @inheritdoc IMarketRegistry
    function addMarket(address asset, address target, MarketType marketType)
        external
        onlyRole(BACKEND_ROLE)
        whenNotPaused
    {
        require(asset != address(0), "Invalid asset address");
        require(target != address(0), "Invalid market target");
        require(_markets[asset].length < MAX_MARKETS, "Too many markets");
        require(_marketIndex[asset][target] == 0, "Market already registered");

        _markets[asset].push(RegistryMarket({target: target, marketType: marketType, active: true}));

        // Store index + 1 (so 0 means "not registered")
        _marketIndex[asset][target] = _markets[asset].length;

        emit MarketAdded(asset, target, marketType);
    }

    /// @inheritdoc IMarketRegistry
    function deactivateMarket(address asset, address target) external onlyRole(BACKEND_ROLE) whenNotPaused {
        uint256 indexPlusOne = _marketIndex[asset][target];
        require(indexPlusOne != 0, "Market not registered");

        uint256 index = indexPlusOne - 1;
        require(_markets[asset][index].active, "Market already inactive");

        _markets[asset][index].active = false;

        emit MarketDeactivated(asset, target);
    }

    // ==================== VIEW FUNCTIONS ====================

    /// @inheritdoc IMarketRegistry
    function getMarkets(address asset) external view returns (RegistryMarket[] memory) {
        return _markets[asset];
    }

    /// @inheritdoc IMarketRegistry
    function getMarketCount(address asset) external view returns (uint256) {
        return _markets[asset].length;
    }

    /// @inheritdoc IMarketRegistry
    function isMarketActive(address asset, address target) external view returns (bool) {
        uint256 indexPlusOne = _marketIndex[asset][target];
        require(indexPlusOne != 0, "Market not registered");
        return _markets[asset][indexPlusOne - 1].active;
    }

    /// @inheritdoc IMarketRegistry
    function getMarket(address asset, address target) external view returns (RegistryMarket memory) {
        uint256 indexPlusOne = _marketIndex[asset][target];
        require(indexPlusOne != 0, "Market not registered");
        return _markets[asset][indexPlusOne - 1];
    }

    // ==================== GUARDIAN FUNCTIONS ====================

    /// @inheritdoc IMarketRegistry
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @inheritdoc IMarketRegistry
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
