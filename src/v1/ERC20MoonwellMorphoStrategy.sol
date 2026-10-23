// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";

import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {WETH9} from "@interfaces/IWETH.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMerkleDistributor {
    function claim(
        address[] calldata accounts,
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata proofs
    ) external;
}

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
    /// @dev The settlement contract's EIP-712 domain separator. Used to verify that a provided UID matches provided order parameters.
    bytes32 public constant DOMAIN_SEPARATOR = 0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b;

    /// @dev Magic value returned by isValidSignature for valid orders
    /// @dev See https://eips.ethereum.org/EIPS/eip-1271
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    // @notice Total basis points used for split calculations (100%)
    uint256 public constant SPLIT_TOTAL = 10000; // 100% in basis points

    /// @notice The maximum allowed  slippage in basis points
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500; // 25% in basis points

    /// @notice The maximum allowed compound fee in basis points
    uint256 public constant MAX_COMPOUND_FEE = 1000; // 10% in basis points

    /// @notice The address of the Cow contracts Vault Relayer contract that needs token approval for executing trades
    address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// @notice The address of the WETH token
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice The CoW order appData this strategy signs for (no hooks)
    string internal constant EXPECTED_APP_DATA = '{"appCode":"Mamo","metadata":{},"version":"1.3.0"}';

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

    // @notice The compound fee in basis points (e.g., 100 = 1%)
    uint256 public compoundFee;

    /// @notice The fee recipient address
    address public feeRecipient;

    /// @notice The hook gas limit
    uint256 public hookGasLimit;

    // Events
    // @notice Emitted when funds are deposited into the strategy
    event Deposit(address indexed asset, uint256 amount);

    // Events
    // @notice Emitted when funds are deposited into the strategy
    event DepositIdle(address indexed asset, uint256 amount);

    // @notice Emitted when funds are withdrawn from the strategy
    event Withdraw(address indexed asset, uint256 amount);

    // @notice Emitted when the position split is updated
    event PositionUpdated(uint256 splitMoonwell, uint256 splitMorpho);

    // @notice Emitted when the slippage tolerance is updated
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    // @notice Emitted when the fee recipient is updated
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);

    // @notice Emitted when rewards are claimed
    event RewardsClaimed(address[] rewardTokens, uint256[] rewardAmounts);

    // @notice Emitted when the compound fee is taken from claimed rewards
    event CompoundFeeCollected(address indexed feeRecipient, address[] rewardTokens, uint256[] feeAmounts);

    // @notice Emitted when Moonwell's cash could not cover the whole mToken position
    event MoonwellRedeemLimited(uint256 cashRedeemed, uint256 mTokenLeft, uint256 underlyingLeft);

    // @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address mamoBackend;
        address mToken;
        address metaMorphoVault;
        address token;
        address slippagePriceChecker;
        address feeRecipient;
        uint256 splitMToken;
        uint256 splitVault;
        uint256 strategyTypeId;
        address[] rewardTokens;
        address owner;
        uint256 hookGasLimit;
        uint256 allowedSlippageInBps;
        uint256 compoundFee;
    }

    address public constant MERKLE_PROTOCOL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    /**
     * @notice Restricts function access to the backend address only
     * @dev Uses the MamoStrategyRegistry to verify the caller is the backend
     */
    modifier onlyBackend() {
        require(_isBackend(msg.sender), "Not backend");
        _;
    }

    // ==================== INITIALIZER ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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
        require(params.feeRecipient != address(0), "Invalid fee recipient address");
        require(params.splitMToken + params.splitVault == 10000, "Split parameters must add up to 10000");
        require(params.hookGasLimit > 0, "Invalid hook gas limit");
        require(params.allowedSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");
        require(params.compoundFee <= MAX_COMPOUND_FEE, "Compound fee exceeds maximum");

        // Set state variables
        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        mToken = IMToken(params.mToken);
        metaMorphoVault = IERC4626(params.metaMorphoVault);
        token = IERC20(params.token);
        slippagePriceChecker = ISlippagePriceChecker(params.slippagePriceChecker);

        allowedSlippageInBps = params.allowedSlippageInBps;
        compoundFee = params.compoundFee;
        splitMToken = params.splitMToken;
        splitVault = params.splitVault;
        feeRecipient = params.feeRecipient;
        hookGasLimit = params.hookGasLimit;

        // Approve CowSwap for each reward token
        if (params.rewardTokens.length > 0) {
            for (uint256 i = 0; i < params.rewardTokens.length; i++) {
                _approveCowSwap(params.rewardTokens[i], type(uint256).max);
            }
        }
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Approves the vault relayer to spend a specific token
     * @dev Only callable by the user who owns this strategy
     * @param tokenAddress The address of the token to approve
     * @param amount The amount of tokens to approve
     */
    function approveCowSwap(address tokenAddress, uint256 amount) public onlyOwner {
        _approveCowSwap(tokenAddress, amount);
    }

    /**
     * @notice Sets a new slippage tolerance value
     * @dev Only callable by the strategy owner
     * @param _newSlippageInBps The new slippage tolerance in basis points (e.g., 100 = 1%)
     */
    function setSlippage(uint256 _newSlippageInBps) external onlyOwner {
        require(_newSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");

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
    function withdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");

        require(_getTotalBalance() >= amount, "Withdrawal amount exceeds available balance in strategy");

        // Check if we have enough tokens in the contract
        uint256 tokenBalance = token.balanceOf(address(this));

        // If we don't have enough tokens, withdraw from contractss
        if (tokenBalance < amount) {
            uint256 amountNeeded = amount - tokenBalance;

            // Split is the preference; a leg that cannot pay its share now shifts the excess to the other
            uint256 fromMoonwell = (amountNeeded * splitMToken) / SPLIT_TOTAL;
            uint256 fromVault = amountNeeded - fromMoonwell;
            uint256 moonwellMax = Math.min(mToken.getCash(), mToken.balanceOfUnderlying(address(this)));
            uint256 vaultMax = metaMorphoVault.maxWithdraw(address(this));

            if (fromMoonwell > moonwellMax) {
                fromVault += fromMoonwell - moonwellMax;
                fromMoonwell = moonwellMax;
            }
            if (fromVault > vaultMax) {
                fromMoonwell += fromVault - vaultMax;
                fromVault = vaultMax;
            }
            require(fromMoonwell <= moonwellMax, "Moonwell cannot pay the remainder now");

            // Withdraw from Moonwell if needed
            if (fromMoonwell > 0) {
                require(mToken.redeemUnderlying(fromMoonwell) == 0, "Failed to redeem mToken");
            }

            // Withdraw from MetaMorpho if needed
            if (fromVault > 0) {
                metaMorphoVault.withdraw(fromVault, address(this), address(this));
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
    function withdrawAll() external onlyOwner {
        // Get current balances
        uint256 vaultBalance = metaMorphoVault.balanceOf(address(this));

        // Withdraw from Moonwell if needed
        _redeemMTokenUpToCash();

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
        _redeemMTokenUpToCash();

        // Withdraw from MetaMorpho
        uint256 vaultBalance = metaMorphoVault.balanceOf(address(this));
        if (vaultBalance > 0) {
            metaMorphoVault.redeem(vaultBalance, address(this), address(this));
        }

        uint256 totalTokenBalance = token.balanceOf(address(this));

        // Update the split parameters
        splitMToken = splitMoonwell;
        splitVault = splitMorpho;

        // Deposit into MetaMorpho Vault and Moonwell MToken after update split parameters
        if (totalTokenBalance > 0) {
            depositInternal(totalTokenBalance);
        }

        emit PositionUpdated(splitMoonwell, splitMorpho);
    }

    /**
     * @notice Claims rewards from Merkle protocol distributor on behalf of a user
     * @dev Only callable by the backend address
     * @dev Merkl only lets this contract claim for itself, so the fee is not user-skippable
     * @param rewardTokens The addresses of the reward tokens
     * @param rewardAmounts The amounts of the reward tokens
     * @param proofs The proofs of the reward tokens
     */
    function claimRewards(
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata proofs
    ) external onlyBackend {
        require(rewardTokens.length == rewardAmounts.length, "Reward tokens and amounts length mismatch");
        require(rewardTokens.length == proofs.length, "Reward tokens and proofs length mismatch");

        address[] memory accounts = new address[](rewardTokens.length);
        uint256[] memory feeAmounts = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (i > 0) require(rewardTokens[i] > rewardTokens[i - 1], "Reward tokens must be strictly ascending");
            accounts[i] = address(this);
            feeAmounts[i] = IERC20(rewardTokens[i]).balanceOf(address(this));
        }

        IMerkleDistributor(MERKLE_PROTOCOL_DISTRIBUTOR).claim(accounts, rewardTokens, rewardAmounts, proofs);

        // Fee on what the claim paid out: Merkl amounts are cumulative, so use the balance delta
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            feeAmounts[i] =
                ((IERC20(rewardTokens[i]).balanceOf(address(this)) - feeAmounts[i]) * compoundFee) / SPLIT_TOTAL;
            if (feeAmounts[i] > 0) {
                IERC20(rewardTokens[i]).safeTransfer(feeRecipient, feeAmounts[i]);
            }
        }

        emit CompoundFeeCollected(feeRecipient, rewardTokens, feeAmounts);

        emit RewardsClaimed(rewardTokens, rewardAmounts);
    }

    /**
     * @notice Sets a new fee recipient address
     * @dev Only callable by the backend address
     * @param _newFeeRecipient The new fee recipient address
     */
    function setFeeRecipient(address _newFeeRecipient) external onlyBackend {
        require(_newFeeRecipient != address(0), "Invalid fee recipient address");

        emit FeeRecipientUpdated(feeRecipient, _newFeeRecipient);
        feeRecipient = _newFeeRecipient;
    }

    // ==================== PERMISSIONLESS FUNCTIONS ====================

    /**
     * @notice Deposits funds into the strategy
     * @notice This function assumes that the exact `amount` of tokens is received after the transfer.
     *      It does not support fee-on-transfer tokens where the received amount would be less than the transfer amount.
     * @dev Only callable by the user who owns this strategy
     * @param amount The amount of tokens to deposit
     */
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer tokens from the owner to this contract
        token.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit the funds according to the current split
        depositInternal(amount);

        emit Deposit(address(token), amount);
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

        emit DepositIdle(address(token), tokenBalance);

        return tokenBalance;
    }

    // ======================= VIEW FUNCTIONS ==========================

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

        require(_order.appData == keccak256(bytes(EXPECTED_APP_DATA)), "Invalid app data");

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

    /// @notice The appData document isValidSignature accepts, and its hash
    function expectedAppData() external pure returns (string memory doc, bytes32 hash) {
        return (EXPECTED_APP_DATA, keccak256(bytes(EXPECTED_APP_DATA)));
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Internal function to deposit tokens according to the current split
     * @param amount The amount of tokens to deposit
     */
    function depositInternal(uint256 amount) internal {
        // Calculate target amounts for each contracts
        uint256 targetMoonwell = (amount * splitMToken) / SPLIT_TOTAL;
        uint256 targetMetaMorpho = (amount * splitVault) / SPLIT_TOTAL;

        // Deposit into each contracts according to the split
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
     * @notice Gets the total balance of tokens across both contractss
     * @return The total balance in tokens
     */
    function _getTotalBalance() internal returns (uint256) {
        uint256 shareBalance = metaMorphoVault.balanceOf(address(this));
        uint256 vaultBalance = shareBalance > 0 ? metaMorphoVault.convertToAssets(shareBalance) : 0;

        return vaultBalance + mToken.balanceOfUnderlying(address(this)) + token.balanceOf(address(this));
    }

    /**
     * @notice Internal function to approve the vault relayer to spend a specific token
     * @param tokenAddress The address of the token to approve
     * @param amount The amount of tokens to approve
     */
    function _approveCowSwap(address tokenAddress, uint256 amount) internal {
        // Check if the token has a configuration in the swap checker
        require(slippagePriceChecker.isRewardToken(tokenAddress), "Token not allowed");

        // Approve the vault relayer unlimited
        IERC20(tokenAddress).forceApprove(VAULT_RELAYER, amount);
    }

    /**
     * @notice Redeems the mToken position up to the market's available cash, skipping when there is none
     */
    function _redeemMTokenUpToCash() internal {
        uint256 mTokenBalance = IERC20(address(mToken)).balanceOf(address(this));
        if (mTokenBalance == 0) return;

        uint256 cash = mToken.getCash();
        uint256 underlying = mToken.balanceOfUnderlying(address(this));
        if (cash >= underlying) {
            require(mToken.redeem(mTokenBalance) == 0, "Failed to redeem mToken");
        } else {
            if (cash > 0) require(mToken.redeemUnderlying(cash) == 0, "Failed to redeem mToken");
            emit MoonwellRedeemLimited(cash, IERC20(address(mToken)).balanceOf(address(this)), underlying - cash);
        }
    }

    /**
     * @notice Allows the contract to receive ETH
     * @dev In the case where token == WETH, wrap back to WETH (for WETH mToken redemption)
     */
    receive() external payable override {
        if (msg.value > 0 && address(token) == WETH) {
            WETH9(WETH).deposit{value: msg.value}();
        }
    }
}
