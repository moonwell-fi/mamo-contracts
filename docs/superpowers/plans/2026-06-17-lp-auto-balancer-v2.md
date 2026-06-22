# LPAutoBalancerV2 (Dual-Position, No-Swap) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a new `LPAutoBalancerV2` contract that manages each slot as a Beefy-CLM-style **dual position** (balanced `main` + single-sided `alt`) and re-ranges via a **swap-free `reset()`**, eliminating the IL crystallization of V1's swap-based `rebalance()`.

**Architecture:** Copy `src/LPAutoBalancer.sol` (V1) as the base — keep the role model, registry, TWAP/oracle/value-floor plumbing, `_alignedRange`/`_floorAlign`, `collectFees`, `claimEmissions`, recover/pause **verbatim**. **Drop the swap entirely:** remove the `SWAP_ROUTER` immutable, `migrate()` (V2 never swaps), `swapPolicy`/`protectedToken`/`maxSlippageBps`. Replace the `ManagedPosition` struct with `ManagedPositionV2` (add `altTokenId`/`mainStaked`/`altStaked`), replace swap-based `rebalance()` with `reset()` (withdraw both → skim fees/AERO → mint balanced main + single-sided alt, no swap), and add Safe-gated `exit()` (withdraw-all-to-Safe, no swap) in place of `migrate()`. Spec: `docs/superpowers/specs/2026-06-17-lp-auto-balancer-v2-dual-position-design.md`.

**Tech Stack:** Solidity 0.8.28, Foundry, OZ AccessControlEnumerable, Aerodrome Slipstream (`ICLPositionManager`, `ICLPool`, `ICLGauge`), Uniswap math libs (`LiquidityAmounts`, `TickMath`). Unit tests run without a fork; integration on Base fork.

---

### Task 1: Scaffold `LPAutoBalancerV2` from V1 (struct swap, remove rebalance)

**Files:**
- Create: `src/LPAutoBalancerV2.sol` (copy of V1, modified)
- Test: `test/LPAutoBalancerV2.unit.t.sol` (new harness)

- [ ] **Step 1: Copy V1 and rename**

```bash
cp src/LPAutoBalancer.sol src/LPAutoBalancerV2.sol
```
In `src/LPAutoBalancerV2.sol`: rename `contract LPAutoBalancer` → `contract LPAutoBalancerV2`. Keep the roles, constructor, `_consultTwapTick`, `_floorAlign`, `_alignedRange`, `collectFees`, `claimEmissions`, `recoverERC20`/`recoverETH`, pause, `onERC721Received`, the value-floor/oracle internals, and the registry functions. **Remove** the `SWAP_ROUTER` immutable + its constructor arg, `migrate()` + `MigrateParams`, and the `ISwapRouter`/`IQuoter`-for-swap imports (keep `QUOTER` only if used for valuation; V2 performs no swaps). `exit()` (Safe-gated withdraw-all) is added in Task 4 to replace `migrate()`.

- [ ] **Step 2: Replace the struct**

Replace `struct ManagedPosition {...}` with `ManagedPositionV2` (drop `swapPolicy`, `protectedToken`; add `altTokenId`, `mainStaked`, `altStaked`; rename `tokenId`→`mainTokenId`, `staked`→`mainStaked`):

```solidity
struct ManagedPositionV2 {
    uint256 mainTokenId;
    uint256 altTokenId;        // 0 when no alt this cycle
    address pool;
    address token0;
    address token1;
    int24   tickSpacing;
    address gauge;
    bool    mainStaked;
    bool    altStaked;
    address feeCollector;
    address oracle0;
    address oracle1;
    uint24  minWidth;
    uint24  maxWidth;
    uint24  maxCenterDeviation;
    uint32  twapWindow;
    int24   maxTickDeviation;
    uint16  maxRebalanceLossBps;
    uint256 minRebalanceInterval;
    uint256 lastRebalance;
    bool    active;
}

mapping(uint256 slotId => ManagedPositionV2) public positions;
```
Update `registerPosition`, `stake`, `unstake`, `collectFees`, `claimEmissions`, the value-floor helper, and any code that read `p.tokenId`/`p.staked`/`p.swapPolicy`/`p.maxSlippageBps` to use the new field names (`p.mainTokenId`/`p.mainStaked`) and to handle `altTokenId` where a position is moved/withdrawn (deregister/withdraw must transfer/burn both NFTs if `altTokenId != 0`). Delete the swap-policy and slippage-cap branches (no swap in V2). `registerPosition` no longer validates `maxSlippageBps`.

