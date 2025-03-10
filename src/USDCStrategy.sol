// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMToken} from "./interfaces/IMToken.sol";

/**
 * @title USDCStrategy
 * @notice A strategy contract for USDC that splits deposits between Moonwell core market and Moonwell Vaults
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract USDCStrategy is Initializable {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant SPLIT_TOTAL = 10000; // 100% in basis points

    // State variables
    address public owner;
    address public mamoCore;
    address public moonwellComptroller;
    address public moonwellUSDC;
    address public metaMorphoVault;
    address public dexRouter;
    address public usdc;

    // Events
    event Deposit(address indexed asset, uint256 amount);
    event Withdraw(address indexed asset, uint256 amount);
    event PositionUpdated(uint256 splitA, uint256 splitB);
    event RewardsClaimed(uint256 amount);
    event DexRouterUpdated(address indexed oldDexRouter, address indexed newDexRouter);

    /**
     * @notice Initializer function that sets all the parameters
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param _owner The owner of this strategy (the user)
     * @param _mamoCore The MamoCore contract address
     * @param _moonwellComptroller The Moonwell Comptroller contract address
     * @param _moonwellUSDC The Moonwell USDC mToken contract address
     * @param _metaMorphoVault The MetaMorpho Vault contract address
     * @param _dexRouter The DEX router for swapping reward tokens
     * @param _usdc The USDC token address
     */
    function initialize(
        address _owner,
        address _mamoCore,
        address _moonwellComptroller,
        address _moonwellUSDC,
        address _metaMorphoVault,
        address _dexRouter,
        address _usdc
    ) external initializer {
        require(_owner != address(0), "Invalid owner address");
        require(_mamoCore != address(0), "Invalid mamoCore address");
        require(_moonwellComptroller != address(0), "Invalid moonwellComptroller address");
        require(_moonwellUSDC != address(0), "Invalid moonwellUSDC address");
        require(_metaMorphoVault != address(0), "Invalid metaMorphoVault address");
        require(_dexRouter != address(0), "Invalid dexRouter address");
        require(_usdc != address(0), "Invalid usdc address");

        owner = _owner;
        mamoCore = _mamoCore;
        moonwellComptroller = _moonwellComptroller;
        moonwellUSDC = _moonwellUSDC;
        metaMorphoVault = _metaMorphoVault;
        dexRouter = _dexRouter;
        usdc = _usdc;
    }

    /**
     * @notice Updates the DEX router address
     * @dev Only callable by the MamoCore contract
     * @param _newDexRouter The new DEX router address
     */
    function setDexRouter(address _newDexRouter) external {
        require(msg.sender == mamoCore, "Only MamoCore can call this function");
        require(_newDexRouter != address(0), "Invalid dexRouter address");
        
        address oldDexRouter = dexRouter;
        dexRouter = _newDexRouter;
        
        emit DexRouterUpdated(oldDexRouter, _newDexRouter);
    }

    /**
     * @notice Deposits funds into the strategy
     * @dev Only callable by the owner
     * @param asset The address of the asset to deposit
     * @param amount The amount to deposit
     */
    function deposit(address asset, uint256 amount) external {
        require(msg.sender == owner, "Only owner can deposit");
        require(asset == usdc, "Only USDC deposits are supported");
        require(amount > 0, "Amount must be greater than 0");

        // Transfer USDC from the owner to this contract
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);

        // Approve and deposit into Moonwell and MetaMorpho based on the current split
        // This is a simplified implementation
        
        emit Deposit(asset, amount);
    }

    /**
     * @notice Withdraws funds from the strategy
     * @dev Only callable by the owner
     * @param asset The address of the asset to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address asset, uint256 amount) external {
        require(msg.sender == owner, "Only owner can withdraw");
        require(asset == usdc, "Only USDC withdrawals are supported");
        require(amount > 0, "Amount must be greater than 0");

        // Withdraw from Moonwell and MetaMorpho based on the current balances
        // This is a simplified implementation
        
        // Transfer USDC to the owner
        IERC20(usdc).safeTransfer(owner, amount);
        
        emit Withdraw(asset, amount);
    }

    /**
     * @notice Updates the position in the strategy
     * @dev Only callable by the MamoCore contract
     * @param splitA The first split parameter (basis points)
     * @param splitB The second split parameter (basis points)
     */
    function updatePosition(uint256 splitA, uint256 splitB) external {
        require(msg.sender == mamoCore, "Only MamoCore can call this function");
        require(splitA + splitB == SPLIT_TOTAL, "Split parameters must add up to SPLIT_TOTAL");

        // Rebalance between Moonwell and MetaMorpho based on the new split
        // This is a simplified implementation
        
        emit PositionUpdated(splitA, splitB);
    }

    /**
     * @notice Claims all available rewards from both Moonwell and Morpho and converts them to USDC
     * @dev Callable by the owner or MamoCore
     */
    function claimRewards() external {
        require(msg.sender == owner || msg.sender == mamoCore, "Only owner or MamoCore can claim rewards");

        // Claim rewards from Moonwell and MetaMorpho
        // This is a simplified implementation
        
        // Convert rewards to USDC using the DEX router
        // This is a simplified implementation
        
        emit RewardsClaimed(0); // Replace with actual amount
    }

}
