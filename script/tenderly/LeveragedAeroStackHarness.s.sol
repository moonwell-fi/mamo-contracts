// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";

/*//////////////////////////////////////////////////////////////////////////////
        Leveraged-Aero POOLED LAYER — Tenderly Virtual TestNet deploy harness
////////////////////////////////////////////////////////////////////////////////

WHAT THIS IS
------------
The Solidity half of the pooled-layer deploy tooling specified in
`docs/LEVERAGED_AERO_VNET_RUNBOOK.md` Phase B: it deploys the
`LeveragedAerodromeCLStrategy` CLONE TEMPLATE plus the `LeveragedAeroVault`, and it
ABI-encodes the strategy's `InitParams` from the environment so the orchestrator can
hand that calldata to `vault.cloneAndBind(template, proposer, initData)`.

It is driven by `script/tenderly/run-leveraged-aero-stack.sh`, which owns the phases
this script cannot express (Tenderly cheat-RPCs: FreshFeed `tenderly_setCode`, USDC
`tenderly_setErc20Balance`, and the multisig-impersonated `cloneAndBind` /
`activateStrategy` sends). Small `--sig` entrypoints logging `HARNESS_*=…` markers for
bash to grep — the same convention as `LeveragedAeroAccountHarness.s.sol` and
`LPV2TenderlyHarness.s.sol`.

WHY THE CLONE+INIT IS NOT DONE HERE
-----------------------------------
`LeveragedAeroVault.cloneAndBind` (added in PR #66 review remediation) is
`onlyOwner` and atomically clones + initializes + binds, closing the front-run window
the old two-step `Clones.clone` → `initialize` → `setStrategy` flow left open; both halves of that
flow are now gone (`initialize` is vault-only, `setStrategy` removed), so it is the only path. The owner
is `MAMO_MULTISIG`, which on a vnet is driven by UNLOCKED IMPERSONATION (no key), so the
call belongs in bash (`cast send --from $MULTISIG --unlocked`), not in a broadcast script.
This script only builds the calldata.

ENTRYPOINTS
  deployTemplate()  deploy the strategy template + the vault  → HARNESS_TEMPLATE, HARNESS_VAULT
  buildInitData()   ABI-encode InitParams from env            → HARNESS_INITDATA

VENUE BOOK
----------
Every venue field is env-driven with a documented Base default (see `_p()` below). The
runner exports the subset it also needs itself (the 5 feeds, USDC, LP_POOL), so at runtime
`run-leveraged-aero-stack.sh` is the single source of truth for those; the defaults here
keep this script runnable standalone and MUST stay in lockstep with the runner's.

  LP_POOL is deliberately a PARAMETER, not a constant — the final pool choice is a pending
  product decision. The default is the WETH/cbBTC CL pool at tickSpacing 100. Note that
  USDC can never be a leg (`_initialize` reverts `UnsupportedLeg`, since USDC is the unit of
  account), nor can the gauge's reward token (AERO — `compound()` sells it wholesale).

  LEG SLOTS, NOT TOKEN IDENTITIES: `weth*` is leg A (the natively-wrappable slot),
  `cbBTC*` is leg B. The names are historical. Ordering (`wethIsToken0`) and both leg
  decimals are DERIVED at init from the pool and the tokens, never passed.

  The per-leg SWAP tickSpacings are separate venues from the LP pool and are PROBED at init
  through the CL factory (`getPool(usdc, leg, spacing) != address(0)`), so a wrong value
  fails `cloneAndBind` loudly with `VenueMismatch()` rather than bricking a live book's
  settle/deleverage path later. Same for `TICK_SPACING`, asserted `== pool.tickSpacing()`.
//////////////////////////////////////////////////////////////////////////////*/

