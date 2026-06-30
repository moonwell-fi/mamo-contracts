# LPAutoBalancerV2 — Single-Pool + AERO Compounding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `LPAutoBalancerV2` from a multi-slot registry to one-contract-per-pool, add a `setPool` re-point setter, and add partial AERO compounding (both legs) via async CowSwap + EIP-1271, bounded by `SlippagePriceChecker`.

**Architecture:** The contract drops `positions[slotId]`/`nextSlotId` for a single `ManagedPositionV2 public position`; every external function loses its `slotId` argument. A new `compound(compoundBps)` harvests AERO, immediately drops the `(1−compoundBps)` share to `feeCollector`, and approves the remainder to the CowSwap `VAULT_RELAYER`; an off-chain bot posts two sell orders (AERO→token0 and AERO→token1) which the contract validates via `isValidSignature` against `SlippagePriceChecker`. Settled underlying sits loose and folds into a balanced main at the next `reset()` (existing mint already reads `balanceOf(this)` — no new reset code). Principal is still never swapped.

**Tech Stack:** Solidity 0.8.28, Foundry (forge/cast), Aerodrome Slipstream CL, Chainlink feeds, CowSwap (GPv2) + EIP-1271, OpenZeppelin AccessControl/ReentrancyGuard/Pausable, Forge Proposal Simulator (FPS).

**Spec:** `docs/superpowers/specs/2026-06-17-lp-auto-balancer-v2-dual-position-design.md` (revised 2026-06-30).

---

## Reference values (verbatim, do not retype from memory)

```solidity
// CowSwap on Base — mirror ERC20MoonwellMorphoStrategy.sol
bytes32 public constant DOMAIN_SEPARATOR = 0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b;
bytes4  internal constant MAGIC_VALUE = 0x1626ba7e;
address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500; // 25%
// GPv2Order lives at @libraries/GPv2Order.sol; struct Data has fields:
//   sellToken, buyToken, receiver, sellAmount, buyAmount, validTo, appData,
//   feeAmount, kind, partiallyFillable, sellTokenBalance, buyTokenBalance
//   constants: KIND_SELL, BALANCE_ERC20; function hash(Data, bytes32) -> bytes32
```

```
Base addresses/8453.json keys (existing):
  WETH 0x4200000000000000000000000000000000000006
  cbBTC 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
  AERO 0x940181a94A35A4569E4529A3CDfB74e38FD98631
  UNISWAP_V3_POSITION_MANAGER_AERODROME 0x827922686190790b37229fd06084350E74485b72
  WETH_CBBTC_CL_POOL 0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1
  WETH_CBBTC_CL_GAUGE 0x41b2126661C673C2beDd208cC72E85DC51a5320a
  CHAINLINK_ETH_USD 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
  CHAINLINK_BTC_USD 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F
  DROP_AUTOMATION 0x959d187D8E6115816a69c29b4809DE8A2Aa680e6
  F-MAMO 0xfE2ff8927EF602DDac27E314A199D16BE6177860
  CHAINLINK_SWAP_CHECKER_PROXY 0x5A8F10be44E25Bb21492C5f46DA94cDb1f0b2fF6  (SlippagePriceChecker, deployed)
MISSING (Task 7 adds it): CHAINLINK_AERO_USD
```

---

## Task 1: Refactor `LPAutoBalancerV2` to a single position (drop `slotId`)

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Modify: `test/LPAutoBalancerV2.unit.t.sol`

This is a mechanical-but-wide refactor. The behavior is identical; only the addressing collapses from `positions[slotId]` to one `position`.

**Transformation rules (apply across `src/LPAutoBalancerV2.sol`):**

1. **Storage.** Replace:
   ```solidity
   mapping(uint256 slotId => ManagedPositionV2) public positions;
   uint256 public nextSlotId;
   ```
   with:
   ```solidity
   ManagedPositionV2 public position;
   ```
2. **New error** (add to the error block):
   ```solidity
   error AlreadyRegistered();
   ```
3. **External function signatures — drop the `slotId` parameter** on every one of:
   `registerPosition` (keep `config`, now returns nothing), `deregisterPosition(address to)`, `withdrawPosition(address to)`, `setPositionConfig(...)` (drop leading `slotId`), `setFeeCollector(address)`, `setOracles(address,address)`, `setGauge(address)`, `stake()`, `unstake()`, `claimEmissions()`, `exit(address to)`, `reset(ResetParams)`, `collectFees()`, `getDecisionSnapshot()`.
4. **Body access.** Inside each, replace `positions[slotId]` with `position`. Where a function did `ManagedPositionV2 storage p = positions[slotId];` keep `ManagedPositionV2 storage p = position;`.
5. **Private helpers** (`_store`, `_exitAll`, `_skimFees`, `_unstake`, `_unstakeAlt`, `_decreaseLiquidityAll`, `_mintBalanced`, `_mintAlt`, `_principalValue`, `_altValue`, `_contractPairValue`, `_forwardDust`, `_mainRange`): remove every `uint256 slotId` parameter and any `slotId` passed through. They already take `ManagedPositionV2 storage p` — keep that.
6. **Events.** Drop the `slotId` argument from every event (`PositionRegistered`, `PositionDeregistered`, `PositionWithdrawn`, `PositionConfigUpdated`, `FeeCollectorUpdated`, `OraclesUpdated`, `GaugeUpdated`, `Staked`, `Unstaked`, `EmissionsClaimed`, `FeesSkimmed`, `Reset`) and every `emit`. Example: `event Reset(uint256 mainTokenId, uint256 altTokenId, int24 tickLower, int24 tickUpper);`
7. **`registerPosition` guard.** At the top, add:
   ```solidity
   if (position.active) revert AlreadyRegistered();
   ```
   Remove `slotId = nextSlotId++;`. Call `_store(config)` and `emit PositionRegistered(config.pool, config.mainTokenId);`. Change return type to `void`.
