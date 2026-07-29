// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "@contracts/leveraged-aero/sherwood/interfaces/ISlipstream.sol";
import {LiquidityAmounts} from "@contracts/leveraged-aero/sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLPool} from "../mocks/MockCLPool.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Leveraged-Aero venue harness — CUSTODIAL mocks for the position lifecycle
 * @notice The existing `test/mocks/Mock{MoonwellMarket,CLPool,CLGauge}` stand-ins answer the reads
 *         `_initialize` makes but move NO tokens, which is enough for init tests and nothing else.
 *         Driving `executeImpl` / `deployIdleImpl` / `redeemUnwindImpl` needs venues that actually take
 *         custody, so this file adds the three that do.
 *
 * @dev The NPM mock computes deposits/withdrawals with the SAME vendored `LiquidityAmounts` at the
 *      pool's live `sqrtP` that the production code uses. That is deliberate: it makes "the split
 *      produced a balanced pair" a meaningful assertion (the mock cannot flatter a mis-sized pair — it
 *      consumes exactly what the real geometry would) while keeping the suite fork-free.
 *
 *      Named `*Harness.sol` on purpose: the Makefile's `coverage` target does `--skip s.sol`, which
 *      suffix-matches "…ss.sol", keeping test-only contracts out of the coverage report. See the note
 *      above `coverage:` in the Makefile.
 */

