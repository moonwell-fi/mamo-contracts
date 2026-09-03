// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title DeployLeveragedAeroPoolConfig
 * @notice Loader for the leveraged-Aero POOLED-layer deployment config: the {LeveragedAeroVault}
 *         constructor args, the whole {LeveragedAerodromeCLStrategy} `InitParams` venue book, and the
 *         two owner-driven lifecycle numbers (`seed`, `maxTotalAssets`).
 * @dev Mirrors {DeployLeveragedAeroAccountConfig}: every non-numeric value is an ADDRESS-BOOK KEY
 *      resolved through FPS `Addresses`, never a literal address, and the decode is field-by-field.
 *
 *      LEG SLOTS, NOT TOKEN IDENTITIES: `legA` is the strategy's `weth`/`mWeth`/`wethFeed` slot (the
 *      natively-wrappable one), `legB` is its `cbBTC*` slot. Those `InitParams` member names are
 *      historical; the config uses the slot names. Ordering (`wethIsToken0`) and both leg decimals are
 *      DERIVED at init from the pool and the tokens, so they are deliberately absent here.
 *
 *      ASSET MODE is expressed, not assumed: the launch book sets `legB == token` (USDC), which makes
 *      `LeveragedAeroVenue.applyVenue` take the `legBIsAsset` branch and REQUIRE `mLegB == mToken`,
 *      `legBFeed == tokenFeed` and `legBSwapTickSpacing == 0`. Keeping those as separate config fields
 *      rather than collapsing them lets 015's `validate()` prove the pin instead of assuming it.
 *
 *      The three grid spacings are declared unsigned and widened to `int24` at use: `applyVenue`
 *      requires `> 0` for a genuinely borrowed leg and exactly `0` for the asset leg, so a negative
 *      value has no meaning on any path.
 */
