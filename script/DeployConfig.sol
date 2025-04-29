// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/**
 * @title DeployConfig
 * @notice Contract to manage deployment configuration for different environments and versions
 * @dev Reads configuration from JSON files in the deploy/ directory
 */
contract DeployConfig is Test {
    using stdJson for string;

    /// @notice Configuration data
    string private configData;

    DeploymentConfig private config;

    /// @notice Deployment configuration struct
    struct DeploymentConfig {
        string admin;
        uint256 allowedSlippageInBps;
        string backend;
        uint256 chainId;
        uint256 compoundFee;
        string guardian;
        uint256 hookGasLimit;
        uint256 maxPriceValidTime;
        RewardToken[] rewardTokens;
        uint256 splitMToken;
        uint256 splitVault;
        string version;
    }

    /// @notice Reward token configuration struct
    struct RewardToken {
        uint256 heartbeat;
        string priceFeed;
        bool reverse;
        string token;
    }

    constructor(string memory _configPath) {
        // Load configuration
        _loadConfig(_configPath);
    }

    /**
     * @notice Get the full deployment configuration
     * @return The DeploymentConfig struct
     */
    function getConfig() public view returns (DeploymentConfig memory) {
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
        DeploymentConfig memory memConfig = abi.decode(parsedJson, (DeploymentConfig));

        // Copy fields individually to avoid struct array memory to storage copy
        config.admin = memConfig.admin;
        config.allowedSlippageInBps = memConfig.allowedSlippageInBps;
        config.backend = memConfig.backend;
        config.chainId = memConfig.chainId;
        config.compoundFee = memConfig.compoundFee;
        config.guardian = memConfig.guardian;
        config.hookGasLimit = memConfig.hookGasLimit;
        config.maxPriceValidTime = memConfig.maxPriceValidTime;
        config.splitMToken = memConfig.splitMToken;
        config.splitVault = memConfig.splitVault;
        config.version = memConfig.version;

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
