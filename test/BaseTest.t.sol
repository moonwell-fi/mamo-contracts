// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TransferFeeCollector} from "../multisig/007_TransferFeeCollector.sol";
import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {DeployConfig} from "@script/DeployConfig.sol";

abstract contract BaseTest is Test {
    Addresses public addresses;
    DeployConfig public config;
    TransferFeeCollector public proposal;

    address public admin;
    address public backend;
    address public guardian;
    address public multisig;

    function setUp() public virtual {
        // Create a new addresses instance for testing
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;

        addresses = new Addresses(addressesFolderPath, chainIds);

        // Get the environment from command line arguments or use default
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_PROD"));
        string memory configPath = string(abi.encodePacked("./deploy/", environment, ".json"));

        config = new DeployConfig(configPath);

        // Get the addresses for the roles
        admin = addresses.getAddress(config.getConfig().admin);
        backend = addresses.getAddress(config.getConfig().backend);
        guardian = addresses.getAddress(config.getConfig().guardian);
        multisig = addresses.getAddress("MAMO_MULTISIG");

        // Create and execute the multisig proposal
        proposal = new TransferFeeCollector();

        // Deploy any necessary contracts
        proposal.deploy();

        // Build the proposal actions
        proposal.build();

        // Simulate the proposal execution
        proposal.simulate();

        // Validate the proposal results
        proposal.validate();
    }

    /// @dev Helper function to create a fork for testing
    function createFork() internal {
        vm.createSelectFork("base");
    }
}
