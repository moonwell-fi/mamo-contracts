// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";

import {IMToken} from "@interfaces/IMToken.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {IMarketRegistry, MarketType, RegistryMarket} from "@interfaces/IMarketRegistry.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {WETH9} from "@interfaces/IWETH.sol";

import {GPv2Order} from "@libraries/GPv2Order.sol";
import {GPv2OrderChecks} from "@libraries/GPv2OrderChecks.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMerkleDistributor {
    function claim(
        address[] calldata accounts,
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata proofs
    ) external;
}

/**
 * @title MamoMultiMarketStrategy
 * @notice A strategy contract for ERC20 tokens that splits deposits across N Moonwell markets and M ERC4626 vaults
 * @notice IMPORTANT: This contract does not support fee-on-transfer tokens. Using such tokens will result in
 *         unexpected behavior and potential loss of funds.
 * @dev This contract is designed to be used as an implementation for proxies.
 *      Market definitions are read from MarketRegistry. Per-market splits are stored locally keyed by address.
 */
contract MamoMultiMarketStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
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

    /// @notice The address of the WETH token
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice The exact CoW Protocol appData document every reward order must carry.
    /// @dev No hooks: the compound fee is settled on-chain by {sweepRewardFees}, so the balance an
    ///      order is allowed to sell is already net of fees and the order needs no pre-hook. The
    ///      previous design pinned a `transferFrom(this, feeRecipient, fee)` pre-hook, which could
    ///      never succeed — for transferFrom the spender is the CALLER (HooksTrampoline), and this
    ///      strategy only ever approves VAULT_RELAYER. The trampoline swallows hook reverts, so
    ///      settlement proceeded and the fee was silently never collected. Approving the
    ///      trampoline is NOT the fix: CoW documents that allowances granted to it are usable by
    ///      anyone.
    ///
    ///      OPERATIONAL NOTE: the CoW appData schema version is pinned here as a constant, with no
    ///      setter. Pinning is the point — the document is what an order commits to, and a mutable
    ///      one would let whoever can change it widen what this strategy will sign. The cost is
    ///      that a CoW schema bump makes new orders unsignable until the implementation is upgraded
    ///      and each proxy is moved to it. Rewards are not at risk in that window (they simply stop
    ///      compounding and remain withdrawable), but the upgrade is on the critical path, so
    ///      schema announcements need to be watched rather than discovered.
    string internal constant EXPECTED_APP_DATA = '{"appCode":"Mamo","metadata":{},"version":"1.3.0"}';

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

    // Slot 62: how much of the CURRENT balance of a reward token has already had the compound fee
    // charged on it. Together with the VAULT_RELAYER allowance (which this contract is the only
    // writer of) it is enough to reconstruct, at any later time, how much of the balance is
    // freshly arrived and still owes the fee — see {_unchargedRewards}.
    mapping(address => uint256) public rewardFeeCharged;

    // Events
    event Deposit(address indexed asset, uint256 amount);
    event DepositIdle(address indexed asset, uint256 amount);
    event Withdraw(address indexed asset, uint256 amount);
    event PositionUpdated(MarketSplitUpdate[] updates);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);
    event RewardsClaimed(address[] rewardTokens, uint256[] rewardAmounts);
    event CompoundFeeCollected(address indexed feeRecipient, address[] rewardTokens, uint256[] feeAmounts);
    event RewardFeeSettled(address indexed rewardToken, address indexed feeRecipient, uint256 feeAmount);
    event MarketRegistryMigrated(address indexed marketRegistry);

    // @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
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
        require(_isBackend(msg.sender), "Not backend");
        _;
    }

    // ==================== INITIALIZER ====================

    /// @notice Locks the implementation so it can never be initialized directly.
    /// @dev Without this the first caller of {initialize} on the implementation becomes its owner
    ///      (initialize takes the owner from caller-supplied params) and gains the inherited
    ///      recoverERC20/recoverETH. Proxies are unaffected — they initialize their own storage.
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer for new deployments using MarketRegistry
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
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
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(params.token);
        require(regMarkets.length > 0, "No markets in registry");
        require(params.defaultSplitBps.length == regMarkets.length, "Split count must match market count");

        // Inactive registry entries are skipped, not rejected. MarketRegistry never removes a
        // market — retiring one is a deactivation — so requiring every historical entry to be
        // active would make every creation after the first retirement revert. An inactive entry
        // may only carry a zero allocation; the ACTIVE splits still have to total SPLIT_TOTAL,
        // which _validateTotalSplit enforces (it, depositInternal and _withdrawProRata all agree
        // on skipping inactive markets).
        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (!regMarkets[i].active) {
                require(params.defaultSplitBps[i] == 0, "Inactive market must have zero split");
                continue;
            }
            marketSplitBps[regMarkets[i].target] = params.defaultSplitBps[i];
        }
        _validateTotalSplit();

        // Reward tokens are validated here but deliberately NOT given a standing allowance. The
        // CoW vault relayer is approved for exactly the fee-settled balance by {sweepRewardFees},
        // which is what lets a later settlement see how much the relayer pulled (see
        // {_unchargedRewards}); an unlimited, never-decreasing allowance would erase that signal
        // and with it the only defence against rewards that arrive outside {claimRewards}.
        for (uint256 i = 0; i < params.rewardTokens.length; i++) {
            _requireRewardToken(params.rewardTokens[i]);
        }
    }

    /**
     * @notice Migration function for v1 strategies to MarketRegistry
     * @dev Self-contained: reads mToken/metaMorphoVault/splitMToken/splitVault from own storage.
     *      Validates each address is registered and active in the MarketRegistry.
     * @param _marketRegistry The address of the MarketRegistry contract
     */
    function migrateV1ToMarketRegistry(address _marketRegistry) external reinitializer(2) {
        require(msg.sender == owner() || _isBackend(msg.sender), "Not owner or backend");
        require(_marketRegistry != address(0), "Invalid market registry address");
        // A strategy created by the factory is already at `_initialized == 1` with both legacy
        // splits at zero, so both migration branches below would be skipped and _validateTotalSplit
        // would pass against the splits it was initialized with — leaving the owner free to point
        // `marketRegistry` at an arbitrary contract and spoof every registry-derived invariant
        // (market set, active flags, and therefore _getTotalBalance) for that strategy. Migration is
        // by definition a one-way move off the v1 layout, so it may only run before a registry is set.
        require(address(marketRegistry) == address(0), "Market registry already set");

        marketRegistry = IMarketRegistry(_marketRegistry);

        // Self-contained migration: read from own storage
        if (splitMToken > 0 && address(mToken) != address(0)) {
            marketSplitBps[address(mToken)] = splitMToken;
            require(marketRegistry.isMarketActive(address(token), address(mToken)), "mToken not active in registry");
        }
        if (splitVault > 0 && address(metaMorphoVault) != address(0)) {
            marketSplitBps[address(metaMorphoVault)] = splitVault;
            require(
                marketRegistry.isMarketActive(address(token), address(metaMorphoVault)),
                "metaMorphoVault not active in registry"
            );
        }

        _validateTotalSplit();

        emit MarketRegistryMigrated(_marketRegistry);
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Recovers ERC20 tokens from this contract, settling any compound fee owed first
     * @dev Sherlock #49. Reward tokens sit here as plain balances, so the inherited unconditional
     *      owner recovery is otherwise a complete escape hatch from the compound fee: claim (or
     *      let anyone claim) the rewards, sweep them out before any order exists, done. Settling
     *      first means the owner can only ever take the post-fee remainder. The trailing settle is
     *      what makes it stick — it drops the anchor and the relayer allowance back down to what
     *      is left, so the next batch of rewards cannot hide behind the recovered amount.
     *
     *      KNOWN LIMITATION: for a reward token, recovery now depends on the fee transfer to
     *      `feeRecipient` succeeding. A token that can blocklist an address (USDC and friends) can
     *      therefore suspend the escape hatch for that token until the backend re-points
     *      `feeRecipient` via {setFeeRecipient}. Accepted deliberately — the alternative, letting
     *      recovery proceed when the fee cannot be paid, is exactly the bypass #49 is about.
     */
    function recoverERC20(address tokenAddress, address to, uint256 amount) public override onlyOwner {
        bool isReward = _isSettleableRewardToken(tokenAddress);

        if (isReward) {
            sweepRewardFees(tokenAddress);
        }

        super.recoverERC20(tokenAddress, to, amount);

        if (isReward) {
            sweepRewardFees(tokenAddress);
        }
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
        require(_getTotalBalance() >= amount, "Withdrawal amount exceeds available balance in strategy");

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
     * @dev Runs on an EMPTY strategy too. This is the only way to repair the split configuration
     *      after a market is deactivated (deposit() refuses to run while the active splits are
     *      incomplete), so refusing to run at zero balance would permanently brick every strategy
     *      that happened to hold nothing at that moment — with no way back, because it cannot be
     *      funded either. There is simply nothing to re-deposit in that case.
     */
    function updatePosition(MarketSplitUpdate[] calldata updates) external onlyBackend {
        // Withdraw everything from all markets
        _withdrawAllFromMarkets();

        uint256 totalTokenBalance = token.balanceOf(address(this));

        // Zero out all splits first
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));
        for (uint256 i = 0; i < regMarkets.length; i++) {
            marketSplitBps[regMarkets[i].target] = 0;
        }

        // Apply new splits from updates
        for (uint256 i = 0; i < updates.length; i++) {
            require(
                marketRegistry.isMarketActive(address(token), updates[i].market), "Market not registered or not active"
            );
            marketSplitBps[updates[i].market] = updates[i].splitBps;
        }

        _validateTotalSplit();

        // Re-deposit via depositInternal
        if (totalTokenBalance > 0) {
            depositInternal(totalTokenBalance);
        }

        emit PositionUpdated(updates);
    }

    /**
     * @notice Claims Merkl rewards for this strategy and settles the compound fee on what arrived
     * @dev Convenience only. The fee is NOT charged on the claimed delta: Merkl's distributor
     *      exposes a permissionless `claim`, so anyone — the strategy owner included — can pull
     *      this strategy's rewards straight from the distributor and the tokens land here without
     *      this function ever running. The fee therefore has to be a property of the BALANCE, not
     *      of the call that fetched it; {sweepRewardFees} is where it is actually charged, and no
     *      CoW order for a reward token can settle until it has been (see {isValidSignature}).
     */
    function claimRewards(
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata proofs
    ) external onlyBackend {
        require(rewardTokens.length == rewardAmounts.length, "Reward tokens and amounts length mismatch");
        require(rewardTokens.length == proofs.length, "Reward tokens and proofs length mismatch");

        uint256 length = rewardTokens.length;
        address[] memory accounts = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            accounts[i] = address(this);
        }

        IMerkleDistributor(MERKLE_PROTOCOL_DISTRIBUTOR).claim(accounts, rewardTokens, rewardAmounts, proofs);

        emit RewardsClaimed(rewardTokens, rewardAmounts);

        uint256[] memory feeAmounts = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            // Skipped, not reverted: the claim itself has already succeeded by this point, and the
            // set of tokens Merkl pays is not ours to choose. It routinely includes the market's
            // own asset, and a campaign can start paying a token before the price checker is
            // configured for it — either one would make _requireRewardToken revert the whole batch
            // and strand every other reward in this call. A token that cannot be settled simply
            // stays where it is, with no fee charged and no relayer allowance armed, until it
            // becomes settleable.
            // A duplicated token settles to zero on its second visit — the first visit already
            // moved the whole uncharged balance behind the anchor.
            if (_isSettleableRewardToken(rewardTokens[i])) {
                feeAmounts[i] = sweepRewardFees(rewardTokens[i]);
            }
        }

        emit CompoundFeeCollected(feeRecipient, rewardTokens, feeAmounts);
    }

    /**
     * @notice Charges the compound fee on any balance of `rewardToken` that has not been charged
     *         yet, and re-arms the CoW vault relayer allowance at the fee-settled balance
     * @dev PERMISSIONLESS on purpose. It is the single settlement point for the fee regardless of
     *      how the tokens got here — a backend {claimRewards}, a permissionless distributor claim
     *      by the owner, or a plain transfer. Anyone may force it, and the relayer allowance this
     *      re-arms is what bounds a CoW settlement to the fee-settled amount, so the only way to
     *      turn rewards into strategy tokens runs through here.
     *
     *      SCOPE NOTE (deliberate broadening vs the audited design): the fee is a property of the
     *      BALANCE, charged on receipt of any priced non-principal token, whether or not a swap
     *      ever happens and regardless of who sent it. A donation of a reward token is taxed like a
     *      reward. That is the direct consequence of the fee not being able to live on the claim
     *      path — Merkl's `claim` is permissionless, so anything keyed to "the call that fetched
     *      the rewards" is trivially bypassed — and it over-collects rather than under-collects,
     *      which is the safe direction. What it is NOT robust to is a REBASING reward token: a
     *      negative rebase moves the balance under a fixed anchor, and a positive one reads as
     *      fresh rewards. Fee-on-transfer tokens are already documented unsupported; rebasing
     *      reward tokens are unsupported for the same reason.
     * @param rewardToken The reward token to settle
     * @return fee The amount transferred to the fee recipient by this call
     */
    function sweepRewardFees(address rewardToken) public returns (uint256 fee) {
        _requireRewardToken(rewardToken);

        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        fee = (_unchargedRewards(rewardToken, balance) * compoundFee) / SPLIT_TOTAL;

        address recipient = feeRecipient;
        if (fee > 0) {
            IERC20(rewardToken).safeTransfer(recipient, fee);
            balance -= fee;
        }

        // Re-anchor BOTH observables to the post-fee balance. The next settlement compares them:
        // the relayer allowance falls by exactly what CoW pulled, and crediting that outflow is
        // what stops a stale anchor from masking an equal amount of freshly arrived rewards.
        rewardFeeCharged[rewardToken] = balance;
        IERC20(rewardToken).forceApprove(VAULT_RELAYER, balance);

        emit RewardFeeSettled(rewardToken, recipient, fee);
    }

    /**
     * @notice The compound fee `rewardToken` currently owes, i.e. what {sweepRewardFees} would pay
     */
    function pendingRewardFee(address rewardToken) public view returns (uint256) {
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        return (_unchargedRewards(rewardToken, balance) * compoundFee) / SPLIT_TOTAL;
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
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));
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
        return marketRegistry.getMarketCount(address(token));
    }

    /// @param orderDigest The EIP-712 signing digest derived from the order
    /// @param encodedOrder Bytes-encoded order information
    /// @dev Order-CLASS checks (reward token in, strategy token out) run first; the shared GPv2
    ///      sell-order mechanics + price check live in GPv2OrderChecks.validate — one
    ///      implementation for this path and both of LPCompoundModule's. Revert strings are the
    ///      repo-canonical short set (see the library).
    ///      The order carries no fee hook. What actually secures the fee is the FINITE relayer
    ///      allowance: {sweepRewardFees} re-arms it at exactly the fee-settled balance, so CoW can
    ///      never pull a unit that has not been taxed, whatever else is sitting in this contract.
    ///      The one state that lock does not cover is a legacy proxy upgraded into this
    ///      implementation while still carrying the old unlimited approval — there the allowance
    ///      says nothing and the fee has to be settled before an order may be signed. Hence the
    ///      conditional below.
    ///
    ///      Applying the gate unconditionally was a liveness bug (and its old comment, claiming
    ///      dust could not block an order, was simply wrong): `pendingRewardFee` is a bps
    ///      multiplication that rounds down, so at the production compoundFee of 500 any donation
    ///      of 20 wei or more of the sell token rounds up to a nonzero owed fee and reverted the
    ///      solver's entire batch. Repeating it after each sweep costs the griefer ~20 wei plus gas
    ///      and stalls reward compounding indefinitely.
    function isValidSignature(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4) {
        GPv2Order.Data memory _order = abi.decode(encodedOrder, (GPv2Order.Data));

        require(_order.sellToken != token, "Sell token can't be strategy token");
        require(_order.buyToken == token, "Buy token must match the strategy token");

        address sellToken = address(_order.sellToken);
        if (IERC20(sellToken).allowance(address(this), VAULT_RELAYER) > rewardFeeCharged[sellToken]) {
            require(pendingRewardFee(sellToken) == 0, "Reward fee not settled");
        }

        GPv2OrderChecks.validate(
            _order,
            GPv2OrderChecks.Binding({
                orderDigest: orderDigest,
                domainSeparator: DOMAIN_SEPARATOR,
                expectedAppData: keccak256(bytes(EXPECTED_APP_DATA))
            }),
            address(this),
            slippagePriceChecker,
            allowedSlippageInBps
        );

        return MAGIC_VALUE;
    }

    /// @notice The appData document (and its hash) every reward order must carry
    function expectedAppData() external pure returns (string memory doc, bytes32 hash) {
        doc = EXPECTED_APP_DATA;
        hash = keccak256(bytes(EXPECTED_APP_DATA));
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Internal function to deposit tokens according to current market splits
     * @param amount The amount of tokens to deposit
     */
    function depositInternal(uint256 amount) internal {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));
        uint256 deposited = 0;

        // Find the last active market with nonzero split for remainder handling, and check the
        // active allocation is complete. The remainder branch below is a DUST sink (integer
        // division leftovers); without this guard it silently absorbs the entire allocation of a
        // market that was just deactivated — 40/30/30 with B deactivated would send 60% of the
        // deposit to C, which is configured for 30%. Depositing is blocked during that window
        // until updatePosition (or the factory's split config) restores a complete allocation.
        uint256 lastActiveIdx = type(uint256).max;
        uint256 totalActiveSplit = 0;
        for (uint256 i = regMarkets.length; i > 0; i--) {
            if (!regMarkets[i - 1].active) continue;

            uint256 activeSplit = marketSplitBps[regMarkets[i - 1].target];
            totalActiveSplit += activeSplit;
            if (activeSplit > 0 && lastActiveIdx == type(uint256).max) {
                lastActiveIdx = i - 1;
            }
        }
        require(totalActiveSplit == SPLIT_TOTAL, "Split parameters must add up to SPLIT_TOTAL");

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
     * @notice Withdraws `amountNeeded` underlying tokens, pro-rata by split where possible
     * @param amountNeeded The total amount of underlying tokens needed
     * @dev Splits are a target allocation, not a statement about what each market currently holds.
     *      Balances drift with interest, an ERC4626 vault can cap what it will pay out, exit fees
     *      make a share worth less than its configured share of principal, and during the
     *      deactivate-then-updatePosition window the active splits do not describe the whole
     *      position at all. So each market is asked for at most its CURRENT capacity, the
     *      shortfall is carried forward, and a second pass sweeps every market — including
     *      inactive ones, which still hold funds — until the amount is covered. Anything less
     *      makes withdraw() revert on ordinary drift while withdrawAll() would have succeeded.
     */
    function _withdrawProRata(uint256 amountNeeded) internal {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));
        uint256 remaining = amountNeeded;

        // Pass 1: pro-rata against the configured allocation, capped at each market's capacity.
        for (uint256 i = 0; i < regMarkets.length && remaining > 0; i++) {
            if (!regMarkets[i].active) continue;

            uint256 split = marketSplitBps[regMarkets[i].target];
            if (split == 0) continue;

            uint256 target = (amountNeeded * split) / SPLIT_TOTAL;
            if (target > remaining) target = remaining;

            // Clamped, not subtracted: _withdrawUpTo reports a measured balance DELTA, and nothing
            // in the ERC4626/mToken interfaces forbids a market paying out more than was asked for.
            // A bare `-=` would panic on the overshoot and revert a withdrawal that had in fact
            // already been over-covered.
            remaining = _subFloorZero(remaining, _withdrawUpTo(regMarkets[i], target));
        }

        // Pass 2: cover the shortfall from wherever the funds actually are.
        for (uint256 i = 0; i < regMarkets.length && remaining > 0; i++) {
            remaining = _subFloorZero(remaining, _withdrawUpTo(regMarkets[i], remaining));
        }

        require(remaining == 0, "Withdrawal failed: insufficient market liquidity");
    }

    /**
     * @notice Withdraws at most `amount` underlying from a single market
     * @return withdrawn The amount of underlying tokens this strategy actually received
     * @dev Measured as a balance delta rather than trusting the requested amount, so a market
     *      that pays out less (or, for a WETH mToken, pays in native ETH that `receive` wraps)
     *      is accounted correctly.
     */
    function _withdrawUpTo(RegistryMarket memory market, uint256 amount) internal returns (uint256 withdrawn) {
        if (amount == 0) return 0;

        uint256 balanceBefore = token.balanceOf(address(this));

        if (market.marketType == MarketType.MTOKEN) {
            // Two independent ceilings, and only taking the lower of them keeps this a partial
            // withdrawal instead of a revert. What the strategy owns is balanceOfUnderlying; what
            // the market can actually pay out today is getCash() — the rest is lent to borrowers.
            // Asking for more than the cash returns TOKEN_INSUFFICIENT_CASH, which the require
            // below turns into a hard revert of the ENTIRE withdrawal, including the second pass
            // that would have covered the shortfall from a market that does have the funds.
            uint256 capacity = IMToken(market.target).balanceOfUnderlying(address(this));
            uint256 cash = IMToken(market.target).getCash();
            if (cash < capacity) capacity = cash;

            uint256 toWithdraw = amount > capacity ? capacity : amount;
            if (toWithdraw == 0) return 0;
            require(IMToken(market.target).redeemUnderlying(toWithdraw) == 0, "Failed to redeem mToken");
        } else {
            // maxWithdraw already accounts for the vault's withdrawal fee and liquidity limits.
            uint256 capacity = IERC4626(market.target).maxWithdraw(address(this));
            if (capacity == 0) return 0;

            if (amount >= capacity) {
                // Taking the whole capacity goes through redeem(maxRedeem), not withdraw(maxWithdraw).
                // The two are only equivalent when the vault's asset<->share conversions are exactly
                // self-inverse; a vault whose maxWithdraw floors while previewWithdraw ceils reports
                // a capacity that costs one more share than it holds, and withdraw() reverts at
                // precisely the boundary this branch always sits on. Share-denominated exit has no
                // such boundary — maxRedeem is by definition redeemable.
                uint256 shares = IERC4626(market.target).maxRedeem(address(this));
                if (shares == 0) return 0;
                IERC4626(market.target).redeem(shares, address(this), address(this));
            } else {
                IERC4626(market.target).withdraw(amount, address(this), address(this));
            }
        }

        return token.balanceOf(address(this)) - balanceBefore;
    }

    /**
     * @notice Withdraws all funds from all markets (including inactive, to recover stuck funds)
     */
    function _withdrawAllFromMarkets() internal {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));

        for (uint256 i = 0; i < regMarkets.length; i++) {
            _withdrawFromMarket(regMarkets[i]);
        }
    }

    /**
     * @notice Withdraws as much as the market can currently pay out
     * @dev Best-effort, NOT all-or-nothing. A Moonwell market that is fully lent out cannot honour
     *      a full-position redeem, and reverting here would take down every caller: withdrawAll()
     *      (the documented recovery route), and updatePosition(), which opens with this sweep and
     *      is the only way to repair a split configuration. Draining what cash there is and leaving
     *      the remainder earning interest is strictly better than bricking all three.
     */
    function _withdrawFromMarket(RegistryMarket memory market) internal {
        if (market.marketType == MarketType.MTOKEN) {
            uint256 mTokenBalance = IERC20(market.target).balanceOf(address(this));
            if (mTokenBalance == 0) return;

            uint256 underlying = IMToken(market.target).balanceOfUnderlying(address(this));
            uint256 cash = IMToken(market.target).getCash();

            if (cash >= underlying) {
                // Share-denominated so the whole position leaves, dust included.
                require(IMToken(market.target).redeem(mTokenBalance) == 0, "Failed to redeem mToken");
            } else if (cash > 0) {
                require(IMToken(market.target).redeemUnderlying(cash) == 0, "Failed to redeem mToken");
            }
        } else {
            uint256 shareBalance = IERC4626(market.target).balanceOf(address(this));
            if (shareBalance == 0) return;

            // Decide in ASSET terms, then act in SHARE terms. Comparing `maxRedeem` against the
            // share balance directly does not work on MetaMorpho: its maxRedeem round-trips
            // shares -> assets -> shares with a floor at each step, so even with ample liquidity it
            // comes back a few units short and a redeem(maxRedeem) leaves permanent share dust
            // behind. maxWithdraw and previewRedeem are both asset-denominated and both floor once,
            // so they agree exactly whenever the vault can honour the whole position.
            if (
                IERC4626(market.target).maxWithdraw(address(this))
                    >= IERC4626(market.target).previewRedeem(shareBalance)
            ) {
                IERC4626(market.target).redeem(shareBalance, address(this), address(this));
            } else {
                // Genuinely liquidity-constrained: take what the vault will pay and leave the rest.
                uint256 redeemable = IERC4626(market.target).maxRedeem(address(this));
                if (redeemable > 0) {
                    IERC4626(market.target).redeem(redeemable, address(this), address(this));
                }
            }
        }
    }

    /**
     * @notice Gets the total balance of tokens across all markets + idle
     * @dev Includes inactive markets so withdraw() reflects actual holdings
     * @return The total balance in underlying tokens
     */
    function _getTotalBalance() internal returns (uint256) {
        uint256 total = token.balanceOf(address(this));
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));

        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (regMarkets[i].marketType == MarketType.MTOKEN) {
                total += IMToken(regMarkets[i].target).balanceOfUnderlying(address(this));
            } else {
                uint256 shares = IERC4626(regMarkets[i].target).balanceOf(address(this));
                if (shares > 0) {
                    // previewRedeem, not convertToAssets: per EIP-4626 convertToAssets excludes
                    // withdrawal fees, so it reports a gross value the shares cannot actually
                    // deliver — withdraw() would accept an amount the vault then refuses to pay.
                    total += IERC4626(regMarkets[i].target).previewRedeem(shares);
                }
            }
        }

        return total;
    }

    /// @dev Saturating subtraction, so an over-delivering market cannot panic the withdrawal loop
    function _subFloorZero(uint256 a, uint256 b) internal pure returns (uint256) {
        return b >= a ? 0 : a - b;
    }

    /**
     * @notice Validates that active market splits sum to SPLIT_TOTAL
     */
    function _validateTotalSplit() internal view {
        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));
        uint256 total = 0;

        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (regMarkets[i].active) {
                total += marketSplitBps[regMarkets[i].target];
            }
        }
        require(total == SPLIT_TOTAL, "Split parameters must add up to SPLIT_TOTAL");
    }

    /**
     * @notice How much of `balance` has never had the compound fee charged on it
     * @dev Two observables, both of which only this contract writes:
     *      - `rewardFeeCharged[t]`, set to the whole balance at the end of every settlement;
     *      - the VAULT_RELAYER allowance, set to the same value at the same moment.
     *      Between settlements the relayer is the only party that can move tokens out without
     *      going through this contract, and every unit it moves decrements the allowance by one.
     *      So `charged - allowance` is exactly the CoW outflow since the last settlement, and
     *      subtracting it prevents the (now too high) anchor from swallowing an equal amount of
     *      rewards that arrived afterwards — the concrete bypass being: let a swap drain the
     *      balance, then permissionlessly claim the next epoch's rewards from the distributor.
     *      The final clamp covers any other outflow the contract itself performed.
     */
    function _unchargedRewards(address rewardToken, uint256 balance) internal view returns (uint256) {
        uint256 charged = rewardFeeCharged[rewardToken];

        uint256 allowanceLeft = IERC20(rewardToken).allowance(address(this), VAULT_RELAYER);
        if (allowanceLeft < charged) charged = allowanceLeft;
        if (charged > balance) charged = balance;

        return balance - charged;
    }

    /// @dev A reward token is anything the price checker will price that is NEITHER the strategy's
    ///      own asset NOR one of its market positions. Both exclusions exist for the same reason:
    ///      {sweepRewardFees} transfers a cut to the fee recipient and approves the relayer for the
    ///      remainder, so anything that reaches it is treated as yield rather than principal.
    ///      Approving the underlying would put every user deposit within reach of a CoW order;
    ///      approving an mToken or 4626 share does the same one level up, and because
    ///      `sweepRewardFees` is permissionless a single mistaken price-checker entry would let
    ///      anyone tax 5% of the position's shares. That entry cannot be walked back either —
    ///      SlippagePriceChecker.removeTokenConfiguration leaves `maxTimePriceValid` set, so
    ///      `isRewardToken` is a one-way latch — which is what makes the redundant check here worth
    ///      its gas.
    function _requireRewardToken(address rewardToken) internal view {
        require(rewardToken != address(token), "Not a reward token");
        require(!_isMarketTarget(rewardToken), "Market share is not a reward token");
        require(slippagePriceChecker.isRewardToken(rewardToken), "Token not allowed");
    }

    /// @dev Non-reverting counterpart of {_requireRewardToken}, for the batch paths that must skip
    ///      an unsettleable token rather than take the whole call down with it.
    function _isSettleableRewardToken(address rewardToken) internal view returns (bool) {
        return rewardToken != address(token) && !_isMarketTarget(rewardToken)
            && slippagePriceChecker.isRewardToken(rewardToken);
    }

    /// @dev Scans the registry's market list rather than calling isMarketActive, which REVERTS for
    ///      an unregistered target — the common case here — and would turn a check into a failure.
    ///      Deactivated markets count too: the strategy can still be holding their shares.
    ///
    ///      The unset-registry branch is NOT defensive padding. A live v1 proxy sits at
    ///      `marketRegistry == address(0)` for the whole window between being upgraded to this
    ///      implementation and its `migrateV1ToMarketRegistry` call, and its positions are still in
    ///      the legacy `mToken` / `metaMorphoVault` slots. Calling `getMarkets` on the zero address
    ///      there reverts, which would take down `claimRewards`, the permissionless
    ///      `sweepRewardFees`, and reward-token `recoverERC20` for every un-migrated strategy —
    ///      paths that worked before this check existed. Reading the legacy slots keeps the
    ///      protection itself intact across the window rather than merely skipping it.
    function _isMarketTarget(address candidate) internal view returns (bool) {
        if (address(marketRegistry) == address(0)) {
            return candidate == address(mToken) || candidate == address(metaMorphoVault);
        }

        RegistryMarket[] memory regMarkets = marketRegistry.getMarkets(address(token));
        for (uint256 i = 0; i < regMarkets.length; i++) {
            if (regMarkets[i].target == candidate) return true;
        }
        return false;
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
