// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";
import {DropAutomation} from "@contracts/DropAutomation.sol";
import {DropAutomationV2} from "@contracts/DropAutomationV2.sol";
import {FeeSplitter} from "@contracts/FeeSplitter.sol";
import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";
import {TransferAndEarn} from "@contracts/TransferAndEarn.sol";
import {IAerodromeGauge} from "@interfaces/IAerodromeGauge.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISafeModules {
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory modules, address next);

    function isModuleEnabled(address module) external view returns (bool);

    function disableModule(address prevModule, address module) external;
}

/**
 * @title StockDropCutover
 * @notice F-MAMO batch moving the Mamo Drop from DropAutomation v1 and its Safe module to {DropAutomationV2}:
 *         repoints the fee lockers (the VIRTUAL/MAMO one through a new splitter with the live split), moves
 *         v1's gauge stake, sweeps v1's balances, makes v2 the MultiRewards distributor of MAMO and cbBTC, and
 *         disables the old module. Stakers see no change; stock rewards follow in f-mamo/007.
 * @dev Runs after mamo-multisig/017, which deploys DropAutomationV2. The old module must have nothing staged, and
 *      a last v1 drop (claimGaugeRewards + createDrop + notifyRewards) should run first so nothing is left behind.
 */
contract StockDropCutover is MultisigProposal {
    string internal constant SPLITTER_KEY = "FEE_SPLITTER_VIRTUAL_MAMO_V2";

    address internal constant SENTINEL_MODULES = address(0x1);

    /// @notice The fee tokens v1 may hold, swept to v2
    string[8] internal SWEPT_TOKENS = ["MAMO", "cbBTC", "WETH", "USDC", "AERO", "VIRTUALS", "ZORA", "EDGE"];

    /// @dev What the batch moves, read when it is built
    address[] internal _gauges;
    uint256[] internal _stakes;

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
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
        return "006_StockDropCutover";
    }

    function description() public pure override returns (string memory) {
        return
        "Move the Mamo Drop to DropAutomationV2: repoint the fee lockers, move the gauge stake and v1 balances, make DropAutomationV2 the MultiRewards distributor of MAMO and cbBTC, and disable the old rewards module";
    }

    /// @dev The live splitter's recipients are immutable, so the VIRTUAL/MAMO leg gets a copy paying v2
    function deploy() public override {
        if (addresses.isAddressSet(SPLITTER_KEY)) return;

        FeeSplitter live = FeeSplitter(addresses.getAddress("FEE_SPLITTER_VIRTUAL_MAMO"));

        vm.startBroadcast(addresses.getAddress("DEPLOYER_EOA"));
        FeeSplitter splitter = new FeeSplitter(
            live.TOKEN_0(),
            live.TOKEN_1(),
            live.RECIPIENT_1(),
            addresses.getAddress("DROP_AUTOMATION_V2"),
            live.RECIPIENT_1_SHARE()
        );
        vm.stopBroadcast();

        addresses.addAddress(SPLITTER_KEY, address(splitter), true);
    }

    function preBuildMock() public override {
        address safe = addresses.getAddress("F-MAMO");
        address module = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));

        assertEq(multiRewards.owner(), safe, "F-MAMO should own MultiRewards");
        assertEq(DropAutomation(addresses.getAddress("DROP_AUTOMATION")).owner(), safe, "F-MAMO should own v1");
        assertEq(DropAutomationV2(addresses.getAddress("DROP_AUTOMATION_V2")).owner(), safe, "F-MAMO should own v2");

        assertTrue(ISafeModules(safe).isModuleEnabled(module), "Old module should be enabled");
        RewardsDistributorSafeModule.RewardState state = RewardsDistributorSafeModule(module).getCurrentState();
        assertTrue(
            state == RewardsDistributorSafeModule.RewardState.EXECUTED
                || state == RewardsDistributorSafeModule.RewardState.UNINITIALIZED,
            "Old module should have nothing staged"
        );

        (address mamoDistributor,,,,,) = multiRewards.rewardData(addresses.getAddress("MAMO"));
        (address cbBtcDistributor,,,,,) = multiRewards.rewardData(addresses.getAddress("cbBTC"));
        assertEq(mamoDistributor, safe, "MAMO distributor should be F-MAMO");
        assertEq(cbBtcDistributor, safe, "cbBTC distributor should be F-MAMO");
    }

    // ─── the batch ───────────────────────────────────────────────────────────────────────────────

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        address drop = addresses.getAddress("DROP_AUTOMATION_V2");

        // 1. Fees go to v2 from here on
        TransferAndEarn(addresses.getAddress("TRANSFER_AND_EARN")).setFeeCollector(drop);
        BurnAndEarn(addresses.getAddress("BURN_AND_EARN")).setFeeCollector(drop);
        BurnAndEarn(addresses.getAddress("BURN_AND_EARN_VIRTUAL_MAMO_LP")).setFeeCollector(
            addresses.getAddress(SPLITTER_KEY)
        );

        // 2. v1's gauge stake, deposited for v2
        _moveGauges(drop);

        // 3. Whatever v1 still holds
        DropAutomation v1 = DropAutomation(addresses.getAddress("DROP_AUTOMATION"));
        for (uint256 i = 0; i < SWEPT_TOKENS.length; i++) {
            address token = addresses.getAddress(SWEPT_TOKENS[i]);
            if (IERC20(token).balanceOf(address(v1)) > 0) v1.recoverERC20(token, drop, 0);
        }

        // 4. v2 funds the MAMO and cbBTC streams
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        multiRewards.setRewardsDistributor(addresses.getAddress("MAMO"), drop);
        multiRewards.setRewardsDistributor(addresses.getAddress("cbBTC"), drop);

        // 5. Retire the old module
        address safe = addresses.getAddress("F-MAMO");
        address module = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        ISafeModules(safe).disableModule(_previousModule(safe, module), module);
    }

    function _moveGauges(address drop) internal {
        DropAutomation v1 = DropAutomation(addresses.getAddress("DROP_AUTOMATION"));
        address safe = addresses.getAddress("F-MAMO");

        for (uint256 i = 0; i < v1.getGaugeCount(); i++) {
            IAerodromeGauge gauge = v1.aerodromeGauges(i);
            uint256 stake = gauge.balanceOf(address(v1));

            if (stake > 0) {
                v1.withdrawGauge(address(gauge), stake, safe);
                IERC20(gauge.stakingToken()).approve(address(gauge), stake);
                gauge.deposit(stake, drop);
            }
            DropAutomationV2(drop).addGauge(address(gauge));

            _gauges.push(address(gauge));
            _stakes.push(stake);
        }
    }

    function _previousModule(address safe, address module) internal view returns (address previous) {
        (address[] memory modules,) = ISafeModules(safe).getModulesPaginated(SENTINEL_MODULES, 50);

        previous = SENTINEL_MODULES;
        for (uint256 i = 0; i < modules.length; i++) {
            if (modules[i] == module) return previous;
            previous = modules[i];
        }
        revert("Module not found");
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("F-MAMO"));
    }

    // ─── post-conditions ─────────────────────────────────────────────────────────────────────────

    function validate() public view override {
        address drop = addresses.getAddress("DROP_AUTOMATION_V2");
        address v1 = addresses.getAddress("DROP_AUTOMATION");

        assertEq(TransferAndEarn(addresses.getAddress("TRANSFER_AND_EARN")).feeCollector(), drop, "TransferAndEarn");
        assertEq(BurnAndEarn(addresses.getAddress("BURN_AND_EARN")).feeCollector(), drop, "BurnAndEarn");
        assertEq(
            BurnAndEarn(addresses.getAddress("BURN_AND_EARN_VIRTUAL_MAMO_LP")).feeCollector(),
            addresses.getAddress(SPLITTER_KEY),
            "VIRTUAL/MAMO locker"
        );

        FeeSplitter live = FeeSplitter(addresses.getAddress("FEE_SPLITTER_VIRTUAL_MAMO"));
        FeeSplitter splitter = FeeSplitter(addresses.getAddress(SPLITTER_KEY));
        assertEq(splitter.RECIPIENT_2(), drop, "Splitter pays v2");
        assertEq(splitter.RECIPIENT_1(), live.RECIPIENT_1(), "Splitter keeps the first recipient");
        assertEq(splitter.RECIPIENT_1_SHARE(), live.RECIPIENT_1_SHARE(), "Splitter keeps the split");
        assertEq(splitter.TOKEN_0(), live.TOKEN_0(), "Splitter token0");
        assertEq(splitter.TOKEN_1(), live.TOKEN_1(), "Splitter token1");

        for (uint256 i = 0; i < _gauges.length; i++) {
            IAerodromeGauge gauge = IAerodromeGauge(_gauges[i]);
            assertEq(gauge.balanceOf(v1), 0, "v1 gauge stake moved");
            assertEq(gauge.balanceOf(drop), _stakes[i], "v2 holds the gauge stake");
            assertTrue(DropAutomationV2(drop).isGauge(address(gauge)), "v2 claims the gauge");
        }

        for (uint256 i = 0; i < SWEPT_TOKENS.length; i++) {
            assertEq(IERC20(addresses.getAddress(SWEPT_TOKENS[i])).balanceOf(v1), 0, "v1 balance swept");
        }

        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        (address mamoDistributor,,,,,) = multiRewards.rewardData(addresses.getAddress("MAMO"));
        (address cbBtcDistributor,,,,,) = multiRewards.rewardData(addresses.getAddress("cbBTC"));
        assertEq(mamoDistributor, drop, "v2 distributes MAMO");
        assertEq(cbBtcDistributor, drop, "v2 distributes cbBTC");

        assertFalse(
            ISafeModules(addresses.getAddress("F-MAMO")).isModuleEnabled(
                addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC")
            ),
            "Old module disabled"
        );
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
