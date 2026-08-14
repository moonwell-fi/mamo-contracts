// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TenderlySwapHelper} from "./TenderlySwapHelper.sol";
import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

/*//////////////////////////////////////////////////////////////////////////////
                    LPAutoBalancerV2 — Tenderly Virtual TestNet harness
////////////////////////////////////////////////////////////////////////////////

WHAT THIS IS
------------
A *broadcasting* harness that deploys LPAutoBalancerV2 to a Tenderly Virtual
TestNet (a Base mainnet fork) and drives its real lifecycle as on-chain txs —
deploy → mint a real Aerodrome Slipstream WETH/cbBTC position → register → stake
→ reset → exit. Unlike the in-process forge fork test
(test/LPAutoBalancerV2.integration.t.sol), every step here is a *real signed
transaction* against a real RPC: it exercises the deployed bytecode (24 KB limit,
real gas, real op-stack EVM) and leaves an inspectable trace in the Tenderly
dashboard. Its purpose is to empirically corroborate the spec's assumptions on
infrastructure that mirrors mainnet, and to feed measured numbers back into the
PR review.

It is NOT a replacement for the unit/integration suites — it complements them by
proving the *deployed artifact* behaves as specified on a live fork.

NOTE ON NAMING: the contract entrypoint was renamed reset() → rebalanceUsingAlt()
upstream. The harness keeps "reset" as its phase vocabulary (doReset/justReset and
the reset.* log labels the orchestrator greps) — they drive rebalanceUsingAlt().

WHY MULTIPLE ENTRYPOINTS
------------------------
A single `--broadcast` run simulates the whole script once and then replays the
queued txs; it cannot let real wall-clock pass mid-run (needed for AERO to
accrue). So the lifecycle is split into `--sig` entrypoints. The orchestrator
(run-harness.sh) interleaves Tenderly cheat-RPCs (`tenderly_setErc20Balance`,
`evm_increaseTime`) between them, so each phase forks the *real, advanced* vnet
state and its assertions hold against it.

Addresses are the SAME real Base mainnet addresses the integration test pins, and
are re-verified live by run-harness.sh before any tx is sent.

  POOL    0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1  WETH/cbBTC CL, tickSpacing=100
  GAUGE   0x41b2126661C673C2beDd208cC72E85DC51a5320a  CL gauge (rewardToken = AERO)
  NFPM    0x827922686190790b37229fd06084350E74485b72  Slipstream NFPM (gauge.nft())
  WETH    0x4200000000000000000000000000000000000006  token0
  cbBTC   0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf  token1
  AERO    0x940181a94A35A4569E4529A3CDfB74e38FD98631  gauge reward token
  ETH/USD 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70  Chainlink, token0 oracle
  BTC/USD 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F  Chainlink, token1 oracle (cbBTC≈BTC)

ENV CONTRACT (set by run-harness.sh)
  HARNESS_SENDER   address that holds ALL roles and is the broadcaster
  HARNESS_LAB      deployed LPAutoBalancerV2 address (phases after setup)
  HARNESS_SCENARIO "balanced" | "singlesided"
//////////////////////////////////////////////////////////////////////////////*/

