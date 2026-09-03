# Leveraged Aero — Backend integration guide

## The product — Leveraged Aerodrome LP Fund

Leveraged Aerodrome LP fund. Users deposit USDC; the Mamo agent runs a leveraged AERO-farming
position that earns through emissions. Custody and execution are deliberately separate: the fund's share
ledger is a minimal in-repo vault (`LeveragedAeroVault` — shares only, priced off the strategy's NAV),
execution lives in one strategy contract (supply USDC on Moonwell → borrow the CL leg(s) → Aerodrome
concentrated LP → farm & compound AERO, with onchain leverage caps and a permissionless deleverage), and
Mamo's **rebalancer** service is the agent — the same trusted-operator model as Mamo today: it manages the
position but can never withdraw user funds. Users redeem anytime at NAV.

| At a glance | |
|---|---|
| Chain | Base |
| Deposit asset | USDC (ETH & cbBTC added later) |
| Structure | Pooled fund — many depositors, one shared position |
| Strategy | Supply USDC → borrow the CL leg(s) → Aerodrome CL LP → farm & compound AERO |
| Pool shape | Per-clone, derived at init: *two borrowed legs* (e.g. cbBTC + ETH) **or** *asset-as-leg-B* (borrow one volatile leg, pair it with USDC). **Nothing on this integration surface branches on it** — see below. |
| Posture | Leveraged Aerodrome CL LP + AERO emissions carry |
| Custody | Agent manages the position, can never withdraw user funds; users redeem anytime |
| Lifetime | Runs indefinitely — no fixed term; the terminal `Settled` state is driven by the vault owner (MAMO multisig) |

**Where this guide sits.** Mamo users don't touch the fund contracts directly. Each user gets a
per-user **Mamo account** (`MamoLeveragedAeroStrategy`) that custodies their fund shares and exposes a
USDC-in / USDC-out surface. This guide is the backend integration surface for that account system:
provisioning and the `depositIdle` nudge. (Running the fund itself — deploy/compound/re-range/leverage
**and fulfilling async withdrawals** — is the rebalancer's fund-ops surface, a separate runbook:
[`LEVERAGED_AERO_REBALANCER.md`](./LEVERAGED_AERO_REBALANCER.md).)

---

This is the backend contract-integration guide for the **leveraged Aerodrome LP** product. The backend
integrates with the per-user **Mamo account** (`MamoLeveragedAeroStrategy`), its **factory**
(`MamoLeveragedAeroStrategyFactory`), and the **registry** (`MamoStrategyRegistry`). The strategy itself
(`fulfillRedeem` / deployIdle / compound / rerange / adjustLeverage / deleverage — the whole fund-ops
surface) is **not** a backend touchpoint: every one of those is `onlyProposer`, and the proposer is the
**rebalancer**, covered by [`LEVERAGED_AERO_REBALANCER.md`](./LEVERAGED_AERO_REBALANCER.md).

- USDC (6dp) in and out; vault shares are **12dp** (`LeveragedAeroVault.decimals() == assetDecimals + 6`),
  custodied by each account, never handled by users.
- The account is `onlyOwner` for user actions; the backend's contract-level responsibilities are
  **account provisioning** and the optional **`depositIdle` nudge** — that is all.
- **Naming (renamed pre-mainnet):** the account's strategy pointer is the public getter
  `leveragedAeroStrategy()` and the initializer guard is `"Invalid leveragedAeroStrategy address"`;
  the address-book key is `LEVERAGED_AERO_STRATEGY`. It points at the in-repo
  `LeveragedAerodromeCLStrategy` clone. The former `sherwood*` spellings are gone — this ABI break
  landed before the first mainnet deployment, so no live integration is affected.

---

## Pool shape (`legBIsAsset`) — the backend does **not** branch on it

The strategy supports two pool shapes, derived per clone at init and readable as
`strategy.layout().legBIsAsset` (`true` ⇒ the leg-B slot **is** USDC, so the fund borrows one volatile leg
and pairs it with USDC; `false` ⇒ both legs are borrowed). The distinction is real and it changes several
**fund-ops** behaviors — see the rebalancer runbook
([`LEVERAGED_AERO_REBALANCER.md`](./LEVERAGED_AERO_REBALANCER.md) §G).

**On this integration boundary it changes nothing, and that is the load-bearing statement.** Verified
against the code rather than assumed:

| Backend call | Shape-dependent? | Why |
|---|---|---|
| `createStrategyForUser(user)` | No | Account/factory layer; never touches the fund's legs. |
| `depositIdle(assets, minShares)` | No | USDC in, shares out. No unclaimed-proceeds gate: a fulfil pays the user directly, so nothing on the account is ever withdrawal proceeds. **You pick `assets`** — it no longer sweeps the whole idle balance. Deposits land as **idle USDC on the strategy** in both shapes and are deployed later by the proposer's `deployIdle`. Reverts if `assets` exceeds the account's idle balance, or with `FundAtCapacity` if the deposit would push the fund's NAV past `vault.maxTotalAssets()` (see below). |
| `fulfillRedeem(id, minAssetsOut)` | No | Same oracle-free proportional unwind in both shapes: remove `f = shares/supply` of **every** leg, repay `f` of **every** debt, pay the net USDC. Asset-mode does change the *internal* stayer-reservation accounting (leg B's "idle leg" balance **is** the idle USDC, so it is reserved once, not twice) — but that is inside `redeemUnwindImpl`, not on the call surface. |
| `WithdrawRequested` → fulfill loop | No | Same events, same ids, same `FULFILL_WINDOW`. |

So: **do not add a `legBIsAsset` branch to the account keeper.** Read it only if you are surfacing the
fund's composition in ops tooling.

## Fund capacity cap

`LeveragedAeroVault.maxTotalAssets` is a ceiling on the **whole fund's NAV**, denominated in USDC
(6dp). `0` means unlimited (the deploy default). Only the vault owner (MAMO_MULTISIG) can change it.

It is a limit on the FUND, not on any one user: once the book reaches the ceiling, **nobody** can
deposit, regardless of how little their own account holds. It is enforced in the strategy's `deposit`
— the single path every share-minting deposit takes, accounts and direct depositors alike — and it
**reverts** rather than trimming:

```
deposit(assets, minShares)        → reverts FundAtCapacity(navAfter, cap)
depositIdle(assets, minShares)    → reverts FundAtCapacity(navAfter, cap)
```

That is why `depositIdle` takes an amount. When the fund is near its ceiling, an account holding more
idle USDC than the remaining capacity cannot deposit the whole balance, so the keeper sizes the call
to the room:

```
room = vault.remainingCapacity()   // USDC (6dp). type(uint256).max => cap disabled
                                   // 0 => fund is full, do not call
```

**Leave headroom — do not size to the exact edge.** Both sides now read the same `nav()` and the guard
is strict (`navPre + assets > cap`), so a same-block deposit of exactly `room` passes — but NAV moves
between your read and your transaction landing. Target ~95% of `room` and treat `FundAtCapacity`
as **retryable** (re-read and re-size, do not escalate). Leftover idle USDC stays on the account and
the owner can sweep it via `claimWithdrawnUsdc` at any time.

Three properties worth building around:

- **The ceiling is in USDC, so it means what it says** — no share conversion, no 12dp/6dp trap.
- **NAV moves on its own.** The fund can drift *above* the ceiling on gains alone, closing deposits
  with nobody having deposited, and back below it on a drawdown, reopening them. Do not treat "closed"
  as permanent, and do not cache `remainingCapacity()`.
- **Withdrawals free room, for everyone.** The check is against live NAV, not a high-water mark, so an
  exit immediately reopens that much capacity to any depositor. There is no release step.

`vault.previewSharesForAssets(assets)` remains the assets→shares conversion for sizing `minShares`; it
**reverts** `"LAV: nav unpriceable"` when the book cannot be priced (`nav() == 0` with shares
outstanding, e.g. post-settle). Treat that as "retry later", never as a usable number.

Two fund-ops reads exist for that tooling and are worth knowing about even though this doc's loop does not
call them — both are plain views on the strategy clone:

```solidity
function targetLtvBps() external view returns (uint16);                   // standing target LTV
function hedgedDebt() external view returns (uint128 legA, uint128 legB); // hedged borrow principal per leg
```

`hedgedDebt().legB` is structurally **0** in asset-mode (leg B is the unit of account and is never
borrowed) — treat a zero there as "shape", not as "missing data".

**One place the shape leaks into the SLA loop indirectly.** Step 2 of the keeper loop below optionally
levers **down** before a fulfill. That direction is safe in both shapes and, in asset-mode, actually
*frees* idle USDC. Levering **up** is the asymmetric one — in asset-mode it **consumes** idle USDC and
reverts `InsufficientIdleForLeverUp(needed, available)` if the book is short — but lever-up is not part of
the fulfill loop and belongs to the fund-ops runbook. If the same service ever drives both, size lever-ups
against available idle.

---

## Two distinct BACKEND_ROLE domains — do not conflate

There are two separate `BACKEND_ROLE` grants, in two different contracts, resolved differently. Ops must
know which key each call needs.

| Domain | Contract | Role holder | What it authorizes |
|---|---|---|---|
| Factory backend | `MamoLeveragedAeroStrategyFactory.BACKEND_ROLE` | `MAMO_BACKEND` (granted at construction) | `createStrategyForUser` on behalf of a user |
| Registry backend | `MamoStrategyRegistry.BACKEND_ROLE` | **the factory contract** holds it (so `addStrategy` succeeds inside creation) | `addStrategy`, and it is the address `getBackendAddress()` resolves for the `depositIdle` gate |

`MamoLeveragedAeroStrategyFactory.BACKEND_ROLE == keccak256("BACKEND_ROLE")` and
`MamoStrategyRegistry.BACKEND_ROLE == keccak256("BACKEND_ROLE")` are the same constant, but they are
**independent role sets on independent contracts**. The factory itself is a registry-backend member so
that `createStrategyForUser` can call `registry.addStrategy` internally.

### The `depositIdle` gate resolves a *specific* registry member (verified live)

```solidity
// MamoLeveragedAeroStrategy.depositIdle
require(msg.sender == owner() || msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not owner or backend");

// MamoStrategyRegistry.getBackendAddress
function getBackendAddress() external view returns (address) {
    return getRoleMember(BACKEND_ROLE, 0); // ROLE MEMBER AT INDEX 0 — not "any backend member"
}
```

`getBackendAddress()` returns **only role member index 0**, not any BACKEND_ROLE holder. On the current
Base registry that is `0x7cb24EFA3fe76650388145b9B0823De6600f1f4c` (the registry has 7 BACKEND_ROLE
members; index ≠ 0 members do **not** pass the `depositIdle` gate). This is **not** the
`MAMO_BACKEND` address-book entry. So:

| Action | Key that must sign | Address (Base) | Whose key |
|---|---|---|---|
| `createStrategyForUser(user)` on the factory | factory BACKEND_ROLE = `MAMO_BACKEND` | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` | backend |
| `depositIdle(assets, minShares)` on an account | registry BACKEND_ROLE **member 0** | `0x7cb24EFA3fe76650388145b9B0823De6600f1f4c` | backend |
| `fulfillRedeem(id, minAssetsOut)` on the strategy | strategy **proposer** = `MAMO_REBALANCER` | `0x73f6B456d063F78129113D42DBC315b9eEee8FAf` | **rebalancer — NOT the backend** |

Signing `depositIdle` with a non-index-0 backend key reverts `"Not owner or backend"`. Wire the keys
explicitly, and note that the two backend keys above are **different addresses**.

> ### ⚠️ The strategy `proposer` is the REBALANCER, not `MAMO_BACKEND`
>
> Earlier revisions of this guide claimed the backend was the strategy's proposer. **That was wrong.** The
> strategy has exactly one operator role (`proposer`, set per clone at
> `initialize(vault_, proposer_, data)` and rotatable thereafter by the vault owner via
> `LeveragedAeroVault.setProposer` — read `proposer()` live, do not cache it), and it is held by a
> **dedicated rebalancer address**
> (`MAMO_REBALANCER`, `pooled.proposer` in `script/tenderly/leveraged-aero-vnet.json`) — deliberately
> **not** `MAMO_BACKEND`. The split is the point: account-layer keys must not reach the levered book's
> operator surface.
>
> **`fulfillRedeem` is `onlyProposer`, so the REBALANCER fulfils user withdrawal requests — not the
> backend.** The backend drives the account layer (`createStrategyForUser`, `depositIdle`); the rebalancer
> drives the strategy (`compound`, `rerange`, `adjustLeverage`, `fulfillRedeem`). Confirm with
> `strategy.proposer()` before wiring any keeper.
>
> ### The operations / policy split — `proposer` is operations only
>
> **The `proposer` role IS the rebalancer** (we deliberately did not rename it) and it covers
> **operations** only. Fund **policy** sits behind a second, derived role: **`admin` ==
> `Ownable(vault()).owner()`, the MAMO multisig** — no stored field, no setter, it simply follows the
> vault owner. The gate is `onlyAdmin` → `NotAdmin()`.
>
> The principle: **the backend/keeper must not be capable of rugging you — RAISING fund risk is
> multisig-only.** Admin-only entrypoints on the strategy are **`setTargetLtv(uint16)`** (the fund's
> standing target LTV, either direction) and **`rescueToVault(address)`** (stray-token sweep; the
> proposer could previously call this and can no longer). Neither is a backend touchpoint; both are
> listed so the role model is unambiguous.
>
> ### The direction rule
>
> **The admin owns the standing target; the proposer only moves the book underneath it.** Policy is
> written by **`setTargetLtv(uint16)`** alone. The proposer's **`adjustLeverage(uint16 targetBps, ...)`**
> (`0x9792419f`) takes a per-call target that is capped at the stored one — `TargetLtvExceedsPolicy(uint16
> requested, uint16 policy)` (`0x614db9b8`) above it — and **never persisted**. So a compromised keeper key
> can never raise fund risk past policy and never move tokens; it *can* keep de-levering and destroy
> yield, which is bounded, transient (the next `deployIdle`/`compound` sizes at the stored target again),
> and reversible with one `adjustLeverage` back at policy. This is what
> keeps the 2-day fulfil SLA off the multisig's critical path (see "SLA — the 2-day deadman" below).
>
> **ABI note for anyone remapping selectors:** `adjustLeverage` has its target parameter back —
> `adjustLeverage(uint256,uint256)` (`0x4be1cadd`) → `adjustLeverage(uint16,uint256,uint256)`
> (`0x9792419f`), the original selector. The target is a per-call argument again, but capped at the
> stored policy target and never persisted, and **`lowerTargetLtv(uint16)` (`0xbd41b78c`) is removed**.
> This is a rebalancer-surface change; the account layer (`MamoLeveragedAeroStrategy`) is **unaffected**.

---

## Account provisioning

```solidity
// MamoLeveragedAeroStrategyFactory — callable by factory BACKEND_ROLE or by `user`
function createStrategyForUser(address user) public returns (address strategy);
function createStrategy(address user) external returns (address strategy);   // alias, same body
function computeStrategyAddress(address user) public view returns (address); // CREATE2 precompute
```

- Deterministic address, salt `keccak256(abi.encodePacked(user))`; precompute with
  `computeStrategyAddress` and treat `code.length == 0` as not-yet-created.
- Inside creation the factory CREATE2-deploys the `ERC1967Proxy`, calls `initialize`, and registers via
  `registry.addStrategy(user, strategy)` (this is why the factory holds registry `BACKEND_ROLE`).
- After creation `account.owner() == user`; the account is registered under the user in the registry.
- Idempotency: re-creating reverts `"Strategy already exists"`; guard with `computeStrategyAddress`.

Revert strings: `"Invalid user address"`, `"Only backend or user can create strategy"`,
`"Strategy already exists"`.

---

## Async withdrawals — the backend does NOT fulfil them

There is **no** backend touchpoint on the strategy. `fulfillRedeem` is `onlyProposer` and the proposer is
the **rebalancer** (`MAMO_REBALANCER`), so the fulfil loop belongs to the fund-ops keeper documented in
[`LEVERAGED_AERO_REBALANCER.md`](./LEVERAGED_AERO_REBALANCER.md) §C:

```solidity
// LeveragedAerodromeCLStrategy (ERC-1167 clone) — onlyProposer (rebalancer), requires state == Executed
function fulfillRedeem(uint256 id, uint256 minAssetsOut) external;
```

The account's `ILeveragedAeroCLStrategy` interface **deliberately omits** `fulfillRedeem` for exactly this
reason: it is out of the wrapper's surface and out of the backend's. Calling it with a backend key reverts
`NotProposer()`.

What the backend **does** own here is **observability** — the async flow is the user's slowest path, so the
backend indexes it and drives product state / notifications off it, and escalates to the rebalancer when the
SLA is at risk. Strategy events for that (note: `owner` here is the **Mamo account address**, i.e. the
`msg.sender` that escrowed the shares — not the end user; `recipient` is the address the fulfil PAYS,
which for a Mamo account is the account's `owner()`, i.e. the end user):

| Event | Meaning |
|---|---|
| `RedeemRequested(uint256 indexed id, address indexed owner, address indexed recipient, uint256 shares)` | request escrowed (owner = account, recipient = end user) |
| `RedeemFulfilled(uint256 indexed id, address indexed owner, address indexed recipient, uint256 assetsOut)` | **rebalancer** fulfilled; USDC paid to `recipient` — the withdrawal is COMPLETE |
| `RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares)` | request cancelled by the account owner |
| `RedeemEmergency(uint256 indexed id, address indexed owner, uint256 assetsOut)` | deadman self-fulfill after the window |

### Who does what

```mermaid
sequenceDiagram
    participant A as User account
    participant BE as Mamo backend (account layer)
    participant RB as Rebalancer keeper (proposer)
    participant S as Strategy (LeveragedAerodromeCL)

    A-->>BE: WithdrawRequested(id, shares, minAssetsOut)   (account event — backend indexes it)
    A-->>RB: RedeemRequested(id, account, owner, shares)   (strategy event — the keeper trigger)
    Note over RB: if the unwind needs it, RB runs adjustLeverage at a lower per-call target (≤ policy) — no multisig
    RB->>S: fulfillRedeem(id, minAssetsOut)                              (PROPOSER key = rebalancer)
    S-->>U: pays USDC to the request's RECIPIENT (the account's owner) + RedeemFulfilled(id, account, owner, assetsOut)
    Note over BE: backend observes RedeemFulfilled and updates product state — the withdrawal is COMPLETE
