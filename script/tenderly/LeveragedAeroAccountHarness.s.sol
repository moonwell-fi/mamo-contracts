// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

import {DeployLeveragedAeroAccountConfig} from "@script/DeployLeveragedAeroAccountConfig.sol";
import {LeveragedAeroAccountDeployer} from "@script/LeveragedAeroAccountDeployer.s.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title LeveragedAeroAccountHarness
 * @notice Tenderly Virtual TestNet deploy runner for the {MamoLeveragedAeroStrategy} account system.
 * @dev Thin broadcasting wrapper around the shared {LeveragedAeroAccountDeployer} — the SAME deploy code
 *      the 012 multisig proposal calls. It exists because the proposal's `SHERWOOD_LEVERAGED_AERO_STRATEGY`
 *      / `SHERWOOD_SYNDICATE_VAULT` address-book keys are deliberately NOT committed to
 *      `addresses/8453.json`: FPS `Addresses` validates `isContract` EAGERLY in its constructor
 *      (Addresses.sol `_checkAddress`, gated on `chainId == block.chainid`), so committing those keys with
 *      `isContract:true` would revert the `Addresses` constructor on every real-Base-mainnet CI run (no
 *      code lives at the Sherwood addresses there). Instead this harness injects them at RUNTIME via
 *      `addresses.addAddress(...)` from env vars, so the keys only ever exist inside the vnet process.
 *
 *      Broadcast identity is supplied by the orchestrator through Tenderly's unlocked-impersonation
 *      (`forge script --unlocked --sender DEPLOYER_EOA`); the inner deployer wraps its CREATEs in
 *      `vm.startBroadcast(deployer)` where `deployer == DEPLOYER_EOA` from the address book.
 *
 *      Env vars (addresses on the vnet):
 *        SHERWOOD_LEVERAGED_AERO_STRATEGY  - the vendored LeveragedAerodromeCLStrategy clone
 *        SHERWOOD_SYNDICATE_VAULT          - the SyndicateVault (share ERC-20)
 */
contract LeveragedAeroAccountHarness is Script {
    string constant CONFIG_PATH = "./config/strategies/LeveragedAeroAccountConfig.json";

    /// @notice Deploy the implementation + factory to the vnet using the real proposal deploy path.
    /// @return implementation The deployed MamoLeveragedAeroStrategy implementation.
    /// @return factory The deployed MamoLeveragedAeroStrategyFactory.
    function deploy() public returns (address implementation, address factory) {
        Addresses addresses = _addresses();
        DeployLeveragedAeroAccountConfig cfg = new DeployLeveragedAeroAccountConfig(CONFIG_PATH);

        address deployer = addresses.getAddress("DEPLOYER_EOA");

        LeveragedAeroAccountDeployer accountDeployer = new LeveragedAeroAccountDeployer();
        (implementation, factory) = accountDeployer.deployImplementationAndFactory(addresses, cfg.getConfig(), deployer);

        // Parseable markers for the bash orchestrator (mirrors the LPV2 harness convention).
        console.log("HARNESS_IMPL=%s", implementation);
        console.log("HARNESS_FACTORY=%s", factory);
    }

    /// @notice Build the FPS address book and inject the vnet-only Sherwood keys from env.
    function _addresses() internal returns (Addresses addresses) {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);

        _addFromEnv(addresses, "SHERWOOD_LEVERAGED_AERO_STRATEGY");
        _addFromEnv(addresses, "SHERWOOD_SYNDICATE_VAULT");
    }

    /// @notice Add `key` from an env var of the same name, idempotently (skip if already committed).
    function _addFromEnv(Addresses addresses, string memory key) internal {
        if (addresses.isAddressSet(key)) return;
        address value = vm.envAddress(key);
        require(value.code.length > 0, string(abi.encodePacked(key, " has no code on this vnet")));
        addresses.addAddress(key, value, true);
    }
}
