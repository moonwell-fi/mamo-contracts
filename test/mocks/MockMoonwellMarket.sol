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
interface IMockMarketReads {
    function balanceOf(address account) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
}

/// @dev Comptroller's OWN oracle: un-gated (no staleness check) like real Moonwell's — the asymmetry
///      the degraded `withdrawIdle` bound leans on.
interface IMockFeedRead {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract MockComptroller {
    /// @notice Collateral-factor mantissa (1e18-scaled) returned by `markets`; 0.88e18 == 8800 bps.
    uint256 public collateralFactorMantissa = 0.88e18;
    bool public isListed = true;

    uint256 public shortfall;
    uint256 public accountLiquidityError; // nonzero → getAccountLiquidity answers (err, 0, 0)

    // Liquidity model, opt-in: un-registered fixtures stay inert (liquidity → (0, 0, shortfall),
    // redeemAllowed → 0); registered ones get Compound's Σ collateral×CF×price − Σ debt×price.
    struct RegisteredMarket {
        address feed; // 8dp USD answer, read raw — see IMockFeedRead
        uint8 underlyingDecimals;
        uint256 cfMantissa; // this market's collateral weight (0 for borrow-only legs)
    }

    address[] public marketList;
    mapping(address => RegisteredMarket) public registered;

    function setCollateralFactorMantissa(uint256 mantissa) external {
        collateralFactorMantissa = mantissa;
    }

    function setIsListed(bool listed) external {
        isListed = listed;
    }

    function setShortfall(uint256 shortfall_) external {
        shortfall = shortfall_;
    }

    function setAccountLiquidityError(uint256 err) external {
        accountLiquidityError = err;
    }

    /// @notice `cfMantissa` 0 for borrow-only legs; for mUSDC pass the same factor `markets()` reports.
    function registerMarket(address market, address feed, uint8 underlyingDecimals, uint256 cfMantissa) external {
        if (registered[market].feed == address(0)) marketList.push(market);
        registered[market] = RegisteredMarket(feed, underlyingDecimals, cfMantissa);
    }

    /// @dev The strategy staticcalls this and reads the SECOND return word as the mantissa.
    function markets(address) external view returns (bool, uint256) {
        return (isListed, collateralFactorMantissa);
    }

    function enterMarkets(address[] calldata mTokens) external pure returns (uint256[] memory errs) {
        errs = new uint256[](mTokens.length);
    }

    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256) {
        if (accountLiquidityError != 0) return (accountLiquidityError, 0, 0);
        if (shortfall != 0 || marketList.length == 0) return (0, 0, shortfall); // legacy inert shape
        (uint256 liq, uint256 sf) = hypotheticalLiquidity(account, address(0), 0);
        return (0, liq, sf);
    }

    /// @notice Compound's `redeemAllowed`: a redeem into shortfall returns an error code, never reverts.
    function redeemAllowed(address market, address redeemer, uint256 redeemTokens) external view returns (uint256) {
        if (marketList.length == 0) return 0; // un-wired fixtures keep the legacy always-allow
        (, uint256 sf) = hypotheticalLiquidity(redeemer, market, redeemTokens);
        return sf > 0 ? 4 : 0;
    }

    function hypotheticalLiquidity(address account, address hypoMarket, uint256 redeemTokens)
        public
        view
        returns (uint256 liquidity, uint256 shortfallOut)
    {
        uint256 sumCollateral;
        uint256 sumBorrow;
        for (uint256 i = 0; i < marketList.length; i++) {
            address market = marketList[i];
            RegisteredMarket memory m = registered[market];
            uint256 cBal = IMockMarketReads(market).balanceOf(account);
            if (market == hypoMarket) cBal = cBal > redeemTokens ? cBal - redeemTokens : 0;
            if (cBal > 0 && m.cfMantissa > 0) {
                uint256 underlyingBal = (cBal * IMockMarketReads(market).exchangeRateStored()) / 1e18;
                sumCollateral += (_usd18(m, underlyingBal) * m.cfMantissa) / 1e18;
            }
            uint256 debt = IMockMarketReads(market).borrowBalanceStored(account);
            if (debt > 0) sumBorrow += _usd18(m, debt);
        }
        if (sumCollateral >= sumBorrow) return (sumCollateral - sumBorrow, 0);
        return (0, sumBorrow - sumCollateral);
    }

    /// @dev token units (10^d) × raw 8dp answer × 1e10 / 10^d = 18dp USD.
    function _usd18(RegisteredMarket memory m, uint256 tokenAmount) internal view returns (uint256) {
        (, int256 answer,,,) = IMockFeedRead(m.feed).latestRoundData();
        return (tokenAmount * uint256(answer) * 1e10) / (10 ** m.underlyingDecimals);
    }
}