- [ ] **Step 3: Remove `rebalance()`, `RebalanceParams`, and `migrate()`**

Delete the entire V1 `rebalance(uint256, RebalanceParams)` function and `struct RebalanceParams`, the `migrate()` function + `MigrateParams` struct + `Migrated` event, the `SWAP_ROUTER` immutable + constructor arg, and V1's `getDecisionSnapshot`/`DecisionSnapshot` (re-added in Task 5). Add a comment placeholder so the file compiles in the interim:

```solidity
// reset() added in Task 2
```

- [ ] **Step 4: Add errors/events for V2**

Add to the events/errors blocks:
```solidity
event Reset(uint256 indexed slotId, uint256 mainTokenId, uint256 altTokenId, int24 tickLower, int24 tickUpper);
error AltMintFailed();
```
Keep all V1 errors/events; remove `SwapPolicyViolation` if present and any `Rebalanced` event V1 used (replaced by `Reset`).

- [ ] **Step 5: Write a compile/registration smoke test**

Create `test/LPAutoBalancerV2.unit.t.sol` — adapt V1's `LPAutoBalancer.unit.t.sol` setUp (mock AERO/gauge/PM/feeds, deploy `LPAutoBalancerV2`). Add:
```solidity
function test_deploys_and_registers() public {
    uint256 slotId = _registerSlot(false);
    (uint256 mainId,,,,,,,,, , , , , , , , , , , ,) = lab.positions(slotId); // adjust tuple arity to ManagedPositionV2
    assertEq(mainId, OLD_TOKEN_ID, "main tokenId stored");
}
```
(Adjust the destructuring to the exact `ManagedPositionV2` field count. `_registerSlot` builds a `ManagedPositionV2` literal with the new fields, no `swapPolicy`/`protectedToken`, and `altTokenId: 0`.)

- [ ] **Step 6: Compile + run**

Run: `forge build` then `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" -vvv`
Expected: compiles; smoke test PASS.

- [ ] **Step 7: Commit**

```bash
forge fmt
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): scaffold dual-position contract from V1 (struct + remove swap-rebalance)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `reset()` — withdraw both, skim, mint balanced main (no alt yet)

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Test: `test/LPAutoBalancerV2.unit.t.sol`

> Build `reset` in two tasks: this one rebuilds only the **main** (parking 100% of withdrawn principal into a balanced main, leftover forwarded to feeCollector as dust); Task 3 adds the single-sided **alt** that captures the leftover instead of dusting it.

- [ ] **Step 1: Write the failing test**

Append to `test/LPAutoBalancerV2.unit.t.sol` (mirror V1's rebalance harness: `mockPool.setSlot0`, `mockPM.setPosition`, `setCollectSequence`, `setNextMintResult`):
```solidity
function test_reset_rebuildsMain_noSwapCall() public {
    uint256 slotId = _registerSlot(false);
    _stagePrincipal(1e18, 1e18); // balanced principal

    vm.prank(rebalancer);
    lab.reset(slotId, _defaultResetParams());

    // slot still active
    ( , , , , , , , , , , , , , , , , , , , , bool active) = lab.positions(slotId);
    assertTrue(active, "slot active");
    // router must NOT be called on the reset path (the IL-defining property)
    assertEq(mockRouter.callCount(), 0, "reset must not swap");
    // old main NFT burned
    assertEq(mockPM.burnCallCount(), 1, "old main burned");
}
```
Add a `MockRouterV2` (or extend the existing mock) exposing `callCount()` that increments on any swap entrypoint, wired as the `router` constructor arg, so the no-swap assertion is real. Add `_defaultResetParams()` returning a `ResetParams` with `width: 400`, generous mins (0), `deadline: block.timestamp + 1`.

- [ ] **Step 2: Run, expect FAIL**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test test_reset -vvv`
Expected: FAIL — `reset` not defined.

