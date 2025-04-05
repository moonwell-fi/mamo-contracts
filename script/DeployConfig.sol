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
        string backend;
        uint256 chainId;
        string guardian;
        uint256 maxPriceValidTime;
        uint256 maxSlippageBps;
        RewardToken[] rewardTokens;
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
     * @notice Get the number of reward tokens in the configuration
     * @return The number of reward tokens
     */
    function getRewardTokenCount() public view returns (uint256) {
        uint256 i = 0;
        while (true) {
            string memory tokenKey = string(abi.encodePacked("rewardTokens.", vm.toString(i), ".token"));
            if (!configData.keyExists(tokenKey)) {
                break;
            }
            i++;
        }
        return i;
    }

    /**
     * @notice Get a reward token configuration
     * @param index The index of the reward token
     * @return token The token name
     * @return priceFeed The price feed name
     * @return reverse Whether the price feed is reversed
     * @return heartbeat The heartbeat duration
     */
    function getRewardToken(uint256 index)
        public
        view
        returns (string memory token, string memory priceFeed, bool reverse, uint256 heartbeat)
    {
        string memory baseKey = string(abi.encodePacked("rewardTokens.", vm.toString(index)));

        token = configData.readString(string(abi.encodePacked(baseKey, ".token")));
        priceFeed = configData.readString(string(abi.encodePacked(baseKey, ".priceFeed")));
        reverse = configData.readBool(string(abi.encodePacked(baseKey, ".reverse")));
        heartbeat = configData.readUint(string(abi.encodePacked(baseKey, ".heartbeat")));
    }

    /**
     * @notice Load configuration from the JSON file
     */
    function _loadConfig(string memory configPath) private {
        configData = vm.readFile(configPath);

        bytes memory parsedJson = vm.parseJson(configData);

        config = abi.decode(parsedJson, (DeploymentConfig));

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
