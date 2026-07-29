// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "@contracts/leveraged-aero/sherwood/interfaces/ISlipstream.sol";
import {LiquidityAmounts} from "@contracts/leveraged-aero/sherwood/libraries/LiquidityAmounts.sol";
import {TickMath} from "@contracts/leveraged-aero/sherwood/libraries/TickMath.sol";

import {MockCLPool} from "../mocks/MockCLPool.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

/// @notice Custodial Moonwell/Compound-fork market: real transfers on mint / redeem / borrow / repay,
///         and a FAITHFUL `(principal, interestIndex)` / `borrowIndex` borrow book.
///
/// @dev Fund it with the underlying before use (it pays borrows and redemptions out of its own
///      balance). `exchangeRateStored` is settable so a test can move the collateral basis.
///
///      THE STORED-vs-CURRENT DISTINCTION IS MODELLED ON PURPOSE, and it is the whole reason this
///      contract carries a borrow index at all. The previous version stored a single
///      `borrowBalance[account]` scalar that every read and every setter touched directly, so
///      `borrowBalanceStored` and `borrowBalanceCurrent` were IDENTICAL BY CONSTRUCTION — and the one
///      real-world condition that matters for `LeveragedAeroValuation._hedgeLeg` (interest that has
///      accrued in wall-clock time but that no transaction has yet folded into the market's
///      `borrowIndex`) was simply not representable. A hedge that measured the stale index therefore
///      looked perfect in the suite and hedged ~0 on a live fork.
///
///      Semantics copied from Moonwell `MToken` / Compound v2:
///        - `borrowBalanceStored(a) = principal[a] × borrowIndex / interestIndex[a]`, on the LAST-ACCRUED
///          `borrowIndex` — no accrual, `view`.
///        - `accrueInterest()` adopts the pending index (returns a Compound error code, always 0 here).
///        - `borrowBalanceCurrent(a)` accrues, THEN returns the stored read — non-`view`.
///        - `borrow` / `repayBorrow` CAPITALISE first: accrue, then
///          `principal = borrowBalanceStored ± amt; interestIndex = borrowIndex`. This is what makes
///          `borrowBalanceStored` immediately after a borrow/repay exactly the capitalised principal the
///          production `Layout.hedgedDebtA/B` basis tracks.
///
///      Two test helpers arm interest, and WHICH ONE a test uses is the point:
///        - `accrueBorrowInterest`         — visible to `borrowBalanceStored` (a third party already
///                                           accrued the market for us). The pre-existing behaviour.
///        - `accruePendingBorrowInterest`  — INVISIBLE to `borrowBalanceStored`; only `accrueInterest` /
///                                           `borrowBalanceCurrent` reveals it. The bug condition.
contract MockLendingMarket {
    using SafeERC20 for IERC20;

    address public immutable underlying;
    uint256 public exchangeRateStored = 1e18;

    mapping(address => uint256) public balanceOf; // cToken balance

    // ── Compound borrow book ──

    /// @notice The market's LAST-ACCRUED borrow index (1e18-scaled), exactly as `MToken.borrowIndex`.
    uint256 public borrowIndex = 1e18;
    /// @dev The index the next `accrueInterest()` will adopt; 0 means "nothing pending" (see
    ///      `pendingBorrowIndex()`). Real Moonwell derives this from `borrowRate × elapsed`; a test double
    ///      sets it directly so a suite can arm an exact amount of un-accrued interest.
    uint256 internal _pendingBorrowIndex;

    /// @notice Per-account capitalised principal (`MToken.accountBorrows[a].principal`).
    mapping(address => uint256) public principal;
    /// @notice Per-account index snapshot (`MToken.accountBorrows[a].interestIndex`).
    mapping(address => uint256) public interestIndex;

    error MockLendingMarketNoDebt();

    constructor(address underlying_) {
        underlying = underlying_;
    }

    function setExchangeRateStored(uint256 rate) external {
        exchangeRateStored = rate;
    }

    // ── Borrow-balance reads ──

    /// @notice Last-accrued borrow balance. STALE whenever a pending accrual is armed.
    function borrowBalanceStored(address account) public view returns (uint256) {
        return _balanceAt(account, borrowIndex);
    }

    /// @notice Accrue, then return the balance — the production read `_hedgeLeg` now uses.
    function borrowBalanceCurrent(address account) external returns (uint256) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    /// @notice Adopt the pending index. Returns a Compound error code (always 0 in the mock).
    function accrueInterest() public returns (uint256) {
        if (_pendingBorrowIndex != 0) {
            borrowIndex = _pendingBorrowIndex;
            _pendingBorrowIndex = 0;
        }
        return 0;
    }

    /// @notice The index `accrueInterest()` would adopt right now.
    function pendingBorrowIndex() public view returns (uint256) {
        return _pendingBorrowIndex == 0 ? borrowIndex : _pendingBorrowIndex;
    }

    /// @notice VIEW observer for the TRUE (fully accrued) debt — what `borrowBalanceCurrent` would
    ///         return, without mutating. Test-only; production never reads this.
    function borrowBalanceAccrued(address account) public view returns (uint256) {
        return _balanceAt(account, pendingBorrowIndex());
    }

    /// @notice Back-compat alias for `borrowBalanceStored` (the suites read `borrowBalance(x)` as "the
    ///         debt the strategy can see"). Equal to `borrowBalanceAccrued` unless a pending accrual is
    ///         armed — which is exactly the gap the pending helper exists to open.
    function borrowBalance(address account) external view returns (uint256) {
        return borrowBalanceStored(account);
    }

    // ── Interest arming (test-only) ──

    /// @notice Accrue `amount` of BORROW INTEREST onto `account`'s debt, with no token movement, and make
    ///         it IMMEDIATELY VISIBLE to `borrowBalanceStored` — i.e. the market has already been accrued
    ///         (by anyone's transaction) since the interest arose.
    /// @dev Capitalises first, so `borrowBalanceStored` grows by EXACTLY `amount` with no index rounding.
    ///      This is the state a Compound-fork market is left in by any third-party touch, and it is the
    ///      state in which a stale-index hedge still measures the drift correctly — which is precisely why
    ///      a suite built only on this helper cannot see the stale-index bug. Use
    ///      `accruePendingBorrowInterest` for that.
    function accrueBorrowInterest(address account, uint256 amount) external {
        _capitalise(account);
        principal[account] += amount;
    }

    /// @notice Accrue `amount` of BORROW INTEREST onto `account`'s debt that is NOT yet folded into the
    ///         market's index: `borrowBalanceStored` keeps reporting the OLD number until someone calls
    ///         `accrueInterest()` / `borrowBalanceCurrent()` (or performs a borrow/repay, which accrue).
    ///
    /// @dev THE CONDITION THE STALE-INDEX BUG LIVES IN, and the one the old scalar mock could not express.
    ///      Implemented as a pending advance of the GLOBAL index sized so that THIS account's balance grows
    ///      by `amount` once adopted (`newIndex = base × (cur + amount) / cur`), which is how real interest
    ///      reaches a borrower. Integer division can leave the realised growth 1–2 units short of `amount`;
    ///      assert with a small tolerance. Composes: arming twice stacks onto the already-pending index.
    /// @param account Borrower whose debt should grow by `amount` once the market is accrued.
    /// @param amount  Un-accrued interest to arm, in underlying units.
    function accruePendingBorrowInterest(address account, uint256 amount) external {
        uint256 base = pendingBorrowIndex();
        uint256 cur = _balanceAt(account, base);
        if (cur == 0) revert MockLendingMarketNoDebt(); // no principal ⇒ an index advance moves nothing
        _pendingBorrowIndex = Math.mulDiv(base, cur + amount, cur);
    }

    // ── Supply side ──

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

    // ── Borrow side ──

    /// @dev Accrues + capitalises before growing the principal, as `MToken.borrowFresh` does.
    function borrow(uint256 amount) external returns (uint256) {
        _capitalise(msg.sender);
        principal[msg.sender] += amount;
        IERC20(underlying).safeTransfer(msg.sender, amount);
        return 0;
    }

    /// @dev `amount == type(uint256).max` repays the full balance (the sentinel the strategy passes).
    ///      Accrues + capitalises first, as `MToken.repayBorrowFresh` does — so a repay is one of the
    ///      events that makes previously-invisible interest visible to `borrowBalanceStored`.
    function repayBorrow(uint256 amount) external returns (uint256) {
        _capitalise(msg.sender);
        uint256 debt = principal[msg.sender];
        if (amount > debt) amount = debt;
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        principal[msg.sender] = debt - amount;
        return 0;
    }

    // ── Internals ──

    /// @dev `principal × index / interestIndex`, with Compound's zero-principal short circuit (which also
    ///      keeps a never-borrowed account's zero `interestIndex` out of the divisor).
    function _balanceAt(address account, uint256 index) internal view returns (uint256) {
        uint256 p = principal[account];
        if (p == 0) return 0;
        return (p * index) / interestIndex[account];
    }

    /// @dev Accrue, then fold the account's accrued balance into its principal and re-snapshot its index —
    ///      `principal = borrowBalanceStored; interestIndex = borrowIndex`, verbatim Compound.
    function _capitalise(address account) internal {
        accrueInterest();
        principal[account] = borrowBalanceStored(account);
        interestIndex[account] = borrowIndex;
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

/// @notice Aerodrome **v2 (AMM)** Router stand-in for `compoundImpl`'s AERO→USDC reward swap.
/// @dev The manager routes that one swap through a HARDCODED mainnet address (`AERO_V2_ROUTER`), so a
///      fork-free test has to place code there. All state is in `immutable`s precisely so the contract
///      survives `vm.etch(AERO_V2_ROUTER, address(m).code)` — immutables live in the deployed runtime
///      bytecode, whereas storage-based config would be left behind at the original address. To change
///      the rate, deploy a second instance and etch again.
///      Fund it with `tokenOut` before use; it pays fills out of its own balance.
contract MockAeroV2Router {
    using SafeERC20 for IERC20;

    address public immutable tokenIn;
    address public immutable tokenOut;
    /// @dev `out per in`, 1e18-scaled, spanning the decimal gap between the two tokens.
    uint256 public immutable rateE18;

    error MockAeroRouterBadRoute();
    error MockAeroRouterMinOut();

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    constructor(address tokenIn_, address tokenOut_, uint256 rateE18_) {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        rateE18 = rateE18_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        if (routes.length != 1 || routes[0].from != tokenIn || routes[0].to != tokenOut) {
            revert MockAeroRouterBadRoute();
        }
        uint256 out = (amountIn * rateE18) / 1e18;
        if (out < amountOutMin) revert MockAeroRouterMinOut();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
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