contract LPV2TenderlyHarness is Script {
    // ─── real Base mainnet addresses (resolved from addresses/8453.json via FPS) ──
    // Populated once per entrypoint by _resolve(). Kept as storage (not hardcoded constants) so the
    // harness reads the SAME address book the deploy scripts write, and ports to any fork/chain.
    Addresses internal addresses;
    address internal POOL;
    address internal GAUGE;
    address internal NFPM;
    address internal WETH;
    address internal CBBTC;
    address internal AERO;
    address internal ETH_USD;
    address internal BTC_USD;

    // Skim sink. Not a precompile (0xFEE5 ≫ 0x0a); starts at zero balance so deltas
    // measured here are exactly what reset()/exit() forwarded.
    address constant FEE_COLLECTOR = 0x000000000000000000000000000000000000Fee5;

    int24 constant TICK_SPACING = 100;
    uint24 constant WIDTH = 400; // 4 * tickSpacing
    int24 constant HALF = 200; // WIDTH / 2

    // Initial main funding. cbBTC (8-dec) ~ 0.05 BTC ≈ a few $k; WETH (18-dec) ~ 2 ETH.
    uint256 constant AMT_WETH = 2 ether;
    uint256 constant AMT_CBBTC = 0.05e8;

    // OZ AccessControl: error AccessControlUnauthorizedAccount(address,bytes32)
    bytes4 constant ACCESS_CONTROL_UNAUTHORIZED = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));

    // Uniswap-V3 sqrtPrice bounds (TickMath MIN/MAX +/- 1) for effectively-unbounded price-sim swaps.
    uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
    uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    // ─── helpers ────────────────────────────────────────────────────────────────

    function _sender() internal view returns (address) {
        return vm.envAddress("HARNESS_SENDER");
    }

    function _lab() internal view returns (LPAutoBalancerV2) {
        return LPAutoBalancerV2(payable(vm.envAddress("HARNESS_LAB")));
    }

    /// @dev Broadcaster private key, read from the ENVIRONMENT (vm.envUint) rather than passed to
    ///      forge on argv as `--private-key`. forge's argv is world-readable via `ps aux` on a shared
    ///      host; a process env var is not (only same-uid via /proc/<pid>/environ). The orchestrator
    ///      exports it from .env (see script/tenderly/lib/common.sh load_env). This MUST be a
    ///      throwaway, fork-only key — never a mainnet deployer. vm.addr() of this key equals
    ///      HARNESS_SENDER (the orchestrator derives the sender from the SAME key via sender()).
    function _broadcastKey() internal view returns (uint256) {
        return vm.envUint("MAMO_DEPLOYER_PRIVATE_KEY");
    }

    /// @notice argv-free sender derivation for the orchestrator. Logs vm.addr(MAMO_DEPLOYER_PRIVATE_KEY)
    ///         so bash can capture the broadcaster address WITHOUT ever putting the raw key on a
    ///         `cast wallet address --private-key` command line (ps-visibility). Needs no fork/RPC.
    function sender() public view {
        console.log("HARNESS_SENDER_DERIVED=%s", vm.addr(_broadcastKey()));
    }

    /// @dev Resolve the Base address book once per invocation (idempotent). Mirrors the deploy
    ///      scripts (DeployLPAutoBalancerV2.s.sol) so the harness and deployments share
    ///      addresses/<chainid>.json as the single source of truth instead of hardcoding hex.
    function _resolve() internal {
        if (address(addresses) != address(0)) return;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
        POOL = addresses.getAddress("WETH_CBBTC_CL_POOL");
        GAUGE = addresses.getAddress("WETH_CBBTC_CL_GAUGE");
        NFPM = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        WETH = addresses.getAddress("WETH");
        CBBTC = addresses.getAddress("cbBTC");
        AERO = addresses.getAddress("AERO");
        ETH_USD = addresses.getAddress("CHAINLINK_ETH_USD");
        BTC_USD = addresses.getAddress("CHAINLINK_BTC_USD");
    }

    function _isSingleSided() internal view returns (bool) {
        return keccak256(bytes(vm.envOr("HARNESS_SCENARIO", string("balanced")))) == keccak256(bytes("singlesided"));
    }

    /// @dev Floor-align a tick toward -inf to a multiple of TICK_SPACING (matches the contract).
    function _align(int24 tick) internal pure returns (int24 q) {
        q = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) q -= 1;
        q *= TICK_SPACING;
    }

    function _spotTick() internal view returns (int24 t) {
        (, t,,,,) = ICLPool(POOL).slot0();
    }

    /// @dev The main range `rebalanceUsingAlt` will derive at the CURRENT live spot — the off-chain
    ///      half of the tick commitment, reproducing `_mainRange` for the scenario this harness ran.
    ///      The balanced scenario withdraws two-sided principal and takes the straddle branch; the
    ///      singlesided scenario withdraws 100% token0 (WETH) and takes the token0-majority branch,
    ///      which parks the range on the first aligned tick strictly above spot.
    function _expectedMainRange() internal view returns (int24 tl, int24 tu) {
        int24 spot = _spotTick();
        if (_isSingleSided()) {
            tl = _align(spot) + TICK_SPACING;
            tu = tl + int24(WIDTH);
        } else {
            tl = _align(spot - int24(WIDTH) / 2);
            tu = tl + int24(WIDTH);
        }
    }

    function _resetParams() internal view returns (LPAutoBalancerV2.RebalanceParams memory) {
        (int24 expectedTl, int24 expectedTu) = _expectedMainRange();
        // mins = 0: the vnet is calm (no in-harness price manipulation), so the rebuild is
        // deterministic. Sandwich-min wiring is asserted in the unit suite.
        return LPAutoBalancerV2.RebalanceParams({
            width: WIDTH,
            amount0MinMain: 0,
            amount1MinMain: 0,
            amount0MinAlt: 0,
            amount1MinAlt: 0,
            amount0MinWithdraw: 0,
            amount1MinWithdraw: 0,
            amount0MinWithdrawAlt: 0,
            amount1MinWithdrawAlt: 0,
            // Generous: a broadcast tx lands in a LATER block than simulation, so a `+1` deadline
            // (fine for in-process fork tests) would expire before the tx mines. 1 day is safe and
            // well inside the harness's lifetime.
            deadline: block.timestamp + 1 days,
            // Tick commitment. NOTE this is computed at SIMULATION time while the broadcast lands in
            // a later block: if spot crosses an alignment boundary in between, the tx reverts
            // TickMismatch. That is the guard working as designed on a live chain — re-run the step.
            expectedTickLower: expectedTl,
            expectedTickUpper: expectedTu
        });
    }

    /// @dev Pick the initial main's mint range + funding to control what reset() later withdraws:
    ///        balanced    → straddles spot → two-sided principal → balanced rebuild path
    ///        singlesided → strictly ABOVE spot → 100% WETH (token0) → single-sided rebuild path
    ///      No swaps needed: the withdrawal's token mix is fixed at MINT time by the range.
    function _mintGeometry(bool single, int24 spot, int24 center)
        internal
        pure
        returns (int24 tl, int24 tu, uint256 a0, uint256 a1)
    {
        if (!single) {
            tl = center - HALF;
            tu = center + HALF;
            a0 = AMT_WETH;
            a1 = AMT_CBBTC;
            require(tl < spot && spot < tu, "geometry: balanced main must straddle spot");
        } else {
            tl = center + TICK_SPACING; // first aligned tick strictly above spot
            tu = tl + int24(WIDTH);
            a0 = AMT_WETH;
            a1 = 0;
            require(tl > spot, "geometry: single-sided main must sit above spot");
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Phase 1a — deployAndMint(): deploy the balancer + mint a REAL position TO it
    // ════════════════════════════════════════════════════════════════════════════
    // Mints directly to the balancer (recipient = lab) so there is NO cross-tx chaining on the
    // NFPM-assigned tokenId: on a live fork the simulated tokenId can differ from the broadcast
    // one, which would break a `safeTransferFrom(simId)`. registerStake() reads the REAL id from
    // chain. The CREATE address IS stable (deterministic from the deployer's own nonce), so using
    // address(lab) as the mint recipient is safe.
    function deployAndMint() public {
        vm.fee(0); // neutralize op-revm operator-fee handling during local simulation
        _resolve();
        address dep = _sender();
        bool single = _isSingleSided();
        int24 spot = _spotTick();
        int24 center = _align(spot);
        (int24 tl, int24 tu, uint256 a0, uint256 a1) = _mintGeometry(single, spot, center);

        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        // deployer holds ALL roles so one signer drives the whole lifecycle. Role SEPARATION
        // (rebalancer vs admin) is verified independently by checkRoleGating() and the unit suite.
        LPAutoBalancerV2 lab = new LPAutoBalancerV2(dep, dep, dep, dep, NFPM, AERO);

        // Widen both staleness bounds to the contract's own ceiling (MAX_ORACLE_DELAY, 1 day).
        // MOO-740 tightened the CONSTRUCTOR default to 1 hour, which is right for a live chain whose
        // feeds publish on a ~1200s heartbeat — and wrong for this harness, which drives the
        // lifecycle by WARPING the vnet clock (`advance_time 7200` before doReset) against feeds
        // that do not publish while it warps. Under the 1h default every warped phase would fail
        // StaleOracle for a reason that has nothing to do with what the phase is testing. Feed
        // repointing is deliberately not implemented for LPV2 (see lib/market.sh), so raising the
        // bound is the available lever. This is a TEST-RIG concession, not the shipped config:
        // proposal 011 arms 3600/3600 on chain and LPAutoBalancerV2SetupTest pins that.
        // The matrix's stale-oracle scenario still fires — it warps 27h, past this 24h ceiling.
        uint256 maxDelay = lab.MAX_ORACLE_DELAY();
        lab.setMaxOracleDelays(maxDelay, maxDelay);

        IERC20(WETH).approve(NFPM, a0);
        if (a1 > 0) IERC20(CBBTC).approve(NFPM, a1);

        ICLPositionManager(NFPM).mint(
            ICLPositionManager.MintParams({
                token0: WETH,
                token1: CBBTC,
                tickSpacing: TICK_SPACING,
                tickLower: tl,
                tickUpper: tu,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(lab), // mint straight into the balancer (it implements onERC721Received)
                deadline: block.timestamp + 1 days, // see _resetParams: broadcast lands in a later block
                sqrtPriceX96: 0
            })
        );
        vm.stopBroadcast();

        console.log("HARNESS_LAB=%s", address(lab));
        console.log("deployAndMint.scenario   :", single ? "singlesided" : "balanced");
        console.log("deployAndMint.spotTick   :", int256(spot));
        console.log("deployAndMint.mainTl     :", int256(tl));
        console.log("deployAndMint.mainTu     :", int256(tu));
        console.log("deployAndMint [OK]");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Phase 1b — registerStake(): register the held NFT (real id from env) + stake
    // ════════════════════════════════════════════════════════════════════════════
    function registerStake() public {
        vm.fee(0);
        _resolve();
        LPAutoBalancerV2 lab = _lab();
        bool single = _isSingleSided();
        uint256 tokenId = vm.envUint("HARNESS_TOKEN_ID"); // real on-chain id, read by the orchestrator
        require(INonfungiblePositionManager(NFPM).ownerOf(tokenId) == address(lab), "registerStake: lab must hold NFT");

        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        lab.registerPosition(
            LPAutoBalancerV2.ManagedPositionV2({
                mainTokenId: tokenId,
                altTokenId: 0,
                pool: POOL,
                token0: WETH,
                token1: CBBTC,
                tickSpacing: TICK_SPACING,
                gauge: GAUGE,
                mainStaked: false,
                altStaked: false,
                feeCollector: FEE_COLLECTOR,
                oracle0: ETH_USD,
                oracle1: BTC_USD,
                minWidth: 200,
                maxWidth: 200_000,
                maxCenterDeviation: 800_000,
                twapWindow: 60,
                // wide so the harness (which does not manipulate price) never trips the calm gate;
                // the gate FIRING is covered by the unit suite + the checkCalmGate entrypoint.
                maxTickDeviation: 800_000,
                maxRebalanceLossBps: 500,
                // >0 so the post-reset cooldown negative-check in doReset() is meaningful. The first
                // reset still passes: _store forces lastRebalance=0, so block.timestamp >> interval.
                minRebalanceInterval: 3600,
                lastRebalance: 0,
                active: false
            })
        );

        // Stake only the balanced scenario: it then accrues AERO while the orchestrator advances
        // the vnet clock, so rebalanceUsingAlt()'s unstake/AERO-skim path runs against real emissions.
        if (!single) lab.stake();
        vm.stopBroadcast();

        console.log("registerStake.tokenId :", tokenId);
        console.log("registerStake.staked  :", !single);
        console.log("registerStake [OK]");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Aux — checkRoleGating(): unprivileged caller must be rejected (pure simulation)
    // ════════════════════════════════════════════════════════════════════════════
    // Run WITHOUT --broadcast. vm.prank is simulation-only; we assert the modifiers revert with
    // the exact OZ AccessControl error, proving privilege separation even though the happy path
    // uses one all-roles EOA.
    function checkRoleGating() public {
        vm.fee(0);
        LPAutoBalancerV2 lab = _lab();
        address rando = address(0xBAD);

        vm.prank(rando);
        (bool ok0, bytes memory r0) = address(lab).call(abi.encodeCall(lab.rebalanceUsingAlt, (_resetParams())));
        require(!ok0, "reset must revert for non-REBALANCER");
        require(bytes4(r0) == ACCESS_CONTROL_UNAUTHORIZED, "reset revert must be AccessControl");

        vm.prank(rando);
        (bool ok1, bytes memory r1) = address(lab).call(abi.encodeCall(lab.exit, (rando)));
        require(!ok1, "exit must revert for non-ADMIN");
        require(bytes4(r1) == ACCESS_CONTROL_UNAUTHORIZED, "exit revert must be AccessControl");

        // a privileged-but-wrong-role surface: stake is REBALANCER-only too
        vm.prank(rando);
        (bool ok2, bytes memory r2) = address(lab).call(abi.encodeCall(lab.stake, ()));
        require(!ok2, "stake must revert for non-REBALANCER");
        require(bytes4(r2) == ACCESS_CONTROL_UNAUTHORIZED, "stake revert must be AccessControl");

        console.log("roleGating.reset_blocked :", true);
        console.log("roleGating.exit_blocked  :", true);
        console.log("roleGating.stake_blocked :", true);
        console.log("checkRoleGating [OK]");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Aux — checkCalmGate(): force a spot↔TWAP deviation and confirm reset() reverts
    // ════════════════════════════════════════════════════════════════════════════
    // The orchestrator overrides the pool's slot0 tick (tenderly_setStorageAt) to a value far from
    // the TWAP, then calls this with a TIGHT maxTickDeviation already configured. Pure simulation:
    // we just need the revert selector. Skipped automatically if the orchestrator can't override
    // storage. `maxTickDeviation` here must have been tightened by setPositionConfig first.
    function checkCalmGate() public {
        vm.fee(0);
        LPAutoBalancerV2 lab = _lab();
        vm.prank(_sender()); // REBALANCER
        (bool ok, bytes memory ret) = address(lab).call(abi.encodeCall(lab.rebalanceUsingAlt, (_resetParams())));
        require(!ok, "reset must revert when spot deviates from TWAP");
        require(bytes4(ret) == LPAutoBalancerV2.TwapDeviation.selector, "revert must be TwapDeviation");
        console.log("calmGate.reset_reverted_TwapDeviation:", true);
        console.log("checkCalmGate [OK]");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Phase 2 — doReset(): the no-swap rebuild + measurements
    // ════════════════════════════════════════════════════════════════════════════
    function doReset() public {
        vm.fee(0);
        _resolve();
        LPAutoBalancerV2 lab = _lab();
        bool single = _isSingleSided();

        LPAutoBalancerV2.DecisionSnapshotV2 memory pre = lab.getDecisionSnapshot();
        uint256 fc0 = IERC20(WETH).balanceOf(FEE_COLLECTOR);
        uint256 fc1 = IERC20(CBBTC).balanceOf(FEE_COLLECTOR);
        uint256 fca = IERC20(AERO).balanceOf(FEE_COLLECTOR);
        int24 spotBefore = _spotTick();

        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        lab.rebalanceUsingAlt(_resetParams());
        vm.stopBroadcast();

        LPAutoBalancerV2.DecisionSnapshotV2 memory post = lab.getDecisionSnapshot();
        uint256 d0 = IERC20(WETH).balanceOf(FEE_COLLECTOR) - fc0;
        uint256 d1 = IERC20(CBBTC).balanceOf(FEE_COLLECTOR) - fc1;
        uint256 da = IERC20(AERO).balanceOf(FEE_COLLECTOR) - fca;

        // ── INVARIANT 1: the rebuild produced a live main position ──
        require(post.mainLiquidity > 0, "reset: rebuilt main has liquidity");

        // ── INVARIANT 2: NO-SWAP / principal conserved ──
        // reset()'s internal value floor already enforced valueAfter >= valueBefore*(1-5%) on the
        // SAME Chainlink oracles (it would have reverted otherwise — so a successful reset IS the
        // floor passing). Beyond that, V2 has no router: principal can never convert between tokens,
        // so the ONLY outflow is fees/AERO/sub-threshold dust to the feeCollector. Bound those at a
        // tiny fraction of the deposited principal (2 WETH / 0.05 cbBTC) — a principal-sized escape
        // would blow these ceilings.
        require(d0 < 0.02 ether, "reset: WETH to feeCollector is fees/dust only, not principal");
        require(d1 < 10_000, "reset: cbBTC to feeCollector is fees/dust only, not principal");

        // ── INVARIANT 3: rebuild geometry matches the spec branch ──
        if (single) {
            // single-sided: parked on the funded (token0/WETH) side, strictly ABOVE spot, NOT in range
            require(post.mainTickLower > post.spotTick, "reset: single-sided main parked above spot");
            require(!post.mainInRange, "reset: single-sided main intentionally out of range");
        } else {
            // balanced: spot-centered straddle → in range
            require(post.mainInRange, "reset: balanced main in range after spot-centered rebuild");
            // staked main → reset restakes it (gauge owns it again)
            require(post.mainStaked, "reset: balanced main restaked");
            // AERO accrued over the orchestrator's time-advance must have been skimmed
            require(da > 0, "reset: AERO emissions skimmed to feeCollector");
        }

        // ── INVARIANT 4: cooldown gates an immediate re-reset (simulation-only, not broadcast) ──
        // reset() just set lastRebalance = now; minRebalanceInterval = 3600 > elapsed, so a second
        // reset by the same REBALANCER must revert Cooldown.
        vm.prank(_sender());
        (bool okCd, bytes memory rCd) = address(lab).call(abi.encodeCall(lab.rebalanceUsingAlt, (_resetParams())));
        require(!okCd, "reset: immediate 2nd reset must hit cooldown");
        require(bytes4(rCd) == LPAutoBalancerV2.Cooldown.selector, "reset: 2nd-reset revert must be Cooldown");

        console.log("=== doReset measurements (scenario: %s) ===", single ? "singlesided" : "balanced");
        console.log("reset.spotTick                :", int256(spotBefore));
        console.log("reset.pre.mainLiquidity       :", uint256(pre.mainLiquidity));
        console.log("reset.post.mainLiquidity      :", uint256(post.mainLiquidity));
        console.log("reset.post.mainInRange        :", post.mainInRange);
        console.log("reset.post.hasAlt             :", post.hasAlt);
        console.log("reset.post.altLiquidity       :", uint256(post.altLiquidity));
        console.log("reset.post.mainStaked         :", post.mainStaked);
        console.log("reset.WETH_to_feeCollector    :", d0);
        console.log("reset.cbBTC_to_feeCollector   :", d1);
        console.log("reset.AERO_to_feeCollector    :", da);
        console.log("reset.cooldown_blocks_2nd     :", true);
        console.log("doReset [OK]");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // Phase 3 — doExit(): Safe-gated teardown returns ALL principal
    // ════════════════════════════════════════════════════════════════════════════
    function doExit() public {
        vm.fee(0);
        _resolve();
        LPAutoBalancerV2 lab = _lab();
        address to = _sender();

        uint256 b0 = IERC20(WETH).balanceOf(to);
        uint256 b1 = IERC20(CBBTC).balanceOf(to);

        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        lab.exit(to);
        vm.stopBroadcast();

        uint256 g0 = IERC20(WETH).balanceOf(to) - b0;
        uint256 g1 = IERC20(CBBTC).balanceOf(to) - b1;

        // ── INVARIANT: all principal returned to the Safe, none stranded in the contract ──
        require(g0 > 0 || g1 > 0, "exit: principal returned to Safe");
        require(IERC20(WETH).balanceOf(address(lab)) < 0.02 ether, "exit: no WETH principal stranded");
        require(IERC20(CBBTC).balanceOf(address(lab)) < 10_000, "exit: no cbBTC principal stranded");

        // ── INVARIANT: slot marked inactive (getDecisionSnapshot reverts NotActive) ──
        bool inactive;
        try lab.getDecisionSnapshot() {
            inactive = false;
        } catch {
            inactive = true;
        }
        require(inactive, "exit: slot marked inactive");

        console.log("=== doExit measurements ===");
        console.log("exit.WETH_returned_to_safe  :", g0);
        console.log("exit.cbBTC_returned_to_safe :", g1);
        console.log("exit.slot_inactive          :", inactive);
        console.log("doExit [OK]");
    }

    // ════════════════════════════════════════════════════════════════════════════
    // PRICE-SIMULATION entrypoints (Phase 2)
    // ════════════════════════════════════════════════════════════════════════════
    // For this WETH/cbBTC pool the tick IS the price, so real broadcast swaps through the pool are the
    // price simulation. The orchestrator deploys TenderlySwapHelper once (deploySwapper), funds it,
    // and drives pushTick between phases; reset() is decoupled from its assertions (justReset +
    // assertInRange/assertSingleSided) so ONE reset path serves both the re-center and the driven
    // single-sided scenarios. Oracle staleness/coherent-oracle work lives in the sherwood port
    // (Moonwell must see the same move); here the fresh Chainlink feed backs the value floor.

    /// @notice Deploy the swap-callback helper. Orchestrator captures HARNESS_SWAPPER from the artifact.
    function deploySwapper() public {
        vm.fee(0);
        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        TenderlySwapHelper swapper = new TenderlySwapHelper();
        vm.stopBroadcast();
        console.log("HARNESS_SWAPPER=%s", address(swapper));
        console.log("deploySwapper [OK]");
    }

    /// @notice Push the pool spot tick via a real swap through the pre-funded helper.
    ///         zeroForOne=true sells WETH → tick falls (ETH cheaper); false sells cbBTC → tick rises.
    function pushTick(bool zeroForOne, uint256 amountIn) public {
        vm.fee(0);
        _resolve();
        address swapper = vm.envAddress("HARNESS_SWAPPER");
        uint160 lim = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;
        int24 spotBefore = _spotTick();
        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        TenderlySwapHelper(swapper).doSwap(POOL, zeroForOne, amountIn, lim);
        vm.stopBroadcast();
        console.log("pushTick.zeroForOne :", zeroForOne);
        console.log("pushTick.spotBefore :", int256(spotBefore));
        console.log("pushTick.spotAfter  :", int256(_spotTick()));
        console.log("pushTick [OK]");
    }

    /// @notice Broadcast reset() with only the universal invariants (rebuilt liquidity + no-swap
    ///         conservation). Scenario-specific geometry is asserted separately so the same reset
    ///         serves both re-center (→ in range) and driven single-sided (→ parked above spot).
    function justReset() public {
        vm.fee(0);
        _resolve();
        LPAutoBalancerV2 lab = _lab();
        uint256 fc0 = IERC20(WETH).balanceOf(FEE_COLLECTOR);
        uint256 fc1 = IERC20(CBBTC).balanceOf(FEE_COLLECTOR);
        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        lab.rebalanceUsingAlt(_resetParams());
        vm.stopBroadcast();
        LPAutoBalancerV2.DecisionSnapshotV2 memory post = lab.getDecisionSnapshot();
        require(post.mainLiquidity > 0, "justReset: rebuilt main has liquidity");
        require(IERC20(WETH).balanceOf(FEE_COLLECTOR) - fc0 < 0.02 ether, "justReset: WETH dust only");
        require(IERC20(CBBTC).balanceOf(FEE_COLLECTOR) - fc1 < 10_000, "justReset: cbBTC dust only");
        console.log("justReset.post.mainInRange   :", post.mainInRange);
        console.log("justReset.post.spotTick      :", int256(post.spotTick));
        console.log("justReset.post.mainTickLower :", int256(post.mainTickLower));
        console.log("justReset.post.mainLiquidity :", uint256(post.mainLiquidity));
        console.log("justReset [OK]");
    }

    /// @notice Post-reset assertion: main is a spot-straddling in-range position (re-center scenario).
    function assertInRange() public view {
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = _lab().getDecisionSnapshot();
        require(s.mainLiquidity > 0, "assertInRange: no liquidity");
        require(s.mainInRange, "assertInRange: main not in range after re-center");
        console.log("assertInRange [OK]");
    }

    /// @notice Post-reset assertion: main is a valid single-sided position parked ABOVE spot with no
    ///         swap (driven single-sided scenario — spot pushed decisively below the old range).
    function assertSingleSided() public view {
        LPAutoBalancerV2.DecisionSnapshotV2 memory s = _lab().getDecisionSnapshot();
        require(s.mainLiquidity > 0, "assertSingleSided: no liquidity");
        require(s.mainTickLower > s.spotTick, "assertSingleSided: main not parked above spot");
        require(!s.mainInRange, "assertSingleSided: main unexpectedly in range");
        console.log("assertSingleSided [OK]");
    }

    /// @notice Tighten the deviation gate so a subsequent spot push (before TWAP catches up) trips it.
    function tightenCalmGate() public {
        vm.fee(0);
        LPAutoBalancerV2 lab = _lab();
        vm.startBroadcast(_broadcastKey()); // key from env, not forge argv (see _broadcastKey)
        // same bounds as registerStake but a TIGHT maxTickDeviation (5 ticks).
        lab.setPositionConfig(200, 200_000, 800_000, 60, int24(5), 500, 3600);
        vm.stopBroadcast();
        console.log("tightenCalmGate.maxTickDeviation :", int256(5));
        console.log("tightenCalmGate [OK]");
    }

    /// @notice Assert reset() reverts StaleOracle (orchestrator advanced the clock past maxOracleDelay).
    function checkStaleOracle() public {
        vm.fee(0);
        LPAutoBalancerV2 lab = _lab();
        vm.prank(_sender());
        (bool ok, bytes memory ret) = address(lab).call(abi.encodeCall(lab.rebalanceUsingAlt, (_resetParams())));
        require(!ok, "checkStaleOracle: reset must revert when feeds are stale");
        require(bytes4(ret) == LPAutoBalancerV2.StaleOracle.selector, "checkStaleOracle: revert must be StaleOracle");
        console.log("checkStaleOracle.reset_reverted_StaleOracle :", true);
        console.log("checkStaleOracle [OK]");
    }
}
