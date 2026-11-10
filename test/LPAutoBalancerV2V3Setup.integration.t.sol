// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2WethCbbtcV3Setup} from "../multisig/mamo-multisig/022_LPAutoBalancerV2WethCbbtcV3Setup.sol";

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPGeometryLib} from "@contracts/libraries/LPGeometryLib.sol";
import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";
import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {ICLPositionManager} from "@interfaces/ICLPositionManager.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IPriceFeed} from "@interfaces/IPriceFeed.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AddressBookHarness} from "./harness/AddressBookHarness.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/// @notice Base-fork run of proposal 022 (WETH/cbBTC Slipstream V3 activation): mint the V3 NFT to
///         F-MAMO, deploy → build → simulate → validate, then stake, claim and exit on the result.
/// @dev Self-forks at a pinned block (NO --fork-url; see the Makefile's lp-v3-setup target).
contract LPAutoBalancerV2V3SetupTest is Test {
    // Above the newest book entry (V3 gauge, 52_913_506) and late enough that it emits; the shared
    // book pin 52_915_000 reads zero earned AERO_V3 after the accrual below.
    uint256 constant PINNED_BLOCK = 52_964_000;
    uint256 constant TARGET_ALLOCATION_USD = 25_000e8;
    int24 constant HALF_WIDTH = 400;
    // Proposal 022's Safe batch: 2 guards + deposit + register + grant + 6 module/allowance setters.
    uint256 constant EXPECTED_ACTIONS = 11;
    string constant BALANCER = "MAMO_LP_AUTO_BALANCER_V2_WETH_CBBTC_V3";
    string constant MODULE = "MAMO_LP_COMPOUND_MODULE_WETH_CBBTC_V3";

    LPAutoBalancerV2WethCbbtcV3Setup proposal;
    Addresses addresses;

    address safe;
    address pool;
    address gauge;
    address nfpm;
    address weth;
    address cbbtc;
    address rebalancerEOA = makeAddr("lpV3Rebalancer");
    uint256 tokenId;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // op-revm Isthmus operator-fee workaround (see LPAutoBalancerV2.integration.t.sol).
        vm.txGasPrice(0);
        vm.fee(0);

        addresses = AddressBookHarness.build("./addresses");
        vm.makePersistent(address(addresses));
        // After the real deploy the book records 022's contracts, which have no code at this pin:
        // forget them so the replay deploys and registers its own.
        if (addresses.isAddressSet(BALANCER)) AddressBookHarness.forget(addresses, BALANCER);
        if (addresses.isAddressSet(MODULE)) AddressBookHarness.forget(addresses, MODULE);

        safe = addresses.getAddress("F-MAMO");
        pool = addresses.getAddress("WETH_CBBTC_V3_CL_POOL");
        gauge = addresses.getAddress("WETH_CBBTC_V3_CL_GAUGE");
        nfpm = addresses.getAddress("AERODROME_SLIPSTREAM_NFPM_V3");
        weth = addresses.getAddress("WETH");
        cbbtc = addresses.getAddress("cbBTC");

        tokenId = _mintAllocation(safe, pool, 1, TARGET_ALLOCATION_USD);

        proposal = new LPAutoBalancerV2WethCbbtcV3Setup();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
        proposal.setTokenId(tokenId);
        proposal.setRebalancerEOA(rebalancerEOA);
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD, 500);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _price(string memory feed) internal view returns (uint256) {
        (, int256 answer,,,) = IPriceFeed(addresses.getAddress(feed)).latestRoundData();
        return uint256(answer);
    }

    /// @dev Mint a WETH/cbBTC position on the V3 NFPM worth ~`targetUsd`, sized from the range geometry.
    function _mintAllocation(address to, address pool_, int24 spacing, uint256 targetUsd) internal returns (uint256) {
        (uint160 sqrtP, int24 spot,,,,) = ICLPool(pool_).slot0();
        int24 center = (spot / spacing) * spacing;
        int24 tl = center - HALF_WIDTH;
        int24 tu = center + HALF_WIDTH;
        (uint256 r0, uint256 r1) = LPGeometryLib.amountsForLiquidityAtTicks(sqrtP, tl, tu, 1e18);
        uint256 refUsd = (r0 * _price("CHAINLINK_ETH_USD")) / 1e18 + (r1 * _price("CHAINLINK_BTC_USD")) / 1e8;
        uint256 amt0 = (r0 * targetUsd * 10_050) / (refUsd * 10_000);
        uint256 amt1 = (r1 * targetUsd * 10_050) / (refUsd * 10_000);

        deal(weth, address(this), amt0);
        deal(cbbtc, address(this), amt1);
        IERC20(weth).approve(nfpm, amt0);
        IERC20(cbbtc).approve(nfpm, amt1);
        (uint256 id,,,) = ICLPositionManager(nfpm)
            .mint(
                ICLPositionManager.MintParams({
                token0: weth,
                token1: cbbtc,
                tickSpacing: spacing,
                tickLower: tl,
                tickUpper: tu,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: to,
                deadline: block.timestamp + 1,
                sqrtPriceX96: 0
            })
            );
        return id;
    }

    /// @dev Sum of `token` mints to `to` in the logs recorded since the last vm.recordLogs().
    function _mintedTo(address token, address to) internal returns (uint256 sum) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == token && logs[i].topics.length == 3 && logs[i].topics[0] == transferSig
                    && logs[i].topics[1] == bytes32(0) && logs[i].topics[2] == bytes32(uint256(uint160(to)))
            ) sum += abi.decode(logs[i].data, (uint256));
        }
    }

    function _lab() internal view returns (LPAutoBalancerV2) {
        return LPAutoBalancerV2(payable(addresses.getAddress(BALANCER)));
    }

    function _runProposal() internal {
        proposal.deploy();
        proposal.build();
        proposal.simulate();
        proposal.validate();
    }

    function test_proposal_lifecycle() public {
        assertFalse(addresses.isAddressSet(BALANCER), "not deployed before (or forgotten in setUp)");
        assertEq(INonfungiblePositionManager(nfpm).ownerOf(tokenId), safe, "F-MAMO holds the V3 NFT");

        _runProposal();
        LPAutoBalancerV2 lab = _lab();
        assertTrue(addresses.isAddressSet(MODULE), "module registered");
        (address[] memory targets,,) = proposal.getProposalActions();
        assertEq(targets.length, EXPECTED_ACTIONS, "Safe batch size");
        assertEq(INonfungiblePositionManager(nfpm).ownerOf(tokenId), address(lab), "balancer holds the NFT");

        // Stake as the granted rebalancer: the NFT moves into the V3 gauge under the balancer.
        vm.prank(rebalancerEOA);
        lab.stake();
        assertEq(INonfungiblePositionManager(nfpm).ownerOf(tokenId), gauge, "NFT in the V3 gauge");
        assertTrue(ICLGauge(gauge).stakedContains(address(lab), tokenId), "staked for the balancer");

        // feeCollector == balancer: a claim keeps the AERO_V3 on the balancer; nothing reaches DROP.
        skip(2 hours);
        vm.roll(block.number + 3_600);
        address module = addresses.getAddress(MODULE);
        address drop = addresses.getAddress("DROP_AUTOMATION");
        IERC20 aeroV3 = IERC20(addresses.getAddress("AERO_V3"));
        IERC20 aeroV1 = IERC20(addresses.getAddress("AERO"));
        uint256 dropV3 = aeroV3.balanceOf(drop);
        uint256 dropV1 = aeroV1.balanceOf(drop);
        vm.recordLogs();
        vm.prank(rebalancerEOA);
        lab.claimEmissions();
        uint256 claimed = aeroV3.balanceOf(address(lab));
        assertEq(claimed, _mintedTo(address(aeroV3), address(lab)), "balancer holds exactly its mint");
        assertGt(claimed, 0, "claim kept AERO_V3 on the balancer");
        assertEq(aeroV3.balanceOf(module), 0, "claim sends nothing to the module");

        // compound(50%) splits the WHOLE balance, earlier claim included: half stays, half to the module.
        skip(1 hours);
        vm.roll(block.number + 1_800);
        vm.prank(rebalancerEOA);
        lab.compound(5_000);
        uint256 kept = aeroV3.balanceOf(address(lab));
        uint256 total = kept + aeroV3.balanceOf(module);
        assertGt(total, claimed, "compound harvested fresh emissions");
        assertEq(kept, total * 5_000 / 10_000, "drop share stays on the balancer");

        // compound(100%) empties the balancer into the module: the path out of the drop share.
        vm.prank(rebalancerEOA);
        lab.compound(10_000);
        assertEq(aeroV3.balanceOf(address(lab)), 0, "balancer emptied");
        assertEq(aeroV3.balanceOf(module), total, "all of it to the module (same block: nothing fresh)");
        assertEq(aeroV3.balanceOf(drop), dropV3, "DROP_AUTOMATION never receives AERO_V3");
        assertEq(aeroV1.balanceOf(drop), dropV1, "no legacy AERO involved");

        // Accrue again so exit's unstake claims something.
        skip(1 hours);
        vm.roll(block.number + 1_800);

        // Exit as F-MAMO: the recipient gets exactly the position's principal at the current price.
        (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = INonfungiblePositionManager(nfpm).positions(tokenId);
        (uint160 sqrtP,,,,,) = ICLPool(pool).slot0();
        (uint256 exp0, uint256 exp1) = LPGeometryLib.amountsForLiquidityAtTicks(sqrtP, tl, tu, liq);
        assertGt(exp0, 0, "in-range: WETH leg");
        assertGt(exp1, 0, "in-range: cbBTC leg");
        address to = makeAddr("exitTo");
        vm.recordLogs();
        vm.prank(safe);
        lab.exit(to);
        uint256 exitMint = _mintedTo(address(aeroV3), address(lab));
        assertEq(IERC20(weth).balanceOf(to), exp0, "exact WETH principal");
        assertEq(IERC20(cbbtc).balanceOf(to), exp1, "exact cbBTC principal");
        (,,,,,,,,,,,,,,,,,,,, bool active) = lab.position();
        assertFalse(active, "inactive after exit");

        // exit's unstake claim stays on the balancer (compound needs an active position): the Safe recovers it.
        uint256 left = aeroV3.balanceOf(address(lab));
        assertGt(left, 0, "exit claim kept on the balancer");
        assertEq(left, exitMint, "exactly the exit mint");
        assertEq(IERC20(aeroV3).balanceOf(to), 0, "exit recipient gets no AERO_V3");
        vm.prank(safe);
        lab.recoverERC20(address(aeroV3), safe, left);
        assertEq(aeroV3.balanceOf(address(lab)), 0, "nothing stranded on the balancer");
    }

    /// @notice Pins every Safe action and its order; the armed delays equal the ctor default, so only
    ///         the calldata shows that setMaxOracleDelays runs, and before registerPosition.
    function test_actions_exactTargetsAndCalldata() public {
        _runProposal();
        LPAutoBalancerV2 lab = _lab();
        address module = addresses.getAddress(MODULE);
        (address[] memory t, uint256[] memory v, bytes[] memory d) = proposal.getProposalActions();
        assertEq(t.length, EXPECTED_ACTIONS, "Safe batch size");
        for (uint256 i; i < v.length; i++) {
            assertEq(v[i], 0, "no value");
        }

        _assertAction(
            t[0],
            d[0],
            address(lab),
            abi.encodeWithSignature(
                "setSequencerUptimeFeed(address,uint256)",
                addresses.getAddress("CHAINLINK_L2_SEQUENCER_UPTIME_FEED"),
                3600
            )
        );
        _assertAction(
            t[1], d[1], address(lab), abi.encodeWithSignature("setMaxOracleDelays(uint256,uint256)", 3600, 3600)
        );
        _assertAction(
            t[2],
            d[2],
            nfpm,
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", safe, address(lab), tokenId)
        );
        assertEq(t[3], address(lab), "registerPosition target");
        assertEq(bytes4(d[3]), LPAutoBalancerV2.registerPosition.selector, "registerPosition selector");
        LPAutoBalancerV2.ManagedPositionV2 memory c = abi.decode(_args(d[3]), (LPAutoBalancerV2.ManagedPositionV2));
        assertEq(c.mainTokenId, tokenId, "registered tokenId");
        assertEq(c.pool, pool, "registered pool");
        assertEq(c.gauge, gauge, "registered gauge");
        assertEq(int256(c.tickSpacing), 1, "registered spacing");
        assertEq(c.feeCollector, address(lab), "registered feeCollector is the balancer");
        _assertAction(
            t[4],
            d[4],
            address(lab),
            abi.encodeWithSignature("grantRole(bytes32,address)", lab.REBALANCER_ROLE(), rebalancerEOA)
        );
        _assertAction(t[5], d[5], address(lab), abi.encodeWithSignature("setCompoundModule(address)", module));
        _assertAction(
            t[6],
            d[6],
            module,
            abi.encodeWithSignature(
                "setSlippagePriceChecker(address)", addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY")
            )
        );
        _assertAction(t[7], d[7], module, abi.encodeWithSignature("setSlippage(uint256)", 200));
        _assertAction(t[8], d[8], module, abi.encodeWithSignature("setRebalanceSlippageBps(uint256)", 50));
        _assertAction(
            t[9], d[9], module, abi.encodeWithSignature("setCompoundAppData(bytes32)", keccak256("mamo-lpv2-compound"))
        );
        _assertAction(t[10], d[10], address(lab), abi.encodeWithSignature("setSwapLossAllowanceBps(uint16)", 300));
    }

    function _assertAction(address target, bytes memory data, address expTarget, bytes memory expData) internal pure {
        assertEq(target, expTarget, "action target");
        assertEq(data, expData, "action calldata");
    }

    function _args(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    /// @notice Non-vacuity of the allocation band: same position, wrong target, validate() fails.
    function test_validate_rejectsWrongAllocation() public {
        _runProposal();
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD * 2, 500);
        vm.expectRevert("position under-allocated vs totalAllocationUsd");
        proposal.validate();
        proposal.setTotalAllocation(TARGET_ALLOCATION_USD / 2, 500);
        vm.expectRevert("position over-allocated vs totalAllocationUsd");
        proposal.validate();
    }

    /// @notice A V3 NFT of another pool (CL10, tickSpacing 10) is refused before any action is recorded.
    function test_build_rejectsOtherPoolPosition() public {
        address cl10Pool = ICLGauge(0x5b14d6D194E49330647eB4717010aDe1B1B3f8B5).pool();
        uint256 otherId = _mintAllocation(safe, cl10Pool, 10, TARGET_ALLOCATION_USD);
        proposal.setTokenId(otherId);
        proposal.deploy();
        vm.expectRevert("tokenId is not a V3 pool position");
        proposal.build();
    }

    /// @notice A V3 NFT on the right pool but emptied of liquidity is refused.
    function test_build_rejectsZeroLiquidityPosition() public {
        uint256 emptyId = _mintAllocation(address(this), pool, 1, TARGET_ALLOCATION_USD);
        (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManager(nfpm).positions(emptyId);
        INonfungiblePositionManager(nfpm)
            .decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: emptyId, liquidity: liq, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
            );
        INonfungiblePositionManager(nfpm).safeTransferFrom(address(this), safe, emptyId);
        proposal.setTokenId(emptyId);
        proposal.deploy();
        vm.expectRevert("tokenId has no liquidity");
        proposal.build();
    }

    function test_build_rejectsTokenNotHeldBySafe() public {
        uint256 strayId = _mintAllocation(address(this), pool, 1, TARGET_ALLOCATION_USD);
        proposal.setTokenId(strayId);
        proposal.deploy();
        vm.expectRevert("F-MAMO does not hold tokenId");
        proposal.build();
    }

    /// @notice The production input path: run() reads the per-run inputs from the env.
    function test_runLoadsInputsFromEnv() public {
        vm.setEnv("DO_DEPLOY", "false");
        vm.setEnv("DO_BUILD", "false");
        vm.setEnv("DO_SIMULATE", "false");
        vm.setEnv("DO_VALIDATE", "false");
        vm.setEnv("DO_PRINT", "false");
        vm.setEnv("INIT_TOKEN_ID", "424242");
        vm.setEnv("TOTAL_ALLOCATION_USD", "1234500000000");
        vm.setEnv("ALLOCATION_TOLERANCE_BPS", "250");

        LPAutoBalancerV2WethCbbtcV3Setup p = new LPAutoBalancerV2WethCbbtcV3Setup();
        p.setPrimaryForkId(vm.activeFork());
        assertEq(p.tokenId(), 0, "tokenId starts unset");
        // run() builds its own book: lend code to entries newer than the pin for that constructor.
        address[] memory lent = AddressBookHarness.lendCodeToEntriesDeployedAfterThePin("./addresses");
        p.run();
        AddressBookHarness.returnLoan(lent);
        (uint256 id, uint256 alloc, uint16 tol) = (p.tokenId(), p.totalAllocationUsd(), p.allocationToleranceBps());

        // vm.setEnv is process-global: restore the defaults BEFORE asserting, so a failure cannot leak.
        vm.setEnv("DO_DEPLOY", "true");
        vm.setEnv("DO_BUILD", "true");
        vm.setEnv("DO_SIMULATE", "true");
        vm.setEnv("DO_VALIDATE", "true");
        vm.setEnv("DO_PRINT", "true");
        vm.setEnv("INIT_TOKEN_ID", "0");
        vm.setEnv("TOTAL_ALLOCATION_USD", "5000000000000");
        vm.setEnv("ALLOCATION_TOLERANCE_BPS", "500");

        assertEq(id, 424_242, "tokenId from INIT_TOKEN_ID");
        assertEq(alloc, 1_234_500_000_000, "allocation from TOTAL_ALLOCATION_USD");
        assertEq(tol, 250, "tolerance from ALLOCATION_TOLERANCE_BPS");
    }
}