8. **`_store`** drops its `slotId` param and writes to `position` (the storage var) instead of `positions[slotId]`.

- [ ] **Step 1: Apply the refactor to `src/LPAutoBalancerV2.sol`**

Apply rules 1–8 above. Do not change any logic, math, ordering, CEI, or guard — only the addressing/signatures/events. The `ManagedPositionV2` struct itself is unchanged.

- [ ] **Step 2: Build the contract**

Run: `forge build`
Expected: compiles. If errors mention `slotId` undefined, finish removing the stragglers.

- [ ] **Step 3: Refactor the unit test to single-position**

In `test/LPAutoBalancerV2.unit.t.sol`:
- Change the helper `_registerSlot(bool withGauge) returns (uint256 slotId)` to `_register(bool withGauge)` returning nothing; keep the same `cfg`; replace `slotId = lab.registerPosition(cfg);` with `lab.registerPosition(cfg);`.
- Find/replace every call site, dropping the slot arg and slot var:
  - `lab.reset(slotId, params)` → `lab.reset(params)`
  - `lab.stake(slotId)` → `lab.stake()`, `lab.unstake(slotId)` → `lab.unstake()`
  - `lab.claimEmissions(slotId)` → `lab.claimEmissions()`
  - `lab.exit(slotId, to)` → `lab.exit(to)`
  - `lab.collectFees(slotId)` → `lab.collectFees()`
  - `lab.getDecisionSnapshot(slotId)` → `lab.getDecisionSnapshot()`
  - `lab.setPositionConfig(slotId, ...)` → `lab.setPositionConfig(...)`
  - `lab.setGauge(slotId, g)` → `lab.setGauge(g)`, `lab.setFeeCollector(slotId, x)` → `lab.setFeeCollector(x)`, `lab.setOracles(slotId, a, b)` → `lab.setOracles(a, b)`
  - reads of `lab.positions(slotId)` → `lab.position()`
  - any `vm.expectEmit` referencing the dropped `slotId` event arg — update to the new event signature.
- Delete now-redundant "second slot" tests if any register two positions (the contract holds one). If a test registered a second slot to test isolation, convert it to assert `registerPosition` now reverts `AlreadyRegistered` when already active.

- [ ] **Step 4: Add the `AlreadyRegistered` test**

Add to `test/LPAutoBalancerV2.unit.t.sol`:

```solidity
function test_registerPosition_revertsWhenAlreadyActive() public {
    _register(false); // first registration succeeds
    LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
    vm.prank(admin);
    vm.expectRevert(LPAutoBalancerV2.AlreadyRegistered.selector);
    lab.registerPosition(cfg);
}
```
(If no `_defaultConfig` helper exists, factor the `cfg` literal out of `_register` into `_defaultConfig(bool withGauge)` returning the struct, and have `_register` call it.)

- [ ] **Step 5: Run the unit suite**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vvv`
Expected: all tests pass (the 54 existing + the new `AlreadyRegistered` test). Fix any remaining `slotId` references the compiler/test runner surfaces.

- [ ] **Step 6: Commit**

```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "refactor(lpv2): single position per contract, drop slotId"
```

---

## Task 2: Add `setPool` (re-point an emptied contract)

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Modify: `test/LPAutoBalancerV2.unit.t.sol`

**Approach:** extract `registerPosition`'s validate-and-store body into a private `_validateAndStore(config)`; `registerPosition` keeps the `AlreadyRegistered` guard and calls it; `setPool` adds an empty-contract guard and calls the same path.

- [ ] **Step 1: Write the failing tests**

Add to `test/LPAutoBalancerV2.unit.t.sol`:

```solidity
function test_setPool_revertsWhenActive() public {
    _register(false);
    LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
    vm.prank(admin);
    vm.expectRevert(LPAutoBalancerV2.NotEmpty.selector);
    lab.setPool(cfg);
}