- [ ] **Step 3: Add `ResetParams` + `reset` (main only)**

In `src/LPAutoBalancerV2.sol`:
```solidity
struct ResetParams {
    uint24  width;
    uint256 amount0MinMain;
    uint256 amount1MinMain;
    uint256 amount0MinAlt;
    uint256 amount1MinAlt;
    uint256 amount0MinWithdraw;
    uint256 amount1MinWithdraw;
    uint256 deadline;
}

function reset(uint256 slotId, ResetParams calldata params)
    external
    onlyRole(REBALANCER_ROLE)
    nonReentrant
    whenNotPaused
{
    ManagedPositionV2 storage p = positions[slotId];
    if (!p.active) revert NotActive();
    if (block.timestamp < p.lastRebalance + p.minRebalanceInterval) revert Cooldown();

    // 1. calm gate (reference tick = TWAP tick) — reuse V1 helpers
    (, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
    int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
    _checkDeviation(spotTick, twapTick, p.maxTickDeviation);

    // 2. pre-value (reuse V1 principal-value helper over BOTH nfts)
    uint256 valueBefore = _principalValue(p, p.mainTokenId) + _altValue(p);

    // 3. unstake + skim AERO, collect fees, withdraw all, burn both
    _exitAll(p); // see Step 4

    // 4. compute main range + mint balanced main
    if (params.width < p.minWidth || params.width > p.maxWidth) revert WidthOutOfBounds();
    (int24 tl, int24 tu) = _alignedRange(twapTick, params.width, p.tickSpacing, spotTick);
    uint256 newMain = _mintBalanced(p, tl, tu, params); // see Step 5

    p.mainTokenId = newMain;
    p.altTokenId = 0; // alt added in Task 3
    p.lastRebalance = block.timestamp;

    // 5. value floor (sanity)
    uint256 valueAfter = _principalValue(p, p.mainTokenId);
    if (valueAfter < valueBefore * (BPS_DENOMINATOR - p.maxRebalanceLossBps) / BPS_DENOMINATOR) revert ValueFloor();

    // 6. forward leftover dust (Task 3 replaces this with the alt mint)
    _forwardDust(p);

    if (p.mainStaked && p.gauge != address(0)) { ICLGauge(p.gauge).deposit(newMain); }

    emit Reset(slotId, newMain, 0, tl, tu);
}
```

- [ ] **Step 4: Add the `_exitAll` / `_altValue` helpers**

Adapt from V1's rebalance internals (unstake → claim AERO skim → collect fees skim → decreaseLiquidity(all) → collect principal → burn). Make it handle both `mainTokenId` and (if non-zero) `altTokenId`. `_altValue(p)` returns 0 when `p.altTokenId == 0`, else the alt principal via the same `_principalValue` logic. Reuse V1's fee/AERO skim code verbatim; just loop over the two token ids.

- [ ] **Step 5: Add `_mintBalanced`**

```solidity
/// @dev Mint a balanced position for [tl,tu] using as much of the contract's
///      current token0/token1 as fits the range's ratio at the current sqrtPrice.
///      Returns the new tokenId. Leftover stays in the contract (Task 3 alt / dust).
function _mintBalanced(ManagedPositionV2 storage p, int24 tl, int24 tu, ResetParams calldata params)
    internal
    returns (uint256 tokenId)
{
    uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
    uint256 bal1 = IERC20(p.token1).balanceOf(address(this));
    (uint160 sqrtP,,,,,) = ICLPool(p.pool).slot0();
    // approve PM, mint via ICLPositionManager.MintParams (mirror V1's mint call shape:
    // int24 tickSpacing + trailing uint160 sqrtPriceX96). amount0Desired/1Desired = bal0/bal1,
    // mins = params.amount{0,1}MinMain. The PM consumes only the balanced portion; the
    // rest is returned to the contract balance.
    (tokenId,,,) = POSITION_MANAGER.mint(/* MintParams: token0,token1,tickSpacing,tl,tu,bal0,bal1,
        amount0MinMain,amount1MinMain, recipient=address(this), deadline, sqrtPriceX96=sqrtP */);
}
```
Copy the exact `ICLPositionManager.MintParams` field layout from V1's `rebalance` mint call. The key property: pass full balances as desired, the PM takes only the in-ratio amount, leftover remains for Task 3.

