// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "@forge-std/Vm.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/// @notice Loads the FPS book on a fork pinned before some of its deployments
library PinnedAddresses {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice `load` from a copy of the book in `dir` that leaves out `names`, entries deployed after the pin
    ///         that a proposal under rehearsal would otherwise treat as already deployed
    function loadWithout(string memory folder, string memory dir, string[] memory names)
        internal
        returns (Addresses addresses)
    {
        string memory file = string.concat("/", vm.toString(block.chainid), ".json");
        Addresses.FileAddresses[] memory book =
            abi.decode(vm.parseJson(vm.readFile(string.concat(folder, file))), (Addresses.FileAddresses[]));

        string memory json = "[";
        bool first = true;
        for (uint256 i = 0; i < book.length; i++) {
            if (_listed(book[i].name, names)) continue;
            json = string.concat(
                json,
                first ? "" : ",",
                '{"addr":"',
                vm.toString(book[i].addr),
                '","name":"',
                book[i].name,
                '","isContract":',
                book[i].isContract ? "true" : "false",
                "}"
            );
            first = false;
        }

        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, file), string.concat(json, "]"));
        addresses = load(dir);
    }

    function load(string memory folder) internal returns (Addresses addresses) {
        address[] memory lent = lend(folder);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(folder, chainIds);

        repay(lent);
    }

    /// @dev FPS requires code at every contract entry, so entries deployed after the pin borrow a byte.
    ///      Repay it once the book is built, since those can be a deployer's next CREATE addresses.
    ///      It also refuses code at an EOA entry, which an EIP-7702 delegation leaves behind, so that
    ///      code is cleared and stays cleared: the tests use the deployer as a plain sender.
    function lend(string memory folder) internal returns (address[] memory lent) {
        Addresses.FileAddresses[] memory book = abi.decode(
            vm.parseJson(vm.readFile(string.concat(folder, "/", vm.toString(block.chainid), ".json"))),
            (Addresses.FileAddresses[])
        );

        lent = new address[](book.length);
        uint256 count;
        for (uint256 i = 0; i < book.length; i++) {
            if (book[i].isContract && book[i].addr.code.length == 0) {
                vm.etch(book[i].addr, hex"00");
                lent[count++] = book[i].addr;
            } else if (!book[i].isContract && book[i].addr.code.length != 0) {
                vm.etch(book[i].addr, "");
            }
        }

        assembly ("memory-safe") {
            mstore(lent, count)
        }
    }

    function _listed(string memory name, string[] memory names) private pure returns (bool) {
        for (uint256 i = 0; i < names.length; i++) {
            if (keccak256(bytes(name)) == keccak256(bytes(names[i]))) return true;
        }
        return false;
    }

    function repay(address[] memory lent) internal {
        for (uint256 i = 0; i < lent.length; i++) {
            vm.etch(lent[i], "");
        }
    }
}
