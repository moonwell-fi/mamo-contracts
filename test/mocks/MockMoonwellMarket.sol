// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title MockMoonwellMarket
 * @notice Minimal Moonwell (Compound-fork) mToken stand-in for unit tests. Exposes the
 *         `underlying()` binding the vendored strategy asserts at init plus the balance /
 *         exchange-rate / borrow-balance reads its accounting touches.
 */
contract MockMoonwellMarket {
    address public underlying;
    uint256 public exchangeRateStored = 1e18;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public borrowBalance;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    // ── Setters ──

    function setUnderlying(address underlying_) external {
        underlying = underlying_;
    }

    function setExchangeRateStored(uint256 rate) external {
        exchangeRateStored = rate;
    }

    function setBalanceOf(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setBorrowBalance(address account, uint256 amount) external {
        borrowBalance[account] = amount;
    }

    // ── IMoonwellMarket / ICToken ──

    function borrowBalanceStored(address account) public view returns (uint256) {
        return borrowBalance[account];
    }

    /// @notice `IMoonwellMarket.borrowBalanceCurrent` — accrue, then read.
    /// @dev This stand-in models NO interest at all (`borrowBalance` is set directly), so accrual is a
    ///      no-op and stored == current here BY CONSTRUCTION — hence `view`, which a caller reaching it
    ///      through the non-`view` interface declaration invokes over a plain CALL just fine. Adequate for
    ///      the init/config suites this mock serves, and exactly why it must NOT be used to test the
    ///      interest hedge: that needs `LeveragedAeroVenuesHarness`'s custodial `MockLendingMarket`, which
    ///      carries a real `borrowIndex` and can hold interest the stored read cannot see.
    function borrowBalanceCurrent(address account) external view returns (uint256) {
        return borrowBalanceStored(account);
    }

    /// @notice Compound's accrual entrypoint. Returns error code 0; nothing to accrue in this stand-in.
    function accrueInterest() external pure returns (uint256) {
        return 0;
    }

    function mint(uint256) external pure returns (uint256) {
        return 0;
    }

    function borrow(uint256) external pure returns (uint256) {
        return 0;
    }

    function repayBorrow(uint256) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256) external pure returns (uint256) {
        return 0;
    }

    function redeemUnderlying(uint256) external pure returns (uint256) {
        return 0;
    }

    function balanceOfUnderlying(address account) external view returns (uint256) {
        return balanceOf[account];
    }
}

/**
 * @title MockComptroller
 * @notice Minimal Moonwell Comptroller stand-in: the `markets(address)` tuple the vendored
 *         strategy reads its USDC collateral factor from, plus the two calls the venue path makes.
 */
contract MockComptroller {
    /// @notice Collateral-factor mantissa (1e18-scaled) returned by `markets`; 0.88e18 == 8800 bps.
    uint256 public collateralFactorMantissa = 0.88e18;
    bool public isListed = true;

    uint256 public shortfall;

    function setCollateralFactorMantissa(uint256 mantissa) external {
        collateralFactorMantissa = mantissa;
    }

    function setIsListed(bool listed) external {
        isListed = listed;
    }

    function setShortfall(uint256 shortfall_) external {
        shortfall = shortfall_;
    }

    /// @dev The strategy staticcalls this and reads the SECOND return word as the mantissa.
    function markets(address) external view returns (bool, uint256) {
        return (isListed, collateralFactorMantissa);
    }

    function enterMarkets(address[] calldata mTokens) external pure returns (uint256[] memory errs) {
        errs = new uint256[](mTokens.length);
    }

    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256) {
        return (0, 0, shortfall);
    }
}
