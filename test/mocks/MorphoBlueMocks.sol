// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IMorphoBlue,
    IMorphoIrm,
    IMorphoOracle,
    Id,
    Market,
    MarketParams,
    MarketParamsLib,
    Position
} from "@contracts/robinhood/interfaces/IMorphoBlue.sol";
import {MorphoBlueMath} from "@contracts/robinhood/libraries/MorphoBlueMath.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mintable ERC20 with configurable decimals — USDG is 6dp, the collateral tokens vary
contract MockMintableERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/**
 * @notice Yield-bearing ERC-4626 collateral with a directly settable exchange rate
 * @dev Models the live spUSDG (Spark Savings USDG) shape: an ERC-4626 vault over the loan asset whose share
 *      price only ever goes up. The rate is set explicitly rather than accrued so tests can express "the
 *      collateral earned 5%" in one line, and `setExchangeRate` mints whatever backing that implies so
 *      redemptions still settle in full.
 */
contract MockYieldBearingVault is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    uint8 private immutable _decimals;

    /// @notice Assets per 1e18 shares... expressed WAD-relative: `assets = shares * exchangeRate / 1e18`
    uint256 public exchangeRate = 1e18;

    constructor(address asset_, string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        assetToken = IERC20(asset_);
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() external view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * 1e18) / exchangeRate;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        _burn(owner, shares);
        assetToken.safeTransfer(receiver, assets);
    }

    /// @notice Simulates the collateral earning yield, minting the backing the new rate implies
    function setExchangeRate(uint256 newRateWad) external {
        exchangeRate = newRateWad;

        uint256 required = convertToAssets(totalSupply());
        uint256 held = assetToken.balanceOf(address(this));
        if (required > held) MockMintableERC20(address(assetToken)).mint(address(this), required - held);
    }
}

/// @notice Morpho Blue oracle stub: one settable price at Blue's 1e36 scale
contract MockMorphoOracle is IMorphoOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}

/// @notice IRM stub: one settable per-second borrow rate, WAD-scaled
contract MockIrm is IMorphoIrm {
    uint256 public ratePerSecond;

    constructor(uint256 initialRatePerSecond) {
        ratePerSecond = initialRatePerSecond;
    }

    function setRatePerSecond(uint256 newRate) external {
        ratePerSecond = newRate;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return ratePerSecond;
    }
}

/**
 * @notice A faithful-enough Morpho Blue singleton for unit tests
 * @dev "Faithful enough" means the four things a levered borrower can actually be broken by are real:
 *      1. Debt is held in SHARES and converted with Blue's own rounding (up against the borrower), so the
 *         vault's accrual-aware NAV math is tested against the same arithmetic it mirrors.
 *      2. Interest accrues from the IRM with Blue's Taylor approximation, on the same schedule (`lastUpdate`).
 *      3. `borrow` and `withdrawCollateral` enforce the LLTV health check; `borrow` also enforces market
 *         liquidity. These are the two reverts the loop engine has to be shaped around.
 *      4. `repay` by shares zeroes a position exactly, while `repay` by assets leaves share dust — the
 *         behaviour that forces `_repay` to switch representations on a full unwind.
 *      Liquidations, callbacks, authorization and the protocol fee are out of scope; the vault touches none.
 */