- [ ] **Step 6: Run, expect PASS**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test test_reset -vvv`
Expected: PASS (main rebuilt, no router call, old NFT burned).

- [ ] **Step 7: Commit**

```bash
forge fmt
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): reset() rebuilds balanced main with no swap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Single-sided `alt` mint (capture leftover, no swap)

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Test: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Write the failing test**

```solidity
function test_reset_mintsAltFromLeftover() public {
    uint256 slotId = _registerSlot(false);
    // Imbalanced principal: more token0 than fits 50/50 => leftover token0 => alt on token0 side
    _stagePrincipal(3e18, 1e18);
    mockPM.setNextMintResult(NEW_TOKEN_ID, 1e18);     // main
    mockPM.setNextAltMintResult(ALT_TOKEN_ID, 5e17);  // alt (add this setter to the mock)

    vm.prank(rebalancer);
    lab.reset(slotId, _defaultResetParams());

    ( , uint256 altId, ) = _readMainAlt(slotId); // helper reading the two ids
    assertEq(altId, ALT_TOKEN_ID, "alt minted from leftover");
    assertEq(mockRouter.callCount(), 0, "still no swap");
}

function test_reset_skipsAltWhenLeftoverDust() public {
    uint256 slotId = _registerSlot(false);
    _stagePrincipal(1e18, 1e18); // balanced => negligible leftover
    vm.prank(rebalancer);
    lab.reset(slotId, _defaultResetParams());
    ( , uint256 altId, ) = _readMainAlt(slotId);
    assertEq(altId, 0, "no alt when leftover is dust");
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test test_reset_mintsAlt -vvv`
Expected: FAIL.

- [ ] **Step 3: Replace the dust-forward in `reset` with the alt mint**

Add `_mintAlt` and call it in `reset` where Task 2 did `_forwardDust`; set `p.altTokenId = _mintAlt(p, tl, tu, params);` and include the alt in the post-value (`valueAfter = _principalValue(p, p.mainTokenId) + _altValue(p);`) and the `Reset` event:
```solidity
/// @dev After the balanced main is minted, deploy the surplus leg single-sided
///      in a narrow range from the main's overweight boundary to the nearest tick.
///      No swap. Returns altTokenId (0 if leftover is below DUST).
function _mintAlt(ManagedPositionV2 storage p, int24 mainTl, int24 mainTu, ResetParams calldata params)
    internal
    returns (uint256 altId)
{
    uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
    uint256 bal1 = IERC20(p.token1).balanceOf(address(this));
    bool surplus0 = bal0 >= bal1;
    uint256 surplus = surplus0 ? bal0 : bal1;
    if (surplus < ALT_DUST) { _forwardDust(p); return 0; }

    // single-sided range: token0 surplus => range ABOVE main upper (token0-only side);
    // token1 surplus => range BELOW main lower (token1-only side). One tickSpacing wide.
    int24 altTl;
    int24 altTu;
    if (surplus0) { altTl = mainTu; altTu = mainTu + p.tickSpacing; }
    else { altTu = mainTl; altTl = mainTl - p.tickSpacing; }

    (altId,,,) = POSITION_MANAGER.mint(/* MintParams: ...,altTl,altTu, bal0,bal1,
        amount0MinAlt,amount1MinAlt, recipient=address(this), deadline, sqrtPriceX96 */);
    _forwardDust(p); // forward any sub-tick remainder
}
```
Add `uint256 internal constant ALT_DUST` (document the unit — a small token-amount threshold).

