# LP Auto-Balancer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `LPAutoBalancer` — a Safe-governed, multi-position Aerodrome CL rebalancer that re-ranges protocol-owned liquidity, stakes position NFTs in gauges to farm AERO, and skims fees/emissions to the weekly drop — with all tick and swap-size math computed on-chain.

**Architecture:** A single `AccessControlEnumerable` contract holds many position NFTs in a `slotId` registry. `rebalance()` computes the target range on-chain from a bounded `width`, computes the swap size on-chain via vendored Uniswap-v3 math (`TickMath`/`LiquidityAmounts`/`FullMath`), and bounds the outcome with a Chainlink-priced value floor plus a pool-TWAP deviation gate. The off-chain caller supplies only `width` + min-amount floors; it never supplies ticks or swap size. Drain-capable powers (migrate/withdraw/recover/caps) stay on the F-MAMO Safe; re-range/stake/claim run on a hot `REBALANCER_ROLE` EOA.

**Tech Stack:** Solidity 0.8.28, Foundry (forge), `via_ir=true`, OpenZeppelin v5.2.0, Forge Proposal Simulator (FPS), Aerodrome Slipstream (CL) on Base. Base fork tests with `--ffi`.

**Spec:** `docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md` (revised, PR #54).

---

## Decisions locked before coding

These were settled during planning. Do not re-litigate while implementing:

1. **Fully on-chain math** (per user). Vendor audited Uniswap-v3 math libraries ported to 0.8.28; compute ticks AND swap size on-chain. Do **not** hand-transcribe audited math — vendor verbatim from the cited source and verify with known-answer tests (Tasks 1–4).
2. **Value floor prices realized token balances via Chainlink**, not theoretical in-range liquidity. After the full decrease+collect, the contract holds principal as real ERC20 balances; value `= amt0·price0 + amt1·price1` using a Chainlink feed per leg (`oracle0`, `oracle1`). This avoids needing `LiquidityAmounts` for valuation and measures *realized* value. (Refines the spec's single `valueOracle` → two per-leg feeds.)
3. **Pool TWAP is used only for the spot-manipulation deviation gate and the range-centering reference tick** — not for valuation. Read via `pool.observe`; convert with a tiny internal `_consultTwapTick` helper (no separate OracleLibrary port).
4. **Roles via OpenZeppelin `AccessControlEnumerable`**: `DEFAULT_ADMIN_ROLE` (Safe), `MANAGER_ROLE`, `REBALANCER_ROLE`, `GUARDIAN_ROLE`. (Replaces the spec's standalone `address rebalancer` + `setRebalancer` with `REBALANCER_ROLE` — cleaner, matches `MamoStakingRegistry`.)
5. **New `ICLPool` interface** (don't touch the existing minimal `IPool` used elsewhere). New `ICLGauge` interface (the existing `IAerodromeGauge` is the v2 ERC20-LP variant and does not apply to CL NFTs).
6. **Out of scope for this plan:** the off-chain rebalancing service (spec §7) — separate workstream. The LLM pool-discovery pipeline (spec §8.3) — nice-to-have, not built.

## Naming/signature contract (used across all tasks — keep consistent)

```solidity
// Roles
bytes32 public constant MANAGER_ROLE    = keccak256("MANAGER_ROLE");
bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
bytes32 public constant GUARDIAN_ROLE   = keccak256("GUARDIAN_ROLE");

// Immutables
INonfungiblePositionManager public immutable POSITION_MANAGER;
ISwapRouter public immutable SWAP_ROUTER;
IQuoter     public immutable QUOTER;
address     public immutable AERO;

// Global caps / constants
uint256 public constant BPS_DENOMINATOR      = 10_000;
uint16  public constant MAX_SLIPPAGE_CAP_BPS = 500;   // 5%
uint16  public constant MAX_LOSS_CAP_BPS     = 500;   // 5%
uint256 public constant SWAP_DEADLINE_BUFFER = 300;   // 5 min
uint256 public maxOracleDelay;                        // admin-set, default 26 hours

struct ManagedPosition {
    uint256 tokenId;
    address pool;               // ICLPool
    address token0;
    address token1;
    int24   tickSpacing;
    address gauge;              // ICLGauge (address(0) => no gauge / never staked)
    bool    staked;
    address feeCollector;       // skim destination (DROP_AUTOMATION)
    address oracle0;            // IPriceFeed for token0 (USD)
    address oracle1;            // IPriceFeed for token1 (USD)
    uint8   swapPolicy;         // 0 = either; 1 = counter-asset only (never sell protectedToken); 2 = protected only
    address protectedToken;     // token swapPolicy protects (e.g. MAMO)
    uint24  minWidth;           // tick units; must be multiple of tickSpacing
    uint24  maxWidth;
    uint24  maxCenterDeviation;
    uint16  maxSlippageBps;     // <= MAX_SLIPPAGE_CAP_BPS
    uint32  twapWindow;         // seconds (deviation gate + centering)
    int24   maxTickDeviation;
    uint16  maxRebalanceLossBps;// <= MAX_LOSS_CAP_BPS
    uint256 minRebalanceInterval;
    uint256 lastRebalance;
    bool    active;
}

struct RebalanceParams {
    uint24  width;
    uint256 swapMinAmountOut;   // extra floor only; effective = max(quoterMin, this)
    uint256 amount0MinDecrease;
    uint256 amount1MinDecrease;
    uint256 amount0MinMint;
    uint256 amount1MinMint;
    uint256 deadline;
}

struct MigrateParams {
    address destPool; address destToken0; address destToken1; int24 destTickSpacing; address destGauge;
    int24 tickLower; int24 tickUpper;
    address swapTokenIn; uint256 swapAmountIn; uint256 swapMinAmountOut;
    uint256 amount0MinDecrease; uint256 amount1MinDecrease;
    uint256 amount0MinMint; uint256 amount1MinMint;
    uint256 deadline;
}
```

## File Structure

| File | Responsibility |
| --- | --- |
| `src/libraries/uniswap/FullMath.sol` | vendored `mulDiv`/`mulDivRoundingUp` (0.8.28 port) |
| `src/libraries/uniswap/FixedPoint96.sol` | vendored `Q96` constant |
| `src/libraries/uniswap/TickMath.sol` | vendored tick ↔ sqrtPriceX96 (0.8.28 port) |
| `src/libraries/uniswap/LiquidityAmounts.sol` | vendored liquidity ↔ amounts (0.8.28 port) |
| `src/interfaces/ICLPool.sol` | Slipstream CL pool: `slot0`, `observe`, `token0/1`, `liquidity`, `tickSpacing` |
| `src/interfaces/ICLGauge.sol` | CL gauge: `deposit(tokenId)`, `withdraw(tokenId)`, `getReward(tokenId)`, `earned`, `rewardToken` |
| `src/LPAutoBalancer.sol` | the contract (registry, rebalance, stake/claim, migrate, admin) |
| `script/DeployLPAutoBalancer.s.sol` | deploy + register `MAMO_LP_AUTO_BALANCER` address |
| `multisig/f-mamo/006_LPAutoBalancerSetup.sol` | FPS proposal: move NFTs from `TransferAndEarn`, register positions |
| `test/LPAutoBalancerMath.unit.t.sol` | known-answer tests for vendored libs |
| `test/LPAutoBalancer.unit.t.sol` | guard/access/config unit tests (mocked) |
| `test/harness/LPAutoBalancerHarness.sol` | re-exposes internal math helpers as public for unit tests |
| `test/LPAutoBalancer.integration.t.sol` | Base-fork rebalance/stake/migrate end-to-end |

---

## Phase 0 — Vendored math libraries (verify by known-answer tests)

> **Why vendor, not transcribe:** `TickMath`/`LiquidityAmounts`/`FullMath` are audited fixed-point math. Copy them verbatim from the cited source and change only the pragma + `unchecked` wrapping. Then prove correctness with known-answer tests. Re-deriving the constants by hand would be a regression risk in audited code.
>
> **Source of truth:** Aerodrome Slipstream targets these exact pools. Vendor from `velodrome-finance/slipstream` (`contracts/core/libraries/TickMath.sol`, `FullMath.sol`, `FixedPoint96.sol`; `contracts/periphery/libraries/LiquidityAmounts.sol`). These are identical in math to Uniswap v3 (`Uniswap/v3-core` `TickMath`/`FullMath`, `Uniswap/v3-periphery` `LiquidityAmounts`). If Slipstream sources are 0.7.x, apply the standard 0.8 adaptation below. Add an SPDX + a `// Vendored from <repo>@<commit>, adapted to 0.8.28` provenance comment at the top of each file.
>
> **Standard 0.8 adaptation:** set `pragma solidity 0.8.28;`; wrap the arithmetic bodies of `mulDiv`, `getSqrtRatioAtTick`, `getTickAtSqrtRatio` in `unchecked { ... }` (they rely on intentional wraparound); keep all magic constants byte-for-byte.

### Task 1: Vendor FullMath + FixedPoint96

**Files:**
- Create: `src/libraries/uniswap/FullMath.sol`
- Create: `src/libraries/uniswap/FixedPoint96.sol`
- Test: `test/LPAutoBalancerMath.unit.t.sol`

- [ ] **Step 1: Write the failing KAT test**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {FixedPoint96} from "@libraries/uniswap/FixedPoint96.sol";

contract LPAutoBalancerMathUnitTest is Test {
    function test_fullMath_mulDiv_basic() public pure {
        assertEq(FullMath.mulDiv(6, 7, 2), 21);
        assertEq(FullMath.mulDiv(type(uint256).max, 5, type(uint256).max), 5);
    }

    function test_fixedPoint96_q96() public pure {
        assertEq(FixedPoint96.Q96, 0x1000000000000000000000000); // 2**96
    }
}
```

- [ ] **Step 2: Run it, verify it fails to compile (libs absent)**

Run: `forge test --match-path test/LPAutoBalancerMath.unit.t.sol -vv`
Expected: compile error — `FullMath`/`FixedPoint96` not found.

- [ ] **Step 3: Vendor the two files**

Copy `FullMath.sol` and `FixedPoint96.sol` from the cited Slipstream/Uniswap source into `src/libraries/uniswap/`, set `pragma solidity 0.8.28;`, wrap `mulDiv`/`mulDivRoundingUp` bodies in `unchecked`, add the provenance comment. `FixedPoint96` is just `uint8 internal constant RESOLUTION = 96; uint256 internal constant Q96 = 0x1000000000000000000000000;`.

- [ ] **Step 4: Run KAT, verify PASS**

Run: `forge test --match-path test/LPAutoBalancerMath.unit.t.sol -vv`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/libraries/uniswap/FullMath.sol src/libraries/uniswap/FixedPoint96.sol test/LPAutoBalancerMath.unit.t.sol
git commit -m "feat(lp): vendor FullMath + FixedPoint96 (0.8.28)"
```

### Task 2: Vendor TickMath

**Files:**
- Create: `src/libraries/uniswap/TickMath.sol`
- Test: `test/LPAutoBalancerMath.unit.t.sol` (extend)

- [ ] **Step 1: Add failing KAT test**

```solidity
import {TickMath} from "@libraries/uniswap/TickMath.sol";

function test_tickMath_knownAnswers() public pure {
    // tick 0 => price 1.0 => sqrtPriceX96 == 2**96
    assertEq(TickMath.getSqrtRatioAtTick(0), 79228162514264337593543950336);
    // bounds
    assertEq(TickMath.MIN_TICK, -887272);
    assertEq(TickMath.MAX_TICK, 887272);
    // round-trip a few ticks (must land within +/-1 by library contract)
    int24[3] memory ticks = [int24(200), int24(-200), int24(60000)];
    for (uint256 i; i < ticks.length; i++) {
        uint160 s = TickMath.getSqrtRatioAtTick(ticks[i]);
        int24 back = TickMath.getTickAtSqrtRatio(s);
        assertApproxEqAbs(int256(back), int256(ticks[i]), 1);
    }
}
```

- [ ] **Step 2: Run, verify fail (TickMath absent)**

Run: `forge test --match-test test_tickMath_knownAnswers -vv`
Expected: compile error.

- [ ] **Step 3: Vendor TickMath.sol**

Copy verbatim, set pragma 0.8.28, wrap `getSqrtRatioAtTick`/`getTickAtSqrtRatio` bodies in `unchecked`, keep constants byte-for-byte, add provenance comment.

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_tickMath_knownAnswers -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/libraries/uniswap/TickMath.sol test/LPAutoBalancerMath.unit.t.sol
git commit -m "feat(lp): vendor TickMath (0.8.28) + KAT"
```

### Task 3: Vendor LiquidityAmounts

**Files:**
- Create: `src/libraries/uniswap/LiquidityAmounts.sol`
- Test: `test/LPAutoBalancerMath.unit.t.sol` (extend)

- [ ] **Step 1: Add failing property test**

```solidity
import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";

function test_liquidityAmounts_boundaryProperties() public pure {
    uint160 sqrtLower = TickMath.getSqrtRatioAtTick(-1000);
    uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(1000);
    uint128 L = 1e18;

    // price at/below lower => all token0, zero token1
    (uint256 a0, uint256 a1) =
        LiquidityAmounts.getAmountsForLiquidity(sqrtLower, sqrtLower, sqrtUpper, L);
    assertGt(a0, 0); assertEq(a1, 0);

    // price at/above upper => all token1, zero token0
    (a0, a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtUpper, sqrtLower, sqrtUpper, L);
    assertEq(a0, 0); assertGt(a1, 0);

    // round-trip: liquidity for amounts then amounts for that liquidity <= inputs
    uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
    uint128 L2 = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, 1e18, 1e18);
    (uint256 r0, uint256 r1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtLower, sqrtUpper, L2);
    assertLe(r0, 1e18); assertLe(r1, 1e18);
}
```

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_liquidityAmounts_boundaryProperties -vv`
Expected: compile error.

- [ ] **Step 3: Vendor LiquidityAmounts.sol**

Copy verbatim (depends on `FullMath` + `FixedPoint96`), set pragma 0.8.28, fix import paths to `@libraries/uniswap/...`, add provenance comment.

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_liquidityAmounts_boundaryProperties -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/libraries/uniswap/LiquidityAmounts.sol test/LPAutoBalancerMath.unit.t.sol
git commit -m "feat(lp): vendor LiquidityAmounts (0.8.28) + property tests"
```

### Task 4: Interfaces — ICLPool + ICLGauge

**Files:**
- Create: `src/interfaces/ICLPool.sol`
- Create: `src/interfaces/ICLGauge.sol`

- [ ] **Step 1: Write ICLPool**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICLPool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
}
```

- [ ] **Step 2: Write ICLGauge**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICLGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
    function earned(address account, uint256 tokenId) external view returns (uint256);
    function rewardToken() external view returns (address);
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
}
```

- [ ] **Step 3: Compile**

Run: `forge build`
Expected: compiles clean.

- [ ] **Step 4: Commit**

```bash
forge fmt
git add src/interfaces/ICLPool.sol src/interfaces/ICLGauge.sol
git commit -m "feat(lp): add ICLPool + ICLGauge interfaces"
```

---

## Phase 1 — Contract scaffold: roles, state, registry

### Task 5: Contract skeleton + constructor + roles

**Files:**
- Create: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test for construction + roles**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

contract LPAutoBalancerUnitTest is Test {
    LPAutoBalancer lab;
    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address pm = makeAddr("positionManager");
    address router = makeAddr("router");
    address quoter = makeAddr("quoter");
    address aero = makeAddr("aero");

    function setUp() public {
        lab = new LPAutoBalancer(admin, manager, rebalancer, guardian, pm, router, quoter, aero);
    }

    function test_rolesGranted() public view {
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(lab.hasRole(lab.MANAGER_ROLE(), manager));
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), rebalancer));
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), guardian));
    }

    function test_immutablesWired() public view {
        assertEq(address(lab.POSITION_MANAGER()), pm);
        assertEq(address(lab.SWAP_ROUTER()), router);
        assertEq(address(lab.QUOTER()), quoter);
        assertEq(lab.AERO(), aero);
        assertEq(lab.maxOracleDelay(), 26 hours);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(LPAutoBalancer.ZeroAddress.selector);
        new LPAutoBalancer(address(0), manager, rebalancer, guardian, pm, router, quoter, aero);
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-path test/LPAutoBalancer.unit.t.sol -vv`
Expected: compile error (no contract).

- [ ] **Step 3: Write the skeleton**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

import {TickMath} from "@libraries/uniswap/TickMath.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {FixedPoint96} from "@libraries/uniswap/FixedPoint96.sol";
import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";

contract LPAutoBalancer is AccessControlEnumerable, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE    = keccak256("MANAGER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant GUARDIAN_ROLE   = keccak256("GUARDIAN_ROLE");

    uint256 public constant BPS_DENOMINATOR      = 10_000;
    uint16  public constant MAX_SLIPPAGE_CAP_BPS = 500;
    uint16  public constant MAX_LOSS_CAP_BPS     = 500;
    uint256 public constant SWAP_DEADLINE_BUFFER = 300;

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    ISwapRouter public immutable SWAP_ROUTER;
    IQuoter     public immutable QUOTER;
    address     public immutable AERO;

    uint256 public maxOracleDelay;

    struct ManagedPosition { /* paste the full struct from the naming/signature contract above */ }

    mapping(uint256 => ManagedPosition) public positions;
    uint256 public nextSlotId;

    error ZeroAddress();

    constructor(
        address admin_, address manager_, address rebalancer_, address guardian_,
        address positionManager_, address swapRouter_, address quoter_, address aero_
    ) {
        if (
            admin_ == address(0) || positionManager_ == address(0) || swapRouter_ == address(0)
                || quoter_ == address(0) || aero_ == address(0)
        ) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (manager_ != address(0)) _grantRole(MANAGER_ROLE, manager_);
        if (rebalancer_ != address(0)) _grantRole(REBALANCER_ROLE, rebalancer_);
        if (guardian_ != address(0)) _grantRole(GUARDIAN_ROLE, guardian_);

        POSITION_MANAGER = INonfungiblePositionManager(positionManager_);
        SWAP_ROUTER = ISwapRouter(swapRouter_);
        QUOTER = IQuoter(quoter_);
        AERO = aero_;
        maxOracleDelay = 26 hours;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(POSITION_MANAGER), "Only position manager");
        return this.onERC721Received.selector;
    }
}
```

Paste the full `ManagedPosition` struct from the naming/signature contract section.

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-path test/LPAutoBalancer.unit.t.sol -vv`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): LPAutoBalancer scaffold — roles, immutables, onERC721Received"
```

### Task 6: registerPosition + deregisterPosition

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test**

Use a minimal mock position manager that records `safeTransferFrom`/`ownerOf` and a fixture `ManagedPosition`. Test that:
- `registerPosition` reverts for non-admin (`AccessControlUnauthorizedAccount`);
- reverts if `maxSlippageBps > MAX_SLIPPAGE_CAP_BPS` (`SlippageCapExceeded`);
- reverts if `maxRebalanceLossBps > MAX_LOSS_CAP_BPS` (`LossCapExceeded`);
- reverts if `minWidth > maxWidth` or width not multiple of tickSpacing (`InvalidWidth`);
- reverts if `oracle0 == 0 || oracle1 == 0` (`OracleRequired`);
- reverts if the NFT isn't already held by the contract (`NotHeld`);
- on success: assigns `slotId = 0`, stores config, sets `active = true`, increments `nextSlotId`, emits `PositionRegistered(slotId, pool, tokenId)`.

```solidity
function test_registerPosition_happy() public {
    uint256 slotId = _register(); // helper: builds valid config, mocks ownerOf==lab, pranks admin
    assertEq(slotId, 0);
    (,,,,,, bool staked,,,,,,,,,,,,, bool active) = lab.positions(slotId); // adjust tuple to struct order
    assertTrue(active);
    assertEq(lab.nextSlotId(), 1);
}
```

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_registerPosition -vv`
Expected: FAIL (function missing).

