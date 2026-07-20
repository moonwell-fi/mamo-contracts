// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title DeployLeveragedAeroAccountConfig
 * @notice Loader for the {MamoLeveragedAeroStrategy} account-system deployment config.
 * @dev Modeled on {DeployAssetConfig} but deliberately minimal: the leveraged-Aero account has NO
 *      Moonwell/Morpho market split, NO CowSwap reward path, and therefore NO
 *      moonwellMarket/metamorphoVault/rewardTokens/priceFeeds. The config carries only what the
 *      implementation + factory constructors need, plus the strategy type id.
 *
 *      Every non-numeric value is an ADDRESS-BOOK KEY (resolved through FPS `Addresses`), not a literal
 *      address — matching repo convention. Two of those keys ({sherwoodStrategy}, {syndicateVault}) do
 *      NOT exist in `addresses/8453.json` yet: the Sherwood system (SyndicateVault +
 *      LeveragedAerodromeCLStrategy) is deployed separately (Tenderly vnet first, Base mainnet after),
 *      and its addresses are added under those keys at that time.
 */
contract DeployLeveragedAeroAccountConfig is Test {
    using stdJson for string;

    /// @notice Raw JSON contents, kept for ad-hoc getters.
    string private configData;

    /// @notice Parsed configuration.
    Config private config;

    struct Config {
        // Address-book key of the deposit/payout token (USDC).
        string token;
        // Address-book key of the vendored Sherwood leveraged Aerodrome CL strategy.
        string sherwoodStrategy;
        // Address-book key of the SyndicateVault whose deposits must be opened.
        string syndicateVault;
        // MamoStrategyRegistry strategy type id assigned to this account family.
        //
        // Next available MamoStrategyRegistry strategy type id. Base mainnet currently has ids 1-4
        // whitelisted (1=USDC, 2=staking, 3=cbBTC, 4=WETH), so 5 is the first free slot. VERIFY ON-CHAIN
        // before deploy: `cast call $MAMO_STRATEGY_REGISTRY 'latestImplementationById(uint256)(address)' 5
        // --rpc-url base` MUST return the zero address. NOTE: registry.nextStrategyTypeId() reads 4 (stale)
        // because whitelistImplementation with an explicit non-zero id does NOT advance that counter - the
        // empty-slot check above is the source of truth for availability, not nextStrategyTypeId().
        uint256 strategyTypeId;
        // Address-book key under which the deployed implementation is stored.
        string strategyImplementation;
        // Address-book key under which the deployed factory is stored.
        string strategyFactory;
    }

    constructor(string memory _configPath) {
        _loadConfig(_configPath);
    }

    /// @notice Get the full deployment configuration.
    function getConfig() public view returns (Config memory) {
        return config;
    }

    function _loadConfig(string memory configPath) private {
        configData = vm.readFile(configPath);

        // Field-by-field decode (avoids whole-struct abi.decode ordering pitfalls).
        config.token = abi.decode(vm.parseJson(configData, ".token"), (string));
        config.sherwoodStrategy = abi.decode(vm.parseJson(configData, ".sherwoodStrategy"), (string));
        config.syndicateVault = abi.decode(vm.parseJson(configData, ".syndicateVault"), (string));
        config.strategyTypeId = abi.decode(vm.parseJson(configData, ".strategyTypeId"), (uint256));
        config.strategyImplementation = abi.decode(vm.parseJson(configData, ".strategyImplementation"), (string));
        config.strategyFactory = abi.decode(vm.parseJson(configData, ".strategyFactory"), (string));
    }
}
