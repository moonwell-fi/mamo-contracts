// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {IDEXRouter} from "@interfaces/IDEXRouter.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ERC20MoonwellMorphoStrategy
 * @notice A strategy contract for ERC20 tokens that splits deposits between Moonwell core market and Moonwell Vaults
 * @notice IMPORTANT: This contract does not support fee-on-transfer tokens. Using such tokens will result in
 *         unexpected behavior and potential loss of funds.
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract ERC20MoonwellMorphoStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for IERC20;

    // Constants
    /// @dev The settlement contract's EIP-712 domain separator. Strategy uses this to verify that a provided UID matches provided order parameters.
    bytes32 public constant DOMAIN_SEPARATOR = 0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b;

    /// @dev Magic value returned by isValidSignature for valid orders
    /// @dev See https://eips.ethereum.org/EIPS/eip-1271
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    // @notice Total basis points used for split calculations (100%)
    uint256 public constant SPLIT_TOTAL = 10000; // 100% in basis points

    /// @notice The address of the Cow Protocol Vault Relayer contract that needs token approval for executing trades
    address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    // State variables
    // @notice Reference to the Moonwell mToken contract
    IMToken public mToken;

    // @notice Reference to the MetaMorpho Vault contract
    IERC4626 public metaMorphoVault;

    // @notice Reference to the ERC20 token contract
    IERC20 public token;

    /// @notice Reference to the swap checker contract used to validate swap prices
    ISlippagePriceChecker public slippagePriceChecker;

    // @notice Percentage of funds allocated to Moonwell mToken in basis points
    uint256 public splitMToken;

    // @notice Percentage of funds allocated to MetaMorpho Vault in basis points
    uint256 public splitVault;

    // @notice The allowed slippage in basis points (e.g., 100 = 1%)
    // @dev Used to calculate the minimum acceptable output amount for swaps
    uint256 public allowedSlippageInBps;

    // Events
    // @notice Emitted when funds are deposited into the strategy
    event Deposit(address indexed asset, uint256 amount);

    // @notice Emitted when funds are withdrawn from the strategy
    event Withdraw(address indexed asset, uint256 amount);

    // @notice Emitted when the position split is updated
    event PositionUpdated(uint256 splitMoonwell, uint256 splitMorpho);

    // @notice Emitted when the slippage tolerance is updated
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    // @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address mamoBackend;
        address mToken;
        address metaMorphoVault;
        address token;
        address slippagePriceChecker;
        uint256 splitMToken;
        uint256 splitVault;
        uint256 strategyTypeId;
    }

    /**
     * @notice Restricts function access to the backend address only
     * @dev Uses the MamoStrategyRegistry to verify the caller is the backend
     */
    modifier onlyBackend() {
        require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
        _;
    }

    // ==================== INITIALIZER ====================

    /**
     * @notice Initializer function that sets all the parameters and grants appropriate roles
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @dev Only the backend address specified in params can call this function
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.mamoBackend != address(0), "Invalid mamoBackend address");
        require(params.mToken != address(0), "Invalid mToken address");
        require(params.metaMorphoVault != address(0), "Invalid metaMorphoVault address");
        require(params.token != address(0), "Invalid token address");
        require(params.slippagePriceChecker != address(0), "Invalid SlippagePriceChecker address");
        require(params.strategyTypeId != 0, "Strategy type id not set");
        require(params.splitMToken + params.splitVault == 10000, "Split parameters must add up to 10000");

        // Set state variables
        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId);

        mToken = IMToken(params.mToken);
        metaMorphoVault = IERC4626(params.metaMorphoVault);
        token = IERC20(params.token);
        slippagePriceChecker = ISlippagePriceChecker(params.slippagePriceChecker);

        splitMToken = params.splitMToken;
        splitVault = params.splitVault;

        // Set default slippage to 1% (100 basis points)
        allowedSlippageInBps = 100;
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Deposits funds into the strategy
     * @notice This function assumes that the exact `amount` of tokens is received after the transfer.
     *      It does not support fee-on-transfer tokens where the received amount would be less than the transfer amount.
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
     * @notice Approves the vault relayer to spend a specific token
     * @dev Only callable by the user who owns this strategy
     * @param tokenAddress The address of the token to approve
     * @param amount The amount of tokens to approve
     */
    function approveCowSwap(address tokenAddress, uint256 amount) external onlyStrategyOwner {
        // Check if the token has a configuration in the swap checker
        require(slippagePriceChecker.isRewardToken(tokenAddress), "Token not allowed");

        // Approve the vault relayer unlimited
        IERC20(tokenAddress).forceApprove(VAULT_RELAYER, amount);
    }

    /**
     * @notice Sets a new slippage tolerance value
     * @dev Only callable by the strategy owner
     * @param _newSlippageInBps The new slippage tolerance in basis points (e.g., 100 = 1%)
     */
    function setSlippage(uint256 _newSlippageInBps) external onlyStrategyOwner {
        require(_newSlippageInBps <= SPLIT_TOTAL, "Slippage exceeds maximum");

        emit SlippageUpdated(allowedSlippageInBps, _newSlippageInBps);
        allowedSlippageInBps = _newSlippageInBps;
    }

    /**
     * @notice Withdraws funds from the strategy
     * @notice This function assumes that the exact `amount` of tokens is transferred to the user.
     *      It does not support fee-on-transfer tokens where the received amount would be less than the transfer amount.
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

    /**
     * @notice Withdraws all funds from the strategy
     * @dev Only callable by the user who owns this strategy
     */
    function withdrawAll() external onlyStrategyOwner {
        // Get current balances
        uint256 mTokenBalance = IERC20(address(mToken)).balanceOf(address(this));
        uint256 vaultBalance = metaMorphoVault.balanceOf(address(this));

        // Withdraw from Moonwell if needed
        if (mTokenBalance > 0) {
            require(mToken.redeem(mTokenBalance) == 0, "Failed to redeem mToken");
        }

        // Withdraw from MetaMorpho if needed
        if (vaultBalance > 0) {
            metaMorphoVault.redeem(vaultBalance, address(this), address(this));
        }

        // Get final token balance
        uint256 finalBalance = token.balanceOf(address(this));
        require(finalBalance > 0, "No tokens to withdraw");

        // Transfer all tokens to the owner
        token.safeTransfer(msg.sender, finalBalance);

        emit Withdraw(address(token), finalBalance);
    }

    // ==================== BACKEND FUNCTIONS ====================

    /**
     * @notice Updates the position in the strategy
     * @dev Only callable by accounts with the BACKEND_ROLE
     * @param splitMoonwell The first split parameter (basis points) for Moonwell
     * @param splitMorpho The second split parameter (basis points) for MetaMorpho
     */
    function updatePosition(uint256 splitMoonwell, uint256 splitMorpho) external onlyBackend {
        require(splitMoonwell + splitMorpho == SPLIT_TOTAL, "Split parameters must add up to SPLIT_TOTAL");

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
        splitMToken = splitMoonwell;
        splitVault = splitMorpho;

        // Deposit into MetaMorpho Vault and Moonwell MToken after update split parameters
        depositInternal(totalTokenBalance);

        emit PositionUpdated(splitMoonwell, splitMorpho);
    }

    /**
     * @notice Deposits any token funds currently in the contract into the strategies based on the split
     * @dev This function is permissionless and can be called by anyone
     * @return amount The amount of tokens deposited
     */
    function depositIdleTokens() external returns (uint256) {
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to deposit");

        // Deposit the funds according to the current split
        depositInternal(tokenBalance);

        emit Deposit(address(token), tokenBalance);

        return tokenBalance;
    }

    // ==================== VIEW FUNCTIONS ====================

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

        require(
            _order.validTo <= block.timestamp + slippagePriceChecker.maxTimePriceValid(address(_order.sellToken)),
            "Order expires too far in the future"
        );

        require(!_order.partiallyFillable, "Order must be fill-or-kill, partial fills not allowed");

        require(_order.sellTokenBalance == GPv2Order.BALANCE_ERC20, "Sell token must be an ERC20 token");

        require(_order.buyTokenBalance == GPv2Order.BALANCE_ERC20, "Buy token must be an ERC20 token");

        require(_order.sellToken != token, "Sell token can't be strategy token");

        require(_order.buyToken == token, "Buy token must match the strategy token");

        require(_order.feeAmount == 0, "Fee amount must be zero");

        require(_order.receiver == address(this), "Order receiver must be this strategy contract");

        require(_order.appData == bytes32(0), "App data must be zero");

        require(
            slippagePriceChecker.checkPrice(
                _order.sellAmount,
                address(_order.sellToken),
                address(_order.buyToken),
                _order.buyAmount,
                allowedSlippageInBps
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
            token.forceApprove(address(mToken), targetMoonwell);

            // Mint mToken with token
            require(mToken.mint(targetMoonwell) == 0, "MToken mint failed");
        }

        if (targetMetaMorpho > 0) {
            token.forceApprove(address(metaMorphoVault), targetMetaMorpho);

            // Deposit token into MetaMorpho
            metaMorphoVault.deposit(targetMetaMorpho, address(this));
        }
    }

    /**
     * @notice Gets the total balance of tokens across both protocols
     * @return The total balance in tokens
     * i
     */
    function getTotalBalance() internal returns (uint256) {
        uint256 shareBalance = metaMorphoVault.balanceOf(address(this));
        uint256 vaultBalance = shareBalance > 0 ? metaMorphoVault.convertToAssets(shareBalance) : 0;

        return vaultBalance + mToken.balanceOfUnderlying(address(this)) + token.balanceOf(address(this));
    }
}