> **Single-sided correctness:** a range entirely above the current tick holds only token0; entirely below holds only token1. The `surplus0 ? above : below` choice guarantees the alt is fundable from the surplus leg with no swap. Verify the tick direction against the pool's token0/token1 orientation when implementing; flip if the mock reveals inverted orientation.

- [ ] **Step 4: Run, expect PASS**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test test_reset -vvv`
Expected: PASS (alt minted on imbalance; skipped on dust; no swap).

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): single-sided alt mint captures leftover (no swap)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Stake/unstake per-pair (alt follows) + claimEmissions over both + `exit()`

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Test: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Write the failing test**

```solidity
function test_stake_main_altFollows() public {
    uint256 slotId = _registerSlotWithAlt(true); // helper: gauged slot with a non-zero altTokenId
    vm.prank(rebalancer);
    lab.stake(slotId);
    (bool mainStaked, bool altStaked) = _readStakeFlags(slotId);
    assertTrue(mainStaked, "main staked");
    assertTrue(altStaked, "alt follows main");
}

function test_claimEmissions_sumsBothNfts() public {
    uint256 slotId = _registerSlotWithAlt(true);
    vm.prank(rebalancer);
    lab.stake(slotId);
    mockGauge.setEarnedAmount(7e18);
    uint256 before = mockAero.balanceOf(feeCollector);
    lab.claimEmissions(slotId);
    assertGt(mockAero.balanceOf(feeCollector), before, "AERO from both nfts forwarded to feeCollector");
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test "test_stake_main_altFollows|test_claimEmissions" -vvv`
Expected: FAIL (stake/claim still V1 single-nft).

- [ ] **Step 3: Update `stake`/`unstake`/`claimEmissions`**

```solidity
function stake(uint256 slotId) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
    ManagedPositionV2 storage p = positions[slotId];
    if (p.gauge == address(0)) revert NoGauge();
    if (p.mainStaked) revert AlreadyStaked();
    POSITION_MANAGER.approve(p.gauge, p.mainTokenId);
    ICLGauge(p.gauge).deposit(p.mainTokenId);
    p.mainStaked = true;
    if (p.altTokenId != 0) {
        POSITION_MANAGER.approve(p.gauge, p.altTokenId);
        ICLGauge(p.gauge).deposit(p.altTokenId);
        p.altStaked = true;
    }
    emit Staked(slotId, p.mainTokenId, p.gauge);
}

function unstake(uint256 slotId) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
    ManagedPositionV2 storage p = positions[slotId];
    if (!p.mainStaked) revert NotStaked();
    ICLGauge(p.gauge).withdraw(p.mainTokenId);
    p.mainStaked = false;
    if (p.altStaked && p.altTokenId != 0) {
        ICLGauge(p.gauge).withdraw(p.altTokenId);
        p.altStaked = false;
    }
    uint256 aero = IERC20(AERO).balanceOf(address(this));
    if (aero > 0) IERC20(AERO).safeTransfer(p.feeCollector, aero);
    emit Unstaked(slotId, p.mainTokenId, p.gauge);
    emit EmissionsClaimed(slotId, aero);
}
```
Update `claimEmissions` to call `gauge.getReward` for `mainTokenId` and (if `altStaked`) `altTokenId`, then forward the whole AERO balance to `feeCollector`.

- [ ] **Step 4: Run, expect PASS**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test "test_stake_main_altFollows|test_claimEmissions" -vvv`
Expected: PASS.

- [ ] **Step 5: Write the failing `exit()` tests**

