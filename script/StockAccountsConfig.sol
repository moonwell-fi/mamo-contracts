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

    /// @notice Deployment configuration, fields alphabetized to match the JSON
    struct DeploymentConfig {
        string admin;
        string aerodromeRouter;
        string asset;
        string backend;
        uint256 chainId;
        string cowSettlement;
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
        string priceChecker;
        bytes32 requiredAppDataHash;
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
        config.priceChecker = json.readString(".priceChecker");
        config.requiredAppDataHash = json.readBytes32(".requiredAppDataHash");
        config.twapWindow = uint32(json.readUint(".twapWindow"));

        require(config.chainId == block.chainid, "Config chain id does not match the current chain");
    }

    /// @notice The full deployment configuration
    function getConfig() public view returns (DeploymentConfig memory) {
        return config;
    }
}
