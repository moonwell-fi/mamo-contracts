// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {LPValuationLib} from "@contracts/libraries/LPValuationLib.sol";
import {ICLGauge, ICLGaugeV3} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {DeployLPAutoBalancerV2Pair} from "@script/DeployLPAutoBalancerV2Pair.s.sol";
import {LPPairConfig} from "@script/LPPairConfig.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

/// @title LPAutoBalancerV2WethCbbtcV3Setup
/// @notice F-MAMO proposal activating LPAutoBalancerV2 on the WETH/cbBTC Slipstream V3 (CL1) pool.
///         deploy(): balancer + compound module via DeployLPAutoBalancerV2Pair (V3 NFPM, AERO_V3),
///         registered as MAMO_LP_AUTO_BALANCER_V2_WETH_CBBTC_V3 / MAMO_LP_COMPOUND_MODULE_WETH_CBBTC_V3.
///         build(), as F-MAMO: sequencer guard, oracle delays, deposit of the pre-minted V3 NFT,
///         registerPosition, REBALANCER_ROLE grant, compound-module setters. Same order as 011.
/// @dev    PRECONDITION: F-MAMO holds a WETH/cbBTC position NFT of the V3 NFPM (tickSpacing 1),
///         passed as INIT_TOKEN_ID. The position is registered UNSTAKED; the rebalancer stakes it.
///         Deferred as in 011 (checker owner is not F-MAMO): AERO_V3 checker config and
///         module.approveCowSwap(). AERO here is AERO_V3, which CHAINLINK_AERO_USD does not price.
contract LPAutoBalancerV2WethCbbtcV3Setup is MultisigProposal {
    using LPPairConfig for LPPairConfig.Pair;

    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;
    uint256 public constant COMPOUND_SLIPPAGE_BPS = 200;
    uint256 public constant REBALANCE_SLIPPAGE_BPS = 50;
    bytes32 public constant COMPOUND_APP_DATA = keccak256("mamo-lpv2-compound");
    uint16 public constant SWAP_LOSS_ALLOWANCE_BPS = 300;

    /// @notice The pre-minted V3 NFT held by F-MAMO. No default.
    uint256 public tokenId;
    /// @notice Rebalancer override; MAMO_LP_REBALANCER when unset.
    address public rebalancerEOA;
    /// @notice Allocation validate() checks the principal against, 8-dec USD, and its band.
    uint256 public totalAllocationUsd = 50_000e8;
    uint16 public allocationToleranceBps = 500;

    function setTokenId(uint256 tokenId_) external {
        tokenId = tokenId_;
    }

    function setRebalancerEOA(address rebalancerEOA_) external {
        rebalancerEOA = rebalancerEOA_;
    }

    function setTotalAllocation(uint256 totalAllocationUsd_, uint16 allocationToleranceBps_) external {
        require(totalAllocationUsd_ != 0, "totalAllocationUsd must be non-zero");
        require(allocationToleranceBps_ < 10_000, "tolerance >= 100%");
        totalAllocationUsd = totalAllocationUsd_;
        allocationToleranceBps = allocationToleranceBps_;
    }

    function name() public pure override returns (string memory) {
        return "022_LPAutoBalancerV2WethCbbtcV3Setup";
    }

    function description() public pure override returns (string memory) {
        return "Deploy LPAutoBalancerV2 + LPCompoundModule for WETH/cbBTC Slipstream V3, deposit the pre-minted V3 NFT held by F-MAMO, register the position, grant REBALANCER_ROLE and wire the compound module.";
    }

    /// @notice Production entrypoint: inputs from the env (setters win), deploy without the base
    ///         run()'s outer broadcast, since deployPair broadcasts its own CREATEs.
    function run() public override {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));

        if (tokenId == 0) tokenId = vm.envOr("INIT_TOKEN_ID", uint256(0));
        totalAllocationUsd = vm.envOr("TOTAL_ALLOCATION_USD", totalAllocationUsd);
        uint256 tol = vm.envOr("ALLOCATION_TOLERANCE_BPS", uint256(allocationToleranceBps));
        require(totalAllocationUsd != 0 && tol < 10_000, "bad allocation inputs");
        allocationToleranceBps = uint16(tol);

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

    function pair() public view returns (LPPairConfig.Pair memory) {
        return LPPairConfig.wethCbbtcV3(addresses);
    }

    function deploy() public override {
        LPPairConfig.Pair memory p = pair();
        if (addresses.isAddressSet(p.balancerName())) return;
        address safe = addresses.getAddress("F-MAMO");
        new DeployLPAutoBalancerV2Pair().deployPair(addresses, p, safe, safe, address(0), address(0));
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        LPPairConfig.Pair memory p = pair();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress(p.balancerName())));
        address rebalancer = _resolveRebalancer();
        _requirePreMint(p);

        // Guards first: registerPosition probes both feeds under them.
        lab.setSequencerUptimeFeed(addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"), SEQUENCER_GRACE_PERIOD);
        lab.setMaxOracleDelays(p.maxOracleDelay0, p.maxOracleDelay1);

        INonfungiblePositionManager(addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V3"))
            .safeTransferFrom(addresses.getAddress("F-MAMO"), address(lab), tokenId);
        lab.registerPosition(_config(p));
        lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);

        _wireModule(lab, p);
    }

    /// @dev A wrong tokenId fails the simulation here, not the Safe execution.
    function _requirePreMint(LPPairConfig.Pair memory p) internal view {
        require(tokenId != 0, "tokenId not set: mint the V3 NFT to F-MAMO and set INIT_TOKEN_ID");
        INonfungiblePositionManager nfpm =
            INonfungiblePositionManager(addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V3"));
        require(nfpm.ownerOf(tokenId) == addresses.getAddress("F-MAMO"), "F-MAMO does not hold tokenId");
        (,, address t0, address t1, int24 ts,,, uint128 liq,,,,) = nfpm.positions(tokenId);
        require(t0 == p.token0 && t1 == p.token1 && ts == p.tickSpacing, "tokenId is not a V3 pool position");
        require(liq > 0, "tokenId has no liquidity");
    }

    function _config(LPPairConfig.Pair memory p) internal view returns (LPAutoBalancerV2.ManagedPositionV2 memory c) {
        c.mainTokenId = tokenId;
        c.pool = p.pool;
        c.token0 = p.token0;
        c.token1 = p.token1;
        c.tickSpacing = p.tickSpacing;
        c.gauge = p.gauge;
        c.feeCollector = addresses.getAddress("DROP_AUTOMATION");
        c.oracle0 = p.oracle0;
        c.oracle1 = p.oracle1;
        c.minWidth = p.minWidth;
        c.maxWidth = p.maxWidth;
        c.maxCenterDeviation = p.maxCenterDeviation;
        c.twapWindow = p.twapWindow;
        c.maxTickDeviation = p.maxTickDeviation;
        c.maxRebalanceLossBps = p.maxRebalanceLossBps;
        c.minRebalanceInterval = p.minRebalanceInterval;
    }

    function _wireModule(LPAutoBalancerV2 lab, LPPairConfig.Pair memory p) internal {
        LPCompoundModule module = LPCompoundModule(addresses.getAddress(p.moduleName()));
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
        LPPairConfig.Pair memory p = pair();
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress(p.balancerName())));
        address safe = addresses.getAddress("F-MAMO");

        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), safe), "admin is F-MAMO");
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), safe), "guardian is F-MAMO");
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), _resolveRebalancer()), "rebalancer granted");

        assertEq(lab.sequencerUptimeFeed(), addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"), "seq feed");
        assertEq(lab.sequencerGracePeriod(), SEQUENCER_GRACE_PERIOD, "seq grace");
        assertEq(lab.maxOracleDelay0(), p.maxOracleDelay0, "oracle0 delay");
        assertEq(lab.maxOracleDelay1(), p.maxOracleDelay1, "oracle1 delay");

        _validateVenue(lab, p);
        _validatePosition(lab, p);
        _validateAllocation(lab, p);
        _validateModule(lab, p, safe);
    }

    /// @notice The balancer is built for V3 and the gauge is the pool's V3 gauge.
    function _validateVenue(LPAutoBalancerV2 lab, LPPairConfig.Pair memory p) internal view {
        address nfpm = addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V3");
        assertEq(address(lab.POSITION_MANAGER()), nfpm, "balancer NFPM is V3");
        assertEq(lab.AERO(), addresses.getAddress("AERO_V3"), "balancer AERO is AERO_V3");
        (bool ok, bytes memory ret) = p.gauge.staticcall(abi.encodeCall(ICLGaugeV3.depositBlock, (0)));
        assertTrue(ok && ret.length == 32, "gauge is V3");
        assertEq(ICLPool(p.pool).gauge(), p.gauge, "pool.gauge() == gauge");
        assertEq(ICLGauge(p.gauge).nft(), nfpm, "gauge.nft() == V3 NFPM");
    }

    function _validatePosition(LPAutoBalancerV2 lab, LPPairConfig.Pair memory p) internal view {
        LPAutoBalancerV2.ManagedPositionV2 memory c = _position(lab);
        assertTrue(c.active, "position active");
        assertEq(c.mainTokenId, tokenId, "mainTokenId");
        assertEq(c.altTokenId, 0, "no alt");
        assertEq(c.pool, p.pool, "pool");
        assertEq(c.token0, p.token0, "token0");
        assertEq(c.token1, p.token1, "token1");
        assertEq(int256(c.tickSpacing), int256(p.tickSpacing), "tickSpacing");
        assertEq(c.gauge, p.gauge, "gauge");
        assertFalse(c.mainStaked, "registered unstaked");
        assertEq(c.feeCollector, addresses.getAddress("DROP_AUTOMATION"), "feeCollector");
        assertEq(c.oracle0, p.oracle0, "oracle0");
        assertEq(c.oracle1, p.oracle1, "oracle1");
        assertEq(c.minWidth, p.minWidth, "minWidth");
        assertEq(c.maxWidth, p.maxWidth, "maxWidth");
        assertEq(c.maxCenterDeviation, p.maxCenterDeviation, "maxCenterDeviation");
        assertEq(c.twapWindow, p.twapWindow, "twapWindow");
        assertEq(int256(c.maxTickDeviation), int256(p.maxTickDeviation), "maxTickDeviation");
        assertEq(c.maxRebalanceLossBps, p.maxRebalanceLossBps, "maxRebalanceLossBps");
        assertEq(c.minRebalanceInterval, p.minRebalanceInterval, "minRebalanceInterval");
        assertEq(
            INonfungiblePositionManager(addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V3")).ownerOf(tokenId),
            address(lab),
            "balancer holds the NFT"
        );
    }

    /// @dev The 21-field getter decoded into memory: destructuring it overflows the via_ir stack,
    ///      and `this.` helpers are refused under `forge script`.
    function _position(LPAutoBalancerV2 lab) internal view returns (LPAutoBalancerV2.ManagedPositionV2 memory) {
        (bool ok, bytes memory ret) = address(lab).staticcall(abi.encodeCall(lab.position, ()));
        require(ok, "position() failed");
        return abi.decode(ret, (LPAutoBalancerV2.ManagedPositionV2));
    }

    /// @notice Principal priced with the balancer's own feeds and guards lands inside the band.
    function _validateAllocation(LPAutoBalancerV2 lab, LPPairConfig.Pair memory p) internal view {
        LPValuationLib.OracleConfig memory cfg = LPValuationLib.OracleConfig({
            oracle0: p.oracle0,
            oracle1: p.oracle1,
            maxDelay0: lab.maxOracleDelay0(),
            maxDelay1: lab.maxOracleDelay1(),
            sequencerUptimeFeed: lab.sequencerUptimeFeed(),
            sequencerGracePeriod: lab.sequencerGracePeriod()
        });
        (uint160 sqrtP,,,,,) = ICLPool(p.pool).slot0();
        uint256 principalUsd = LPValuationLib.principalValue(
            addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V3"), tokenId, sqrtP, cfg, p.decimals0, p.decimals1
        );
        uint256 lo = (totalAllocationUsd * (10_000 - allocationToleranceBps)) / 10_000;
        uint256 hi = (totalAllocationUsd * (10_000 + allocationToleranceBps)) / 10_000;
        assertTrue(principalUsd >= lo, "position under-allocated vs totalAllocationUsd");
        assertTrue(principalUsd <= hi, "position over-allocated vs totalAllocationUsd");
    }

    function _validateModule(LPAutoBalancerV2 lab, LPPairConfig.Pair memory p, address safe) internal view {
        LPCompoundModule module = LPCompoundModule(addresses.getAddress(p.moduleName()));
        assertEq(lab.compoundModule(), address(module), "balancer wired to module");
        assertEq(module.balancer(), address(lab), "module bound to balancer");
        assertEq(module.AERO(), addresses.getAddress("AERO_V3"), "module AERO is AERO_V3");
        assertTrue(module.hasRole(module.DEFAULT_ADMIN_ROLE(), safe), "module admin is F-MAMO");
        assertEq(module.allowedSlippageInBps(), COMPOUND_SLIPPAGE_BPS, "slippage");
        assertEq(module.rebalanceSlippageBps(), REBALANCE_SLIPPAGE_BPS, "rebalance slippage");
        assertEq(module.compoundAppData(), COMPOUND_APP_DATA, "appData");
        assertEq(
            address(module.slippagePriceChecker()), addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"), "checker"
        );
        assertEq(lab.swapLossAllowanceBps(), SWAP_LOSS_ALLOWANCE_BPS, "swap loss allowance");
    }

    function _resolveRebalancer() internal view returns (address) {
        if (rebalancerEOA != address(0)) return rebalancerEOA;
        return addresses.getAddress("MAMO_LP_REBALANCER");
    }
}
