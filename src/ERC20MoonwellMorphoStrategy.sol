// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";

import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
 * @notice A strategy contract for ERC20 tokens that splits deposits across N Moonwell markets and M ERC4626 vaults
 * @notice IMPORTANT: This contract does not support fee-on-transfer tokens. Using such tokens will result in
 *         unexpected behavior and potential loss of funds.
 * @dev This contract is designed to be used as an implementation for proxies.
 *      Market definitions are read from MarketRegistry. Per-market splits are stored locally keyed by address.
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

    /// @notice The maximum allowed slippage in basis points
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500; // 25% in basis points

    /// @notice The maximum allowed compound fee in basis points
    uint256 public constant MAX_COMPOUND_FEE = 1000; // 10% in basis points

    /// @notice The address of the Cow contracts Vault Relayer contract that needs token approval for executing trades
    address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// @notice Maximum number of markets allowed per strategy
    uint256 public constant MAX_MARKETS = 10;

    /// @notice The Merkle protocol distributor address for reward claims
    address public constant MERKLE_PROTOCOL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    // ==================== STORAGE LAYOUT ====================
    // Slots 0-49: BaseStrategy (mamoStrategyRegistry, strategyTypeId, __gap[48])

    // Slot 50: DEPRECATED — old mToken (value preserved for migration)
    IMToken public mToken;

    // Slot 51: DEPRECATED — old metaMorphoVault
    IERC4626 public metaMorphoVault;

    // Slot 52: token (kept)
    IERC20 public token;

    // Slot 53: slippagePriceChecker (kept)
    ISlippagePriceChecker public slippagePriceChecker;

    // Slot 54: DEPRECATED — old splitMToken (value preserved for migration)
    uint256 public splitMToken;

    // Slot 55: DEPRECATED — old splitVault (value preserved for migration)
    uint256 public splitVault;

    // Slot 56: allowedSlippageInBps (kept)
    uint256 public allowedSlippageInBps;

    // Slot 57: compoundFee (kept)
    uint256 public compoundFee;

    // Slot 58: feeRecipient (kept)
    address public feeRecipient;

    // Slot 59: hookGasLimit (kept)
    uint256 public hookGasLimit;

    // ==================== NEW STORAGE (appended after slot 59) ====================

    // Slot 60: marketRegistry
    IMarketRegistry public marketRegistry;

    // Slot 61: per-market splits keyed by market address
    mapping(address => uint256) public marketSplitBps;

    // Events
    event Deposit(address indexed asset, uint256 amount);
    event DepositIdle(address indexed asset, uint256 amount);
    event Withdraw(address indexed asset, uint256 amount);
    event PositionUpdated(MarketSplitUpdate[] updates);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);
    event RewardsClaimed(address[] rewardTokens, uint256[] rewardAmounts);

    // @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address mamoBackend;
        address token;
        address slippagePriceChecker;
        address feeRecipient;
        uint256 strategyTypeId;
        address[] rewardTokens;
        address owner;
        uint256 hookGasLimit;
        uint256 allowedSlippageInBps;
        uint256 compoundFee;
        address marketRegistry;
        uint256[] defaultSplitBps;
    }

    /// @notice Used by updatePosition to set new splits (address-keyed)
    struct MarketSplitUpdate {
        address market;
        uint256 splitBps;
    }

    /// @notice Composite view struct returned by getMarkets()
    struct Market {
        address target;
        MarketType marketType;
        bool active;
        uint256 splitBps;
    }

    modifier onlyBackend() {
        require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
        _;
    }

    // ==================== INITIALIZER ====================

    /**
     * @notice Initializer for new deployments using MarketRegistry
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.mamoBackend != address(0), "Invalid mamoBackend address");
        require(params.token != address(0), "Invalid token address");
        require(params.slippagePriceChecker != address(0), "Invalid SlippagePriceChecker address");
        require(params.strategyTypeId != 0, "Strategy type id not set");
        require(params.feeRecipient != address(0), "Invalid fee recipient address");
        require(params.hookGasLimit > 0, "Invalid hook gas limit");
        require(params.allowedSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");
        require(params.compoundFee <= MAX_COMPOUND_FEE, "Compound fee exceeds maximum");
        require(params.marketRegistry != address(0), "Invalid market registry address");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        token = IERC20(params.token);
        slippagePriceChecker = ISlippagePriceChecker(params.slippagePriceChecker);
        allowedSlippageInBps = params.allowedSlippageInBps;
        compoundFee = params.compoundFee;
        feeRecipient = params.feeRecipient;
        hookGasLimit = params.hookGasLimit;
        marketRegistry = IMarketRegistry(params.marketRegistry);

        // Read markets from registry and apply default splits
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(params.strategyTypeId);
        require(regMarkets.length > 0, "No markets in registry");
        require(params.defaultSplitBps.length == regMarkets.length, "Split count must match market count");

        for (uint256 i = 0; i < regMarkets.length; i++) {
            require(regMarkets[i].active, "Market not active");
            marketSplitBps[regMarkets[i].target] = params.defaultSplitBps[i];
        }
        _validateTotalSplit();

        // Approve CowSwap for each reward token
        for (uint256 i = 0; i < params.rewardTokens.length; i++) {
            _approveCowSwap(params.rewardTokens[i], type(uint256).max);
        }
    }

    /**
     * @notice Migration function for v1 strategies to MarketRegistry
     * @dev Self-contained: reads mToken/metaMorphoVault/splitMToken/splitVault from own storage.
     *      Validates each address is registered and active in the MarketRegistry.
     * @param _marketRegistry The address of the MarketRegistry contract
     */
    function migrateV1ToMarketRegistry(address _marketRegistry) external reinitializer(2) {
        require(msg.sender == owner() || msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not owner or backend");
        require(_marketRegistry != address(0), "Invalid market registry address");

        marketRegistry = IMarketRegistry(_marketRegistry);

        // Self-contained migration: read from own storage
        if (splitMToken > 0 && address(mToken) != address(0)) {
            marketSplitBps[address(mToken)] = splitMToken;
            require(marketRegistry.isMarketActive(strategyTypeId, address(mToken)), "mToken not active in registry");
        }
        if (splitVault > 0 && address(metaMorphoVault) != address(0)) {
            marketSplitBps[address(metaMorphoVault)] = splitVault;
            require(
                marketRegistry.isMarketActive(strategyTypeId, address(metaMorphoVault)),
                "metaMorphoVault not active in registry"
            );
        }

        _validateTotalSplit();
    }

    // ==================== OWNER FUNCTIONS ====================

    function approveCowSwap(address tokenAddress, uint256 amount) public onlyOwner {
        _approveCowSwap(tokenAddress, amount);
    }

    function setSlippage(uint256 _newSlippageInBps) external onlyOwner {
        require(_newSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");

        emit SlippageUpdated(allowedSlippageInBps, _newSlippageInBps);
        allowedSlippageInBps = _newSlippageInBps;
    }

    /**
     * @notice Withdraws funds from the strategy
     * @dev Only callable by the user who owns this strategy
     * @param amount The amount to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(_getTotalBalance() > amount, "Withdrawal amount exceeds available balance in strategy");

        uint256 tokenBalance = token.balanceOf(address(this));

        if (tokenBalance < amount) {
            uint256 amountNeeded = amount - tokenBalance;
            _withdrawProRata(amountNeeded);
        }

        require(token.balanceOf(address(this)) >= amount, "Withdrawal failed: insufficient funds");
        token.safeTransfer(msg.sender, amount);

        emit Withdraw(address(token), amount);
    }

    /**
     * @notice Withdraws all funds from the strategy
     * @dev Only callable by the user who owns this strategy
     */
    function withdrawAll() external onlyOwner {
        _withdrawAllFromMarkets();

        uint256 finalBalance = token.balanceOf(address(this));
        require(finalBalance > 0, "No tokens to withdraw");

        token.safeTransfer(msg.sender, finalBalance);

        emit Withdraw(address(token), finalBalance);
    }

    // ==================== BACKEND FUNCTIONS ====================

    /**
     * @notice Updates the position across markets with new splits (address-keyed)
     * @param updates Array of market address + new splitBps pairs
     */
    function updatePosition(MarketSplitUpdate[] calldata updates) external onlyBackend {
        // Withdraw everything from all markets
        _withdrawAllFromMarkets();

        uint256 totalTokenBalance = token.balanceOf(address(this));
        require(totalTokenBalance > 0, "Nothing to rebalance");

        // Zero out all splits first
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(strategyTypeId);
        for (uint256 i = 0; i < regMarkets.length; i++) {
            marketSplitBps[regMarkets[i].target] = 0;
        }

        // Apply new splits from updates
        for (uint256 i = 0; i < updates.length; i++) {
            require(marketRegistry.isMarketActive(strategyTypeId, updates[i].market), "Market not active in registry");
            marketSplitBps[updates[i].market] = updates[i].splitBps;
        }

        _validateTotalSplit();

        // Re-deposit via depositInternal
        depositInternal(totalTokenBalance);

        emit PositionUpdated(updates);
    }

    function claimRewards(
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata proofs
    ) external onlyBackend {
        require(rewardTokens.length == rewardAmounts.length, "Reward tokens and amounts length mismatch");
        require(rewardTokens.length == proofs.length, "Reward tokens and proofs length mismatch");

        address[] memory accounts = new address[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            accounts[i] = address(this);
        }

        IMerkleDistributor(MERKLE_PROTOCOL_DISTRIBUTOR).claim(accounts, rewardTokens, rewardAmounts, proofs);

        emit RewardsClaimed(rewardTokens, rewardAmounts);
    }

    function setFeeRecipient(address _newFeeRecipient) external onlyBackend {
        require(_newFeeRecipient != address(0), "Invalid fee recipient address");

        emit FeeRecipientUpdated(feeRecipient, _newFeeRecipient);
        feeRecipient = _newFeeRecipient;
    }

    // ==================== PERMISSIONLESS FUNCTIONS ====================

    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        token.safeTransferFrom(msg.sender, address(this), amount);
        depositInternal(amount);

        emit Deposit(address(token), amount);
    }

    function depositIdleTokens() external returns (uint256) {
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to deposit");

        depositInternal(tokenBalance);

        emit DepositIdle(address(token), tokenBalance);

        return tokenBalance;
    }

    // ======================= VIEW FUNCTIONS ==========================

    /**
     * @notice Returns all markets with their local splits (composite view)
     * @return Array of Market structs combining registry data + local splits
     */
    function getMarkets() external view returns (Market[] memory) {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(strategyTypeId);
        Market[] memory result = new Market[](regMarkets.length);

        for (uint256 i = 0; i < regMarkets.length; i++) {
            result[i] = Market({
                target: regMarkets[i].target,
                marketType: regMarkets[i].marketType,
                active: regMarkets[i].active,
                splitBps: marketSplitBps[regMarkets[i].target]
            });
        }

        return result;
    }

    /**
     * @notice Returns the number of markets from the registry
     */
    function getMarketCount() external view returns (uint256) {
        return marketRegistry.getMarketCount(strategyTypeId);
    }

    /// @param orderDigest The EIP-712 signing digest derived from the order
    /// @param encodedOrder Bytes-encoded order information
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

        uint256 feeAmount = (_order.sellAmount * compoundFee) / SPLIT_TOTAL;

        bytes memory preHookCalldata =
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(this), feeRecipient, feeAmount);

        string memory preHookCalldataStr = string.concat("0x", _bytesToHexString(preHookCalldata));

        string memory targetAddress = Strings.toHexString(uint160(address(_order.sellToken)), 20);

        string memory expectedAppData = string(
            abi.encodePacked(
                '{"appCode":"Mamo","metadata":{"hooks":{"pre":[{"callData":"',
                preHookCalldataStr,
                '","gasLimit":"',
                Strings.toString(hookGasLimit),
                '","target":"',
                targetAddress,
                '"}],"version":"0.1.0"}},"version":"1.3.0"}'
            )
        );

        bytes32 expectedAppDataBytes = keccak256(bytes(expectedAppData));

        require(_order.appData == expectedAppDataBytes, "Invalid app data");

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
     * @notice Internal function to deposit tokens according to current market splits
     * @param amount The amount of tokens to deposit
     */
    function depositInternal(uint256 amount) internal {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(strategyTypeId);
        uint256 deposited = 0;

        // Find the last active market with nonzero split for remainder handling
        uint256 lastActiveIdx = type(uint256).max;
        for (uint256 i = regMarkets.length; i > 0; i--) {
            if (regMarkets[i - 1].active && marketSplitBps[regMarkets[i - 1].target] > 0) {
                lastActiveIdx = i - 1;
                break;
            }
        }

        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (!regMarkets[i].active) continue;

            uint256 split = marketSplitBps[regMarkets[i].target];
            if (split == 0) continue;

            uint256 marketAmount;
            // Give remainder to last active market to avoid dust
            if (i == lastActiveIdx) {
                marketAmount = amount - deposited;
            } else {
                marketAmount = (amount * split) / SPLIT_TOTAL;
            }

            if (marketAmount == 0) continue;

            _depositToMarket(regMarkets[i], marketAmount);
            deposited += marketAmount;
        }
    }

    /**
     * @notice Deposits tokens into a specific market
     */
    function _depositToMarket(RegistryMarket memory market, uint256 amount) internal {
        if (market.marketType == MarketType.MTOKEN) {
            token.forceApprove(market.target, amount);
            require(IMToken(market.target).mint(amount) == 0, "MToken mint failed");
        } else {
            token.forceApprove(market.target, amount);
            IERC4626(market.target).deposit(amount, address(this));
        }
    }

    /**
     * @notice Withdraws pro-rata from active markets based on their split
     * @param amountNeeded The total amount of underlying tokens needed
     */
    function _withdrawProRata(uint256 amountNeeded) internal {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(strategyTypeId);

        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (!regMarkets[i].active) continue;

            uint256 split = marketSplitBps[regMarkets[i].target];
            if (split == 0) continue;

            uint256 withdrawAmount = (amountNeeded * split) / SPLIT_TOTAL;
            if (withdrawAmount == 0) continue;

            if (regMarkets[i].marketType == MarketType.MTOKEN) {
                require(IMToken(regMarkets[i].target).redeemUnderlying(withdrawAmount) == 0, "Failed to redeem mToken");
            } else {
                IERC4626(regMarkets[i].target).withdraw(withdrawAmount, address(this), address(this));
            }
        }
    }

    /**
     * @notice Withdraws all funds from all markets (including inactive, to recover stuck funds)
     */
    function _withdrawAllFromMarkets() internal {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(strategyTypeId);

        for (uint256 i = 0; i < regMarkets.length; i++) {
            _withdrawFromMarket(regMarkets[i]);
        }
    }

    /**
     * @notice Withdraws all funds from a single market
     */
    function _withdrawFromMarket(RegistryMarket memory market) internal {
        if (market.marketType == MarketType.MTOKEN) {
            uint256 mTokenBalance = IERC20(market.target).balanceOf(address(this));
            if (mTokenBalance > 0) {
                require(IMToken(market.target).redeem(mTokenBalance) == 0, "Failed to redeem mToken");
            }
        } else {
            uint256 shareBalance = IERC4626(market.target).balanceOf(address(this));
            if (shareBalance > 0) {
                IERC4626(market.target).redeem(shareBalance, address(this), address(this));
            }
        }
    }

    /**
     * @notice Gets the total balance of tokens across all markets + idle
     * @return The total balance in underlying tokens
     */
    function _getTotalBalance() internal returns (uint256) {
        uint256 total = token.balanceOf(address(this));
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(strategyTypeId);

        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (!regMarkets[i].active) continue;

            if (regMarkets[i].marketType == MarketType.MTOKEN) {
                total += IMToken(regMarkets[i].target).balanceOfUnderlying(address(this));
            } else {
                uint256 shares = IERC4626(regMarkets[i].target).balanceOf(address(this));
                if (shares > 0) {
                    total += IERC4626(regMarkets[i].target).convertToAssets(shares);
                }
            }
        }

        return total;
    }

    /**
     * @notice Validates that active market splits sum to SPLIT_TOTAL
     */
    function _validateTotalSplit() internal view {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(strategyTypeId);
        uint256 total = 0;

        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (regMarkets[i].active) {
                total += marketSplitBps[regMarkets[i].target];
            }
        }
        require(total == SPLIT_TOTAL, "Split parameters must add up to SPLIT_TOTAL");
    }

    function _approveCowSwap(address tokenAddress, uint256 amount) internal {
        require(slippagePriceChecker.isRewardToken(tokenAddress), "Token not allowed");
        IERC20(tokenAddress).forceApprove(VAULT_RELAYER, amount);
    }

    function _bytesToHexString(bytes memory _bytes) internal pure returns (string memory) {
        bytes memory hexString = new bytes(_bytes.length * 2);
        bytes memory hexChars = "0123456789abcdef";

        for (uint256 i = 0; i < _bytes.length; i++) {
            uint8 value = uint8(_bytes[i]);
            hexString[i * 2] = hexChars[value >> 4];
            hexString[i * 2 + 1] = hexChars[value & 0xf];
        }

        return string(hexString);
    }
}
