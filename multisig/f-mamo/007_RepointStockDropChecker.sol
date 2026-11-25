// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MamoStakingRegistryV2} from "@contracts/MamoStakingRegistryV2.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

/**
 * @title RepointStockDropChecker
 * @notice F-MAMO batch moving every staking-registry route hop priced by the pre-023 stock checker onto the hardened
 *         one (MOO-1164), so compounding a B20 stock to MAMO refuses the same TWAP windows the stock accounts do
 * @dev Runs after mamo-multisig/023, whose deploy records both checkers. Only the checker of each hop changes.
 */
contract RepointStockDropChecker is MultisigProposal {
    string internal constant STAKING_REGISTRY_KEY = "MAMO_STAKING_REGISTRY_V2";
    string internal constant CHECKER_KEY = "STOCK_ACCOUNT_PRICE_CHECKER";
    string internal constant OLD_CHECKER_KEY = "STOCK_ACCOUNT_PRICE_CHECKER_PRE_023";

    /// @dev Every reward token's route as it read before the batch, and which tokens the batch repoints
    MamoStakingRegistryV2.Hop[][] internal _routesBefore;
    address[] internal _repointed;
    bool internal _snapshotted;

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
        return "007_RepointStockDropChecker";
    }

    function description() public pure override returns (string memory) {
        return "Point every staking-registry route hop priced by the pre-023 stock checker at the hardened checker";
    }

    function deploy() public override {}

    function preBuildMock() public override {
        MamoStakingRegistryV2 registry = _registry();
        address checker = addresses.getAddress(CHECKER_KEY);

        assertTrue(
            registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), addresses.getAddress("F-MAMO")),
            "F-MAMO should hold DEFAULT_ADMIN_ROLE on the staking registry"
        );
        assertEq(
            address(IStockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY")).priceChecker()),
            checker,
            "023 must execute first"
        );

        delete _routesBefore;
        delete _repointed;
        MamoStakingRegistryV2.RewardToken[] memory tokens = registry.getRewardTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            MamoStakingRegistryV2.Hop[] memory route = registry.getRoute(tokens[i].token);
            _routesBefore.push();
            for (uint256 j = 0; j < route.length; j++) {
                _routesBefore[i].push(route[j]);
            }
            if (_namesOldChecker(route)) _repointed.push(tokens[i].token);
        }
        assertGt(_repointed.length, 0, "No route names the pre-023 checker");
        _snapshotted = true;
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        MamoStakingRegistryV2 registry = _registry();
        address old = addresses.getAddress(OLD_CHECKER_KEY);
        ISlippagePriceChecker checker = ISlippagePriceChecker(addresses.getAddress(CHECKER_KEY));

        for (uint256 i = 0; i < _repointed.length; i++) {
            MamoStakingRegistryV2.Hop[] memory route = registry.getRoute(_repointed[i]);
            for (uint256 j = 0; j < route.length; j++) {
                if (address(route[j].checker) == old) route[j].checker = checker;
            }
            registry.setRoute(_repointed[i], route);
        }
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("F-MAMO"));
    }

    function validate() public view override {
        assertTrue(_snapshotted, "Routes were never snapshotted; run preBuildMock");

        MamoStakingRegistryV2 registry = _registry();
        address old = addresses.getAddress(OLD_CHECKER_KEY);
        address checker = addresses.getAddress(CHECKER_KEY);

        // Same tokens, same hops; a hop on the old checker now names the new one, every other field is unchanged
        MamoStakingRegistryV2.RewardToken[] memory tokens = registry.getRewardTokens();
        assertEq(tokens.length, _routesBefore.length, "reward token count");
        for (uint256 i = 0; i < tokens.length; i++) {
            MamoStakingRegistryV2.Hop[] memory before = _routesBefore[i];
            MamoStakingRegistryV2.Hop[] memory route = registry.getRoute(tokens[i].token);
            assertEq(route.length, before.length, "route length");
            for (uint256 j = 0; j < route.length; j++) {
                assertEq(route[j].pool, before[j].pool, "hop pool");
                assertEq(address(route[j].router), address(before[j].router), "hop router");
                address expected = address(before[j].checker) == old ? checker : address(before[j].checker);
                assertEq(address(route[j].checker), expected, "hop checker");
            }
        }
    }

    function _namesOldChecker(MamoStakingRegistryV2.Hop[] memory route) internal view returns (bool) {
        address old = addresses.getAddress(OLD_CHECKER_KEY);
        for (uint256 j = 0; j < route.length; j++) {
            if (address(route[j].checker) == old) return true;
        }
        return false;
    }

    function _registry() internal view returns (MamoStakingRegistryV2) {
        return MamoStakingRegistryV2(addresses.getAddress(STAKING_REGISTRY_KEY));
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
