# Leveraged Aero — Backend integration guide

This is the backend contract-integration guide for the **leveraged Aerodrome LP** product. The backend
integrates with the per-user **Mamo account** (`MamoLeveragedAeroStrategy`), its **factory**
(`MamoLeveragedAeroStrategyFactory`), and the **registry** (`MamoStrategyRegistry`) — **plus exactly one
Sherwood strategy touchpoint** (`fulfillRedeem`, below). Everything else about the Sherwood strategy
(deployIdle / compound / rerange / adjustLeverage / deleverage — the fund-ops surface) is a separate
concern covered by the fund-ops runbook, not this integration boundary.

- USDC (6dp) in and out; vault shares are **12dp**, custodied by each account, never handled by users.
- The account is `onlyOwner` for user actions; the backend's contract-level responsibilities are
  **account provisioning**, the optional **`depositIdle` nudge**, and **`fulfillRedeem` of async
  withdrawals**.

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

| Backend action | Key that must sign | Address (Base) |
|---|---|---|
| `depositIdle(minShares)` on an account | registry BACKEND_ROLE **member 0** | `0x7cb24EFA3fe76650388145b9B0823De6600f1f4c` |
| `fulfillRedeem(id)` on the Sherwood strategy | Sherwood **proposer** = `MAMO_BACKEND` | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` |
| `createStrategyForUser(user)` on the factory | factory BACKEND_ROLE = `MAMO_BACKEND` | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` |

Signing `depositIdle` with the proposer key (or any non-index-0 backend key) reverts `"Not owner or
backend"`. Wire the two keys explicitly.

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

## The one Sherwood touchpoint — `fulfillRedeem`

Async withdrawals are the only place the backend reaches past the Mamo account into the Sherwood
strategy. The account's `ILeveragedAeroCLStrategy` interface **deliberately omits** `fulfillRedeem` (it
is a proposer-only op, out of the wrapper's surface), so the backend calls it on the Sherwood strategy
clone directly, as the strategy **proposer**:

```solidity
// LeveragedAerodromeCLStrategy (Sherwood clone) — onlyProposer, requires state == Executed
function fulfillRedeem(uint256 id) external;
```

Sherwood strategy events for indexing (note: `owner` here is the **Mamo account address**, i.e. the
`msg.sender` that escrowed the shares — not the end user):

| Event | Meaning |
|---|---|
| `RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares)` | request escrowed (owner = account) |
| `RedeemFulfilled(uint256 indexed id, address indexed owner, uint256 assetsOut)` | backend fulfilled; USDC paid to the account |
| `RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares)` | request cancelled by the account owner |
| `RedeemEmergency(uint256 indexed id, address indexed owner, uint256 assetsOut)` | deadman self-fulfill after the window |

### Keeper loop

```mermaid
sequenceDiagram
    participant A as User account
    participant B as Backend keeper (proposer)
    participant S as Sherwood strategy

    A-->>B: WithdrawRequested(id, shares, minAssetsOut)   (account event)
    Note over B: optionally deleverage first (adjustLeverage) — fund-ops concern, separate runbook
    B->>S: fulfillRedeem(id)                              (proposer key)
    S-->>A: pays USDC to the account (idle) + RedeemFulfilled(id, account, assetsOut)
    Note over A: owner then sweeps via claimWithdrawnUsdc() → UsdcClaimed(amount)
```

1. Watch each account's `WithdrawRequested(id, shares, minAssetsOut)` (equivalently the strategy's
   `RedeemRequested(id, account, shares)`). The `id` is the strategy request id — pass it straight to
   `fulfillRedeem`.
2. Optionally deleverage first so the oracle-free proportional unwind self-funds its IL (via
   `adjustLeverage` — **fund-ops**, separate runbook; not part of this integration surface).
3. `fulfillRedeem(id)` with the **proposer** key. USDC lands on the account; the owner claims it with
   `claimWithdrawnUsdc()`.
4. Confirm downstream via the account's `UsdcClaimed(amount)` (owner-initiated) or the strategy's
   `RedeemFulfilled`.

### SLA — the 2-day deadman

`FULFILL_WINDOW = 2 days`. If the backend does not fulfill within that window, the request owner (the
account, owner-gated) can trustlessly self-service via `emergencyWithdraw(id, minAssetsOut)` →
`emergencyRedeem` (oracle-free proportional unwind). Treat 2 days as the hard fulfillment SLA:
unfulfilled requests become user-executable and remove the backend from the loop.

---

## `depositIdle` — coordination footgun (documented in the contract)

```solidity
function depositIdle(uint256 minShares) external returns (uint256 shares); // owner OR registry backend member 0
```

Idle USDC on an account is **ambiguous**: it may be funds a user plain-transferred for re-deposit, **or**
the payout of a fulfilled async withdrawal that is waiting for the owner's `claimWithdrawnUsdc()`. A
permissionless `depositIdle` would let anyone front-run the owner's claim and force a fulfilled
withdrawal back into the leveraged position (repeatable re-lock griefing) — which is why the call is
gated to the owner or registry backend member 0.

