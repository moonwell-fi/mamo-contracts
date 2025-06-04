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
        uint8 decimals;
        string token;
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
        uint256 strategyTypeId;
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
     * @notice Load configuration from the JSON file
     */
    function _loadConfig(string memory configPath) private {
        configData = vm.readFile(configPath);

        // Copy fields individually to avoid struct array memory to storage copy
        config.symbol = abi.decode(vm.parseJson(configData, ".symbol"), (string));
        config.token = abi.decode(vm.parseJson(configData, ".token"), (string));
        config.decimals = abi.decode(vm.parseJson(configData, ".decimals"), (uint8));
        config.moonwellMarket = abi.decode(vm.parseJson(configData, ".moonwellMarket"), (string));
        config.metamorphoVault = abi.decode(vm.parseJson(configData, ".metamorphoVault"), (string));
        config.priceOracle = abi.decode(vm.parseJson(configData, ".priceOracle"), (string));
        config.strategyParams = abi.decode(vm.parseJson(configData, ".strategyParams"), (StrategyParams));

        // Handle the array separately
        config.rewardTokens = abi.decode(vm.parseJson(configData, ".rewardTokens"), (RewardToken[]));
    }
}
