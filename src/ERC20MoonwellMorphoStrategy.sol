// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IComptroller} from "./interfaces/IComptroller.sol";
import {IDEXRouter} from "./interfaces/IDEXRouter.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title ERC20MoonwellMorphoStrategy
 * @notice A strategy contract for ERC20 tokens that splits deposits between Moonwell core market and Moonwell Vaults
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract ERC20MoonwellMorphoStrategy is Initializable, AccessControlEnumerable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    // @notice Total basis points used for split calculations (100%)
    uint256 public constant SPLIT_TOTAL = 10000; // 100% in basis points

    // Role definitions
    // @notice Role identifier for the strategy owner (the user)
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    // @notice Role identifier for the upgrader (Mamo Strategy Registry)
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // @notice Role identifier for the backend role
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    // State variables
    // @notice Reference to the Mamo Strategy Registry contract
    IMamoStrategyRegistry public mamoStrategyRegistry;

    // @notice Reference to the Moonwell Comptroller contract
    IComptroller public moonwellComptroller;

    // @notice Reference to the Moonwell mToken contract
    IMToken public mToken;

    // @notice Reference to the MetaMorpho Vault contract
    IERC4626 public metaMorphoVault;

    // @notice Reference to the DEX router contract
    IDEXRouter public dexRouter;

    // @notice Reference to the ERC20 token contract
    IERC20 public token;

    // @notice Percentage of funds allocated to Moonwell mToken in basis points
    uint256 public splitMToken;

    // @notice Percentage of funds allocated to MetaMorpho Vault in basis points
    uint256 public splitVault;

    // @notice Set of reward token addresses
    EnumerableSet.AddressSet private _rewardTokens;

    // Events
    // @notice Emitted when funds are deposited into the strategy
    event Deposit(address indexed asset, uint256 amount);

    // @notice Emitted when funds are withdrawn from the strategy
    event Withdraw(address indexed asset, uint256 amount);

    // @notice Emitted when the position split is updated
    event PositionUpdated(uint256 splitA, uint256 splitB);

    // @notice Emitted when rewards are harvested
    event RewardsHarvested(uint256 amount);

    // @notice Emitted when the DEX router is updated
    event DexRouterUpdated(address indexed oldDexRouter, address indexed newDexRouter);

    // @notice Emitted when a reward token is added or removed
    event RewardTokenUpdated(address indexed token, bool added);

    // @notice Emitted when tokens are recovered from the contract
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    // @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address owner;
        address mamoStrategyRegistry;
        address mamoBackend;
        address moonwellComptroller;
        address mToken;
        address metaMorphoVault;
        address dexRouter;
        address token;
        uint256 splitMToken;
        uint256 splitVault;
    }

    // ==================== INITIALIZER ====================

    /**
     * @notice Initializer function that sets all the parameters and grants appropriate roles
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.owner != address(0), "Invalid owner address");
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.mamoBackend != address(0), "Invalid mamoBackend address");
        require(params.moonwellComptroller != address(0), "Invalid moonwellComptroller address");
        require(params.mToken != address(0), "Invalid mToken address");
        require(params.metaMorphoVault != address(0), "Invalid metaMorphoVault address");
        require(params.dexRouter != address(0), "Invalid dexRouter address");
        require(params.token != address(0), "Invalid token address");

        // Set up roles
        _grantRole(OWNER_ROLE, params.owner);
        _grantRole(UPGRADER_ROLE, params.mamoStrategyRegistry);
        _grantRole(BACKEND_ROLE, params.mamoBackend);

        // Set state variables
        mamoStrategyRegistry = IMamoStrategyRegistry(params.mamoStrategyRegistry);
        moonwellComptroller = IComptroller(params.moonwellComptroller);
        mToken = IMToken(params.mToken);
        metaMorphoVault = IERC4626(params.metaMorphoVault);
        dexRouter = IDEXRouter(params.dexRouter);
        token = IERC20(params.token);

        splitMToken = params.splitMToken;
        splitVault = params.splitVault;
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Deposits funds into the strategy
     * @dev Only callable by accounts with the OWNER_ROLE
     * @param amount The amount of tokens to deposit
     */
    function deposit(uint256 amount) external onlyRole(OWNER_ROLE) {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer tokens from the owner to this contract
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit the funds according to the current split
        depositInternal(amount);

        emit Deposit(address(token), amount);
    }

    /**
     * @notice Withdraws funds from the strategy
     * @dev Only callable by accounts with the OWNER_ROLE
     * @param amount The amount to withdraw
     */
    function withdraw(uint256 amount) external onlyRole(OWNER_ROLE) {
        require(amount > 0, "Amount must be greater than 0");

        require(getTotalBalance() > amount, "Amount greater than liquidity");

        // Check if we have enough tokens in the contract
        uint256 tokenBalance = token.balanceOf(address(this));

        // If we don't have enough tokens, withdraw from protocols
        if (tokenBalance < amount) {
            uint256 amountNeeded = amount - tokenBalance;

            uint256 withdrawFromMoonwell = (amountNeeded * splitMToken) / SPLIT_TOTAL;

            // Withdraw from Moonwell if needed
            if (withdrawFromMoonwell > 0) {
                require(mToken.redeemUnderlying(withdrawFromMoonwell) == 0, "Failed to redeem mToken");
            }

            uint256 withdrawFromMetaMorpho = (amountNeeded * splitVault) / SPLIT_TOTAL;

            // Withdraw from MetaMorpho if needed
            if (withdrawFromMetaMorpho > 0) {
                metaMorphoVault.withdraw(withdrawFromMetaMorpho, address(this), address(this));
            }
        }

        // Verify we have enough tokens now
        require(token.balanceOf(address(this)) >= amount, "Withdrawal failed: insufficient funds");

        // Transfer tokens to the owner
        token.safeTransfer(msg.sender, amount);

        emit Withdraw(address(token), amount);
    }

    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @dev Only callable by accounts with the OWNER_ROLE
     * @param tokenAddress The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address tokenAddress, address to, uint256 amount) external onlyRole(OWNER_ROLE) {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(tokenAddress).safeTransfer(to, amount);

        emit TokenRecovered(tokenAddress, to, amount);
    }

    // add recover ETH

    // ==================== BACKEND FUNCTIONS ====================

    /**
     * @notice Updates the position in the strategy
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param splitA The first split parameter (basis points) for Moonwell
     * @param splitB The second split parameter (basis points) for MetaMorpho
     */
    function updatePosition(uint256 splitA, uint256 splitB) external onlyRole(BACKEND_ROLE) {
        require(splitA + splitB == SPLIT_TOTAL, "Split parameters must add up to SPLIT_TOTAL");

        // Withdraw from Moonwell
        uint256 mTokenBalance = IERC20(address(mToken)).balanceOf(address(this));
        if (mTokenBalance > 0) {
            require(mToken.redeem(mTokenBalance) == 0, "Failed to redeem mToken");
        }

        // Withdraw from MetaMorpho
        uint256 vaultBalance = metaMorphoVault.balanceOf(address(this));
        if (vaultBalance > 0) {
            metaMorphoVault.redeem(vaultBalance, address(this), address(this));
        }

        uint256 totalTokenBalance = token.balanceOf(address(this));
        require(totalTokenBalance > 0, "Nothing to rebalance");

        // Update the split parameters
        splitMToken = splitA;
        splitVault = splitB;

        // Deposit into MetaMorpho Vault and Moonwell MToken after update split parameters
        depositInternal(totalTokenBalance);

        emit PositionUpdated(splitA, splitB);
    }

    /**
     * @notice Updates the reward tokens set by adding or removing a token
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param rewardToken The address of the token to add or remove
     * @param add True to add the token, false to remove it
     */
    function updateRewardToken(address rewardToken, bool add) external onlyRole(BACKEND_ROLE) {
        require(rewardToken != address(0), "Invalid token address");
        require(rewardToken != address(token), "Strategy token cannot be a reward token");

        if (add) {
            require(_rewardTokens.add(rewardToken), "Token already exists in reward tokens");
        } else {
            require(_rewardTokens.remove(rewardToken), "Token does not exist in reward tokens");
        }

        emit RewardTokenUpdated(rewardToken, add);
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
     * @notice Harvests reward tokens by swapping them to the strategy token and depositing according to the current split
     * @dev Callable by accounts with either the BACKEND_ROLE or OWNER_ROLE
     */
    function harvestRewards() external {
        require(
            hasRole(BACKEND_ROLE, msg.sender) || hasRole(OWNER_ROLE, msg.sender),
            "Caller must have BACKEND_ROLE or OWNER_ROLE"
        );

        uint256 totalTokenHarvested = 0;
        uint256 rewardTokenCount = _rewardTokens.length();

        // Iterate through all reward tokens
        for (uint256 i = 0; i < rewardTokenCount; i++) {
            address rewardToken = _rewardTokens.at(i);

            uint256 rewardBalance = IERC20(rewardToken).balanceOf(address(this));

            // Skip if no balance
            if (rewardBalance == 0) {
                continue;
            }

            // Approve DEX router to spend reward tokens
            IERC20(rewardToken).approve(address(dexRouter), rewardBalance);

            // Set up the swap path: reward token -> strategy token
            address[] memory path = new address[](2);
            path[0] = rewardToken;
            path[1] = address(token);

            // Swap reward tokens for strategy tokens
            uint256[] memory amounts = dexRouter.swapExactTokensForTokens(
                rewardBalance,
                0, // Accept any amount of tokens (we can add a minimum later if needed)
                path,
                address(this),
                block.timestamp + 1800 // 30 minute deadline
            );

            // Add the tokens received to our total
            totalTokenHarvested += amounts[amounts.length - 1];
        }

        // If we harvested any tokens, deposit them according to the current split
        if (totalTokenHarvested > 0) {
            depositInternal(totalTokenHarvested);
            emit RewardsHarvested(totalTokenHarvested);
        }
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Internal function to deposit tokens according to the current split
     * @param amount The amount of tokens to deposit
     */
    function depositInternal(uint256 amount) internal {
        // Calculate target amounts for each protocol
        uint256 targetMoonwell = (amount * splitMToken) / SPLIT_TOTAL;
        uint256 targetMetaMorpho = (amount * splitVault) / SPLIT_TOTAL;

        // Deposit into each protocol according to the split
        if (targetMoonwell > 0) {
            token.approve(address(mToken), targetMoonwell);

            // Mint mToken with token
            require(mToken.mint(targetMoonwell) == 0, "MToken mint failed");
        }

        if (targetMetaMorpho > 0) {
            token.approve(address(metaMorphoVault), targetMetaMorpho);

            // Deposit token into MetaMorpho
            metaMorphoVault.deposit(targetMetaMorpho, address(this));
        }
    }

    /**
     * @notice Internal function that authorizes an upgrade to a new implementation
     * @dev Only callable by accounts with the UPGRADER_ROLE (Mamo Strategy Registry)
     */
    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Gets the total balance of tokens across both protocols
     * @return The total balance in tokens
     */
    function getTotalBalance() public returns (uint256) {
        uint256 shareBalance = metaMorphoVault.balanceOf(address(this));
        uint256 vaultBalance = metaMorphoVault.convertToAssets(shareBalance);

        // TODO check vault balance decimals
        return vaultBalance + mToken.balanceOfUnderlying(address(this)) + token.balanceOf(address(this));
    }
}