- [ ] **Step 3: Implement**

```solidity
event PositionRegistered(uint256 indexed slotId, address indexed pool, uint256 indexed tokenId);
event PositionDeregistered(uint256 indexed slotId, address indexed to);

error SlippageCapExceeded();
error LossCapExceeded();
error InvalidWidth();
error OracleRequired();
error InvalidConfig();
error NotActive();
error NotHeld();

function registerPosition(ManagedPosition calldata config)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
    returns (uint256 slotId)
{
    if (config.maxSlippageBps > MAX_SLIPPAGE_CAP_BPS) revert SlippageCapExceeded();
    if (config.maxRebalanceLossBps > MAX_LOSS_CAP_BPS) revert LossCapExceeded();
    if (config.pool == address(0) || config.token0 == address(0) || config.token1 == address(0)) {
        revert InvalidConfig();
    }
    if (config.oracle0 == address(0) || config.oracle1 == address(0)) revert OracleRequired();
    if (config.twapWindow == 0 || config.maxTickDeviation <= 0) revert InvalidConfig();
    int24 spacing = config.tickSpacing;
    if (
        config.minWidth == 0 || config.minWidth > config.maxWidth
            || config.minWidth % uint24(spacing) != 0 || config.maxWidth % uint24(spacing) != 0
    ) revert InvalidWidth();
    if (POSITION_MANAGER.ownerOf(config.tokenId) != address(this)) revert NotHeld();

    slotId = nextSlotId++;
    _store(slotId, config); // field-by-field copy; forces active=true, staked=false, lastRebalance=0
    emit PositionRegistered(slotId, config.pool, config.tokenId);
}

function deregisterPosition(uint256 slotId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
    ManagedPosition storage p = positions[slotId];
    if (!p.active) revert NotActive();
    if (p.staked) _unstake(p, slotId); // defined in Task 13
    POSITION_MANAGER.safeTransferFrom(address(this), to, p.tokenId);
    p.active = false;
    emit PositionDeregistered(slotId, to);
}
```

