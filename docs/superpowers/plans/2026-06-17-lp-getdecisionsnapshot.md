# getDecisionSnapshot View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single read-only `getDecisionSnapshot(uint256 slotId)` view to `LPAutoBalancer` that batches the gate-relevant chain facts the off-chain agent needs (companion spec §4.7).

**Architecture:** One `external view` returning a `DecisionSnapshot` struct, derived from `positions[slotId]` + `POSITION_MANAGER.positions(tokenId)` + `ICLPool(pool).slot0()` + the existing `_consultTwapTick` helper. No state change, no new powers, no new dependency. Tests reuse the existing `LPAutoBalancerRebalance.unit.t.sol` harness (its `MockPositionManagerV2`/`MockCLPoolV2` are the only mocks with settable `positions()`/`slot0()`).

**Tech Stack:** Solidity 0.8.28, Foundry (forge), OZ AccessControlEnumerable. Unit tests run without a fork.

---

### Task 1: `DecisionSnapshot` struct + `getDecisionSnapshot` view

**Files:**
- Modify: `src/LPAutoBalancer.sol` (add struct near `RebalanceParams`; add view near `collectFees` at ~`src/LPAutoBalancer.sol:801`)
- Test: `test/LPAutoBalancerRebalance.unit.t.sol` (add tests + reuse existing mocks/`setUp`/`_registerSlot`)

- [ ] **Step 1: Write the failing tests**

Append these tests to `test/LPAutoBalancerRebalance.unit.t.sol` (inside the existing test contract — it already wires `mockPool.setSlot0`, `mockPM.setPosition`, `_registerSlot`, and the constants `SPOT_TICK=100`, `TWAP_TICK=0`, `OLD_TL=-200`, `OLD_TU=200`, `OLD_LIQ=1e18`):

