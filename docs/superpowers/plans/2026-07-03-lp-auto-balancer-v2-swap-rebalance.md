# LP Auto Balancer V2 Swap-Rebalance (CowSwap Two-Phase) Implementation Plan

> **2026-07-14 editorial note:** references to `LPBalancerLib` below are historical — that spillover
> library was later split by domain into `LPGeometryLib` / `LPValuationLib` / `LPPositionLib`
> (bytecode-neutral refactor). The plan text is preserved as written.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an async, MEV-protected principal-rebalance mode to `LPAutoBalancerV2`: unwind both LP positions, sell the excess leg via CowSwap (EIP-1271 validated by `LPCompoundModule`), then rebuild a balanced position — alongside the existing no-swap path, which is renamed `rebalanceUsingAlt()`.

**Architecture:** Two-phase state machine on the balancer: `unwindForSwap()` tears down positions, snapshots USD value, approves the CowSwap vault relayer for exactly the sell amount, and sets `rebalanceInFlight`; `rebuildAfterSwap()` revokes the approval, re-mints main+alt from whatever the contract holds (filled or unfilled order), enforces a value floor, and clears the flag. Order validation lives on `LPCompoundModule.validateRebalanceOrder` (window-gated on `rebalanceInFlight`); the balancer exposes a ~3-line `isValidSignature` passthrough because it has only ~590 bytes of EIP-170 headroom. `exit()` is the always-available mid-flight escape hatch.

**Tech Stack:** Solidity 0.8.28, Foundry (forge), OpenZeppelin AccessControlEnumerable/ReentrancyGuard/Pausable/SafeERC20, GPv2Order (CowSwap), Aerodrome CL (Slipstream) pool/gauge/NFPM, Chainlink-backed `SlippagePriceChecker`.

**Key commands:**
- Balancer unit suite: `forge test --mc LPAutoBalancerV2UnitTest -vv`
- Module unit suite: `forge test --mc LPCompoundModuleUnitTest -vv`
- Fork suite: `BASE_RPC_URL=https://mainnet.base.org forge test --ffi --mc LPAutoBalancerV2Integration -vv` (never add `--fork-url` — the test self-forks at a pinned block; adding it double-forks and panics on the OP-stack L1Block handler)
- Setup proposal fork test: `make lp-v2-setup`
- Size check: `forge build --sizes 2>/dev/null | grep LPAutoBalancerV2`

**Manual follow-up (NOT a task in this plan):** the `CHAINLINK_SWAP_CHECKER_PROXY` owner (not F-MAMO, not us) must add `WETH->cbBTC` and `cbBTC->WETH` price-feed configs to the slippage price checker before rebalance orders can settle in production. We do not own that contract, so no task calls it — it is recorded in the runbook (Task 9).

---

### Task 1: Rename `reset()` → `rebalanceUsingAlt()` across the codebase

Purely mechanical rename, behavior UNCHANGED. Three names change everywhere:
- function `reset` → `rebalanceUsingAlt`
- struct `ResetParams` → `RebalanceParams` (same fields, same order, same types)
- event `Reset(...)` → `RebalancedUsingAlt(...)` (same fields)

