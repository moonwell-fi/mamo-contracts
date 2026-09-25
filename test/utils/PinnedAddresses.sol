// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "@forge-std/Vm.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/// @notice Loads the FPS book on a fork pinned before some of its deployments
library PinnedAddresses {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function load(string memory folder) internal returns (Addresses addresses) {
        address[] memory lent = lend(folder);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(folder, chainIds);

        repay(lent);
    }

    /// @dev FPS requires code at every contract entry, so entries deployed after the pin borrow a byte.
    ///      Repay it once the book is built, since those can be a deployer's next CREATE addresses.
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
            }
        }

        assembly ("memory-safe") {
            mstore(lent, count)
        }
    }

    function repay(address[] memory lent) internal {
        for (uint256 i = 0; i < lent.length; i++) {
            vm.etch(lent[i], "");
        }
    }
}
