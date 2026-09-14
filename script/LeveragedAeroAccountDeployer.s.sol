// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

import {DeployLeveragedAeroAccountConfig} from "./DeployLeveragedAeroAccountConfig.sol";

import {MamoLeveragedAeroStrategy} from "@contracts/MamoLeveragedAeroStrategy.sol";
import {MamoLeveragedAeroStrategyFactory} from "@contracts/MamoLeveragedAeroStrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title LeveragedAeroAccountDeployer
 * @notice Deploys the {MamoLeveragedAeroStrategy} implementation and its
 *         {MamoLeveragedAeroStrategyFactory}, resolving all constructor args from FPS `Addresses` and
 *         the {DeployLeveragedAeroAccountConfig} JSON.
 * @dev Structured as a reusable helper (mirrors {MultiMarketStrategyFactoryDeployer}) so the
 *      012 multisig proposal calls into it rather than duplicating deploy logic. Broadcasts under the
 *      supplied `deployer` EOA and writes both address-book keys.
 *
 *      Requires the `LEVERAGED_AERO_STRATEGY` and `USDC` keys to resolve at call time; the
 *      former is added by proposal 015 when the pooled layer is deployed (Tenderly vnet, then Base mainnet).
 */
contract LeveragedAeroAccountDeployer is Script {
    /**
     * @notice Deploy the implementation (if not already set) and a fresh factory, registering both.
     * @param addresses The FPS address book.
     * @param config The loaded leveraged-Aero account config.
     * @param deployer The EOA to broadcast the deployment transactions from.
     * @return implementation The MamoLeveragedAeroStrategy implementation address.
     * @return factory The MamoLeveragedAeroStrategyFactory address.
     */
    function deployImplementationAndFactory(
        Addresses addresses,
        DeployLeveragedAeroAccountConfig.Config memory config,
        address deployer
    ) public returns (address implementation, address factory) {
        // Resolve constructor dependencies from the address book.
        address mamoStrategyRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address admin = addresses.getAddress("MAMO_MULTISIG");
        address mamoBackend = addresses.getAddress("MAMO_BACKEND");
        address leveragedAeroStrategy = addresses.getAddress(config.leveragedAeroStrategy);
        address usdc = addresses.getAddress(config.token);

        vm.startBroadcast(deployer);

        // 1. Deploy the UUPS implementation (only once; reuse if already deployed).
        if (addresses.isAddressSet(config.strategyImplementation)) {
            implementation = addresses.getAddress(config.strategyImplementation);
        } else {
            implementation = address(new MamoLeveragedAeroStrategy());
        }

        // 2. Deploy the factory wired to the implementation.
        MamoLeveragedAeroStrategyFactory deployedFactory = new MamoLeveragedAeroStrategyFactory(
            admin, mamoBackend, mamoStrategyRegistry, implementation, config.strategyTypeId, leveragedAeroStrategy, usdc
        );
        factory = address(deployedFactory);

        vm.stopBroadcast();

        // 3. Register both addresses (create-or-update so re-runs stay idempotent).
        _setAddress(addresses, config.strategyImplementation, implementation);
        _setAddress(addresses, config.strategyFactory, factory);

        console.log("MamoLeveragedAeroStrategy implementation:", implementation);
        console.log("MamoLeveragedAeroStrategyFactory:", factory);
    }

    function _setAddress(Addresses addresses, string memory key, address value) internal {
        if (addresses.isAddressSet(key)) {
            addresses.changeAddress(key, value, true);
        } else {
            addresses.addAddress(key, value, true);
        }
    }
}
