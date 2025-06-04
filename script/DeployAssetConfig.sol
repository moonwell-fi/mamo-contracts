// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/**
 * @title DeployAssetConfig
 * @notice Contract to manage deployment configuration for different environments and versions
 * @dev Reads configuration from JSON files in the deploy/ directory
 */
contract DeployAssetConfig is Test {
    using stdJson for string;

    /// @notice Configuration data
    string private configData;

    struct Config {
        string symbol;
        string token;
        uint8 decimals;
        string moonwellMarket;
        string metamorphoVault;
        string priceOracle;
        StrategyParams strategyParams;
        RewardToken[] rewardTokens;
    }

    struct StrategyParams {
        uint256 splitMToken;
        uint256 splitVault;
        uint256 hookGasLimit;
        uint256 allowedSlippageInBps;
        uint256 compoundFee;
    }

    /// @notice Reward token configuration struct
    struct RewardToken {
        uint256 heartbeat;
        string priceFeed;
        bool reverse;
        string token;
    }

    Config private config;

    constructor(string memory _configPath) {
        // Load configuration
        _loadConfig(_configPath);
    }

    /**
     * @notice Get the full deployment configuration
     * @return The DeploymentConfig struct
     */
    function getConfig() public view returns (Config memory) {
        return config;
    }

    /**
     * @notice Get a string value from the configuration
     * @param key The configuration key
     * @return The string value
     */
    function getString(string memory key) public view returns (string memory) {
        string memory jsonPath = string(abi.encodePacked(".", key));

        // Check if the key exists in the JSON
        if (!configData.keyExists(jsonPath)) {
            revert(string(abi.encodePacked("Config key not found: ", key)));
        }

        return configData.readString(jsonPath);
    }

    /**
     * @notice Get a number value from the configuration
     * @param key The configuration key
     * @return The number value
     */
    function getNumber(string memory key) public view returns (uint256) {
        string memory jsonPath = string(abi.encodePacked(".", key));

        // Check if the key exists in the JSON
        if (!configData.keyExists(jsonPath)) {
            revert(string(abi.encodePacked("Config key not found: ", key)));
        }

        return configData.readUint(jsonPath);
    }

    /**
     * @notice Get a boolean value from the configuration
     * @param key The configuration key
     * @return The boolean value
     */
    function getBool(string memory key) public view returns (bool) {
        string memory jsonPath = string(abi.encodePacked(".", key));

        // Check if the key exists in the JSON
        if (!configData.keyExists(jsonPath)) {
            revert(string(abi.encodePacked("Config key not found: ", key)));
        }

        return configData.readBool(jsonPath);
    }

    /**
     * @notice Get the version from the configuration
     * @return The version string
     */
    function getVersion() public view returns (string memory) {
        return getString("version");
    }

    /**
     * @notice Get the chain ID from the configuration
     * @return The chain ID
     */
    function getChainId() public view returns (uint256) {
        return getNumber("chainId");
    }

    /**
     * @notice Load configuration from the JSON file
     */
    function _loadConfig(string memory configPath) private {
        configData = vm.readFile(configPath);

        bytes memory parsedJson = vm.parseJson(configData);

        // Decode to a memory struct first
        Config memory memConfig = abi.decode(parsedJson, (Config));

        // Copy fields individually to avoid struct array memory to storage copy
        config.symbol = memConfig.symbol;
        config.token = memConfig.token;
        config.decimals = memConfig.decimals;
        config.moonwellMarket = memConfig.moonwellMarket;
        config.metamorphoVault = memConfig.metamorphoVault;
        config.priceOracle = memConfig.priceOracle;
        config.strategyParams = memConfig.strategyParams;

        // Handle the array separately
        if (memConfig.rewardTokens.length > 0) {
            // Initialize the storage array with the correct length
            delete config.rewardTokens;
            for (uint256 i = 0; i < memConfig.rewardTokens.length; i++) {
                config.rewardTokens.push(memConfig.rewardTokens[i]);
            }
        }

        // Validate configuration
        require(
            getChainId() == block.chainid,
            string(
                abi.encodePacked(
                    "Config chain ID (",
                    vm.toString(getChainId()),
                    ") does not match current chain ID (",
                    vm.toString(block.chainid),
                    ")"
                )
            )
        );
    }
}
