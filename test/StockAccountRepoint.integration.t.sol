// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RepointStocksToSlipstreamV3} from "../multisig/mamo-multisig/021_RepointStocksToSlipstreamV3.sol";

import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

/**
 * @title StockAccountRepointTest
 * @notice Base-fork rehearsal of multisig proposal 021 against the live V2 stock registry, self-forked at
 *         a pinned block (no --fork-url, same op-revm reason as StockAccountSystemSetupTest)
 */
contract StockAccountRepointTest is Test {
    /// @dev After Slipstream V3 and 019; the registry still routes through the old router and lists the old pools
    uint256 internal constant PINNED_BLOCK = 53_120_000;

    address internal constant OLD_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;

    bytes internal constant ROUTER_CALL = hex"d52506810000000000000000000000009ee35bf1bd69a03c6f0393582030fce8bb93d418";
    bytes internal constant AAPLC_POOL_CALL =
        hex"d77c5e17000000000000000000000000b200000000000000000000c2e324d24d7eecd1fb000000000000000000000000f5fcb9cdafce67d50afef298f88e709d2b946ba6";

    RepointStocksToSlipstreamV3 internal proposal;
    Addresses internal addresses;
    StockAccountRegistry internal registry;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));

        registry = StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY"));
        proposal = new RepointStocksToSlipstreamV3();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
    }

    function test_repointStocksToSlipstreamV3() public {
        assertEq(address(registry.aerodromeRouter()), OLD_ROUTER, "registry starts on the old router");

        proposal.preBuildMock();
        proposal.build();

        uint256 gasBefore = gasleft();
        proposal.simulate();
        console.log("simulate() gas, Safe stand-in deployment included:", gasBefore - gasleft());

        proposal.validate();

        (address[] memory targets, uint256[] memory values, bytes[] memory args) = proposal.getProposalActions();
        StockAccountsConfig.TokenListEntry[] memory entries = proposal.deployConfig().loadTokenList();

        assertEq(entries.length, 12, "twelve stocks on the list");
        assertEq(targets.length, 1 + 3 * entries.length, "router, then halt, repoint and reactivate per stock");
        for (uint256 i = 0; i < targets.length; i++) {
            assertEq(targets[i], address(registry), "action target");
            assertEq(values[i], 0, "no action moves ETH");
        }
        assertEq(args[0], ROUTER_CALL, "router calldata");
        assertEq(args[2], AAPLC_POOL_CALL, "AAPLc repoint calldata");
        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(
                args[1 + 3 * i],
                abi.encodeCall(registry.setTokenStatus, (entries[i].token, IStockAccountRegistry.TokenStatus.Halted)),
                "halt"
            );
            assertEq(
                args[2 + 3 * i], abi.encodeCall(registry.setTokenPool, (entries[i].token, entries[i].pool)), "repoint"
            );
            assertEq(
                args[3 + 3 * i],
                abi.encodeCall(registry.setTokenStatus, (entries[i].token, IStockAccountRegistry.TokenStatus.Active)),
                "reactivate"
            );
        }
    }

    /// @notice Prints what the Safe signs: the MultiSend payload and each action, in execution order
    function test_safeCalldata() public {
        proposal.preBuildMock();
        proposal.build();

        (address[] memory targets, uint256[] memory values, bytes[] memory args) = proposal.getProposalActions();
        bytes memory payload = proposal.getCalldata();

        console.log("MultiSend multiSend(bytes) payload:");
        console.logBytes(payload);
        for (uint256 i = 0; i < targets.length; i++) {
            console.log("action", i + 1, targets[i], values[i]);
            console.logBytes(args[i]);
        }

        assertEq(bytes4(payload), bytes4(keccak256("multiSend(bytes)")), "multiSend selector");
    }

    /// @notice Once executed, the diff against the registry is empty
    function test_rerunAfterExecutionBuildsNothing() public {
        proposal.preBuildMock();
        proposal.build();
        proposal.simulate();

        RepointStocksToSlipstreamV3 rerun = new RepointStocksToSlipstreamV3();
        rerun.setPrimaryForkId(vm.activeFork());
        rerun.setAddresses(addresses);
        rerun.preBuildMock();
        rerun.build();

        vm.expectRevert(bytes("No actions found"));
        rerun.getProposalActions();
    }
}