function test_setPool_repointsAfterExit() public {
    _register(false);
    // exit to empty the contract (admin path; mock PM burns NFTs)
    vm.prank(admin);
    lab.exit(admin);
    // new pool config (reuse mocks; new mainTokenId held by lab)
    pm.mint_setOwner(NEW_TOKEN_ID, address(lab)); // mock helper: make lab own a new NFT
    LPAutoBalancerV2.ManagedPositionV2 memory cfg = _defaultConfig(false);
    cfg.mainTokenId = NEW_TOKEN_ID;
    vm.prank(admin);
    vm.expectEmit(true, true, false, false, address(lab));
    emit LPAutoBalancerV2.PoolChanged(cfg.pool, NEW_TOKEN_ID);
    lab.setPool(cfg);
    (uint256 mainId,,,,,,,,,,,,,,,,,,,) = lab.position();
    assertEq(mainId, NEW_TOKEN_ID);
}
```
Add `uint256 constant NEW_TOKEN_ID = 4242;` near the other constants. If `MockPositionManagerV2` lacks a way to set an NFT's owner/position fields for a fresh id, add a minimal helper to the inline mock (e.g. `setOwnerAndPosition(tokenId, owner, token0, token1, tickSpacing)`); the existing mint path already records owners — reuse it.

- [ ] **Step 2: Run to verify they fail**

Run: `forge test --mc LPAutoBalancerV2UnitTest --mt "setPool" -vvv`
Expected: FAIL — `setPool`/`NotEmpty`/`PoolChanged` undefined.

- [ ] **Step 3: Implement `setPool` + `_validateAndStore` + members**

In `src/LPAutoBalancerV2.sol`:
- Add error: `error NotEmpty();`
- Add event: `event PoolChanged(address indexed pool, uint256 indexed mainTokenId);`
- Refactor `registerPosition`:
  ```solidity
  function registerPosition(ManagedPositionV2 calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
      if (position.active) revert AlreadyRegistered();
      _validateAndStore(config);
      emit PositionRegistered(config.pool, config.mainTokenId);
  }
  ```
- Add:
  ```solidity
  /// @notice Re-point this (emptied) contract at a new pool/pair. Requires a prior exit()/withdraw
  ///         to have zeroed the position. Same validation as registerPosition.
  function setPool(ManagedPositionV2 calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
      if (position.active || position.mainTokenId != 0 || position.altTokenId != 0) revert NotEmpty();
      _validateAndStore(config);
      emit PoolChanged(config.pool, config.mainTokenId);
  }
  ```
- Create `_validateAndStore(ManagedPositionV2 calldata config) private` containing **all** the validation currently inside `registerPosition` (loss cap, zero-address, oracle probes, twap/deviation/centerDeviation, tickSpacing, pool cross-check, width bounds/alignment, gauge reward-token check, NFT ownership, NFT pool-binding) followed by `_store(config)`. `registerPosition` and `setPool` both call it.

- [ ] **Step 4: Run the tests to verify pass**

Run: `forge test --mc LPAutoBalancerV2UnitTest --mt "setPool|AlreadyRegistered" -vvv`
Expected: PASS.

- [ ] **Step 5: Full unit suite green**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vvv`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/LPAutoBalancerV2.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): setPool re-point for emptied contract"
```

---

## Task 3: CowSwap / EIP-1271 scaffolding (no compound yet)

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Create: `test/mocks/MockSlippagePriceChecker.sol`
- Modify: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Create the mock SlippagePriceChecker**

Create `test/mocks/MockSlippagePriceChecker.sol`:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

/// @notice Minimal mock for LPAutoBalancerV2 compound/EIP-1271 tests.
contract MockSlippagePriceChecker {
    bool public priceOk = true;
    uint256 public maxValid = 30 minutes;
    mapping(address => bool) public reward;

    function setPriceOk(bool ok) external { priceOk = ok; }
    function setMaxTimePriceValid(address, uint256 v) external { maxValid = v; }
    function setRewardToken(address t, bool v) external { reward[t] = v; }

    function checkPrice(uint256, address, address, uint256, uint256) external view returns (bool) {
        return priceOk;
    }
    function isRewardToken(address t) external view returns (bool) { return reward[t]; }
    function maxTimePriceValid(address) external view returns (uint256) { return maxValid; }
}
```

- [ ] **Step 2: Write the failing EIP-1271 tests**

Add to `test/LPAutoBalancerV2.unit.t.sol` (import `GPv2Order` and the mock at top). Add a builder + the cases:

