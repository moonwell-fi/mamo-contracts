// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockSyndicateVault} from "./MockSyndicateVault.sol";
import {ILeveragedAeroCLStrategy} from "@interfaces/ILeveragedAeroCLStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockLeveragedAeroCLStrategy
 * @notice Simple-accounting stand-in for the vendored Sherwood LeveragedAerodromeCLStrategy, used by
 *         the MamoLeveragedAeroStrategy wrapper unit tests. Implements the full
 *         {ILeveragedAeroCLStrategy} surface plus a couple of test-only helpers.
 *
 * @dev Fixed-point convention (documented once, applied everywhere):
 *      - USDC has 6 decimals; vault shares have 12 decimals (a 1e6 decimal gap).
 *      - `pricePerShareE18` is the price scaled by 1e18. Its DEFAULT of 1e18 means "par": depositing
 *        1 whole USDC (1e6 units) mints exactly 1 whole share (1e12 units), and redeeming 1 whole
 *        share returns 1 whole USDC. Raising `pricePerShareE18` above 1e18 makes each share worth
 *        MORE USDC (simulates strategy profit); lowering it simulates loss.
 *
 *        shares  = assets * DECIMAL_GAP * PRICE_SCALE / pricePerShareE18
 *        assets  = shares * pricePerShareE18 / (DECIMAL_GAP * PRICE_SCALE)
 *
 *      The mock CUSTODIES the USDC deposited into it and pays redemptions out of that balance; tests
 *      `deal`/`mint` extra USDC to the mock to fund profit scenarios.
 */
