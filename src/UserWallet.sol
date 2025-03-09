// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title UserWallet
 * @notice This contract holds user funds and interacts with strategies
 * @dev It's deployed by the MamoCore using CREATE2 and it's upgradeable through a UUPS proxy pattern
 */
contract UserWallet is Ownable, UUPSUpgradeable {
    // The Mamo Core contract address
    address public immutable mamoCore;
    
    // Mapping of strategies that the user has approved
    mapping(address => bool) public approvedStrategies;
    
    // Events
    event StrategyApprovalChanged(address indexed strategy, bool approved);
    event FundsWithdrawn(address indexed token, uint256 amount);
    event PositionUpdated(address indexed strategy, uint256 splitA, uint256 splitB);
    event RewardsClaimed(address indexed strategy);
    
    /**
     * @dev Modifier to ensure only the Mamo Core contract can call a function
     */
    modifier onlyMamoCore() {
        require(msg.sender == mamoCore, "Only Mamo Core can call this function");
        _;
    }
    
    /**
     * @dev Constructor sets the Mamo Core address and transfers ownership to the user
     * @param _owner The owner of this contract (the user)
     * @param _mamoCore The Mamo Core contract address
     */
    constructor(address _owner, address _mamoCore) Ownable(_owner) {
        mamoCore = _mamoCore;
    }
    
    /**
     * @notice Sets the approval status of a strategy
     * @param strategy The address of the strategy
     * @param approved True to approve the strategy, false to disapprove
     */
    function setStrategyApproval(address strategy, bool approved) external onlyOwner {
        // If disapproving, check that the strategy was previously approved
        if (!approved && !approvedStrategies[strategy]) {
            revert("Strategy not approved");
        }
        
        approvedStrategies[strategy] = approved;
        emit StrategyApprovalChanged(strategy, approved);
    }
    
    /**
     * @notice Checks if a strategy is approved
     * @param strategy The address of the strategy to check
     * @return True if the strategy is approved, false otherwise
     */
    function isStrategyApproved(address strategy) external view returns (bool) {
        return approvedStrategies[strategy];
    }
    
    /**
     * @notice Withdraws funds from the contract to the owner
     * @param token The address of the token to withdraw
     * @param amount The amount of tokens to withdraw
     */
    function withdrawFunds(address token, uint256 amount) external onlyOwner {
        // Ensure the contract has enough balance
        require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient balance");
        
        // Transfer tokens to the owner
        require(IERC20(token).transfer(owner(), amount), "Transfer failed");
        
        emit FundsWithdrawn(token, amount);
    }
    
    /**
     * @notice Updates the position in a strategy with specified split parameters
     * @dev Only callable by the Mamo Core
     * @param strategy The address of the strategy to update
     * @param splitA The first split parameter (basis points)
     * @param splitB The second split parameter (basis points)
     */
    function updatePosition(address strategy, uint256 splitA, uint256 splitB) external onlyMamoCore {
        require(approvedStrategies[strategy], "Strategy not approved");
        
        // Make a delegateCall to the strategy contract to execute the actual position update logic
        (bool success, bytes memory result) = strategy.delegatecall(
            abi.encodeWithSignature("updateStrategy(uint256,uint256)", splitA, splitB)
        );
        
        require(success, "Strategy update failed");
        
        emit PositionUpdated(strategy, splitA, splitB);
    }
    
    /**
     * @notice Claims all available rewards from the strategy
     * @dev Only callable by the Mamo Core or the owner
     * @param strategy The address of the strategy to claim rewards from
     */
    function claimRewards(address strategy) external {
        require(msg.sender == mamoCore || msg.sender == owner(), "Only Mamo Core or owner can call this function");
        require(approvedStrategies[strategy], "Strategy not approved");
        
        // Make a delegateCall to the strategy contract to execute the actual reward claiming logic
        (bool success, bytes memory result) = strategy.delegatecall(
            abi.encodeWithSignature("claimRewards()")
        );
        
        require(success, "Reward claiming failed");
        
        emit RewardsClaimed(strategy);
    }
    
    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only callable by the owner
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Additional validation could be added here if needed
    }
}
