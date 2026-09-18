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

    function testTokenListDecodesTheCommittedEntries() public view {
        StockAccountsConfig.TokenListEntry[] memory entries = loader.loadTokenList();

        assertEq(entries.length, 5, "token count");

        string[5] memory symbols = ["AAPLc", "cbBTC", "GOOGLc", "METAc", "NVDAc"];
        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].symbol, symbols[i], "symbol");
            assertTrue(entries[i].token != address(0), "token");
            assertTrue(entries[i].pool != address(0), "pool");
        }
    }

    function testPoolTwapEntriesCarryNoFeed() public view {
        StockAccountsConfig.TokenListEntry[] memory entries = loader.loadTokenList();

        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].source)) != keccak256(bytes("PoolTwap"))) continue;
            assertEq(entries[i].chainlinkFeed, address(0), "feed");
            assertEq(entries[i].heartbeat, 0, "heartbeat");
        }
    }

    function testChainlinkEntryCarriesAFeedAndHeartbeat() public view {
        StockAccountsConfig.TokenListEntry[] memory entries = loader.loadTokenList();

        assertEq(entries[1].source, "Chainlink", "source");
        assertEq(entries[1].token, 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, "cbBTC");
        assertEq(entries[1].chainlinkFeed, 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F, "feed");
        assertEq(entries[1].heartbeat, 3600, "heartbeat");
    }
}
