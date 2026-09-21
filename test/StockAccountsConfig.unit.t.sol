// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";

/// @notice Guards the committed token list: a malformed entry fails the decode here rather than at deploy
contract StockAccountsConfigUnitTest is Test {
    StockAccountsConfig internal loader;

    function setUp() public {
        vm.chainId(8453);
        loader = new StockAccountsConfig("./deploy/stock-accounts/8453_TESTING.json");
    }

    /// @dev Pinned by exact address, not merely non-zero: a field written as "" is encoded as a string
    ///      and decodes to the ABI offset 0x...C0, which a non-zero check waves through
    function testTokenListDecodesTheCommittedEntries() public view {
        StockAccountsConfig.TokenListEntry[] memory entries = loader.loadTokenList();

        assertEq(entries.length, 5, "token count");

        string[5] memory symbols = ["AAPLc", "cbBTC", "GOOGLc", "METAc", "NVDAc"];
        address[5] memory tokens = [
            0xb200000000000000000000C2e324d24d7eEcd1fb,
            0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf,
            0xb2000000000000000000002D0BA3164cc74f58B7,
            0xb2000000000000000000008bC8786B856E61707C,
            0xb20000000000000000000078ee7ce2fE4908108C
        ];
        address[5] memory pools = [
            0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0,
            0x160D7E9d948B16c163332a277b393c288408eb12,
            0xB1987CAD1682841b4b641d50E520777eC5Ab5542,
            0xEAF57753BC382E0324a1D43F72E7027705a2273E,
            0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9
        ];

        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].symbol, symbols[i], "symbol");
            assertEq(entries[i].token, tokens[i], "token");
            assertEq(entries[i].pool, pools[i], "pool");
        }
    }

    /// @dev The count is asserted too, so a mis-cased `source` cannot empty the loop and pass
    function testPoolTwapEntriesCarryNoFeed() public view {
        StockAccountsConfig.TokenListEntry[] memory entries = loader.loadTokenList();

        uint256 poolPriced;
        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].source)) != keccak256(bytes("PoolTwap"))) continue;
            assertEq(entries[i].chainlinkFeed, address(0), "feed");
            assertEq(entries[i].heartbeat, 0, "heartbeat");
            poolPriced++;
        }
        assertEq(poolPriced, 4, "pool-priced entries");
    }

    function testChainlinkEntryCarriesAFeedAndHeartbeat() public view {
        StockAccountsConfig.TokenListEntry[] memory entries = loader.loadTokenList();

        assertEq(entries[1].source, "Chainlink", "source");
        assertEq(entries[1].token, 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, "cbBTC");
        assertEq(entries[1].chainlinkFeed, 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F, "feed");
        assertEq(entries[1].heartbeat, 3600, "heartbeat");
    }
}
