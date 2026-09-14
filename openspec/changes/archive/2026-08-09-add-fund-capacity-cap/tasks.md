# Tasks: add-fund-capacity-cap

> Branch note: the leveraged-aero contracts live on `feat/venue-migration` (branched from
> `feat/leveraged-aero-vanilla-vault`). Branch this work from there, or from whatever lands on `main`
> first — this change touches `LeveragedAeroVault.sol` and `MamoLeveragedAeroStrategy.sol` only, so it
> does not conflict with the venue-migration diff (which is confined to `src/leveraged-aero/`).

## 1. Vault: the capacity value

- [x] 1.1 Add `maxTotalAssets` (uint256, USDC 6dp) to `LeveragedAeroVault`, with a `setMaxTotalAssets(uint256)` gated `onlyOwner` and a `MaxTotalAssetsSet(uint256)` event; document `0` as the unlimited sentinel and point at `depositsOpen` as the separate freeze switch
- [x] 1.2 Add `remainingCapacity()` (USDC still depositable; `type(uint256).max` when the cap is disabled, so "unlimited" is distinguishable from "full") and keep `previewSharesForAssets` as the assets→shares conversion for `minShares` sizing
- [x] 1.3 Tests: owner sets and re-sets; non-owner reverts; event carries the value; `0` reads back as unlimited; remaining capacity shrinks as the book fills and floors at 0 above the ceiling

## 2. Account: partial idle deposit

- [x] 2.1 **BREAKING** — change `depositIdle(uint256 minShares)` to `depositIdle(uint256 assets, uint256 minShares)`; require `assets > 0` and `assets <= usdc.balanceOf(address(this))`; keep the existing owner-or-backend gate and the `Deposit` event
- [x] 2.2 Tests: partial deposit leaves the remainder idle and owner-withdrawable; amount above the idle balance reverts; zero reverts; non-owner/non-backend still reverts

## 3. Strategy: capacity enforcement

- [x] 3.1 Add the check to `LeveragedAerodromeCLStrategy.deposit` (per design D3 — the one path every share-minting deposit takes, and NOT `strategyMint`, which also serves best-effort fee mints): read `maxTotalAssets` off the vault, skip when `0`, and revert `FundAtCapacity(navAfter, cap)` when `navNet + assets` would cross it. Check BEFORE the transfer so a rejected deposit moves no USDC
- [x] 3.2 Tests — enforcement (against the REAL vault + REAL strategy, since that is where the check lives): a crossing deposit reverts with no shares minted and no USDC moved; a deposit landing exactly at the ceiling succeeds; a full fund refuses a different depositor holding nothing; the amount that fits still goes in
- [x] 3.3 Tests — interactions: `0` allows any size; withdrawing frees capacity for other depositors; lowering the ceiling below the live book does not trap holders (exits unaffected); remaining capacity floors at 0 when NAV drifts above the ceiling

## 4. Verification

- [x] 4.1 Mutant-check every new guard: remove each one individually and confirm the corresponding test fails (a passing test proves nothing until the mutant is seen to break it)
- [x] 4.2 Full unit sweep (`forge test --ffi --match-path "test/*.unit.t.sol"`), `forge build --sizes` (all contracts under EIP-170), and `forge fmt` — NOTE: format with CI's pinned nightly, not local forge 1.7.1, which wraps method chains the opposite way

## 5. Docs & ops

- [x] 5.1 Natspec on the new vault field/setter/views and the strategy's capacity check (the NAV-drift trade-off from design D2, and why enforcement is in `deposit` rather than `strategyMint`)
- [x] 5.2 Runbook: the multisig procedure for setting the ceiling (a plain USDC figure — no share conversion), plus the notes that it is a real TVL ceiling binding every depositor, that NAV drift can open and close it without owner action, and that it gates deposits only
- [x] 5.3 Flag the `depositIdle` signature change to whoever owns the backend integration; the deploy must be coordinated with that change
