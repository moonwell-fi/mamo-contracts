// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IMamoCore} from "./interfaces/IMamoCore.sol";
import {IDEXRouter} from "./interfaces/IDEXRouter.sol";
import {USDCStrategyStorage} from "./USDCStrategyStorage.sol";

/**
 * @title USDCStrategy
 * @notice A specific implementation of a Strategy Contract for USDC that splits deposits between Moonwell core market and Moonwell Vaults
 * @dev This contract is stateless and is designed to be called via delegatecall from a UserWallet
 */
contract USDCStrategy {
    using SafeERC20 for IERC20;
    
    /**
     * @notice Claims all available rewards from both Moonwell and Morpho and converts them to USDC
     * @param storage_ The address of the storage contract
     */
    function claimRewards(address storage_) external {
        // This function is called via delegatecall from the UserWallet contract
        // So 'address(this)' refers to the UserWallet contract
        USDCStrategyStorage store = USDCStrategyStorage(storage_);
        
        uint256 totalConverted = 0;
        
        // Claim Moonwell rewards
        // Check if the user has any existing positions in Moonwell markets
        uint256 mTokenBalance = IERC20(store.moonwellUSDC()).balanceOf(address(this));
        if (mTokenBalance > 0) {
            // Claim rewards from the Moonwell Comptroller for the user
            // In a real implementation, you would call the claimReward function on the Moonwell Comptroller
            // For simplicity, we'll just simulate it here
            
            // For each Moonwell reward token, check if any rewards were received
            for (uint256 i = 0; i < store.getRewardTokensLength(); i++) {
                address rewardToken = store.getRewardToken(i);
                
                // Get the reward token balance before and after claiming
                uint256 balanceBefore = IERC20(rewardToken).balanceOf(address(this));
                
                // Claim rewards (simulated)
                // IMoonwellComptroller(store.moonwellComptroller()).claimReward(address(this), rewardToken);
                
                uint256 balanceAfter = IERC20(rewardToken).balanceOf(address(this));
                uint256 rewardAmount = balanceAfter - balanceBefore;
                
                if (rewardAmount > 0) {
                    // Approve the DEX router to spend the reward tokens
                    IERC20(rewardToken).approve(store.dexRouter(), rewardAmount);
                    
                    // Swap the reward tokens for USDC using the DEX router
                    // In a real implementation, you would call the swap function on the DEX router
                    // For simplicity, we'll just simulate it here
                    
                    // uint256 usdcReceived = IDEXRouter(store.dexRouter()).swapExactTokensForTokens(
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
        address morphoToken = store.getRewardToken(0); // Assuming the first reward token is MORPHO
        uint256 morphoBalance = IERC20(morphoToken).balanceOf(address(this));
        
        if (morphoBalance > 0) {
            // Approve the DEX router to spend the MORPHO tokens
            IERC20(morphoToken).approve(store.dexRouter(), morphoBalance);
            
            // Swap the MORPHO tokens for USDC using the DEX router
            // In a real implementation, you would call the swap function on the DEX router
            // For simplicity, we'll just simulate it here
            
            // uint256 usdcReceived = IDEXRouter(store.dexRouter()).swapExactTokensForTokens(
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
        
        emit USDCStrategyStorage.RewardsHarvested(address(this), totalConverted);
    }
    
    /**
     * @notice Updates the position in the USDC strategy by depositing funds with a specified split
     * @param storage_ The address of the storage contract
     * @param splitA The percentage (in basis points) to allocate to Moonwell core market
     * @param splitB The percentage (in basis points) to allocate to MetaMorpho Vault
     */
    function updateStrategy(address storage_, uint256 splitA, uint256 splitB) external {
        // This function is called via delegatecall from the UserWallet contract
        // So 'address(this)' refers to the UserWallet contract
        USDCStrategyStorage store = USDCStrategyStorage(storage_);
        
        // Verify that this wallet is managed by MamoCore
        require(IMamoCore(store.mamoCore()).isUserWallet(address(this)), "Wallet not managed by MamoCore");
        
        // Validate that splitA + splitB equals SPLIT_TOTAL (10,000 basis points)
        require(splitA + splitB == store.SPLIT_TOTAL(), "Split must equal 100%");
        
        // Withdraw all existing funds from both the Moonwell core market and MetaMorpho Vault
        
        // Withdraw from Moonwell core market
        uint256 mTokenBalance = IERC20(store.moonwellUSDC()).balanceOf(address(this));
        if (mTokenBalance > 0) {
            // Call the redeem function on the Moonwell USDC mToken
            IMToken(store.moonwellUSDC()).redeem(mTokenBalance);
        }
        
        // Withdraw from MetaMorpho Vault
        uint256 vaultShares = IERC20(store.metaMorphoVault()).balanceOf(address(this));
        if (vaultShares > 0) {
            // Redeem all vault shares for USDC
            IERC4626(store.metaMorphoVault()).redeem(
                vaultShares,      // amount of shares to redeem
                address(this),    // receiver of the assets (this wallet)
                address(this)     // owner of the shares (this wallet)
            );
        }
        
        // Calculate the total available USDC
        uint256 totalUSDC = store.usdc().balanceOf(address(this));
        
        // Calculate the amount to be deposited into each protocol
        uint256 amountA = (totalUSDC * splitA) / store.SPLIT_TOTAL(); // For Moonwell core market
        uint256 amountB = (totalUSDC * splitB) / store.SPLIT_TOTAL(); // For MetaMorpho Vault
        
        // Deposit into Moonwell core market
        if (amountA > 0) {
            // Approve the Moonwell USDC mToken to spend USDC
            store.usdc().approve(store.moonwellUSDC(), amountA);
            
            // Mint mUSDC tokens
            IMToken(store.moonwellUSDC()).mint(amountA);
        }
        
        // Deposit into MetaMorpho Vault
        if (amountB > 0) {
            // Approve the MetaMorpho Vault to spend USDC
            store.usdc().approve(store.metaMorphoVault(), amountB);
            
            // Deposit USDC and receive vault shares
            IERC4626(store.metaMorphoVault()).deposit(
                amountB,         // amount of assets (USDC) to deposit
                address(this)    // receiver of the shares (this wallet)
            );
        }
        
        emit USDCStrategyStorage.StrategyUpdated(address(this), totalUSDC, splitA, splitB);
    }
    
    /**
     * @notice Withdraws USDC from both Moonwell core market and MetaMorpho Vault
     * @param storage_ The address of the storage contract
     * @param user The address of the user to withdraw funds for
     * @param amount The amount of USDC to withdraw
     */
    function withdrawFunds(address storage_, address user, uint256 amount) external {
        // This function is called via delegatecall from the UserWallet contract
        // So 'address(this)' refers to the UserWallet contract
        USDCStrategyStorage store = USDCStrategyStorage(storage_);
        
        // Ensure the contract has enough balance across both protocols
        uint256 totalBalance = getTotalBalance(storage_);
        require(totalBalance >= amount, "Insufficient balance");
        
        // Calculate the proportional amount to withdraw from each protocol
        uint256 mTokenBalance = IERC20(store.moonwellUSDC()).balanceOf(address(this));
        uint256 vaultShares = IERC20(store.metaMorphoVault()).balanceOf(address(this));
        
        // Calculate the USDC value of the vault shares
        uint256 morphoUSDCBalance = IERC4626(store.metaMorphoVault()).previewRedeem(vaultShares);
        
        // Calculate the USDC value of the mTokens (simplified)
        uint256 mTokenUSDC = mTokenBalance; // In a real implementation, this would be calculated based on the exchange rate
        
        // Calculate the proportion to withdraw from each protocol
        uint256 amountFromMoonwell = (amount * mTokenUSDC) / (mTokenUSDC + morphoUSDCBalance);
        uint256 amountFromMorpho = amount - amountFromMoonwell;
        
        // Withdraw from Moonwell core market
        if (amountFromMoonwell > 0) {
            // Call the redeem function on the Moonwell USDC mToken
            IMToken(store.moonwellUSDC()).redeem(amountFromMoonwell);
        }
        
        // Withdraw from MetaMorpho Vault
        if (amountFromMorpho > 0) {
            // Calculate how many shares we need to withdraw to get the desired amount of USDC
            uint256 sharesToWithdraw = IERC4626(store.metaMorphoVault()).previewWithdraw(amountFromMorpho);
            
            // Make sure we have enough shares
            uint256 availableShares = IERC20(store.metaMorphoVault()).balanceOf(address(this));
            require(availableShares >= sharesToWithdraw, "Not enough vault shares");
            
            // Withdraw USDC from the vault
            IERC4626(store.metaMorphoVault()).withdraw(
                amountFromMorpho,  // amount of assets (USDC) to withdraw
                address(this),     // receiver of the assets (this wallet)
                address(this)      // owner of the shares (this wallet)
            );
        }
        
        // Transfer the withdrawn USDC to the user (the wallet contract owner)
        // In a real implementation, you would get the owner from the UserWallet contract
        address owner = user; // Placeholder
        store.usdc().transfer(owner, amount);
        
        emit USDCStrategyStorage.FundsWithdrawn(user, amount);
    }
    
    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @param storage_ The address of the storage contract
     * @param token The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address storage_, address token, address to, uint256 amount) external {
        USDCStrategyStorage store = USDCStrategyStorage(storage_);
        require(msg.sender == store.admin(), "Only admin can call this function");
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20(token).transfer(to, amount);
        
        emit USDCStrategyStorage.TokenRecovered(token, to, amount);
    }
    
    /**
     * @notice Gets the total balance of USDC across both protocols
     * @param storage_ The address of the storage contract
     * @return The total balance in USDC
     */
    function getTotalBalance(address storage_) public view returns (uint256) {
        USDCStrategyStorage store = USDCStrategyStorage(storage_);
        
        // Get the balance in the Moonwell core market
        uint256 mTokenBalance = IERC20(store.moonwellUSDC()).balanceOf(address(this));
        uint256 moonwellUSDCBalance = mTokenBalance; // In a real implementation, this would be calculated based on the exchange rate
        
        // Get the balance in the MetaMorpho Vault
        uint256 vaultShares = IERC20(store.metaMorphoVault()).balanceOf(address(this));
        uint256 morphoUSDCBalance = IERC4626(store.metaMorphoVault()).previewRedeem(vaultShares);
        
        // Get the USDC balance in the contract
        uint256 directUSDCBalance = store.usdc().balanceOf(address(this));
        
        // Return the total balance
        return moonwellUSDCBalance + morphoUSDCBalance + directUSDCBalance;
    }
}
