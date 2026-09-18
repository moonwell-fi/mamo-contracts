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
    /// @dev Every entry carries every key: vm.parseJson types a JSON value by its shape, so an entry
    ///      missing one, or writing a feed as "" rather than the zero address, breaks the array decode.
    ///      A PoolTwap entry uses the zero feed and a zero heartbeat
    struct TokenListEntry {
        address chainlinkFeed;
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
        config.twapWindow = uint32(json.readUint(".twapWindow"));

        require(config.chainId == block.chainid, "Config chain id does not match the current chain");
    }

    /// @notice The full deployment configuration
    function getConfig() public view returns (DeploymentConfig memory) {
        return config;
    }

    /// @notice The tokens to list on the stock registry, from config/stock-accounts/<chainId>.json
    /// @dev Returns an empty array when the file is missing or its `.tokens` array is empty
    function loadTokenList() public view returns (TokenListEntry[] memory) {
        string memory path = string.concat("./config/stock-accounts/", vm.toString(config.chainId), ".json");
        if (!vm.isFile(path)) return new TokenListEntry[](0);

        bytes memory raw = vm.parseJson(vm.readFile(path), ".tokens");
        return raw.length == 0 ? new TokenListEntry[](0) : abi.decode(raw, (TokenListEntry[]));
    }
}
