// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockDropCutover} from "../multisig/f-mamo/006_StockDropCutover.sol";
import {AddStockRewards} from "../multisig/f-mamo/007_AddStockRewards.sol";
import {DeployStockDrop} from "../multisig/mamo-multisig/017_DeployStockDrop.sol";

import {DropAutomationV2} from "@contracts/DropAutomationV2.sol";
import {MamoStakingStrategyFactory} from "@contracts/MamoStakingStrategyFactory.sol";
import {MamoStakingStrategyV2} from "@contracts/MamoStakingStrategyV2.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

/// @notice Base-fork rehearsal of the stock drop proposals in mainnet order (mamo-multisig/017, then f-mamo/006 and
///         f-mamo/007) through the real Safes, followed by the lifecycle on the result: a live-style staking account
///         upgrades and migrates, a drop tops up the running streams and starts WETH and USDC ones, the account
///         compounds all three through the live pools,
///         and a new stock account pays its fee to DropAutomationV2.
/// @dev The B20 stocks cannot execute in revm (code 0xEF), so their drop, compound and reinvest legs are covered by
///      the unit suites. Self-forks at a pinned block, so it runs without --fork-url.
contract StockDropSetupTest is Test {
    /// @dev The old module has paid out its last drop, the MAMO and cbBTC streams are running, and the BTC/USD
    ///      answer is 20s old, leaving the rehearsal most of its 1h heartbeat
    uint256 internal constant PINNED_BLOCK = 51_951_451;

    uint256 internal constant STAKE = 10_000_000e18;
    uint256 internal constant DROP_MAMO = 100_000e18;
    uint256 internal constant DROP_CBBTC = 0.05e8;
    uint256 internal constant DROP_WETH = 1e18;
    uint256 internal constant DROP_USDC = 5_000e6;
    uint256 internal constant USDC_DEPOSIT = 5_000e6;

    Addresses internal addresses;
    address internal user = makeAddr("stockDropUser");

    DeployStockDrop internal deployProposal;
    StockDropCutover internal cutoverProposal;
    AddStockRewards internal stockRewardsProposal;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));

        // A nonce-0 deployer: the real one's next CREATE slots may already be in the book
        addresses.changeAddress("DEPLOYER_EOA", makeAddr("stockDropDeployer"), false);

        deployProposal = new DeployStockDrop();
        cutoverProposal = new StockDropCutover();
        stockRewardsProposal = new AddStockRewards();
        deployProposal.setAddresses(addresses);
        cutoverProposal.setAddresses(addresses);
        stockRewardsProposal.setAddresses(addresses);
    }

    function test_stockDropSetup_andLifecycle() public {
        address account = _createLiveStakingAccount();

        // 017: whitelist, 2 grants, 2 revokes, 3 pairs
        _run(deployProposal, 8);
        // 006: 3 lockers, the gauge (withdraw, approve, deposit, addGauge), 2 distributors, the module
        _run(cutoverProposal, 10);
        // 007: addReward and addRewardToken for WETH, USDC and each stock
        _run(stockRewardsProposal, 12);

        _upgradeAndMigrate(account);
        _proveDropTopsUpRunningStreams();
        _proveCompound(account);
        _proveStockAccountPaysDropAutomation();
    }

    // ─── stages ──────────────────────────────────────────────────────────────────────────────────

    /// @dev An account made by the live factory before the proposals, i.e. on the V1 implementation and registry
    function _createLiveStakingAccount() internal returns (address account) {
        MamoStakingStrategyFactory factory =
            MamoStakingStrategyFactory(addresses.getAddress("MAMO_STAKING_STRATEGY_FACTORY"));
        IERC20 mamo = IERC20(addresses.getAddress("MAMO"));

        vm.prank(user);
        account = factory.createStrategyForUser(user);

        vm.prank(addresses.getAddress("F-MAMO"));
        mamo.transfer(user, STAKE);
        vm.startPrank(user);
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

    function _upgradeAndMigrate(address account) internal {
        address implementation = addresses.getAddress("MAMO_STAKING_STRATEGY_V2");
        address registry = addresses.getAddress("MAMO_STAKING_REGISTRY_V2");

        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        vm.prank(user);
        mamoRegistry.upgradeStrategy(account, implementation);

        vm.prank(addresses.getAddress("F-MAMO"));
        MamoStakingStrategyV2(payable(account)).setStakingRegistry(registry);

        assertEq(address(MamoStakingStrategyV2(payable(account)).stakingRegistry()), registry, "Migrated");
    }

    /// @dev The streams are mid-period at the pin, so this is the top-up the old module's 7-day lock prevented
    function _proveDropTopsUpRunningStreams() internal {
        DropAutomationV2 drop = DropAutomationV2(addresses.getAddress("DROP_AUTOMATION_V2"));
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        address cbBtc = addresses.getAddress("cbBTC");

        (,, uint256 periodFinishBefore,,,) = multiRewards.rewardData(cbBtc);
        assertGt(periodFinishBefore, block.timestamp, "cbBTC stream should be running");

        IERC20 mamo = IERC20(addresses.getAddress("MAMO"));

        deal(cbBtc, address(drop), DROP_CBBTC);
        deal(addresses.getAddress("WETH"), address(drop), DROP_WETH);
        deal(addresses.getAddress("USDC"), address(drop), DROP_USDC);
        vm.prank(addresses.getAddress("F-MAMO"));
        mamo.transfer(address(drop), DROP_MAMO);

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
        vm.prank(addresses.getAddress("STRATEGY_MULTICALL"));
        MamoStakingStrategyV2(payable(account)).compound(block.timestamp + 10 minutes);

        assertGt(multiRewards.balanceOf(account), stakedBefore, "MAMO and swapped cbBTC restaked");
        assertEq(IERC20(addresses.getAddress("cbBTC")).balanceOf(account), 0, "cbBTC swapped, not held");
        assertEq(IERC20(addresses.getAddress("WETH")).balanceOf(account), 0, "WETH swapped, not held");
        assertEq(IERC20(addresses.getAddress("USDC")).balanceOf(account), 0, "USDC swapped, not held");
    }

    function _proveStockAccountPaysDropAutomation() internal {
        StockAccountStrategyFactory factory =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY_V2"));
        address drop = addresses.getAddress("DROP_AUTOMATION_V2");
        IERC20 usdc = IERC20(addresses.getAddress("USDC"));

        IStockAccountStrategy.BasketEntry[] memory entries = new IStockAccountStrategy.BasketEntry[](1);
        entries[0] = IStockAccountStrategy.BasketEntry({token: addresses.getAddress("cbBTC"), targetBps: 5_000});

        vm.prank(user);
        StockAccountStrategy stockAccount =
            StockAccountStrategy(payable(factory.createStrategyForUser(user, entries, 5_000)));
        assertEq(stockAccount.feeRecipient(), drop, "Fees go to DropAutomationV2");

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
