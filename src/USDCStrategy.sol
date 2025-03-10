// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {IComptroller} from "./interfaces/IComptroller.sol";
import {IDEXRouter} from "./interfaces/IDEXRouter.sol";

/**
 * @title USDCStrategy
 * @notice A strategy contract for USDC that splits deposits between Moonwell core market and Moonwell Vaults
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract USDCStrategy is Initializable, AccessControlEnumerable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    uint256 public constant SPLIT_TOTAL = 10000; // 100% in basis points
    
    // Role definitions
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    // State variables
    IMamoStrategyRegistry public mamoStrategyRegistry;
    IComptroller public moonwellComptroller;
    IMToken public moonwellUSDC;
    IERC4626 public metaMorphoVault;
    IDEXRouter public dexRouter;
    IERC20 public usdc;
    
    // Reward tokens
    EnumerableSet.AddressSet private _rewardTokens;

    // Events
    event Deposit(address indexed asset, uint256 amount);
    event Withdraw(address indexed asset, uint256 amount);
    event PositionUpdated(uint256 splitA, uint256 splitB);
    event RewardsClaimed(uint256 amount);
    event DexRouterUpdated(address indexed oldDexRouter, address indexed newDexRouter);
    event RewardTokenUpdated(address indexed token, bool added);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Initializer function that sets all the parameters and grants appropriate roles
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param _owner The owner of this strategy (the user)
     * @param _mamoStrategyRegistry The MamoStrategyRegistry contract address
     * @param _mamoBackend The Mamo Backend address
     * @param _moonwellComptroller The Moonwell Comptroller contract address
     * @param _moonwellUSDC The Moonwell USDC mToken contract address
     * @param _metaMorphoVault The MetaMorpho Vault contract address
     * @param _dexRouter The DEX router for swapping reward tokens
     * @param _usdc The USDC token address
     */
    function initialize(
        address _owner,
        address _mamoStrategyRegistry,
        address _mamoBackend,
        address _moonwellComptroller,
        address _moonwellUSDC,
        address _metaMorphoVault,
        address _dexRouter,
        address _usdc
    ) external initializer {
        require(_owner != address(0), "Invalid owner address");
        require(_mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(_mamoBackend != address(0), "Invalid mamoBackend address");
        require(_moonwellComptroller != address(0), "Invalid moonwellComptroller address");
        require(_moonwellUSDC != address(0), "Invalid moonwellUSDC address");
        require(_metaMorphoVault != address(0), "Invalid metaMorphoVault address");
        require(_dexRouter != address(0), "Invalid dexRouter address");
        require(_usdc != address(0), "Invalid usdc address");

        // Set up roles
        _grantRole(OWNER_ROLE, _owner);
        _grantRole(UPGRADER_ROLE, _mamoStrategyRegistry);
        _grantRole(BACKEND_ROLE, _mamoBackend);
        
        // Set state variables
        mamoStrategyRegistry = IMamoStrategyRegistry(_mamoStrategyRegistry);
        moonwellComptroller = IComptroller(_moonwellComptroller);
        moonwellUSDC = IMToken(_moonwellUSDC);
        metaMorphoVault = IERC4626(_metaMorphoVault);
        dexRouter = IDEXRouter(_dexRouter);
        usdc = IERC20(_usdc);
    }

    /**
     * @notice Updates the DEX router address
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param _newDexRouter The new DEX router address
     */
    function setDexRouter(address _newDexRouter) external onlyRole(BACKEND_ROLE) {
        require(_newDexRouter != address(0), "Invalid dexRouter address");
        
        address oldDexRouter = address(dexRouter);
        dexRouter = IDEXRouter(_newDexRouter);
        
        emit DexRouterUpdated(oldDexRouter, _newDexRouter);
    }

    /**
     * @notice Deposits funds into the strategy
     * @dev Only callable by accounts with the OWNER_ROLE
     * @param asset The address of the asset to deposit
     * @param amount The amount to deposit
     */
    function deposit(address asset, uint256 amount) external onlyRole(OWNER_ROLE) {
        require(asset == address(usdc), "Only USDC deposits are supported");
        require(amount > 0, "Amount must be greater than 0");

        // Transfer USDC from the owner to this contract
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(asset, amount);
    }

    /**
     * @notice Withdraws funds from the strategy
     * @dev Only callable by accounts with the OWNER_ROLE
     * @param asset The address of the asset to withdraw
     * @param amount The amount to withdraw
     */
    function withdraw(address asset, uint256 amount) external onlyRole(OWNER_ROLE) {
        require(asset == address(usdc), "Only USDC withdrawals are supported");
        require(amount > 0, "Amount must be greater than 0");

        // Withdraw from Moonwell and MetaMorpho based on the current balances
        // This is a simplified implementation
        
        // Transfer USDC to the owner
        usdc.safeTransfer(msg.sender, amount);
        
        emit Withdraw(asset, amount);
    }

    /**
     * @notice Updates the position in the strategy
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param splitA The first split parameter (basis points) for Moonwell
     * @param splitB The second split parameter (basis points) for MetaMorpho
     */
    function updatePosition(uint256 splitA, uint256 splitB) external onlyRole(BACKEND_ROLE) {
        require(splitA + splitB == SPLIT_TOTAL, "Split parameters must add up to SPLIT_TOTAL");

        // Step 1: Withdraw everything from both protocols
        
        // Withdraw from Moonwell
        uint256 moonwellBalance = getMoonwellBalance();
        if (moonwellBalance > 0) {
            // Get the mToken balance
            uint256 mTokenBalance = IERC20(address(moonwellUSDC)).balanceOf(address(this));
            if (mTokenBalance > 0) {
                // Redeem all mTokens for USDC
                moonwellUSDC.redeem(mTokenBalance);
            }
        }
        
        // Withdraw from MetaMorpho
        uint256 metaMorphoBalance = getMetaMorphoBalance();
        if (metaMorphoBalance > 0) {
            // Get the vault share balance
            uint256 shareBalance = metaMorphoVault.balanceOf(address(this));
            if (shareBalance > 0) {
                // Redeem all shares for USDC
                metaMorphoVault.redeem(shareBalance, address(this), address(this));
            }
        }
        
        // Step 2: Get the total USDC balance now in the contract
        uint256 totalUSDCBalance = usdc.balanceOf(address(this));
        
        require(totalUSDCBalance > 0, "Nothing to rebalance");
        
        // Step 3: Calculate target amounts for each protocol
        uint256 targetMoonwell = (totalUSDCBalance * splitA) / SPLIT_TOTAL;
        uint256 targetMetaMorpho = totalUSDCBalance - targetMoonwell; // Use subtraction to avoid rounding errors
        
        // Step 4: Deposit into each protocol according to the split
        if (targetMoonwell > 0) {
            usdc.approve(address(moonwellUSDC), targetMoonwell);
            
            // Mint mUSDC with USDC
            moonwellUSDC.mint(targetMoonwell);
        }
        
        if (targetMetaMorpho > 0) {
            usdc.approve(address(metaMorphoVault), targetMetaMorpho);
            
            // Deposit USDC into MetaMorpho
            metaMorphoVault.deposit(targetMetaMorpho, address(this));
        }
        
        emit PositionUpdated(splitA, splitB);
    }

    /**
     * @notice Claims all available rewards from both Moonwell and Morpho and converts them to USDC
     * @dev Callable by accounts with either OWNER_ROLE or BACKEND_ROLE
     */
    function claimRewards() external {
        require(
            hasRole(OWNER_ROLE, msg.sender) || hasRole(BACKEND_ROLE, msg.sender),
            "Only owner or backend can claim rewards"
        );

        // Get initial USDC balance
        uint256 initialUSDCBalance = usdc.balanceOf(address(this));
        
        // Claim rewards from Moonwell
        moonwellComptroller.claimReward();
        
        // MetaMorpho rewards claiming would go here if applicable
        
        // Convert rewards to USDC using the DEX router
        _swapRewardsToUSDC();
        
        // Calculate the amount of USDC gained from rewards
        uint256 finalUSDCBalance = usdc.balanceOf(address(this));
        uint256 rewardsAmount = finalUSDCBalance > initialUSDCBalance ? 
                               finalUSDCBalance - initialUSDCBalance : 0;
        
        emit RewardsClaimed(rewardsAmount);
    }
    
    /**
     * @notice Swaps reward tokens to USDC
     * @dev Internal function to convert reward tokens to USDC
     */
    function _swapRewardsToUSDC() internal {
        // Get all reward tokens
        address[] memory rewardTokens = new address[](_rewardTokens.length());
        for (uint256 i = 0; i < _rewardTokens.length(); i++) {
            rewardTokens[i] = _rewardTokens.at(i);
        }
        
        // Swap each reward token for USDC
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            if (token == address(usdc)) continue; // Skip if token is already USDC
            
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                // Approve DEX router to spend the token
                IERC20(token).approve(address(dexRouter), balance);
                
                // Create the swap path: token -> USDC
                address[] memory path = new address[](2);
                path[0] = token;
                path[1] = address(usdc);
                
                // Swap tokens for USDC
                // Note: This is a simplified implementation - in a real contract, you would handle slippage, etc.
                dexRouter.swapExactTokensForTokens(
                    balance,
                    0, // Accept any amount of USDC
                    path,
                    address(this),
                    block.timestamp
                );
            }
        }
    }
    
    /**
     * @notice Updates the reward tokens set by adding or removing a token
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param token The address of the token to add or remove
     * @param add True to add the token, false to remove it
     */
    function updateRewardToken(address token, bool add) external onlyRole(BACKEND_ROLE) {
        require(token != address(0), "Invalid token address");
        
        if (add) {
            require(_rewardTokens.add(token), "Token already exists in reward tokens");
            
        } else {
            require(_rewardTokens.remove(token), "Token does not exist in reward tokens");
        }
        
        emit RewardTokenUpdated(token, add);
    }
    
    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @dev Only callable by accounts with the OWNER_ROLE
     * @param token The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyRole(OWNER_ROLE) {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20(token).safeTransfer(to, amount);
        
        emit TokenRecovered(token, to, amount);
    }
    
    /**
     * @notice Internal function that authorizes an upgrade to a new implementation
     * @dev Only callable by accounts with the UPGRADER_ROLE (Mamo Strategy Registry)
     */
    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {
    }
    
    /**
     * @notice Gets the total balance of USDC across both protocols
     * @return The total balance in USDC
     */
    function getTotalBalance() public returns (uint256) {
        uint256 shareBalance = metaMorphoVault.balanceOf(address(this));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(shareBalance);

        // TODO check vault balance decimals 
        return vaultBalance + moonwellUSDC.balanceOfUnderlying(address(this)) + usdc.balanceOf(address(this));
    }
    
    /**
     * @notice Gets the balance of USDC in Moonwell
     * @return The balance in USDC
     */
    function getMoonwellBalance() public returns (uint256) {
        return moonwellUSDC.balanceOfUnderlying(address(this));
    }
    
    /**
     * @notice Gets the balance of USDC in MetaMorpho
     * @return The balance in USDC
     */
    function getMetaMorphoBalance() public view returns (uint256) {
        uint256 shareBalance = metaMorphoVault.balanceOf(address(this));
        return metaMorphoVault.convertToAssets(shareBalance);
    }
}
