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
        string compounder;
        uint256 compoundFee;
        string deployer;
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

        // Parse individual fields instead of using abi.decode
        config.admin = configData.readString(".admin");
        config.allowedSlippageInBps = configData.readUint(".allowedSlippageInBps");
        config.backend = configData.readString(".backend");
        config.chainId = configData.readUint(".chainId");
        config.compounder = configData.readString(".compounder");
        config.compoundFee = configData.readUint(".compoundFee");
        config.deployer = configData.readString(".deployer");
        config.guardian = configData.readString(".guardian");
        config.hookGasLimit = configData.readUint(".hookGasLimit");
        config.maxPriceValidTime = configData.readUint(".maxPriceValidTime");
        config.splitMToken = configData.readUint(".splitMToken");
        config.splitVault = configData.readUint(".splitVault");
        config.version = configData.readString(".version");

        // Handle reward tokens array
        bytes memory rewardTokensJson = vm.parseJson(configData, ".rewardTokens");
        RewardToken[] memory rewardTokens = abi.decode(rewardTokensJson, (RewardToken[]));

        delete config.rewardTokens;
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            config.rewardTokens.push(rewardTokens[i]);
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
