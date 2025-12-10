// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";
import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";
import {IAerodromeGauge} from "@contracts/interfaces/IAerodromeGauge.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {DeployDropAutomation} from "@script/DeployDropAutomation.s.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title DropAutomationSetup
 * @notice F-MAMO multisig proposal to setup DropAutomation contract
 * @dev This proposal:
 *      1. Deploys the DropAutomation contract (owned by F-MAMO)
 *      2. Transfers RewardsDistributorSafeModule admin from F-MAMO to DropAutomation
 *      3. Sets fee collector to DropAutomation for:
 *         - BurnAndEarn (0xe25e010026692De7A3bb35ef7474cdf4fa1C7e44)
 *         - BurnAndEarn Virtual MAMO LP (0x79c1921Fc8CD076415cBD1EBB330629F4EC7Bbd1)
 *         - TransferAndEarn (0x95B0D21bBc973A6aEc501026260e26D333b94d80)
 *      4. Transfers gauge position to DropAutomation
 *      5. Adds USDC-AERO gauge for reward harvesting
 * Note: All contract ownerships remain with F-MAMO for governance control
 * Note: Swap tokens are passed as parameters to createDrop() for flexibility
 */
contract DropAutomationSetup is MultisigProposal {
    DeployDropAutomation public immutable deployDropAutomation;

    constructor() {
        // Initialize deploy script
        deployDropAutomation = new DeployDropAutomation();
        vm.makePersistent(address(deployDropAutomation));
    }

    function _initializeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

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
        return "005_DropAutomationSetup";
    }

    function description() public pure override returns (string memory) {
        return "Deploy DropAutomation and transfer admin/feeCollector roles";
    }

    function deploy() public override {
        // Check if the drop automation address already exists
        string memory dropAutomationName = "DROP_AUTOMATION";
        if (addresses.isAddressSet(dropAutomationName)) {
            console.log("DROP_AUTOMATION already deployed, skipping deployment");
            return;
        }

        // Deploy DropAutomation using the deploy script
        address dropAutomationAddress = deployDropAutomation.deploy(addresses);

        console.log("DropAutomation deployed at:", dropAutomationAddress);
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        address dropAutomation = addresses.getAddress("DROP_AUTOMATION");
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        address burnAndEarnAddress = addresses.getAddress("BURN_AND_EARN");
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        // 1. Transfer RewardsDistributorSafeModule admin to DropAutomation
        RewardsDistributorSafeModule(rewardsDistributorModule).setAdmin(dropAutomation);

        // 2. Set fee collector to DropAutomation for all BurnAndEarn/TransferAndEarn contracts
        BurnAndEarn burnAndEarn = BurnAndEarn(burnAndEarnAddress);
        burnAndEarn.setFeeCollector(dropAutomation);

        address burnAndEarnVirtualMamoLP = addresses.getAddress("BURN_AND_EARN_VIRTUAL_MAMO_LP");
        BurnAndEarn(burnAndEarnVirtualMamoLP).setFeeCollector(dropAutomation);

        address transferAndEarn = addresses.getAddress("TRANSFER_AND_EARN");
        BurnAndEarn(transferAndEarn).setFeeCollector(dropAutomation);

        // 3. Transfer Aerodrome gauge position to DropAutomation
        // First check if F-MAMO has staked LP tokens
        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        uint256 stakedBalance = gaugeContract.balanceOf(addresses.getAddress("F-MAMO"));

        if (stakedBalance > 0) {
            // Withdraw LP tokens from gauge
            gaugeContract.withdraw(stakedBalance);

            // Re-deposit LP tokens to gauge with DropAutomation as recipient
            IERC20 lpToken = IERC20(stakingToken);
            lpToken.approve(gauge, stakedBalance);
            gaugeContract.deposit(stakedBalance, dropAutomation);
        }

        DropAutomation dropAutomationContract = DropAutomation(dropAutomation);

        // 4. Configure gauge for reward harvesting
        if (!dropAutomationContract.isConfiguredGauge(gauge)) {
            dropAutomationContract.addGauge(gauge);
        }

        // Note: Swap tokens are now passed as parameters to createDrop() for flexibility
        // Note: BurnAndEarn ownership remains with F-MAMO for governance control
    }

    function simulate() public override {
        address multisig = addresses.getAddress("F-MAMO");
        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get contract addresses
        address dropAutomation = addresses.getAddress("DROP_AUTOMATION");
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        address burnAndEarnAddress = addresses.getAddress("BURN_AND_EARN");
        address mamoMultisig = addresses.getAddress("MAMO_MULTISIG");
        address adityaEOA = addresses.getAddress("ADITYA_EOA");
        address fMamoSafe = addresses.getAddress("F-MAMO");

        // Validate DropAutomation deployment
        assertGt(dropAutomation.code.length, 0, "DropAutomation not deployed");

        DropAutomation dropAutomationContract = DropAutomation(dropAutomation);

        // Validate DropAutomation configuration
        assertEq(
            dropAutomationContract.owner(),
            fMamoSafe,
            "DropAutomation owner should be F-MAMO"
        );
        assertEq(
            dropAutomationContract.dedicatedMsgSender(),
            adityaEOA,
            "DropAutomation dedicatedMsgSender should be ADITYA_EOA"
        );

        // Validate RewardsDistributorSafeModule admin transfer
        RewardsDistributorSafeModule module = RewardsDistributorSafeModule(rewardsDistributorModule);
        assertEq(
            module.admin(),
            dropAutomation,
            "RewardsDistributorSafeModule admin should be DropAutomation"
        );

        // Validate BurnAndEarn configuration for all three contracts
        BurnAndEarn burnAndEarn = BurnAndEarn(burnAndEarnAddress);
        assertEq(
            burnAndEarn.feeCollector(),
            dropAutomation,
            "BurnAndEarn fee collector should be DropAutomation"
        );
        assertEq(
            burnAndEarn.owner(),
            fMamoSafe,
            "BurnAndEarn owner should remain F-MAMO for governance"
        );

        address burnAndEarnVirtualMamoLP = addresses.getAddress("BURN_AND_EARN_VIRTUAL_MAMO_LP");
        BurnAndEarn burnAndEarnVirtual = BurnAndEarn(burnAndEarnVirtualMamoLP);
        assertEq(
            burnAndEarnVirtual.feeCollector(),
            dropAutomation,
            "BurnAndEarn Virtual MAMO LP fee collector should be DropAutomation"
        );

        address transferAndEarn = addresses.getAddress("TRANSFER_AND_EARN");
        BurnAndEarn transferAndEarnContract = BurnAndEarn(transferAndEarn);
        assertEq(
            transferAndEarnContract.feeCollector(),
            dropAutomation,
            "TransferAndEarn fee collector should be DropAutomation"
        );

        // Validate admin transfers
        assertFalse(
            module.admin() == fMamoSafe,
            "RewardsDistributorSafeModule should no longer have F-MAMO as admin"
        );

        // Validate gauge configuration and position transfer
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        assertTrue(dropAutomationContract.isConfiguredGauge(gauge), "Gauge should be configured");
        assertEq(dropAutomationContract.getGaugeCount(), 1, "Should have 1 configured gauge");

        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        uint256 dropAutomationStakedBalance = gaugeContract.balanceOf(dropAutomation);

        if (dropAutomationStakedBalance > 0) {
            console.log("LP tokens staked in gauge for DropAutomation:", dropAutomationStakedBalance);
        }

        console.log("DropAutomation successfully deployed at:", dropAutomation);
        console.log("RewardsDistributorSafeModule admin transferred to DropAutomation");
        console.log("Fee collector set to DropAutomation for:");
        console.log("  - BurnAndEarn:", burnAndEarnAddress);
        console.log("  - BurnAndEarn Virtual MAMO LP:", burnAndEarnVirtualMamoLP);
        console.log("  - TransferAndEarn:", transferAndEarn);
        console.log("All contract ownerships remain with F-MAMO for governance control");
        console.log("Gauge configured for reward harvesting");
        console.log("");
        console.log("NOTE: Swap tokens are now passed as parameters to createDrop() for flexibility");
        console.log("NOTE: Existing factory contracts have immutable feeRecipient addresses.");
        console.log("Future factory deployments should use DropAutomation as the feeRecipient.");
    }
}