contract DeployLeveragedAeroPoolConfig is Test {
    using stdJson for string;

    /// @notice Raw JSON contents, kept for ad-hoc getters.
    string private configData;

    /// @notice Parsed configuration.
    Config private config;

    struct Config {
        // ── vault construction ──
        string vaultName;
        string vaultSymbol;
        // ── tokens + Moonwell markets (address-book keys) ──
        string token; // unit of account + collateral asset (USDC, 6dp)
        string mToken; // Moonwell collateral market for `token`
        string comptroller; // Moonwell Comptroller (the unitroller proxy, not the logic contract)
        string legA;
        string legB;
        string mLegA;
        string mLegB;
        // ── venues ──
        string pool;
        string gauge;
        string npm;
        string swapRouter;
        // ── Chainlink feeds (all 8dp; the strategy asserts the decimals at init) ──
        string legAFeed;
        string legBFeed;
        string tokenFeed;
        string aeroUsdFeed;
        string sequencerFeed;
        // ── roles ──
        string rebalancer; // the strategy's `proposer` (operator) role
        string feeRecipient; // receives the in-kind AERO skim
        // ── address-book keys written by the deploy ──
        string strategyTemplate;
        string strategy; // the clone, resolved after the vault binds it
        string vault;
        // ── pool config ──
        uint256 tickSpacing;
        uint256 legASwapTickSpacing;
        uint256 legBSwapTickSpacing;
        bool legADeliversNative;
        // ── oracle config ──
        uint256 maxDelay;
        uint256 gracePeriod;
        uint256 twapWindow;
        uint256 calmDeviationTicks;
        // ── range band ──
        uint256 width;
        uint256 minWidth;
        uint256 maxWidth;
        uint256 skewBps;
        uint256 minSkewBps;
        uint256 maxSkewBps;
        // ── risk params ──
        uint256 targetLtvBps;
        uint256 maxLtvBps;
        uint256 minHealthBps;
        uint256 maxSlippageBps;
        // ── fee ──
        uint256 compoundFeeBps;
        // ── owner-driven lifecycle numbers ──
        uint256 seed; // asset units (6dp) the multisig seeds the strategy with at activation
        uint256 maxTotalAssets; // fund capacity ceiling over the whole book, asset units; 0 == unlimited
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
        _loadKeys();
        _loadParams();
    }

    /// @dev Address-book keys and the two vault strings. Split from {_loadParams} purely to keep each
    ///      function's frame under the via_ir stack limit.
    function _loadKeys() private {
        config.vaultName = abi.decode(vm.parseJson(configData, ".vaultName"), (string));
        config.vaultSymbol = abi.decode(vm.parseJson(configData, ".vaultSymbol"), (string));
        config.token = abi.decode(vm.parseJson(configData, ".token"), (string));
        config.mToken = abi.decode(vm.parseJson(configData, ".mToken"), (string));
        config.comptroller = abi.decode(vm.parseJson(configData, ".comptroller"), (string));
        config.legA = abi.decode(vm.parseJson(configData, ".legA"), (string));
        config.legB = abi.decode(vm.parseJson(configData, ".legB"), (string));
        config.mLegA = abi.decode(vm.parseJson(configData, ".mLegA"), (string));
        config.mLegB = abi.decode(vm.parseJson(configData, ".mLegB"), (string));
        config.pool = abi.decode(vm.parseJson(configData, ".pool"), (string));
        config.gauge = abi.decode(vm.parseJson(configData, ".gauge"), (string));
        config.npm = abi.decode(vm.parseJson(configData, ".npm"), (string));
        config.swapRouter = abi.decode(vm.parseJson(configData, ".swapRouter"), (string));
        config.legAFeed = abi.decode(vm.parseJson(configData, ".legAFeed"), (string));
        config.legBFeed = abi.decode(vm.parseJson(configData, ".legBFeed"), (string));
        config.tokenFeed = abi.decode(vm.parseJson(configData, ".tokenFeed"), (string));
        config.aeroUsdFeed = abi.decode(vm.parseJson(configData, ".aeroUsdFeed"), (string));
        config.sequencerFeed = abi.decode(vm.parseJson(configData, ".sequencerFeed"), (string));
        config.rebalancer = abi.decode(vm.parseJson(configData, ".rebalancer"), (string));
        config.feeRecipient = abi.decode(vm.parseJson(configData, ".feeRecipient"), (string));
        config.strategyTemplate = abi.decode(vm.parseJson(configData, ".strategyTemplate"), (string));
        config.strategy = abi.decode(vm.parseJson(configData, ".strategy"), (string));
        config.vault = abi.decode(vm.parseJson(configData, ".vault"), (string));
    }

    function _loadParams() private {
        config.tickSpacing = abi.decode(vm.parseJson(configData, ".tickSpacing"), (uint256));
        config.legASwapTickSpacing = abi.decode(vm.parseJson(configData, ".legASwapTickSpacing"), (uint256));
        config.legBSwapTickSpacing = abi.decode(vm.parseJson(configData, ".legBSwapTickSpacing"), (uint256));
        config.legADeliversNative = abi.decode(vm.parseJson(configData, ".legADeliversNative"), (bool));
        config.maxDelay = abi.decode(vm.parseJson(configData, ".maxDelay"), (uint256));
        config.gracePeriod = abi.decode(vm.parseJson(configData, ".gracePeriod"), (uint256));
        config.twapWindow = abi.decode(vm.parseJson(configData, ".twapWindow"), (uint256));
        config.calmDeviationTicks = abi.decode(vm.parseJson(configData, ".calmDeviationTicks"), (uint256));
        config.width = abi.decode(vm.parseJson(configData, ".width"), (uint256));
        config.minWidth = abi.decode(vm.parseJson(configData, ".minWidth"), (uint256));
        config.maxWidth = abi.decode(vm.parseJson(configData, ".maxWidth"), (uint256));
        config.skewBps = abi.decode(vm.parseJson(configData, ".skewBps"), (uint256));
        config.minSkewBps = abi.decode(vm.parseJson(configData, ".minSkewBps"), (uint256));
        config.maxSkewBps = abi.decode(vm.parseJson(configData, ".maxSkewBps"), (uint256));
        config.targetLtvBps = abi.decode(vm.parseJson(configData, ".targetLtvBps"), (uint256));
        config.maxLtvBps = abi.decode(vm.parseJson(configData, ".maxLtvBps"), (uint256));
        config.minHealthBps = abi.decode(vm.parseJson(configData, ".minHealthBps"), (uint256));
        config.maxSlippageBps = abi.decode(vm.parseJson(configData, ".maxSlippageBps"), (uint256));
        config.compoundFeeBps = abi.decode(vm.parseJson(configData, ".compoundFeeBps"), (uint256));
        config.seed = abi.decode(vm.parseJson(configData, ".seed"), (uint256));
        config.maxTotalAssets = abi.decode(vm.parseJson(configData, ".maxTotalAssets"), (uint256));
    }
}
