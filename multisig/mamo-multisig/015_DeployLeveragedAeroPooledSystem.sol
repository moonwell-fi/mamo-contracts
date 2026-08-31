// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";
import {BaseStrategy} from "@contracts/leveraged-aero/BaseStrategy.sol";
import {LeveragedAerodromeCLStrategy} from "@contracts/leveraged-aero/LeveragedAerodromeCLStrategy.sol";
import {IStrategy} from "@contracts/leveraged-aero/interfaces/IStrategy.sol";

import {DeployLeveragedAeroPoolConfig} from "@script/DeployLeveragedAeroPoolConfig.sol";
import {LeveragedAeroPoolDeployer} from "@script/LeveragedAeroPoolDeployer.s.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployLeveragedAeroPooledSystem
 * @notice Multisig proposal that deploys and activates the leveraged-Aero POOLED layer — the layer
 *         proposal 012's account system sits on top of:
 *           - deploys the {LeveragedAerodromeCLStrategy} clone TEMPLATE and the {LeveragedAeroVault}
 *             (owner = MAMO_MULTISIG, asset = USDC);
 *           - as the multisig: approves the seed, `cloneAndBind`s a fresh strategy clone against the
 *             whole venue book from `config/strategies/LeveragedAeroPoolConfig.json`, sets the fund
 *             capacity ceiling, and `activateStrategy`s it (Pending → Executed) with that seed.
 *
 * @dev RUN THIS BEFORE 012. 012 resolves `LEVERAGED_AERO_VAULT` and `LEVERAGED_AERO_STRATEGY`; both
 *      keys are written here (the vault in {deploy}, the clone in {simulate}, since the clone address
 *      is only known once the multisig's `cloneAndBind` has executed).
 *
 *      ORDERING INSIDE {build} IS LOAD-BEARING. `cloneAndBind` must precede `activateStrategy` — the
 *      latter reverts "LAV: strategy not set" otherwise — and the USDC approval must precede
 *      `activateStrategy`, which pulls the seed from the CALLER (`safeTransferFrom(msg.sender, ...)`),
 *      so the multisig approves the VAULT, not the strategy. `setMaxTotalAssets` is placed between the
 *      bind and the activation so the ceiling is in force from the first block the strategy exists;
 *      the seed itself is not subject to it (the cap is checked in the strategy's `deposit`, and the
 *      seed goes in through `activateStrategy`).
 *
 *      TBD-D4 — `maxTotalAssets` (currently 250,000 USDC in the config) is a PLACEHOLDER pending the
 *      product capacity decision. It is a required config field on purpose: the alternative default is
 *      `0`, which the vault reads as UNLIMITED, and shipping an accidental unlimited cap is the worse
 *      failure. `setMaxTotalAssets` is `onlyOwner` and takes effect on the next deposit, so revising it
 *      later is a single multisig call, not a redeploy.
 *
 *      ASSET-MODE PIN: the launch book is the cbBTC/USDC CL pool at tickSpacing 100 with leg B == USDC,
 *      i.e. one borrowed leg. `LeveragedAeroVenue.applyVenue` derives that shape from `legB == token`
 *      and then REQUIRES `mLegB == mToken`, `legBFeed == tokenFeed` and `legBSwapTickSpacing == 0`, so
 *      a book that is asset-mode in the config but not in the venue reverts `VenueMismatch` inside
 *      `cloneAndBind` rather than half-wiring a live fund. {validate} re-asserts all three.
 *
 *      DEPOSITS STAY CLOSED HERE. `depositsOpen` is false at construction and 012 is what opens it, so
 *      between the two executions the fund holds only the multisig's seed and can take no third-party
 *      capital. Exits (`strategyBurn`) are never gated on that flag.
 */
contract DeployLeveragedAeroPooledSystem is MultisigProposal {
    DeployLeveragedAeroPoolConfig public immutable deployConfig;
    LeveragedAeroPoolDeployer public immutable poolDeployer;

    string public templateKey;
    string public strategyKey;
    string public vaultKey;

    constructor() {
        deployConfig = new DeployLeveragedAeroPoolConfig("./config/strategies/LeveragedAeroPoolConfig.json");
        vm.makePersistent(address(deployConfig));

        poolDeployer = new LeveragedAeroPoolDeployer();
        vm.makePersistent(address(poolDeployer));

        DeployLeveragedAeroPoolConfig.Config memory cfg = deployConfig.getConfig();
        templateKey = cfg.strategyTemplate;
        strategyKey = cfg.strategy;
        vaultKey = cfg.vault;
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "015_DeployLeveragedAeroPooledSystem";
    }

    function description() public pure override returns (string memory) {
        return
        "Deploy the LeveragedAerodromeCLStrategy template and the LeveragedAeroVault, clone+bind a strategy against the cbBTC/USDC asset-mode venue book, set the fund capacity ceiling, and activate it with the seed";
    }

    function deploy() public override {
        address deployer = addresses.getAddress("DEPLOYER_EOA");
        poolDeployer.deployTemplateAndVault(addresses, deployConfig.getConfig(), deployer);
    }

    function preBuildMock() public override {
        DeployLeveragedAeroPoolConfig.Config memory cfg = deployConfig.getConfig();
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        LeveragedAeroVault vault = LeveragedAeroVault(addresses.getAddress(vaultKey));

        // The vault's strategy pointer is SET-ONCE (`cloneAndBind` is the only writer and `_bind`
        // requires `strategy == address(0)`), so a vault that is already bound makes this proposal
        // unexecutable. Assert it here rather than discovering it as a revert inside `simulate`.
        assertEq(vault.strategy(), address(0), "Vault already has a strategy bound");
        assertEq(vault.owner(), multisig, "Vault owner should be MAMO_MULTISIG");
        assertEq(vault.asset(), addresses.getAddress(cfg.token), "Vault asset should be the configured token");
        assertFalse(vault.depositsOpen(), "Deposits should still be closed (012 opens them)");

        // The template must be permanently locked against `initialize`: its constructor sets
        // `_initialized`, and clones — which skip constructors — are what stay initializable. A template
        // deployed some other way (e.g. cloned itself) would let someone else's init win the race.
        // Resolve BEFORE arming the cheatcode: `getAddress` is itself an external call and would
        // consume the expectation.
        address template = addresses.getAddress(templateKey);
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        IStrategy(template).initialize(address(this), address(this), "");

        // Fund the seed for SIMULATION only: on mainnet the multisig genuinely holds the USDC, and this
        // `deal` is a no-op there in the sense that it overwrites a balance that is already sufficient.
        IERC20 token = IERC20(addresses.getAddress(cfg.token));
        if (token.balanceOf(multisig) < cfg.seed) deal(address(token), multisig, cfg.seed);
        assertGe(token.balanceOf(multisig), cfg.seed, "Multisig should hold at least the seed");
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        DeployLeveragedAeroPoolConfig.Config memory cfg = deployConfig.getConfig();
        LeveragedAeroVault vault = LeveragedAeroVault(addresses.getAddress(vaultKey));

        // 1. Approve the seed to the VAULT: `activateStrategy` pulls it from the caller.
        IERC20(addresses.getAddress(cfg.token)).approve(address(vault), cfg.seed);

        // 2. Clone the template, initialize it against this vault with the venue book, and bind it —
        //    one atomic call, so no third party can initialize the clone in between.
        vault.cloneAndBind(addresses.getAddress(templateKey), addresses.getAddress(cfg.rebalancer), _initData());

        // 3. Capacity ceiling before any deposit is possible (see the contract NatSpec).
        vault.setMaxTotalAssets(cfg.maxTotalAssets);

        // 4. Seed + Pending -> Executed, minting the multisig the genesis shares backing the seed.
        vault.activateStrategy(cfg.seed);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        _simulateActions(multisig);

        // The clone address only exists once `cloneAndBind` has actually executed, so this is the
        // earliest point the key can be written. 012 resolves it under exactly this key.
        address clone = LeveragedAeroVault(addresses.getAddress(vaultKey)).strategy();
        if (addresses.isAddressSet(strategyKey)) {
            addresses.changeAddress(strategyKey, clone, true);
        } else {
            addresses.addAddress(strategyKey, clone, true);
        }
    }

    function validate() public view override {
        LeveragedAeroVault vault = LeveragedAeroVault(addresses.getAddress(vaultKey));
        address clone = addresses.getAddress(strategyKey);

        // Vault <-> clone binding, both directions, plus the unit of account.
        assertEq(vault.strategy(), clone, "Vault should be bound to the deployed clone");
        assertEq(IStrategy(clone).vault(), address(vault), "Clone should point back at the vault");
        assertEq(vault.owner(), addresses.getAddress("MAMO_MULTISIG"), "Vault owner should be MAMO_MULTISIG");

        // Genesis state: Executed, seeded, and the seeder holds the genesis shares.
        this.validateGenesis(vault, clone);

        // Every `InitParams` field, read back off the clone's own storage. Split into `this.` external
        // views so via_ir compiles each in its own frame — `layout()` returns a 48-field struct and
        // inlining all of these into `validate()` overflows the stack.
        this.validateVenue(clone);
        this.validateRiskAndRange(clone);
    }

    /// @dev Lifecycle + share-ledger post-conditions of `activateStrategy`.
    function validateGenesis(LeveragedAeroVault vault, address clone) public view {
        DeployLeveragedAeroPoolConfig.Config memory cfg = deployConfig.getConfig();
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        assertEq(
            uint256(LeveragedAerodromeCLStrategy(payable(clone)).state()),
            uint256(BaseStrategy.State.Executed),
            "Clone should be Executed"
        );
        assertEq(IStrategy(clone).proposer(), addresses.getAddress(cfg.rebalancer), "Proposer should be the rebalancer");
        assertEq(vault.maxTotalAssets(), cfg.maxTotalAssets, "Capacity ceiling mismatch");
        assertFalse(vault.depositsOpen(), "Deposits should still be closed (012 opens them)");

        // Genesis shares: `seed * 10 ** (vault.decimals() - assetDecimals)`, i.e. seed * 1e6 for USDC.
        uint256 genesisShares = cfg.seed * 1e6;
        assertEq(vault.totalSupply(), genesisShares, "Total supply should be the genesis shares");
        assertEq(vault.balanceOf(multisig), genesisShares, "Multisig should hold the genesis shares");

        // The seed is now a levered book, so NAV is a priced quantity rather than the seed exactly.
        // Bound it to +/-2% of the seed: anything outside that means the venue mis-priced or the
        // deployment leaked capital, not that the LP drifted.
        uint256 nav = LeveragedAerodromeCLStrategy(payable(clone)).nav();
        assertGe(nav, (cfg.seed * 98) / 100, "NAV should be within 2% below the seed");
        assertLe(nav, (cfg.seed * 102) / 100, "NAV should be within 2% above the seed");
    }

    /// @dev Token / venue / feed wiring, plus the three asset-mode pins.
    function validateVenue(address clone) public view {
        DeployLeveragedAeroPoolConfig.Config memory cfg = deployConfig.getConfig();
        LeveragedAerodromeCLStrategy.LayoutView memory v = LeveragedAerodromeCLStrategy(payable(clone)).layout();

        assertEq(v.usdc, addresses.getAddress(cfg.token), "layout.usdc");
        assertEq(v.mUsdc, addresses.getAddress(cfg.mToken), "layout.mUsdc");
        assertEq(v.comptroller, addresses.getAddress(cfg.comptroller), "layout.comptroller");
        // The strategy's `weth*` slot is leg A, its `cbBTC*` slot is leg B (historical member names).
        assertEq(v.weth, addresses.getAddress(cfg.legA), "layout.weth == legA");
        assertEq(v.cbBTC, addresses.getAddress(cfg.legB), "layout.cbBTC == legB");
        assertEq(v.mWeth, addresses.getAddress(cfg.mLegA), "layout.mWeth == mLegA");
        assertEq(v.mCbBTC, addresses.getAddress(cfg.mLegB), "layout.mCbBTC == mLegB");
        assertEq(v.pool, addresses.getAddress(cfg.pool), "layout.pool");
        assertEq(v.gauge, addresses.getAddress(cfg.gauge), "layout.gauge");
        assertEq(v.npm, addresses.getAddress(cfg.npm), "layout.npm");
        assertEq(v.swapRouter, addresses.getAddress(cfg.swapRouter), "layout.swapRouter");
        assertEq(v.wethFeed, addresses.getAddress(cfg.legAFeed), "layout.wethFeed == legAFeed");
        assertEq(v.cbBTCFeed, addresses.getAddress(cfg.legBFeed), "layout.cbBTCFeed == legBFeed");
        assertEq(v.usdcFeed, addresses.getAddress(cfg.tokenFeed), "layout.usdcFeed == tokenFeed");
        assertEq(v.aeroUsdFeed, addresses.getAddress(cfg.aeroUsdFeed), "layout.aeroUsdFeed");
        assertEq(v.sequencerFeed, addresses.getAddress(cfg.sequencerFeed), "layout.sequencerFeed");

        // ASSET MODE, derived by the strategy and pinned by the venue checks — assert all four so a
        // config that only looks asset-mode cannot pass.
        assertTrue(v.legBIsAsset, "layout.legBIsAsset should be true (asset mode)");
        assertEq(v.cbBTC, v.usdc, "asset mode: leg B is the unit of account");
        assertEq(v.mCbBTC, v.mUsdc, "asset mode: leg B market is the collateral market");
        assertEq(v.cbBTCFeed, v.usdcFeed, "asset mode: leg B feed is the asset feed");

        assertEq(int256(v.tickSpacing), int256(cfg.tickSpacing), "layout.tickSpacing");
        assertEq(int256(v.wethSwapTickSpacing), int256(cfg.legASwapTickSpacing), "layout.wethSwapTickSpacing");
        assertEq(int256(v.cbBTCSwapTickSpacing), int256(cfg.legBSwapTickSpacing), "layout.cbBTCSwapTickSpacing");
        assertEq(v.wethDeliversNative, cfg.legADeliversNative, "layout.wethDeliversNative");
    }

    /// @dev Oracle, range, risk and fee params.
    function validateRiskAndRange(address clone) public view {
        DeployLeveragedAeroPoolConfig.Config memory cfg = deployConfig.getConfig();
        LeveragedAerodromeCLStrategy.LayoutView memory v = LeveragedAerodromeCLStrategy(payable(clone)).layout();

        assertEq(v.maxDelay, cfg.maxDelay, "layout.maxDelay");
        assertEq(v.gracePeriod, cfg.gracePeriod, "layout.gracePeriod");
        assertEq(uint256(v.twapWindow), cfg.twapWindow, "layout.twapWindow");
        assertEq(uint256(v.calmDeviationTicks), cfg.calmDeviationTicks, "layout.calmDeviationTicks");

        assertEq(uint256(v.width), cfg.width, "layout.width");
        assertEq(uint256(v.minWidth), cfg.minWidth, "layout.minWidth");
        assertEq(uint256(v.maxWidth), cfg.maxWidth, "layout.maxWidth");
        assertEq(uint256(v.skewBps), cfg.skewBps, "layout.skewBps");
        assertEq(uint256(v.minSkewBps), cfg.minSkewBps, "layout.minSkewBps");
        assertEq(uint256(v.maxSkewBps), cfg.maxSkewBps, "layout.maxSkewBps");

        assertEq(uint256(v.targetLtvBps), cfg.targetLtvBps, "layout.targetLtvBps");
        assertEq(uint256(v.maxLtvBps), cfg.maxLtvBps, "layout.maxLtvBps");
        assertEq(uint256(v.minHealthBps), cfg.minHealthBps, "layout.minHealthBps");
        assertEq(uint256(v.maxSlippageBps), cfg.maxSlippageBps, "layout.maxSlippageBps");

        assertEq(uint256(v.compoundFeeBps), cfg.compoundFeeBps, "layout.compoundFeeBps");
        assertEq(v.feeRecipient, addresses.getAddress(cfg.feeRecipient), "layout.feeRecipient");

        // Read off the live Moonwell market rather than the config: the collateral factor is the
        // ceiling `maxLtvBps` was chosen against, and it can move under governance.
        assertLt(uint256(v.maxLtvBps), uint256(v.usdcCollateralFactorBps), "maxLtvBps must stay under the CF");
        // No position staged for migration, and the genesis mint produced a real LP token.
        assertEq(v.stagedVenueHash, bytes32(0), "no venue staged at genesis");
        assertGt(v.tokenId, 0, "genesis mint should have produced an LP position");
    }

    /// @dev Build `InitParams` field-by-field, sourced from the config + address book. Assignments
    ///      rather than a struct literal: a 33-field literal puts the Yul IR over the
    ///      16-live-variable cliff. Field ORDER is irrelevant here (named assignment) but the struct's
    ///      own declaration order is what the ABI encoding is positional over.
    function _initData() internal view returns (bytes memory) {
        DeployLeveragedAeroPoolConfig.Config memory cfg = deployConfig.getConfig();
        LeveragedAerodromeCLStrategy.InitParams memory p;

        p.usdc = addresses.getAddress(cfg.token);
        p.mUsdc = addresses.getAddress(cfg.mToken);
        p.comptroller = addresses.getAddress(cfg.comptroller);
        p.weth = addresses.getAddress(cfg.legA);
        p.cbBTC = addresses.getAddress(cfg.legB);
        p.mWeth = addresses.getAddress(cfg.mLegA);
        p.mCbBTC = addresses.getAddress(cfg.mLegB);

        p.pool = addresses.getAddress(cfg.pool);
        p.npm = addresses.getAddress(cfg.npm);
        p.gauge = addresses.getAddress(cfg.gauge);
        p.swapRouter = addresses.getAddress(cfg.swapRouter);

        p.wethFeed = addresses.getAddress(cfg.legAFeed);
        p.cbBTCFeed = addresses.getAddress(cfg.legBFeed);
        p.usdcFeed = addresses.getAddress(cfg.tokenFeed);
        p.aeroUsdFeed = addresses.getAddress(cfg.aeroUsdFeed);
        p.sequencerFeed = addresses.getAddress(cfg.sequencerFeed);

        p.maxDelay = cfg.maxDelay;
        p.gracePeriod = cfg.gracePeriod;
        p.calmDeviationTicks = uint16(cfg.calmDeviationTicks);
        p.twapWindow = uint32(cfg.twapWindow);

        p.tickSpacing = int24(int256(cfg.tickSpacing));
        p.wethSwapTickSpacing = int24(int256(cfg.legASwapTickSpacing));
        p.cbBTCSwapTickSpacing = int24(int256(cfg.legBSwapTickSpacing));
        p.wethDeliversNative = cfg.legADeliversNative;

        p.width = uint24(cfg.width);
        p.minWidth = uint24(cfg.minWidth);
        p.maxWidth = uint24(cfg.maxWidth);
        p.skewBps = uint16(cfg.skewBps);
        p.minSkewBps = uint16(cfg.minSkewBps);
        p.maxSkewBps = uint16(cfg.maxSkewBps);

        p.targetLtvBps = uint16(cfg.targetLtvBps);
        p.maxLtvBps = uint16(cfg.maxLtvBps);
        p.minHealthBps = uint16(cfg.minHealthBps);
        p.maxSlippageBps = uint16(cfg.maxSlippageBps);

        p.compoundFeeBps = uint16(cfg.compoundFeeBps);
        p.feeRecipient = addresses.getAddress(cfg.feeRecipient);

        return abi.encode(p);
    }

    function _initializeAddresses() internal {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }
}
