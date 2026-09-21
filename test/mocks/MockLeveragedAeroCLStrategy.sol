// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockLeveragedAeroVault} from "./MockLeveragedAeroVault.sol";
import {ILeveragedAeroCLStrategy} from "@interfaces/ILeveragedAeroCLStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockLeveragedAeroCLStrategy
 * @notice Simple-accounting stand-in for the vendored LeveragedAerodromeCLStrategy, used by
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

    MockLeveragedAeroVault public immutable vaultToken;
    IERC20 public immutable usdc;

    /// @notice Lifecycle state; defaults to Executed so deposit/redeem work out of the box. The
    ///         auto-generated getter satisfies {ILeveragedAeroCLStrategy.state}.
    State public override state = State.Executed;

    /// @notice Price of a share, scaled by 1e18 (default 1e18 == par). Settable for profit/loss tests.
    uint256 public pricePerShareE18 = 1e18;

    /// @notice When true, the fast-path {redeem} reverts and {previewRedeem} reports fastOk == false,
    ///         simulating an oracle-down / LTV-gate condition.
    bool public fastPathBlocked;

    /// @notice Fund NAV in USDC (6dp), used only by the capacity check; set explicitly, not derived.
    uint256 public nav;

    function setNav(uint256 nav_) external {
        nav = nav_;
    }

    /// @dev `RedeemRequest` is inherited from {ILeveragedAeroCLStrategy}; redeclaring would shadow it.
    mapping(uint256 => RedeemRequest) public requests;
    uint256 public nextRequestId;

    constructor(address vault_, address usdc_) {
        vaultToken = MockLeveragedAeroVault(vault_);
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
        require(state == State.Executed, "MockLeveragedAero: not executed");

        // Fund capacity as the real strategy does it: pre-transfer, post-deposit book, `0` == unlimited.
        uint256 cap = vaultToken.maxTotalAssets();
        require(cap == 0 || nav + assets <= cap, "MockLeveragedAero: fund at capacity");

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        shares = _sharesForAssets(assets);
        require(shares >= minShares, "MockLeveragedAero: min shares");

        vaultToken.strategyMint(msg.sender, shares);
    }

    function redeem(uint256 shares, uint256 minAssetsOut) external override returns (uint256 assetsOut) {
        require(state == State.Executed, "MockLeveragedAero: not executed");
        require(!fastPathBlocked, "FastRedeemExceedsLtv");

        // Pull the shares in and burn them (mirrors the wrapper approving shares to us first).
        IERC20(address(vaultToken)).safeTransferFrom(msg.sender, address(this), shares);
        vaultToken.strategyBurn(shares);

        assetsOut = _assetsForShares(shares);
        require(assetsOut >= minAssetsOut, "MockLeveragedAero: min assets out");

        usdc.safeTransfer(msg.sender, assetsOut);
    }

    function requestRedeem(uint256 shares, uint256 minAssetsOut, address recipient)
        external
        override
        returns (uint256 id)
    {
        require(state == State.Executed, "MockLeveragedAero: not executed");

        IERC20(address(vaultToken)).safeTransferFrom(msg.sender, address(this), shares);

        if (recipient == address(0)) recipient = msg.sender;

        id = nextRequestId++;
        requests[id] = RedeemRequest({
            owner: msg.sender,
            shares: shares,
            minAssetsOut: minAssetsOut,
            requestedAt: uint40(block.timestamp), // uint40 to match the real strategy's struct
            settled: false,
            recipient: recipient
        });
    }

    function cancelRedeem(uint256 id) external override {
        RedeemRequest storage req = requests[id];
        require(req.owner == msg.sender, "MockLeveragedAero: not request owner");
        require(!req.settled, "MockLeveragedAero: already settled");

        req.settled = true;
        IERC20(address(vaultToken)).safeTransfer(req.owner, req.shares);
    }

    function emergencyRedeem(uint256 id, uint256 minAssetsOut) external override returns (uint256 assetsOut) {
        require(state == State.Executed, "MockLeveragedAero: not executed");

        RedeemRequest storage req = requests[id];
        require(req.owner == msg.sender, "MockLeveragedAero: not request owner");
        require(!req.settled, "MockLeveragedAero: already settled");
        require(block.timestamp > req.requestedAt + 2 days, "MockLeveragedAero: fulfill window not elapsed");

        assetsOut = _assetsForShares(req.shares);
        require(assetsOut >= minAssetsOut, "MockLeveragedAero: min assets out");

        req.settled = true;
        vaultToken.strategyBurn(req.shares);
        usdc.safeTransfer(msg.sender, assetsOut);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256 assetsOut, bool fastOk) {
        return (_assetsForShares(shares), !fastPathBlocked);
    }

    /// @dev As on the real strategy, an unknown id returns the zero struct (`settled == false`).
    function redeemRequest(uint256 id) external view override returns (RedeemRequest memory) {
        return requests[id];
    }

    function vault() external view override returns (address) {
        return address(vaultToken);
    }

    // ==================== TEST-ONLY HELPER ====================

    /**
     * @notice Burns the escrowed shares and pays USDC to the request's RECIPIENT (not its owner), as the
     *         real one does; no proposer gate (test helper). Enforces the real `max(stored, fresh)` floor.
     */
    function fulfillRedeem(uint256 id, uint256 minAssetsOut) external returns (uint256 assetsOut) {
        RedeemRequest storage req = requests[id];
        require(!req.settled, "MockLeveragedAero: already settled");

        assetsOut = _assetsForShares(req.shares);
        uint256 floor = minAssetsOut > req.minAssetsOut ? minAssetsOut : req.minAssetsOut;
        require(assetsOut >= floor, "MockLeveragedAero: min assets out");

        req.settled = true;
        vaultToken.strategyBurn(req.shares);
        usdc.safeTransfer(req.recipient, assetsOut);
    }
}