```solidity
function test_exit_returnsBothTokensToSafe_andDeactivates() public {
    uint256 slotId = _registerSlotWithAlt(false); // main + alt, unstaked
    _stagePrincipal(2e18, 1e18); // PM holds principal to return on decrease/collect

    vm.prank(admin);
    lab.exit(slotId, admin);

    // both NFTs burned
    assertEq(mockPM.burnCallCount(), 2, "main + alt burned");
    // all underlying returned to `to` (admin)
    assertGt(tok0.balanceOf(admin), 0, "token0 to Safe");
    assertGt(tok1.balanceOf(admin), 0, "token1 to Safe");
    // contract holds no dust
    assertEq(tok0.balanceOf(address(lab)), 0, "no token0 left");
    assertEq(tok1.balanceOf(address(lab)), 0, "no token1 left");
    // slot inactive
    ( , , , , , , , , , , , , , , , , , , bool active) = lab.positions(slotId); // adjust arity
    assertFalse(active, "slot deactivated");
    // no swap
    assertEq(mockRouter.callCount(), 0, "exit must not swap");
}

function test_exit_onlyAdmin() public {
    uint256 slotId = _registerSlotWithAlt(false);
    vm.prank(rebalancer);
    vm.expectRevert(); // REBALANCER_ROLE is not DEFAULT_ADMIN_ROLE
    lab.exit(slotId, rebalancer);
}

function test_exit_unstakesAndSkimsAero_whenStaked() public {
    uint256 slotId = _registerSlotWithAlt(true);
    vm.prank(rebalancer);
    lab.stake(slotId);
    mockGauge.setEarnedAmount(4e18);
    uint256 before = mockAero.balanceOf(feeCollector);
    vm.prank(admin);
    lab.exit(slotId, admin);
    assertGt(mockAero.balanceOf(feeCollector), before, "AERO skimmed on exit");
}
```

- [ ] **Step 6: Run, expect FAIL**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test test_exit -vvv`
Expected: FAIL — `exit` not defined.

- [ ] **Step 7: Implement `exit()` (Safe-gated, no swap)**

```solidity
/// @notice Emergency / migration primitive (spec §3.6). Withdraws all liquidity from
///         main + alt, burns both NFTs, returns ALL underlying token0/token1 to `to`
///         (the Safe), marks the slot inactive. Skims any fees/AERO to feeCollector. No swap.
function exit(uint256 slotId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
    ManagedPositionV2 storage p = positions[slotId];
    if (!p.active) revert NotActive();
    if (to == address(0)) revert ZeroAddress();

    _exitAll(p); // unstake (skim AERO) + collect fees (skim) + decreaseLiquidity(all) + collect principal + burn both

    uint256 bal0 = IERC20(p.token0).balanceOf(address(this));
    uint256 bal1 = IERC20(p.token1).balanceOf(address(this));
    if (bal0 > 0) IERC20(p.token0).safeTransfer(to, bal0);
    if (bal1 > 0) IERC20(p.token1).safeTransfer(to, bal1);

    p.mainTokenId = 0;
    p.altTokenId = 0;
    p.active = false;
    emit PositionWithdrawn(slotId, to); // reuse V1 event, or add Exited(slotId, to, bal0, bal1)
}
```
Reuse the `_exitAll` helper from Task 2 (it already unstakes/skims/withdraws/burns both NFTs). `exit` differs from `reset` only in that it forwards the recovered principal to `to` instead of re-minting.

- [ ] **Step 8: Run, expect PASS**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test test_exit -vvv`
Expected: PASS (3 exit tests).

- [ ] **Step 9: Commit**

```bash
forge fmt
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): per-pair stake (alt follows) + claim over both + exit() to Safe

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `getDecisionSnapshot` V2 (main + alt fields)

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Test: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Write the failing test**

```solidity
function test_getDecisionSnapshotV2_fields() public {
    uint256 slotId = _registerSlotWithAlt(false);
    LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot(slotId);
    assertEq(s.spotTick, SPOT_TICK, "spot");
    assertTrue(s.mainInRange, "main in range");
    assertTrue(s.hasAlt, "alt present");
    assertEq(s.mainLiquidity, OLD_LIQ, "main liq");
    assertGt(s.altLiquidity, 0, "alt liq");
    assertFalse(s.mainStaked, "not staked");
    assertTrue(s.deviationGateOpen, "calm");
}