Implement `_store(uint256 slotId, ManagedPosition calldata config)` as an explicit field-by-field copy (calldata → storage), forcing `active=true`, `staked=false`, `lastRebalance=0`. (Don't assign the whole struct in one shot if it trips `via-ir`; copy fields explicitly.)

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test "test_registerPosition|test_deregister" -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): registerPosition + deregisterPosition with config validation"
```

### Task 7: Admin/manager setters + pause + recover

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing tests**

- `setPositionConfig(slotId, minWidth, maxWidth, maxCenterDeviation, maxSlippageBps, twapWindow, maxTickDeviation, maxRebalanceLossBps, minRebalanceInterval)` — `MANAGER_ROLE`; reverts if any cap exceeded; emits `PositionConfigUpdated`.
- `setFeeCollector(slotId, addr)` — `MANAGER_ROLE`; non-zero; emits `FeeCollectorUpdated`.
- `setOracles(slotId, o0, o1)`, `setSwapPolicy(slotId, policy, protectedToken)`, `setGauge(slotId, gauge)`, `setMaxOracleDelay(uint256)` — `DEFAULT_ADMIN_ROLE`.
- `pause()`/`unpause()` — `GUARDIAN_ROLE`; assert `paused()` flips.
- `recoverERC20(token, to, amount)` / `recoverETH(to)` — `DEFAULT_ADMIN_ROLE`; non-zero `to`; emits `TokensRecovered`.
- Each setter: assert a non-role caller reverts with `AccessControlUnauthorizedAccount`.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test "test_set|test_pause|test_recover" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement the setters**

Add events `PositionConfigUpdated`, `FeeCollectorUpdated`, `OraclesUpdated`, `SwapPolicyUpdated`, `GaugeUpdated`, `MaxOracleDelayUpdated`, `TokensRecovered`. Manager setters re-check caps. `pause`/`unpause` call `_pause()`/`_unpause()`. `recoverERC20` uses `SafeERC20.safeTransfer`; `recoverETH` uses a `call` with success check (mirror `src/BaseStrategy.sol:46-70`).

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test "test_set|test_pause|test_recover" -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): admin/manager setters, pause, token recovery"
```

---

## Phase 2 — On-chain math helpers (pure/view, unit-tested in isolation)

> These are the heart of the "fully on-chain" decision. Each is `internal`, re-exposed `public` via `LPAutoBalancerHarness` (inherits the contract), so they can be unit-tested without a fork.

### Task 8: Harness + `_alignedRange(referenceTick, width, spacing, currentTick)`

**Files:**
- Create: `test/harness/LPAutoBalancerHarness.sol`
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test**

```solidity
// referenceTick=0, width=2000, spacing=200, currentTick=0 -> [-1000,1000]
function test_alignedRange_centersAndAligns() public view {
    (int24 lo, int24 hi) = harness.alignedRange(0, 2000, 200, 0);
    assertEq(lo, -1000);
    assertEq(hi, 1000);
    assertEq(lo % 200, 0);
    assertEq(hi % 200, 0);
    assertTrue(lo < 0 && 0 < hi);
}

// negative reference => floor-align toward -inf, width preserved
function test_alignedRange_negativeFloor() public view {
    (int24 lo, int24 hi) = harness.alignedRange(-150, 2000, 200, -150);
    assertEq((hi - lo), 2000);
    assertEq(lo % 200, 0);
    assertEq(hi % 200, 0);
    assertTrue(lo < -150 && -150 < hi);
}
```

