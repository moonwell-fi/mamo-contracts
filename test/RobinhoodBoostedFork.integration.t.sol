// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, Vm, console} from "@forge-std/Test.sol";

import {BoostedUsdgVault} from "@contracts/robinhood/BoostedUsdgVault.sol";
import {
    IMorphoBlue,
    IMorphoIrm,
    IMorphoOracle,
    Id,
    Market,
    MarketParams,
    MarketParamsLib
} from "@contracts/robinhood/interfaces/IMorphoBlue.sol";
import {IUniswapV3SwapRouter} from "@contracts/robinhood/interfaces/IUniswapV3SwapRouter.sol";
import {MorphoBlueMath} from "@contracts/robinhood/libraries/MorphoBlueMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title OracleFillRouter
 * @notice A stand-in for SwapRouter02 that fills at the Morpho market's own oracle price out of inventory
 * @dev USED ONLY WHEN THE CHAIN HAS NO VIABLE DEX POOL FOR THE CHOSEN COLLATERAL, and the suite says so
 *      loudly when it engages. It is not a convenience: the fact that it has to be used at all is one of this
 *      file's findings. It lets the rest of the loop — real Morpho Blue, real oracle, real collateral token,
 *      real borrow, real interest — still be exercised end to end, with exactly one leg simulated.
 */
contract OracleFillRouter is IUniswapV3SwapRouter {
    address public immutable loanToken;
    address public immutable collateralToken;
    address public immutable oracle;

    constructor(address _loanToken, address _collateralToken, address _oracle) {
        loanToken = _loanToken;
        collateralToken = _collateralToken;
        oracle = _oracle;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        uint256 price = IMorphoOracle(oracle).price();

        if (params.tokenIn == loanToken) {
            amountOut = (params.amountIn * MorphoBlueMath.ORACLE_PRICE_SCALE) / price;
        } else {
            amountOut = (params.amountIn * price) / MorphoBlueMath.ORACLE_PRICE_SCALE;
        }

        require(amountOut >= params.amountOutMinimum, "Too little received");

        IERC20(params.tokenOut).transfer(msg.sender, amountOut);
    }
}

/**
 * @title RobinhoodBoostedForkIntegrationTest
 * @notice The live-chain fork suite for `BoostedUsdgVault`: the Boosted USDG loop run against the REAL
 *         Morpho Blue singleton, REAL USDG-loan markets, REAL oracles and the REAL AdaptiveCurveIRM on
 *         Robinhood Chain (chain id 4663).
 *
 * @dev WHY THIS EXISTS ALONGSIDE THE UNIT SUITE
 *      `test/BoostedUsdgVault.unit.t.sol` proves the loop arithmetic against a faithful Blue mock. What it
 *      cannot prove is whether the CHAIN supports the product at all, which is four separate questions:
 *      1. Does a USDG-loan market with real borrow liquidity exist, and at what LLTV and borrow rate?
 *      2. Does its oracle answer, and does its IRM answer?
 *      3. Can the vault actually ACQUIRE the collateral? This is the one that is not obvious: a loop needs a
 *         venue to turn borrowed USDG into more collateral, and a Morpho market existing says nothing about
 *         whether such a venue does. The suite probes the Uniswap v3 factory across every fee tier and the
 *         collateral's own ERC-4626 surface, and reports what it finds.
 *      4. Does a full round trip — deposit, lever, accrue real interest, deleverage, redeem — settle?
 *
 * @dev MARKET SELECTION
 *      `setUp` discovers every market on the canonical singleton from its `CreateMarket` logs, filters to
 *      USDG-loan markets, ranks them by free borrow liquidity, and reports the leaders. It then picks the
 *      highest-liquidity market it can actually OPERATE — meaning one whose collateral is reachable, by an
 *      ERC-4626 primary market or by a Uniswap pool that quotes inside the slippage bound. If no market is
 *      operable, the loop runs against the liquidity leader with `OracleFillRouter` standing in for the entry
 *      leg, and every test says so in its log.
 *
 * @dev WHY IT IS ENV-GATED (same contract as the other two Robinhood fork suites)
 *      Every test needs an RPC to chain 4663; a sandbox without egress would otherwise fail CI for an
 *      environmental reason. The suite skips itself unless an RPC is reachable and lights up untouched when
 *      one is.
 *
 *      HOW TO RUN
 *          export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
 *          make robinhood-fork      # runs this suite alongside the chassis and basket fork suites
 */
contract RobinhoodBoostedForkIntegrationTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    // ==================== LIVE ADDRESSES (verified on-chain) ====================

    /// @dev Paxos-issued Global Dollar, the chain's base asset (6 decimals)
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @dev The canonical Morpho Blue singleton, deployed at genesis (block ~286)
    address internal constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

    /// @dev AdaptiveCurveIRM — every real USDG market on this chain uses it
    address internal constant ADAPTIVE_CURVE_IRM = 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1;

    /// @dev Uniswap V3 factory, used to probe whether a collateral is reachable by swap at all
    address internal constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    /// @dev Uniswap QuoterV2, used by the test (never by the vault) to read what a pool would really fill
    address internal constant UNISWAP_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    /// @dev `CreateMarket(bytes32 indexed id, MarketParams marketParams)`
    bytes32 internal constant CREATE_MARKET_TOPIC = 0xac4b2400f169220b0c0afdde7a0b32e775ba727ea1cb30b35f935cdaab8683ac;

    // ==================== PRODUCT PARAMETERS ====================

    /// @dev Small enough to be invisible to any of these markets, large enough to survive 6dp rounding
    uint256 internal constant DEPOSIT_AMOUNT = 500e6;

    /// @dev Admin ceiling on conversion slippage (1%)
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;

    /// @dev What the keeper actually asks for. Non-zero even on the exact ERC-4626 route, because a vault
    ///      that rounds share issuance down can land a unit or two under the oracle's expectation.
    uint256 internal constant BACKEND_SLIPPAGE_BPS = 25;

    /// @dev The vault's LTV ceiling sits 10% below the market's LLTV; the target sits at half of LLTV
    uint256 internal constant MAX_LTV_MARGIN_BPS = 1000;

    /// @dev Probe size for the DEX-reachability check
    uint256 internal constant POOL_PROBE_SIZE = 500e6;

    /// @dev Gas cap on QuoterV2 probes: a spam pool with thousands of initialised ticks would otherwise
    ///      traverse them all, and every tick is a fresh storage fetch from the RPC
    uint256 internal constant QUOTE_GAS_LIMIT = 2_000_000;

    /// @dev How many of the liquidity leaders get their oracle, rate and route read
    uint256 internal constant DETAIL_DEPTH = 6;

    uint24[4] internal FEE_TIERS = [uint24(100), 500, 3000, 10000];

    // ==================== DISCOVERY STATE ====================

    struct Candidate {
        Id id;
        MarketParams params;
        uint256 supplyAssets;
        uint256 borrowAssets;
        uint256 liquidity;
        uint256 price;
        uint256 borrowRatePerSecond;
        BoostedUsdgVault.CollateralRoute route;
        uint24 poolFee;
        bool routeProbed;
    }

    Candidate[] internal candidates;

    /// @notice The liquidity leader among USDG-loan markets with a working oracle (reporting)
    Candidate internal leader;

    /// @notice The market the vault actually runs (highest liquidity with a reachable collateral)
    Candidate internal chosen;

    bool public forkEnabled;
    bool public marketFound;

    /// @notice True when no live venue could acquire the chosen collateral and the entry leg is simulated
    bool public entryLegSimulated;

    address public admin = makeAddr("adminMultisig");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public feeRecipient = makeAddr("feeRecipient");
    address public user = makeAddr("user");

    BoostedUsdgVault public vault;
    OracleFillRouter public shimRouter;

    /// @dev Skips the body (marking the test skipped) when no Robinhood Chain RPC is reachable.
    modifier onlyFork() {
        if (!forkEnabled) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Skips when the chain has no USDG-loan market the vault could run at all.
    modifier onlyWithMarket() {
        if (!forkEnabled || !marketFound) {
            if (forkEnabled) console.log("NO-GO: no operable USDG-loan market found - skipping");
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));

        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
            forkEnabled = true;
        } else if (block.chainid == ROBINHOOD_CHAIN_ID) {
            // already forked via --fork-url
            forkEnabled = true;
        } else {
            console.log("RobinhoodBoostedFork: ROBINHOOD_RPC_URL not set and no 4663 fork active - skipping suite");
            return;
        }

        assertEq(block.chainid, ROBINHOOD_CHAIN_ID, "RPC is not Robinhood Chain (expected chain id 4663)");

        // `ROBINHOOD_FORK_BLOCK` pins the fork for a reproducible run. It is OFF by default because this
        // RPC keeps only a few thousand blocks of historical state ("metadata is not found" beyond roughly
        // 1-2k blocks back), so a pin more than a few minutes old fails outright and there is no archive node
        // to fall back on. Discovery is therefore kept cheap enough to finish inside that window instead.
        uint256 pinned = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pinned != 0) vm.rollFork(pinned);

        _discoverMarkets();
        if (!marketFound) return;

        _deployVault();
    }

    // ==================== 1. GROUND TRUTHS & MARKET CENSUS ====================

    /// @notice What the chain actually offers a levered USDG product, read from the singleton itself.
    function testForkBlueGroundTruthsAndMarketCensus() public onlyFork {
        assertGt(MORPHO_BLUE.code.length, 0, "Morpho Blue has no code at the documented address");
        assertGt(ADAPTIVE_CURVE_IRM.code.length, 0, "AdaptiveCurveIRM has no code at the documented address");
        assertEq(IERC20Metadata(USDG).decimals(), 6, "USDG decimals should be 6");

        console.log("--- pinned block %s, timestamp %s ---", vm.toString(block.number), vm.toString(block.timestamp));
        console.log("USDG-loan markets discovered: %s", vm.toString(candidates.length));

        uint256 shown = candidates.length < 6 ? candidates.length : 6;
        for (uint256 i = 0; i < shown; i++) {
            _logCandidate(i == 0 ? "LEADER " : "       ", candidates[i]);
        }

        if (!marketFound) {
            console.log("NO-GO: no USDG market has both liquidity and a reachable collateral");
            return;
        }

        console.log("");
        console.log("=== MARKET THE VAULT RUNS ===");
        _logCandidate("CHOSEN ", chosen);
        console.log("entry leg: %s", entryLegSimulated ? "SIMULATED (no live venue)" : "LIVE");

        assertGt(chosen.liquidity, 0, "chosen market has no free borrow liquidity");
        assertGt(chosen.price, 0, "chosen market's oracle does not price");
        assertGt(chosen.params.lltv, 0, "chosen market has no LLTV");

        // the IRM must answer, or the vault's accrual-aware NAV cannot be computed
        Market memory m = IMorphoBlue(MORPHO_BLUE).market(chosen.id);
        uint256 rate = IMorphoIrm(chosen.params.irm).borrowRateView(chosen.params, m);
        console.log("IRM responded, borrow rate per second (wad): %s", vm.toString(rate));
        assertEq(chosen.params.irm, ADAPTIVE_CURVE_IRM, "chosen market does not use the canonical IRM");
    }

    /**
     * @notice Can borrowed USDG be turned back into this chain's loop collateral at all?
     * @dev This is the load-bearing question for the product and it is answered by the DEX, not by Morpho.
     *      The test reports rather than asserts a verdict, because either answer is a finding: a live pool
     *      means the classic swap loop works, and no live pool means production entry has to run through the
     *      collateral's primary market (mint/redeem) or a bridge, which is a materially different design.
     */
    function testForkCollateralReachability() public onlyFork {
        if (candidates.length == 0) {
            console.log("no USDG-loan markets to probe");
            vm.skip(true);
            return;
        }

        console.log("=== COLLATERAL REACHABILITY (top USDG markets by liquidity) ===");

        uint256 probed = candidates.length < 3 ? candidates.length : 3;
        for (uint256 i = 0; i < probed; i++) {
            Candidate memory c = candidates[i];
            console.log("%s (liquidity %s USDG)", _symbol(c.params.collateralToken), _usdg(c.liquidity));

            // (a) primary market: is the collateral itself an ERC-4626 over USDG?
            (bool isVault, address underlying) = _tryReadAddress(c.params.collateralToken, "asset()");
            if (isVault && underlying == USDG) {
                console.log("  PRIMARY MARKET: ERC-4626 over USDG - mint/redeem at the vault's own rate");
            } else {
                console.log("  PRIMARY MARKET: none on-chain (not an ERC-4626 over USDG)");
            }

            // (b) secondary market: any Uniswap v3 pool, at any fee tier, that fills inside the bound?
            bool anyPool;
            for (uint256 f = 0; f < FEE_TIERS.length; f++) {
                address pool = _getPool(USDG, c.params.collateralToken, FEE_TIERS[f]);
                if (pool == address(0)) continue;

                anyPool = true;
                uint256 quoted = _quote(USDG, c.params.collateralToken, POOL_PROBE_SIZE, FEE_TIERS[f]);
                uint256 expected = (POOL_PROBE_SIZE * MorphoBlueMath.ORACLE_PRICE_SCALE) / c.price;

                console.log("  v3 pool @ %s bps: %s", vm.toString(uint256(FEE_TIERS[f]) / 100), vm.toString(pool));
                console.log(
                    "    quote %s vs oracle %s (%s)",
                    vm.toString(quoted),
                    vm.toString(expected),
                    quoted * 10000 >= expected * (10000 - MAX_SLIPPAGE_BPS) ? "USABLE" : "outside the 1% bound"
                );
            }
            if (!anyPool) console.log("  SECONDARY MARKET: no Uniswap v3 pool at any fee tier");
        }

        if (entryLegSimulated) {
            console.log("");
            console.log("FINDING: the chosen market's collateral has NO live acquisition venue on 4663.");
            console.log("Production entry cannot be a DEX swap - it needs primary-market minting or bridging.");
        }
    }

    // ==================== 2. DEPOSIT AND OPEN LEVERAGE ====================

    /// @notice Deposit USDG, then lever the pooled book against the live market to a conservative target.
    function testForkDepositAndOpenLeverage() public onlyWithMarket {
        _depositAll();

        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT, "NAV should equal the deposit before levering");
        assertEq(vault.idleAssets(), DEPOSIT_AMOUNT, "deposits land idle");

        uint256 target = _targetLtvBps();

        vm.prank(backend);
        vault.openLeverage(target, 8, BACKEND_SLIPPAGE_BPS);

        console.log("target LTV:      %s bps", vm.toString(target));
        console.log("achieved LTV:    %s bps", vm.toString(vault.ltvBps()));
        console.log(
            "collateral:      %s (%s USDG of value)",
            vm.toString(vault.collateralBalance()),
            _usdg(vault.collateralValue())
        );
        console.log("debt:            %s USDG", _usdg(vault.debtAssets()));
        console.log("NAV:             %s USDG (deposited %s)", _usdg(vault.totalAssets()), _usdg(DEPOSIT_AMOUNT));
        console.log("health factor:   %s (wad)", vm.toString(vault.healthFactor()));
        console.log("entry leg:       %s", entryLegSimulated ? "SIMULATED" : "LIVE");

        assertGt(vault.collateralBalance(), 0, "collateral supplied to the live market");
        assertGt(vault.debtAssets(), 0, "USDG borrowed against it");
        assertLe(vault.ltvBps(), vault.maxLtvBps(), "INVARIANT: LTV at or below the ceiling");
        assertGt(vault.healthFactor(), 1e18, "INVARIANT: position healthy per Blue");
        assertApproxEqRel(vault.ltvBps(), target, 0.05e18, "converged on the target");

        // levering is NAV-neutral apart from conversion cost, which is bounded by the oracle floor
        assertApproxEqRel(vault.totalAssets(), DEPOSIT_AMOUNT, 0.01e18, "levering should not bleed NAV");
    }

    // ==================== 3. REAL INTEREST ACCRUAL AND THE CARRY SPREAD ====================

    /**
     * @notice Run the live position forward and measure the two rates that decide whether this product works.
     * @dev Two things are being checked, and only the first is a correctness claim:
     *      1. CORRECTNESS. `totalAssets()` must reflect accrued borrow interest WITHOUT anyone having poked
     *         `accrueInterest`, or a pooled vault mints and burns shares at a stale price. The test reads the
     *         accrual-aware view, then pokes the singleton, and requires the two to agree.
     *      2. THE PRODUCT QUESTION. A loop only pays if the collateral's yield exceeds the borrow rate. Both
     *         legs move on the same warp here — the collateral is a savings vault and the Blue oracle reads
     *         its exchange rate — so the window measures the REAL carry spread on the live market rather than
     *         an assumed one. That number is logged rather than asserted, because it is a market fact that
     *         will change, and pinning a test to today's spread would only make the suite lie later.
     */
    function testForkCarrySpreadAndAccrualAwareNav() public onlyWithMarket {
        _depositAll();

        vm.prank(backend);
        vault.openLeverage(_targetLtvBps(), 8, BACKEND_SLIPPAGE_BPS);

        uint256 collateralBefore = vault.collateralValue();
        uint256 debtBefore = vault.debtAssets();
        uint256 navBefore = vault.totalAssets();
        uint256 ltvBefore = vault.ltvBps();

        uint256 window = 30 days;
        vm.warp(block.timestamp + window);

        uint256 debtViewOnly = vault.debtAssets();
        uint256 navViewOnly = vault.totalAssets();
        uint256 collateralAfter = vault.collateralValue();

        // poke the singleton for real, and require the view to have already agreed with it
        IMorphoBlue(MORPHO_BLUE).accrueInterest(chosen.params);
        assertApproxEqAbs(vault.debtAssets(), debtViewOnly, 2, "the accrual-aware view matches what Blue writes");

        uint256 collateralGain = collateralAfter > collateralBefore ? collateralAfter - collateralBefore : 0;
        uint256 interestPaid = debtViewOnly > debtBefore ? debtViewOnly - debtBefore : 0;

        console.log("window: 30 days on the live market");
        console.log(
            "  collateral %s -> %s USDG (+%s)", _usdg(collateralBefore), _usdg(collateralAfter), _usdg(collateralGain)
        );
        console.log("  debt       %s -> %s USDG (+%s)", _usdg(debtBefore), _usdg(debtViewOnly), _usdg(interestPaid));
        console.log("  NAV        %s -> %s USDG", _usdg(navBefore), _usdg(navViewOnly));
        console.log("  LTV        %s -> %s bps", vm.toString(ltvBefore), vm.toString(vault.ltvBps()));
        console.log(
            "  leverage:  %s bps of collateral per unit of equity", vm.toString(collateralBefore * 10000 / navBefore)
        );
        console.log(
            "  collateral yield ~%s bps/yr, borrow cost ~%s bps/yr",
            vm.toString(_annualisedBps(collateralGain, collateralBefore, window)),
            vm.toString(_annualisedBps(interestPaid, debtBefore, window))
        );

        // the accounting identity the whole NAV model rests on
        assertEq(
            navViewOnly + interestPaid, navBefore + collateralGain, "NAV moves by exactly (collateral gain - interest)"
        );
        assertGt(interestPaid, 0, "the live market charges real borrow interest");

        if (navViewOnly > navBefore) {
            uint256 netApy = _annualisedBps(navViewOnly - navBefore, navBefore, window);
            console.log("  GO: levered carry is POSITIVE, ~%s bps/yr net on equity", vm.toString(netApy));
        } else {
            console.log("  NO-GO: borrow cost exceeds collateral yield - the loop currently destroys NAV");
        }
    }

    /**
     * @notice The number that decides whether Boosted USDG is a product at all: the carry spread, per market.
     * @dev A loop earns `leverage x (collateral yield - borrow rate)`. Both legs are read here from the live
     *      chain rather than assumed: the collateral yield is the drift of the market's OWN Blue oracle over a
     *      30-day window (these oracles read savings-vault exchange rates, so they move with the collateral),
     *      and the borrow rate is what AdaptiveCurveIRM quotes right now. Reporting only — the spread is a
     *      market fact that moves, and a test that asserted today's number would just become a lie later.
     *
     *      One limit to read the output with: a fork window only sees oracles whose price is a function of
     *      TIME. An oracle whose value is pushed on-chain by an updater looks frozen under `vm.warp`, and is
     *      indistinguishable from a collateral that genuinely earns nothing. The test flags that case rather
     *      than scoring it as negative carry.
     */
    function testForkCarrySpreadCensus() public onlyFork {
        if (candidates.length == 0) {
            console.log("no USDG-loan markets to measure");
            vm.skip(true);
            return;
        }

        uint256 window = 30 days;
        uint256 measured = candidates.length < 3 ? candidates.length : 3;

        uint256[] memory before = new uint256[](measured);
        for (uint256 i = 0; i < measured; i++) {
            before[i] = _tryPrice(candidates[i].params.oracle);
        }

        vm.warp(block.timestamp + window);

        console.log("=== CARRY SPREAD, 30-day window on the live chain ===");
        for (uint256 i = 0; i < measured; i++) {
            uint256 nowPrice = _tryPrice(candidates[i].params.oracle);
            uint256 yieldBps = nowPrice > before[i] ? _annualisedBps(nowPrice - before[i], before[i], window) : 0;
            uint256 borrowBps = (candidates[i].borrowRatePerSecond * 365 days * 10000) / 1e18;

            console.log(
                "%s / USDG (free liquidity %s USDG)",
                _symbol(candidates[i].params.collateralToken),
                _usdg(candidates[i].liquidity)
            );
            console.log(
                "  collateral yield ~%s bps/yr, borrow ~%s bps/yr", vm.toString(yieldBps), vm.toString(borrowBps)
            );

            if (yieldBps > borrowBps) {
                console.log("  SPREAD: +%s bps/yr - leverage adds return here", vm.toString(yieldBps - borrowBps));
            } else if (yieldBps == 0) {
                // A fork cannot distinguish "this collateral does not earn" from "its oracle is push-updated
                // and no updater ran during the warp". Both read as a flat price. Say so instead of scoring it.
                console.log("  NOT MEASURABLE ON A FORK: the oracle did not move under vm.warp.");
                console.log("  Either the collateral does not accrue, or its oracle is pushed by an off-chain");
                console.log("  updater rather than derived from a time-based exchange rate. Confirm off-chain");
                console.log("  before assuming a spread of -%s bps/yr.", vm.toString(borrowBps));
            } else {
                console.log("  SPREAD: -%s bps/yr - leverage DESTROYS return here", vm.toString(borrowBps - yieldBps));
            }
        }
        console.log("Sizing note: net ROE = yield + leverage x spread. A ~zero spread means leverage buys nothing,");
        console.log("however high the LTV, while still carrying full liquidation and depeg risk.");
    }

    // ==================== 4. DELEVERAGE AND FULL EXIT ====================

    /// @notice The complete round trip: deposit, lever, unwind, redeem — all against the live market.
    function testForkDeleverageAndRedeemAllSettles() public onlyWithMarket {
        _depositAll();

        vm.prank(backend);
        vault.openLeverage(_targetLtvBps(), 8, BACKEND_SLIPPAGE_BPS);

        vm.prank(backend);
        vault.deleverage(8, BACKEND_SLIPPAGE_BPS);

        console.log(
            "after deleverage: collateral %s, debt %s USDG",
            vm.toString(vault.collateralBalance()),
            _usdg(vault.debtAssets())
        );

        assertEq(vault.debtAssets(), 0, "debt fully repaid on the live market");
        assertEq(vault.collateralBalance(), 0, "collateral fully withdrawn");
        assertEq(vault.ltvBps(), 0, "position flat");

        uint256 shares = vault.balanceOf(user);
        uint256 balanceBefore = IERC20(USDG).balanceOf(user);

        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, 0);

        uint256 received = IERC20(USDG).balanceOf(user) - balanceBefore;
        uint256 roundTripCostBps =
            received >= DEPOSIT_AMOUNT ? 0 : ((DEPOSIT_AMOUNT - received) * 10000) / DEPOSIT_AMOUNT;

        console.log("deposited %s USDG -> returned %s USDG", _usdg(DEPOSIT_AMOUNT), _usdg(received));
        console.log(
            "ROUND-TRIP COST: %s bps (entry leg %s)",
            vm.toString(roundTripCostBps),
            entryLegSimulated ? "SIMULATED" : "LIVE"
        );

        assertEq(received, assets, "redeem paid what it reported");
        assertEq(vault.totalSupply(), 0, "all shares burnt");
        assertApproxEqRel(received, DEPOSIT_AMOUNT, 0.02e18, "round trip should cost less than 2% of NAV");
    }

    /// @notice A redemption straight out of a LEVERED book, with no keeper unwind first.
    /// @dev This is the path a real user takes, and the one the async settlement ledger exists to replace.
    ///      It must either settle in-transaction or revert cleanly on `minAssetsOut` — never short the user.
    function testForkRedeemUnwindsALeveredBookInOneTransaction() public onlyWithMarket {
        _depositAll();

        vm.prank(backend);
        vault.openLeverage(_targetLtvBps(), 8, BACKEND_SLIPPAGE_BPS);

        uint256 navBefore = vault.totalAssets();
        uint256 ltvBefore = vault.ltvBps();
        uint256 shares = vault.balanceOf(user) / 2;
        uint256 balanceBefore = IERC20(USDG).balanceOf(user);

        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, 0);

        console.log("redeemed half a levered book: %s USDG on a %s USDG NAV", _usdg(assets), _usdg(navBefore));
        console.log("LTV %s -> %s bps", vm.toString(ltvBefore), vm.toString(vault.ltvBps()));

        assertEq(IERC20(USDG).balanceOf(user) - balanceBefore, assets, "paid out in full");
        assertApproxEqRel(assets, navBefore / 2, 0.02e18, "roughly half of NAV, net of unwind cost");
        assertApproxEqRel(vault.ltvBps(), ltvBefore, 0.05e18, "remaining holders keep their leverage");
        assertGt(vault.healthFactor(), 1e18, "INVARIANT: position still healthy after a user exit");
    }

    // ==================== SETUP HELPERS ====================

    /**
     * @dev Reads every `CreateMarket` log from the singleton, keeps the USDG-loan markets, ranks them by free
     *      borrow liquidity, and picks the highest-liquidity one whose collateral can actually be acquired.
     */
    function _discoverMarkets() internal {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = CREATE_MARKET_TOPIC;

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(0, block.number, MORPHO_BLUE, topics);
        console.log("CreateMarket logs on the canonical singleton: %s", vm.toString(logs.length));

        if (logs.length == 0) {
            console.log("no CreateMarket logs returned - the RPC may cap eth_getLogs ranges");
            return;
        }

        for (uint256 i = 0; i < logs.length; i++) {
            MarketParams memory params = abi.decode(logs[i].data, (MarketParams));
            if (params.loanToken != USDG || params.collateralToken == address(0)) continue;
            if (params.oracle == address(0) || params.irm == address(0) || params.lltv == 0) continue;

            Id id = Id.wrap(logs[i].topics[1]);
            Market memory m = IMorphoBlue(MORPHO_BLUE).market(id);
            if (m.lastUpdate == 0) continue;

            uint256 liquidity =
                m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0;
            if (liquidity == 0) continue;

            candidates.push(
                Candidate({
                    id: id,
                    params: params,
                    supplyAssets: m.totalSupplyAssets,
                    borrowAssets: m.totalBorrowAssets,
                    liquidity: liquidity,
                    price: 0,
                    borrowRatePerSecond: 0,
                    route: BoostedUsdgVault.CollateralRoute.NONE,
                    poolFee: 0,
                    routeProbed: false
                })
            );
        }

        _sortByLiquidity();

        // detail only the leaders: the tail is listing dust and probing it all would hammer the RPC
        uint256 detailed = candidates.length < DETAIL_DEPTH ? candidates.length : DETAIL_DEPTH;
        for (uint256 i = 0; i < detailed; i++) {
            candidates[i].price = _tryPrice(candidates[i].params.oracle);
            if (candidates[i].price == 0) continue;

            candidates[i].borrowRatePerSecond = _tryBorrowRate(candidates[i].params, candidates[i].id);

            if (Id.unwrap(leader.id) == bytes32(0)) leader = candidates[i];

            // route detection is the expensive read (pool quotes); stop as soon as one market is operable
            if (marketFound) continue;

            (candidates[i].route, candidates[i].poolFee) = _detectRoute(candidates[i]);
            candidates[i].routeProbed = true;

            if (candidates[i].route != BoostedUsdgVault.CollateralRoute.NONE) {
                chosen = candidates[i];
                marketFound = true;
            }
        }

        // no reachable collateral anywhere: fall back to the liquidity leader with a simulated entry leg
        if (!marketFound && Id.unwrap(leader.id) != bytes32(0)) {
            chosen = leader;
            chosen.route = BoostedUsdgVault.CollateralRoute.DEX;
            chosen.poolFee = 3000;
            entryLegSimulated = true;
            marketFound = true;
        }
    }

    /// @dev ERC-4626 primary market first (exact), then a Uniswap pool that quotes inside the bound
    function _detectRoute(Candidate memory c) internal returns (BoostedUsdgVault.CollateralRoute, uint24) {
        (bool isVault, address underlying) = _tryReadAddress(c.params.collateralToken, "asset()");
        if (isVault && underlying == USDG && _tryPreviewDeposit(c.params.collateralToken) > 0) {
            return (BoostedUsdgVault.CollateralRoute.ERC4626, 0);
        }

        uint256 expected = (POOL_PROBE_SIZE * MorphoBlueMath.ORACLE_PRICE_SCALE) / c.price;
        uint256 floor = (expected * (10000 - MAX_SLIPPAGE_BPS)) / 10000;

        for (uint256 f = 0; f < FEE_TIERS.length; f++) {
            if (_getPool(USDG, c.params.collateralToken, FEE_TIERS[f]) == address(0)) continue;
            if (_quote(USDG, c.params.collateralToken, POOL_PROBE_SIZE, FEE_TIERS[f]) >= floor) {
                return (BoostedUsdgVault.CollateralRoute.DEX, FEE_TIERS[f]);
            }
        }

        return (BoostedUsdgVault.CollateralRoute.NONE, 0);
    }

    function _deployVault() internal {
        vault = new BoostedUsdgVault(USDG, MORPHO_BLUE, admin, "Mamo Boosted USDG", "bUSDG");

        uint256 lltv = (chosen.params.lltv * 10000) / 1e18;
        uint256 maxLtv = lltv > MAX_LTV_MARGIN_BPS ? lltv - MAX_LTV_MARGIN_BPS : 0;

        vm.startPrank(admin);
        vault.addMarket(chosen.params, chosen.route, chosen.poolFee);
        vault.setActiveMarket(chosen.id);
        vault.setMaxLtv(maxLtv);
        vault.setMaxSlippage(MAX_SLIPPAGE_BPS);
        vault.setPerformanceFee(1000);
        vault.setFeeRecipient(feeRecipient);
        vault.setBackend(backend);
        vault.setGuardian(guardian);
        vault.setSupplyCap(1_000_000e6);

        if (chosen.route == BoostedUsdgVault.CollateralRoute.DEX) {
            if (entryLegSimulated) {
                shimRouter = new OracleFillRouter(USDG, chosen.params.collateralToken, chosen.params.oracle);
                _fundShim();
                vault.setDexRouter(address(shimRouter));
            } else {
                vault.setDexRouter(0xCaf681a66D020601342297493863E78C959E5cb2);
            }
        }
        vm.stopPrank();
    }

    /// @dev Stocks the stand-in router with both legs so it can fill in either direction
    function _fundShim() internal {
        try this.dealExternal(chosen.params.collateralToken, address(shimRouter), 1_000_000e18) {} catch {}
        try this.dealExternal(USDG, address(shimRouter), 10_000_000e6) {} catch {}
    }

    function _depositAll() internal {
        _fundUser(DEPOSIT_AMOUNT);

        vm.startPrank(user);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    /// @dev `deal` rewrites USDG's balance storage on this chain (verified by the chassis fork suite); the
    ///      `ROBINHOOD_USDG_WHALE` fallback covers a future Paxos implementation change.
    function _fundUser(uint256 amount) internal {
        try this.dealExternal(USDG, user, amount) {} catch {}

        if (IERC20(USDG).balanceOf(user) < amount) {
            address whale = vm.envOr("ROBINHOOD_USDG_WHALE", address(0));
            require(whale != address(0), "deal() failed on USDG - set ROBINHOOD_USDG_WHALE and rerun");
            vm.prank(whale);
            IERC20(USDG).transfer(user, amount);
        }

        assertGe(IERC20(USDG).balanceOf(user), amount, "could not source USDG for the test user");
    }

    /// @dev `deal` is internal to StdCheats; this wrapper makes it try/catch-able.
    function dealExternal(address token, address to, uint256 give) external {
        deal(token, to, give);
    }

    /// @dev Half the market's liquidation LTV — a deliberately conservative production-shaped target
    function _targetLtvBps() internal view returns (uint256) {
        return ((chosen.params.lltv * 10000) / 1e18) / 2;
    }

    // ==================== READ HELPERS ====================

    function _sortByLiquidity() internal {
        for (uint256 i = 0; i < candidates.length; i++) {
            uint256 best = i;
            for (uint256 j = i + 1; j < candidates.length; j++) {
                if (candidates[j].liquidity > candidates[best].liquidity) best = j;
            }
            if (best != i) {
                Candidate memory tmp = candidates[i];
                candidates[i] = candidates[best];
                candidates[best] = tmp;
            }
        }
    }

    function _logCandidate(string memory prefix, Candidate memory c) internal view {
        console.log(
            "%s%s / USDG  LLTV %s bps",
            prefix,
            _symbol(c.params.collateralToken),
            vm.toString((c.params.lltv * 10000) / 1e18)
        );
        console.log(
            "         supply %s  borrow %s  free %s USDG",
            _usdg(c.supplyAssets),
            _usdg(c.borrowAssets),
            _usdg(c.liquidity)
        );
        console.log(
            "         oracle price %s   borrow ~%s bps/yr   route %s",
            vm.toString(c.price),
            vm.toString((c.borrowRatePerSecond * 365 days * 10000) / 1e18),
            c.routeProbed ? _routeName(c.route) : "not probed"
        );
    }

    function _routeName(BoostedUsdgVault.CollateralRoute route) internal pure returns (string memory) {
        if (route == BoostedUsdgVault.CollateralRoute.ERC4626) return "ERC4626 primary market";
        if (route == BoostedUsdgVault.CollateralRoute.DEX) return "Uniswap v3";
        return "NONE (unreachable)";
    }

    function _symbol(address token) internal view returns (string memory) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (!ok || ret.length < 64) return vm.toString(token);
        return abi.decode(ret, (string));
    }

    /// @dev Formats a 6-decimal USDG amount with two decimal places
    function _usdg(uint256 amount) internal pure returns (string memory) {
        uint256 cents = (amount % 1e6) / 1e4;
        string memory fraction = cents < 10 ? string.concat("0", vm.toString(cents)) : vm.toString(cents);
        return string.concat(vm.toString(amount / 1e6), ".", fraction);
    }

    /// @dev Simple (non-compounded) annualisation of `gain` on `base` observed over `window` seconds, in bps
    function _annualisedBps(uint256 gain, uint256 base, uint256 window) internal pure returns (uint256) {
        if (base == 0 || window == 0) return 0;
        return (gain * 365 days * 10000) / (base * window);
    }

    function _tryPrice(address oracle) internal view returns (uint256) {
        (bool ok, bytes memory ret) = oracle.staticcall(abi.encodeWithSignature("price()"));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256));
    }

    function _tryBorrowRate(MarketParams memory params, Id id) internal view returns (uint256) {
        Market memory m = IMorphoBlue(MORPHO_BLUE).market(id);
        try IMorphoIrm(params.irm).borrowRateView(params, m) returns (uint256 rate) {
            return rate;
        } catch {
            return 0;
        }
    }

    function _tryPreviewDeposit(address vaultToken) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            vaultToken.staticcall(abi.encodeWithSignature("previewDeposit(uint256)", uint256(1e6)));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256));
    }

    function _tryReadAddress(address target, string memory signature) internal view returns (bool, address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        if (!ok || ret.length != 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }

    function _getPool(address tokenA, address tokenB, uint24 fee) internal view returns (address) {
        (bool ok, bytes memory ret) = UNISWAP_V3_FACTORY.staticcall(
            abi.encodeWithSignature("getPool(address,address,uint24)", tokenA, tokenB, fee)
        );
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    /// @dev QuoterV2 reverts internally and decodes its own revert data, so it cannot be called as a view
    function _quote(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee) internal returns (uint256) {
        (bool ok, bytes memory ret) = UNISWAP_QUOTER_V2.call{gas: QUOTE_GAS_LIMIT}(
            abi.encodeWithSignature(
                "quoteExactInputSingle((address,address,uint256,uint24,uint160))",
                tokenIn,
                tokenOut,
                amountIn,
                fee,
                uint160(0)
            )
        );
        if (!ok || ret.length < 128) return 0;

        (uint256 amountOut,,,) = abi.decode(ret, (uint256, uint160, uint32, uint256));
        return amountOut;
    }
}