```solidity
import {GPv2Order} from "@libraries/GPv2Order.sol";
import {MockSlippagePriceChecker} from "./mocks/MockSlippagePriceChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// in the test contract:
MockSlippagePriceChecker spc;

function _order(address sell, address buy, address receiver, uint32 validTo)
    internal
    view
    returns (GPv2Order.Data memory o)
{
    o = GPv2Order.Data({
        sellToken: IERC20(sell),
        buyToken: IERC20(buy),
        receiver: receiver,
        sellAmount: 1e18,
        buyAmount: 1e18,
        validTo: validTo,
        appData: appData,           // stored compoundAppData (set below)
        feeAmount: 0,
        kind: GPv2Order.KIND_SELL,
        partiallyFillable: false,
        sellTokenBalance: GPv2Order.BALANCE_ERC20,
        buyTokenBalance: GPv2Order.BALANCE_ERC20
    });
}

function _sig(GPv2Order.Data memory o) internal view returns (bytes32 digest, bytes memory enc) {
    digest = o.hash(lab.DOMAIN_SEPARATOR());
    enc = abi.encode(o);
}

function _wireCompound() internal {
    spc = new MockSlippagePriceChecker();
    spc.setRewardToken(aero, true);
    vm.startPrank(admin);
    lab.setSlippagePriceChecker(address(spc));
    lab.setSlippage(100);
    lab.setCompoundAppData(appData);
    lab.approveCowSwap(aero, type(uint256).max);
    vm.stopPrank();
}

function test_isValidSignature_validAeroToToken0() public {
    _register(true);
    _wireCompound();
    GPv2Order.Data memory o = _order(aero, token0, address(lab), uint32(block.timestamp + 10 minutes));
    (bytes32 d, bytes memory e) = _sig(o);
    assertEq(lab.isValidSignature(d, e), bytes4(0x1626ba7e));
}

function test_isValidSignature_validAeroToToken1() public {
    _register(true);
    _wireCompound();
    GPv2Order.Data memory o = _order(aero, token1, address(lab), uint32(block.timestamp + 10 minutes));
    (bytes32 d, bytes memory e) = _sig(o);
    assertEq(lab.isValidSignature(d, e), bytes4(0x1626ba7e));
}

function test_isValidSignature_revertsWrongSellToken() public {
    _register(true); _wireCompound();
    GPv2Order.Data memory o = _order(token0, token1, address(lab), uint32(block.timestamp + 10 minutes));
    (bytes32 d, bytes memory e) = _sig(o);
    vm.expectRevert(bytes("sellToken must be AERO"));
    lab.isValidSignature(d, e);
}

function test_isValidSignature_revertsBuyTokenNotUnderlying() public {
    _register(true); _wireCompound();
    GPv2Order.Data memory o = _order(aero, address(0xBEEF), address(lab), uint32(block.timestamp + 10 minutes));
    (bytes32 d, bytes memory e) = _sig(o);
    vm.expectRevert(bytes("buyToken must be underlying"));
    lab.isValidSignature(d, e);
}

function test_isValidSignature_revertsReceiverNotThis() public {
    _register(true); _wireCompound();
    GPv2Order.Data memory o = _order(aero, token0, address(0xCAFE), uint32(block.timestamp + 10 minutes));
    (bytes32 d, bytes memory e) = _sig(o);
    vm.expectRevert(bytes("receiver must be this"));
    lab.isValidSignature(d, e);
}

function test_isValidSignature_revertsCheckPriceFails() public {
    _register(true); _wireCompound();
    spc.setPriceOk(false);
    GPv2Order.Data memory o = _order(aero, token0, address(lab), uint32(block.timestamp + 10 minutes));
    (bytes32 d, bytes memory e) = _sig(o);
    vm.expectRevert(bytes("price check failed"));
    lab.isValidSignature(d, e);
}

function test_setSlippage_bounds() public {
    _register(true); _wireCompound();
    vm.prank(admin);
    vm.expectRevert(bytes("slippage too high"));
    lab.setSlippage(2501); // MAX_SLIPPAGE_IN_BPS = 2500
}
```
Add a `bytes32 appData = keccak256("mamo-lpv2-compound");` constant to the test contract (the bot would match this).

- [ ] **Step 3: Run to verify they fail**

Run: `forge test --mc LPAutoBalancerV2UnitTest --mt isValidSignature -vvv`
Expected: FAIL — `isValidSignature`/setters undefined.

- [ ] **Step 4: Implement the scaffolding in `src/LPAutoBalancerV2.sol`**

Add imports:
```solidity
import {GPv2Order} from "@libraries/GPv2Order.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
```
Add `using GPv2Order for GPv2Order.Data;` after the existing `using SafeERC20 for IERC20;`.

Add constants + state:
```solidity
bytes32 public constant DOMAIN_SEPARATOR = 0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b;
bytes4  internal constant MAGIC_VALUE = 0x1626ba7e;
address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500;
uint16  public constant MAX_COMPOUND_BPS = 10_000; // = BPS_DENOMINATOR; also guards BPS - compoundBps underflow

ISlippagePriceChecker public slippagePriceChecker;
uint256 public allowedSlippageInBps;
bytes32 public compoundAppData; // expected CowSwap appData hash for compound orders
```
Add errors + events:
```solidity
error SlippageTooHigh();
error CheckerNotSet();
event SlippageUpdated(uint256 oldBps, uint256 newBps);
event SlippagePriceCheckerUpdated(address checker);
event CompoundAppDataUpdated(bytes32 appData);
```
Add admin setters (DEFAULT_ADMIN_ROLE):
```solidity
function setSlippagePriceChecker(address checker) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (checker == address(0)) revert ZeroAddress();
    slippagePriceChecker = ISlippagePriceChecker(checker);
    emit SlippagePriceCheckerUpdated(checker);
}

function setSlippage(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(newBps <= MAX_SLIPPAGE_IN_BPS, "slippage too high");
    emit SlippageUpdated(allowedSlippageInBps, newBps);
    allowedSlippageInBps = newBps;
}

function setCompoundAppData(bytes32 appData) external onlyRole(DEFAULT_ADMIN_ROLE) {
    compoundAppData = appData;
    emit CompoundAppDataUpdated(appData);
}

/// @notice Approve the CowSwap vault relayer to pull `amount` of `tokenAddress` (AERO).
function approveCowSwap(address tokenAddress, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (address(slippagePriceChecker) == address(0)) revert CheckerNotSet();
    require(slippagePriceChecker.isRewardToken(tokenAddress), "Token not allowed");
    IERC20(tokenAddress).forceApprove(VAULT_RELAYER, amount);
}
```
Add `isValidSignature` (view):
```solidity
/// @notice EIP-1271 validation for CowSwap compound orders (AERO -> token0|token1, reward-only).
function isValidSignature(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4) {
    GPv2Order.Data memory o = abi.decode(encodedOrder, (GPv2Order.Data));
    require(o.hash(DOMAIN_SEPARATOR) == orderDigest, "bad digest");
    require(o.kind == GPv2Order.KIND_SELL, "must be sell");
    require(!o.partiallyFillable, "must be fill-or-kill");
    require(o.sellTokenBalance == GPv2Order.BALANCE_ERC20, "sell must be erc20");
    require(o.buyTokenBalance == GPv2Order.BALANCE_ERC20, "buy must be erc20");
    require(address(o.sellToken) == AERO, "sellToken must be AERO");
    require(address(o.buyToken) == position.token0 || address(o.buyToken) == position.token1, "buyToken must be underlying");
    require(o.receiver == address(this), "receiver must be this");
    require(o.feeAmount == 0, "fee must be zero");
    require(o.appData == compoundAppData, "bad appData");
    require(o.validTo >= block.timestamp + 5 minutes, "expires too soon");
    require(o.validTo <= block.timestamp + slippagePriceChecker.maxTimePriceValid(address(o.sellToken)), "expires too far");
    require(
        slippagePriceChecker.checkPrice(o.sellAmount, address(o.sellToken), address(o.buyToken), o.buyAmount, allowedSlippageInBps),
        "price check failed"
    );
    return MAGIC_VALUE;
}
```
The contract already imports `IERC20` and declares `address public immutable AERO;` — reuse them. (`SlippageTooHigh` is declared for parity but `setSlippage` uses a string revert to match the strategy and the test; keep one or the other consistently — the test expects the string `"slippage too high"`.)

