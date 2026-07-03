// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {DeployLPAutoBalancerV2} from "@script/DeployLPAutoBalancerV2.s.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {console} from "forge-std/console.sol";

/// @title LPAutoBalancerV2Setup
/// @notice FPS Safe (F-MAMO) proposal for the WETH/cbBTC phase-1 setup of LPAutoBalancerV2.
///
///         Sequence (all executed atomically by the F-MAMO Safe in `simulate`):
///           1. deploy() — deploy LPAutoBalancerV2 (admin/guardian = F-MAMO, manager/rebalancer =
///              address(0); both are granted later, the rebalancer in this very proposal). Skipped
///              if MAMO_LP_AUTO_BALANCER_V2 is already registered.
///           2. build() — Safe actions, in order:
///                a. NFPM.safeTransferFrom(F-MAMO, balancer, tokenId)  — deposit the pre-minted
///                   WETH/cbBTC Slipstream NFT into the balancer.
///                b. balancer.registerPosition(config)                 — register the phase-1 position.
///                c. balancer.grantRole(REBALANCER_ROLE, rebalancerEOA) — authorize the backend signer.
///              The AERO->drop wiring is intentionally NOT an action here — see the NOTE below.
///
///         PRECONDITION (off-chain Phase B): the WETH/cbBTC Slipstream position NFT must already be
///         minted and held by the F-MAMO Safe BEFORE build() runs. registerPosition reverts with
///         NotHeld unless the balancer owns the NFT, and the transfer action (2a) executes inside
///         build()'s state-diff recording, so by the time registerPosition (2b) runs the balancer
///         already owns it. The production run MUST set the real values via the setters below:
///           - setTokenId(uint256)        — the tokenId the Safe holds (minted in Phase B2).
///           - setRebalancerEOA(address)  — the real backend signer EOA (MAMO_LP_REBALANCER).
///         The fork test injects fork-minted / makeAddr values via the same setters.
///         If MAMO_LP_REBALANCER is registered in addresses/8453.json at run time it is used as the
///         default; otherwise rebalancerEOA MUST be set explicitly or build() reverts.
///
///         NOTE — AERO COMPOUND (SlippagePriceChecker + approveCowSwap): PARTIALLY DEFERRED.
///         deploy() deploys LPCompoundModule (admin = F-MAMO) and build() wires the F-MAMO-doable
///         setters (setCompoundModule, setSlippagePriceChecker, setSlippage, setCompoundAppData).
///         The remaining two steps are a SEPARATE owner tx because the CHAINLINK_SWAP_CHECKER_PROXY
///         owner is NOT F-MAMO:
///           1. checker owner: addTokenConfiguration(AERO->WETH) + addTokenConfiguration(AERO->cbBTC)
///              + setMaxTimePriceValid(AERO, ...) — feeds: CHAINLINK_AERO_USD (fwd) then ETH/USD resp.
///              BTC/USD (reverse). Only after this is AERO a reward token.
///           2. F-MAMO: module.approveCowSwap() — reverts "Token not allowed" until step 1 lands.
///         Until both run, compound() still harvests + drops + forwards AERO to the module; only the
///         CowSwap sell leg is inert (no relayer allowance, orders fail slippage), which is safe.
///
///         NOTE — AERO / DropAutomation: DEFERRED (no on-chain action). DropAutomation has no
///         per-token "swappable reward" whitelist setter. The tokens it swaps are passed per-call as
///         the `swapTokens_` calldata of `createDrop` (AERO is already routed with
///         swapDirectToCbBtc_ = true — see DropAutomation.sol). The only owner-gated config,
///         `addGauge`, is for the case where DropAutomation itself stakes LP; here the balancer stakes
///         the position and skims AERO to the feeCollector (DROP_AUTOMATION), so nothing needs to be
///         whitelisted. AERO swapping is therefore configured off-chain at drop time, not via a Safe
///         action — this is a documented manual follow-up, not a missing on-chain step.
contract LPAutoBalancerV2Setup is MultisigProposal {
    // ─── phase-1 position config (WETH/cbBTC, tickSpacing 100) ──────────────────
    int24 public constant TICK_SPACING = 100;
    uint24 public constant MIN_WIDTH = 200;
    uint24 public constant MAX_WIDTH = 20_000;
    uint24 public constant MAX_CENTER_DEVIATION = 200;
    uint32 public constant TWAP_WINDOW = 1800;
    int24 public constant MAX_TICK_DEVIATION = 100;
    uint16 public constant MAX_REBALANCE_LOSS_BPS = 100;
    uint256 public constant MIN_REBALANCE_INTERVAL = 21_600; // 6h

    // ─── compound module config ─────────────────────────────────────────────────
    /// @notice Conservative 2% default slippage for the AERO->underlying compound swap.
    uint256 public constant COMPOUND_SLIPPAGE_BPS = 200;
    /// @notice Expected CowSwap appData hash for compound orders. Replace with the real hash agreed
    ///         with the off-chain bot before mainnet execution.
    bytes32 public constant COMPOUND_APP_DATA = keccak256("mamo-lpv2-compound");
    /// @notice Extra value-floor tolerance for the CowSwap swap-rebalance round-trip's real-world
    ///         slippage, on top of maxRebalanceLossBps.
    uint16 public constant SWAP_LOSS_ALLOWANCE_BPS = 300;

    /// @notice The pre-minted WETH/cbBTC Slipstream NFT tokenId held by the F-MAMO Safe (Phase B2).
    ///         MUST be set (setTokenId) before build() — there is no sensible default.
    uint256 public tokenId;

    /// @notice The backend signer EOA to be granted REBALANCER_ROLE. If unset, defaults to the
    ///         MAMO_LP_REBALANCER address entry when present; otherwise MUST be set via setRebalancerEOA.
    address public rebalancerEOA;

    function setTokenId(uint256 tokenId_) external {
        tokenId = tokenId_;
    }

    function setRebalancerEOA(address rebalancerEOA_) external {
        rebalancerEOA = rebalancerEOA_;
    }

    function _initializeAddresses() internal {
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.updateJson();
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
        return "011_LPAutoBalancerV2Setup";
    }

    function description() public pure override returns (string memory) {
        return
        "Deploy LPAutoBalancerV2 (if needed), deposit the pre-minted WETH/cbBTC Slipstream NFT into it, register the phase-1 position, and grant REBALANCER_ROLE to the backend signer.";
    }

    function deploy() public override {
        // 1. Balancer (idempotent).
        if (!addresses.isAddressSet("MAMO_LP_AUTO_BALANCER_V2")) {
            // Delegate to the canonical deploy script helper instead of re-implementing the
            // constructor-args assembly + address registration (single source of truth for the
            // balancer's roles/wiring; the script handles the addAddress/changeAddress bookkeeping).
            LPAutoBalancerV2 lab = new DeployLPAutoBalancerV2().deployLPAutoBalancerV2(addresses);
            console.log("LPAutoBalancerV2 deployed at:", address(lab));
        }

        // 2. Compound module (idempotent). Admin == F-MAMO so the Safe can run the setters in build().
        if (!addresses.isAddressSet("MAMO_LP_COMPOUND_MODULE")) {
            LPCompoundModule module = new LPCompoundModule(
                addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2"),
                addresses.getAddress("AERO"),
                addresses.getAddress("F-MAMO")
            );
            addresses.addAddress("MAMO_LP_COMPOUND_MODULE", address(module), true);
            console.log("LPCompoundModule deployed at:", address(module));
        }
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        LPAutoBalancerV2 lab = LPAutoBalancerV2(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2"));

        // Steps 1-3 in a block so the config struct + locals free before _wireModule inlines
        // (keeps build() under the via_ir stack limit — position config has 21 fields).
        {
            address nfpm = addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME");
            address safe = addresses.getAddress("F-MAMO");

            require(tokenId != 0, "tokenId not set: mint the WETH/cbBTC NFT to the Safe and call setTokenId");
            address rebalancer = _resolveRebalancer();

            // 1. Deposit the pre-minted WETH/cbBTC NFT from the Safe into the balancer. This executes
            //    inside build()'s state-diff recording, so the balancer owns the NFT when (2) runs.
            INonfungiblePositionManager(nfpm).safeTransferFrom(safe, address(lab), tokenId);

            // 2. Register the phase-1 position. `altTokenId`, `mainStaked`, `altStaked`, `lastRebalance`,
            //    and `active` are forced by `_store`; the values supplied for them are ignored.
            LPAutoBalancerV2.ManagedPositionV2 memory config = LPAutoBalancerV2.ManagedPositionV2({
                mainTokenId: tokenId,
                altTokenId: 0,
                pool: addresses.getAddress("WETH_CBBTC_CL_POOL"),
                token0: addresses.getAddress("WETH"),
                token1: addresses.getAddress("cbBTC"),
                tickSpacing: TICK_SPACING,
                gauge: addresses.getAddress("WETH_CBBTC_CL_GAUGE"),
                mainStaked: false,
                altStaked: false,
                feeCollector: addresses.getAddress("DROP_AUTOMATION"),
                oracle0: addresses.getAddress("CHAINLINK_ETH_USD"),
                oracle1: addresses.getAddress("CHAINLINK_BTC_USD"),
                minWidth: MIN_WIDTH,
                maxWidth: MAX_WIDTH,
                maxCenterDeviation: MAX_CENTER_DEVIATION,
                twapWindow: TWAP_WINDOW,
                maxTickDeviation: MAX_TICK_DEVIATION,
                maxRebalanceLossBps: MAX_REBALANCE_LOSS_BPS,
                minRebalanceInterval: MIN_REBALANCE_INTERVAL,
                lastRebalance: 0,
                active: false
            });
            lab.registerPosition(config);

            // 3. Grant REBALANCER_ROLE to the backend signer EOA.
            lab.grantRole(lab.REBALANCER_ROLE(), rebalancer);
        }

        // 4. Wire the compound module (isolated helper to keep build() under the via_ir stack limit).
        _wireModule(lab);
    }

    /// @dev Wire the balancer to the compound module and set the F-MAMO-doable compound config.
    ///      approveCowSwap() + the SlippagePriceChecker AERO->WETH/cbBTC config are DEFERRED (see the
    ///      COMPOUND NOTE at the top): the checker owner is NOT F-MAMO, so AERO cannot be whitelisted
    ///      as a reward token here, and approveCowSwap would revert ("Token not allowed").
    function _wireModule(LPAutoBalancerV2 lab) internal {
        LPCompoundModule module = LPCompoundModule(addresses.getAddress("MAMO_LP_COMPOUND_MODULE"));
        lab.setCompoundModule(address(module));
        module.setSlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
        module.setSlippage(COMPOUND_SLIPPAGE_BPS);
        module.setCompoundAppData(COMPOUND_APP_DATA);
        lab.setSwapLossAllowanceBps(SWAP_LOSS_ALLOWANCE_BPS);
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("F-MAMO"));
    }

    function validate() public view override {
        address labAddr = addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2");
        assertTrue(labAddr != address(0), "balancer address set");
        assertTrue(labAddr.code.length > 0, "balancer has code");
        LPAutoBalancerV2 lab = LPAutoBalancerV2(labAddr);

        // Roles: admin = F-MAMO, rebalancer granted.
        address safe = addresses.getAddress("F-MAMO");
        assertTrue(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), safe), "admin is F-MAMO");
        assertTrue(lab.hasRole(lab.GUARDIAN_ROLE(), safe), "guardian is F-MAMO");
        assertTrue(lab.hasRole(lab.REBALANCER_ROLE(), _resolveRebalancer()), "rebalancer granted");

        // Position config + NFT custody, and the compound module wiring — split into `this.` external
        // views so via_ir compiles each in its own frame (position() returns a 21-field tuple; inlining
        // both into validate() overflows the stack).
        this.validatePosition(lab);
        this.validateModule(labAddr, safe);
    }

    /// @dev Assert the registered position matches the phase-1 config and the balancer holds the NFT.
    function validatePosition(LPAutoBalancerV2 lab) public view {
        (
            uint256 mainTokenId,
            ,
            address pool,
            address token0,
            address token1,
            int24 tickSpacing,
            address gauge,
            ,
            ,
            address feeCollector,
            address oracle0,
            address oracle1,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool active
        ) = lab.position();

        assertTrue(active, "position active");
        assertEq(mainTokenId, tokenId, "mainTokenId == tokenId");
        assertEq(pool, addresses.getAddress("WETH_CBBTC_CL_POOL"), "pool");
        assertEq(token0, addresses.getAddress("WETH"), "token0 == WETH");
        assertEq(token1, addresses.getAddress("cbBTC"), "token1 == cbBTC");
        assertEq(int256(tickSpacing), int256(TICK_SPACING), "tickSpacing");
        assertEq(gauge, addresses.getAddress("WETH_CBBTC_CL_GAUGE"), "gauge");
        assertEq(feeCollector, addresses.getAddress("DROP_AUTOMATION"), "feeCollector == DROP_AUTOMATION");
        assertEq(oracle0, addresses.getAddress("CHAINLINK_ETH_USD"), "oracle0 == ETH/USD");
        assertEq(oracle1, addresses.getAddress("CHAINLINK_BTC_USD"), "oracle1 == BTC/USD");

        assertEq(
            INonfungiblePositionManager(addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME")).ownerOf(
                mainTokenId
            ),
            address(lab),
            "balancer owns the WETH/cbBTC NFT"
        );
    }

    /// @dev Assert the compound module was deployed and wired (the F-MAMO-doable portion; the
    ///      checker AERO config + approveCowSwap are the deferred owner tx — see the COMPOUND NOTE).
    function validateModule(address labAddr, address safe) public view {
        address moduleAddr = addresses.getAddress("MAMO_LP_COMPOUND_MODULE");
        assertTrue(moduleAddr != address(0) && moduleAddr.code.length > 0, "module deployed");
        assertEq(LPAutoBalancerV2(labAddr).compoundModule(), moduleAddr, "balancer wired to module");
        LPCompoundModule module = LPCompoundModule(moduleAddr);
        assertEq(module.balancer(), labAddr, "module bound to balancer");
        assertEq(module.AERO(), addresses.getAddress("AERO"), "module AERO");
        assertTrue(module.hasRole(module.DEFAULT_ADMIN_ROLE(), safe), "module admin is F-MAMO");
        assertEq(module.allowedSlippageInBps(), COMPOUND_SLIPPAGE_BPS, "slippage set");
        assertEq(module.compoundAppData(), COMPOUND_APP_DATA, "appData set");
        assertEq(
            address(module.slippagePriceChecker()), addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"), "checker set"
        );
        assertEq(LPAutoBalancerV2(labAddr).swapLossAllowanceBps(), SWAP_LOSS_ALLOWANCE_BPS, "swap loss allowance set");
    }

    /// @dev Resolve the rebalancer EOA: explicit setter wins; else fall back to the
    ///      MAMO_LP_REBALANCER address entry if present.
    function _resolveRebalancer() internal view returns (address) {
        if (rebalancerEOA != address(0)) return rebalancerEOA;
        require(addresses.isAddressSet("MAMO_LP_REBALANCER"), "rebalancerEOA unset and MAMO_LP_REBALANCER missing");
        return addresses.getAddress("MAMO_LP_REBALANCER");
    }
}