contract LeveragedAeroStackHarness is Script {
    // ── Base venue-book defaults (overridable via env; keep in lockstep with the runner) ──
    address constant DEF_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant DEF_M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address constant DEF_COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
    address constant DEF_LEG_A = 0x4200000000000000000000000000000000000006; // WETH
    address constant DEF_LEG_B = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // cbBTC
    address constant DEF_M_LEG_A = 0x628ff693426583D9a7FB391E54366292F509D457; // Moonwell mWETH
    address constant DEF_M_LEG_B = 0xF877ACaFA28c19b96727966690b2f44d35aD5976; // Moonwell mcbBTC
    address constant DEF_LP_POOL = 0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1; // WETH/cbBTC CL, ts=100
    address constant DEF_NPM = 0x827922686190790b37229fd06084350E74485b72; // Slipstream NFPM
    address constant DEF_GAUGE = 0x41b2126661C673C2beDd208cC72E85DC51a5320a; // CL gauge (reward = AERO)
    address constant DEF_SWAP_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5; // Slipstream CL router
    address constant DEF_LEG_A_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // ETH/USD, 8dp
    address constant DEF_LEG_B_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F; // BTC/USD, 8dp (cbBTC≈BTC)
    address constant DEF_USDC_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // USDC/USD, 8dp
    address constant DEF_AERO_FEED = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0; // AERO/USD, 8dp (asserted)
    address constant DEF_SEQ_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // L2 sequencer uptime

    /// @dev Default `MAMO_REBALANCER` — the strategy's `proposer` (operator) role and, unless
    ///      `FEE_RECIPIENT` overrides it, the fee recipient. A throwaway keypair minted for the vnet
    ///      (`cast wallet new`), DELIBERATELY DISTINCT from `MAMO_BACKEND`: the strategy has exactly one
    ///      operator role and the rebalancer service owns it. MAINNET MUST PASS THE REAL REBALANCER OPS
    ///      KEY — this address has a published private key (see the runner's header) and is fork-only.
    address constant DEF_REBALANCER = 0x73f6B456d063F78129113D42DBC315b9eEee8FAf;

    /// @notice Deploy the `LeveragedAerodromeCLStrategy` clone TEMPLATE and the `LeveragedAeroVault`.
    /// @dev Broadcast as `DEPLOYER_EOA` (unlocked impersonation supplies the identity; the orchestrator
    ///      passes `--unlocked --sender DEPLOYER_EOA`).
    ///
    ///      The template links THREE delegatecall libraries (`LeveragedAeroManager`,
    ///      `LeveragedAeroValuation`, `LeveragedAeroFees`). A `forge script` broadcast deploys and links
    ///      them automatically — a raw `cast` CREATE cannot, which is the whole reason this entrypoint
    ///      exists. Each library is its own tx, so the Base per-tx gas cap (16,777,216) applies per
    ///      CREATE and `--gas-estimate-multiplier 200` clears all of them.
    ///
    ///      The template's constructor sets `_initialized = true`, permanently locking `initialize` on
    ///      the template itself; ERC-1167 clones skip constructors, so clones stay initializable (and
    ///      `cloneAndBind` is what closes the window between cloning and initializing).
    ///
    ///      The vault is constructed with `owner_ = MAMO_MULTISIG` directly: `Ownable(owner_)` makes it
    ///      owner immediately, so there is NO `acceptOwnership()` step (Ownable2Step only gates LATER
    ///      transfers). Deploying to `DEPLOYER_EOA` and handing off would leave every `onlyOwner` path
    ///      — including `cloneAndBind` and proposal 012's `setOpenDeposits(true)` — dead until accepted.
    /// @return template The strategy template (clone source).
    /// @return vault The share-token + lifecycle vault, owned by `MAMO_MULTISIG`, asset = USDC.
    function deployTemplate() public returns (address template, address vault) {
        Addresses addresses = new Addresses("./addresses", _chainIds());
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        address usdc = vm.envOr("USDC", DEF_USDC);

        string memory name_ = vm.envOr("VAULT_NAME", string("Mamo Leveraged Aero Vault"));
        string memory symbol_ = vm.envOr("VAULT_SYMBOL", string("mlaUSDC"));

        vm.startBroadcast(deployer);
        template = address(new LeveragedAerodromeCLStrategy());
        vault = address(new LeveragedAeroVault(usdc, multisig, name_, symbol_));
        vm.stopBroadcast();

        console.log("HARNESS_TEMPLATE=%s", template);
        console.log("HARNESS_VAULT=%s", vault);
        console.log("template runtime size (limit 24576):", template.code.length);
        console.log("vault.owner:", LeveragedAeroVault(vault).owner());
        console.log("vault.asset:", LeveragedAeroVault(vault).asset());
        console.log("vault.decimals:", uint256(LeveragedAeroVault(vault).decimals())); // 12 = USDC 6dp + 6
    }

    /// @notice ABI-encode the strategy's `InitParams` from the environment.
    /// @dev The `initData` argument of `vault.cloneAndBind(template, proposer, initData)` — the vault
    ///      forwards it to `clone.initialize(address(this), proposer, initData)`.
    ///
    ///      `view`, not a broadcast: the orchestrator greps `HARNESS_INITDATA` out of the log and passes
    ///      the hex straight to `cast send`. Building it here rather than with 33 nested
    ///      `cast abi-encode` fields keeps the struct's field ORDER tied to the source of truth — the
    ///      encoding is positional, so a reordered field would silently mis-wire the strategy.
    /// @return initData The ABI-encoded `LeveragedAerodromeCLStrategy.InitParams`.
    function buildInitData() public view returns (bytes memory initData) {
        LeveragedAerodromeCLStrategy.InitParams memory p = _p();
        initData = abi.encode(p);
        console.log("HARNESS_INITDATA=%s", vm.toString(initData));
        console.log("initData bytes:", initData.length);
        console.log("  pool     :", p.pool);
        console.log("  legA/legB:", p.weth, p.cbBTC);
        console.log("  feeRecip :", p.feeRecipient);
        console.log("  mgmt/perf fee bps:", uint256(p.managementFeeBps), uint256(p.performanceFeeBps));
        console.log("  width band min/width/max:", uint256(p.minWidth), uint256(p.width), uint256(p.maxWidth));
        // Separate line: console.log tops out at 4 args. Keep the "width band" prefix — Phase B.2 greps it.
        console.log(
            "  width band skewBps (below-fraction, 5000 = centered) min/skew/max:",
            uint256(p.minSkewBps),
            uint256(p.skewBps),
            uint256(p.maxSkewBps)
        );
    }

    /// @dev Build `InitParams` from env vars. Field-by-field (not a struct literal) to keep the Yul IR
    ///      off the 16-live-variable cliff — the same shape `_baseParams()` uses in
    ///      `test/leveraged-aero/LeveragedAeroStrategyInit.unit.t.sol`, which this MIRRORS: that suite's
    ///      canonical-valid params are the reference for every risk/oracle/fee value below, with the
    ///      three oracle knobs (`maxDelay`, `gracePeriod`, `calmDeviationTicks`, `twapWindow`) taking
    ///      the live-deployment values the retired Sherwood `CloneAndInitLeveragedAero.s.sol` used
    ///      instead of the tighter mock-friendly ones.
    function _p() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        // ── tokens + Moonwell markets ──
        p.usdc = vm.envOr("USDC", DEF_USDC);
        p.mUsdc = vm.envOr("M_USDC", DEF_M_USDC);
        p.comptroller = vm.envOr("COMPTROLLER", DEF_COMPTROLLER);
        p.weth = vm.envOr("LEG_A", DEF_LEG_A); // leg A — the natively-wrappable slot
        p.cbBTC = vm.envOr("LEG_B", DEF_LEG_B); // leg B
        p.mWeth = vm.envOr("M_LEG_A", DEF_M_LEG_A);
        p.mCbBTC = vm.envOr("M_LEG_B", DEF_M_LEG_B);
        // ── venues ──
        p.pool = vm.envOr("LP_POOL", DEF_LP_POOL); // PARAMETER: final pool choice is a pending decision
        p.npm = vm.envOr("NPM", DEF_NPM);
        p.gauge = vm.envOr("GAUGE", DEF_GAUGE);
        p.swapRouter = vm.envOr("SWAP_ROUTER", DEF_SWAP_ROUTER);
        // ── Chainlink feeds (all FreshFeed-overridden on the vnet by run-leveraged-aero-stack.sh B.0) ──
        p.wethFeed = vm.envOr("LEG_A_FEED", DEF_LEG_A_FEED);
        p.cbBTCFeed = vm.envOr("LEG_B_FEED", DEF_LEG_B_FEED);
        p.usdcFeed = vm.envOr("USDC_FEED", DEF_USDC_FEED);
        p.aeroUsdFeed = vm.envOr("AERO_FEED", DEF_AERO_FEED); // MUST be 8dp: UnexpectedFeedDecimals
        p.sequencerFeed = vm.envOr("SEQ_FEED", DEF_SEQ_FEED);
        // ── oracle config: maxDelay ∈ (0,7d], gracePeriod ≤ 1d, twapWindow ∈ (0,1d], calmTicks ∈ (0,5000] ──
        p.maxDelay = vm.envOr("MAX_DELAY", uint256(48 hours));
        p.gracePeriod = vm.envOr("GRACE_PERIOD", uint256(1 hours));
        p.calmDeviationTicks = uint16(vm.envOr("CALM_DEVIATION_TICKS", uint256(500)));
        p.twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(1800)));
        // ── pool config ──
        p.tickSpacing = int24(int256(vm.envOr("TICK_SPACING", int256(100)))); // == pool.tickSpacing()
        p.wethSwapTickSpacing = int24(int256(vm.envOr("LEG_A_SWAP_TICK_SPACING", int256(100))));
        p.cbBTCSwapTickSpacing = int24(int256(vm.envOr("LEG_B_SWAP_TICK_SPACING", int256(100))));
        // Base's Moonwell mWETH market pays NATIVE ETH on borrow; the strategy wraps it to leg A.
        // Set false for an ERC-20-delivering leg-A market (and then stray ETH is stranded — no ETH rescue).
        p.wethDeliversNative = vm.envOr("WETH_DELIVERS_NATIVE", true);
        // ── width band: multiples of tickSpacing, minWidth ≥ 2×spacing, width inside [min,max] ──
        p.width = uint24(vm.envOr("WIDTH", uint256(4000))); // 40 × spacing — genesis mints at this
        p.minWidth = uint24(vm.envOr("MIN_WIDTH", uint256(200))); // 2 × spacing
        p.maxWidth = uint24(vm.envOr("MAX_WIDTH", uint256(20_000)));
        // ── range skew: bps of `width` placed BELOW the current tick; 5000 = centered. Must be in
        // (0, 10000), inside [MIN_SKEW_BPS, MAX_SKEW_BPS], and leave both spans >= one tickSpacing.
        p.skewBps = uint16(vm.envOr("SKEW_BPS", uint256(5000)));
        // ── skew governance band, fixed for the clone's life: `0 < min <= max < 10000`.
        p.minSkewBps = uint16(vm.envOr("MIN_SKEW_BPS", uint256(1000)));
        p.maxSkewBps = uint16(vm.envOr("MAX_SKEW_BPS", uint256(9000)));
        // ── risk params: targetLtv ≤ maxLtv < USDC CF, minHealth ≥ 10500, minHealth×maxLtv < 1e8 ──
        p.targetLtvBps = uint16(vm.envOr("TARGET_LTV_BPS", uint256(5000)));
        p.maxLtvBps = uint16(vm.envOr("MAX_LTV_BPS", uint256(6500)));
        p.minHealthBps = uint16(vm.envOr("MIN_HEALTH_BPS", uint256(12_000)));
        p.maxSlippageBps = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(100)));
        // ── fees: recipient defaults to the proposer (the rebalancer ops address) ──
        p.managementFeeBps = uint16(vm.envOr("MGMT_FEE_BPS", uint256(100))); // 1%/yr
        p.performanceFeeBps = uint16(vm.envOr("PERF_FEE_BPS", uint256(1000))); // 10% over HWM
        p.feeRecipient = vm.envOr("FEE_RECIPIENT", vm.envOr("MAMO_REBALANCER", DEF_REBALANCER));
    }

    function _chainIds() internal view returns (uint256[] memory chainIds) {
        chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
    }
}
