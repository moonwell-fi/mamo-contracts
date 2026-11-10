// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "@forge-std/Vm.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/// @notice Builds the FPS address book on a fork pinned below some of its entries.
/// @dev FPS checks every `isContract` entry has code at construction. Entries deployed after the
///      pin get one byte of code for that constructor only, then lose it again.
library AddressBookHarness {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function build(string memory folder) internal returns (Addresses addresses) {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        address[] memory lent = lendCodeToEntriesDeployedAfterThePin(folder);
        addresses = new Addresses(folder, chainIds);
        returnLoan(lent);
    }

    /// @notice Strip the lent byte again: those slots can be a deployer's next CREATE addresses here.
    function returnLoan(address[] memory lent) internal {
        for (uint256 i = 0; i < lent.length; i++) {
            vm.etch(lent[i], "");
        }
    }

    /// @return lent The `isContract` entries that had no code and were given one byte.
    function lendCodeToEntriesDeployedAfterThePin(string memory folder) internal returns (address[] memory lent) {
        string memory path = string.concat(folder, "/", vm.toString(block.chainid), ".json");
        Addresses.FileAddresses[] memory book = abi.decode(vm.parseJson(vm.readFile(path)), (Addresses.FileAddresses[]));
        lent = new address[](book.length);
        uint256 count;
        for (uint256 i = 0; i < book.length; i++) {
            if (book[i].isContract && book[i].addr.code.length == 0) {
                vm.etch(book[i].addr, hex"00");
                lent[count++] = book[i].addr;
            }
        }
        assembly {
            mstore(lent, count)
        }
    }

    /// @notice Unset `name` on this chain, so a replay can deploy and register it again.
    /// @dev Zeroes the `_addresses[name][chainid]` slot found by recording the getter's read.
    function forget(Addresses addresses, string memory name) internal {
        vm.record();
        addresses._addresses(name, block.chainid);
        (bytes32[] memory reads,) = vm.accesses(address(addresses));
        require(reads.length == 1, "AddressBookHarness: unexpected getter reads");
        vm.store(address(addresses), reads[0], bytes32(0));
        require(!addresses.isAddressSet(name), "AddressBookHarness: forget failed");
    }
}
