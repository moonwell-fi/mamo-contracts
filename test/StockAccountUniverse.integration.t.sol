// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ListStockUniverse} from "../multisig/mamo-multisig/018_ListStockUniverse.sol";

import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";

import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

/**
 * @title StockAccountUniverseListingTest
 * @notice Base-fork rehearsal of multisig proposal 018 against the live stock registry, self-forked at
 *         a pinned block (no --fork-url, same op-revm reason as StockAccountSystemSetupTest)
 */
contract StockAccountUniverseListingTest is Test {
    /// @dev Live registry lists AAPLc, cbBTC (Active), GOOGLc, METAc, NVDAc; the eight new stocks read None
    uint256 internal constant PINNED_BLOCK = 52_381_500;

    address internal constant DEPLOYER_EOA = 0xDca82E03057329f53Ed4173429D46B0511E46Fb8;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    bytes internal constant CBBTC_HALT =
        hex"15d95a00000000000000000000000000cbb7c0000ab88b473b1f5afd9ef808440eed33bf0000000000000000000000000000000000000000000000000000000000000003";
    bytes internal constant AMZNC_LISTING =
        hex"5874e177000000000000000000000000b200000000000000000000d9192b6b456483c2e800000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d03bc8c7f2faedce2aac81bf0444aea08ea06e9b0000000000000000000000000000000000000000000000000000000000000000";

    ListStockUniverse internal proposal;
    Addresses internal addresses;
    StockAccountRegistry internal registry;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        /// @dev The deployer carries an EIP-7702 delegation since block 51,790,538, which FPS reads as a contract
        vm.etch(DEPLOYER_EOA, "");
        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));

        registry = StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY_DEPRECATED"));
        proposal = new ListStockUniverse();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
    }

    function test_listStockUniverse() public {
        proposal.preBuildMock();
        proposal.build();

        uint256 gasBefore = gasleft();
        proposal.simulate();
        console.log("simulate() gas, Safe stand-in deployment included:", gasBefore - gasleft());

        proposal.validate();

        (address[] memory targets, uint256[] memory values, bytes[] memory args) = proposal.getProposalActions();
        address[8] memory listed = [
            0xb200000000000000000000d9192b6B456483C2E8, // AMZNc
            0xB200000000000000000000Ab99cFa739E253872B, // MSFTc
            0xb2000000000000000000004884b426556b92883d, // MSTRc
            0xb200000000000000000000Fd2f87532B90095211, // MUc
            0xb2000000000000000000007d16372840dF4dAbbe, // PLTRc
            0xb200000000000000000000397293Cb8cda9a10c5, // SNDKc
            0xb2000000000000000000007b9fcbd005511aCBd5, // SPCXc
            0xb2000000000000000000001e800a7f5189430cD0 // TSLAc
        ];

        assertEq(targets.length, 9, "one halt + eight listings");
        for (uint256 i = 0; i < targets.length; i++) {
            assertEq(targets[i], address(registry), "action target");
            assertEq(values[i], 0, "no action moves ETH");
        }
        assertEq(args[0], CBBTC_HALT, "cbBTC halt calldata");
        assertEq(args[1], AMZNC_LISTING, "AMZNc listing calldata");
        for (uint256 i = 0; i < listed.length; i++) {
            assertEq(bytes4(args[1 + i]), StockAccountRegistry.listToken.selector, "listing selector");
            assertEq(
                abi.decode(_arguments(args[1 + i]), (address)), listed[i], "listToken targets the real token address"
            );
            assertEq(
                uint256(registry.tokenConfig(listed[i]).status),
                uint256(IStockAccountRegistry.TokenStatus.Active),
                "new stock Active"
            );
        }

        assertEq(registry.allTokens().length, 13, "five existing listings + eight new");
        assertEq(
            uint256(registry.tokenConfig(CBBTC).status),
            uint256(IStockAccountRegistry.TokenStatus.Halted),
            "cbBTC Halted"
        );
        assertEq(
            registry.tokenConfig(0xb20000000000000000000078ee7ce2fE4908108C).pool,
            0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9,
            "NVDAc pool untouched"
        );
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

        bytes memory transactions = abi.decode(_arguments(payload), (bytes));
        assertEq(bytes4(payload), bytes4(keccak256("multiSend(bytes)")), "multiSend selector");
        assertEq(
            _slice(transactions, 0, 85 + CBBTC_HALT.length),
            abi.encodePacked(uint8(0), address(registry), uint256(0), uint256(CBBTC_HALT.length), CBBTC_HALT),
            "first packed transaction is the cbBTC halt"
        );
    }

    /// @notice Once executed, the diff against the registry is empty
    function test_rerunAfterExecutionBuildsNothing() public {
        proposal.preBuildMock();
        proposal.build();
        proposal.simulate();

        ListStockUniverse rerun = new ListStockUniverse();
        rerun.setPrimaryForkId(vm.activeFork());
        rerun.setAddresses(addresses);
        rerun.preBuildMock();
        rerun.build();

        vm.expectRevert(bytes("No actions found"));
        rerun.getProposalActions();
    }

    function _arguments(bytes memory data) internal pure returns (bytes memory) {
        return _slice(data, 4, data.length - 4);
    }

    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[start + i];
        }
    }
}
