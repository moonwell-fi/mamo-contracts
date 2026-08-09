# Tasks: add-account-share-cap

> Branch note: the leveraged-aero contracts live on `feat/venue-migration` (branched from
> `feat/leveraged-aero-vanilla-vault`). Branch this work from there, or from whatever lands on `main`
> first — this change touches `LeveragedAeroVault.sol` and `MamoLeveragedAeroStrategy.sol` only, so it
> does not conflict with the venue-migration diff (which is confined to `src/leveraged-aero/`).

## 1. Vault: the cap value

- [x] 1.1 Add `maxSharesPerAccount` (uint256, vault shares 12dp) to `LeveragedAeroVault`, with a `setMaxSharesPerAccount(uint256)` gated `onlyOwner` and a `MaxSharesPerAccountSet(uint256)` event; document `0` as the unlimited sentinel and point at `depositsOpen` as the separate freeze switch
- [x] 1.2 Add the ops conversion view (USDC 6dp → shares 12dp at current pricing, mirroring the strategy's `mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navNet + 1)`); document it as advisory/point-in-time, not a peg
- [x] 1.3 Tests: owner sets and re-sets; non-owner reverts; event carries the value; `0` reads back as unlimited

## 2. Account: partial idle deposit

- [x] 2.1 **BREAKING** — change `depositIdle(uint256 minShares)` to `depositIdle(uint256 assets, uint256 minShares)`; require `assets > 0` and `assets <= usdc.balanceOf(address(this))`; keep the existing owner-or-backend gate and the `Deposit` event
- [x] 2.2 Tests: partial deposit leaves the remainder idle and owner-withdrawable; amount above the idle balance reverts; zero reverts; non-owner/non-backend still reverts

## 3. Account: cap enforcement

- [x] 3.1 Add a shared internal check called after `sherwoodStrategy.deposit` returns in BOTH `deposit` and `depositIdle` (post-hoc per design D3): read `maxSharesPerAccount` off the vault via the existing `vaultShares` pointer, skip when `0`, revert with a typed error carrying (held, cap) when `vaultShares.balanceOf(address(this))` exceeds it
- [x] 3.2 Tests — enforcement: deposit that would exceed reverts (no shares minted, no USDC moved); deposit landing exactly at the cap succeeds; `depositIdle` over the cap reverts with idle untouched; an account with idle far above its remaining room can still deposit an amount that fits
- [x] 3.3 Tests — interactions: `0` cap allows any size; withdrawing frees room for a subsequent deposit; lowering the cap below an existing position does not trap the holder (all four withdrawal paths still work); a fee-share crystallisation on the pooled fund does not consume an account's cap room (fee-shares mint to `feeRecipient`, the D1 assumption — pin it)

## 4. Verification

- [x] 4.1 Mutant-check every new guard: remove each one individually and confirm the corresponding test fails (a passing test proves nothing until the mutant is seen to break it)
- [x] 4.2 Full unit sweep (`forge test --ffi --match-path "test/*.unit.t.sol"`), `forge build --sizes` (all contracts under EIP-170), and `forge fmt` — NOTE: format with CI's pinned nightly, not local forge 1.7.1, which wraps method chains the opposite way

## 5. Docs & ops

- [x] 5.1 Natspec on the new vault field/setter/view and the account's cap check (the share-vs-dollar drift from design D1, and why enforcement is account-side rather than in `strategyMint`)
- [x] 5.2 Runbook: the multisig procedure for setting the cap — always derive the number from the conversion view, never hand-compute the 12dp figure — plus the note that the cap is an allocation guardrail, not a fund-wide TVL limit and not a security boundary
- [x] 5.3 Flag the `depositIdle` signature change to whoever owns the backend integration; the deploy must be coordinated with that change
