// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {ILeveragedAeroCLStrategy} from "@interfaces/ILeveragedAeroCLStrategy.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Just the vault's per-account share ceiling. Declared locally so the account needs no new
///      storage pointer — `vaultShares` already IS the vault address (derived at init from
///      `sherwoodStrategy.vault()`), which is why the cap lives on the vault rather than the
///      factory or the registry.
interface ILeveragedAeroVaultCap {
    function maxSharesPerAccount() external view returns (uint256);
}

/**
 * @title MamoLeveragedAeroStrategy
 * @notice A per-user Mamo account contract that wraps the vendored Sherwood leveraged Aerodrome CL
 *         strategy. It holds SyndicateVault shares on the user's behalf and drives the Sherwood
 *         strategy externally: USDC (6dp) flows in on deposit, vault shares are custodied here, and
 *         USDC flows back out to the owner on every withdrawal path.
 * @dev This contract inherits Mamo's {BaseStrategy} (Initializable + UUPSUpgradeable +
 *      OwnableUpgradeable). It deliberately does NOT inherit or extend the Sherwood
 *      `LeveragedAerodromeCLStrategy` — that contract inherits Sherwood's incompatible
 *      vault/proposer base — and interacts with it only through {ILeveragedAeroCLStrategy}.
 *
 *      Deployed behind an {ERC1967Proxy} and used as a UUPS implementation, so all initialization runs
 *      through {initialize} rather than a constructor.
 *
 *      Storage: {BaseStrategy} occupies slots 0-49 (registry, strategyTypeId, and a 48-slot gap), so
 *      this contract's concrete state starts at slot 50. Matching the repo convention set by
 *      {MamoStakingStrategy}, no additional trailing storage gap is declared here; future fields append
 *      after the existing ones.
 *
 *      Design notes:
 *      - Terminal/Settled exit is deliberately NOT implemented as a bespoke flow. The
 *        inherited `recoverERC20(vaultShares, owner, amount)` is an always-available `onlyOwner` hatch
 *        (no state gate — it does not go through the withdraw slippage/LTV path, consistent with the
 *        other Mamo strategies); its intended use here is the Settled terminal state, where the owner
 *        pulls the raw shares out and burns them for their pro-rata slice of the settled USDC via the
 *        vault's `redeemSettled`.
 *      - The fast {withdraw}/{withdrawAll} paths are oracle-dependent and LTV-gated: they revert when the
 *        oracle is down or the LTV gate trips, in which case the owner should route through the async
 *        {requestWithdraw} flow instead.
 *      - Approvals use `forceApprove` for the exact amount immediately before each external call; no
 *        standing approvals are left outstanding.
 */
