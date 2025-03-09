// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title USDCStrategyStorage
 * @notice Storage contract for the USDCStrategy
 */
contract USDCStrategyStorage {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    // Constant for split calculations (10,000 basis points = 100%)
    uint256 public constant SPLIT_TOTAL = 10000;

    // Moonwell Comptroller contract address
    address public immutable moonwellComptroller;
    
    // Moonwell USDC mToken contract address
    address public immutable moonwellUSDC;
    
    // MetaMorpho Vault contract address
    address public immutable metaMorphoVault;
   
    // MamoCore contract address
    address public immutable mamoCore;

    // USDC token interface
    IERC20 public immutable usdc;
    
    // Admin address that can recover tokens and set DEX router
    address public admin;

    // DEX router for swapping reward tokens to USDC
    address public dexRouter;

    // Set of reward token addresses
    EnumerableSet.AddressSet private _rewardTokens;
    
    // Events
    event StrategyUpdated(address indexed user, uint256 totalAmount, uint256 splitA, uint256 splitB);
    event RewardsHarvested(address indexed user, uint256 totalConverted);
    event FundsWithdrawn(address indexed user, uint256 amount);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event RewardTokenAdded(address indexed token);
    event RewardTokenRemoved(address indexed token);
    
    /**
     * @notice Constructor initializes the storage contract with the necessary values
     * @param _moonwellComptroller The address of the Moonwell Comptroller contract
     * @param _moonwellUSDC The address of the Moonwell USDC mToken contract
     * @param _metaMorphoVault The address of the MetaMorpho Vault contract
     * @param _dexRouter The address of the DEX router for swapping reward tokens to USDC
     * @param _mamoCore The address of the MamoCore contract
     * @param _admin The address of the admin who can recover tokens and set DEX router
     * @param _usdc The address of the USDC token
     * @param _initialRewardTokens An array of initial reward token addresses
     */
    constructor(
        address _moonwellComptroller,
        address _moonwellUSDC,
        address _metaMorphoVault,
        address _dexRouter,
        address _mamoCore,
        address _admin,
        address _usdc,
        address[] memory _initialRewardTokens
    ) {
        require(_moonwellComptroller != address(0), "Invalid Moonwell Comptroller address");
        require(_moonwellUSDC != address(0), "Invalid Moonwell USDC address");
        require(_metaMorphoVault != address(0), "Invalid MetaMorpho Vault address");
        require(_dexRouter != address(0), "Invalid DEX router address");
        require(_mamoCore != address(0), "Invalid MamoCore address");
        require(_admin != address(0), "Invalid admin address");
        require(_usdc != address(0), "Invalid USDC address");
        
        moonwellComptroller = _moonwellComptroller;
        moonwellUSDC = _moonwellUSDC;
        metaMorphoVault = _metaMorphoVault;
        dexRouter = _dexRouter;
        mamoCore = _mamoCore;
        admin = _admin;
        usdc = IERC20(_usdc);
        
        // Add initial reward tokens
        for (uint256 i = 0; i < _initialRewardTokens.length; i++) {
            if (_initialRewardTokens[i] != address(0)) {
                _rewardTokens.add(_initialRewardTokens[i]);
                emit RewardTokenAdded(_initialRewardTokens[i]);
            }
        }
    }
    
    /**
     * @notice Modifier to ensure only the admin can call a function
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }
    
    /**
     * @notice Gets a reward token at a specific index
     * @param index The index of the reward token
     * @return The address of the reward token
     */
    function getRewardToken(uint256 index) external view returns (address) {
        require(index < _rewardTokens.length(), "Index out of bounds");
        return _rewardTokens.at(index);
    }
    
    /**
     * @notice Gets the number of reward tokens
     * @return The number of reward tokens
     */
    function getRewardTokensLength() external view returns (uint256) {
        return _rewardTokens.length();
    }
    
    /**
     * @notice Checks if a token is in the reward tokens set
     * @param token The address of the token to check
     * @return True if the token is a reward token, false otherwise
     */
    function isRewardToken(address token) external view returns (bool) {
        return _rewardTokens.contains(token);
    }
    
    /**
     * @notice Gets all reward tokens
     * @return An array of all reward token addresses
     */
    function getAllRewardTokens() external view returns (address[] memory) {
        uint256 length = _rewardTokens.length();
        address[] memory tokens = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = _rewardTokens.at(i);
        }
        
        return tokens;
    }
    
    /**
     * @notice Sets a new DEX router address
     * @param _newDexRouter The address of the new DEX router
     */
    function setDexRouter(address _newDexRouter) external onlyAdmin {
        require(_newDexRouter != address(0), "Invalid DEX router address");
        
        address oldDexRouter = dexRouter;
        dexRouter = _newDexRouter;
        
        emit DexRouterUpdated(oldDexRouter, _newDexRouter);
    }
    
    /**
     * @notice Sets a new admin address
     * @param _newAdmin The address of the new admin
     */
    function setAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Invalid admin address");
        
        address oldAdmin = admin;
        admin = _newAdmin;
        
        emit AdminChanged(oldAdmin, _newAdmin);
    }
    
    /**
     * @notice Updates the reward tokens set by adding or removing a token
     * @param token The address of the token to add or remove
     * @param add True to add the token, false to remove it
     * @return True if the operation was successful, false otherwise
     */
    function updateRewardToken(address token, bool add) external onlyAdmin returns (bool) {
        if (add) {
            require(token != address(0), "Invalid token address");
            
            bool added = _rewardTokens.add(token);
            if (added) {
                emit RewardTokenAdded(token);
            }
            
            return added;
        } else {
            bool removed = _rewardTokens.remove(token);
            if (removed) {
                emit RewardTokenRemoved(token);
            }
            
            return removed;
        }
    }
    
    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @param token The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20(token).transfer(to, amount);
        
        emit TokenRecovered(token, to, amount);
    }

    // TODO add recoverETH
}