contract MockMorphoBlue is IMorphoBlue {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;

    mapping(Id => Market) internal _markets;
    mapping(Id => MarketParams) internal _idToMarketParams;
    mapping(Id => mapping(address => Position)) internal _positions;

    function createMarket(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(_markets[id].lastUpdate == 0, "market already created");

        _markets[id].lastUpdate = uint128(block.timestamp);
        _idToMarketParams[id] = marketParams;
    }

    function market(Id id) external view returns (Market memory) {
        return _markets[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _idToMarketParams[id];
    }

    function accrueInterest(MarketParams memory marketParams) public {
        _accrue(marketParams);
    }

    /// @notice Test hook: books `amount` of interest without waiting for time to pass
    function injectInterest(MarketParams memory marketParams, uint256 amount) external {
        Id id = marketParams.id();
        _markets[id].totalBorrowAssets += uint128(amount);
        _markets[id].totalSupplyAssets += uint128(amount);
    }

    // ==================== LENDER SIDE ====================

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        _accrue(marketParams);

        Id id = marketParams.id();
        Market storage m = _markets[id];

        if (assets > 0) {
            shares = MorphoBlueMath.toSharesDown(assets, m.totalSupplyAssets, m.totalSupplyShares);
        } else {
            assets = MorphoBlueMath.toAssetsUp(shares, m.totalSupplyAssets, m.totalSupplyShares);
        }

        _positions[id][onBehalf].supplyShares += shares;
        m.totalSupplyShares += uint128(shares);
        m.totalSupplyAssets += uint128(assets);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        _accrue(marketParams);

        Id id = marketParams.id();
        Market storage m = _markets[id];

        if (assets > 0) {
            shares = MorphoBlueMath.toSharesUp(assets, m.totalSupplyAssets, m.totalSupplyShares);
        } else {
            assets = MorphoBlueMath.toAssetsDown(shares, m.totalSupplyAssets, m.totalSupplyShares);
        }

        _positions[id][onBehalf].supplyShares -= shares;
        m.totalSupplyShares -= uint128(shares);
        m.totalSupplyAssets -= uint128(assets);

        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    // ==================== BORROWER SIDE ====================

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory)
        external
    {
        require(assets > 0, "zero assets");

        Id id = marketParams.id();
        _positions[id][onBehalf].collateral += uint128(assets);

        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        require(assets > 0, "zero assets");
        _accrue(marketParams);

        Id id = marketParams.id();
        _positions[id][onBehalf].collateral -= uint128(assets);

        require(_isHealthy(marketParams, id, onBehalf), "insufficient collateral");

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        _accrue(marketParams);

        Id id = marketParams.id();
        Market storage m = _markets[id];

        if (assets > 0) {
            shares = MorphoBlueMath.toSharesUp(assets, m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            assets = MorphoBlueMath.toAssetsDown(shares, m.totalBorrowAssets, m.totalBorrowShares);
        }

        _positions[id][onBehalf].borrowShares += uint128(shares);
        m.totalBorrowShares += uint128(shares);
        m.totalBorrowAssets += uint128(assets);

        require(_isHealthy(marketParams, id, onBehalf), "insufficient collateral");
        require(m.totalBorrowAssets <= m.totalSupplyAssets, "insufficient liquidity");

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        _accrue(marketParams);

        Id id = marketParams.id();
        Market storage m = _markets[id];

        if (assets > 0) {
            shares = MorphoBlueMath.toSharesDown(assets, m.totalBorrowAssets, m.totalBorrowShares);
        } else {
            assets = MorphoBlueMath.toAssetsUp(shares, m.totalBorrowAssets, m.totalBorrowShares);
        }

        _positions[id][onBehalf].borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = m.totalBorrowAssets > uint128(assets) ? m.totalBorrowAssets - uint128(assets) : 0;

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    function flashLoan(address token, uint256 assets, bytes calldata) external {
        // present for interface parity only; the vault never calls it
        IERC20(token).safeTransfer(msg.sender, assets);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    // ==================== INTERNAL ====================

    function _accrue(MarketParams memory marketParams) internal {
        Id id = marketParams.id();
        Market storage m = _markets[id];

        if (m.lastUpdate == 0) return;
        if (block.timestamp <= m.lastUpdate) return;

        uint256 elapsed = block.timestamp - m.lastUpdate;

        if (m.totalBorrowAssets > 0 && marketParams.irm != address(0)) {
            uint256 rate = IMorphoIrm(marketParams.irm).borrowRateView(marketParams, m);
            uint256 interest =
                MorphoBlueMath.wMulDown(m.totalBorrowAssets, MorphoBlueMath.wTaylorCompounded(rate, elapsed));

            m.totalBorrowAssets += uint128(interest);
            m.totalSupplyAssets += uint128(interest);
        }

        m.lastUpdate = uint128(block.timestamp);
    }

    function _isHealthy(MarketParams memory marketParams, Id id, address user) internal view returns (bool) {
        Position memory p = _positions[id][user];
        if (p.borrowShares == 0) return true;

        Market memory m = _markets[id];
        uint256 borrowed = MorphoBlueMath.toAssetsUp(p.borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
        uint256 collateralValue = MorphoBlueMath.mulDivDown(
            p.collateral, IMorphoOracle(marketParams.oracle).price(), MorphoBlueMath.ORACLE_PRICE_SCALE
        );

        return MorphoBlueMath.wMulDown(collateralValue, marketParams.lltv) >= borrowed;
    }
}