contract MamoLeveragedAeroStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice The vendored Sherwood leveraged Aerodrome CL strategy this account drives.
    ILeveragedAeroCLStrategy public sherwoodStrategy;

    /// @notice The SyndicateVault share token (12dp) held by this account; also the token approved to
    ///         the Sherwood strategy for redeem/request flows.
    IERC20 public vaultShares;

    /// @notice The USDC token (6dp): the deposit asset and the withdrawal payout token.
    IERC20 public usdc;

    /// @notice Ids of async redeem requests this account has opened and not yet observed as settled.
    /// @dev APPENDED STORAGE (the contract's storage note above sanctions appending; nothing is
    ///      reordered, so existing slots are untouched). Needed because the share cap measures
    ///      `vaultShares.balanceOf(this)`, and {requestWithdraw} moves shares into the strategy's
    ///      escrow — so without this an in-flight request reads as "holds nothing".
    ///
    ///      NOT A MIRROR OF STRATEGY STATE: `settled` is read LIVE from the strategy, because a
    ///      backend `fulfillRedeem` settles a request with no callback to this account. Keeping a
    ///      local settled-flag would therefore drift permanently high after the first fulfill and
    ///      silently shrink the account's cap room forever. This list is only the id SET; truth about
    ///      each id comes from {ILeveragedAeroCLStrategy.redeemRequest}. Settled ids are pruned
    ///      opportunistically, so the list is self-healing.
    uint256[] private _openRequestIds;

    /// @notice Hard ceiling on simultaneously-open async requests, bounding the cap check's gas.
    /// @dev Only reached by the owner opening many requests against their own position; at the limit
    ///      the fix is to cancel or let one settle. Chosen well above any realistic exit pattern.
    uint256 public constant MAX_OPEN_REQUESTS = 16;

    /// @notice Emitted when USDC is deposited and vault shares are minted to this account.
    event Deposit(address indexed depositor, uint256 assets, uint256 shares);

    /// @notice Emitted on a fast-path withdrawal that pays USDC to the owner.
    event Withdraw(address indexed owner, uint256 shares, uint256 assetsOut);

    /// @notice Emitted when an async redeem request is created.
    event WithdrawRequested(uint256 indexed id, uint256 shares, uint256 minAssetsOut);

    /// @notice Emitted when an async redeem request is cancelled and shares are returned to this account.
    event WithdrawCancelled(uint256 indexed id);

    /// @notice Emitted on a trustless emergency redeem that pays USDC to the owner.
    event WithdrawEmergency(uint256 indexed id, uint256 assetsOut);

    /// @notice Emitted when idle USDC on this account is swept to the owner.
    event UsdcClaimed(uint256 amount);

    /// @notice Initialization parameters struct to avoid stack-too-deep and keep the ABI stable.
    struct InitParams {
        address mamoStrategyRegistry;
        uint256 strategyTypeId;
        address owner;
        address sherwoodStrategy;
        address usdc;
    }

    /**
     * @notice Constructor disables initializers in the implementation contract.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer that wires the account to the Mamo registry and the Sherwood strategy.
     * @dev Used instead of a constructor since the contract is deployed behind a proxy. The vault
     *      share token is derived from `sherwoodStrategy.vault()` (single source of truth) rather than
     *      passed separately.
     * @param params The initialization parameters struct.
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.strategyTypeId != 0, "Strategy type id not set");
        require(params.owner != address(0), "Invalid owner address");
        require(params.sherwoodStrategy != address(0), "Invalid sherwoodStrategy address");
        require(params.usdc != address(0), "Invalid usdc address");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        sherwoodStrategy = ILeveragedAeroCLStrategy(params.sherwoodStrategy);
        usdc = IERC20(params.usdc);

        address vault = sherwoodStrategy.vault();
        require(vault != address(0), "Invalid vault address");
        vaultShares = IERC20(vault);
    }

    /**
     * @notice Deposit USDC into the Sherwood strategy, minting vault shares to this account (permissionless).
     * @dev Pulls `assets` USDC from the caller, approves the exact amount to the strategy, and deposits.
     *      Permissionless by design so the backend or any keeper can fund the account; the resulting
     *      shares are always custodied by this account and remain under owner control.
     * @param assets USDC to deposit (6dp).
     * @param minShares Minimum vault shares to accept (slippage guard).
     * @return shares Vault shares minted to this account (12dp).
     */
    function deposit(uint256 assets, uint256 minShares) external returns (uint256 shares) {
        require(assets > 0, "Amount must be greater than 0");

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        usdc.forceApprove(address(sherwoodStrategy), assets);
        shares = sherwoodStrategy.deposit(assets, minShares);
        _assertWithinShareCap();

        emit Deposit(msg.sender, assets, shares);
    }

    /**
     * @notice Deposit `assets` of this account's idle USDC into the Sherwood strategy (owner or backend).
     * @dev Users can plain-transfer USDC to their account; the backend then nudges it in via this call
     *      (mirrors `depositIdleTokens` in MamoMultiMarketStrategy). Reverts if there is no idle USDC.
     *
     *      THE CALLER PICKS THE AMOUNT rather than this depositing the whole balance, and that is what
     *      makes {LeveragedAeroVault.maxSharesPerAccount} usable: an account holding more idle USDC
     *      than its remaining cap room would otherwise be unable to deposit ANYTHING, because the cap
     *      rejects rather than trims. The caller sizes the deposit to the room; the remainder stays
     *      idle and the owner can withdraw it at any time.
     *
     *      Gated to the owner or the registry backend — the repo's trusted-actor pattern. This closes the
     *      anonymous-griefer vector: because idle USDC is ambiguous (it may be pending re-deposit OR a
     *      fulfilled async withdrawal awaiting {claimWithdrawnUsdc}), a permissionless call let any third
     *      party front-run the owner's {claimWithdrawnUsdc} and force a fulfilled withdrawal back into the
     *      leveraged position (repeatable re-lock griefing). A residual footgun remains between the two
     *      trusted actors: the owner claims withdrawals explicitly via {claimWithdrawnUsdc}, so the backend
     *      must only call this when a re-deposit is intended, and the owner and backend coordinate which
     *      idle USDC is which.
     * @param assets    Idle USDC to deposit (6dp); must be non-zero and at most the balance held.
     * @param minShares Minimum vault shares to accept (slippage guard).
     * @return shares Vault shares minted to this account (12dp).
     */
    function depositIdle(uint256 assets, uint256 minShares) external returns (uint256 shares) {
        require(msg.sender == owner() || msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not owner or backend");

        require(assets > 0, "Amount must be greater than 0");
        require(assets <= usdc.balanceOf(address(this)), "Insufficient idle USDC");

        usdc.forceApprove(address(sherwoodStrategy), assets);
        shares = sherwoodStrategy.deposit(assets, minShares);
        _assertWithinShareCap();

        emit Deposit(msg.sender, assets, shares);
    }

    /**
     * @dev Reject the deposit just made if it left this account above the vault's global
     *      {LeveragedAeroVault.maxSharesPerAccount}. `0` there means unlimited.
     *
     *      CHECKED AFTER THE DEPOSIT, DELIBERATELY. The share count is only known once
     *      `sherwoodStrategy.deposit` returns — the strategy has no `previewDeposit`, and its
     *      pricing runs a fee crystallisation first, so any pre-check here would have to duplicate
     *      `mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navNet + 1)` AND stay in lock-step with it
     *      forever. A silent drift between two copies of that formula is a worse failure than the gas
     *      burnt on a reverting path: the revert unwinds the whole transaction, so no shares are
     *      minted and no USDC moves.
     *
     *      Measured against the BALANCE HELD **PLUS SHARES IN ESCROW**, not a running total, so
     *      withdrawing frees room with no bookkeeping. Lowering the cap below an existing position
     *      traps nobody — every withdrawal path ignores the cap entirely.
     *
     *      ESCROW COUNTS, and it has to. {requestWithdraw} moves shares account → strategy, so the
     *      balance alone reads 0 while the position is still fully owned — an in-flight request is a
     *      pending withdrawal, not a completed one, and {cancelWithdraw} is owner-callable in ANY
     *      state with no timing lock. Counting only the balance made the cap trivially bypassable:
     *      `deposit(cap)` → `requestWithdraw(all)` → `deposit(cap)` → `cancelWithdraw` leaves the
     *      account holding 2 × cap, repeatable for gas. Summing live escrow closes that loop while
     *      keeping deposits available during a pending request (up to the real remaining room).
     */
    function _assertWithinShareCap() internal view {
        uint256 cap = ILeveragedAeroVaultCap(address(vaultShares)).maxSharesPerAccount();
        if (cap == 0) return; // unlimited
        uint256 held = vaultShares.balanceOf(address(this)) + _escrowedShares();
        require(held <= cap, "Share cap exceeded");
    }

    /// @dev Shares this account currently has escrowed in the strategy across all UNSETTLED requests.
    ///      Reads `settled` live rather than trusting a local flag — a backend `fulfillRedeem` settles
    ///      without notifying this account.
    function _escrowedShares() internal view returns (uint256 escrowed) {
        uint256[] storage ids = _openRequestIds;
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            ILeveragedAeroCLStrategy.RedeemRequest memory r = sherwoodStrategy.redeemRequest(ids[i]);
            if (!r.settled) escrowed += r.shares;
        }
    }

    /// @dev Drop ids the strategy now reports as settled (fulfilled, cancelled, or emergency-redeemed).
    ///      Swap-and-pop; order is irrelevant. Keeps {_escrowedShares} bounded and self-healing without
    ///      needing a settle callback.
    function _pruneSettledRequests() private {
        uint256[] storage ids = _openRequestIds;
        for (uint256 i = ids.length; i > 0; --i) {
            uint256 idx = i - 1;
            if (sherwoodStrategy.redeemRequest(ids[idx]).settled) {
                ids[idx] = ids[ids.length - 1];
                ids.pop();
            }
        }
    }

    /// @notice Ids of this account's async redeem requests not yet observed as settled.
    /// @dev Introspection for the backend / UI; entries may already be settled on-chain until the next
    ///      state-changing call prunes them.
    function openRequestIds() external view returns (uint256[] memory) {
        return _openRequestIds;
    }

    /// @notice Vault shares this account has escrowed in the strategy across all unsettled requests.
    /// @dev Counts toward {LeveragedAeroVault.maxSharesPerAccount} alongside {sharesBalance}.
    function escrowedShares() external view returns (uint256) {
        return _escrowedShares();
    }

    /**
     * @notice Fast-path withdrawal of `shares`, paying USDC to the owner.
     * @dev Approves the exact share amount to the strategy, calls its oracle-priced `redeem`, and
     *      forwards the returned USDC to the owner. The fast path reverts when the oracle is down or the
     *      LTV gate trips — in that case use {requestWithdraw} instead.
     * @param shares Vault shares to redeem (12dp).
     * @param minAssetsOut Minimum USDC out (slippage guard).
     * @return assetsOut USDC forwarded to the owner (6dp).
     */
    function withdraw(uint256 shares, uint256 minAssetsOut) external onlyOwner returns (uint256 assetsOut) {
        require(shares > 0, "Amount must be greater than 0");

        assetsOut = _redeemAndForward(shares, minAssetsOut);

        emit Withdraw(owner(), shares, assetsOut);
    }

    /**
     * @notice Fast-path withdrawal of this account's entire vault-share balance, paying USDC to the owner.
     * @dev Same oracle/LTV constraints as {withdraw}; route to {requestWithdraw} if the fast path reverts.
     * @param minAssetsOut Minimum USDC out (slippage guard).
     * @return assetsOut USDC forwarded to the owner (6dp).
     */
    function withdrawAll(uint256 minAssetsOut) external onlyOwner returns (uint256 assetsOut) {
        uint256 shares = vaultShares.balanceOf(address(this));
        require(shares > 0, "No shares to withdraw");

        assetsOut = _redeemAndForward(shares, minAssetsOut);

        emit Withdraw(owner(), shares, assetsOut);
    }

    /**
     * @notice Create an async redeem request for `shares` (the exit for sizes the fast path can't serve,
     *         or when the oracle is down).
     * @dev Approves the exact share amount to the strategy and escrows the shares there. The backend
     *      later fulfills the request; the resulting USDC lands on this account with no callback and is
     *      swept to the owner via {claimWithdrawnUsdc}.
     * @param shares Vault shares to escrow (12dp).
     * @param minAssetsOut Slippage floor enforced at fulfill.
     * @return id The request id.
     */
    function requestWithdraw(uint256 shares, uint256 minAssetsOut) external onlyOwner returns (uint256 id) {
        require(shares > 0, "Amount must be greater than 0");

        // Prune first so settled ids never consume a slot, then bound the open set (the cap check
        // iterates it). Pruning here also keeps the common single-request flow at length <= 1.
        _pruneSettledRequests();
        require(_openRequestIds.length < MAX_OPEN_REQUESTS, "Too many open requests");

        vaultShares.forceApprove(address(sherwoodStrategy), shares);
        id = sherwoodStrategy.requestRedeem(shares, minAssetsOut);
        // Tracked so the escrowed shares keep counting against the vault's per-account share cap.
        _openRequestIds.push(id);

        emit WithdrawRequested(id, shares, minAssetsOut);
    }

    /**
     * @notice Cancel an outstanding async redeem request, returning the escrowed shares to this account.
     * @param id Request id to cancel.
     */
    function cancelWithdraw(uint256 id) external onlyOwner {
        sherwoodStrategy.cancelRedeem(id);
        // The shares are back on this account's balance, so the id must stop counting as escrow —
        // otherwise they would be double-counted against the cap.
        _pruneSettledRequests();

        emit WithdrawCancelled(id);
    }

    /**
     * @notice Trustless emergency redeem of an unfulfilled request after the strategy's fulfill window,
     *         paying USDC to the owner.
     * @dev The strategy pays USDC directly to `msg.sender` (this account); the received amount is then
     *      forwarded to the owner.
     * @param id Request id (owner-gated on the strategy side too).
     * @param minAssetsOut Fresh slippage floor on the net payout.
     * @return assetsOut USDC forwarded to the owner (6dp).
     */
    function emergencyWithdraw(uint256 id, uint256 minAssetsOut) external onlyOwner returns (uint256 assetsOut) {
        assetsOut = sherwoodStrategy.emergencyRedeem(id, minAssetsOut);
        // Request is settled and its shares burnt — drop the id so it stops counting as escrow.
        _pruneSettledRequests();

        _forwardToOwner(assetsOut);

        emit WithdrawEmergency(id, assetsOut);
    }

    /**
     * @notice Sweep this account's entire idle USDC balance to the owner.
     * @dev After the backend fulfills an async request, USDC lands on this account with no callback;
     *      this is the owner's explicit claim. It sweeps whatever USDC is idle here — which may include
     *      funds intended for re-deposit (see {depositIdle}); the owner and backend coordinate which is
     *      which, since idle USDC is inherently ambiguous.
     * @return amount USDC swept to the owner (6dp).
     */
    function claimWithdrawnUsdc() external onlyOwner returns (uint256 amount) {
        amount = usdc.balanceOf(address(this));
        require(amount > 0, "No USDC to claim");

        usdc.safeTransfer(owner(), amount);

        emit UsdcClaimed(amount);
    }

    // ==================== VIEWS ====================

    /**
     * @notice The vault shares (12dp) currently held by this account.
     * @return The vault-share balance.
     */
    function sharesBalance() external view returns (uint256) {
        return vaultShares.balanceOf(address(this));
    }

    /**
     * @notice Advisory preview of a fast-path withdrawal (pass-through to the strategy).
     * @param shares Vault shares to preview (12dp).
     * @return assetsOut Predicted USDC out (0 when unpriceable or the payout floors to 0).
     * @return fastOk True iff the fast path would price and clear the LTV gate (advisory).
     */
    function previewWithdraw(uint256 shares) external view returns (uint256 assetsOut, bool fastOk) {
        return sherwoodStrategy.previewRedeem(shares);
    }

    /**
     * @notice The Sherwood strategy's lifecycle state (pass-through).
     * @return The strategy lifecycle state.
     */
    function strategyState() external view returns (ILeveragedAeroCLStrategy.State) {
        return sherwoodStrategy.state();
    }

    // ==================== INTERNAL ====================

    /**
     * @notice Shared body of {withdraw}/{withdrawAll}: approve the exact shares, fast-redeem, and forward
     *         the returned USDC to the owner.
     * @param shares Vault shares to redeem (12dp).
     * @param minAssetsOut Minimum USDC out (slippage guard).
     * @return assetsOut USDC forwarded to the owner (6dp).
     */
    function _redeemAndForward(uint256 shares, uint256 minAssetsOut) internal returns (uint256 assetsOut) {
        vaultShares.forceApprove(address(sherwoodStrategy), shares);
        assetsOut = sherwoodStrategy.redeem(shares, minAssetsOut);

        _forwardToOwner(assetsOut);
    }

    /**
     * @notice Forward `amount` USDC to the owner, skipping the transfer when there is nothing to send.
     * @param amount USDC to forward to the owner (6dp).
     */
    function _forwardToOwner(uint256 amount) private {
        if (amount > 0) {
            usdc.safeTransfer(owner(), amount);
        }
    }
}