**Rule:** the backend calls `depositIdle` **only on explicit user/product intent to re-deposit** — never
as an automatic idle-USDC sweep. There is no on-chain flag distinguishing "re-deposit" from "awaiting
claim" idle USDC; the owner and backend coordinate off-chain which idle balance is which. Auto-sweeping
would silently re-lock users' fulfilled withdrawals.

---

## Account entrypoints the backend touches

| Call | Contract | Gate | Notes |
|---|---|---|---|
| `createStrategyForUser(user)` | Factory | factory BACKEND_ROLE or `user` | provisioning; deterministic address |
| `depositIdle(minShares)` | Account | owner OR registry backend member 0 | only on explicit re-deposit intent |
| `fulfillRedeem(id)` | Sherwood strategy | proposer (`MAMO_BACKEND`) | the one Sherwood touchpoint |

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
| `WithdrawRequested(uint256 indexed id, uint256 shares, uint256 minAssetsOut)` | **keeper trigger** for `fulfillRedeem` |
| `WithdrawCancelled(uint256 indexed id)` | request cancelled — drop from the fulfill queue |
| `WithdrawEmergency(uint256 indexed id, uint256 assetsOut)` | deadman fired (backend missed SLA) |
| `UsdcClaimed(uint256 amount)` | owner swept fulfilled USDC |

Factory: `StrategyCreated(address indexed user, address indexed strategy)`.

Registry: `StrategyAdded(address indexed user, address strategy, address implementation)`,
`StrategyOwnerUpdated(address indexed strategy, address indexed oldOwner, address indexed newOwner)`.

Sherwood strategy: `RedeemRequested` / `RedeemFulfilled` / `RedeemCancelled` / `RedeemEmergency` (table
above) — use these when indexing the strategy clone directly rather than per-account.

---

## Revert-string reference

Account (`require` strings): `"Amount must be greater than 0"`, `"No idle USDC to deposit"`,
`"Not owner or backend"`, `"No shares to withdraw"`, `"No USDC to claim"`; OZ
`OwnableUnauthorizedAccount(address)` for `onlyOwner` misuse; initializer strings
`"Invalid mamoStrategyRegistry address"`, `"Strategy type id not set"`, `"Invalid owner address"`,
`"Invalid sherwoodStrategy address"`, `"Invalid usdc address"`, `"Invalid vault address"`.

Factory: `"Invalid user address"`, `"Only backend or user can create strategy"`,
`"Strategy already exists"` (plus constructor guards `"Invalid admin address"`,
`"Invalid mamoBackend address"`, `"Invalid mamoStrategyRegistry address"`,
`"Invalid strategyImplementation address"`, `"Implementation must be a contract"`,
`"Strategy type id not set"`, `"Invalid sherwoodStrategy address"`, `"Invalid usdc address"`).

Sherwood strategy (custom errors, decode by selector): `NotExecuted()`,
`FastRedeemExceedsLtv(uint256 ltvBps, uint256 maxLtvBps)`, `FulfillWindowOpen()`, `RequestSettled()`,
`NotRequestOwner()`, plus `onlyProposer` gate on `fulfillRedeem`.

---

## Staging

| Field | Value |
|---|---|
| Network | Base fork (Tenderly Virtual TestNet) — **current staging instance, rotates** |
| RPC | `https://virtual.base.eu.rpc.tenderly.co/70a4990f-6686-4536-8237-ad9103acd11b` |
| Factory | `0x9CDBe7DB9F967E793E7261e0ffd546E5D29b476f` |
| Account implementation | `0x3F26d1E36310442453d3aefCf75d5817eceBCF29` |
| Strategy type id | `5` |
| Sherwood vault (shares, 12dp) | `0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9` |
| Sherwood strategy clone | `0x168ac730AB0DA6FCDE8aA26e33eac4aE6c8CfB4B` |

Staging endpoints rotate — re-read the current instance from `docs/LEVERAGED_AERO_VNET_RUNBOOK.md` before
wiring an environment.

---

## Backend checklist

- [ ] Provision accounts via `createStrategyForUser` with the factory `MAMO_BACKEND` key; guard with `computeStrategyAddress`.
- [ ] Sign `depositIdle` with registry BACKEND_ROLE **member 0** (`0x7cb2…1f4c`), and only on explicit re-deposit intent — never as an auto-sweep.
- [ ] Sign `fulfillRedeem` with the Sherwood **proposer** key (`MAMO_BACKEND`, `0x2Ab0…5e73`).
- [ ] Keeper watches `WithdrawRequested`, (optionally deleverages), `fulfillRedeem(id)`, confirms via `RedeemFulfilled` / `UsdcClaimed`.
- [ ] Treat `FULFILL_WINDOW = 2 days` as the fulfillment SLA; monitor for `WithdrawEmergency` (missed SLA).