**Files:**
- Modify: `src/LPAutoBalancerV2.sol` (the `ResetParams` struct declaration, the `event Reset` declaration, the `reset()` function at ~line 516, and the `ResetParams calldata` parameter types on the private helpers `_mintBalanced` and `_mintAlt`)
- Modify: `test/LPAutoBalancerV2.unit.t.sol` (all `lab.reset(`, `LPAutoBalancerV2.ResetParams`, `_defaultResetParams` occurrences; rename helper to `_defaultRebalanceParams`; rename tests `test_reset_*` → `test_rebalanceUsingAlt_*`)
- Modify: `test/LPAutoBalancerV2.integration.t.sol` (same rename set; `_defaultParams()` helper's return type)
- Modify: `test/LPAutoBalancerV2Setup.integration.t.sol` (if it references `reset(` / `ResetParams`)
- Modify: `test/DeployLPAutoBalancerV2.t.sol` (if it references `reset(` / `ResetParams` / `Reset(`)
- Modify: `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol` (if it references any of the three names)
- Modify: `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md` (prose + any calldata examples referencing `reset`)

- [ ] **Step 1: Enumerate every occurrence (this is the "failing test" for a rename — the list must reach zero)**

Run:
```bash
grep -rn "ResetParams\|\breset(\|event Reset\|emit Reset\|Reset(" src/ test/ multisig/ docs/ script/ --include="*.sol" --include="*.md"
```
Expected: hits in `src/LPAutoBalancerV2.sol`, `test/LPAutoBalancerV2.unit.t.sol`, `test/LPAutoBalancerV2.integration.t.sol`, possibly `test/LPAutoBalancerV2Setup.integration.t.sol`, `test/DeployLPAutoBalancerV2.t.sol`, `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol`, `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md`. Save this list; every hit must be renamed or confirmed unrelated (e.g. `vm.reset` false positives — none expected, but check).

- [ ] **Step 2: Apply the rename in `src/LPAutoBalancerV2.sol`**

Make exactly these text-level changes (`replace_all` where noted):
1. `struct ResetParams {` → `struct RebalanceParams {`
2. `event Reset(uint256 mainTokenId, uint256 altTokenId, int24 tickLower, int24 tickUpper);` → `event RebalancedUsingAlt(uint256 mainTokenId, uint256 altTokenId, int24 tickLower, int24 tickUpper);`
3. `function reset(ResetParams calldata params)` → `function rebalanceUsingAlt(RebalanceParams calldata params)`
4. `emit Reset(newMain, p.altTokenId, tl, tu);` → `emit RebalancedUsingAlt(newMain, p.altTokenId, tl, tu);`
5. Every remaining `ResetParams calldata` in helper signatures (`_mintBalanced`, `_mintAlt`) → `RebalanceParams calldata` (a `replace_all` of `ResetParams` → `RebalanceParams` covers 1, 3, 5 in one pass).
Also update NatSpec comments above the renamed items to say `rebalanceUsingAlt` instead of `reset`.

- [ ] **Step 3: Verify the source compiles**

Run: `forge build`
Expected: compiles clean for `src/`. If `forge build` also builds tests, expect errors ONLY in the test/multisig files listed above, all of the form `Member "reset" not found` / `Identifier not found: ResetParams` — this is the rename cascade, not a new bug.

- [ ] **Step 4: Apply the rename in all test/proposal/doc files**

In each file from the Step 1 list, apply (`replace_all` per file):
- `LPAutoBalancerV2.ResetParams` → `LPAutoBalancerV2.RebalanceParams`
- `ResetParams` → `RebalanceParams`
- `lab.reset(` → `lab.rebalanceUsingAlt(` (and any other receiver, e.g. `balancer.reset(` → `balancer.rebalanceUsingAlt(`)
- `Reset(` in event expectations (`vm.expectEmit` + `emit Reset(`) → `RebalancedUsingAlt(`
- In `test/LPAutoBalancerV2.unit.t.sol`: rename helper `_defaultResetParams` → `_defaultRebalanceParams` (declaration + all call sites), and rename tests `test_reset_...` → `test_rebalanceUsingAlt_...` (e.g. `test_reset_rebuildsMain_fromWithdrawnBalances` → `test_rebalanceUsingAlt_rebuildsMain_fromWithdrawnBalances`).
- In `test/LPAutoBalancerV2.integration.t.sol`: `_defaultParams()`'s return type becomes `LPAutoBalancerV2.RebalanceParams memory`.
- In `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md`: update prose mentions of `reset()` to `rebalanceUsingAlt()` and `ResetParams` to `RebalanceParams`.

- [ ] **Step 5: Verify zero stragglers and green tests**

Run:
```bash
grep -rn "ResetParams\|lab\.reset(\|event Reset(\|emit Reset(" src/ test/ multisig/ docs/ script/ --include="*.sol" --include="*.md"
forge build
forge test --mc LPAutoBalancerV2UnitTest -vv
```
Expected: grep returns nothing; build clean; all unit tests PASS (behavior unchanged, only names).

- [ ] **Step 6: Run the fork + setup suites to confirm the rename cascaded**

Run:
```bash
BASE_RPC_URL=https://mainnet.base.org forge test --ffi --mc LPAutoBalancerV2Integration -vv
make lp-v2-setup
```
Expected: PASS (all existing tests, renamed).

- [ ] **Step 7: Commit**
```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol test/LPAutoBalancerV2.integration.t.sol test/LPAutoBalancerV2Setup.integration.t.sol test/DeployLPAutoBalancerV2.t.sol multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md
git commit -m "refactor(lpv2): rename reset -> rebalanceUsingAlt, ResetParams -> RebalanceParams"
```

---

### Task 2: New balancer state, errors, events + `setSwapLossAllowanceBps`

**Files:**
- Modify: `src/LPAutoBalancerV2.sol` (state block near `compoundModule`, error block, event block, new setter next to `setCompoundModule`)
- Test: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Write the failing tests**

Append to `test/LPAutoBalancerV2.unit.t.sol` (inside `LPAutoBalancerV2UnitTest`):
```solidity
    // ---------- swap-loss allowance setter ----------

    function test_setSwapLossAllowanceBps_adminSets_andEmits() public {
        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancerV2.SwapLossAllowanceUpdated(0, 300);
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(300);
        assertEq(lab.swapLossAllowanceBps(), 300);
    }

    function test_setSwapLossAllowanceBps_revertsAboveCap() public {
        vm.prank(admin);
        vm.expectRevert(LPAutoBalancerV2.SwapLossAllowanceTooHigh.selector);
        lab.setSwapLossAllowanceBps(501);
    }

    function test_setSwapLossAllowanceBps_capValueAllowed() public {
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(500);
        assertEq(lab.swapLossAllowanceBps(), 500);
    }

    function test_setSwapLossAllowanceBps_revertsNonAdmin() public {
        vm.prank(rebalancer);
        vm.expectRevert();
        lab.setSwapLossAllowanceBps(100);
    }

    function test_swapRebalance_stateDefaults() public view {
        assertFalse(lab.rebalanceInFlight());
        assertEq(lab.rebalanceValueBefore(), 0);
        assertEq(lab.rebalanceStartedAt(), 0);
        assertEq(lab.sellTokenInFlight(), address(0));
        assertFalse(lab.rebalanceWasStaked());
        assertEq(lab.swapLossAllowanceBps(), 0);
        assertEq(lab.MAX_SWAP_LOSS_ALLOWANCE_BPS(), 500);
        assertEq(lab.VAULT_RELAYER(), 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --mc LPAutoBalancerV2UnitTest --match-test "setSwapLossAllowanceBps|swapRebalance_stateDefaults" -vv`
Expected: FAIL to compile with `Member "setSwapLossAllowanceBps" not found or not visible` (compile error is the failing state here — the members don't exist yet).

- [ ] **Step 3: Write minimal implementation**

In `src/LPAutoBalancerV2.sol`:

(a) Next to the existing `address public compoundModule;` declaration, add:
```solidity
    /// @notice CowSwap settlement vault relayer (same constant as LPCompoundModule; duplicated to
    ///         avoid an external call from the balancer's hot paths).
    address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    /// @notice Cap on the extra rebalance-loss tolerance granted for the CowSwap round trip.
    uint16 public constant MAX_SWAP_LOSS_ALLOWANCE_BPS = 500;

    /// @notice True between unwindForSwap() and rebuildAfterSwap()/exit(); gates rebalance-order validation.
    bool public rebalanceInFlight;
    /// @notice USD (1e8) value snapshot taken at unwind, used as the rebuild value-floor base.
    uint256 public rebalanceValueBefore;
    /// @notice Timestamp of the last unwindForSwap() (diagnostics + snapshot field).
    uint256 public rebalanceStartedAt;
    /// @notice Token approved to VAULT_RELAYER during the in-flight window (revoked at rebuild/exit).
    address public sellTokenInFlight;
    /// @notice Whether the main position was staked at unwind time (restake at rebuild).
    bool public rebalanceWasStaked;
    /// @notice Extra floor tolerance (bps) added to maxRebalanceLossBps for the swap round trip.
    uint16 public swapLossAllowanceBps;
```

(b) In the error block (after `error ModuleNotSet();`), add:
```solidity
    error NotInFlight();
    error AlreadyInFlight();
    error InvalidSellToken();
    error SwapLossAllowanceTooHigh();
```

(c) In the event block (after `event RebalancedUsingAlt(...)`), add:
```solidity
    event RebalanceUnwound(address sellToken, uint256 sellAmount);
    event RebalanceRebuilt(uint256 mainTokenId, uint256 altTokenId);
    event SwapLossAllowanceUpdated(uint256 oldBps, uint256 newBps);
```

(d) Next to `setCompoundModule`, add:
```solidity
    /// @notice Sets the extra value-floor tolerance for swap rebalances. Admin only, capped.
    function setSwapLossAllowanceBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_SWAP_LOSS_ALLOWANCE_BPS) revert SwapLossAllowanceTooHigh();
        emit SwapLossAllowanceUpdated(swapLossAllowanceBps, newBps);
        swapLossAllowanceBps = newBps;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vv`
Expected: PASS (new tests plus the whole existing suite).

- [ ] **Step 5: Commit**
```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): swap-rebalance state, errors, events, setSwapLossAllowanceBps"
```

---

### Task 3: Add `rebalanceInFlight` + `rebalanceStartedAt` to `getDecisionSnapshot()`

**Files:**
- Modify: `src/LPAutoBalancerV2.sol` (`DecisionSnapshotV2` struct + `getDecisionSnapshot()` body)
- Test: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Write the failing test**

Append to `test/LPAutoBalancerV2.unit.t.sol`:
```solidity
    function test_getDecisionSnapshot_includesInFlightFields() public {
        _register(false);

        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertFalse(s.rebalanceInFlight, "not in flight by default");
        assertEq(s.rebalanceStartedAt, 0, "no unwind yet");
    }
```
(The in-flight=true side is asserted in Task 4's unwind happy-path test, once `unwindForSwap` exists to flip the flag.)

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --mc LPAutoBalancerV2UnitTest --match-test test_getDecisionSnapshot_includesInFlightFields -vv`
Expected: FAIL to compile with `Member "rebalanceInFlight" not found ... struct LPAutoBalancerV2.DecisionSnapshotV2`.

- [ ] **Step 3: Write minimal implementation**

In `src/LPAutoBalancerV2.sol`, extend the struct — add two fields at the END of `DecisionSnapshotV2` (after `bool deviationGateOpen;`):
```solidity
        bool rebalanceInFlight;
        uint256 rebalanceStartedAt;
```
And at the end of `getDecisionSnapshot()` (after the `s.deviationGateOpen = ...` line):
```solidity
        s.rebalanceInFlight = rebalanceInFlight;
        s.rebalanceStartedAt = rebalanceStartedAt;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vv`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): expose rebalanceInFlight/rebalanceStartedAt in decision snapshot"
```

---

### Task 4: Implement `unwindForSwap`

**Files:**
- Modify: `src/LPAutoBalancerV2.sol` (new `UnwindParams` struct next to `RebalanceParams`; new function right before `rebalanceUsingAlt()`)
- Test: `test/LPAutoBalancerV2.unit.t.sol`

**Existing test-file facts used below (verified against the current file, not guessed):**
- The pool mock's spot-tick setter is `mockPool.setSlot0(uint160 sqrtP, int24 tick)`, NOT `setSpotTick`. The suite's TWAP-deviation tests call it as e.g. `mockPool.setSlot0(SQRT_P, 5000); // far from twap 0 => |dev| > maxTickDeviation` — `SQRT_P` is the existing constant `79_228_162_514_264_337_593_543_950_336` (sqrt price at tick 0); TWAP stays at 0 because `setObserve(0, 0)` in `setUp()` is untouched.
- `_register(bool withGauge)` only calls `registerPosition` — it does **not** stake. A "was staked" test must explicitly call `vm.prank(rebalancer); lab.stake();` after `_register(true)`.
- The default config from `_register(...)`/`_defaultConfig` sets `minRebalanceInterval: 0` ("no cooldown so reset() can run immediately") — a cooldown test needs the existing `_registerWithInterval(uint256 interval)` helper (already defined in the file, registers `TOKEN_ID` with `gauge: address(0)`, `minRebalanceInterval: interval`), not `_register`.
- There is no existing pause test in this file to copy; `Pausable` is not yet imported in the test file. Add the import in Step 1.
- Bare `vm.expectRevert();` (no selector) is the file's established pattern for "caller lacks the required role" (see existing `onlyRole` revert tests).

- [ ] **Step 1: Write the failing tests**

Add the import at the top of `test/LPAutoBalancerV2.unit.t.sol` (with the other imports):
```solidity
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
```

Add fixtures + append tests to the test contract:
```solidity
    // ---------- swap-rebalance fixtures ----------

    LPCompoundModule realModule;

    function _setRealModule() internal {
        realModule = new LPCompoundModule(address(lab), address(mockAero), admin);
        vm.prank(admin);
        lab.setCompoundModule(address(realModule));
    }

    function _defaultUnwindParams() internal view returns (LPAutoBalancerV2.UnwindParams memory) {
        return LPAutoBalancerV2.UnwindParams({
            sellToken: token0,
            sellAmount: 5e17,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
            amount0MinWithdrawAlt: 0,
            amount1MinWithdrawAlt: 0,
            deadline: block.timestamp + 1
        });
    }

    // ---------- unwindForSwap ----------

    function test_unwindForSwap_happyPath_teardownApprovalFlagSnapshot() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancerV2.RebalanceUnwound(token0, 5e17);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        // teardown happened: old NFT burned, principal loose on the balancer
        assertEq(mockPM.burnCallCount(), 1);
        assertEq(mockPM.lastBurnedTokenId(), TOKEN_ID);
        assertEq(tok0.balanceOf(address(lab)), 1e18);
        assertEq(tok1.balanceOf(address(lab)), 1e18);

        // no mint in phase 1
        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,,) = lab.position();
        assertEq(mainTokenId, TOKEN_ID, "mainTokenId untouched until rebuild");

        // approval + in-flight state
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 5e17);
        assertTrue(lab.rebalanceInFlight());
        assertEq(lab.sellTokenInFlight(), token0);
        assertEq(lab.rebalanceStartedAt(), block.timestamp);
        assertGt(lab.rebalanceValueBefore(), 0, "snapshot captured");
        assertFalse(lab.rebalanceWasStaked());

        // snapshot view reflects in-flight
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = lab.getDecisionSnapshot();
        assertTrue(s.rebalanceInFlight);
        assertEq(s.rebalanceStartedAt, block.timestamp);
    }

    function test_unwindForSwap_recordsWasStaked() public {
        _register(true); // gauge configured; _register does NOT stake, so stake explicitly:
        vm.prank(rebalancer);
        lab.stake();
        _setRealModule();
        _stagePrincipal(1e18, 1e18);

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());
        assertTrue(lab.rebalanceWasStaked());
    }

    function test_unwindForSwap_revertsNotActive() public {
        _setRealModule();
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotActive.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsAlreadyInFlight() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.AlreadyInFlight.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsOnCooldown() public {
        _registerWithInterval(3600); // default config's minRebalanceInterval is 0 (no gate); use a real interval
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        // do a normal rebalance to stamp lastRebalance
        vm.prank(rebalancer);
        lab.rebalanceUsingAlt(_defaultRebalanceParams());

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.Cooldown.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsOnTwapDeviation() public {
        _register(false);
        _setRealModule();
        // push spot far from twap=0 using the pool mock's real setter (setSlot0), matching the
        // existing TWAP-deviation test convention in this file.
        mockPool.setSlot0(SQRT_P, 5000);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TwapDeviation.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsBadSellToken() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.UnwindParams memory u = _defaultUnwindParams();
        u.sellToken = address(mockAero);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidSellToken.selector);
        lab.unwindForSwap(u);
    }

    function test_unwindForSwap_revertsZeroSellAmount() public {
        _register(false);
        _setRealModule();
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancerV2.UnwindParams memory u = _defaultUnwindParams();
        u.sellAmount = 0;

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.InvalidSellToken.selector);
        lab.unwindForSwap(u);
    }

    function test_unwindForSwap_revertsModuleNotSet() public {
        _register(false); // no module set
        _stagePrincipal(1e18, 1e18);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ModuleNotSet.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsWhenPaused() public {
        _register(false);
        _setRealModule();
        vm.prank(guardian);
        lab.pause();

        vm.prank(rebalancer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_unwindForSwap_revertsNonRebalancer() public {
        _register(false);
        _setRealModule();
        vm.prank(manager);
        vm.expectRevert();
        lab.unwindForSwap(_defaultUnwindParams());
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --mc LPAutoBalancerV2UnitTest --match-test unwindForSwap -vv`
Expected: FAIL to compile with `Member "unwindForSwap" not found` / `Identifier not found: UnwindParams`.

- [ ] **Step 3: Write minimal implementation**

In `src/LPAutoBalancerV2.sol`, next to `RebalanceParams` add:
```solidity
    /// @notice Parameters for phase 1 of a swap rebalance.
    struct UnwindParams {
        address sellToken; // token0 or token1 — the excess leg (backend-computed)
        uint256 sellAmount; // approve exactly this to VAULT_RELAYER
        uint256 amount0MinWithdraw; // sandwich floors for the teardown (main)
        uint256 amount1MinWithdraw;
        uint256 amount0MinWithdrawAlt; // (alt)
        uint256 amount1MinWithdrawAlt;
        uint256 deadline;
    }
```
Immediately before `rebalanceUsingAlt()` add:
```solidity
    /// @notice Phase 1 of a swap rebalance: tears down both positions, snapshots value,
    ///         approves the CowSwap vault relayer for exactly `sellAmount`, and opens the
    ///         order-validation window. No mint happens here; `rebuildAfterSwap` completes the cycle.
    function unwindForSwap(UnwindParams calldata params)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        ManagedPositionV2 storage p = position;
        if (!p.active) revert NotActive();
        if (rebalanceInFlight) revert AlreadyInFlight();
        if (block.timestamp < p.lastRebalance + p.minRebalanceInterval) revert Cooldown();
        if (compoundModule == address(0)) revert ModuleNotSet();
        if (params.sellToken != p.token0 && params.sellToken != p.token1) revert InvalidSellToken();
        if (params.sellAmount == 0) revert InvalidSellToken();

        (uint160 sqrtP, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
        int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
        _checkDeviation(spotTick, twapTick, p.maxTickDeviation);

        uint8 dec0 = IERC20Metadata(p.token0).decimals();
        uint8 dec1 = IERC20Metadata(p.token1).decimals();

        rebalanceValueBefore = _principalValue(p, p.mainTokenId, sqrtP, dec0, dec1) + _altValue(p, sqrtP, dec0, dec1)
            + _contractPairValue(p, dec0, dec1);
        rebalanceStartedAt = block.timestamp;
        rebalanceWasStaked = p.mainStaked;
        sellTokenInFlight = params.sellToken;

        _exitAll(
            p,
            params.amount0MinWithdraw,
            params.amount1MinWithdraw,
            params.amount0MinWithdrawAlt,
            params.amount1MinWithdrawAlt,
            params.deadline
        );

        IERC20(params.sellToken).forceApprove(VAULT_RELAYER, params.sellAmount);
        rebalanceInFlight = true;

        emit RebalanceUnwound(params.sellToken, params.sellAmount);
    }
```
Note `forceApprove` comes from the already-present `using SafeERC20 for IERC20;`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vv`
Expected: PASS (all new + all existing).

- [ ] **Step 5: Commit**
```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): unwindForSwap — phase 1 of CowSwap principal rebalance"
```

---

### Task 5: Implement `rebuildAfterSwap`

**Files:**
- Modify: `src/LPAutoBalancerV2.sol` (new function right after `unwindForSwap`)
- Test: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Write the failing tests**

Append to `test/LPAutoBalancerV2.unit.t.sol`:
```solidity
    // ---------- rebuildAfterSwap ----------

    function _unwind() internal {
        _stagePrincipal(1e18, 1e18);
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams());
    }

    function test_rebuildAfterSwap_happyPath_afterSimulatedSettlement() public {
        _register(false);
        _setRealModule();
        _unwind();

        // simulate CowSwap settlement: relayer pulls 5e17 tok0, delivers tok1
        vm.prank(address(lab));
        tok0.transfer(makeAddr("solver"), 5e17);
        tok1.mint(address(lab), 5e17);

        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancerV2.RebalanceRebuilt(NEW_TOKEN_ID, 0);
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebalanceParams());

        (uint256 mainTokenId, uint256 altTokenId,,,,,,,,,,,,,,,,,, uint256 lastRebalance, bool active) =
            lab.position();
        assertEq(mainTokenId, NEW_TOKEN_ID, "new main minted");
        assertEq(altTokenId, 0, "balanced inputs leave no alt");
        assertTrue(active);
        assertEq(lastRebalance, block.timestamp, "cooldown stamped at rebuild");

        // in-flight state fully cleared + approval revoked
        assertFalse(lab.rebalanceInFlight());
        assertEq(lab.rebalanceValueBefore(), 0);
        assertEq(lab.sellTokenInFlight(), address(0));
        assertFalse(lab.rebalanceWasStaked());
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "relayer approval revoked");
    }

    function test_rebuildAfterSwap_unfilledOrder_matchesNoSwapOutcome() public {
        _register(false);
        _setRealModule();
        _unwind();
        // order expired unfilled: balances unchanged (1e18 / 1e18 loose)

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebalanceParams());

        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,,) = lab.position();
        assertEq(mainTokenId, NEW_TOKEN_ID, "rebuilt from original balances, identical to rebalanceUsingAlt outcome");
        assertFalse(lab.rebalanceInFlight());
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "stale approval revoked");
    }

    function test_rebuildAfterSwap_restakesWhenWasStaked() public {
        _register(true);
        vm.prank(rebalancer);
        lab.stake(); // _register does NOT stake — stake explicitly, matching Task 4's convention
        _setRealModule();
        _unwind();
        assertTrue(lab.rebalanceWasStaked());

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebalanceParams());

        (,,,,,,, bool mainStaked,,,,,,,,,,,,,) = lab.position();
        assertTrue(mainStaked, "restaked after rebuild");
        assertFalse(lab.rebalanceWasStaked(), "flag cleared");
    }

    function test_rebuildAfterSwap_revertsNotInFlight() public {
        _register(false);
        _setRealModule();
        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.NotInFlight.selector);
        lab.rebuildAfterSwap(_defaultRebalanceParams());
    }

    function test_rebuildAfterSwap_revertsOnValueFloorBreach() public {
        _register(false);
        _setRealModule();
        _unwind();

        // simulate a catastrophic fill: half the tok0 leaves, nothing comes back
        vm.prank(address(lab));
        tok0.transfer(makeAddr("solver"), 5e17);

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.ValueFloor.selector);
        lab.rebuildAfterSwap(_defaultRebalanceParams());
        assertTrue(lab.rebalanceInFlight(), "still in flight; can retry or exit");
    }

    function test_rebuildAfterSwap_lossWithinAllowancePasses() public {
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(500); // default maxRebalanceLossBps is 100 (1%); +500 = 6% tolerance
        _register(false);
        _setRealModule();
        _unwind();

        // small loss: 2% of tok0 gone — within maxRebalanceLossBps(1%) + allowance(5%) = 6%
        vm.prank(address(lab));
        tok0.transfer(makeAddr("solver"), 2e16);

        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebalanceParams());
        assertFalse(lab.rebalanceInFlight());
    }

    function test_rebuildAfterSwap_revertsOnTwapDeviation() public {
        _register(false);
        _setRealModule();
        _unwind();
        mockPool.setSlot0(SQRT_P, 5000); // same setter/convention as the unwindForSwap TWAP test

        vm.prank(rebalancer);
        vm.expectRevert(LPAutoBalancerV2.TwapDeviation.selector);
        lab.rebuildAfterSwap(_defaultRebalanceParams());
    }

    function test_rebuildAfterSwap_noCooldownGate() public {
        _register(false);
        _setRealModule();
        _unwind();
        // do NOT warp past minRebalanceInterval — rebuild must still work
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultRebalanceParams());
        assertFalse(lab.rebalanceInFlight());
    }

    function test_rebuildAfterSwap_revertsWhenPaused() public {
        _register(false);
        _setRealModule();
        _unwind();
        vm.prank(guardian);
        lab.pause();

        vm.prank(rebalancer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lab.rebuildAfterSwap(_defaultRebalanceParams());
    }

    function test_rebuildAfterSwap_revertsNonRebalancer() public {
        _register(false);
        _setRealModule();
        _unwind();
        vm.prank(manager);
        vm.expectRevert();
        lab.rebuildAfterSwap(_defaultRebalanceParams());
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --mc LPAutoBalancerV2UnitTest --match-test rebuildAfterSwap -vv`
Expected: FAIL to compile with `Member "rebuildAfterSwap" not found`.

- [ ] **Step 3: Write minimal implementation**

In `src/LPAutoBalancerV2.sol`, right after `unwindForSwap` add:
```solidity
    /// @notice Phase 2 of a swap rebalance: revokes the relayer approval, re-mints main (+alt)
    ///         from whatever the contract currently holds, enforces the value floor against the
    ///         unwind snapshot (with swapLossAllowanceBps extra tolerance), restakes if the
    ///         position was staked before, and closes the in-flight window.
    /// @dev    Deliberately NOT gated on cooldown or on CowSwap order state: filled, expired,
    ///         or never-placed orders all rebuild from current balances. IS gated on pause and
    ///         the calm gate; `exit()` remains the escape hatch if either blocks.
    function rebuildAfterSwap(RebalanceParams calldata params)
        external
        onlyRole(REBALANCER_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (!rebalanceInFlight) revert NotInFlight();
        ManagedPositionV2 storage p = position;

        IERC20(sellTokenInFlight).forceApprove(VAULT_RELAYER, 0);

        (uint160 sqrtP, int24 spotTick,,,,) = ICLPool(p.pool).slot0();
        int24 twapTick = _consultTwapTick(p.pool, p.twapWindow);
        _checkDeviation(spotTick, twapTick, p.maxTickDeviation);

        uint8 dec0 = IERC20Metadata(p.token0).decimals();
        uint8 dec1 = IERC20Metadata(p.token1).decimals();

        if (params.width < p.minWidth || params.width > p.maxWidth) revert WidthOutOfBounds();

        (int24 tl, int24 tu) = _mainRange(p, spotTick, params.width, dec0, dec1);

        uint256 newMain = _mintBalanced(p, tl, tu, params);
        p.mainTokenId = newMain;
        p.altStaked = false;
        p.mainStaked = false;
        p.lastRebalance = block.timestamp;

        p.altTokenId = _mintAlt(p, tl, tu, dec0, dec1, params);

        uint256 valueAfter = _principalValue(p, p.mainTokenId, sqrtP, dec0, dec1) + _altValue(p, sqrtP, dec0, dec1)
            + _contractPairValue(p, dec0, dec1);
        if (
            valueAfter
                < FullMath.mulDiv(
                    rebalanceValueBefore,
                    BPS_DENOMINATOR - p.maxRebalanceLossBps - swapLossAllowanceBps,
                    BPS_DENOMINATOR
                )
        ) {
            revert ValueFloor();
        }

        bool wasStaked = rebalanceWasStaked;
        rebalanceInFlight = false;
        rebalanceValueBefore = 0;
        sellTokenInFlight = address(0);
        rebalanceWasStaked = false;

        _forwardDust(p);

        if (wasStaked && p.gauge != address(0)) {
            POSITION_MANAGER.approve(p.gauge, newMain);
            ICLGauge(p.gauge).deposit(newMain);
            p.mainStaked = true;
            emit Staked(newMain, p.gauge);
            if (p.altTokenId != 0) {
                POSITION_MANAGER.approve(p.gauge, p.altTokenId);
                ICLGauge(p.gauge).deposit(p.altTokenId);
                p.altStaked = true;
                emit Staked(p.altTokenId, p.gauge);
            }
        }

        emit RebalanceRebuilt(newMain, p.altTokenId);
    }
```
Note the `ValueFloor` revert happens BEFORE the in-flight state is cleared, so on a floor breach the whole call (including mints) reverts and the window stays open for retry or `exit()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vv`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): rebuildAfterSwap — phase 2 of CowSwap principal rebalance"
```

---

### Task 6: `validateRebalanceOrder` on the module + `isValidSignature` passthrough on the balancer

**Files:**
- Modify: `src/interfaces/ILPAutoBalancerV2.sol` (add `rebalanceInFlight()`)
- Modify: `src/LPCompoundModule.sol` (add `validateRebalanceOrder`; do NOT touch the existing `isValidSignature`)
- Modify: `src/LPAutoBalancerV2.sol` (minimal local interface + `isValidSignature` passthrough)
- Test: `test/LPCompoundModule.unit.t.sol`, `test/LPAutoBalancerV2.unit.t.sol`

**Existing fixture names in `test/LPCompoundModule.unit.t.sol` (verified — use these exact names, not invented ones):** `bal` (the `StubBalancer` instance, with `token0`/`token1` public state vars and a `setTokens` setter — needs a new `setInFlight` setter for this task), `spc` (the `MockSlippagePriceChecker` instance), `module` (the `LPCompoundModule` instance), `aero`/`token0`/`token1` (raw addresses), `appData` (the file's `bytes32 appData = keccak256("mamo-lpv2-compound");` constant, already wired via `module.setCompoundAppData(appData)` in `setUp()`), and the existing helper `_sig(GPv2Order.Data memory o) internal view returns (bytes32 digest, bytes memory enc)` which hashes via `o.hash(module.DOMAIN_SEPARATOR())` and ABI-encodes the order — reuse it instead of re-deriving digests inline.

- [ ] **Step 1: Write the failing module tests**

In `test/LPCompoundModule.unit.t.sol`, extend the existing `StubBalancer` contract with a settable in-flight flag:
```solidity
    // add inside the existing StubBalancer contract:
    bool public rebalanceInFlight;

    function setInFlight(bool v) external {
        rebalanceInFlight = v;
    }
```
Then append tests to `LPCompoundModuleUnitTest` (reusing `bal`, `spc`, `module`, `_order`, `_sig`, `appData` exactly as they exist in the file):
```solidity
    // ---------- validateRebalanceOrder ----------

    function _rebalanceOrder(address sell, address buy) internal view returns (GPv2Order.Data memory) {
        return _order(sell, buy, address(bal), uint32(block.timestamp + 10 minutes));
    }

    function test_validateRebalanceOrder_validBothDirections_whileInFlight() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);

        GPv2Order.Data memory o01 = _rebalanceOrder(token0, token1);
        (bytes32 d01, bytes memory e01) = _sig(o01);
        assertEq(module.validateRebalanceOrder(d01, e01), bytes4(0x1626ba7e));

        GPv2Order.Data memory o10 = _rebalanceOrder(token1, token0);
        (bytes32 d10, bytes memory e10) = _sig(o10);
        assertEq(module.validateRebalanceOrder(d10, e10), bytes4(0x1626ba7e));
    }

    function test_validateRebalanceOrder_revertsOutsideWindow() public {
        // bal.rebalanceInFlight defaults false — do not call setInFlight
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("no rebalance in flight");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsSameToken() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token0);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("tokens must be distinct underlying");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsAeroAsLeg() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(aero, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(aero, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("tokens must be distinct underlying");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsWrongReceiver() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _order(token0, token1, makeAddr("attacker"), uint32(block.timestamp + 10 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("receiver must be balancer");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBadPrice() public {
        bal.setInFlight(true);
        spc.setPriceOk(false);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("price check failed");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsExpiresTooSoon() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o =
            _order(token0, token1, address(bal), uint32(block.timestamp + 1 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("expires too soon");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsExpiresTooFar() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 6 minutes);
        GPv2Order.Data memory o =
            _order(token0, token1, address(bal), uint32(block.timestamp + 30 minutes));
        (bytes32 d, bytes memory e) = _sig(o);
        vm.expectRevert("expires too far");
        module.validateRebalanceOrder(d, e);
    }

    function test_validateRebalanceOrder_revertsBadDigest() public {
        bal.setInFlight(true);
        spc.setMaxTimePriceValid(token0, 1 hours);
        GPv2Order.Data memory o = _rebalanceOrder(token0, token1);
        (, bytes memory e) = _sig(o);
        vm.expectRevert("bad digest");
        module.validateRebalanceOrder(bytes32(uint256(1)), e);
    }
```
Note: `MockSlippagePriceChecker.setMaxTimePriceValid(address, uint256)` ignores its first argument and sets one shared `maxValid` value internally — calling it once per test with either token address is equivalent; keep the calls above for readability/documentation of intent.

- [ ] **Step 2: Write the failing balancer passthrough test**

Append to `test/LPAutoBalancerV2.unit.t.sol`:
```solidity
    function test_isValidSignature_delegatesToModule() public {
        _register(false);
        // mock module: any (bytes32, bytes) call to validateRebalanceOrder returns the magic value
        address mockModule = makeAddr("mockModule");
        vm.prank(admin);
        lab.setCompoundModule(mockModule);
        vm.mockCall(
            mockModule,
            abi.encodeWithSignature("validateRebalanceOrder(bytes32,bytes)"),
            abi.encode(bytes4(0x1626ba7e))
        );

        bytes4 v = lab.isValidSignature(bytes32(uint256(123)), hex"deadbeef");
        assertEq(v, bytes4(0x1626ba7e));
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
forge test --mc LPCompoundModuleUnitTest --match-test validateRebalanceOrder -vv
forge test --mc LPAutoBalancerV2UnitTest --match-test isValidSignature -vv
```
Expected: FAIL to compile — `Member "validateRebalanceOrder" not found` on the module, `Member "isValidSignature" not found` on the balancer, `Member "setInFlight" not found` on `StubBalancer` (apply the `StubBalancer` edit together with the tests in Step 1, not separately).

- [ ] **Step 4: Write minimal implementation**

(a) `src/interfaces/ILPAutoBalancerV2.sol` — full new content:
```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal balancer surface the compound module reads live (survives setPool).
interface ILPAutoBalancerV2 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function rebalanceInFlight() external view returns (bool);
}
```

(b) `src/LPCompoundModule.sol` — append after the existing `isValidSignature` function (do not modify it):
```solidity
    /// @notice EIP-1271 validation for principal-rebalance orders. The balancer's
    ///         isValidSignature delegates here. Orders validate ONLY while the balancer
    ///         reports rebalanceInFlight, must swap between the two pool underlyings
    ///         (either direction), deliver to the balancer, and pass the price checker.
    function validateRebalanceOrder(bytes32 orderDigest, bytes calldata encodedOrder)
        external
        view
        returns (bytes4)
    {
        require(ILPAutoBalancerV2(balancer).rebalanceInFlight(), "no rebalance in flight");
        GPv2Order.Data memory o = abi.decode(encodedOrder, (GPv2Order.Data));
        require(o.hash(DOMAIN_SEPARATOR) == orderDigest, "bad digest");
        require(o.kind == GPv2Order.KIND_SELL, "must be sell");
        require(!o.partiallyFillable, "must be fill-or-kill");
        require(o.sellTokenBalance == GPv2Order.BALANCE_ERC20, "sell must be erc20");
        require(o.buyTokenBalance == GPv2Order.BALANCE_ERC20, "buy must be erc20");
        address t0 = ILPAutoBalancerV2(balancer).token0();
        address t1 = ILPAutoBalancerV2(balancer).token1();
        require(
            (address(o.sellToken) == t0 || address(o.sellToken) == t1)
                && (address(o.buyToken) == t0 || address(o.buyToken) == t1)
                && address(o.sellToken) != address(o.buyToken),
            "tokens must be distinct underlying"
        );
        require(o.receiver == balancer, "receiver must be balancer");
        require(o.feeAmount == 0, "fee must be zero");
        require(o.appData == compoundAppData, "bad appData");
        require(o.validTo >= block.timestamp + 5 minutes, "expires too soon");
        require(
            o.validTo <= block.timestamp + slippagePriceChecker.maxTimePriceValid(address(o.sellToken)),
            "expires too far"
        );
        require(
            slippagePriceChecker.checkPrice(
                o.sellAmount, address(o.sellToken), address(o.buyToken), o.buyAmount, allowedSlippageInBps
            ),
            "price check failed"
        );
        return MAGIC_VALUE;
    }
```

(c) `src/LPAutoBalancerV2.sol` — add a minimal local interface (do NOT import `LPCompoundModule`, which would drag in `GPv2Order`/`ISlippagePriceChecker` the balancer doesn't need). Place it above the contract declaration, after the imports:
```solidity
/// @dev Minimal view surface of LPCompoundModule needed for the EIP-1271 passthrough.
interface ILPCompoundModuleRebalance {
    function validateRebalanceOrder(bytes32 orderDigest, bytes calldata encodedOrder)
        external
        view
        returns (bytes4);
}
```
And add the passthrough function (near `getDecisionSnapshot`):
```solidity
    /// @notice EIP-1271 passthrough. The balancer is the CowSwap order owner (tokens pulled
    ///         from / delivered to it); all validation logic lives on the compound module.
    function isValidSignature(bytes32 digest, bytes calldata order) external view returns (bytes4) {
        return ILPCompoundModuleRebalance(compoundModule).validateRebalanceOrder(digest, order);
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
forge test --mc LPCompoundModuleUnitTest -vv
forge test --mc LPAutoBalancerV2UnitTest -vv
```
Expected: PASS (all new + all existing, including the untouched AERO-compound `isValidSignature` module tests).

- [ ] **Step 6: Commit**
```bash
git add src/interfaces/ILPAutoBalancerV2.sol src/LPCompoundModule.sol src/LPAutoBalancerV2.sol test/LPCompoundModule.unit.t.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): rebalance-order EIP-1271 — module validateRebalanceOrder + balancer passthrough"
```

---

### Task 7: `exit()` clears in-flight state

**Files:**
- Modify: `src/LPAutoBalancerV2.sol` (`exit()` — insert cleanup near the top, before existing logic)
- Test: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Write the failing test**

Append to `test/LPAutoBalancerV2.unit.t.sol`:
```solidity
    function test_exit_midFlight_clearsStateAndRevokesApproval() public {
        _register(false);
        _setRealModule();
        _unwind(); // helper from Task 5: stages 1e18/1e18 principal and calls unwindForSwap

        assertTrue(lab.rebalanceInFlight());
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 5e17);

        address to = makeAddr("exitRecipient");
        vm.prank(admin);
        lab.exit(to);

        assertFalse(lab.rebalanceInFlight(), "flag cleared");
        assertEq(lab.rebalanceValueBefore(), 0, "snapshot zeroed");
        assertEq(lab.sellTokenInFlight(), address(0), "sell token cleared");
        assertFalse(lab.rebalanceWasStaked(), "staked flag cleared");
        assertEq(tok0.allowance(address(lab), lab.VAULT_RELAYER()), 0, "relayer approval revoked");

        // funds swept to recipient as before
        assertEq(tok0.balanceOf(to), 1e18);
        assertEq(tok1.balanceOf(to), 1e18);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --mc LPAutoBalancerV2UnitTest --match-test test_exit_midFlight_clearsStateAndRevokesApproval -vv`
Expected: FAIL on the assertion `flag cleared` (`exit` compiles and runs but does not touch `rebalanceInFlight` yet).

- [ ] **Step 3: Write minimal implementation**

In `src/LPAutoBalancerV2.sol`, in `exit(address to)`, insert immediately after `if (to == address(0)) revert ZeroAddress();` and before `p.active = false;`:
```solidity
        if (sellTokenInFlight != address(0)) {
            IERC20(sellTokenInFlight).forceApprove(VAULT_RELAYER, 0);
            sellTokenInFlight = address(0);
        }
        rebalanceInFlight = false;
        rebalanceValueBefore = 0;
        rebalanceWasStaked = false;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vv`
Expected: PASS (including all pre-existing `exit` tests — the cleanup is a no-op when not in flight).

- [ ] **Step 5: Commit**
```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): exit() clears in-flight swap-rebalance state"
```

---

### Task 8: Fork test — full two-phase cycle on real Base WETH/cbBTC

**Files:**
- Test: `test/LPAutoBalancerV2.integration.t.sol`

- [ ] **Step 1: Write the failing fork tests**

Append inside `LPAutoBalancerV2Integration`, using its existing fixtures (`_bootstrap`, `_defaultParams()`, real `WETH`/`CBBTC`/`AERO` constants, `lab`, `admin`, `rebalancer`):
```solidity
    function _defaultUnwindParams(address sellToken, uint256 sellAmount)
        internal
        view
        returns (LPAutoBalancerV2.UnwindParams memory)
    {
        return LPAutoBalancerV2.UnwindParams({
            sellToken: sellToken,
            sellAmount: sellAmount,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
            amount0MinWithdrawAlt: 0,
            amount1MinWithdrawAlt: 0,
            deadline: block.timestamp + 300
        });
    }

    function _ensureModule() internal returns (LPCompoundModule m) {
        if (lab.compoundModule() != address(0)) {
            return LPCompoundModule(lab.compoundModule());
        }
        m = new LPCompoundModule(address(lab), AERO, admin);
        vm.prank(admin);
        lab.setCompoundModule(address(m));
    }

    function test_fork_swapRebalance_fullTwoPhaseCycle() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        uint256 tokenId = _bootstrap(center - 200, center + 200, 1 ether, 0.03e8);
        _ensureModule();
        vm.prank(admin);
        lab.setSwapLossAllowanceBps(300); // headroom for the simulated fill's real-world slippage

        // ---- phase 1: unwind, selling 0.2 WETH ----
        uint256 sellAmount = 0.2 ether;
        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams(WETH, sellAmount));

        assertTrue(lab.rebalanceInFlight());
        assertEq(lab.sellTokenInFlight(), WETH);
        assertEq(IERC20(WETH).allowance(address(lab), lab.VAULT_RELAYER()), sellAmount);
        assertGt(lab.rebalanceValueBefore(), 0);
        assertGt(IERC20(WETH).balanceOf(address(lab)), 0, "principal loose on balancer");

        // ---- simulate CowSwap settlement: relayer pulls WETH, solver delivers cbBTC ----
        vm.prank(address(lab));
        IERC20(WETH).transfer(makeAddr("cowSolver"), sellAmount);
        deal(CBBTC, address(lab), IERC20(CBBTC).balanceOf(address(lab)) + 0.006e8);

        // ---- phase 2: rebuild ----
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultParams());

        (uint256 mainTokenId,,,,,,, bool mainStaked,,,,,,,,,,,,,) = lab.position();
        assertTrue(mainTokenId != 0 && mainTokenId != tokenId, "new main minted");
        assertFalse(lab.rebalanceInFlight(), "window closed");
        assertEq(lab.sellTokenInFlight(), address(0));
        assertEq(lab.rebalanceValueBefore(), 0);
        assertEq(IERC20(WETH).allowance(address(lab), lab.VAULT_RELAYER()), 0, "approval revoked");
        assertTrue(mainStaked, "restaked (bootstrap stakes)");
    }

    function test_fork_swapRebalance_unfilledOrder_rebuildStillWorks() public {
        (, int24 spotTick,,,,) = ICLPool(POOL).slot0();
        int24 center = _align(spotTick);
        _bootstrap(center - 200, center + 200, 1 ether, 0.03e8);
        _ensureModule();

        vm.prank(rebalancer);
        lab.unwindForSwap(_defaultUnwindParams(WETH, 0.2 ether));

        // order expires unfilled: NO balance changes at all. Rebuild immediately.
        vm.prank(rebalancer);
        lab.rebuildAfterSwap(_defaultParams());

        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,,) = lab.position();
        assertTrue(mainTokenId != 0, "rebuilt from original balances — identical outcome to rebalanceUsingAlt");
        assertFalse(lab.rebalanceInFlight());
        assertEq(IERC20(WETH).allowance(address(lab), lab.VAULT_RELAYER()), 0, "stale approval revoked");
    }
```
Add the import at the top of the integration test file if not present:
```solidity
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
```
`_align` and `_bootstrap` are the file's existing helpers (`_align(int24 tick)` floor-aligns to `TICK_SPACING`; `_bootstrap(tl, tu, amt0, amt1)` mints+registers+stakes+skips 2h). The `position()` destructure has 21 fields — `mainStaked` is field index 7 (0-based), matching the comma count shown above; verify against the struct order in `src/LPAutoBalancerV2.sol` before running if unsure.

- [ ] **Step 2: Run tests to verify they fail**

Run: `BASE_RPC_URL=https://mainnet.base.org forge test --ffi --mc LPAutoBalancerV2Integration --match-test fork_swapRebalance -vv`
Expected: with Tasks 2-7 already merged these should mostly pass on the first real try — the TDD "fail" here is catching real-pool integration issues (`ValueFloor` from an unfair simulated fill, wrong destructure offsets). Iterate on the TEST staging (the `deal`ed cbBTC amount, the `swapLossAllowanceBps` value) until green; do not weaken the contract to make a test pass.

- [ ] **Step 3: No new implementation expected**

This task is integration verification of Tasks 4-7 against the real pool. Only touch `src/` if the fork test exposes a genuine contract bug — if it does, fix it with a matching unit test first, then re-run.

- [ ] **Step 4: Run the full fork suite to verify everything passes**

Run: `BASE_RPC_URL=https://mainnet.base.org forge test --ffi --mc LPAutoBalancerV2Integration -vv`
Expected: PASS — all pre-existing fork tests plus the two new ones.

- [ ] **Step 5: Commit**
```bash
git add test/LPAutoBalancerV2.integration.t.sol
git commit -m "test(lpv2): fork tests for two-phase swap rebalance on Base WETH/cbBTC"
```

---

### Task 9: Size check, 011 proposal wiring, runbook update, full-suite run

**Files:**
- Modify: `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol`
- Modify: `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md`
- (Conditional fallback only) Modify: `src/LPAutoBalancerV2.sol` + `src/libraries/LPBalancerLib.sol`

- [ ] **Step 1: EIP-170 size check**

Run: `forge build --sizes 2>/dev/null | grep -E "LPAutoBalancerV2 |LPCompoundModule "`
Expected: `LPAutoBalancerV2` runtime size < 24,576 bytes. The contract started at ~23,986 bytes (~590 headroom) and this feature added two functions that mostly reuse existing internals, a setter, and a passthrough — it is TIGHT.

**Conditional fallback — only if the size check FAILS:** first dedup the repeated three-term valuation sum `_principalValue(...) + _altValue(...) + _contractPairValue(...)` (used in `rebalanceUsingAlt`, `unwindForSwap`, and `rebuildAfterSwap`) into one private helper:
```solidity
    function _totalValue(ManagedPositionV2 storage p, uint160 sqrtP, uint8 dec0, uint8 dec1)
        private
        view
        returns (uint256)
    {
        return _principalValue(p, p.mainTokenId, sqrtP, dec0, dec1) + _altValue(p, sqrtP, dec0, dec1)
            + _contractPairValue(p, dec0, dec1);
    }
```
Replace the three call sites with `_totalValue(p, sqrtP, dec0, dec1)`, re-run the size check. If STILL over, move the per-position valuation math (`_principalValue`/`_altValue`/`_contractPairValue`) into `src/libraries/LPBalancerLib.sol` as additional `public` functions (it already holds `alignedRange`, `consultTwapTick`, `readFeed`, `valueInUsd`, `amountsForLiquidityAtTicks` this way — delegatecalled library code does not count against the balancer's own runtime size), update call sites to `LPBalancerLib.xxx(...)`, and re-run the FULL unit + fork suites. Skip this entire fallback if the first size check passes.

- [ ] **Step 2: Wire `setSwapLossAllowanceBps` into the 011 proposal**

In `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol`, add a constant next to `COMPOUND_SLIPPAGE_BPS`:
```solidity
    uint16 public constant SWAP_LOSS_ALLOWANCE_BPS = 300;
```
Then, in the existing `_wireModule(LPAutoBalancerV2 lab)` internal function (the file wires compound config there via plain calls, e.g. `lab.setCompoundModule(address(module));` — follow that exact style, no action-list/selector-encoding abstraction exists in this file), add one line at the end:
```solidity
    function _wireModule(LPAutoBalancerV2 lab) internal {
        LPCompoundModule module = LPCompoundModule(addresses.getAddress("MAMO_LP_COMPOUND_MODULE"));
        lab.setCompoundModule(address(module));
        module.setSlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        module.setSlippage(COMPOUND_SLIPPAGE_BPS);
        module.setCompoundAppData(COMPOUND_APP_DATA);
        lab.setSwapLossAllowanceBps(SWAP_LOSS_ALLOWANCE_BPS);
    }
```
In the existing `validateModule(address labAddr, address safe)` function, add one assertion at the end (before the closing brace):
```solidity
        assertEq(LPAutoBalancerV2(labAddr).swapLossAllowanceBps(), SWAP_LOSS_ALLOWANCE_BPS, "swap loss allowance set");
```
Run: `make lp-v2-setup`
Expected: PASS — the setup fork test executes the proposal and the new call succeeds; `validateModule`'s new assertion passes.

- [ ] **Step 3: Update the runbook**

In `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md`, add a "Rebalance mode selection" section covering:
- Per-cycle choice by the REBALANCER backend: `rebalanceUsingAlt(RebalanceParams)` (no-swap, single tx) vs `unwindForSwap(UnwindParams)` + CowSwap order + `rebuildAfterSwap(RebalanceParams)` (swap path). No Safe master switch.
- Sell amount is chosen off-chain and embedded in the order; the on-chain contract only pins the approval amount.
- Stuck orders: `rebuildAfterSwap` is never gated on order state — an expired-unfilled rebuild is identical to the no-swap outcome; it IS gated on pause and the TWAP calm gate; `exit()` (`DEFAULT_ADMIN_ROLE`) is the always-available mid-flight escape hatch and revokes the relayer approval.
- Order requirements enforced on-chain (fill-or-kill sell order between the two underlyings, receiver = balancer, appData = compoundAppData, price-checker-bounded, 5-minute-minimum / maxTimePriceValid-maximum expiry, validates only while `rebalanceInFlight`).
- **Manual prerequisite:** the `CHAINLINK_SWAP_CHECKER_PROXY` owner must add `WETH->cbBTC` and `cbBTC->WETH` feed configs to the slippage price checker before production orders can validate. Not in our control; track separately.

- [ ] **Step 4: Full LPV2 suite + formatting**

Run:
```bash
forge test --mc LPAutoBalancerV2UnitTest -vv
forge test --mc LPCompoundModuleUnitTest -vv
BASE_RPC_URL=https://mainnet.base.org forge test --ffi --mc LPAutoBalancerV2Integration -vv
make lp-v2-setup
forge fmt
```
Expected: all PASS; `forge fmt` clean. **Caveat:** CI pins forge `nightly-e52076714ace23c7a68e14f0048a40be3c6c8f0b`, and its `forge fmt` wraps tuple destructuring and long chains differently from local 1.7.1 — if CI's `forge fmt --check` fails after this, the fix is formatting with the pinned nightly (a toolchain change to surface to the user, NOT something to fix autonomously in this task).

- [ ] **Step 5: Commit**
```bash
git add multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md
git commit -m "feat(lpv2): wire setSwapLossAllowanceBps into 011 proposal, document swap-rebalance runbook"
```

---

## Self-review checklist (verified against the actual codebase, not just the spec)

**Spec coverage vs the decision table:**
- [x] Async CowSwap two-phase (no atomic swap) — Tasks 4, 5, 6, 8.
- [x] Per-cycle mode selection by REBALANCER, no Safe switch — both entry points role-gated `REBALANCER_ROLE` (Tasks 4, 5); rename keeps `rebalanceUsingAlt` as the no-swap sibling (Task 1); runbook documents the choice (Task 9).
- [x] Continuous swap ratio, no on-chain ratio param — `sellAmount` is the only sizing input (Task 4).
- [x] Stuck-order handling: `rebuildAfterSwap` never gated on order state, IS gated on calm gate + pause, `exit()` escape hatch — Tasks 5, 7, and both fork paths in Task 8.
- [x] EIP-1271: module validates (full logic), balancer is a 3-line passthrough, order owner = balancer — Task 6; NO validation logic added to the balancer (EIP-170 headroom).

**Verified against real code (fixed from the initial draft, not left as guesses):**
- [x] Pool mock spot-tick setter is `mockPool.setSlot0(sqrtP, tick)`, confirmed by reading `test/LPAutoBalancerV2.unit.t.sol` — all TWAP-deviation tests use this, not an invented `setSpotTick`.
- [x] `_register(bool)` does NOT stake — confirmed by reading its body. Any "was staked" test explicitly calls `lab.stake()` after `_register(true)`.
- [x] Default config's `minRebalanceInterval` is `0` — confirmed. The cooldown test uses the existing `_registerWithInterval(3600)` helper instead.
- [x] No pre-existing pause test to "match" — confirmed by grep (zero hits). Task 4/5 write pause tests directly against OZ's `Pausable.EnforcedPause` error (confirmed present in the vendored `Pausable.sol`), with the import added explicitly.
- [x] Module test fixture names are `bal`/`spc`/`module` (not `stub`/`checker`), and the file already has a `_sig(...)` helper reused instead of re-deriving digests inline — confirmed by reading `test/LPCompoundModule.unit.t.sol`.
- [x] The `011` proposal has no `_pushAction`/selector-encoding helper — confirmed by reading the file; `_wireModule` uses plain Solidity calls, and Task 9 follows that exact pattern.

**No-placeholder scan:**
- [x] No "TBD", "implement later", or "similar to Task N — repeat elsewhere" phrasing. Every code block is complete and copy-pasteable.

**Type/name consistency:**
- [x] `ResetParams` appears ONLY in Task 1 (as the rename source); every later task uses `RebalanceParams` — including `rebuildAfterSwap(RebalanceParams calldata)` reusing the SAME struct (no second params struct).
- [x] `reset(` appears ONLY in Task 1; all later calls are `rebalanceUsingAlt(` / `rebuildAfterSwap(` / `unwindForSwap(`.
- [x] `Reset(` event ONLY in Task 1; later expectations use `RebalancedUsingAlt` / `RebalanceUnwound` / `RebalanceRebuilt`.
- [x] Error reuse honored: `ModuleNotSet`, `ValueFloor`, `Cooldown`, `TwapDeviation`, `NotActive`, `WidthOutOfBounds` reused; only `NotInFlight`/`AlreadyInFlight`/`InvalidSellToken`/`SwapLossAllowanceTooHigh` are new.
- [x] Module's existing AERO `isValidSignature` untouched; `GPv2Order.sol` untouched (forbidden — non-memory-safe assembly, shared with production `ERC20MoonwellMorphoStrategy`).

**EIP-170 size risk:**
- [x] Balancer starts at ~23,986/24,576 bytes. Task 9 Step 1 is the hard gate; the `LPBalancerLib` fallback is written conditionally ("only if the size check fails") with a cheap `_totalValue` dedup as the first resort before library extraction. Do not skip the size check even if all tests pass.
