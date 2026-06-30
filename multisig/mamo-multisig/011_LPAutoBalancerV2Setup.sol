// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
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
        return "Deploy LPAutoBalancerV2 (if needed), deposit the pre-minted WETH/cbBTC Slipstream NFT into it, register the phase-1 position, and grant REBALANCER_ROLE to the backend signer.";
    }

    function deploy() public override {
        if (addresses.isAddressSet("MAMO_LP_AUTO_BALANCER_V2")) {
            // Already deployed — nothing to do (idempotent).
            return;
        }

        // Delegate to the canonical deploy script helper instead of re-implementing the
        // constructor-args assembly + address registration (single source of truth for the
        // balancer's roles/wiring; the script handles the addAddress/changeAddress bookkeeping).
        LPAutoBalancerV2 lab = new DeployLPAutoBalancerV2().deployLPAutoBalancerV2(addresses);
        console.log("LPAutoBalancerV2 deployed at:", address(lab));
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        LPAutoBalancerV2 lab = LPAutoBalancerV2(addresses.getAddress("MAMO_LP_AUTO_BALANCER_V2"));
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

        // Position registered and active with the phase-1 config.
        (
            uint256 mainTokenId,,
            address pool,
            address token0,
            address token1,
            int24 tickSpacing,
            address gauge,,,
            address feeCollector,
            address oracle0,
            address oracle1,,,,,,,,,
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

        // The balancer owns the NFT.
        assertEq(
            INonfungiblePositionManager(addresses.getAddress("UNISWAP_V3_POSITION_MANAGER_AERODROME")).ownerOf(tokenId),
            labAddr,
            "balancer owns the WETH/cbBTC NFT"
        );
    }

    /// @dev Resolve the rebalancer EOA: explicit setter wins; else fall back to the
    ///      MAMO_LP_REBALANCER address entry if present.
    function _resolveRebalancer() internal view returns (address) {
        if (rebalancerEOA != address(0)) return rebalancerEOA;
        require(addresses.isAddressSet("MAMO_LP_REBALANCER"), "rebalancerEOA unset and MAMO_LP_REBALANCER missing");
        return addresses.getAddress("MAMO_LP_REBALANCER");
    }
}