```

1. The backend watches each account's `WithdrawRequested(id, shares, minAssetsOut)` (equivalently the
   strategy's `RedeemRequested(id, account, recipient, shares)`) for UX/product state — **not** to fulfil it.
2. The book is optionally levered **down** first so the oracle-free proportional unwind self-funds its IL
   — a **single-actor** step: the rebalancer runs `adjustLeverage(lowerTarget, minLiq, minOut)` and then
   `fulfillRedeem(id, minAssetsOut)` — both with the **proposer** key, no multisig on the path, and the
   restore afterwards is the same call at `targetLtvBps()`.
3. **USDC goes straight to the user.** `requestWithdraw` names the account's `owner()` as the pooled
   request's `recipient`, so `fulfillRedeem` transfers the payout to that address. There is no second
   claim transaction, and no USDC rests on the account.
4. Confirm downstream via the strategy's `RedeemFulfilled(id, account, recipient, assetsOut)` — that
   event *is* the completion, not a signal that a claim is now due.

### SLA — the 2-day deadman

`FULFILL_WINDOW = 2 days`. If the **rebalancer** does not fulfil within that window, the request owner (the
account, owner-gated) can trustlessly self-service via `emergencyWithdraw(id, minAssetsOut)` →
`emergencyRedeem` (oracle-free proportional unwind). 2 days is the hard fulfillment SLA — it is the
rebalancer's to meet, and the backend's to alert on: unfulfilled requests become user-executable and remove
the operator from the loop.

**No multisig signature sits inside that window.** The pre-fulfil de-risk is one proposer-only
`adjustLeverage` at a lower per-call target, so the SLA never depends on assembling multisig signers —
and neither does restoring the book, which is the same call at the untouched `targetLtvBps()`.

---

## `depositIdle` — no unclaimed-withdrawal gate any more

```solidity
function depositIdle(uint256 assets, uint256 minShares) external returns (uint256 shares); // owner OR registry backend member 0
function hasSettledRequest()      external view returns (bool);   // a tracked request has COMPLETED
function openRequestIds()         external view returns (uint256[] memory);
function syncRedeemRequests()     external;                       // owner-only housekeeping
```

Idle USDC on an account used to be **ambiguous** — funds a user plain-transferred for re-deposit, or the
payout of a fulfilled async withdrawal awaiting `claimWithdrawnUsdc()` — so a BACKEND `depositIdle`
reverted `"Unclaimed withdrawal proceeds"` while any tracked request read `settled`.

**That gate is gone, because the ambiguity is gone.** A fulfil now pays the account's `owner()` directly
and the fast/emergency paths forward in the same transaction, so **no withdrawal proceeds ever rest on an
account**. Idle USDC there is always money someone transferred in — exactly what `depositIdle` is for.
`"Unclaimed withdrawal proceeds"` is no longer a reachable revert; drop any pre-check for it.

What replaced it:

- **Nothing gates the backend** beyond the caller check and the amount/balance checks. Both callers
  `_pruneSettled()` on the way through, so a completed request can never strand a tracked id.
- **`hasSettledRequest()` is a COMPLETION SIGNAL, not a gate**, and BEST-EFFORT: your own `depositIdle`
  prunes, which clears it. The durable records are the account's `WithdrawSettled(id)` and the strategy's
  `RedeemFulfilled`. It claims nothing and blocks nothing.
- **`hasUnclaimedWithdrawal()` is REMOVED**, not aliased — calls to it no longer compile. Deliberate
  pre-deploy ABI break: leaving a stub that always reads `false` would have hidden the change, and a stub
  that tracked `settled` would stall any backend still applying the old "skip `depositIdle` while true"
  rule (it declines, and its own `depositIdle` was one of the calls that prunes). Use `hasSettledRequest()`
  for completion, or better the `WithdrawSettled` event below.
- **`recoverERC20` no longer deadlocks anything** — it can leave a stale tracked id, and that is inert.
  `syncRedeemRequests()` (owner-only) still prunes explicitly if you want the set tidy.
- **`requestWithdraw` is capped** at `MAX_OPEN_REQUESTS` (16) simultaneously-tracked requests; it prunes
  settled ids first, so only genuinely OUTSTANDING requests consume the budget. A 17th outstanding
  request reverts `"Too many open requests"`.

**Rule (unchanged):** the backend calls `depositIdle` **only on explicit user/product intent to
re-deposit** — never as an automatic idle-USDC sweep.

---

## Account entrypoints the backend touches

| Call | Contract | Gate | Notes |
|---|---|---|---|
| `createStrategyForUser(user)` | Factory | factory BACKEND_ROLE or `user` | provisioning; deterministic address |
| `depositIdle(assets, minShares)` | Account | owner OR registry backend member 0 | only on explicit re-deposit intent; **you pick `assets`**; no unclaimed-proceeds gate any more |

That is the whole backend write surface. `fulfillRedeem(id, minAssetsOut)` on the strategy clone is **not** on it —
`onlyProposer`, i.e. the **rebalancer** (`MAMO_REBALANCER`), never `MAMO_BACKEND`.

Account entrypoints the backend does **not** call (owner-only, for reference): `deposit` (permissionless,
but normally user-driven), `withdraw` / `withdrawAll` / `requestWithdraw` / `cancelWithdraw` /
`emergencyWithdraw` / `claimWithdrawnUsdc` / `recoverERC20` — all `onlyOwner`.

---

## Events the backend indexes

Account (`MamoLeveragedAeroStrategy`):

| Event | Use |
|---|---|
| `Deposit(address indexed depositor, uint256 assets, uint256 shares)` | fund inflows (deposit/depositIdle) |
| `Withdraw(address indexed owner, uint256 shares, uint256 assetsOut)` | fast-path exits |
| `WithdrawRequested(uint256 indexed id, uint256 shares, uint256 minAssetsOut)` | pending async withdrawal — product state + SLA alerting (the `fulfillRedeem` trigger itself is the **rebalancer's**) |
| `WithdrawCancelled(uint256 indexed id)` | request cancelled — drop it from the pending set |
| `WithdrawEmergency(uint256 indexed id, uint256 assetsOut)` | deadman fired (backend missed SLA) |
| `WithdrawSettled(uint256 indexed id)` | a tracked request completed and was untracked — the account-side completion record |
| `UsdcClaimed(uint256 amount)` | owner swept idle USDC off the account (a plain transfer, or a deposit remainder) — **not** a withdrawal claim any more |

Factory: `StrategyCreated(address indexed user, address indexed strategy)`.

Registry: `StrategyAdded(address indexed user, address strategy, address implementation)`,
`StrategyOwnerUpdated(address indexed strategy, address indexed oldOwner, address indexed newOwner)`.

Strategy: `RedeemRequested` / `RedeemFulfilled` / `RedeemCancelled` / `RedeemEmergency` (table
above) — use these when indexing the strategy clone directly rather than per-account.

---

## Revert-string reference

Account (`require` strings): `"Amount must be greater than 0"`, `"Insufficient idle USDC"`,
`"Not owner or backend"`, `"No shares to withdraw"`, `"No USDC to claim"`; OZ
`OwnableUnauthorizedAccount(address)` for `onlyOwner` misuse; initializer strings
`"Invalid mamoStrategyRegistry address"`, `"Strategy type id not set"`, `"Invalid owner address"`,
`"Invalid leveragedAeroStrategy address"`, `"Invalid usdc address"`, `"Invalid vault address"`.

Factory: `"Invalid user address"`, `"Only backend or user can create strategy"`,
`"Strategy already exists"` (plus constructor guards `"Invalid admin address"`,
`"Invalid mamoBackend address"`, `"Invalid mamoStrategyRegistry address"`,
`"Invalid strategyImplementation address"`, `"Implementation must be a contract"`,
`"Strategy type id not set"`, `"Invalid leveragedAeroStrategy address"`, `"Invalid usdc address"`).

Strategy (custom errors, decode by selector): `NotExecuted()`,
`FastRedeemExceedsLtv(uint256 ltvBps, uint256 maxLtvBps)`, `FulfillWindowOpen()`, `RequestSettled()`,
`NotRequestOwner()`, plus `onlyProposer` gate on `fulfillRedeem`.

Vault (`LeveragedAeroVault`, `require` strings the backend can hit): `"LAV: deposits closed"` — every
share mint, including `deposit`/`depositIdle` through an account, while the vault owner has
`depositsOpen == false`. It is the **only** issuance gate (no depositor whitelist, no pause), and
withdrawals are deliberately not gated on it, so the rebalancer's fulfil loop is unaffected. Read `depositsOpen()`
before a `depositIdle` nudge and treat the revert as retryable, not as a bad request.

---

## Vault lifecycle — what gates the backend's calls

The strategy's `Pending → Executed → Settled` lifecycle is driven by the **vault owner** (MAMO multisig)
via `activateStrategy(seed)` and `settleStrategy()`. There is no proposal, vote, or external governance
in the path any more. Operationally for the backend:

- `deposit` / `depositIdle` / `fulfillRedeem` all require `Executed` — before activation and after
  settlement they revert `NotExecuted()`.
- After `settleStrategy()` the whole book is unwound and the realized USDC sits on the **vault**. Holders
  exit permissionlessly with `vault.redeemSettled(shares)`, which needs the shares in the caller's own
  wallet — i.e. each account owner first pulls them out with `recoverERC20(vaultShares, owner, …)`. The
  backend has **no role** in the Settled exit; drop accounts from the async watch list once state is
  `Settled`.

---

## Staging

> **The staging instance runs the AUDITED build** (vault generation 3), redeployed 2026-08-25 (`6d25f5f`):
> `LeveragedAeroVault` replaces Sherwood's `SyndicateVault`, so `depositsOpen()` / `setOpenDeposits` /
> `activateStrategy` / `settleStrategy` / `redeemSettled` are all the in-repo ones, and the vault carries
> the fund capacity cap (`maxTotalAssets()` / `remainingCapacity()`) the strategy's deposit path checks.
> The direct-pay `fulfillRedeem(uint256,uint256)` documented above (the payout goes to the request's
> `recipient`, i.e. the account's owner) is live here, and the `depositIdle` unclaimed-proceeds gate is
> gone with the state it guarded — the account-layer harness drives both end to end on every run. No
> governor, no proposal lifecycle.
>
> ⚠️ **`script/tenderly/leveraged-aero-vnet.json` is the source of truth**, not this table — a harness
> redeploy changes these addresses (and a new pooled layer invalidates the account factory, which binds the
> strategy clone at construction). Read the config and `docs/LEVERAGED_AERO_VNET_RUNBOOK.md` before wiring
> an environment.

| Field | Value | Config key |
|---|---|---|
| Network | Base fork (Tenderly Virtual TestNet), **custom** chainId `73578453` (parent Base `8453`) | `chainId` |
| RPC (public, read-only) | `https://virtual.base.eu.rpc.tenderly.co/b5ec5ea9-e5ea-4e06-a9a6-21310065d282` | `publicRpc` |
| Admin RPC (writes) | **1Password** (write-capable — never committed to this repo) | `adminRpc` |
| Factory | `0x70707eb4337FAB8043ea737Fa16a14A90Ad1C440` | `mamo.accountFactory` |
| Account implementation | `0x0EE12E97Fe2b176dB30A00bcE0cDe2699b7F4b8f` | `mamo.accountImplementation` |
| Registry | `0x46a5624C2ba92c08aBA4B206297052EDf14baa92` | `mamo.strategyRegistry` |
| Strategy type id | `5` | `strategyTypeId` |
| Vault (`LeveragedAeroVault`, shares 12dp) | `0x461BdB37099A30dD5242F7216B440Fcc1C38b9cC` | `pooled.vault` |
| Strategy clone | `0xf72Dd040A1af43e25C3f1B330F5fbc7b909e8008` | `pooled.strategyClone` |
| Strategy `proposer` (rebalancer — fulfils redeems) | `0x73f6B456d063F78129113D42DBC315b9eEee8FAf` | `pooled.proposer` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `usdc` |