The harness:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

contract LPAutoBalancerHarness is LPAutoBalancer {
    constructor(address a, address m, address r, address g, address pm, address sr, address q, address aero)
        LPAutoBalancer(a, m, r, g, pm, sr, q, aero) {}

    function alignedRange(int24 ref, uint24 width, int24 spacing, int24 cur)
        external pure returns (int24, int24) { return _alignedRange(ref, width, spacing, cur); }
    // add more pass-throughs in later tasks (consultTwapTick, valueInUsd, computeSwap)
}
```

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_alignedRange -vv`
Expected: FAIL.

- [ ] **Step 3: Implement `_alignedRange` + `_floorAlign`**

```solidity
function _floorAlign(int24 tick, int24 spacing) internal pure returns (int24) {
    int24 q = tick / spacing;
    if (tick < 0 && tick % spacing != 0) q -= 1; // floor toward -inf
    return q * spacing;
}

function _alignedRange(int24 referenceTick, uint24 width, int24 spacing, int24 currentTick)
    internal
    pure
    returns (int24 tickLower, int24 tickUpper)
{
    int24 half = int24(width / 2);
    tickLower = _floorAlign(referenceTick - half, spacing);
    tickUpper = tickLower + int24(width);
    require(tickLower < currentTick && currentTick < tickUpper, "no straddle");
}
```

`width` is validated as a multiple of `spacing` at registration, so `tickUpper - tickLower == width` stays spacing-aligned.

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_alignedRange -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/harness/LPAutoBalancerHarness.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): on-chain aligned range computation + harness"
```

### Task 9: `_consultTwapTick(pool, window)` + deviation gate

**Files:**
- Modify: `src/LPAutoBalancer.sol`, `test/harness/LPAutoBalancerHarness.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test (mock pool)**

Mock `ICLPool.observe` to return two `tickCumulatives` whose difference / window = a known tick (e.g. cumulative delta `2000 * 60` over a 60s window → tick 2000). Assert `harness.consultTwapTick(pool, 60) == 2000`. Add a case where `(spot - twap)` exceeds `maxTickDeviation` and assert `harness.checkDeviation(...)` reverts `TwapDeviation`.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test "test_consultTwap|test_deviation" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement**

```solidity
error TwapDeviation();

function _consultTwapTick(address pool, uint32 window) internal view returns (int24) {
    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = window;
    secondsAgos[1] = 0;
    (int56[] memory cum,) = ICLPool(pool).observe(secondsAgos);
    int56 delta = cum[1] - cum[0];
    int24 twapTick = int24(delta / int56(uint56(window)));
    if (delta < 0 && (delta % int56(uint56(window)) != 0)) twapTick--; // round toward -inf
    return twapTick;
}

function _checkDeviation(int24 spotTick, int24 twapTick, int24 maxDev) internal pure {
    int24 diff = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
    if (diff > maxDev) revert TwapDeviation();
}
```

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test "test_consultTwap|test_deviation" -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/harness/LPAutoBalancerHarness.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): pool TWAP tick consult + spot-vs-TWAP deviation gate"
```

### Task 10: `_valueInUsd(...)` Chainlink valuation

**Files:**
- Modify: `src/LPAutoBalancer.sol`, `test/harness/LPAutoBalancerHarness.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test (mock feeds)**

Mock two `IPriceFeed`s: oracle0 = MAMO/USD ($0.0089, 8 decimals), oracle1 = cbBTC/USD ($65000, 8 decimals). With token0 decimals 18, token1 decimals 8, amounts (1000e18 MAMO, 1e8 cbBTC), assert `harness.valueInUsd(...)` returns the expected 1e8-scaled USD sum within rounding. Assert a stale feed (`updatedAt` older than `maxOracleDelay`) reverts `StaleOracle`, and a zero/negative answer reverts `StaleOracle`.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_valueInUsd -vv`
Expected: FAIL.

- [ ] **Step 3: Implement**

```solidity
error StaleOracle();

function _readFeed(address feed) internal view returns (uint256 price, uint8 decimals) {
    (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
    if (answer <= 0) revert StaleOracle();
    if (block.timestamp - updatedAt > maxOracleDelay) revert StaleOracle();
    price = uint256(answer);
    decimals = IPriceFeed(feed).decimals();
}

/// @return usd value scaled to 1e8
function _valueInUsd(
    uint256 amount0, uint256 amount1,
    address oracle0, address oracle1,
    uint8 dec0, uint8 dec1
) internal view returns (uint256 usd) {
    (uint256 p0, uint8 fd0) = _readFeed(oracle0);
    (uint256 p1, uint8 fd1) = _readFeed(oracle1);
    usd = FullMath.mulDiv(amount0, p0, 10 ** dec0) * (10 ** 8) / (10 ** fd0)
        + FullMath.mulDiv(amount1, p1, 10 ** dec1) * (10 ** 8) / (10 ** fd1);
}
```

Add `IERC20Metadata` import (already added in Task 5).

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_valueInUsd -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/harness/LPAutoBalancerHarness.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): Chainlink USD valuation of token amounts with staleness guard"
```

### Task 11: `_computeSwap(...)` — on-chain swap sizing

**Files:**
- Modify: `src/LPAutoBalancer.sol`, `test/harness/LPAutoBalancerHarness.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test**

```solidity
function test_computeSwap_sellsSurplusToken0() public view {
    uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
    (bool zeroForOne, uint256 amtIn) =
        harness.computeSwap(sqrtP, -1000, 1000, 2e18, 0, 0, A, B, address(0));
    assertTrue(zeroForOne);
    assertGt(amtIn, 0);
    assertLt(amtIn, 2e18);
}

function test_computeSwap_policyBlocksSellingProtected() public view {
    uint160 sqrtP = TickMath.getSqrtRatioAtTick(0);
    // surplus token0 (=A), protected=A, policy=1 -> no swap
    (, uint256 amtIn) = harness.computeSwap(sqrtP, -1000, 1000, 2e18, 0, 1, A, B, A);
    assertEq(amtIn, 0);
}
```

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_computeSwap -vv`
Expected: FAIL.

- [ ] **Step 3: Implement** (approximate single-swap zap; residual becomes dust forwarded post-mint; value floor backstops approximation error):

```solidity
/// @return zeroForOne true => sell token0 for token1
/// @return amountIn   amount of the surplus token to swap (0 => no swap)
function _computeSwap(
    uint160 sqrtP, int24 tickLower, int24 tickUpper,
    uint256 bal0, uint256 bal1,
    uint8 swapPolicy, address token0, address token1, address protectedToken
) internal pure returns (bool zeroForOne, uint256 amountIn) {
    uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
    uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);

    // price of token0 in token1, Q96: P = sqrtP^2 / 2^96
    uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), FixedPoint96.Q96);

    uint256 total1 = bal1 + FullMath.mulDiv(bal0, priceX96, FixedPoint96.Q96);
    if (total1 == 0) return (false, 0);

    (uint256 req0, uint256 req1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, 1e18);
    uint256 req0In1 = FullMath.mulDiv(req0, priceX96, FixedPoint96.Q96);
    uint256 denom = req0In1 + req1;
    if (denom == 0) {
        if (req1 == 0) { return bal1 > 0 ? (false, bal1) : (false, 0); }      // range all token0
        else { return bal0 > 0 ? (true, bal0) : (true, 0); }                  // range all token1
    }

    uint256 desired0In1 = FullMath.mulDiv(total1, req0In1, denom);
    uint256 cur0In1 = FullMath.mulDiv(bal0, priceX96, FixedPoint96.Q96);

    if (cur0In1 > desired0In1) {
        uint256 surplus1 = cur0In1 - desired0In1;
        amountIn = FullMath.mulDiv(surplus1, FixedPoint96.Q96, priceX96); // back to token0 units
        zeroForOne = true;
    } else {
        amountIn = desired0In1 - cur0In1;
        zeroForOne = false;
    }

    address sellToken = zeroForOne ? token0 : token1;
    if (swapPolicy == 1 && sellToken == protectedToken) return (zeroForOne, 0);
    if (swapPolicy == 2 && sellToken != protectedToken) return (zeroForOne, 0);
}
```

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_computeSwap -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/harness/LPAutoBalancerHarness.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): on-chain swap sizing (zap) with swap-leg policy"
```

### Task 12: `_executeSwap(...)` — quoter-bounded swap

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test (mock router + quoter)**

Mock quoter returns `quotedOut`; mock router returns `amountOut`. Assert the effective min passed to the router equals `max(quotedOut*(BPS-slippage)/BPS, callerMin)`. Assert a router return below min reverts `"Received less than min amount"`. Assert garbage `callerMin = 0` still applies the quoter floor.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_executeSwap -vv`
Expected: FAIL.

