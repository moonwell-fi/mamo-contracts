// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IERC4626
 * @dev Interface for the ERC4626 Tokenized Vault Standard
 */
interface IERC4626 is IERC20 {
    /**
     * @dev Returns the address of the underlying token used for the Vault
     * @return The address of the asset token
     */
    function asset() external view returns (address);
    
    /**
     * @dev Returns the total amount of the underlying asset that is "managed" by Vault
     * @return The total amount of the asset
     */
    function totalAssets() external view returns (uint256);
    
    /**
     * @dev Returns the amount of shares that would be exchanged for the given amount of assets
     * @param assets The amount of assets to convert
     * @return The amount of shares
     */
    function convertToShares(uint256 assets) external view returns (uint256);
    
    /**
     * @dev Returns the amount of assets that would be exchanged for the given amount of shares
     * @param shares The amount of shares to convert
     * @return The amount of assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256);
    
    /**
     * @dev Returns the maximum amount of the underlying asset that can be deposited
     * @param receiver The address that will receive the assets
     * @return The maximum amount of assets
     */
    function maxDeposit(address receiver) external view returns (uint256);
    
    /**
     * @dev Simulates the effects of a deposit at the current block
     * @param assets The amount of assets to deposit
     * @return The amount of shares that would be minted
     */
    function previewDeposit(uint256 assets) external view returns (uint256);
    
    /**
     * @dev Deposits assets and mints shares to the receiver
     * @param assets The amount of assets to deposit
     * @param receiver The address to receive the shares
     * @return The amount of shares minted
     */
    function deposit(uint256 assets, address receiver) external returns (uint256);
    
    /**
     * @dev Returns the maximum amount of shares that can be minted
     * @param receiver The address that will receive the shares
     * @return The maximum amount of shares
     */
    function maxMint(address receiver) external view returns (uint256);
    
    /**
     * @dev Simulates the effects of a mint at the current block
     * @param shares The amount of shares to mint
     * @return The amount of assets that would be deposited
     */
    function previewMint(uint256 shares) external view returns (uint256);
    
    /**
     * @dev Mints shares to the receiver by depositing assets
     * @param shares The amount of shares to mint
     * @param receiver The address to receive the shares
     * @return The amount of assets deposited
     */
    function mint(uint256 shares, address receiver) external returns (uint256);
    
    /**
     * @dev Returns the maximum amount of assets that can be withdrawn
     * @param owner The address that owns the assets
     * @return The maximum amount of assets
     */
    function maxWithdraw(address owner) external view returns (uint256);
    
    /**
     * @dev Simulates the effects of a withdrawal at the current block
     * @param assets The amount of assets to withdraw
     * @return The amount of shares that would be burned
     */
    function previewWithdraw(uint256 assets) external view returns (uint256);
    
    /**
     * @dev Burns shares from owner and sends assets to receiver
     * @param assets The amount of assets to withdraw
     * @param receiver The address to receive the assets
     * @param owner The address that owns the shares
     * @return The amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    
    /**
     * @dev Returns the maximum amount of shares that can be redeemed
     * @param owner The address that owns the shares
     * @return The maximum amount of shares
     */
    function maxRedeem(address owner) external view returns (uint256);
    
    /**
     * @dev Simulates the effects of a redemption at the current block
     * @param shares The amount of shares to redeem
     * @return The amount of assets that would be withdrawn
     */
    function previewRedeem(uint256 shares) external view returns (uint256);
    
    /**
     * @dev Burns shares from owner and sends assets to receiver
     * @param shares The amount of shares to redeem
     * @param receiver The address to receive the assets
     * @param owner The address that owns the shares
     * @return The amount of assets withdrawn
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}
