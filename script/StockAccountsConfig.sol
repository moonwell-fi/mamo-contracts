// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {stdJson} from "@forge-std/StdJson.sol";

/**
 * @title StockAccountsConfig
 * @notice Loads the stock accounts deployment configuration from deploy/stock-accounts/<env>.json
 * @dev Address fields hold FPS address names, resolved through Addresses at use-time
 */
contract StockAccountsConfig is Script {
    using stdJson for string;

    /// @notice A token to list on the stock registry, fields alphabetized to match the JSON
    /// @dev vm.parseJson types a JSON value by its shape and encodes the keys in alphabetical order, so
    ///      every entry has to carry every key. A missing key does revert the decode, but a key of the
    ///      wrong type in the right position does not: an address written as "" is encoded as a string
    ///      and reads back as the ABI offset, 0x...C0, a nonzero garbage address. _validate below is
    ///      what catches that. A PoolTwap entry uses the zero feed and a zero heartbeat
    /// @dev `decimals` is carried in the config rather than read off the token because the four B20
    ///      stocks are node-native: their onchain code is the single reserved byte 0xEF, which revm
    ///      refuses to execute, so `decimals()` cannot be called on them from a fork simulation
    struct TokenListEntry {
        address chainlinkFeed;
        uint8 decimals;
        uint256 heartbeat;
        address pool;
        string source;
        string symbol;
        address token;
    }

    /// @notice Deployment configuration, fields alphabetized to match the JSON
    struct DeploymentConfig {
        string admin;
        string aerodromeRouter;
        string asset;
        string backend;
        uint256 chainId;
        string cowSettlement;
        /// @dev The audited SlippagePriceChecker every PriceSource.Chainlink token is priced against
        string existingPriceChecker;
        string feeRecipient;
        string guardian;
        uint16 managementFeeBps;
        uint16 maxBackendSlippageBps;
        uint16 maxDeviationBps;
        uint8 maxPositions;
        uint256 maxStrategyDeposit;
        uint16 maxWithdrawSlippageBps;
        uint256 minStrategyDeposit;
        uint16 minTargetBps;
        string orderSigner;
        /// @dev Bootstrap only: satisfies the registry constructor, then setPriceChecker replaces it
        string placeholderPriceChecker;
        /// @dev Chosen, never auto-assigned: the registry's counter is a stale lower bound, not the next free slot
        uint256 strategyTypeId;
        uint32 twapWindow;
    }

    DeploymentConfig private config;

    constructor(string memory configPath) {
        string memory json = vm.readFile(configPath);

        config.admin = json.readString(".admin");
        config.aerodromeRouter = json.readString(".aerodromeRouter");
        config.asset = json.readString(".asset");
        config.backend = json.readString(".backend");
        config.chainId = json.readUint(".chainId");
        config.cowSettlement = json.readString(".cowSettlement");
        config.existingPriceChecker = json.readString(".existingPriceChecker");
        config.feeRecipient = json.readString(".feeRecipient");
        config.guardian = json.readString(".guardian");
        config.managementFeeBps = uint16(json.readUint(".managementFeeBps"));
        config.maxBackendSlippageBps = uint16(json.readUint(".maxBackendSlippageBps"));
        config.maxDeviationBps = uint16(json.readUint(".maxDeviationBps"));
        config.maxPositions = uint8(json.readUint(".maxPositions"));
        config.maxStrategyDeposit = json.readUint(".maxStrategyDeposit");
        config.maxWithdrawSlippageBps = uint16(json.readUint(".maxWithdrawSlippageBps"));
        config.minStrategyDeposit = json.readUint(".minStrategyDeposit");
        config.minTargetBps = uint16(json.readUint(".minTargetBps"));
        config.orderSigner = json.readString(".orderSigner");
        config.placeholderPriceChecker = json.readString(".placeholderPriceChecker");
        config.strategyTypeId = json.readUint(".strategyTypeId");
        config.twapWindow = uint32(json.readUint(".twapWindow"));

        require(config.chainId == block.chainid, "Config chain id does not match the current chain");
    }

    /// @notice The full deployment configuration
    function getConfig() public view returns (DeploymentConfig memory) {
        return config;
    }

    /// @notice The tokens to list on the stock registry, from config/stock-accounts/<chainId>.json
    /// @dev A missing or empty list is fatal rather than an empty array: every consumer loops over it,
    ///      and an empty loop is a deploy that lists nothing and a readiness run that checks nothing.
    ///      Every entry is validated here, so a malformed one fails before any consumer reads it
    function loadTokenList() public view returns (TokenListEntry[] memory) {
        string memory path = string.concat("./config/stock-accounts/", vm.toString(config.chainId), ".json");
        require(vm.isFile(path), string.concat("Token list: no such file, ", path));

        bytes memory raw = vm.parseJson(vm.readFile(path), ".tokens");
        require(raw.length != 0, string.concat("Token list: empty .tokens in ", path));

        TokenListEntry[] memory entries = abi.decode(raw, (TokenListEntry[]));
        for (uint256 i = 0; i < entries.length; i++) {
            _validate(entries[i]);
        }
        return entries;
    }

    /// @notice Rejects a token list entry the deploy would otherwise carry into an admin batch
    /// @dev The decode cannot do this on its own: a mistyped value reads back as garbage rather than
    ///      reverting, and a mis-cased `source` compares unequal to both legal strings, which would
    ///      drop the entry out of pool readiness while still listing it as pool-priced
    function _validate(TokenListEntry memory entry) internal pure {
        string memory symbol = entry.symbol;

        require(entry.token != address(0), string.concat("Token list: zero token, ", symbol));
        require(entry.pool != address(0), string.concat("Token list: zero pool, ", symbol));
        require(entry.decimals != 0, string.concat("Token list: zero decimals, ", symbol));

        bytes32 source = keccak256(bytes(entry.source));
        bool isChainlink = source == keccak256(bytes("Chainlink"));
        require(
            isChainlink || source == keccak256(bytes("PoolTwap")), string.concat("Token list: bad source, ", symbol)
        );

        require(
            (entry.chainlinkFeed != address(0)) == isChainlink, string.concat("Token list: feed vs source, ", symbol)
        );
        require((entry.heartbeat != 0) == isChainlink, string.concat("Token list: heartbeat vs source, ", symbol));
    }
}
