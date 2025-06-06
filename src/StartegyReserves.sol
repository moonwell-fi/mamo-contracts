// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStrategy} from "@interfaces/IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IStrategyWithOwnership
 * @notice Interface for strategy contracts with ownership functionality
 * @dev Extends IStrategy with ownership methods from Ownable
 */
interface IStrategyWithOwnership is IStrategy {
    /**
     * @notice Transfers ownership of the strategy to a new owner
     * @param newOwner The address to transfer ownership to
     */
    function transferOwnership(address newOwner) external;

    function owner() external view returns (address);
}

/**
 * @title StrategyFactory
 * @notice Factory contract for managing a pool of strategies that users can claim
 * @dev Maintains a list of strategies owned by the factory that users can claim by depositing USDC
 */
contract StrategyFactory is Ownable {
    using SafeERC20 for IERC20;

    /// @notice The USDC token contract
    IERC20 public immutable usdc;

    /// @notice Array of available strategies
    address[] public strategies;

    /// @notice Emitted when a strategy is added to the factory
    event StrategyAdded(address indexed strategy);

    /// @notice Emitted when a strategy is claimed by a user
    event StrategyClaimed(address indexed user, address indexed strategy, uint256 amount);

    /**
     * @notice Constructor that initializes the factory with USDC token address
     * @param _usdc Address of the USDC token
     * @param _owner Address of the factory owner
     */
    constructor(address _usdc, address _owner) Ownable(_owner) {
        require(_usdc != address(0), "Invalid USDC address");
        usdc = IERC20(_usdc);
    }

    /**
     * @notice Adds a strategy to the available pool
     * @dev The factory must be the owner of the strategy when adding
     * @param strategy The address of the strategy to add
     */
    function add(address strategy) external onlyOwner {
        require(strategy != address(0), "Invalid strategy address");

        IStrategyWithOwnership strategyContract = IStrategyWithOwnership(strategy);

        // Verify that this contract is the owner of the strategy
        require(strategyContract.owner() == address(this), "Factory must be the owner of the strategy");

        strategies.push(strategy);

        emit StrategyAdded(strategy);
    }

    /**
     * @notice Claims a strategy from the pool by depositing USDC
     * @dev Pops the last strategy from the list, transfers USDC from caller to contract,
     *      transfers ownership to caller, deposits USDC, and verifies ownership transfer
     * @param amount The amount of USDC to deposit (in USDC's native decimals, typically 6)
     */
    function claim(uint256 amount) external {
        // Check that we have available strategies
        require(strategies.length > 0, "No strategies available");
        // Require at least 1 USDC (6 decimals)
        require(amount >= 1e6, "Amount must be at least 1 USDC");

        // Pop the last strategy from the list
        address strategyAddress = strategies[strategies.length - 1];
        strategies.pop();

        IStrategyWithOwnership strategy = IStrategyWithOwnership(strategyAddress);

        // Transfer USDC from msg.sender to this contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Transfer ownership of the strategy to msg.sender
        strategy.transferOwnership(msg.sender);

        // Approve the strategy to spend USDC for the deposit
        usdc.forceApprove(strategyAddress, amount);

        // Call deposit on the strategy
        strategy.deposit(address(usdc), amount);

        // Confirm that the owner of the strategy is now msg.sender
        require(strategy.owner() == msg.sender, "Ownership transfer failed");

        emit StrategyClaimed(msg.sender, strategyAddress, amount);
    }

    /**
     * @notice Returns the number of available strategies
     * @return The count of strategies in the pool
     */
    function getAvailableStrategiesCount() external view returns (uint256) {
        return strategies.length;
    }

    /**
     * @notice Returns all available strategy addresses
     * @return Array of strategy addresses
     */
    function getAvailableStrategies() external view returns (address[] memory) {
        return strategies;
    }

    /**
     * @notice Emergency function to recover ERC20 tokens sent to this contract
     * @dev Only callable by the owner
     * @param token The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Emergency function to recover ETH sent to this contract
     * @dev Only callable by the owner
     * @param to The address to send the ETH to
     */
    function recoverETH(address payable to) external onlyOwner {
        require(to != address(0), "Cannot send to zero address");

        uint256 balance = address(this).balance;
        require(balance > 0, "Empty balance");

        (bool success,) = to.call{value: balance}("");
        require(success, "Transfer failed");
    }

    /**
     * @notice Allows the contract to receive ETH
     */
    receive() external payable {}
}
