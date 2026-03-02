// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MarketRegistry
 * @notice Centralized registry for market definitions per strategyTypeId
 * @dev Markets are append-only (indices are stable). Deactivation is a soft-delete.
 *      Same access control pattern as MamoStrategyRegistry.
 */
contract MarketRegistry is IMarketRegistry, AccessControlEnumerable, Pausable {
    /// @notice Role identifier for guardians who can pause/unpause
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Role identifier for the backend that can manage markets
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Maximum number of markets per strategyTypeId
    uint256 public constant MAX_MARKETS = 10;

    /// @notice Markets per strategyTypeId (append-only)
    mapping(uint256 => RegistryMarket[]) private _markets;

    // Events
    event MarketAdded(uint256 indexed strategyTypeId, uint256 indexed marketIndex, address target, MarketType marketType);
    event MarketDeactivated(uint256 indexed strategyTypeId, uint256 indexed marketIndex, address target);

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
    function addMarket(uint256 strategyTypeId, address target, MarketType marketType)
        external
        onlyRole(BACKEND_ROLE)
        whenNotPaused
    {
        require(strategyTypeId != 0, "Invalid strategy type id");
        require(target != address(0), "Invalid market target");
        require(_markets[strategyTypeId].length < MAX_MARKETS, "Too many markets");

        _markets[strategyTypeId].push(RegistryMarket({target: target, marketType: marketType, active: true}));

        uint256 marketIndex = _markets[strategyTypeId].length - 1;
        emit MarketAdded(strategyTypeId, marketIndex, target, marketType);
    }

    /// @inheritdoc IMarketRegistry
    function deactivateMarket(uint256 strategyTypeId, uint256 marketIndex)
        external
        onlyRole(BACKEND_ROLE)
        whenNotPaused
    {
        require(marketIndex < _markets[strategyTypeId].length, "Invalid market index");
        require(_markets[strategyTypeId][marketIndex].active, "Market already inactive");

        _markets[strategyTypeId][marketIndex].active = false;

        emit MarketDeactivated(strategyTypeId, marketIndex, _markets[strategyTypeId][marketIndex].target);
    }

    // ==================== VIEW FUNCTIONS ====================

    /// @inheritdoc IMarketRegistry
    function getMarkets(uint256 strategyTypeId) external view returns (RegistryMarket[] memory) {
        return _markets[strategyTypeId];
    }

    /// @inheritdoc IMarketRegistry
    function getMarketCount(uint256 strategyTypeId) external view returns (uint256) {
        return _markets[strategyTypeId].length;
    }

    /// @inheritdoc IMarketRegistry
    function isMarketActive(uint256 strategyTypeId, uint256 marketIndex) external view returns (bool) {
        require(marketIndex < _markets[strategyTypeId].length, "Invalid market index");
        return _markets[strategyTypeId][marketIndex].active;
    }

    /// @inheritdoc IMarketRegistry
    function getMarket(uint256 strategyTypeId, uint256 marketIndex) external view returns (RegistryMarket memory) {
        require(marketIndex < _markets[strategyTypeId].length, "Invalid market index");
        return _markets[strategyTypeId][marketIndex];
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
