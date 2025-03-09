// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IMamoCore} from "./interfaces/IMamoCore.sol";
import {IDEXRouter} from "./interfaces/IDEXRouter.sol";

/**
 * @title USDCStrategy
 * @notice A specific implementation of a Strategy Contract for USDC that splits deposits between Moonwell core market and Moonwell Vaults
 */
contract USDCStrategy {
    using SafeERC20 for IERC20;

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
    
    // Admin address that can recover tokens and set DEX router
    address public admin;

    // USDC token interface
    IERC20 public immutable usdc;

    // DEX router for swapping reward tokens to USDC
    address public dexRouter;

    // Array of reward token addresses
    address[] public rewardTokens;

    // Events
    event StrategyUpdated(address indexed user, uint256 totalAmount, uint256 splitA, uint256 splitB);
    event RewardsHarvested(address indexed user, uint256 totalConverted);
    event FundsWithdrawn(address indexed user, uint256 amount);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    
    /**
     * @notice Constructor initializes the strategy with the necessary contract addresses
     * @param _moonwellComptroller The address of the Moonwell Comptroller contract
     * @param _moonwellUSDC The address of the Moonwell USDC mToken contract
     * @param _metaMorphoVault The address of the MetaMorpho Vault contract
     * @param _dexRouter The address of the DEX router for swapping reward tokens to USDC
     * @param _mamoCore The address of the MamoCore contract
     * @param _admin The address of the admin who can recover tokens and set DEX router
     * @param _rewardTokens An array of reward token addresses
     */
    constructor(
        address _moonwellComptroller,
        address _moonwellUSDC,
        address _metaMorphoVault,
        address _dexRouter,
        address _mamoCore,
        address _admin,
        address[] memory _rewardTokens
    ) {
        moonwellComptroller = _moonwellComptroller;
        moonwellUSDC = _moonwellUSDC;
        metaMorphoVault = _metaMorphoVault;
        dexRouter = _dexRouter;
        mamoCore = _mamoCore;
        admin = _admin;
        rewardTokens = _rewardTokens;
        
        // Get the underlying USDC token from the Moonwell USDC mToken
        address usdcAddress = IMToken(moonwellUSDC).underlying();
        usdc = IERC20(usdcAddress);
        
        // Verify that the MetaMorpho Vault's asset matches the USDC token address
        require(IERC4626(metaMorphoVault).asset() == usdcAddress, "MetaMorpho Vault asset must be USDC");
    }
    
    /**
     * @notice Claims all available rewards from both Moonwell and Morpho and converts them to USDC
     */
    function claimRewards() external {
        // This function is called via delegatecall from the UserWallet contract
        // So 'address(this)' refers to the UserWallet contract
        
        uint256 totalConverted = 0;
        
        // Claim Moonwell rewards
        // Check if the user has any existing positions in Moonwell markets
        uint256 mTokenBalance = IERC20(moonwellUSDC).balanceOf(address(this));
        if (mTokenBalance > 0) {
            // Claim rewards from the Moonwell Comptroller for the user
            // In a real implementation, you would call the claimReward function on the Moonwell Comptroller
            // For simplicity, we'll just simulate it here
            
            // For each Moonwell reward token, check if any rewards were received
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                address rewardToken = rewardTokens[i];
                
                // Get the reward token balance before and after claiming
                uint256 balanceBefore = IERC20(rewardToken).balanceOf(address(this));
                
                // Claim rewards (simulated)
                // IMoonwellComptroller(moonwellComptroller).claimReward(address(this), rewardToken);
                
                uint256 balanceAfter = IERC20(rewardToken).balanceOf(address(this));
                uint256 rewardAmount = balanceAfter - balanceBefore;
                
                if (rewardAmount > 0) {
                    // Approve the DEX router to spend the reward tokens
                    IERC20(rewardToken).approve(dexRouter, rewardAmount);
                    
                    // Swap the reward tokens for USDC using the DEX router
                    // In a real implementation, you would call the swap function on the DEX router
                    // For simplicity, we'll just simulate it here
                    
                    // uint256 usdcReceived = IDEXRouter(dexRouter).swapExactTokensForTokens(
                    //     rewardAmount,
                    //     0,
                    //     path,
                    //     address(this),
                    //     block.timestamp
                    // );
                    
                    // Simulated USDC received (in a real implementation, this would be the actual amount)
                    uint256 usdcReceived = rewardAmount;
                    
                    totalConverted += usdcReceived;
                }
            }
        }
        
        // Morpho rewards
        // Morpho implements a permissionless reward claiming system
        // The Mamo server will handle claiming Morpho rewards externally
        // When this function is called, we check if there are any MORPHO tokens in the contract
        address morphoToken = rewardTokens[0]; // Assuming the first reward token is MORPHO
        uint256 morphoBalance = IERC20(morphoToken).balanceOf(address(this));
        
        if (morphoBalance > 0) {
            // Approve the DEX router to spend the MORPHO tokens
            IERC20(morphoToken).approve(dexRouter, morphoBalance);
            
            // Swap the MORPHO tokens for USDC using the DEX router
            // In a real implementation, you would call the swap function on the DEX router
            // For simplicity, we'll just simulate it here
            
            // uint256 usdcReceived = IDEXRouter(dexRouter).swapExactTokensForTokens(
            //     morphoBalance,
            //     0,
            //     path,
            //     address(this),
            //     block.timestamp
            // );
            
            // Simulated USDC received (in a real implementation, this would be the actual amount)
            uint256 usdcReceived = morphoBalance;
            
            totalConverted += usdcReceived;
        }
        
        emit RewardsHarvested(address(this), totalConverted);
    }
    
    /**
     * @notice Updates the position in the USDC strategy by depositing funds with a specified split
     * @param splitA The percentage (in basis points) to allocate to Moonwell core market
     * @param splitB The percentage (in basis points) to allocate to MetaMorpho Vault
     */
    function updateStrategy(uint256 splitA, uint256 splitB) external {
        // This function is called via delegatecall from the UserWallet contract
        // So 'address(this)' refers to the UserWallet contract
        
        // Verify that this wallet is managed by MamoCore
        require(IMamoCore(mamoCore).isUserWallet(address(this)), "Wallet not managed by MamoCore");
        
        // Validate that splitA + splitB equals SPLIT_TOTAL (10,000 basis points)
        require(splitA + splitB == SPLIT_TOTAL, "Split must equal 100%");
        
        // Withdraw all existing funds from both the Moonwell core market and MetaMorpho Vault
        
        // Withdraw from Moonwell core market
        uint256 mTokenBalance = IERC20(moonwellUSDC).balanceOf(address(this));
        if (mTokenBalance > 0) {
            // Call the redeem function on the Moonwell USDC mToken
            IMToken(moonwellUSDC).redeem(mTokenBalance);
        }
        
        // Withdraw from MetaMorpho Vault
        uint256 vaultShares = IERC20(metaMorphoVault).balanceOf(address(this));
        if (vaultShares > 0) {
            // In a real implementation, you would call the redeem function on the MetaMorpho Vault
            // For simplicity, we'll just simulate it here
            // IERC4626(metaMorphoVault).redeem(vaultShares, address(this), address(this));
        }
        
        // Calculate the total available USDC
        uint256 totalUSDC = usdc.balanceOf(address(this));
        
        // Calculate the amount to be deposited into each protocol
        uint256 amountA = (totalUSDC * splitA) / SPLIT_TOTAL; // For Moonwell core market
        uint256 amountB = (totalUSDC * splitB) / SPLIT_TOTAL; // For MetaMorpho Vault
        
        // Deposit into Moonwell core market
        if (amountA > 0) {
            // Approve the Moonwell USDC mToken to spend USDC
            usdc.approve(moonwellUSDC, amountA);
            
            // Mint mUSDC tokens
            IMToken(moonwellUSDC).mint(amountA);
        }
        
        // Deposit into MetaMorpho Vault
        if (amountB > 0) {
            // Approve the MetaMorpho Vault to spend USDC
            usdc.approve(metaMorphoVault, amountB);
            
            // Deposit USDC and receive vault shares
            // In a real implementation, you would call the deposit function on the MetaMorpho Vault
            // For simplicity, we'll just simulate it here
            // IERC4626(metaMorphoVault).deposit(amountB, address(this));
        }
        
        emit StrategyUpdated(address(this), totalUSDC, splitA, splitB);
    }
    
    /**
     * @notice Withdraws USDC from both Moonwell core market and MetaMorpho Vault
     * @param user The address of the user to withdraw funds for
     * @param amount The amount of USDC to withdraw
     */
    function withdrawFunds(address user, uint256 amount) external {
        // This function is called via delegatecall from the UserWallet contract
        // So 'address(this)' refers to the UserWallet contract
        
        // Ensure the contract has enough balance across both protocols
        uint256 totalBalance = getTotalBalance();
        require(totalBalance >= amount, "Insufficient balance");
        
        // Calculate the proportional amount to withdraw from each protocol
        uint256 mTokenBalance = IERC20(moonwellUSDC).balanceOf(address(this));
        uint256 vaultShares = IERC20(metaMorphoVault).balanceOf(address(this));
        
        // Calculate the USDC value of the vault shares
        uint256 vaultUSDC = IERC4626(metaMorphoVault).previewRedeem(vaultShares);
        
        // Calculate the USDC value of the mTokens (simplified)
        uint256 mTokenUSDC = mTokenBalance; // In a real implementation, this would be calculated based on the exchange rate
        
        // Calculate the proportion to withdraw from each protocol
        uint256 amountFromMoonwell = (amount * mTokenUSDC) / totalBalance;
        uint256 amountFromMorpho = amount - amountFromMoonwell;
        
        // Withdraw from Moonwell core market
        if (amountFromMoonwell > 0) {
            // Call the redeem function on the Moonwell USDC mToken
            IMToken(moonwellUSDC).redeem(amountFromMoonwell);
        }
        
        // Withdraw from MetaMorpho Vault
        if (amountFromMorpho > 0) {
            // In a real implementation, you would call the withdraw function on the MetaMorpho Vault
            // For simplicity, we'll just simulate it here
            // IERC4626(metaMorphoVault).withdraw(amountFromMorpho, address(this), address(this));
        }
        
        // Transfer the withdrawn USDC to the user (the wallet contract owner)
        // In a real implementation, you would get the owner from the UserWallet contract
        address owner = user; // Placeholder
        usdc.transfer(owner, amount);
        
        emit FundsWithdrawn(user, amount);
    }
    
    /**
     * @notice Sets a new DEX router address
     * @dev Can only be called by the MamoCore contract or the admin
     * @param _newDexRouter The address of the new DEX router
     */
    function setDexRouter(address _newDexRouter) external {
        require(msg.sender == mamoCore || msg.sender == admin, "Only MamoCore or admin can call this function");
        require(_newDexRouter != address(0), "Invalid DEX router address");
        
        address oldDexRouter = dexRouter;
        dexRouter = _newDexRouter;
        
        emit DexRouterUpdated(oldDexRouter, _newDexRouter);
    }
    
    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @dev Can only be called by the admin
     * @param token The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external {
        require(msg.sender == admin, "Only admin can call this function");
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20(token).transfer(to, amount);
        
        emit TokenRecovered(token, to, amount);
    }
    
    /**
     * @notice Sets a new admin address
     * @dev Can only be called by the current admin
     * @param _newAdmin The address of the new admin
     */
    function setAdmin(address _newAdmin) external {
        require(msg.sender == admin, "Only admin can call this function");
        require(_newAdmin != address(0), "Invalid admin address");
        
        address oldAdmin = admin;
        admin = _newAdmin;
        
        emit AdminChanged(oldAdmin, _newAdmin);
    }
    
    /**
     * @notice Gets the total balance of USDC across both protocols
     * @return The total balance in USDC
     */
    function getTotalBalance() public view returns (uint256) {
        // Get the balance in the Moonwell core market
        uint256 mTokenBalance = IERC20(moonwellUSDC).balanceOf(address(this));
        uint256 moonwellUSDCBalance = mTokenBalance; // In a real implementation, this would be calculated based on the exchange rate
        
        // Get the balance in the MetaMorpho Vault
        uint256 vaultShares = IERC20(metaMorphoVault).balanceOf(address(this));
        uint256 morphoUSDCBalance = IERC4626(metaMorphoVault).previewRedeem(vaultShares);
        
        // Get the USDC balance in the contract
        uint256 directUSDCBalance = usdc.balanceOf(address(this));
        
        // Return the total balance
        return moonwellUSDCBalance + morphoUSDCBalance + directUSDCBalance;
    }
}
