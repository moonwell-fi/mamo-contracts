// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

import {DeployLeveragedAeroPoolConfig} from "./DeployLeveragedAeroPoolConfig.sol";

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title LeveragedAeroPoolDeployer
 * @notice Deploys the leveraged-Aero POOLED layer: the {LeveragedAerodromeCLStrategy} clone TEMPLATE
 *         and the {LeveragedAeroVault} that owns its lifecycle.
 * @dev Structured as a reusable helper (mirrors {LeveragedAeroAccountDeployer}) so proposal 015 calls
 *      into it rather than duplicating the CREATEs, and broadcasts under the supplied `deployer` EOA.
 *
 *      WHY A `forge script` AND NOT A RAW CREATE: the template links THREE delegatecall libraries
 *      (`LeveragedAeroManager`, `LeveragedAeroValuation`, `LeveragedAeroVenue`). A broadcast deploys
 *      and links them automatically, each as its own transaction — so the Base per-tx gas cap
 *      (16,777,216) applies per CREATE rather than to the whole bundle.
 *
 *      The template's constructor sets `_initialized = true`, permanently locking `initialize` on the
 *      template itself; ERC-1167 clones skip constructors, so clones stay initializable and
 *      `LeveragedAeroVault.cloneAndBind` is the only thing that can ever initialize one.
 *
 *      The vault is constructed with `owner_ = MAMO_MULTISIG` DIRECTLY. `Ownable(owner_)` makes it
 *      owner immediately, so there is no `acceptOwnership()` step (Ownable2Step gates only LATER
 *      transfers). Deploying to the EOA and handing off would leave every `onlyOwner` path — including
 *      `cloneAndBind`, `activateStrategy` and proposal 012's `setOpenDeposits(true)` — dead until
 *      accepted, which would split this deployment across two multisig executions.
 */
contract LeveragedAeroPoolDeployer is Script {
    /**
     * @notice Deploy the strategy template and the vault (each only once), registering both keys.
     * @param addresses The FPS address book.
     * @param config The loaded pooled-layer config.
     * @param deployer The EOA to broadcast the deployment transactions from.
     * @return template The strategy clone template.
     * @return vault The share-token + lifecycle vault, owned by MAMO_MULTISIG.
     */
    function deployTemplateAndVault(
        Addresses addresses,
        DeployLeveragedAeroPoolConfig.Config memory config,
        address deployer
    ) public returns (address template, address vault) {
        address token = addresses.getAddress(config.token);
        address owner = addresses.getAddress("MAMO_MULTISIG");

        vm.startBroadcast(deployer);

        if (addresses.isAddressSet(config.strategyTemplate)) {
            template = addresses.getAddress(config.strategyTemplate);
        } else {
            template = address(new LeveragedAerodromeCLStrategy());
        }

        if (addresses.isAddressSet(config.vault)) {
            vault = addresses.getAddress(config.vault);
        } else {
            vault = address(new LeveragedAeroVault(token, owner, config.vaultName, config.vaultSymbol));
        }

        vm.stopBroadcast();

        _setAddress(addresses, config.strategyTemplate, template);
        _setAddress(addresses, config.vault, vault);

        console.log("LeveragedAerodromeCLStrategy template:", template);
        console.log("  template runtime size (limit 24576):", template.code.length);
        console.log("LeveragedAeroVault:", vault);
        console.log("  vault.owner:", LeveragedAeroVault(vault).owner());
        console.log("  vault.asset:", LeveragedAeroVault(vault).asset());
        console.log("  vault.decimals:", uint256(LeveragedAeroVault(vault).decimals()));
    }

    function _setAddress(Addresses addresses, string memory key, address value) internal {
        if (addresses.isAddressSet(key)) {
            addresses.changeAddress(key, value, true);
        } else {
            addresses.addAddress(key, value, true);
        }
    }
}
