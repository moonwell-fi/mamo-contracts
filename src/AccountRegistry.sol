// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title AccountRegistry
 * @notice Manages caller whitelist for the staking system
 * @dev Provides two-tier strategy approval system
 */
contract AccountRegistry is AccessControlEnumerable, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Backend role for strategy approval
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Guardian role for emergency pause functionality
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Mapping of account to whitelisted strategies
    mapping(address => mapping(address => bool)) public isWhitelistedStrategy;

    /// @notice Mapping of backend-approved strategies
    mapping(address => bool) public approvedStrategies;

    event StrategyWhitelisted(address indexed account, address indexed strategy, bool approved);
    event StrategyApproved(address indexed strategy, bool approved);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Constructor that sets up initial roles
     * @param admin The address to grant the DEFAULT_ADMIN_ROLE to
     * @param backend The address to grant the BACKEND_ROLE to
     * @param guardian The address to grant the GUARDIAN_ROLE to
     */
    constructor(address admin, address backend, address guardian) {
        require(admin != address(0), "Invalid admin address");
        require(backend != address(0), "Invalid backend address");
        require(guardian != address(0), "Invalid guardian address");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    /**
     * @notice Whitelist an approved strategy for a specific account (account owner only)
     * @param account The account address
     * @param strategy The strategy address to whitelist
     * @param approved Whether to approve or revoke the strategy
     */
    function setWhitelistStrategy(address account, address strategy, bool approved) external whenNotPaused {
        // msg.sender must be the account owner
        require(Ownable(account).owner() == msg.sender, "Not account owner");
        // Strategy must be approved by backend first
        require(approvedStrategies[strategy], "Strategy not approved by backend");
        isWhitelistedStrategy[account][strategy] = approved;
        emit StrategyWhitelisted(account, strategy, approved);
    }

    // ==================== ADMIN FUNCTIONS ====================
    /**
     * @notice Approve a strategy globally (backend only)
     * @param strategy The strategy address to approve
     * @param approved Whether to approve or revoke the strategy
     */
    function setApprovedStrategy(address strategy, bool approved) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(strategy != address(0), "Invalid strategy");
        approvedStrategies[strategy] = approved;
        emit StrategyApproved(strategy, approved);
    }

    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @dev Only callable by the user who owns this strategy
     * @param tokenAddress The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address tokenAddress, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(tokenAddress).safeTransfer(to, amount);

        emit TokenRecovered(tokenAddress, to, amount);
    }

    // ==================== GUARDIAN FUNCTIONS ====================

    /**
     * @notice Pauses the contract in case of emergency
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract after an emergency is resolved
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
