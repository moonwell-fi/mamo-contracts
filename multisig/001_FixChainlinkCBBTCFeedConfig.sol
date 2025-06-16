// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MultisigProposal} from "@fps/proposals/MultisigProposal.sol";

import {Addresses} from "@addresses/Addresses.sol";
import {AddTokenConfiguration} from "@script/AddTokenConfiguration.s.sol";
import {DeployAssetConfig} from "@script/DeployAssetConfig.sol";

contract FixChainlinkCBBTCFeedConfig is MultisigProposal {
    DeployAssetConfig public immutable deployAssetConfig;

    constructor() {
        setPrimaryForkId(vm.createSelectFork("base"));

        // TODO move four below lines to a generic function as we use all the time
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        deployAssetConfig = new DeployAssetConfig("./config/strategies/cbBTCStrategyConfig.json");
        vm.makePersistent(address(deployAssetConfig));
    }

    function name() public pure override returns (string memory) {
        return "001_FixChainlinkCBBTCFeedConfig";
    }

    function description() public pure override returns (string memory) {
        return "Fix Chainlink CBBTC Feed Config";
    }

    function build() public override {
        vm.startPrank(addresses.getAddress("MAMO_MULTISIG"));
        AddTokenConfiguration addTokenConfiguration = new AddTokenConfiguration();
        addTokenConfiguration.addTokenConfiguration(addresses, deployAssetConfig);
        vm.stopPrank();
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public override {
        // check if returns the correct well - btc exchange rate
        address well = addresses.getAddress("xWELL_PROXY");
        address btc = addresses.getAddress("cbBTC");
        address chainlinkBTC = addresses.getAddress("CHAINLINK_BTC_USD");
        address chainlinkWell = addresses.getAddress("CHAINLINK_WELL_USD");
    }
}