- [ ] **Step 3: Implement** — copy `DropAutomation._executeSwap` (`src/DropAutomation.sol:419-462`) verbatim, adapting names: `_executeSwap(tokenIn, tokenOut, amountIn, tickSpacing, callerMinOut, maxSlippageBps)`, using `QUOTER`/`SWAP_ROUTER`, `forceApprove`, deadline `block.timestamp + SWAP_DEADLINE_BUFFER`.

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_executeSwap -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): quoter-bounded swap execution (dual-layer guard)"
```

---

## Phase 3 — Gauge staking & fee/emission skims

### Task 13: `stake` / `unstake` / `_unstake`

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test (mock gauge + PM)**

- `stake(slotId)` reverts `NoGauge` if `gauge==0`; reverts `AlreadyStaked` if staked; on success approves PM→gauge, calls `gauge.deposit(tokenId)`, sets `staked=true`, emits `Staked`. Non-rebalancer reverts.
- `unstake(slotId)` reverts `NotStaked` if not staked; calls `gauge.withdraw(tokenId)`, forwards AERO to `feeCollector`, sets `staked=false`, emits `Unstaked` + `EmissionsClaimed`.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test "test_stake|test_unstake" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement**

```solidity
event Staked(uint256 indexed slotId, uint256 indexed tokenId, address gauge);
event Unstaked(uint256 indexed slotId, uint256 indexed tokenId, address gauge);
event EmissionsClaimed(uint256 indexed slotId, uint256 amount);

error NoGauge();
error AlreadyStaked();
error NotStaked();

function stake(uint256 slotId) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
    ManagedPosition storage p = positions[slotId];
    if (!p.active) revert NotActive();
    if (p.gauge == address(0)) revert NoGauge();
    if (p.staked) revert AlreadyStaked();
    POSITION_MANAGER.approve(p.gauge, p.tokenId);
    ICLGauge(p.gauge).deposit(p.tokenId);
    p.staked = true;
    emit Staked(slotId, p.tokenId, p.gauge);
}

function unstake(uint256 slotId) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
    ManagedPosition storage p = positions[slotId];
    if (!p.staked) revert NotStaked();
    _unstake(p, slotId);
}

function _unstake(ManagedPosition storage p, uint256 slotId) internal {
    ICLGauge(p.gauge).withdraw(p.tokenId); // returns NFT + auto-claims AERO
    p.staked = false;
    uint256 aeroBal = IERC20(AERO).balanceOf(address(this));
    if (aeroBal > 0) {
        IERC20(AERO).safeTransfer(p.feeCollector, aeroBal);
        emit EmissionsClaimed(slotId, aeroBal);
    }
    emit Unstaked(slotId, p.tokenId, p.gauge);
}
```

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test "test_stake|test_unstake" -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): gauge stake/unstake with AERO skim to fee collector"
```

### Task 14: `claimEmissions` + `collectFees` (both permissionless)

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test**

- `claimEmissions(slotId)` permissionless: requires staked; `gauge.getReward(tokenId)`; forwards AERO to `feeCollector`; emits `EmissionsClaimed`.
- `collectFees(slotId)` permissionless: requires NOT staked; `collect(tokenId, max, max)`; forwards token0/token1 to `feeCollector`; emits `FeesSkimmed`.
- Both revert `EnforcedPause` when paused.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test "test_claimEmissions|test_collectFees" -vv`
Expected: FAIL.

- [ ] **Step 3: Implement**

```solidity
event FeesSkimmed(uint256 indexed slotId, uint256 amount0, uint256 amount1);

function claimEmissions(uint256 slotId) external whenNotPaused nonReentrant {
    ManagedPosition storage p = positions[slotId];
    if (!p.staked) revert NotStaked();
    ICLGauge(p.gauge).getReward(p.tokenId);
    uint256 aeroBal = IERC20(AERO).balanceOf(address(this));
    if (aeroBal > 0) {
        IERC20(AERO).safeTransfer(p.feeCollector, aeroBal);
        emit EmissionsClaimed(slotId, aeroBal);
    }
}

function collectFees(uint256 slotId) external whenNotPaused nonReentrant {
    ManagedPosition storage p = positions[slotId];
    if (!p.active) revert NotActive();
    if (p.staked) revert AlreadyStaked(); // staked => fees go to gauge, use claimEmissions
    (uint256 a0, uint256 a1) = POSITION_MANAGER.collect(
        INonfungiblePositionManager.CollectParams({
            tokenId: p.tokenId, recipient: address(this),
            amount0Max: type(uint128).max, amount1Max: type(uint128).max
        })
    );
    if (a0 > 0) IERC20(p.token0).safeTransfer(p.feeCollector, a0);
    if (a1 > 0) IERC20(p.token1).safeTransfer(p.feeCollector, a1);
    emit FeesSkimmed(slotId, a0, a1);
}
```

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test "test_claimEmissions|test_collectFees" -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): permissionless claimEmissions + collectFees"
```

---

## Phase 4 — `rebalance()` (the orchestrator)

### Task 15: `rebalance` happy path (unit, fully mocked)

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test**

Mock PM (`positions`/`decreaseLiquidity`/`collect`/`mint`/`burn`), pool (`slot0`/`observe`), quoter, router, two feeds, gauge. Drive a position out of range; call `rebalance(slotId, params{width})` as rebalancer. Assert: cooldown updated, old NFT burned, `pos.tokenId` updated to the mock's new id, `Rebalanced` emitted, dust forwarded to feeCollector. (Structural test — economic correctness is covered by the fork test in Task 26.)

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_rebalance_happy -vv`
Expected: FAIL.

- [ ] **Step 3: Implement `rebalance`** orchestrating the helpers in this order:

```solidity
event Rebalanced(uint256 indexed slotId, uint256 oldTokenId, uint256 newTokenId, int24 tickLower, int24 tickUpper);

error Cooldown();
error WidthOutOfBounds();
error CenterDeviation();
error ValueFloor();