```solidity
function test_getDecisionSnapshot_inRange_noGauge() public {
    uint256 slotId = _registerSlot(false); // no gauge

    LPAutoBalancer.DecisionSnapshot memory s = lab.getDecisionSnapshot(slotId);

    assertEq(s.spotTick, SPOT_TICK, "spotTick");
    assertEq(s.twapTick, TWAP_TICK, "twapTick");
    assertEq(s.tickLower, OLD_TL, "tickLower");
    assertEq(s.tickUpper, OLD_TU, "tickUpper");
    assertTrue(s.inRange, "should be in range (-200<=100<200)");
    assertFalse(s.staked, "not staked");
    assertFalse(s.hasGauge, "no gauge");
    assertEq(s.liquidity, OLD_LIQ, "liquidity");
    assertEq(s.earnedAero, 0, "no aero when unstaked");
    assertEq(s.cooldownRemaining, 0, "no cooldown (interval 0)");
    assertTrue(s.deviationGateOpen, "|100-0|=100 <= 200");
}

function test_getDecisionSnapshot_hasGauge_flag() public {
    uint256 slotId = _registerSlot(true); // with gauge
    LPAutoBalancer.DecisionSnapshot memory s = lab.getDecisionSnapshot(slotId);
    assertTrue(s.hasGauge, "gauge configured => hasGauge true");
    assertFalse(s.staked, "registered but not staked");
}

function test_getDecisionSnapshot_outOfRange_closesDeviationGate() public {
    uint256 slotId = _registerSlot(false);
    // Push spot far from TWAP: tick 500, twap stays 0. 500 not < 200 => out of range;
    // |500-0|=500 > maxTickDeviation(200) => gate closed.
    mockPool.setSlot0(SQRT_P, 500);

    LPAutoBalancer.DecisionSnapshot memory s = lab.getDecisionSnapshot(slotId);
    assertFalse(s.inRange, "500 not in [-200,200)");
    assertFalse(s.deviationGateOpen, "|500-0| > 200");
}

function test_getDecisionSnapshot_cooldownRemaining() public {
    // Register a slot with a non-zero cooldown to exercise cooldownRemaining.
    LPAutoBalancer.ManagedPosition memory cfg = LPAutoBalancer.ManagedPosition({
        tokenId: OLD_TOKEN_ID,
        pool: address(mockPool),
        token0: address(tok0),
        token1: address(tok1),
        tickSpacing: 200,
        gauge: address(0),
        staked: false,
        feeCollector: feeCollector,
        oracle0: address(feed0),
        oracle1: address(feed1),
        swapPolicy: 0,
        protectedToken: address(0),
        minWidth: 200,
        maxWidth: 2000,
        maxCenterDeviation: 400,
        maxSlippageBps: 100,
        twapWindow: 1800,
        maxTickDeviation: 200,
        maxRebalanceLossBps: 100,
        minRebalanceInterval: 3600, // 1h cooldown; lastRebalance starts at 0
        lastRebalance: 0,
        active: false
    });
    vm.prank(admin);
    uint256 slotId = lab.registerPosition(cfg);

    vm.warp(1000); // ready = lastRebalance(0)+3600 = 3600; remaining = 3600-1000
    LPAutoBalancer.DecisionSnapshot memory s = lab.getDecisionSnapshot(slotId);
    assertEq(s.cooldownRemaining, 2600, "3600 - 1000");
}

function test_getDecisionSnapshot_revertsOnInactiveSlot() public {
    vm.expectRevert(LPAutoBalancer.NotActive.selector);
    lab.getDecisionSnapshot(999);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `forge test --ffi --match-path "test/LPAutoBalancerRebalance.unit.t.sol" --match-test getDecisionSnapshot -vvv`
Expected: FAIL — compile error / `DeclarationError: getDecisionSnapshot not found` (struct + function don't exist yet).

- [ ] **Step 3: Add the `DecisionSnapshot` struct**

In `src/LPAutoBalancer.sol`, directly after the `RebalanceParams` struct (~line 384), add:

```solidity
/// @notice Read-only snapshot of the gate-relevant facts the off-chain agent needs.
///         No emission rate — ICLGauge has no rewardRate getter; emission APR is
///         sourced off-chain (LpSugar/DefiLlama). See spec §4.7.
struct DecisionSnapshot {
    int24 spotTick;
    int24 twapTick;
    int24 tickLower;
    int24 tickUpper;
    bool inRange;
    bool staked;
    bool hasGauge;
    uint128 liquidity;
    uint256 earnedAero;
    uint256 cooldownRemaining;
    bool deviationGateOpen;
}
```

- [ ] **Step 4: Implement the view**

In `src/LPAutoBalancer.sol`, after `collectFees` (~line 818), add:

```solidity
/// @notice Batched, gate-relevant read for the off-chain decisioning agent (spec §4.7).
///         View-only; reverts if the slot is inactive.
function getDecisionSnapshot(uint256 slotId) external view returns (DecisionSnapshot memory s) {
    ManagedPosition storage p = positions[slotId];
    if (!p.active) revert NotActive();

    (, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
    int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
    (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = POSITION_MANAGER.positions(p.tokenId);

    int24 dev = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
    uint256 ready = p.lastRebalance + p.minRebalanceInterval;

    s.spotTick = spotTick;
    s.twapTick = twapTick;
    s.tickLower = tl;
    s.tickUpper = tu;
    s.inRange = tl <= spotTick && spotTick < tu;
    s.staked = p.staked;
    s.hasGauge = p.gauge != address(0);
    s.liquidity = liq;
    s.earnedAero = (p.staked && p.gauge != address(0)) ? ICLGauge(p.gauge).earned(address(this), p.tokenId) : 0;
    s.cooldownRemaining = block.timestamp >= ready ? 0 : ready - block.timestamp;
    s.deviationGateOpen = dev <= p.maxTickDeviation;
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `forge test --ffi --match-path "test/LPAutoBalancerRebalance.unit.t.sol" --match-test getDecisionSnapshot -vvv`
Expected: PASS (5 tests).

- [ ] **Step 6: Run the full unit suite to confirm no regression**

Run: `forge test --ffi --match-path "test/*.unit.t.sol" -vvv`
Expected: PASS (existing LPAutoBalancer unit tests + the 5 new ones).

- [ ] **Step 7: Format and commit**

```bash
forge fmt
git add src/LPAutoBalancer.sol test/LPAutoBalancerRebalance.unit.t.sol docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md
git commit -m "feat(lp): getDecisionSnapshot view for the off-chain agent

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** spec §4.7 `DecisionSnapshot` (all fields minus `gaugeRewardRate`, per the emission-rate correction) — Task 1. `hasGauge` gating signal — asserted in `test_getDecisionSnapshot_hasGauge_flag`. No emission rate on-chain — reflected by `earnedAero`-only + the comment.
- **Placeholder scan:** none — every step has full code and an exact command.
- **Type consistency:** `DecisionSnapshot` field names/types match the view body and the test asserts. `NotActive` is an existing error (in the contract's error list). `_consultTwapTick`, `POSITION_MANAGER.positions`, `ICLPool.slot0`, `ICLGauge.earned` signatures match the contract verbatim.
