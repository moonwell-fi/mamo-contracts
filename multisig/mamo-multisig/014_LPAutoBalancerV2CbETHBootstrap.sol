// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {LPValuationLib} from "@contracts/libraries/LPValuationLib.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";

/// @title LPAutoBalancerV2CbETHBootstrap
/// @notice FPS Safe (F-MAMO) proposal standing up the BOOTSTRAP LPAutoBalancerV2 position:
///         cbETH/WETH on Aerodrome Slipstream (Base), tickSpacing 1, gauged.
///
///         This is a SEPARATE deployment from `011_LPAutoBalancerV2Setup` (WETH/cbBTC). One
///         `LPAutoBalancerV2` manages exactly ONE pool — state lives in a single `position` struct
///         and `registerPosition` reverts `AlreadyRegistered` once a position is active — so a
///         second pair means a second balancer and a second compound module, registered here under
///         `MAMO_LP_AUTO_BALANCER_V2_CBETH` / `MAMO_LP_COMPOUND_MODULE_CBETH`. 011 is untouched and
///         can land before or after this proposal.
///
///         Sequence (all executed atomically by the F-MAMO Safe in `simulate`):
///           1. deploy() — LPAutoBalancerV2 + LPCompoundModule (admin/guardian = F-MAMO,
///              manager/rebalancer = address(0); the rebalancer is granted in build()). Idempotent.
///           2. build() — Safe actions, in order:
///                a. setSequencerUptimeFeed(CHAINLINK_L2_SEQUENCER_UPTIME_FEED, grace)
///                b. setMaxOracleDelays(delay0, delay1)
///                c. NFPM.safeTransferFrom(F-MAMO, balancer, tokenId)
///                d. registerPosition(config)
///                e. grantRole(REBALANCER_ROLE, rebalancerEOA)
///                f. compound-module wiring (F-MAMO-doable portion only)
///              (a) and (b) MUST precede (d): `registerPosition` probes both Chainlink feeds, and
///              that probe is only meaningful once it runs against the bounds this deployment
///              intends to ship. Same reasoning as 011 — a guard whose setter is never called is a
///              guard that is not there.
///
///         ─── TOTAL ALLOCATION ───────────────────────────────────────────────────────────────────
///         `totalAllocationUsd` (8-decimal USD, default $50,000) is the size the Safe commits to the
///         bootstrap position. It is a proposal PARAMETER, settable per run via
///         `setTotalAllocation(uint256,uint16)`, and `validate()` asserts the registered position's
///         principal lands inside `totalAllocationUsd ± allocationToleranceBps`.
///
///         Why validated rather than minted here: the position NFT is minted OFF-CHAIN (Phase B2)
///         and pinned via `setTokenId`, exactly as in 011. FPS records `build()`'s actions as
///         calldata and replays them at Safe-execution time, so a `mint` performed inside `build()`
///         would return a tokenId observed during SIMULATION, while the Slipstream NFPM's tokenId is
///         a global counter that anyone's mint advances between simulation and execution. The
///         encoded `registerPosition(tokenId)` would then name someone else's NFT. Minting off-chain
///         and asserting the resulting SIZE is the only form of this parameter that cannot silently
///         bind the wrong token. The mint amounts to use are derived from `totalAllocationUsd` in
///         the handbook (`docs/LP_AUTO_BALANCER_V2_BACKEND_HANDBOOK.md` §2).
///
///         ─── SWAP PATH IS DARK AT BOOTSTRAP (deliberate) ────────────────────────────────────────
///         `unwindForSwap`/`rebuildAfterSwap` require the CHAINLINK_SWAP_CHECKER_PROXY owner (MAMO
///         multisig, NOT F-MAMO) to configure the cbETH<->WETH token pair AND `setMaxTimePriceValid`
///         for BOTH tokens. Until that separate owner tx lands, `validateRebalanceOrder` reverts on
///         every order and a swap cycle degrades to a no-swap rebuild that still burns a full
///         cooldown. cbETH/WETH is an LST pair whose ratio drifts ~0.7 ticks/day, so the no-swap
///         `rebalanceUsingAlt` path is sufficient for the bootstrap: the backend runs ALT-only and
///         the swap path stays unused until the checker tx lands. The module knobs are still armed
///         here so enabling it later is a checker-owner tx, not a redeploy.
///
///         DEFERRED to the checker owner (`0x26c158A4…`), tracked in the handbook §7:
///           1. addTokenConfiguration(AERO->cbETH) + (AERO->WETH) + setMaxTimePriceValid(AERO, …)
///              — required before `module.approveCowSwap()` stops reverting "Token not allowed",
///              i.e. before the AERO reinvest leg does anything.
///           2. addTokenConfiguration(cbETH->WETH) + (WETH->cbETH) + setMaxTimePriceValid(cbETH, …)
///              + setMaxTimePriceValid(WETH, …) — required before the swap-rebalance path works.
///              `maxTimePriceValid == 0` collapses the module's `validTo <= now + maxTimePriceValid`
///              bound against its own `validTo >= now + 5 minutes` floor: every order reverts.
///           3. F-MAMO: `module.approveCowSwap()` (after 1).
contract LPAutoBalancerV2CbETHBootstrap is MultisigProposal {
    // ─── bootstrap position config (cbETH/WETH, tickSpacing 1) ──────────────────
    //
    // Every number below is a function of the venue, not a copy of 011's WETH/cbBTC values. The
    // pool's tickSpacing is 1 (not 100), so the whole width grid is 100x finer and 011's constants
    // would be nonsense here.
    int24 public constant TICK_SPACING = 1;

    /// @notice Calm gate: `rebalanceUsingAlt`/`unwindForSwap`/`rebuildAfterSwap` require
    ///         `|spot - twap| <= MAX_TICK_DEVIATION`. 20 ticks ~= 0.20% on a pair whose two legs are
    ///         the same underlying asset. Tighter than 011's 100 in absolute ticks AND far tighter
    ///         economically (011's 100 ticks at spacing 100 is 1%).
    int24 public constant MAX_TICK_DEVIATION = 20;

    /// @notice `minWidth > 2 * MAX_TICK_DEVIATION` — this is the CONFIG-LEVEL closure of the
    ///         branch-collision residual (R7) the backend spec §2.2 documents, not an arbitrary
    ///         floor. At `width == 2 * tickSpacing` the balanced tick pair and the token1-single-
    ///         sided tick pair collide, so a spot push inside the calm gate can turn a committed
    ///         two-sided mint into a single-sided one with a zeroed mint minimum. Only
    ///         `width >= 4 * tickSpacing`, i.e. `minWidth > 2 * maxTickDeviation`, rules it out for
    ///         every caller. On WETH/cbBTC that closure costs a doubled minimum width (011 declined
    ///         it and left the mitigation per-cycle); at tickSpacing 1 the same closure costs 50
    ///         ticks = 0.50% of range, so it is bought outright here.
    ///         Must be an even multiple of tickSpacing — 50 is.
    uint24 public constant MIN_WIDTH = 50;

    /// @notice 2000 ticks ~= 22% wide. Ample headroom for a manager to widen into a volatile
    ///         regime; the backend's operating width is 100 (see the handbook §4).
    uint24 public constant MAX_WIDTH = 2_000;

    /// @notice Backstop on how far the freshly minted range's center may sit from spot.
    uint24 public constant MAX_CENTER_DEVIATION = 20;

    /// @notice 30-minute TWAP for the calm gate. The pool's observation cardinality is 1440, so a
    ///         full ring spans >= 1440 blocks (~48 min at Base's 2s blocks) — the window is covered.
    uint32 public constant TWAP_WINDOW = 1800;

    /// @notice 0.50%. Half of 011's 100 bps: a no-swap rebuild on a correlated pair loses only pool
    ///         rounding plus forwarded dust, so the sanity guard has no reason to be looser.
    uint16 public constant MAX_REBALANCE_LOSS_BPS = 50;

    /// @notice 6h — matches the backend sweep cadence and stops a buggy agent looping rebalances.
    uint256 public constant MIN_REBALANCE_INTERVAL = 21_600;

    // ─── compound module config ─────────────────────────────────────────────────
    /// @notice 2% on the AERO->underlying compound swap (reward-only; principal is never sold here).
    uint256 public constant COMPOUND_SLIPPAGE_BPS = 200;

    /// @notice 0.30% on principal cbETH<->WETH rebalance orders. Tighter than 011's 50 bps because
    ///         both legs price off ETH-correlated feeds (cbETH/USD and ETH/USD) and the pool's own
    ///         fee tier is 0.0065%: a 50 bps floor would leave far more room than this venue needs.
    ///         EIP-1271 placement is permissionless while `rebalanceInFlight`, so this knob — not the
    ///         backend's limit price — is the binding price floor on the whole approved principal.
    uint256 public constant REBALANCE_SLIPPAGE_BPS = 30;

    /// @notice Placeholder CowSwap appData hash. `keccak256(...)` has NO valid appData-JSON preimage
    ///         and the orderbook demands the full document at placement — replace via
    ///         `setCompoundAppData(realHash)` before the FIRST order of either kind (handbook §7).
    bytes32 public constant COMPOUND_APP_DATA = keccak256("mamo-lpv2-compound-cbeth");

    /// @notice Extra value-floor tolerance on the CowSwap round-trip, on top of
    ///         MAX_REBALANCE_LOSS_BPS. 100 bps, not 011's 300: the swap leg here is cbETH<->WETH,
    ///         which executes inside a few bps, and a loose allowance is a loss the floor stops
    ///         detecting rather than a loss it prevents.
    uint16 public constant SWAP_LOSS_ALLOWANCE_BPS = 100;

    // ─── run-time parameters ────────────────────────────────────────────────────

    /// @notice The pre-minted cbETH/WETH Slipstream NFT tokenId held by the F-MAMO Safe (Phase B2).
    ///         MUST be set via `setTokenId` before build() — there is no sensible default.
    uint256 public tokenId;

    /// @notice Backend signer EOA granted REBALANCER_ROLE. Falls back to the MAMO_LP_REBALANCER
    ///         address entry when unset.
    address public rebalancerEOA;

    /// @notice TOTAL ALLOCATION committed to the bootstrap position, 8-decimal USD (matching the
    ///         balancer's own `valueInUsd` scale). $50,000 by default: large enough that AERO
    ///         emissions and gas are measurable against real fee income, small enough that the
    ///         bootstrap proves the rebalancer at a TVL the protocol can lose. Change it per run
    ///         with `setTotalAllocation`, never by editing this file.
    uint256 public totalAllocationUsd = 50_000e8;

    /// @notice Band `validate()` accepts around `totalAllocationUsd`. 500 bps absorbs the spread
    ///         between the price the Safe minted at and the price validation reads, plus the
    ///         in-ratio remainder the NFPM refunds. It is NOT slack for a wrong allocation: a
    ///         position minted at half the intended size fails this assertion.
    uint16 public allocationToleranceBps = 500;

    uint256 public sequencerGracePeriod = 3600;

    /// @notice Staleness bound for oracle0 (CHAINLINK_CBETH_USD). Measured on Base 2026-08-21 over
    ///         501 consecutive rounds spanning 37.4h: max inter-round gap 1290s, i.e. the feed
    ///         behaves like a ~1200s heartbeat, the same cadence as ETH/USD. 3600s therefore
    ///         tolerates two consecutive missed rounds — do NOT assume the 24h heartbeat some LST
    ///         feeds carry on other chains; it was checked here because the answer would have made
    ///         a 3600s bound brick the position.
    uint256 public maxOracleDelay0 = 3600;

    /// @notice Staleness bound for oracle1 (CHAINLINK_ETH_USD, ~1200s heartbeat). Separate field
    ///         rather than a shared one so the two legs stay independently tunable.
    uint256 public maxOracleDelay1 = 3600;

    function setTokenId(uint256 tokenId_) external {
        tokenId = tokenId_;
    }

    function setRebalancerEOA(address rebalancerEOA_) external {
        rebalancerEOA = rebalancerEOA_;
    }

    /// @notice Set the total allocation this proposal commits and validates.
    /// @param totalAllocationUsd_ 8-decimal USD. Must be non-zero — a zero target would make the
    ///        validation band `[0, 0]` and silently accept any position, which is the one outcome
    ///        this parameter exists to prevent.
    /// @param allocationToleranceBps_ band around the target, <= 10000.
    function setTotalAllocation(uint256 totalAllocationUsd_, uint16 allocationToleranceBps_) external {
        require(totalAllocationUsd_ != 0, "totalAllocationUsd must be non-zero");
        require(allocationToleranceBps_ <= 10_000, "tolerance > 100%");
        totalAllocationUsd = totalAllocationUsd_;
        allocationToleranceBps = allocationToleranceBps_;
    }

    function setSequencerGracePeriod(uint256 gracePeriod_) external {
        sequencerGracePeriod = gracePeriod_;
    }

    /// @notice Both bounds must be named: there is deliberately no one-value form here or on the
    ///         balancer, because writing one number to both feeds is how per-feed tuning gets
    ///         silently flattened back to a shared bound.
    function setMaxOracleDelays(uint256 delay0_, uint256 delay1_) external {
        maxOracleDelay0 = delay0_;
        maxOracleDelay1 = delay1_;
    }

    function _initializeAddresses() internal {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.updateJson();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "014_LPAutoBalancerV2CbETHBootstrap";
    }

    function description() public pure override returns (string memory) {
        return
        "Deploy the bootstrap LPAutoBalancerV2 + LPCompoundModule for cbETH/WETH, deposit the pre-minted Slipstream NFT, register the position at the configured total allocation, and grant REBALANCER_ROLE to the backend signer.";
    }

    function deploy() public override {
        // Both CREATEs broadcast explicitly: the overridden run() above does NOT wrap deploy() in
        // vm.startBroadcast (unlike the FPS base run()), so a production `forge script --broadcast`
        // would otherwise record these only in simulation and leave the address book pointing at
        // codeless bytes.
        if (!addresses.isAddressSet("MAMO_LP_AUTO_BALANCER_V2_CBETH")) {
            address safe = addresses.getAddress("F-MAMO");
            vm.startBroadcast();
            LPAutoBalancerV2 lab = new LPAutoBalancerV2(
                safe, // admin
                address(0), // manager — granted later if a manager EOA is named
                address(0), // rebalancer — granted in build(), never at deploy
                safe, // guardian
                addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME"),
                addresses.getAddress("AERO")
            );
            vm.stopBroadcast();
            addresses.addAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH", address(lab), true);
            console.log("LPAutoBalancerV2 (cbETH/WETH) deployed at:", address(lab));
        }

        if (!addresses.isAddressSet("MAMO_LP_COMPOUND_MODULE_CBETH")) {
            vm.startBroadcast();
            LPCompoundModule module = new LPCompoundModule(
                addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH"),
                addresses.getAddress("AERO"),
                addresses.getAddress("F-MAMO")
            );
            vm.stopBroadcast();
            addresses.addAddress("MAMO_LP_COMPOUND_MODULE_CBETH", address(module), true);
            console.log("LPCompoundModule (cbETH/WETH) deployed at:", address(module));
        }
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH")));

        // Own frames: keeps build() under the via_ir stack limit (the position config alone is 21
        // fields). Both MUST run before registerPosition — see the header.
        _wireSequencer(lab);
        _wireOracleDelays(lab);

        {
            address nfpm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
            address safe = addresses.getAddress("F-MAMO");

            require(tokenId != 0, "tokenId not set: mint the cbETH/WETH NFT to the Safe and call setTokenId");
            address rebalancer = _resolveRebalancer();

            // 1. Deposit the pre-minted NFT. Executes inside build()'s state-diff recording, so the
            //    balancer owns it by the time registerPosition runs (which reverts NotHeld otherwise).
            INonfungiblePositionManager(nfpm).safeTransferFrom(safe, address(lab), tokenId);

            // 2. Register. `altTokenId`, `mainStaked`, `altStaked`, `lastRebalance` and `active` are
            //    forced by `_store`; the values supplied for them are ignored (`active` -> true).
            //    Token ORDER is by address: cbETH (0x2Ae3…) < WETH (0x4200…), so cbETH is token0 and
            //    every oracle0/oracle1, amount0/amount1 field downstream follows that.
            LPAutoBalancerV2.ManagedPositionV2 memory config = LPAutoBalancerV2.ManagedPositionV2({
                mainTokenId: tokenId,
                altTokenId: 0,
                pool: addresses.getAddress("CBETH_WETH_CL_POOL"),
                token0: addresses.getAddress("cbETH"),
                token1: addresses.getAddress("WETH"),
                tickSpacing: TICK_SPACING,
                gauge: addresses.getAddress("CBETH_WETH_CL_GAUGE"),
                mainStaked: false,
                altStaked: false,
                feeCollector: addresses.getAddress("DROP_AUTOMATION"),
                oracle0: addresses.getAddress("CHAINLINK_CBETH_USD"),
                oracle1: addresses.getAddress("CHAINLINK_ETH_USD"),
                minWidth: MIN_WIDTH,
                maxWidth: MAX_WIDTH,
                maxCenterDeviation: MAX_CENTER_DEVIATION,
                twapWindow: TWAP_WINDOW,
                maxTickDeviation: MAX_TICK_DEVIATION,
                maxRebalanceLossBps: MAX_REBALANCE_LOSS_BPS,
                minRebalanceInterval: MIN_REBALANCE_INTERVAL,
                lastRebalance: 0,
                active: false
            });
            lab.registerPosition(config);

            // 3. Grant REBALANCER_ROLE to the backend signer EOA.
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        _wireModule(lab);
    }

    /// @dev Arm the L2 sequencer-uptime guard. The balancer ships with it DISABLED
    ///      (`sequencerUptimeFeed == address(0)` makes `checkSequencer` a no-op), so a deployment
    ///      that never runs this action prices every rebalance off Chainlink rounds that may
    ///      pre-date a Base sequencer outage. `setSequencerUptimeFeed` probes the feed in this same
    ///      tx, so a wrong address fails the Safe simulation rather than the next rebalance.
    function _wireSequencer(LPAutoBalancerV2 lab) internal {
        lab.setSequencerUptimeFeed(addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"), sequencerGracePeriod);
    }

    /// @dev Arm both per-feed staleness bounds explicitly. The constructor seeds
    ///      DEFAULT_MAX_ORACLE_DELAY on both legs, so without this action the bound that protects
    ///      the position on chain is an implicit default a later refactor could loosen with no
    ///      proposal changing. Naming them here is what makes them assertable in validate().
    function _wireOracleDelays(LPAutoBalancerV2 lab) internal {
        lab.setMaxOracleDelays(maxOracleDelay0, maxOracleDelay1);
    }

    /// @dev Wire the compound module and the F-MAMO-doable knobs. `approveCowSwap()` and the
    ///      checker's AERO/pair configuration are the DEFERRED owner tx (see the header).
    function _wireModule(LPAutoBalancerV2 lab) internal {
        LPCompoundModule module = LPCompoundModule(addresses.getAddress("MAMO_LP_COMPOUND_MODULE_CBETH"));
        lab.setCompoundModule(address(module));
        module.setSlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        module.setSlippage(COMPOUND_SLIPPAGE_BPS);
        module.setRebalanceSlippageBps(REBALANCE_SLIPPAGE_BPS);
        module.setCompoundAppData(COMPOUND_APP_DATA);
        lab.setSwapLossAllowanceBps(SWAP_LOSS_ALLOWANCE_BPS);
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("F-MAMO"));
    }

    function validate() public view override {
        address labAddr = addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2_CBETH");
        assertTrue(labAddr != address(0), "balancer address set");
        assertTrue(labAddr.code.length > 0, "balancer has code");
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(labAddr));

        address safe = addresses.getAddress("F-MAMO");
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), safe), "admin is F-MAMO");
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), safe), "guardian is F-MAMO");
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), _resolveRebalancer()), "rebalancer granted");

        // The sequencer guard must be ENABLED when this lands. A zero feed is a silently-disabled
        // guard, indistinguishable from "never wired".
        assertEq(
            lab.sequencerUptimeFeed(),
            addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"),
            "sequencer uptime feed armed"
        );
        assertEq(lab.sequencerGracePeriod(), sequencerGracePeriod, "sequencer grace period set");
        assertTrue(lab.sequencerGracePeriod() != 0, "sequencer guard not silently disabled");

        // Assert the EXACT bounds armed, not merely "non-zero" or "<= cap": the failure mode is a
        // bound that is technically valid and economically meaningless, which every weaker
        // assertion passes.
        assertEq(lab.maxOracleDelay0(), maxOracleDelay0, "oracle0 staleness bound armed");
        assertEq(lab.maxOracleDelay1(), maxOracleDelay1, "oracle1 staleness bound armed");
        assertTrue(lab.maxOracleDelay0() <= lab.MAX_ORACLE_DELAY(), "oracle0 bound within cap");
        assertTrue(lab.maxOracleDelay1() <= lab.MAX_ORACLE_DELAY(), "oracle1 bound within cap");

        // Split into `this.` external views so via_ir compiles each in its own frame (position()
        // returns a 21-field tuple; inlining these into validate() overflows the stack).
        this.validatePosition(lab);
        this.validateAllocation();
        this.validateModule(labAddr, safe);
    }

    /// @dev Assert the registered position matches the bootstrap config and the balancer holds the NFT.
    function validatePosition(LPAutoBalancerV2 lab) public view {
        (
            uint256 mainTokenId,
            ,
            address pool,
            address token0,
            address token1,
            int24 tickSpacing,
            address gauge,
            ,
            ,
            address feeCollector,
            address oracle0,
            address oracle1,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool active
        ) = lab.position();

        assertTrue(active, "position active");
        assertEq(mainTokenId, tokenId, "mainTokenId == tokenId");
        assertEq(pool, addresses.getAddress("CBETH_WETH_CL_POOL"), "pool");
        assertEq(token0, addresses.getAddress("cbETH"), "token0 == cbETH");
        assertEq(token1, addresses.getAddress("WETH"), "token1 == WETH");
        assertEq(int256(tickSpacing), int256(TICK_SPACING), "tickSpacing");
        assertEq(gauge, addresses.getAddress("CBETH_WETH_CL_GAUGE"), "gauge");
        assertEq(feeCollector, addresses.getAddress("DROP_AUTOMATION"), "feeCollector == DROP_AUTOMATION");
        assertEq(oracle0, addresses.getAddress("CHAINLINK_CBETH_USD"), "oracle0 == cbETH/USD");
        assertEq(oracle1, addresses.getAddress("CHAINLINK_ETH_USD"), "oracle1 == ETH/USD");

        assertEq(
            INonfungiblePositionManager(addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME")).ownerOf(
                mainTokenId
            ),
            address(lab),
            "balancer owns the cbETH/WETH NFT"
        );

        // R7 closure, asserted rather than assumed: `minWidth > 2 * maxTickDeviation` is what makes
        // the balanced/single-sided tick-pair collision unreachable for EVERY caller. If a future
        // edit loosens minWidth or widens the calm gate, this fails instead of quietly reopening a
        // sandwich that turns a committed two-sided mint into a zero-minimum single-sided one.
        assertTrue(
            uint256(MIN_WIDTH) > 2 * uint256(uint24(MAX_TICK_DEVIATION)),
            "minWidth > 2 * maxTickDeviation (branch-collision residual closed by config)"
        );
    }

    /// @dev Assert the registered position's principal actually equals the allocation this proposal
    ///      commits. Priced with the SAME feeds, staleness bounds and sequencer guard the balancer
    ///      itself uses, at the pool's live sqrtPriceX96 — so this is the balancer's own notion of
    ///      the position's value, not an independent estimate that could agree by luck.
    function validateAllocation() public view {
        LPValuationLib.OracleConfig memory cfg = LPValuationLib.OracleConfig({
            oracle0: addresses.getAddress("CHAINLINK_CBETH_USD"),
            oracle1: addresses.getAddress("CHAINLINK_ETH_USD"),
            maxDelay0: maxOracleDelay0,
            maxDelay1: maxOracleDelay1,
            sequencerUptimeFeed: addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"),
            sequencerGracePeriod: sequencerGracePeriod
        });

        (uint160 sqrtP,,,,,) = ICLPool(addresses.getAddress("CBETH_WETH_CL_POOL")).slot0();

        // cbETH and WETH are both 18-decimal.
        uint256 principalUsd = LPValuationLib.principalValue(
            addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME"), tokenId, sqrtP, cfg, 18, 18
        );

        uint256 lo = (totalAllocationUsd * (10_000 - allocationToleranceBps)) / 10_000;
        uint256 hi = (totalAllocationUsd * (10_000 + allocationToleranceBps)) / 10_000;

        assertTrue(principalUsd >= lo, "position under-allocated vs totalAllocationUsd");
        assertTrue(principalUsd <= hi, "position over-allocated vs totalAllocationUsd");
    }

    /// @dev Assert the compound module was deployed and wired (the F-MAMO-doable portion only).
    function validateModule(address labAddr, address safe) public view {
        address moduleAddr = addresses.getAddress("MAMO_LP_COMPOUND_MODULE_CBETH");
        assertTrue(moduleAddr != address(0) && moduleAddr.code.length > 0, "module deployed");
        assertEq(LPAutoBalancerV2(payable(labAddr)).compoundModule(), moduleAddr, "balancer wired to module");
        LPCompoundModule module = LPCompoundModule(moduleAddr);
        assertEq(module.balancer(), labAddr, "module bound to balancer");
        assertEq(module.AERO(), addresses.getAddress("AERO"), "module AERO");
        assertTrue(module.hasRole(module.DEFAULT_ADMIN_ROLE(), safe), "module admin is F-MAMO");
        assertEq(module.allowedSlippageInBps(), COMPOUND_SLIPPAGE_BPS, "slippage set");
        assertEq(module.rebalanceSlippageBps(), REBALANCE_SLIPPAGE_BPS, "rebalance slippage set");
        assertEq(module.compoundAppData(), COMPOUND_APP_DATA, "appData set");
        assertEq(
            address(module.slippagePriceChecker()), addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"), "checker set"
        );
        assertEq(
            LPAutoBalancerV2(payable(labAddr)).swapLossAllowanceBps(),
            SWAP_LOSS_ALLOWANCE_BPS,
            "swap loss allowance set"
        );
    }

    /// @dev Resolve the rebalancer EOA: explicit setter wins; else the MAMO_LP_REBALANCER entry.
    function _resolveRebalancer() internal view returns (address) {
        if (rebalancerEOA != address(0)) return rebalancerEOA;
        require(addresses.isAddressSet("MAMO_LP_REBALANCER"), "rebalancerEOA unset and MAMO_LP_REBALANCER missing");
        return addresses.getAddress("MAMO_LP_REBALANCER");
    }
}
