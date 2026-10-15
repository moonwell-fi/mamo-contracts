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

        assertEq(entries.length, 12, "token count");

        string[12] memory symbols =
            ["AAPLc", "AMZNc", "GOOGLc", "METAc", "MSFTc", "MSTRc", "MUc", "NVDAc", "PLTRc", "SNDKc", "SPCXc", "TSLAc"];
        address[12] memory tokens = [
            0xb200000000000000000000C2e324d24d7eEcd1fb,
            0xb200000000000000000000d9192b6B456483C2E8,
            0xb2000000000000000000002D0BA3164cc74f58B7,
            0xb2000000000000000000008bC8786B856E61707C,
            0xB200000000000000000000Ab99cFa739E253872B,
            0xb2000000000000000000004884b426556b92883d,
            0xb200000000000000000000Fd2f87532B90095211,
            0xb20000000000000000000078ee7ce2fE4908108C,
            0xb2000000000000000000007d16372840dF4dAbbe,
            0xb200000000000000000000397293Cb8cda9a10c5,
            0xb2000000000000000000007b9fcbd005511aCBd5,
            0xb2000000000000000000001e800a7f5189430cD0
        ];
        address[12] memory pools = [
            0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0,
            0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b,
            0xB1987CAD1682841b4b641d50E520777eC5Ab5542,
            0xEAF57753BC382E0324a1D43F72E7027705a2273E,
            0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54,
            0x8b27f626ab668197000BC722A1012022CAeD10E2,
            0x17e1bEB2cD65493Da73ed4BbbC7BEcAAa0F91C73,
            0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9,
            0x650cc267AA248191978013d5Ae421e5Dc2A6e242,
            0x5A8236f575471e7BfCA2C8462a200c28f737246E,
            0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E,
            0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB
        ];

        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].symbol, symbols[i], "symbol");
            assertEq(entries[i].token, tokens[i], "token");
            assertEq(entries[i].pool, pools[i], "pool");
            // Carried in the config because the B20 tokens cannot be read from a fork, and used by
            // proposal 016's stand-in and by every one-whole-token probe
            assertEq(entries[i].decimals, 8, "decimals");
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
        assertEq(poolPriced, 12, "pool-priced entries");
    }

    function testLaunchListHasNoChainlinkEntry() public view {
        StockAccountsConfig.TokenListEntry[] memory entries = loader.loadTokenList();

        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].source, "PoolTwap", "source");
        }
    }

    /// @dev Against the list proposal 016 executed with, the one committed list carrying a Chainlink entry
    function testChainlinkEntryCarriesAFeedAndHeartbeat() public view {
        StockAccountsConfig.TokenListEntry[] memory entries =
            loader.loadTokenList("./config/stock-accounts/8453-016.json");

        assertEq(entries[1].source, "Chainlink", "source");
        assertEq(entries[1].token, 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, "cbBTC");
        assertEq(entries[1].chainlinkFeed, 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F, "feed");
        assertEq(entries[1].heartbeat, 3600, "heartbeat");
    }
}
