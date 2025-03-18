// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {IBaseStrategy} from "@interfaces/IBaseStrategy.sol";
import {IComptroller} from "@interfaces/IComptroller.sol";
import {IDEXRouter} from "@interfaces/IDEXRouter.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IPriceChecker} from "@interfaces/IPriceChecker.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title ERC20MoonwellMorphoStrategy
 * @notice A strategy contract for ERC20 tokens that splits deposits between Moonwell core market and Moonwell Vaults
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract ERC20MoonwellMorphoStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Constants
    /// @dev The settlement contract's EIP-712 domain separator. Strategy uses this to verify that a provided UID matches provided order parameters.
    bytes32 public constant DOMAIN_SEPARATOR = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;

    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    // @notice Total basis points used for split calculations (100%)
    uint256 public constant SPLIT_TOTAL = 10000; // 100% in basis points

    // State variables
    // @notice Reference to the Moonwell Comptroller contract
    IComptroller public moonwellComptroller;

    // @notice Reference to the Moonwell mToken contract
    IMToken public mToken;

    // @notice Reference to the MetaMorpho Vault contract
    IERC4626 public metaMorphoVault;

    // @notice Reference to the ERC20 token contract
    IERC20 public token;

    IPriceChecker priceChecker;

    // @notice Percentage of funds allocated to Moonwell mToken in basis points
    uint256 public splitMToken;

    // @notice Percentage of funds allocated to MetaMorpho Vault in basis points
    uint256 public splitVault;

    // @notice Set of reward token addresses
    EnumerableSet.AddressSet private _rewardTokens;

    mapping(address rewardToken => bytes priceCheckerData) rewardTokenPriceCheckerData;

    // Events
    // @notice Emitted when funds are deposited into the strategy
    event Deposit(address indexed asset, uint256 amount);

    // @notice Emitted when funds are withdrawn from the strategy
    event Withdraw(address indexed asset, uint256 amount);

    // @notice Emitted when the position split is updated
    event PositionUpdated(uint256 splitA, uint256 splitB);

    // @notice Emitted when rewards are compounded
    event RewardsCompounded(uint256 amount);

    // @notice Emitted when a reward token is added
    event RewardTokenAdded(address indexed token);

    // @notice Emitted when a reward token is removed
    event RewardTokenRemoved(address indexed token);

    // @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address mamoBackend;
        address moonwellComptroller;
        address mToken;
        address metaMorphoVault;
        address token;
        uint256 splitMToken;
        uint256 splitVault;
    }

    /**
     * @notice Restricts function access to the backend address only
     * @dev Uses the MamoStrategyRegistry to verify the caller is the backend
     */
    modifier onlyBackend() {
        require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
        _;
    }

    /**
     * @notice Restricts function access to the MamoStrategyRegistry contract only
     * @dev Used for functions that should only be called by the registry, such as upgrades
     */
    modifier onlyStrategyRegistry() {
        require(msg.sender == address(mamoStrategyRegistry), "Only Mamo Strategy Registry can call");
        _;
    }

    // ==================== INITIALIZER ====================

    /**
     * @notice Initializer function that sets all the parameters and grants appropriate roles
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.mamoBackend != address(0), "Invalid mamoBackend address");
        require(params.moonwellComptroller != address(0), "Invalid moonwellComptroller address");
        require(params.mToken != address(0), "Invalid mToken address");
        require(params.metaMorphoVault != address(0), "Invalid metaMorphoVault address");
        require(params.token != address(0), "Invalid token address");

        // Set state variables
        __BaseStrategy_init(params.mamoStrategyRegistry);

        moonwellComptroller = IComptroller(params.moonwellComptroller);
        mToken = IMToken(params.mToken);
        metaMorphoVault = IERC4626(params.metaMorphoVault);
        token = IERC20(params.token);

        splitMToken = params.splitMToken;
        splitVault = params.splitVault;
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Deposits funds into the strategy
     * @dev Only callable by the user who owns this strategy
     * @param amount The amount of tokens to deposit
     */
    function deposit(uint256 amount) external onlyStrategyOwner {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer tokens from the owner to this contract
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit the funds according to the current split
        depositInternal(amount);

        emit Deposit(address(token), amount);
    }

    /**
     * @notice Withdraws funds from the strategy
     * @dev Only callable by the user who owns this strategy
     * @param amount The amount to withdraw
     */
    function withdraw(uint256 amount) external onlyStrategyOwner {
        require(amount > 0, "Amount must be greater than 0");

        require(getTotalBalance() > amount, "Withdrawal amount exceeds available balance in strategy");

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

    // ==================== BACKEND FUNCTIONS ====================

    /**
     * @notice Updates the position in the strategy
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param splitA The first split parameter (basis points) for Moonwell
     * @param splitB The second split parameter (basis points) for MetaMorpho
     */
    function updatePosition(uint256 splitA, uint256 splitB) external onlyBackend {
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
     * @notice Adds a token to the reward tokens set
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param rewardToken The address of the token to add
     */
    function addRewardToken(address rewardToken) external onlyBackend {
        require(rewardToken != address(0), "Invalid token address");
        require(rewardToken != address(token), "Strategy token cannot be a reward token");
        require(_rewardTokens.add(rewardToken), "Token already exists in reward tokens");

        emit RewardTokenAdded(rewardToken);
    }

    /**
     * @notice Removes a token from the reward tokens set
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param rewardToken The address of the token to remove
     */
    function removeRewardToken(address rewardToken) external onlyBackend {
        require(rewardToken != address(0), "Invalid token address");
        require(_rewardTokens.remove(rewardToken), "Token does not exist in reward tokens");

        emit RewardTokenRemoved(rewardToken);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Gets the total balance of tokens across both protocols
     * @return The total balance in tokens
     * i
     */
    function getTotalBalance() public returns (uint256) {
        uint256 shareBalance = metaMorphoVault.balanceOf(address(this));
        uint256 vaultBalance = shareBalance > 0 ? metaMorphoVault.convertToAssets(shareBalance) : 0;

        // TODO check vault balance decimals
        return vaultBalance + mToken.balanceOfUnderlying(address(this)) + token.balanceOf(address(this));
    }

    /// @param orderDigest The EIP-712 signing digest derived from the order
    /// @param encodedOrder Bytes-encoded order information, originally created by an off-chain bot. Created by concatening the order data (in the form of GPv2Order.Data), the price checker address, and price checker data.
    function isValidSignature(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4) {
        GPv2Order.Data memory _order = abi.decode(encodedOrder, (GPv2Order.Data));

        require(_order.hash(DOMAIN_SEPARATOR) == orderDigest, "Order hash does not match the provided digest");

        require(_order.kind == GPv2Order.KIND_SELL, "Order must be a sell order");

        require(
            _order.validTo >= block.timestamp + 5 minutes,
            "Order expires too soon - must be valid for at least 5 minutes"
        );

        require(!_order.partiallyFillable, "Order must be fill-or-kill, partial fills not allowed");

        require(_order.sellTokenBalance == GPv2Order.BALANCE_ERC20, "Sell token must be an ERC20 token");

        require(_order.buyTokenBalance == GPv2Order.BALANCE_ERC20, "Buy token must be an ERC20 token");

        bytes memory _priceCheckerData = rewardTokenPriceCheckerData[address(_order.sellToken)];

        require(_priceCheckerData.length > 0, "Price checker data not found for the sell token");

        require(_order.buyToken == token, "Buy token must match the strategy token");

        require(_order.receiver == address(this), "Order receiver must be this strategy contract");

        require(_order.feeAmount == 0, "Fee amount must be zero");

        require(
            priceChecker.checkPrice(
                _order.sellAmount ,
                address(_order.sellToken),
                address(_order.buyToken),
                0,
                _order.buyAmount,
                _priceCheckerData
            ),
            "Price check failed - output amount too low"
        );

        return MAGIC_VALUE;
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
}