contract MockLeveragedAeroCLStrategy is ILeveragedAeroCLStrategy {
    using SafeERC20 for IERC20;

    uint256 private constant DECIMAL_GAP = 1e6; // 12dp shares vs 6dp USDC
    uint256 private constant PRICE_SCALE = 1e18;

    MockSyndicateVault public immutable vaultToken;
    IERC20 public immutable usdc;

    /// @notice Lifecycle state; defaults to Executed so deposit/redeem work out of the box. The
    ///         auto-generated getter satisfies {ILeveragedAeroCLStrategy.state}.
    State public override state = State.Executed;

    /// @notice Price of a share, scaled by 1e18 (default 1e18 == par). Settable for profit/loss tests.
    uint256 public pricePerShareE18 = 1e18;

    /// @notice When true, the fast-path {redeem} reverts and {previewRedeem} reports fastOk == false,
    ///         simulating an oracle-down / LTV-gate condition.
    bool public fastPathBlocked;

    /// @notice The fund's NAV in USDC (6dp), used ONLY by the capacity check. Set explicitly by tests
    ///         rather than derived, so a suite can put the book at any level independently of the
    ///         share pricing above.
    uint256 public nav;

    function setNav(uint256 nav_) external {
        nav = nav_;
    }

    /// @dev `RedeemRequest` is INHERITED from {ILeveragedAeroCLStrategy}, which now declares it so the
    ///      account can read escrowed shares off the real strategy's getter. Redeclaring it here would
    ///      shadow that type and let the mock's field order drift from the contract it stands in for.
    mapping(uint256 => RedeemRequest) public requests;
    uint256 public nextRequestId;

    constructor(address vault_, address usdc_) {
        vaultToken = MockSyndicateVault(vault_);
        usdc = IERC20(usdc_);
    }

    // ==================== TEST SETTERS ====================

    function setState(State state_) external {
        state = state_;
    }

    function setPricePerShareE18(uint256 price_) external {
        pricePerShareE18 = price_;
    }

    function setFastPathBlocked(bool blocked_) external {
        fastPathBlocked = blocked_;
    }

    // ==================== CONVERSIONS ====================

    function _sharesForAssets(uint256 assets) internal view returns (uint256) {
        return (assets * DECIMAL_GAP * PRICE_SCALE) / pricePerShareE18;
    }

    function _assetsForShares(uint256 shares) internal view returns (uint256) {
        return (shares * pricePerShareE18) / (DECIMAL_GAP * PRICE_SCALE);
    }

    // ==================== ILeveragedAeroCLStrategy ====================

    function deposit(uint256 assets, uint256 minShares) external override returns (uint256 shares) {
        require(state == State.Executed, "MockSherwood: not executed");

        // FUND CAPACITY, mirroring the real strategy's check against `vault.maxTotalAssets()`:
        // measured pre-transfer on the POST-deposit book, `0` == unlimited, and a deposit that would
        // CROSS the ceiling is rejected outright rather than trimmed. Modelled here so the account
        // suite covers the wiring — the account itself no longer enforces anything.
        uint256 cap = vaultToken.maxTotalAssets();
        require(cap == 0 || nav + assets <= cap, "MockSherwood: fund at capacity");

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        shares = _sharesForAssets(assets);
        require(shares >= minShares, "MockSherwood: min shares");

        vaultToken.strategyMint(msg.sender, shares);
    }

    function redeem(uint256 shares, uint256 minAssetsOut) external override returns (uint256 assetsOut) {
        require(state == State.Executed, "MockSherwood: not executed");
        require(!fastPathBlocked, "FastRedeemExceedsLtv");

        // Pull the shares in and burn them (mirrors the wrapper approving shares to us first).
        IERC20(address(vaultToken)).safeTransferFrom(msg.sender, address(this), shares);
        vaultToken.strategyBurn(shares);

        assetsOut = _assetsForShares(shares);
        require(assetsOut >= minAssetsOut, "MockSherwood: min assets out");

        usdc.safeTransfer(msg.sender, assetsOut);
    }

    function requestRedeem(uint256 shares, uint256 minAssetsOut) external override returns (uint256 id) {
        require(state == State.Executed, "MockSherwood: not executed");

        IERC20(address(vaultToken)).safeTransferFrom(msg.sender, address(this), shares);

        id = nextRequestId++;
        requests[id] = RedeemRequest({
            owner: msg.sender,
            shares: shares,
            minAssetsOut: minAssetsOut,
            requestedAt: uint40(block.timestamp), // uint40 to match the real strategy's struct
            settled: false
        });
    }

    function cancelRedeem(uint256 id) external override {
        RedeemRequest storage req = requests[id];
        require(req.owner == msg.sender, "MockSherwood: not request owner");
        require(!req.settled, "MockSherwood: already settled");

        req.settled = true;
        IERC20(address(vaultToken)).safeTransfer(req.owner, req.shares);
    }

    function emergencyRedeem(uint256 id, uint256 minAssetsOut) external override returns (uint256 assetsOut) {
        require(state == State.Executed, "MockSherwood: not executed");

        RedeemRequest storage req = requests[id];
        require(req.owner == msg.sender, "MockSherwood: not request owner");
        require(!req.settled, "MockSherwood: already settled");
        require(block.timestamp > req.requestedAt + 2 days, "MockSherwood: fulfill window not elapsed");

        assetsOut = _assetsForShares(req.shares);
        require(assetsOut >= minAssetsOut, "MockSherwood: min assets out");

        req.settled = true;
        vaultToken.strategyBurn(req.shares);
        usdc.safeTransfer(msg.sender, assetsOut);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256 assetsOut, bool fastOk) {
        return (_assetsForShares(shares), !fastPathBlocked);
    }

    /// @dev Mirrors the real strategy's `redeemRequest` getter, which the account reads to track a
    ///      pending async withdrawal. An unknown id returns the zero struct (`settled == false`,
    ///      `shares == 0`), exactly how the real mapping behaves.
    function redeemRequest(uint256 id) external view override returns (RedeemRequest memory) {
        return requests[id];
    }

    function vault() external view override returns (address) {
        return address(vaultToken);
    }

    // ==================== TEST-ONLY HELPER ====================

    /**
     * @notice Fulfills an escrowed async request: burns the escrowed shares, enforces the LARGER of the
     *         stored `minAssetsOut` and the fresh `minAssetsOut` argument, and pays USDC to the request
     *         owner. No proposer gate (test helper). Mirrors the real strategy's `max(stored, fresh)`
     *         rule — the requester's floor is never lowerable by whoever fulfils.
     */
    function fulfillRedeem(uint256 id, uint256 minAssetsOut) external returns (uint256 assetsOut) {
        RedeemRequest storage req = requests[id];
        require(!req.settled, "MockSherwood: already settled");

        assetsOut = _assetsForShares(req.shares);
        uint256 floor = minAssetsOut > req.minAssetsOut ? minAssetsOut : req.minAssetsOut;
        require(assetsOut >= floor, "MockSherwood: min assets out");

        req.settled = true;
        vaultToken.strategyBurn(req.shares);
        usdc.safeTransfer(req.owner, assetsOut);
    }
}