function test_getDecisionSnapshotV2_earnedAero_tryCatch() public {
    uint256 slotId = _registerSlotWithAlt(true);
    vm.prank(rebalancer);
    lab.stake(slotId);
    mockGauge.setEarnedAmount(3e18);
    LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot(slotId);
    assertGt(s.earnedAero, 0, "earned summed over staked nfts");
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test getDecisionSnapshotV2 -vvv`
Expected: FAIL.

- [ ] **Step 3: Add the struct + view**

```solidity
struct DecisionSnapshotV2 {
    int24 spotTick;
    int24 twapTick;
    int24 mainTickLower;
    int24 mainTickUpper;
    bool  mainInRange;
    int24 altTickLower;
    int24 altTickUpper;
    bool  hasAlt;
    uint128 mainLiquidity;
    uint128 altLiquidity;
    bool  mainStaked;
    bool  hasGauge;
    uint256 earnedAero;
    uint256 cooldownRemaining;
    bool  deviationGateOpen;
}

function getDecisionSnapshot(uint256 slotId) external view returns (DecisionSnapshotV2 memory s) {
    ManagedPositionV2 storage p = positions[slotId];
    if (!p.active) revert NotActive();

    (, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
    int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
    (,,,,, int24 mtl, int24 mtu, uint128 mliq,,,,) = POSITION_MANAGER.positions(p.mainTokenId);

    s.spotTick = spotTick;
    s.twapTick = twapTick;
    s.mainTickLower = mtl;
    s.mainTickUpper = mtu;
    s.mainInRange = mtl <= spotTick && spotTick < mtu;
    s.mainLiquidity = mliq;
    s.hasAlt = p.altTokenId != 0;
    if (s.hasAlt) {
        (,,,,, int24 atl, int24 atu, uint128 aliq,,,,) = POSITION_MANAGER.positions(p.altTokenId);
        s.altTickLower = atl;
        s.altTickUpper = atu;
        s.altLiquidity = aliq;
    }
    s.mainStaked = p.mainStaked;
    s.hasGauge = p.gauge != address(0);

    uint256 aero;
    if (p.mainStaked) {
        try ICLGauge(p.gauge).earned(address(this), p.mainTokenId) returns (uint256 e) { aero += e; } catch {}
    }
    if (p.altStaked && p.altTokenId != 0) {
        try ICLGauge(p.gauge).earned(address(this), p.altTokenId) returns (uint256 e) { aero += e; } catch {}
    }
    s.earnedAero = aero;

    uint256 ready = p.lastRebalance + p.minRebalanceInterval;
    s.cooldownRemaining = block.timestamp >= ready ? 0 : ready - block.timestamp;
    int24 dev = spotTick > twapTick ? spotTick - twapTick : twapTick - spotTick;
    s.deviationGateOpen = dev <= p.maxTickDeviation;
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" --match-test getDecisionSnapshotV2 -vvv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
forge fmt
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): getDecisionSnapshot V2 (main + alt fields)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Adversarial guards + Base-fork integration

**Files:**
- Modify: `test/LPAutoBalancerV2.unit.t.sol`
- Create: `test/LPAutoBalancerV2.integration.t.sol`

- [ ] **Step 1: Adversarial unit tests**

Append to the unit file (port V1's adversarial tests to `reset`):
```solidity
function test_reset_revertsOnManipulatedSpot() public {
    uint256 slotId = _registerSlot(false);
    mockPool.setSlot0(SQRT_P, 5000); // far from twap 0 => |dev| > maxTickDeviation
    vm.prank(rebalancer);
    vm.expectRevert(LPAutoBalancerV2.TwapDeviation.selector);
    lab.reset(slotId, _defaultResetParams());
}

function test_reset_revertsBeforeCooldown() public {
    uint256 slotId = _registerSlotWithInterval(3600);
    vm.warp(100);
    vm.prank(rebalancer);
    vm.expectRevert(LPAutoBalancerV2.Cooldown.selector);
    lab.reset(slotId, _defaultResetParams());
}

function test_reset_revertsOnWidthOutOfBounds() public {
    uint256 slotId = _registerSlot(false);
    LPAutoBalancerV2.ResetParams memory pr = _defaultResetParams();
    pr.width = 1; // below minWidth
    vm.prank(rebalancer);
    vm.expectRevert(LPAutoBalancerV2.WidthOutOfBounds.selector);
    lab.reset(slotId, pr);
}

function test_reset_onlyRebalancer() public {
    uint256 slotId = _registerSlot(false);
    vm.expectRevert();
    lab.reset(slotId, _defaultResetParams()); // no prank => not REBALANCER_ROLE
}
```

- [ ] **Step 2: Run, expect PASS**

Run: `forge test --ffi --match-path "test/LPAutoBalancerV2.unit.t.sol" -vvv`
Expected: PASS (full V2 unit suite).

- [ ] **Step 3: Base-fork integration test**

Create `test/LPAutoBalancerV2.integration.t.sol` (mirror V1's `LPAutoBalancerIntegration` style — `vm.createSelectFork("base")`, real `ICLPositionManager`/pool/gauge for **WETH/cbBTC** — the correlated, gauged phase-1 pair (§7), real `_alignedRange`). Bootstrap the position the way the FPS setup will (mint a WETH/cbBTC CL position from test-held WETH+cbBTC, transfer the NFT into the contract, `registerPosition` gauged with WETH/USD + cbBTC/USD Chainlink oracles). One end-to-end test: register the WETH/cbBTC position, push tick out of range, `reset(width)`, assert:
- main + alt rebuilt (both NFTs owned by the contract),
- **no token sold** (compare token0/token1 contract balances before/after the deposit — principal conserved within mint rounding),
- fees/AERO forwarded to `feeCollector`,
- `mainInRange == true` afterward via `getDecisionSnapshot`,
- old NFTs burned, `Reset` emitted.

- [ ] **Step 4: Run integration**

Run: `forge test --fork-url base --ffi --match-path "test/LPAutoBalancerV2.integration.t.sol" -vvv`
Expected: PASS.

- [ ] **Step 5: Add the Makefile target + commit**

Add to `Makefile`:
```makefile
lp-auto-balancer-v2:
	forge test --fork-url base --ffi --mc LPAutoBalancerV2Integration -vvv
```
```bash
forge fmt
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol test/LPAutoBalancerV2.integration.t.sol Makefile
git commit -m "test(lpv2): adversarial guards + Base-fork no-swap integration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** §3.1 struct (no `maxSlippageBps`) → Task 1; §3.2/§3.3 reset (no-swap, withdraw/skim/mint-main/value-floor) → Task 2; alt single-sided mint → Task 3; §3.4 per-pair stake + §3.6 `exit()` → Task 4; §3.5 getDecisionSnapshot V2 → Task 5; §8 adversarial + no-swap assertion + WETH/cbBTC fork integration → Task 6. §4 carryover (registry/oracle/pause) → reused verbatim in Task 1; `SWAP_ROUTER`/`migrate()` **removed** there (no swap in V2). §4 drop economics (skim, no compound) → preserved in `_exitAll` (Task 2). Phase-2 automated migration (§6) builds on `exit()` + future safety rails — out of this plan's scope.
- **Placeholder scan:** mint `MintParams` field layouts in `_mintBalanced`/`_mintAlt` are shown as commented field lists rather than literal struct constructors, because the exact `ICLPositionManager.MintParams` field order must be copied from V1's working mint call (Task 2 Step 5 / Task 3 Step 3 instruct this explicitly). This is a copy-from-V1 instruction, not an unresolved TODO. All test code is complete.
- **Type consistency:** `ManagedPositionV2` field names (`mainTokenId`/`mainStaked`/`altTokenId`/`altStaked`) used consistently across reset, stake/unstake, getDecisionSnapshot. `DecisionSnapshotV2` field order matches the centaur decoder update (Plan B Task 2). `ResetParams` fields referenced consistently in `reset`/`_mintBalanced`/`_mintAlt`. Errors (`TwapDeviation`, `Cooldown`, `WidthOutOfBounds`, `ValueFloor`, `NotActive`, `NoGauge`, `AlreadyStaked`, `NotStaked`) reused from V1.
- **Risk note:** the single-sided alt tick-direction (above vs below current tick for token0 vs token1 surplus) depends on pool token orientation — Task 3 Step 3 flags verifying/flipping against the mock. The Base-fork integration (Task 6) is the real proof the no-swap redeploy conserves principal.
