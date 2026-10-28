// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockDropCutover} from "../multisig/f-mamo/006_StockDropCutover.sol";
import {DeployStockDrop} from "../multisig/mamo-multisig/017_DeployStockDrop.sol";

import {DropAutomationV2} from "@contracts/DropAutomationV2.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
import {MamoStakingStrategyV2} from "@contracts/MamoStakingStrategyV2.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {IAerodromeGauge} from "@interfaces/IAerodromeGauge.sol";
import {IAerodromeVoter} from "@interfaces/IAerodromeVoter.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

/// @dev The live V1 staking implementation, which predates the compound deadline
interface ILiveStakingStrategy {
    function compound() external;
}

/// @notice Base-fork rehearsal of the stock drop launch on the live stock accounts v2 system (019 and 021 executed):
///         mamo-multisig/017, with the price checker hardening of 013 inside it, then f-mamo/006, which also starts
///         the in-kind streams, through the real Safes. Then the lifecycle on the result: a live staking account
///         upgrades and repoints itself, a drop tops up the running streams and starts WETH and USDC ones, the account
///         compounds all three through the live pools, an account left on V1 parks the new tokens until its upgrade
///         sweeps them, and a v2 stock account pays its fee to DropAutomationV2.
/// @dev The B20 stocks cannot execute in revm (code 0xEF), so their drop, compound and reinvest legs are covered by
///      the unit suites. Self-forks at a pinned block, so it runs without --fork-url.
contract StockDropSetupTest is Test {
    /// @dev After 019 (52,830,279) and 021 (53,132,330); v1's USDC/AERO gauge is killed, the cbBTC stream is running
    uint256 internal constant PINNED_BLOCK = 53_200_000;

    address internal constant DEPLOYER_EOA = 0xDca82E03057329f53Ed4173429D46B0511E46Fb8;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    /// @dev AAPLc's pool before 021
    address internal constant AAPLC_OLD_POOL = 0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0;

    uint256 internal constant STAKE = 10_000_000e18;
    uint256 internal constant DROP_MAMO = 100_000e18;
    uint256 internal constant DROP_CBBTC = 0.05e8;
    uint256 internal constant DROP_WETH = 1e18;
    uint256 internal constant DROP_USDC = 5_000e6;
    uint256 internal constant USDC_DEPOSIT = 5_000e6;

    Addresses internal addresses;
    address internal user = makeAddr("stockDropUser");
    address internal lateUser = makeAddr("stockDropLateUser");

    DeployStockDrop internal deployProposal;
    StockDropCutover internal cutoverProposal;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        // The deployer's EIP-7702 delegation reads as a contract to FPS; a nonce-0 throwaway replaces it anyway
        vm.etch(DEPLOYER_EOA, "");
        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));
        addresses.changeAddress("DEPLOYER_EOA", makeAddr("stockDropDeployer"), false);

        deployProposal = new DeployStockDrop();
        cutoverProposal = new StockDropCutover();
        deployProposal.setAddresses(addresses);
        cutoverProposal.setAddresses(addresses);
    }

    function test_stockDropSetup_andLifecycle() public {
        address account = _createLiveStakingAccount(user);
        address lateAccount = _createLiveStakingAccount(lateUser);

        // 017: 013's upgrade, sequencer feed, 6 backfills and 2 WETH pairs; whitelist, grant, 2 revokes, fee recipient, 3 pairs
        _run(deployProposal, 18);

        // Aerodrome has killed v1's gauge, so 006 takes that branch: the stake goes to F-MAMO, nothing is deposited and
        // v2 does not claim it. The alive branch (approve, deposit, addGauge) is no longer reachable on a fork.
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        assertFalse(IAerodromeVoter(IAerodromeGauge(gauge).voter()).isAlive(gauge), "v1's gauge is killed");
        // 006: 3 lockers, the gauge withdrawal, 2 distributors, the module, then addReward and addRewardToken for
        // WETH, USDC and each of the 12 stocks; v1 holds nothing to sweep
        _run(cutoverProposal, 35);

        _upgradeAndRepoint(user, account);
        _proveDropTopsUpRunningStreams();
        _proveCompound(account);
        _proveV1ParksUntilUpgraded(lateAccount);
        _proveStockAccountPaysDropAutomation();
    }

    /// @dev 017 refuses to deploy while the stock registry lists a stock on another pool than the config, as it did
    ///      before 021; mocked here because the pin is past 021
    function test_stockDrop_cannotDeployBefore021() public {
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY"));
        IStockAccountRegistry.TokenConfig memory listing = stockRegistry.tokenConfig(AAPLC);
        listing.pool = AAPLC_OLD_POOL;
        vm.mockCall(address(stockRegistry), abi.encodeCall(stockRegistry.tokenConfig, (AAPLC)), abi.encode(listing));
        deployProposal.setPrimaryForkId(vm.activeFork());

        vm.expectRevert(
            bytes(
                string.concat(
                    "AAPLc is not listed on its configured pool; execute mamo-multisig/021 first: ",
                    vm.toString(AAPLC_OLD_POOL),
                    " != ",
                    vm.toString(0xF5FCB9CDAFcE67d50AfEf298F88E709d2B946BA6)
                )
            )
        );
        deployProposal.deploy();
    }

    // ─── stages ──────────────────────────────────────────────────────────────────────────────────

    /// @dev An account made by the live factory before the proposals, i.e. on the V1 implementation and registry
    function _createLiveStakingAccount(address owner) internal returns (address account) {
        MamoStakingStrategyFactory factory =
            MamoStakingStrategyFactory(addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY"));
        IERC20 mamo = IERC20(addresses.getAddress("MAMO"));

        vm.prank(owner);
        account = factory.createStrategyForUser(owner);

        deal(address(mamo), owner, STAKE);
        vm.startPrank(owner);
        mamo.approve(account, STAKE);
        MamoStakingStrategyV2(payable(account)).deposit(STAKE);
        vm.stopPrank();
    }

    function _run(MultisigProposal p, uint256 actions) internal {
        p.setPrimaryForkId(vm.activeFork());
        p.deploy();
        p.preBuildMock();
        p.build();

        (address[] memory targets,,) = p.getProposalActions();
        assertEq(targets.length, actions, string.concat(p.name(), " batch size"));

        p.simulate();
        p.validate();
    }

    /// @dev Both calls as the owner, as the app's upgrade flow makes them
    function _upgradeAndRepoint(address owner, address account) internal {
        address registry = addresses.getAddress("MAMO_STAKING_REGISTRY_V2");

        vm.startPrank(owner);
        MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"))
            .upgradeStrategy(account, addresses.getAddress("MAMO_STAKING_STRATEGY_V2"));
        MamoStakingStrategyV2(payable(account)).setStakingRegistry(registry);
        vm.stopPrank();

        assertEq(address(MamoStakingStrategyV2(payable(account)).stakingRegistry()), registry, "Repointed");
    }

    /// @dev The streams are mid-period at the pin, so this is the top-up the old module's 7-day lock prevented
    function _proveDropTopsUpRunningStreams() internal {
        DropAutomationV2 drop = DropAutomationV2(addresses.getAddress("DROP_AUTOMATION_V2"));
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        address cbBtc = addresses.getAddress("cbBTC");

        (,, uint256 periodFinishBefore,,,) = multiRewards.rewardData(cbBtc);
        assertGt(periodFinishBefore, block.timestamp, "cbBTC stream should be running");

        deal(addresses.getAddress("MAMO"), address(drop), DROP_MAMO);
        deal(cbBtc, address(drop), DROP_CBBTC);
        deal(addresses.getAddress("WETH"), address(drop), DROP_WETH);
        deal(addresses.getAddress("USDC"), address(drop), DROP_USDC);

        vm.prank(drop.dedicatedMsgSender());
        drop.createDrop(new address[](0), new int24[](0), new bool[](0), new uint256[](0));

        (,, uint256 periodFinish,,,) = multiRewards.rewardData(cbBtc);
        assertEq(periodFinish, block.timestamp + 7 days, "cbBTC stream restarted from now");
        assertLt(IERC20(cbBtc).balanceOf(address(drop)), 7 days, "only the rounding remainder is held");
        (,, uint256 wethFinish,,,) = multiRewards.rewardData(addresses.getAddress("WETH"));
        (,, uint256 usdcFinish,,,) = multiRewards.rewardData(addresses.getAddress("USDC"));
        assertEq(wethFinish, block.timestamp + 7 days, "WETH stream started");
        assertEq(usdcFinish, block.timestamp + 7 days, "USDC stream started");
    }

    function _proveCompound(address account) internal {
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        uint256 stakedBefore = multiRewards.balanceOf(account);

        skip(30 minutes);
        _compound(account);

        assertGt(multiRewards.balanceOf(account), stakedBefore, "MAMO and swapped cbBTC restaked");
        _assertNothingHeld(account);
    }

    /// @dev V1 swaps only the old registry's cbBTC, so WETH and USDC wait on the account for its upgrade
    function _proveV1ParksUntilUpgraded(address account) internal {
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        IERC20 weth = IERC20(addresses.getAddress("WETH"));
        IERC20 usdc = IERC20(addresses.getAddress("USDC"));

        vm.prank(addresses.getAddress("STRATEGY_MULTICALL"));
        ILiveStakingStrategy(account).compound();
        assertEq(IERC20(addresses.getAddress("cbBTC")).balanceOf(account), 0, "V1 swaps cbBTC");
        assertGt(weth.balanceOf(account), 0, "V1 parks WETH");
        assertGt(usdc.balanceOf(account), 0, "V1 parks USDC");

        uint256 stakedBefore = multiRewards.balanceOf(account);
        _upgradeAndRepoint(lateUser, account);
        _compound(account);

        assertGt(multiRewards.balanceOf(account), stakedBefore, "Parked tokens restaked as MAMO");
        _assertNothingHeld(account);
    }

    function _compound(address account) internal {
        vm.prank(addresses.getAddress("STRATEGY_MULTICALL"));
        MamoStakingStrategyV2(payable(account)).compound(block.timestamp + 10 minutes);
    }

    function _assertNothingHeld(address account) internal view {
        assertEq(IERC20(addresses.getAddress("cbBTC")).balanceOf(account), 0, "cbBTC swapped, not held");
        assertEq(IERC20(addresses.getAddress("WETH")).balanceOf(account), 0, "WETH swapped, not held");
        assertEq(IERC20(addresses.getAddress("USDC")).balanceOf(account), 0, "USDC swapped, not held");
    }

    /// @dev Created by the live v2 factory the app uses
    function _proveStockAccountPaysDropAutomation() internal {
        StockAccountStrategyFactory factory =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));
        address drop = addresses.getAddress("DROP_AUTOMATION_V2");
        IERC20 usdc = IERC20(addresses.getAddress("USDC"));

        IStockAccountStrategy.BasketEntry[] memory entries = new IStockAccountStrategy.BasketEntry[](1);
        entries[0] = IStockAccountStrategy.BasketEntry({token: NVDAC, targetBps: 5_000});

        vm.prank(user);
        StockAccountStrategy stockAccount =
            StockAccountStrategy(payable(factory.createStrategyForUser(user, entries, 5_000)));
        assertEq(
            StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY")).feeRecipient(),
            drop,
            "Fees go to DropAutomationV2"
        );

        deal(address(usdc), user, USDC_DEPOSIT);
        vm.startPrank(user);
        usdc.approve(address(stockAccount), USDC_DEPOSIT);
        stockAccount.deposit(USDC_DEPOSIT);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(drop);
        skip(30 days);
        stockAccount.payFees(address(usdc));

        assertGt(usdc.balanceOf(drop), before, "The management fee reached DropAutomationV2");
    }
}
