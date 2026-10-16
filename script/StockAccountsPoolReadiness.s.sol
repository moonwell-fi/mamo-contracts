// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StockAccountsConfig} from "./StockAccountsConfig.sol";

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";

/**
 * @title StockAccountsPoolReadiness
 * @notice Checks the observation ring of every PoolTwap pool in the token list against its TWAP window,
 *         and with GROW=1 grows the short ones
 * @dev Base blocks are about two seconds, so a window needs about window / 2 observations; the ring is
 *      sized at twice that for headroom. A pool already at or above the target is left alone, which
 *      makes a second grow run send nothing
 * @dev Env: DEPLOY_ENV (default 8453_TESTING), ADDRESSES_PATH (default ./addresses),
 *      POOLS (optional comma-separated pool list, used instead of the token list),
 *      GROW (default 0; non-zero sends the grow, only meaningful under --broadcast)
 */
contract StockAccountsPoolReadiness is Script {
    string internal constant REGISTRY_NAME = "STOCK_ACCOUNT_REGISTRY_V2";

    /// @notice Seconds per Base block, the rate at which a pool writes observations
    uint256 internal constant BLOCK_SECONDS = 2;

    /// @notice How many times the window's own observation count the ring is sized at
    uint256 internal constant RING_HEADROOM = 2;

    Addresses internal addresses;
    StockAccountsConfig internal configLoader;

    function run() external {
        string memory environment = vm.envOr("DEPLOY_ENV", string("8453_TESTING"));
        string memory addressesPath = vm.envOr("ADDRESSES_PATH", string("./addresses"));

        // Clears the deployer's EIP-7702 delegation, which FPS reads as a contract, in simulation only
        addresses = PinnedAddresses.load(addressesPath);
        configLoader = new StockAccountsConfig(string.concat("./deploy/stock-accounts/", environment, ".json"));

        bool grow = vm.envOr("GROW", uint256(0)) != 0;
        uint32 twapWindow = _twapWindow();
        uint16 required = _requiredCardinality(twapWindow);

        console.log(
            "twap window: %s seconds, required cardinality: %s",
            vm.toString(uint256(twapWindow)),
            vm.toString(uint256(required))
        );

        (string[] memory symbols, address[] memory pools) = _targets();
        require(pools.length != 0, "Pool readiness: no pools to check");

        for (uint256 i = 0; i < pools.length; i++) {
            _check(symbols[i], ICLPool(pools[i]), twapWindow, required, grow);
        }
    }

    /// @notice The window the deployed registry enforces, or the configured one before it exists
    function _twapWindow() internal view returns (uint32) {
        if (addresses.isAddressSet(REGISTRY_NAME)) {
            return IStockAccountRegistry(addresses.getAddress(REGISTRY_NAME)).twapWindow();
        }
        return configLoader.getConfig().twapWindow;
    }

    /// @notice Observations a window needs at Base's block rate, times the headroom factor
    /// @dev BLOCK_SECONDS and RING_HEADROOM are both 2 today, so the two cancel and the target equals
    ///      the window in seconds: 180 for the configured 180-second window. They are named rather than
    ///      folded away because moving either one is what changes the target
    function _requiredCardinality(uint32 twapWindow) internal pure returns (uint16) {
        uint256 required = (uint256(twapWindow) / BLOCK_SECONDS) * RING_HEADROOM;
        return required > type(uint16).max ? type(uint16).max : uint16(required);
    }

    /// @notice The pools to check: the POOLS override when set, else every PoolTwap entry of the token list
    function _targets() internal view returns (string[] memory symbols, address[] memory pools) {
        string memory poolsEnv = vm.envOr("POOLS", string(""));

        if (bytes(poolsEnv).length > 0) {
            string[] memory parts = vm.split(poolsEnv, ",");
            symbols = new string[](parts.length);
            pools = new address[](parts.length);
            for (uint256 i = 0; i < parts.length; i++) {
                symbols[i] = "POOLS";
                pools[i] = vm.parseAddress(parts[i]);
            }
            return (symbols, pools);
        }

        StockAccountsConfig.TokenListEntry[] memory entries = configLoader.loadTokenList();
        symbols = new string[](entries.length);
        pools = new address[](entries.length);
        uint256 count;
        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].source)) != keccak256(bytes("PoolTwap"))) continue;
            symbols[count] = entries[i].symbol;
            pools[count] = entries[i].pool;
            count++;
        }
        assembly ("memory-safe") {
            mstore(symbols, count)
            mstore(pools, count)
        }
    }

    /// @notice Reports one pool's ring, grows it when it is short and `grow` is set, then reports whether it
    ///         serves the window
    /// @dev The observe result is information only: a freshly grown ring still has to fill with blocks,
    ///      so a "no" right after a grow is expected rather than a failure
    function _check(string memory symbol, ICLPool pool, uint32 twapWindow, uint16 required, bool grow) internal {
        (,,, uint16 cardinality, uint16 next,) = pool.slot0();

        console.log(
            "%s %s %s",
            symbol,
            vm.toString(address(pool)),
            string.concat(
                vm.toString(uint256(cardinality)),
                "/",
                vm.toString(uint256(next)),
                " required ",
                vm.toString(uint256(required))
            )
        );

        if (next < required && !grow) {
            console.log("  needs growing to %s, run make stock-pool-grow", vm.toString(uint256(required)));
        } else if (next < required) {
            vm.broadcast();
            pool.increaseObservationCardinalityNext(required);

            (,,, cardinality, next,) = pool.slot0();
            console.log("  grown to %s/%s", vm.toString(uint256(cardinality)), vm.toString(uint256(next)));
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos) {
            console.log("  serves window: yes");
        } catch {
            console.log("  serves window: no");
        }
    }
}
