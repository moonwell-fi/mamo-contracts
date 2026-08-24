// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {ILeveragedAeroCLStrategy} from "@interfaces/ILeveragedAeroCLStrategy.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
 *      - EVERY withdrawal path pays `owner()` in the transaction that settles it (the async path by naming
 *        `owner()` as the pooled request's RECIPIENT), so no proceeds ever rest on this account.
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

    /// @dev Open async redeem ids. A tracked id reading `settled` is a COMPLETED request, not unclaimed
    ///      money — stale bookkeeping, pruned by every path that touches the set.
    uint256[] private _openRequestIds;

    /// @notice Ceiling on simultaneously-tracked async requests, bounding the gas of the scans over it.
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

        emit Deposit(msg.sender, assets, shares);
    }

    /**
     * @notice Deposit `assets` of this account's idle USDC into the Sherwood strategy (owner or backend).
     * @dev Users can plain-transfer USDC to their account; the backend then nudges it in via this call
     *      (mirrors `depositIdleTokens` in MamoMultiMarketStrategy). Reverts if there is no idle USDC.
     *      The CALLER sizes the amount to `vault.remainingCapacity()`, since
     *      {LeveragedAeroVault.maxTotalAssets} rejects rather than trims. NO unclaimed-proceeds gate on the
     *      backend: no proceeds can rest here, so idle USDC is always money sent in. Both callers prune.
     * @param assets    Idle USDC to deposit (6dp); must be non-zero and at most the balance held.
     * @param minShares Minimum vault shares to accept (slippage guard).
     * @return shares Vault shares minted to this account (12dp).
     */
    function depositIdle(uint256 assets, uint256 minShares) external returns (uint256 shares) {
        require(msg.sender == owner() || msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not owner or backend");
        _pruneSettled();

        require(assets > 0, "Amount must be greater than 0");
        require(assets <= usdc.balanceOf(address(this)), "Insufficient idle USDC");

        usdc.forceApprove(address(sherwoodStrategy), assets);
        shares = sherwoodStrategy.deposit(assets, minShares);

        emit Deposit(msg.sender, assets, shares);
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
     * @dev The recipient is captured HERE and immutable pooled-side, so a `transferOwnership` before the
     *      fulfil still pays the address that asked; the new owner's remedy is {cancelWithdraw} + re-request.
     *      Prunes first, so a completed request cannot consume the {MAX_OPEN_REQUESTS} budget.
     * @param shares Vault shares to escrow (12dp).
     * @param minAssetsOut Slippage floor enforced at fulfill.
     * @return id The request id.
     */
    function requestWithdraw(uint256 shares, uint256 minAssetsOut) external onlyOwner returns (uint256 id) {
        require(shares > 0, "Amount must be greater than 0");
        _pruneSettled();
        require(_openRequestIds.length < MAX_OPEN_REQUESTS, "Too many open requests");

        vaultShares.forceApprove(address(sherwoodStrategy), shares);
        id = sherwoodStrategy.requestRedeem(shares, minAssetsOut, owner());
        _openRequestIds.push(id);

        emit WithdrawRequested(id, shares, minAssetsOut);
    }

    /**
     * @notice Cancel an outstanding async redeem request, returning the escrowed shares to this account.
     * @param id Request id to cancel.
     */
    function cancelWithdraw(uint256 id) external onlyOwner {
        sherwoodStrategy.cancelRedeem(id);
        // BY ID ONLY: a cancel returns SHARES, so a blanket prune would clear the gate for other proceeds.
        _untrack(id);

        emit WithdrawCancelled(id);
    }

    /**
     * @notice Trustless emergency redeem of an unfulfilled request after the strategy's fulfill window,
     *         paying USDC to the owner.
     * @dev The strategy pays this account here, not the recipient, so the amount is forwarded on — same end
     *      payee as a fulfil, one hop more.
     * @param id Request id (owner-gated on the strategy side too).
     * @param minAssetsOut Fresh slippage floor on the net payout.
     * @return assetsOut USDC forwarded to the owner (6dp).
     */
    function emergencyWithdraw(uint256 id, uint256 minAssetsOut) external onlyOwner returns (uint256 assetsOut) {
        assetsOut = sherwoodStrategy.emergencyRedeem(id, minAssetsOut);

        _forwardToOwner(assetsOut);
        // BY ID ONLY, as in {cancelWithdraw}: this pays straight through, leaving nothing unclaimed here.
        _untrack(id);

        emit WithdrawEmergency(id, assetsOut);
    }

    /**
     * @notice Sweep this account's entire idle USDC balance to the owner.
     * @dev NOT the withdrawal claim (a fulfil pays `owner()` directly): sweeps only USDC that arrived some
     *      other way, e.g. a plain transfer.
     * @return amount USDC swept to the owner (6dp).
     */
    function claimWithdrawnUsdc() external onlyOwner returns (uint256 amount) {
        amount = usdc.balanceOf(address(this));
        require(amount > 0, "No USDC to claim");

        _pruneSettled();
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

    /// @notice Deprecated alias of {hasSettledRequest}, kept for ABI compatibility. `true` means COMPLETED.
    function hasUnclaimedWithdrawal() public view returns (bool) {
        return hasSettledRequest();
    }

    /// @notice True while a tracked async request has settled, i.e. completed.
    /// @dev The completion signal a frontend polls (no account-side event on fulfil); gates nothing.
    function hasSettledRequest() public view returns (bool) {
        uint256 n = _openRequestIds.length;
        for (uint256 i; i < n; ++i) {
            if (sherwoodStrategy.redeemRequest(_openRequestIds[i]).settled) return true;
        }
        return false;
    }

    /// @notice The async request ids this account is tracking — the set {hasSettledRequest} scans.
    function openRequestIds() external view returns (uint256[] memory) {
        return _openRequestIds;
    }

    /// @notice Owner escape hatch: drop every tracked request that has settled.
    /// @dev Explicit housekeeping only — {requestWithdraw}, {depositIdle} and {claimWithdrawnUsdc} prune too.
    function syncRedeemRequests() external onlyOwner {
        _pruneSettled();
    }

    // ==================== INTERNAL ====================

    /// @dev Drop `id` from the tracked set (swap-pop; order carries no meaning). No-op if absent.
    function _untrack(uint256 id) private {
        uint256 n = _openRequestIds.length;
        for (uint256 i; i < n; ++i) {
            if (_openRequestIds[i] == id) {
                _openRequestIds[i] = _openRequestIds[n - 1];
                _openRequestIds.pop();
                return;
            }
        }
    }

    /// @dev Drop every settled tracked request. Iterates from the TAIL so swap-pop cannot skip an element.
    function _pruneSettled() private {
        uint256 i = _openRequestIds.length;
        while (i > 0) {
            unchecked {
                --i;
            }
            if (sherwoodStrategy.redeemRequest(_openRequestIds[i]).settled) {
                _openRequestIds[i] = _openRequestIds[_openRequestIds.length - 1];
                _openRequestIds.pop();
            }
        }
    }

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