> **The chain id is deliberately not `8453`.** Sign and broadcast against `73578453` (Tenderly's `7357`
> prefix + the parent network); fork *state* is still Base, so every venue address resolves unchanged.
> Anything that derives a chain id from "this is a Base fork" will produce invalid signatures here.

---

## Backend checklist

- [ ] Provision accounts via `createStrategyForUser` with the factory `MAMO_BACKEND` key (`0x2Ab0…5e73`); guard with `computeStrategyAddress`.
- [ ] Sign `depositIdle` with registry BACKEND_ROLE **member 0** (`0x7cb2…1f4c`), and only on explicit re-deposit intent — never as an auto-sweep.
- [ ] Do **not** wire a backend key to `fulfillRedeem` — it is `onlyProposer` (the **rebalancer**, `0x73f6…8FAf`) and reverts `NotProposer()` for the backend.
- [ ] Index `WithdrawRequested` / `RedeemFulfilled` / `UsdcClaimed` for product state, and alert the rebalancer when a request nears its SLA.
- [ ] Treat `FULFILL_WINDOW = 2 days` as the (rebalancer's) fulfillment SLA; monitor for `WithdrawEmergency` (missed SLA).
- [ ] Gate deposit nudges on `strategy.state() == Executed` **and** `vault.depositsOpen()`; treat `"LAV: deposits closed"` as retryable.
- [ ] Stop nudging deposits once the strategy is `Settled` — exits then run owner-side via `recoverERC20` + `vault.redeemSettled`, with no backend involvement.
