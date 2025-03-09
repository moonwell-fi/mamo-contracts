// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UserWallet} from "./UserWallet.sol";
import {IUserWallet} from "./interfaces/IUserWallet.sol";

/**
 * @title MamoCore
 * @notice This contract is responsible for deploying user wallet contracts, tracking user wallet contracts,
 * moving funds/positions, and interacting with strategies
 * @dev It's upgradeable through a UUPS pattern, with only the owner able to perform upgrades.
 */
contract MamoCore is Ownable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Private state variables using the EnumerableSet library
    EnumerableSet.AddressSet private _userWallets;
    EnumerableSet.AddressSet private _strategies;

    // Events
    event WalletCreated(address indexed user, address wallet);
    event Deposited(address indexed user, address indexed wallet, address asset, address strategy, uint256 amount);
    event StrategiesUpdated(address indexed strategy, address[] wallets, uint256 splitA, uint256 splitB);
    event RewardsClaimed(address indexed strategy, address[] wallets);

    constructor() Ownable(msg.sender) {
    }

    /**
     * @notice User deposits funds. If the user has not granted permission to the strategy, it will revert.
     * @dev User must pre-approve the contract with the asset token.
     * @param asset The address of the token being deposited
     * @param strategy The address of the strategy to use
     * @param amount The amount of tokens to deposit
     * @return The address of the user's wallet (either existing or newly created)
     */
    function deposit(address asset, address strategy, uint256 amount) external returns (address) {
        // Check if the strategy is valid
        require(_strategies.contains(strategy), "Strategy not found");
        
        // Get or create user wallet
        address userWallet = getUserWallet(msg.sender);
        
        // Check if the user has granted permission to the strategy
        require(IUserWallet(userWallet).isStrategyApproved(strategy), "Strategy not approved");
        
        // Transfer tokens from user to their wallet
        require(IERC20(asset).transferFrom(msg.sender, userWallet, amount), "Transfer failed");
        
        emit Deposited(msg.sender, userWallet, asset, strategy, amount);
        
        return userWallet;
    }
    
    /**
     * @notice Gets the user's wallet address or creates a new one if it doesn't exist
     * @param user The address of the user
     * @return The address of the user's wallet
     */
    function getUserWallet(address user) public returns (address) {
        // Check if user already has a wallet
        address userWallet = computeWalletAddress(user);
        
        // If wallet doesn't exist in our set, deploy it
        if (!_userWallets.contains(userWallet)) {
            // Deploy wallet using CREATE2
            bytes memory bytecode = getWalletBytecode(user);
            bytes32 salt = keccak256(abi.encodePacked(user));
            
            userWallet = Create2.deploy(0, salt, bytecode);
            
            // Add wallet to our set
            _userWallets.add(userWallet);
            
            emit WalletCreated(user, userWallet);
        }
        
        return userWallet;
    }
    
    /**
     * @notice Computes the deterministic address for a user's wallet
     * @param user The address of the user
     * @return The computed address of the user's wallet
     */
    function computeWalletAddress(address user) public view returns (address) {
        bytes memory bytecode = getWalletBytecode(user);
        bytes32 salt = keccak256(abi.encodePacked(user));
        return Create2.computeAddress(salt, keccak256(bytecode));
    }
    
    /**
     * @notice Gets the bytecode for a new user wallet
     * @param user The address of the user (wallet owner)
     * @return The bytecode for the wallet contract
     */
    function getWalletBytecode(address user) internal view returns (bytes memory) {
        // In a real implementation, we would create the bytecode for the UserWallet contract
        // including constructor parameters for the user (owner) and this contract (mamoCore)
        
        // Get the bytecode of the UserWallet contract
        bytes memory bytecode = type(UserWallet).creationCode;
        
        // Encode the constructor parameters
        bytes memory constructorArgs = abi.encode(user, address(this));
        
        // Combine the bytecode and constructor arguments
        return abi.encodePacked(bytecode, constructorArgs);
    }
    
    /**
     * @notice Adds a new strategy
     * @param strategy The address of the strategy to add
     */
    function addStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "Invalid strategy address");
        require(_strategies.add(strategy), "Strategy already exists");
    }
    
    /**
     * @notice Removes a strategy
     * @param strategy The address of the strategy to remove
     */
    function removeStrategy(address strategy) external onlyOwner {
        require(_strategies.contains(strategy), "Strategy not found");
        require(_strategies.remove(strategy), "Failed to remove strategy");
    }
    
    /**
     * @notice Checks if a wallet is managed by Mamo
     * @param wallet The address of the wallet to check
     * @return True if the wallet is managed by Mamo, false otherwise
     */
    function isUserWallet(address wallet) external view returns (bool) {
        return _userWallets.contains(wallet);
    }
    
    /**
     * @notice Checks if a strategy is valid
     * @param strategy The address of the strategy to check
     * @return True if the strategy is valid, false otherwise
     */
    function isValidStrategy(address strategy) external view returns (bool) {
        return _strategies.contains(strategy);
    }
    
    /**
     * @notice Updates a single strategy for multiple users at once
     * @dev Only callable by the owner
     * @param strategy The address of the strategy to update
     * @param wallets Array of wallet addresses to update
     * @param splitA The first split parameter (basis points)
     * @param splitB The second split parameter (basis points)
     * @return True if the update was successful
     */
    function updateUsersStrategies(
        address strategy,
        address[] calldata wallets,
        uint256 splitA,
        uint256 splitB
    ) external onlyOwner returns (bool) {
        // Validate strategy exists
        require(_strategies.contains(strategy), "Strategy not found");
        
        // Validate wallets and update positions
        for (uint256 i = 0; i < wallets.length; i++) {
            address wallet = wallets[i];
            
            // Validate wallet is managed by Mamo
            require(_userWallets.contains(wallet), "Wallet not managed by Mamo");
            
            // Validate strategy is approved by the wallet
            require(IUserWallet(wallet).isStrategyApproved(strategy), "Strategy not approved by wallet");
            
            // Update position
            IUserWallet(wallet).updatePosition(strategy, splitA, splitB);
        }
        
        emit StrategiesUpdated(strategy, wallets, splitA, splitB);
        
        return true;
    }
    
    /**
     * @notice Claims rewards from the specified strategy for multiple users at once
     * @dev Only callable by the owner
     * @param strategy The address of the strategy to claim rewards from
     * @param wallets Array of wallet addresses to claim rewards for
     */
    function claimRewardsForUsers(
        address strategy,
        address[] calldata wallets
    ) external onlyOwner {
        // Validate strategy exists
        require(_strategies.contains(strategy), "Strategy not found");
        
        // Validate wallets and claim rewards
        for (uint256 i = 0; i < wallets.length; i++) {
            address wallet = wallets[i];
            
            // Validate wallet is managed by Mamo
            require(_userWallets.contains(wallet), "Wallet not managed by Mamo");
            
            // Claim rewards
            IUserWallet(wallet).claimRewards(strategy);
        }
        
        emit RewardsClaimed(strategy, wallets);
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
