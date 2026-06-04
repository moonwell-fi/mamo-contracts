// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";
import {ITransferAndEarn} from "@contracts/interfaces/ITransferAndEarn.sol";
import {INonfungiblePositionManager} from "@contracts/interfaces/INonfungiblePositionManager.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {DeployLPAutoBalancer} from "@script/DeployLPAutoBalancer.s.sol";

import {console} from "forge-std/console.sol";

/**
 * @title LPAutoBalancerSetup
 * @notice F-MAMO multisig proposal to deploy and initialize the LPAutoBalancer for the
 *         MAMO/USDC CL position (tokenId 21585074).
 * @dev This proposal:
 *      1. Deploys LPAutoBalancer (admin=F-MAMO, manager=MAMO_LP_MANAGER,
 *         rebalancer=MAMO_LP_REBALANCER, guardian=MAMO_PAUSE_GUARDIAN).
 *      2. Calls TransferAndEarn.transfer(21585074) to return the NFT to F-MAMO.
 *      3. Transfers the NFT from F-MAMO to LPAutoBalancer via safeTransferFrom.
 *      4. Registers the position with full configuration via registerPosition().
 */
contract LPAutoBalancerSetup is MultisigProposal {
    uint256 public constant TOKEN_ID = 21585074;

    DeployLPAutoBalancer public immutable deployLPAutoBalancer;

    constructor() {
        deployLPAutoBalancer = new DeployLPAutoBalancer();
        vm.makePersistent(address(deployLPAutoBalancer));
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
        return "006_LPAutoBalancerSetup";
    }

    function description() public pure override returns (string memory) {
        return "Deploy LPAutoBalancer and register MAMO/USDC CL position (tokenId 21585074)";
    }

    function deploy() public override {
        string memory labName = "MAMO_LP_AUTO_BALANCER";
        if (addresses.isAddressSet(labName)) {
            console.log("MAMO_LP_AUTO_BALANCER already deployed, skipping deployment");
            return;
        }

        address lab = deployLPAutoBalancer.deploy(addresses);
        addresses.addAddress(labName, lab, true);
        console.log("LPAutoBalancer deployed at:", lab);
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        address lab = addresses.getAddress("MAMO_LP_AUTO_BALANCER");
        address fMamo = addresses.getAddress("F-MAMO");
        address transferAndEarn = addresses.getAddress("TRANSFER_AND_EARN");
        address pm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");

        // 1. Release the NFT from TransferAndEarn back to F-MAMO (the owner).
        //    TransferAndEarn.transfer() requires lockedPositions[tokenId]==true and
        //    msg.sender==owner (F-MAMO). It sends the NFT to owner().
        ITransferAndEarn(transferAndEarn).transfer(TOKEN_ID);

        // 2. Transfer the NFT from F-MAMO to LPAutoBalancer.
        INonfungiblePositionManager(pm).safeTransferFrom(fMamo, lab, TOKEN_ID);

        // 3. Register the position with LPAutoBalancer.
        //    registerPosition() requires DEFAULT_ADMIN_ROLE (F-MAMO has it as admin).
        LPAutoBalancer.ManagedPosition memory config = LPAutoBalancer.ManagedPosition({
            tokenId: TOKEN_ID,
            pool: addresses.getAddress("MAMO_USDC_POOL"),
            token0: addresses.getAddress("MAMO"),
            token1: addresses.getAddress("USDC"),
            tickSpacing: 200,
            gauge: addresses.getAddress("AERODROME_MAMO_USDC_GAUGE"),
            staked: false,
            feeCollector: addresses.getAddress("DROP_AUTOMATION"),
            oracle0: addresses.getAddress("CHAINLINK_MAMO_USD"),
            oracle1: addresses.getAddress("CHAINLINK_USDC_USD"),
            swapPolicy: 1, // counter-asset only — never sell MAMO
            protectedToken: addresses.getAddress("MAMO"),
            minWidth: 400,
            maxWidth: 20000,
            maxCenterDeviation: 2000,
            maxSlippageBps: 100,
            twapWindow: 1800,
            maxTickDeviation: 500,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 1 days,
            lastRebalance: 0,
            active: true
        });

        LPAutoBalancer(lab).registerPosition(config);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("F-MAMO");
        _simulateActions(multisig);
    }

    function validate() public view override {
        address lab = addresses.getAddress("MAMO_LP_AUTO_BALANCER");
        address fMamo = addresses.getAddress("F-MAMO");
        address pm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
        address rebalancer = addresses.getAddress("MAMO_LP_REBALANCER");
        address dropAutomation = addresses.getAddress("DROP_AUTOMATION");
        address mamoAddr = addresses.getAddress("MAMO");
        address oracle0 = addresses.getAddress("CHAINLINK_MAMO_USD");
        address oracle1 = addresses.getAddress("CHAINLINK_USDC_USD");

        // LPAutoBalancer deployed
        assertGt(lab.code.length, 0, "LPAutoBalancer not deployed");

        // NFT 21585074 now owned by LPAutoBalancer
        assertEq(
            INonfungiblePositionManager(pm).ownerOf(TOKEN_ID),
            lab,
            "NFT 21585074 should be owned by LPAutoBalancer"
        );

        // Slot 0 is active and correctly configured
        LPAutoBalancer labContract = LPAutoBalancer(lab);
        (
            uint256 tokenId,
            ,
            ,
            ,
            ,
            ,
            ,
            address feeCollector,
            address storedOracle0,
            address storedOracle1,
            uint8 swapPolicy,
            address protectedToken,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool active
        ) = labContract.positions(0);

        assertTrue(active, "Slot 0 should be active");
        assertEq(tokenId, TOKEN_ID, "Slot 0 tokenId should be 21585074");
        assertEq(feeCollector, dropAutomation, "feeCollector should be DROP_AUTOMATION");
        assertEq(storedOracle0, oracle0, "oracle0 should be CHAINLINK_MAMO_USD");
        assertEq(storedOracle1, oracle1, "oracle1 should be CHAINLINK_USDC_USD");
        assertEq(swapPolicy, 1, "swapPolicy should be 1 (counter-asset only)");
        assertEq(protectedToken, mamoAddr, "protectedToken should be MAMO");

        // Role checks
        bytes32 rebalancerRole = labContract.REBALANCER_ROLE();
        bytes32 adminRole = labContract.DEFAULT_ADMIN_ROLE();
        assertTrue(labContract.hasRole(rebalancerRole, rebalancer), "MAMO_LP_REBALANCER should have REBALANCER_ROLE");
        assertTrue(labContract.hasRole(adminRole, fMamo), "F-MAMO should have DEFAULT_ADMIN_ROLE");

        console.log("LPAutoBalancer deployed at:", lab);
        console.log("NFT 21585074 owned by LPAutoBalancer");
        console.log("Slot 0 active with DROP_AUTOMATION as feeCollector");
        console.log("REBALANCER_ROLE granted to MAMO_LP_REBALANCER");
        console.log("DEFAULT_ADMIN_ROLE held by F-MAMO");
    }
}
