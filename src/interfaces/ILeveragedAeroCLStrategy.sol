// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ILeveragedAeroCLStrategy
 * @notice Minimal interface for the vendored {LeveragedAerodromeCLStrategy}, exposing
 *         exactly the entrypoints and views that {MamoLeveragedAeroStrategy} drives externally.
 * @dev Signatures are verified byte-for-byte against
 *      `src/leveraged-aero/LeveragedAerodromeCLStrategy.sol` and its base
 *      `src/leveraged-aero/BaseStrategy.sol`. This interface is intentionally NOT the full
 *      strategy surface: it omits proposer-only ops (deployIdle / compound / rerange / adjustLeverage /
 *      fulfillRedeem), the settle/execute lifecycle, and the diamond-storage views. Importing the
 *      concrete contract would drag in the entire vendored dependency tree, so the wrapper depends on
 *      this narrow interface instead.
 *
 *      The vault (share ERC-20) is deliberately not typed here: the wrapper reads/approves shares via
 *      the OpenZeppelin `IERC20` returned by {vault}, since the vendored `ILeveragedAeroVault` does not
 *      extend `IERC20`.
 */
interface ILeveragedAeroCLStrategy {
    /// @notice Strategy lifecycle state. Ordering MUST match the vendored `BaseStrategy.State`.
    enum State {
        Pending, // 0
        Executed, // 1
        Settled // 2

    }

    /// @notice An escrowed async-redeem request; field order MUST match the vendored
    ///         `LeveragedAerodromeCLStrategy.RedeemRequest`, which it is ABI-decoded from.
    struct RedeemRequest {
        address owner; // the only address that can cancel / emergency-redeem it
        uint256 shares;
        uint256 minAssetsOut;
        uint40 requestedAt; // the deadman clock anchor
        bool settled; // set once fulfilled / cancelled / emergency-redeemed
        address recipient; // the `fulfillRedeem` payee, fixed at request time; never zero
    }

    /**
     * @notice Oracle-priced deposit: pulls `assets` USDC via `safeTransferFrom(msg.sender)` and mints
     *         vault shares to `msg.sender`. Requires `state() == State.Executed`.
     * @param assets USDC to deposit (6dp).
     * @param minShares Minimum vault shares to accept (slippage guard).
     * @return shares Vault shares minted to the caller (12dp).
     */
    function deposit(uint256 assets, uint256 minShares) external returns (uint256 shares);

    /**
     * @notice Oracle-priced fast-path redeem. Pulls `shares` from `msg.sender` via `safeTransferFrom`
     *         (caller must approve the strategy on the VAULT token first) and pays USDC to `msg.sender`.
     * @dev Can revert on oracle staleness or when the withdraw would breach `maxLtvBps`
     *      (`FastRedeemExceedsLtv`); callers should fall back to {requestRedeem}.
     * @param shares Vault shares to redeem (12dp).
     * @param minAssetsOut Minimum USDC out (slippage guard).
     * @return assetsOut USDC paid to the caller (6dp).
     */
    function redeem(uint256 shares, uint256 minAssetsOut) external returns (uint256 assetsOut);

    /**
     * @notice Escrows `shares` for an async proportional redeem. Pulls shares via `safeTransferFrom`
     *         (caller must approve the strategy on the VAULT token first).
     * @param shares Vault shares to escrow (12dp).
     * @param minAssetsOut Slippage floor enforced at fulfill.
     * @param recipient Payee of the eventual `fulfillRedeem` payout, fixed here; 0 means `msg.sender`.
     * @return id The request id.
     */
    function requestRedeem(uint256 shares, uint256 minAssetsOut, address recipient) external returns (uint256 id);

    /**
     * @notice Cancels an unsettled request and returns the escrowed shares to its owner.
     * @dev Request owner only; callable in ANY strategy state. Shares go to `owner`, never `recipient`.
     * @param id Request id to cancel.
     */
    function cancelRedeem(uint256 id) external;

    /**
     * @notice Deadman trustless backstop: after the fulfill window elapses on an unfulfilled request,
     *         its owner may self-fulfill via an oracle-free proportional unwind; pays USDC to `msg.sender`.
     * @dev Pays `owner` (== `msg.sender`), NOT `recipient`: it returns `assetsOut` for its caller to forward.
     * @param id Request id (owner-gated).
     * @param minAssetsOut Fresh slippage floor on the net payout.
     * @return assetsOut USDC paid to the caller (6dp).
     */
    function emergencyRedeem(uint256 id, uint256 minAssetsOut) external returns (uint256 assetsOut);

    /**
     * @notice Advisory preview of the fast-path redeem.
     * @param shares Vault shares to preview (12dp).
     * @return assetsOut Predicted USDC out (0 when unpriceable or the payout floors to 0).
     * @return fastOk True iff the fast path would price AND clear the LTV gate (advisory).
     */
    function previewRedeem(uint256 shares) external view returns (uint256 assetsOut, bool fastOk);

    /// @notice A single escrowed async-redeem request by id — an in-flight request moves shares to the
    ///         strategy, so `balanceOf` alone understates a holder's position.
    function redeemRequest(uint256 id) external view returns (RedeemRequest memory);

    /// @notice The current strategy lifecycle state.
    function state() external view returns (State);

    /// @notice The SyndicateVault (share ERC-20) this strategy mints/burns against.
    function vault() external view returns (address);
}
