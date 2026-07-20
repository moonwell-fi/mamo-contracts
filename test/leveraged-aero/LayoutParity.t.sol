// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "@forge-std/Test.sol";

/// @title LayoutParity
/// @notice Guards the CORRUPTION-CRITICAL invariant that `LeveragedAerodromeCLStrategy.sol`
///         and `LeveragedAeroManager.sol` share an identical diamond-storage triplet:
///         the `RedeemRequest` struct, the `Layout` struct (field types/order/names),
///         and the `STORAGE_SLOT` literal `0x405ae0b1...`. The manager is delegatecalled
///         by the strategy, so any drift silently corrupts storage.
/// @dev Uses FFI to extract each block from the on-disk sources and diff them. Run with:
///        forge test --match-path 'test/leveraged-aero/*' --ffi -vv
///      Line comments are stripped before comparison, so the check tolerates the one
///      benign self-referential comment in `Layout` while catching every storage-relevant
///      change. See layout_parity.sh.
contract LayoutParityTest is Test {
    string constant SCRIPT = "test/leveraged-aero/layout_parity.sh";

    function _diff(string memory kind) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = SCRIPT;
        cmd[2] = kind;
        return string(vm.ffi(cmd));
    }

    function _assertParity(string memory kind, string memory blockName) internal {
        string memory d = _diff(kind);
        if (bytes(d).length != 0) {
            emit log_named_string(string.concat(blockName, " drifted between strategy and manager -- unified diff"), d);
        }
        assertEq(
            bytes(d).length,
            0,
            string.concat(
                blockName,
                " drifted between LeveragedAerodromeCLStrategy.sol and LeveragedAeroManager.sol. ",
                "These share a diamond-storage triplet (Layout/RedeemRequest/STORAGE_SLOT) that MUST ",
                "remain byte-identical -- the manager is delegatecalled by the strategy, so any drift ",
                "silently corrupts storage. See the CORRUPTION-CRITICAL note above each block; ",
                "restore identity, do not 'clean up' either copy."
            )
        );
    }

    function test_RedeemRequestStructParity() public {
        _assertParity("redeemrequest", "RedeemRequest struct");
    }

    function test_LayoutStructParity() public {
        _assertParity("layout", "Layout struct");
    }

    function test_StorageSlotConstantParity() public {
        _assertParity("storageslot", "STORAGE_SLOT constant");
    }

    /// @dev Sanity: the extractor must actually find the blocks. A silent empty match
    ///      (e.g. a renamed struct making both sides empty) would otherwise pass parity.
    function test_ExtractionIsNonEmpty() public {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "awk '/^    struct Layout \\{/,/^    \\}$/{if (/address usdc;/) print \"FOUND\"}' ",
            "src/leveraged-aero/LeveragedAerodromeCLStrategy.sol"
        );
        string memory out = string(vm.ffi(cmd));
        // The strategy Layout block must contain the `address usdc;` field line; if the
        // struct were renamed/emptied, both sides of the parity diff could be empty and
        // silently "match". This proves the extractor is anchored on real content.
        assertEq(out, "FOUND", "extractor found no Layout.usdc field -- struct may have been renamed/moved");
    }
}