/// @notice Chainlink aggregator stand-in with FULL control of the hardened reader's inputs.
/// @dev `test/mocks/MockPriceFeed` hardcodes `startedAt = 0`, which `ChainlinkReader` correctly
///      rejects as `StaleOracle` — so it cannot serve a live oracle path. This one can, and doubles as
///      the L2 sequencer-uptime feed (`answer == 0` means "up").
contract MockChainlinkFeed {
    int256 public answer;
    uint8 public decimals;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(int256 answer_, uint8 decimals_, uint256 startedAt_, uint256 updatedAt_) {
        answer = answer_;
        decimals = decimals_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @notice Custodial Moonwell/Compound-fork market: real transfers on mint / redeem / borrow / repay.
/// @dev Fund it with the underlying before use (it pays borrows and redemptions out of its own
///      balance). `exchangeRateStored` is settable so a test can move the collateral basis.
contract MockLendingMarket {
    using SafeERC20 for IERC20;

    address public immutable underlying;
    uint256 public exchangeRateStored = 1e18;

    mapping(address => uint256) public balanceOf; // cToken balance
    mapping(address => uint256) public borrowBalance;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    function setExchangeRateStored(uint256 rate) external {
        exchangeRateStored = rate;
    }

    function borrowBalanceStored(address account) external view returns (uint256) {
        return borrowBalance[account];
    }

    function balanceOfUnderlying(address account) external view returns (uint256) {
        return (balanceOf[account] * exchangeRateStored) / 1e18;
    }

    function mint(uint256 amount) external returns (uint256) {
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += (amount * 1e18) / exchangeRateStored;
        return 0;
    }

    function redeem(uint256 cAmount) external returns (uint256) {
        balanceOf[msg.sender] -= cAmount; // under-collateralised redeem reverts, as Moonwell would
        IERC20(underlying).safeTransfer(msg.sender, (cAmount * exchangeRateStored) / 1e18);
        return 0;
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        balanceOf[msg.sender] -= (amount * 1e18) / exchangeRateStored;
        IERC20(underlying).safeTransfer(msg.sender, amount);
        return 0;
    }

    function borrow(uint256 amount) external returns (uint256) {
        borrowBalance[msg.sender] += amount;
        IERC20(underlying).safeTransfer(msg.sender, amount);
        return 0;
    }

    /// @dev `amount == type(uint256).max` repays the full balance (the sentinel the strategy passes).
    function repayBorrow(uint256 amount) external returns (uint256) {
        uint256 debt = borrowBalance[msg.sender];
        if (amount > debt) amount = debt;
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        borrowBalance[msg.sender] = debt - amount;
        return 0;
    }
}

/// @notice Custodial Slipstream NPM: mints/holds CL positions and moves tokens per the REAL
///         `LiquidityAmounts` geometry at the pool's live `sqrtP`, honouring the caller's slippage mins.
contract MockNpm {
    using SafeERC20 for IERC20;

    struct Pos {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    mapping(uint256 => Pos) internal _pos;
    uint256 public nextId = 1;
    MockCLPool public immutable pool;

    error MockNpmSlippage();

    constructor(MockCLPool pool_) {
        pool = pool_;
    }

    /// @dev Canonical Slipstream 12-tuple. The strategy/manager read fields 5-7 (tickLower, tickUpper,
    ///      liquidity) out of the raw returndata, so the ORDER and full width matter here.
    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Pos memory p = _pos[tokenId];
        return (0, address(0), p.token0, p.token1, p.tickSpacing, p.tickLower, p.tickUpper, p.liquidity, 0, 0, 0, 0);
    }

    function liquidityOf(uint256 tokenId) external view returns (uint128) {
        return _pos[tokenId].liquidity;
    }

    function mint(INonfungiblePositionManager.MintParams calldata mp)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (liquidity, amount0, amount1) = _addFor(mp.tickLower, mp.tickUpper, mp.amount0Desired, mp.amount1Desired);
        if (amount0 < mp.amount0Min || amount1 < mp.amount1Min) revert MockNpmSlippage();
        _pull(mp.token0, mp.token1, amount0, amount1);
        tokenId = nextId++;
        _pos[tokenId] = Pos({
            token0: mp.token0,
            token1: mp.token1,
            tickSpacing: mp.tickSpacing,
            tickLower: mp.tickLower,
            tickUpper: mp.tickUpper,
            liquidity: liquidity,
            owed0: 0,
            owed1: 0
        });
    }

    function increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams calldata ip)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Pos storage p = _pos[ip.tokenId];
        (liquidity, amount0, amount1) = _addFor(p.tickLower, p.tickUpper, ip.amount0Desired, ip.amount1Desired);
        if (amount0 < ip.amount0Min || amount1 < ip.amount1Min) revert MockNpmSlippage();
        _pull(p.token0, p.token1, amount0, amount1);
        p.liquidity += liquidity;
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata dp)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        Pos storage p = _pos[dp.tokenId];
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            pool.sqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(p.tickLower),
            TickMath.getSqrtRatioAtTick(p.tickUpper),
            dp.liquidity
        );
        if (amount0 < dp.amount0Min || amount1 < dp.amount1Min) revert MockNpmSlippage();
        p.liquidity -= dp.liquidity;
        p.owed0 += uint128(amount0);
        p.owed1 += uint128(amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata cp)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        Pos storage p = _pos[cp.tokenId];
        amount0 = p.owed0 < cp.amount0Max ? p.owed0 : cp.amount0Max;
        amount1 = p.owed1 < cp.amount1Max ? p.owed1 : cp.amount1Max;
        p.owed0 -= uint128(amount0);
        p.owed1 -= uint128(amount1);
        if (amount0 > 0) IERC20(p.token0).safeTransfer(cp.recipient, amount0);
        if (amount1 > 0) IERC20(p.token1).safeTransfer(cp.recipient, amount1);
    }

    /// @dev ERC-721 approve — the manager calls this raw before staking; only success matters.
    function approve(address, uint256) external {}

    function _addFor(int24 tickLower, int24 tickUpper, uint256 desired0, uint256 desired1)
        internal
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        uint160 sqrtP = pool.sqrtPriceX96();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, desired0, desired1);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, liquidity);
    }

    function _pull(address token0, address token1, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
    }
}

/// @notice Slipstream CL swap router stand-in at a fixed, settable rate per ordered token pair.
/// @dev Fund it with both tokens. Rates are `out per in`, 1e18-scaled, and are NOT required to be
///      mutually consistent — a test can widen/narrow one direction to probe the slippage bounds.
contract MockClSwapRouter {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => uint256)) public rateE18;

    error MockRouterNoRate();
    error MockRouterMinOut();
    error MockRouterMaxIn();

    function setRate(address tokenIn, address tokenOut, uint256 outPerInE18) external {
        rateE18[tokenIn][tokenOut] = outPerInE18;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        uint256 rate = rateE18[p.tokenIn][p.tokenOut];
        if (rate == 0) revert MockRouterNoRate();
        amountOut = (p.amountIn * rate) / 1e18;
        if (amountOut < p.amountOutMinimum) revert MockRouterMinOut();
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256 amountIn) {
        uint256 rate = rateE18[p.tokenIn][p.tokenOut];
        if (rate == 0) revert MockRouterNoRate();
        amountIn = (p.amountOut * 1e18 + rate - 1) / rate; // round up, as a real router would
        if (amountIn > p.amountInMaximum) revert MockRouterMaxIn();
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(p.tokenOut).safeTransfer(p.recipient, p.amountOut);
    }
}