function rebalance(uint256 slotId, RebalanceParams calldata params)
    external
    onlyRole(REBALANCER_ROLE)
    nonReentrant
    whenNotPaused
{
    ManagedPosition storage p = positions[slotId];
    if (!p.active) revert NotActive();
    if (block.timestamp < p.lastRebalance + p.minRebalanceInterval) revert Cooldown();
    if (params.width < p.minWidth || params.width > p.maxWidth) revert WidthOutOfBounds();

    bool wasStaked = p.staked;

    // 1. spot + twap, gate
    (uint160 sqrtP, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
    int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
    _checkDeviation(spotTick, twapTick, p.maxTickDeviation);

    // 2. decimals
    uint8 dec0 = IERC20Metadata(p.token0).decimals();
    uint8 dec1 = IERC20Metadata(p.token1).decimals();

    // 3. value BEFORE: principal-only (from liquidity; excludes owed fees by construction)
    uint256 valueBefore = _principalValue(p, sqrtP, dec0, dec1);

    // 4. unstake if needed (auto-claims AERO -> feeCollector)
    if (wasStaked) _unstake(p, slotId);

    // 5. collect fees only (pre-decrease), forward to feeCollector
    _skimFees(p, slotId);

    // 6. decrease all liquidity + collect principal
    _decreaseAll(p, params);

    // 7. compute new range on-chain (centered on twapTick)
    (int24 tickLower, int24 tickUpper) = _alignedRange(twapTick, params.width, p.tickSpacing, spotTick);
    int24 center = (tickLower + tickUpper) / 2;
    int24 dev = center > twapTick ? center - twapTick : twapTick - center;
    if (dev > int24(uint24(p.maxCenterDeviation))) revert CenterDeviation();

    // 8. compute + execute swap on-chain
    uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
    uint256 bal1 = IERC20(p.token1).balanceOf(address(this));
    (bool zeroForOne, uint256 amountIn) =
        _computeSwap(sqrtP, tickLower, tickUpper, bal0, bal1, p.swapPolicy, p.token0, p.token1, p.protectedToken);
    if (amountIn > 0) {
        (address tin, address tout) = zeroForOne ? (p.token0, p.token1) : (p.token1, p.token0);
        _executeSwap(tin, tout, amountIn, p.tickSpacing, params.swapMinAmountOut, p.maxSlippageBps);
    }

    // 9. mint new, burn old
    uint256 oldTokenId = p.tokenId;
    uint256 newTokenId = _mintNew(p, tickLower, tickUpper, params);
    POSITION_MANAGER.burn(oldTokenId);
    p.tokenId = newTokenId;
    p.lastRebalance = block.timestamp;

    // 10. restake if it was staked
    if (wasStaked && p.gauge != address(0)) {
        POSITION_MANAGER.approve(p.gauge, newTokenId);
        ICLGauge(p.gauge).deposit(newTokenId);
        p.staked = true;
        emit Staked(slotId, newTokenId, p.gauge);
    }

    // 11. value AFTER (principal in new NFT), value floor
    uint256 valueAfter = _principalValue(p, sqrtP, dec0, dec1);
    if (valueAfter < FullMath.mulDiv(valueBefore, BPS_DENOMINATOR - p.maxRebalanceLossBps, BPS_DENOMINATOR)) {
        revert ValueFloor();
    }

    // 12. forward dust
    _forwardDust(p);

    emit Rebalanced(slotId, oldTokenId, newTokenId, tickLower, tickUpper);
}
```

Private helpers to implement:
- `_skimFees(p, slotId)`: `collect(tokenId, max, max)` → forward both tokens to `feeCollector`; emit `FeesSkimmed`.
- `_decreaseAll(p, params)`: read `(,,,,,,, uint128 liquidity,,,,) = POSITION_MANAGER.positions(p.tokenId)`; `decreaseLiquidity(p.tokenId, liquidity, params.amount0MinDecrease, params.amount1MinDecrease, params.deadline)`; then `collect(tokenId, max, max)`.
- `_mintNew(p, tickLower, tickUpper, params) returns (uint256 newTokenId)`: `forceApprove` both tokens to PM for current balances; build `MintParams` (token0/token1 from `p`, `fee`=0 — Aerodrome CL uses tickSpacing not fee; pass `fee` field as the pool fee if the PM requires it, else 0; recipient = `address(this)`; `amount0Desired/1Desired` = current balances; `amount0Min`/`amount1Min` = `params.amount0MinMint`/`amount1MinMint`; deadline); `(newTokenId,,,) = POSITION_MANAGER.mint(params)`.
- `_forwardDust(p)`: transfer any residual token0/token1 balance to `feeCollector`.
- `_principalValue(p, sqrtP, dec0, dec1) returns (uint256)`: read the position's `tickLower/tickUpper/liquidity` via `POSITION_MANAGER.positions(p.tokenId)`; `(uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liquidity)`; return `_valueInUsd(a0, a1, p.oracle0, p.oracle1, dec0, dec1)`.

> **Value-floor ordering note (write as a code comment):** `valueBefore` uses `_principalValue` which derives amounts from `liquidity` only — it deliberately excludes `tokensOwed` (fees), so skimming fees in step 5 does not change the measured principal. This keeps the before/after comparison principal-only, atomic, single-transaction (no separate `snapshot()`).
>
> **Note on `INonfungiblePositionManager.MintParams.fee`:** the repo's interface includes a `fee` field. Aerodrome Slipstream `mint` uses `tickSpacing`, not `fee` — verify the deployed PM's `MintParams` shape during Task 26 and set the field the live contract expects (the repo interface may need a `tickSpacing` field added; if so, extend `INonfungiblePositionManager` in a tiny separate edit and note it).

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_rebalance_happy -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): rebalance orchestration (on-chain ticks+swap, value floor)"
```

### Task 16: rebalance guard reverts (unit)

**Files:**
- Modify: `test/LPAutoBalancer.unit.t.sol` (and `src/LPAutoBalancer.sol` if a guard is missing)

- [ ] **Step 1: Write failing tests** — each asserts a specific revert:
  - pre-cooldown → `Cooldown`
  - `width < minWidth` / `> maxWidth` → `WidthOutOfBounds`
  - spot vs twap beyond `maxTickDeviation` → `TwapDeviation`
  - center beyond `maxCenterDeviation` → `CenterDeviation`
  - value-after below floor (mock mint returns low liquidity) → `ValueFloor`
  - stale feed → `StaleOracle`
  - non-rebalancer caller → `AccessControlUnauthorizedAccount`

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_rebalance_revert -vv`
Expected: FAIL.

- [ ] **Step 3: Adjust contract** if any guard is missing/misordered until all revert tests pass (completeness only).

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_rebalance_revert -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "test(lp): rebalance guard revert coverage"
```

---

## Phase 5 — `migrate()` (Safe-only) + emergency

### Task 17: `migrate` happy path + access control (unit)

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test**

- `migrate(slotId, params)` reverts for rebalancer/manager/random → `AccessControlUnauthorizedAccount`; only `DEFAULT_ADMIN_ROLE` succeeds.
- Sanity guards: `destPool.code.length==0` → `InvalidConfig`; `destTickSpacing != ICLPool(destPool).tickSpacing()` → `InvalidConfig`; `tickLower >= tickUpper` → `InvalidConfig`.
- Happy path (mocked): unstakes if staked, skims fees, decreases+collects, swaps with `params.swapMinAmountOut`, mints into `destPool`, optionally deposits into `destGauge`, burns old, updates slot in place (pool/tokens/tickSpacing/gauge/tokenId, resets `lastRebalance`), emits `Migrated`.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_migrate -vv`
Expected: FAIL.

- [ ] **Step 3: Implement `migrate`** per spec §8.2. Uses `params.swapTokenIn/swapAmountIn/swapMinAmountOut` (admin-reviewed; no trustworthy on-chain oracle for an arbitrary dest). **No value floor** (documented). Emit `Migrated(slotId, oldPool, destPool, oldTokenId, newTokenId)`.

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_migrate -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): Safe-gated migrate() with fat-finger sanity guards"
```

### Task 18: `withdrawPosition` emergency (unit)

**Files:**
- Modify: `src/LPAutoBalancer.sol`
- Test: `test/LPAutoBalancer.unit.t.sol`

- [ ] **Step 1: Write failing test** — `withdrawPosition(slotId, to)` admin-only; unstakes if staked; `safeTransferFrom` NFT to `to`; marks inactive; emits `PositionWithdrawn`. Non-admin reverts.

- [ ] **Step 2: Run, verify fail**

Run: `forge test --match-test test_withdrawPosition -vv`
Expected: FAIL.

- [ ] **Step 3: Implement** `withdrawPosition` + `event PositionWithdrawn(uint256 indexed slotId, address indexed to)`.

- [ ] **Step 4: Run, verify PASS**

Run: `forge test --match-test test_withdrawPosition -vv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancer.unit.t.sol
git commit -m "feat(lp): emergency withdrawPosition"
```

### Task 19: Full unit-suite green + size + slither

- [ ] **Step 1:** Run the whole unit suite.

Run: `forge test --match-path "test/LPAutoBalancer*.unit.t.sol" -vv`
Expected: ALL PASS.

- [ ] **Step 2:** Build size + lints.

Run: `forge build --sizes` (assert `LPAutoBalancer` < 24576 bytes) and `slither src/LPAutoBalancer.sol` (triage; no new high/medium). If over size, move private helpers into an `internal library` or trim revert strings.

- [ ] **Step 3: Commit** any fixes.

```bash
forge fmt && git add -A && git commit -m "chore(lp): unit suite green, size + slither triage"
```

---

## Phase 6 — Address registration & deployment

### Task 20: Add MAMO/USD feed + new address keys

**Files:**
- Modify: `addresses/8453.json`

- [ ] **Step 1: Add the Chainlink MAMO/USD feed** (verified live: `MAMO / USD`, 8 decimals):

```json
{ "addr": "0xeF7541b388a77C1709a3d44BfBfC5c1ED3F0Ac94", "name": "CHAINLINK_MAMO_USD", "isContract": true }
```

- [ ] **Step 2: Confirm the MAMO/USDC pool key.** Only `cbBTC_MAMO_POOL` exists today. If the MAMO/USDC managed position is in scope at launch, look up its CL pool + add `MAMO_USDC_POOL`. Otherwise skip (the proposal in Task 23 registers only pools that exist). Document the choice.

- [ ] **Step 3:** Sanity-check existing keys the deploy needs: `UNISWAP_V3_POSITION_MANAGER_AERODROME`, `AERODROME_ROUTER`, `AERODROME_QUOTER`, `AERO`, `cbBTC`, `MAMO`, `USDC`, `CHAINLINK_BTC_USD`, `CHAINLINK_USDC_USD`, `DROP_AUTOMATION`, `F-MAMO`, `TRANSFER_AND_EARN`, `cbBTC_MAMO_POOL`, `MAMO_PAUSE_GUARDIAN`.

Run: `grep -E "CHAINLINK_MAMO_USD|UNISWAP_V3_POSITION_MANAGER_AERODROME|AERODROME_QUOTER" addresses/8453.json`
Expected: all present.

- [ ] **Step 4: Commit**

```bash
git add addresses/8453.json
git commit -m "chore(addresses): add CHAINLINK_MAMO_USD feed"
```

### Task 21: Deploy script

**Files:**
- Create: `script/DeployLPAutoBalancer.s.sol`

- [ ] **Step 1: Write the deploy script** (mirror `script/DeployDropAutomation.s.sol`):

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

contract DeployLPAutoBalancer is Script {
    function run() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        Addresses addresses = new Addresses("./addresses", chainIds);

        vm.startBroadcast();
        address lab = deploy(addresses);
        vm.stopBroadcast();

        string memory key = "MAMO_LP_AUTO_BALANCER";
        if (addresses.isAddressSet(key)) addresses.changeAddress(key, lab, true);
        else addresses.addAddress(key, lab, true);
        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deploy(Addresses addresses) public returns (address) {
        address admin = addresses.getAddress("F-MAMO");
        address manager = addresses.getAddress("MAMO_LP_MANAGER");      // EOA (add to addresses)
        address rebalancer = addresses.getAddress("MAMO_LP_REBALANCER"); // EOA (add to addresses)
        address guardian = addresses.getAddress("MAMO_PAUSE_GUARDIAN");
        address pm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        address router = addresses.getAddress("AERODROME_ROUTER");
        address quoter = addresses.getAddress("AERODROME_QUOTER");
        address aero = addresses.getAddress("AERO");

        LPAutoBalancer lab = new LPAutoBalancer(admin, manager, rebalancer, guardian, pm, router, quoter, aero);
        console.log("LPAutoBalancer deployed at:", address(lab));
        return address(lab);
    }
}
```

- [ ] **Step 2: Add the two EOA keys** `MAMO_LP_MANAGER` and `MAMO_LP_REBALANCER` to `addresses/8453.json` (`isContract: false`; placeholder values, noted as must-set-before-mainnet).

- [ ] **Step 3: Compile**

Run: `forge build`
Expected: compiles.

- [ ] **Step 4: Commit**

```bash
forge fmt
git add script/DeployLPAutoBalancer.s.sol addresses/8453.json
git commit -m "feat(lp): deploy script + LP manager/rebalancer EOA keys"
```

---

## Phase 7 — FPS proposal (move NFTs + register)

### Task 22: Proposal scaffold (deploy + name/description)

**Files:**
- Create: `multisig/f-mamo/006_LPAutoBalancerSetup.sol`

- [ ] **Step 1: Write the proposal scaffold** (mirror `multisig/f-mamo/005_DropAutomationSetup.sol`):

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {DeployLPAutoBalancer} from "@script/DeployLPAutoBalancer.s.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {TransferAndEarn} from "@contracts/TransferAndEarn.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LPAutoBalancerSetup is MultisigProposal {
    DeployLPAutoBalancer public immutable deployer;

    constructor() {
        deployer = new DeployLPAutoBalancer();
        vm.makePersistent(address(deployer));
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initializeAddresses();
        if (DO_DEPLOY) { deploy(); addresses.updateJson(); addresses.printJSONChanges(); }
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
    }

    function name() public pure override returns (string memory) { return "006_LPAutoBalancerSetup"; }
    function description() public pure override returns (string memory) {
        return "Deploy LPAutoBalancer, move TransferAndEarn CL positions into it, register them";
    }

    function deploy() public override {
        if (!addresses.isAddressSet("MAMO_LP_AUTO_BALANCER")) {
            address lab = deployer.deploy(addresses);
            addresses.addAddress("MAMO_LP_AUTO_BALANCER", lab, true);
        }
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("F-MAMO"));
    }
}
```

- [ ] **Step 2: Compile**

Run: `forge build`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
forge fmt
git add multisig/f-mamo/006_LPAutoBalancerSetup.sol
git commit -m "feat(lp): FPS proposal scaffold 006"
```

### Task 23: Proposal `build()` — transfer NFTs + register

**Files:**
- Modify: `multisig/f-mamo/006_LPAutoBalancerSetup.sol`

- [ ] **Step 1: Implement `build()`** wrapped in `buildModifier(addresses.getAddress("F-MAMO"))`. For the cbBTC/MAMO position (and MAMO/USDC if in scope):
1. `TransferAndEarn(transferAndEarn).transfer(tokenId)` → NFT to F-MAMO Safe. (Look up the real `tokenId`s held by `TRANSFER_AND_EARN` on-chain; store as constants with a comment on how obtained.)
2. `INonfungiblePositionManager(pm).safeTransferFrom(safe, lab, tokenId)`.
3. `LPAutoBalancer(lab).registerPosition(config)` with: `feeCollector = DROP_AUTOMATION`; `oracle0/oracle1` = USD feeds matched to `ICLPool(pool).token0()/token1()`; `swapPolicy = 1`; `protectedToken = MAMO`; conservative `minWidth/maxWidth` (multiples of `tickSpacing`); `twapWindow = 1800`; `maxTickDeviation`; `maxRebalanceLossBps = 100`; `minRebalanceInterval = 1 days`; `gauge` = the pool's CL gauge if staking at launch (else `address(0)`).

> **Token-order gotcha:** `oracle0` must price `token0`, `oracle1` must price `token1`. For cbBTC/MAMO, read `ICLPool(pool).token0()` and assign `CHAINLINK_BTC_USD` / `CHAINLINK_MAMO_USD` accordingly. Wrong order → meaningless value floor.

- [ ] **Step 2: Compile**

Run: `forge build`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
forge fmt
git add multisig/f-mamo/006_LPAutoBalancerSetup.sol
git commit -m "feat(lp): proposal build() — move + register positions"
```

### Task 24: Proposal `validate()`

**Files:**
- Modify: `multisig/f-mamo/006_LPAutoBalancerSetup.sol`

- [ ] **Step 1: Implement `validate()`** (view): assert `lab.code.length > 0`; for each registered slot assert the NFT is held by `lab` (`POSITION_MANAGER.ownerOf(tokenId) == lab`), config matches (feeCollector == DROP_AUTOMATION, oracles set + correctly ordered, swapPolicy == 1, protectedToken == MAMO, caps within bounds), `lab.hasRole(REBALANCER_ROLE, MAMO_LP_REBALANCER)`, `lab.hasRole(DEFAULT_ADMIN_ROLE, F-MAMO)`. Use `assertEq`/`assertTrue`.

- [ ] **Step 2: Compile**

Run: `forge build`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
forge fmt
git add multisig/f-mamo/006_LPAutoBalancerSetup.sol
git commit -m "feat(lp): proposal validate()"
```

---

## Phase 8 — Integration (Base fork) & adversarial tests

### Task 25: Integration setUp — run the proposal end-to-end

**Files:**
- Create: `test/LPAutoBalancer.integration.t.sol`

- [ ] **Step 1: Write setUp** (extend `BaseTest`, mirror `test/DropAutomation.integration.t.sol`):

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {LPAutoBalancerSetup} from "../multisig/f-mamo/006_LPAutoBalancerSetup.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LPAutoBalancerIntegrationTest is BaseTest {
    LPAutoBalancer public lab;
    LPAutoBalancerSetup public setupProposal;
    address public rebalancer;

    function setUp() public override {
        super.setUp();
        rebalancer = addresses.getAddress("MAMO_LP_REBALANCER");
        setupProposal = new LPAutoBalancerSetup();
        setupProposal.setAddresses(addresses);
        if (!addresses.isAddressSet("MAMO_LP_AUTO_BALANCER")) {
            address labAddr = setupProposal.deployer().deploy(addresses);
            addresses.addAddress("MAMO_LP_AUTO_BALANCER", labAddr, true);
        }
        lab = LPAutoBalancer(addresses.getAddress("MAMO_LP_AUTO_BALANCER"));
        setupProposal.build();
        setupProposal.simulate();
        setupProposal.validate();
    }

    function test_setup_positionsRegistered() public view {
        (uint256 tokenId,,,,,,,,,,,,,,,,,, bool active) = lab.positions(0); // adjust tuple to struct order
        assertTrue(active);
        assertEq(INonfungiblePositionManager(addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME")).ownerOf(tokenId), address(lab));
    }
}
```

- [ ] **Step 2: Run on fork**

Run: `forge test --fork-url base --ffi --mc LPAutoBalancerIntegration -vvv`
Expected: PASS (setup completes, position registered).

- [ ] **Step 3: Commit**

```bash
forge fmt
git add test/LPAutoBalancer.integration.t.sol
git commit -m "test(lp): integration setUp runs proposal end-to-end"
```

### Task 26: Integration — re-range a real position

**Files:**
- Modify: `test/LPAutoBalancer.integration.t.sol`

- [ ] **Step 1: Write the test** — push the pool tick out of the current range (impersonate a whale or `deal` tokens + swap via `AERODROME_ROUTER`), then `rebalance(slotId, params)` as `rebalancer` with a valid `width`. Assert: new range straddles the new tick; old NFT burned (`ownerOf` reverts) and `pos.tokenId` changed; fees/AERO skimmed to `DROP_AUTOMATION` (balance up); principal USD value preserved within `maxRebalanceLossBps`; dust forwarded (lab token balances ≈ 0). This is where the `MintParams.fee`/`tickSpacing` shape gets verified against the live PM (Task 15 note).

- [ ] **Step 2: Run**

Run: `forge test --fork-url base --ffi --mc LPAutoBalancerIntegration --match-test test_rebalance_realPosition -vvv`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
forge fmt
git add test/LPAutoBalancer.integration.t.sol src/interfaces/INonfungiblePositionManager.sol
git commit -m "test(lp): fork re-range of a real Aerodrome CL position"
```

### Task 27: Integration — gauge stake/claim/restake

**Files:**
- Modify: `test/LPAutoBalancer.integration.t.sol`

- [ ] **Step 1: Write the test** (requires a pool with a live CL gauge — use the cbBTC/MAMO gauge if it exists, else a deep correlated pool e.g. cbBTC/WETH per spec scope; confirm the gauge address on-chain): `stake(slotId)` → `vm.warp` forward → `claimEmissions(slotId)` asserts AERO landed at `DROP_AUTOMATION` → `rebalance(slotId, ...)` asserts it unstaked, re-ranged, restaked (`pos.staked == true`, `gauge.stakedContains(lab, newTokenId)`).

- [ ] **Step 2: Run**

Run: `forge test --fork-url base --ffi --mc LPAutoBalancerIntegration --match-test test_gauge -vvv`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
forge fmt
git add test/LPAutoBalancer.integration.t.sol
git commit -m "test(lp): fork gauge stake/claim/restake"
```

### Task 28: Integration — adversarial

**Files:**
- Modify: `test/LPAutoBalancer.integration.t.sol`

- [ ] **Step 1: Write tests:**
  - manipulate spot (large in-pool swap pushing spot past `maxTickDeviation` from TWAP) → `rebalance` reverts `TwapDeviation`;
  - `swapPolicy=1` (protected=MAMO): force a state where balancing would require selling MAMO → assert no MAMO sold (swap skipped), mint succeeds with dust;
  - garbage `swapMinAmountOut = 0` → swap bounded by quoter floor (succeeds within slippage, not drained);
  - pre-cooldown second call → `Cooldown`;
  - non-rebalancer → `AccessControlUnauthorizedAccount`.

- [ ] **Step 2: Run**

Run: `forge test --fork-url base --ffi --mc LPAutoBalancerIntegration --match-test test_adversarial -vvv`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
forge fmt
git add test/LPAutoBalancer.integration.t.sol
git commit -m "test(lp): fork adversarial — deviation gate, swap policy, slippage floor"
```

### Task 29: Integration — migrate (Safe)

**Files:**
- Modify: `test/LPAutoBalancer.integration.t.sol`

- [ ] **Step 1: Write the test** — `vm.prank(F-MAMO)` calls `migrate(slotId, params)` moving a real position into another pool; assert fees/AERO skimmed, principal moved within `swapMinAmountOut`, slot updated (pool/tokens/tickSpacing/gauge/tokenId), old NFT burned, `Migrated` emitted, and the position is subsequently re-rangeable by `rebalancer` in the new pool. Also assert `rebalancer`/`manager` calling `migrate` revert.

- [ ] **Step 2: Run**

Run: `forge test --fork-url base --ffi --mc LPAutoBalancerIntegration --match-test test_migrate -vvv`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
forge fmt
git add test/LPAutoBalancer.integration.t.sol
git commit -m "test(lp): fork Safe-gated migrate"
```

### Task 30: Makefile target + full suite + docs flip

**Files:**
- Modify: `Makefile`, `docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md`

- [ ] **Step 1: Add the Makefile target** and exclude the heavy fork contract from lean `test`:

```makefile
lp-auto-balancer:
	forge test --fork-url base --ffi --mc LPAutoBalancer -vvv
```
Append `|LPAutoBalancerIntegrationTest` to the `--no-match-contract` filter on the `test` target; add `lp-auto-balancer` to `test-all` + `.PHONY`.

- [ ] **Step 2: Run the full relevant suite**

Run: `make lp-auto-balancer` and `forge test --match-path "test/LPAutoBalancer*.unit.t.sol" -vv`
Expected: ALL PASS.

- [ ] **Step 3: Flip the spec status** — add an "Implemented" note linking this plan; tick the §9 testing checklist items now covered.

- [ ] **Step 4: Commit**

```bash
forge fmt
git add Makefile docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md
git commit -m "chore(lp): make target, suite green, spec status -> implemented"
```

---

## Self-Review

**Spec coverage** (spec §→task):
- §1 two yield sources (fees + AERO) → Tasks 13–14, 27 ✅
- §2 decisions (multi-position, on-chain ticks/swap, Chainlink floor, swap policy) → Tasks 6, 8, 10–11, 15 ✅
- §3.1 trust boundary (on-chain ticks, quoter min, single-tx value floor) → Tasks 8, 12, 15 ✅
- §3.2 roles → Task 5 ✅
- §3.3 state struct (incl. swapPolicy, dual oracles) → Tasks 5–6 ✅
- §3.4 ICLGauge → Task 4 ✅
- §4.1–4.4 stake/unstake/claim/collect/rebalance → Tasks 13–15 ✅
- §4.5 admin fns → Tasks 6–7, 17–18 ✅
- §4.6 events/errors → distributed ✅
- §5 emissions parity → Tasks 13–14, 27 ✅
- §6 scope incl. non-MAMO pools → Task 27 (cbBTC/WETH option) ✅
- §7 deploy + phased rollout (swapPolicy=1 default) → Tasks 20–23 ✅
- §8 migrate (Safe-gated, sanity guards, no value floor) → Tasks 17, 29 ✅
- §9 testing matrix → Tasks 1–3 (KAT), 16, 19, 26–29 ✅
- §10 non-goals (off-chain service, LLM discovery) → out of scope ✅

**Gaps flagged for the implementer (not blockers):**
- Real `tokenId`s in `TRANSFER_AND_EARN` must be looked up on-chain (Task 23) — can't hardcode in the plan.
- Whether a CL **gauge** exists for cbBTC/MAMO at launch decides if Task 27 uses that pool or cbBTC/WETH — confirm on-chain.
- MAMO/USDC pool key may need adding (Task 20 Step 2) if that position launches day one.
- `INonfungiblePositionManager.MintParams` may need a `tickSpacing` field for Slipstream — verify against the live PM in Task 26; extend the interface if required.

**Type/signature consistency:** `_unstake(p, slotId)` signature consistent (Tasks 6, 13, 15, 18). `RebalanceParams`/`ManagedPosition`/`MigrateParams` match the naming contract. `_executeSwap(tokenIn, tokenOut, amountIn, tickSpacing, callerMinOut, maxSlippageBps)` consistent (Tasks 12, 15, 17). `_valueInUsd`/`_principalValue` both consume cached `dec0/dec1`.

**Placeholder scan:** No "TBD"/"add error handling" — every code step has concrete code; vendored-lib steps use explicit provenance + KAT instead of transcription (deliberate, justified at Phase 0 header).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-04-lp-auto-balancer-implementation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