- [ ] **Step 5: Build + run the EIP-1271 tests**

Run: `forge build && forge test --mc LPAutoBalancerV2UnitTest --mt "isValidSignature|setSlippage" -vvv`
Expected: PASS.

- [ ] **Step 6: Confirm contract still under 24 KB**

Run: `forge build --sizes 2>/dev/null | grep LPAutoBalancerV2`
Expected: runtime size < 24576 bytes. (Prior commit `29bce6f` trimmed for this limit — watch it.) If over, convert the `isValidSignature` string reverts to custom errors to save bytecode.

- [ ] **Step 7: Commit**

```bash
git add src/LPAutoBalancerV2.sol test/mocks/MockSlippagePriceChecker.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): CowSwap EIP-1271 isValidSignature + slippage config"
```

---

## Task 4: `compound(compoundBps)` — harvest, split, approve

**Files:**
- Modify: `src/LPAutoBalancerV2.sol`
- Modify: `test/mocks/MockCLGauge.sol` (add `getReward` payout)
- Modify: `test/LPAutoBalancerV2.unit.t.sol`

- [ ] **Step 1: Give the mock gauge a `getReward` payout**

In `test/mocks/MockCLGauge.sol`, ensure `getReward(uint256 tokenId)` mints/transfers a configurable AERO amount to `msg.sender` (the balancer). Add if missing:

```solidity
uint256 public rewardOnGetReward;
function setRewardOnGetReward(uint256 amt) external { rewardOnGetReward = amt; }
function getReward(uint256) external {
    if (rewardOnGetReward > 0) {
        MockERC20(aero).mint(msg.sender, rewardOnGetReward);
    }
}
```
(Match the existing mock's AERO handle/field name and `MockERC20` mint signature; the withdraw path already simulates AERO payout, mirror it.)

- [ ] **Step 2: Write the failing compound tests**

Add to `test/LPAutoBalancerV2.unit.t.sol`:

```solidity
function test_compound_revertsAboveMaxBps() public {
    _register(true); _wireCompound();
    vm.prank(rebalancer);
    vm.expectRevert(LPAutoBalancerV2.CompoundBpsTooHigh.selector);
    lab.compound(10_001);
}

function test_compound_onlyRebalancer() public {
    _register(true); _wireCompound();
    vm.prank(admin);
    vm.expectRevert(); // AccessControl: missing REBALANCER_ROLE
    lab.compound(5_000);
}

function test_compound_splitsDropAndApproves() public {
    _register(true);            // staked-capable position
    _wireCompound();
    vm.prank(rebalancer);
    lab.stake();                // stake so getReward has an NFT context
    gauge.setRewardOnGetReward(1_000e18); // 1000 AERO harvested
    uint256 fcBefore = MockERC20(aero).balanceOf(feeCollector);

    vm.prank(rebalancer);
    lab.compound(7_000);        // 70% compound / 30% drop

    // 30% -> feeCollector
    assertEq(MockERC20(aero).balanceOf(feeCollector) - fcBefore, 300e18);
    // 70% stays on contract, approved to relayer
    assertEq(MockERC20(aero).balanceOf(address(lab)), 700e18);
    assertEq(MockERC20(aero).allowance(address(lab), lab.VAULT_RELAYER()), 700e18);
}

function test_compound_revertsWhenNothingHarvested() public {
    _register(true); _wireCompound();
    vm.prank(rebalancer); lab.stake();
    // rewardOnGetReward defaults 0
    vm.prank(rebalancer);
    vm.expectRevert(LPAutoBalancerV2.NothingToCompound.selector);
    lab.compound(5_000);
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `forge test --mc LPAutoBalancerV2UnitTest --mt compound -vvv`
Expected: FAIL — `compound`/errors undefined.

- [ ] **Step 4: Implement `compound`**

Add errors + event to `src/LPAutoBalancerV2.sol`:
```solidity
error CompoundBpsTooHigh();
error NothingToCompound();
event CompoundInitiated(uint256 compoundAmount, uint256 droppedAmount, uint16 compoundBps);
```
Add the function (place near `claimEmissions`):
```solidity
/// @notice Harvest AERO and reinvest `compoundBps` of it into the underlying pair via CowSwap.
///         Drops the remaining (BPS - compoundBps) share to feeCollector immediately. The compound
///         share is left approved to VAULT_RELAYER; the off-chain bot posts two sell orders
///         (AERO->token0 and AERO->token1) validated by isValidSignature. Settled underlying folds
///         into the main+alt at the next reset(). Reward-only swap — never touches principal.
function compound(uint16 compoundBps) external onlyRole(REBALANCER_ROLE) nonReentrant whenNotPaused {
    if (compoundBps > MAX_COMPOUND_BPS) revert CompoundBpsTooHigh();
    ManagedPositionV2 storage p = position;
    if (!p.active) revert NotActive();
    if (address(slippagePriceChecker) == address(0)) revert CheckerNotSet();

    // Harvest pending AERO from staked legs into this contract (no unstake).
    if (p.mainStaked) ICLGauge(p.gauge).getReward(p.mainTokenId);
    if (p.altStaked && p.altTokenId != 0) ICLGauge(p.gauge).getReward(p.altTokenId);

    uint256 aero = IERC20(AERO).balanceOf(address(this));
    if (aero == 0) revert NothingToCompound();

    uint256 dropAmount = FullMath.mulDiv(aero, BPS_DENOMINATOR - compoundBps, BPS_DENOMINATOR);
    uint256 compoundAmount = aero - dropAmount;

    if (dropAmount > 0) {
        IERC20(AERO).safeTransfer(p.feeCollector, dropAmount);
        emit EmissionsClaimed(dropAmount);
    }
    if (compoundAmount > 0) {
        IERC20(AERO).forceApprove(VAULT_RELAYER, compoundAmount);
    }
    emit CompoundInitiated(compoundAmount, dropAmount, compoundBps);
}
```
Notes: `FullMath`, `IERC20`, `ICLGauge`, `BPS_DENOMINATOR`, `REBALANCER_ROLE` are already imported/declared. `EmissionsClaimed` is the existing event (now single-arg after Task 1).

- [ ] **Step 5: Run compound tests + full suite**

Run: `forge test --mc LPAutoBalancerV2UnitTest -vvv`
Expected: all PASS.

- [ ] **Step 6: Size check + commit**

Run: `forge build --sizes 2>/dev/null | grep LPAutoBalancerV2` (must stay < 24576).
```bash
git add src/LPAutoBalancerV2.sol test/mocks/MockCLGauge.sol test/LPAutoBalancerV2.unit.t.sol
git commit -m "feat(lpv2): compound() partial AERO reinvest via CowSwap"
```

---

## Task 5: Loose-balance fold at reset (unit test only — no new contract code)

**Files:**
- Modify: `test/LPAutoBalancerV2.unit.t.sol`

`reset()` already mints from `balanceOf(this)`, so settled compound proceeds (loose token0 + token1) fold automatically. Prove it.

- [ ] **Step 1: Write the test**

```solidity
function test_reset_foldsLooseCompoundProceeds_bothLegs() public {
    _register(true);
    _setOutOfRangeWithBothLegsWithdrawable(); // existing helper that makes reset withdraw a balanced main
    // Simulate settled CowSwap proceeds: drop loose token0 AND token1 onto the contract.
    MockERC20(token0).mint(address(lab), 1e18);
    MockERC20(token1).mint(address(lab), 1e8);
    uint256 t0Before = MockERC20(token0).balanceOf(address(lab));
    uint256 t1Before = MockERC20(token1).balanceOf(address(lab));
    assertGt(t0Before, 0);
    assertGt(t1Before, 0);

    vm.prank(rebalancer);
    lab.reset(_defaultResetParams());

    // The loose proceeds were consumed by the new mint (not left idle / not all dust-forwarded).
    // Main mint should have pulled both legs; assert the post-reset loose balance dropped.
    assertLt(MockERC20(token0).balanceOf(address(lab)) + MockERC20(token1).balanceOf(address(lab)), t0Before + t1Before);
}
```
Use whatever existing setup helper the unit file already uses to drive a balanced reset (mirror `test_reset_rebuildsMain_fromWithdrawnBalances`). If no `_setOutOfRangeWithBothLegsWithdrawable` exists, inline the same mock wiring that test uses.

- [ ] **Step 2: Run it**

Run: `forge test --mc LPAutoBalancerV2UnitTest --mt foldsLooseCompoundProceeds -vvv`
Expected: PASS (no contract change needed). If it fails because the mock PM ignores desired amounts, assert instead on the mock's recorded `mint` desired-amounts including the injected loose balances.

- [ ] **Step 3: Commit**

```bash
git add test/LPAutoBalancerV2.unit.t.sol
git commit -m "test(lpv2): loose compound proceeds fold into main at reset"
```

---

## Task 6: Integration tests (Base fork) — single-position + compound

**Files:**
- Modify: `test/LPAutoBalancerV2.integration.t.sol`

- [ ] **Step 1: Drop slotId from the integration test**

Apply the same call-site transformation as Task 1 Step 3 to `test/LPAutoBalancerV2.integration.t.sol`: `_register(tokenId)` returns nothing; `lab.reset(slotId, params)` → `lab.reset(params)`; any `lab.positions(slotId)`/`lab.getDecisionSnapshot(slotId)` → single-arg.

- [ ] **Step 2: Add a compound-fold integration test**

```solidity
function test_compound_then_reset_foldsProceeds() public {
    uint256 tokenId = _mintMainPositionToThis(2 ether, 0.05e8);
    _register(tokenId);
    // wire compound infra against the REAL deployed SlippagePriceChecker proxy
    vm.startPrank(admin);
    lab.setSlippagePriceChecker(SWAP_CHECKER_PROXY);
    lab.setSlippage(200);
    lab.setCompoundAppData(keccak256("mamo-lpv2-compound"));
    vm.stopPrank();
    vm.prank(rebalancer); lab.stake();

    // We cannot settle a real CowSwap order in a fork, so simulate the SETTLED proceeds:
    // deal loose WETH + cbBTC onto the contract (what the solver would deliver), then reset.
    deal(WETH, address(lab), 0.1 ether);
    deal(CBBTC, address(lab), 0.002e8);

    _pushTickDown();        // force out of range
    vm.warp(block.timestamp + 2 hours); // TWAP convergence (mirror existing tests)
    vm.prank(rebalancer);
    lab.reset(_defaultParams());

    // new main exists and the injected proceeds were folded (loose balances shrank)
    (uint256 mainId,,,,,,,,,,,,,,,,,,,) = lab.position();
    assertGt(mainId, 0);
}
```
Add `address constant SWAP_CHECKER_PROXY = 0x5A8F10be44E25Bb21492C5f46DA94cDb1f0b2fF6;` to the test constants. Reuse the file's existing `_mintMainPosition*`, `_pushTickDown`, `_defaultParams` helpers (rename to match what's there).

- [ ] **Step 3: Run the integration suite**

Run: `make lp-auto-balancer-v2`
Expected: all PASS (2 existing + 1 new). Fork is pinned at block 47_600_000; `vm.fee(0)` Isthmus workaround already in `setUp`.

- [ ] **Step 4: Commit**

```bash
git add test/LPAutoBalancerV2.integration.t.sol
git commit -m "test(lpv2): integration single-position + compound fold"
```

---

## Task 7: FPS setup proposal + addresses + SlippagePriceChecker config

**Files:**
- Modify: `addresses/8453.json` (add `CHAINLINK_AERO_USD`)
- Modify: `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol`
- Modify: `test/LPAutoBalancerV2Setup.integration.t.sol`
- Modify: `script/DeployLPAutoBalancerV2.s.sol` and `test/DeployLPAutoBalancerV2.t.sol` only if the constructor signature changed (it did not — leave unless build breaks)

- [ ] **Step 1: Obtain + add the Base AERO/USD Chainlink feed address**

The AERO/USD feed is not in `addresses/8453.json`. Get the canonical Base mainnet AERO/USD aggregator from Chainlink's Base feed list (candidate to VERIFY, do not trust blindly: `0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0`). Verify it is live before adding:

Run: `cast call 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0 "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url base`
Expected: returns a positive `answer` and a recent `updatedAt`. Also `cast call 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0 "description()(string)" --rpc-url base` should read `AERO / USD`.

Add to `addresses/8453.json` (follow the file's existing object shape — `{ "addr": "...", "name": "CHAINLINK_AERO_USD", "isContract": true }`):
```json
{ "addr": "0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0", "name": "CHAINLINK_AERO_USD", "isContract": true }
```

- [ ] **Step 2: Drop slotId in the proposal + add compound wiring**

In `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol`:
- `registerPosition(config)` call is unchanged in shape (still takes the struct). No slotId there.
- Add Safe build actions after `registerPosition`:
  1. `lab.setSlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"))`
  2. `lab.setSlippage(200)` (conservative 2% default)
  3. `lab.setCompoundAppData(COMPOUND_APP_DATA)` — define `bytes32 constant COMPOUND_APP_DATA = keccak256("mamo-lpv2-compound");` (replace with the real appData hash agreed with the off-chain bot before mainnet execution).
  4. `lab.approveCowSwap(addresses.getAddress("AERO"), type(uint256).max)`
- Configure the SlippagePriceChecker for AERO→WETH and AERO→cbBTC (mirror `010_WhitelistWETHStrategyImplementation.sol::_configureRewardTokens`). The owner of `CHAINLINK_SWAP_CHECKER_PROXY` must call these; if that owner is the F-MAMO Safe, add them as Safe actions, else note they are a separate owner tx:
  ```solidity
  ISlippagePriceChecker spc = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));

  // AERO -> WETH : AERO/USD (forward) then ETH/USD (reverse)
  ISlippagePriceChecker.TokenFeedConfiguration[] memory toWeth = new ISlippagePriceChecker.TokenFeedConfiguration[](2);
  toWeth[0] = ISlippagePriceChecker.TokenFeedConfiguration({ chainlinkFeed: addresses.getAddress("CHAINLINK_AERO_USD"), reverse: false, heartbeat: 86400 });
  toWeth[1] = ISlippagePriceChecker.TokenFeedConfiguration({ chainlinkFeed: addresses.getAddress("CHAINLINK_ETH_USD"), reverse: true, heartbeat: 1200 });
  spc.addTokenConfiguration(addresses.getAddress("AERO"), addresses.getAddress("WETH"), toWeth);

  // AERO -> cbBTC : AERO/USD (forward) then BTC/USD (reverse)
  ISlippagePriceChecker.TokenFeedConfiguration[] memory toBtc = new ISlippagePriceChecker.TokenFeedConfiguration[](2);
  toBtc[0] = ISlippagePriceChecker.TokenFeedConfiguration({ chainlinkFeed: addresses.getAddress("CHAINLINK_AERO_USD"), reverse: false, heartbeat: 86400 });
  toBtc[1] = ISlippagePriceChecker.TokenFeedConfiguration({ chainlinkFeed: addresses.getAddress("CHAINLINK_BTC_USD"), reverse: true, heartbeat: 1200 });
  spc.addTokenConfiguration(addresses.getAddress("AERO"), addresses.getAddress("cbBTC"), toBtc);

  spc.setMaxTimePriceValid(addresses.getAddress("AERO"), 3600);
  ```
  Add `import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";` to the proposal.
- Extend `validate()` to assert: `lab.allowedSlippageInBps() == 200`, `lab.compoundAppData() == COMPOUND_APP_DATA`, `address(lab.slippagePriceChecker()) == CHAINLINK_SWAP_CHECKER_PROXY`, `IERC20(AERO).allowance(address(lab), lab.VAULT_RELAYER()) == type(uint256).max`, and `spc.isTokenPairConfigured(AERO, WETH) && spc.isTokenPairConfigured(AERO, cbBTC)`.

- [ ] **Step 3: Drop slotId in the setup test + add compound assertions**

In `test/LPAutoBalancerV2Setup.integration.t.sol`:
- `lab.stake(0)` → `lab.stake()`, `lab.reset(0, params)` → `lab.reset(params)`.
- After `proposal.validate()`, the new compound wiring is asserted inside the proposal's `validate()`; optionally add a direct assertion here that `lab.compoundAppData()` is set.

- [ ] **Step 4: Run the setup proposal test**

Run: `make lp-v2-setup`
Expected: PASS — deploy, build, simulate, validate (now including compound wiring + SlippagePriceChecker config).

- [ ] **Step 5: Verify the deploy smoke test + script still build**

Run: `forge test --mc DeployLPAutoBalancerV2 -vvv` (constructor unchanged, should pass untouched). If the deploy script/test referenced any dropped slotId/getter, fix minimally.

- [ ] **Step 6: Commit**

```bash
git add addresses/8453.json multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol test/LPAutoBalancerV2Setup.integration.t.sol
git commit -m "feat(lpv2): setup proposal wires compounding + AERO slippage config"
```

---

## Task 8: Docs + full suite + format

**Files:**
- Modify: `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md`

- [ ] **Step 1: Update the setup doc**

Edit `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md` to reflect: one contract per pool (no slotId), the `setPool` re-point flow, and the compounding setup (SlippagePriceChecker AERO→WETH/cbBTC config, `setSlippage`, `setCompoundAppData`, `approveCowSwap`, and that the backend calls `compound(compoundBps)`).

- [ ] **Step 2: Run the full LPV2 surface**

Run:
```bash
forge test --mc LPAutoBalancerV2UnitTest -vvv
make lp-auto-balancer-v2
make lp-v2-setup
```
Expected: all green.

- [ ] **Step 3: Format with the CI-pinned nightly forge**

CI pins `nightly-e52076714ace23c7a68e14f0048a40be3c6c8f0b` and `forge fmt` differs across versions. Surface to the user before switching toolchains; do not flip their forge autonomously. Once on the matching forge:

Run: `forge fmt && git diff --stat`
Expected: no churn beyond intended files.

- [ ] **Step 4: Commit**

```bash
git add docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md
git commit -m "docs(lpv2): single-pool + compounding setup"
```

---

## Self-review checklist (run before handing off)

- **Spec coverage:** §3 single-position → Task 1; §3.7 setPool → Task 2; §4a compound/isValidSignature/SlippagePriceChecker → Tasks 3–4; both-legs fold → Tasks 5–6; §6 setup/SlippagePriceChecker config → Task 7; §8 tests distributed across Tasks 1–7; docs → Task 8.
- **AERO/USD feed** is the one external unknown — Task 7 Step 1 verifies it on-chain before use (not a code placeholder).
- **Size budget:** the 24 KB limit is real for this contract (commit `29bce6f`); Tasks 3 & 4 check `--sizes` and fall back to custom errors if needed.
- **No principal swap invariant** preserved: `compound` only ever moves AERO; `isValidSignature` forces `sellToken == AERO`. The unit test `test_noSwapPolicyField` and the adversarial "no principal swap path" assertions remain valid.
- **Type consistency:** `compound(uint16)`, `MAX_COMPOUND_BPS` (uint16), `compoundAppData` (bytes32), `setCompoundAppData`/`setSlippage`/`setSlippagePriceChecker`/`approveCowSwap`, `position` getter, and `CompoundInitiated(uint256,uint256,uint16)` are referenced identically across contract, tests, and proposal.
```