// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";
import {LPCompoundModule} from "@contracts/LPCompoundModule.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {DeployLPAutoBalancerV2Pair} from "@script/DeployLPAutoBalancerV2Pair.s.sol";
import {LPPairConfig} from "@script/LPPairConfig.sol";

import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployLPAutoBalancerV2PairTest
 * @notice EOA-admin TEST deployment of one pair, wired exactly like the live WETH/cbBTC test pair
 *         (MAMO_LP_AUTO_BALANCER_V2_WETH_CBBTC): every module/guard value is read from that deployment.
 *
 * @dev Registers under `<pair name>_TEST`, never the plain pair name: proposal 022 deploys the F-MAMO
 *      balancer under MAMO_LP_AUTO_BALANCER_V2_WETH_CBBTC_V3_CL10 and reverts if that name is taken.
 *
 *      Step 1, `run()`, any funded key: CREATEs + wiring with the deployer as temporary admin, then
 *      DEFAULT_ADMIN_ROLE moves to LP_ADMIN and the deployer renounces.
 *      Step 2, `register(uint256)`, as LP_ADMIN holding the minted NFT: deposit + registerPosition.
 *
 *      approveCowSwap is not called: the checker must list the emission token first, and AERO_V3 is
 *      not listed yet (same deferral as 022).
 *
 *      Env:
 *        LP_PAIR        optional — LPPairConfig key, defaults to WETH_CBBTC_V3_CL10
 *        LP_ADMIN       optional — final DEFAULT_ADMIN_ROLE (owner); defaults to LUKE
 *        LP_GUARDIAN    optional — defaults to LP_ADMIN
 *        LP_REBALANCER  optional — backend signer (REBALANCER_ROLE); defaults to MAMO_LP_REBALANCER
 */
contract DeployLPAutoBalancerV2PairTest is DeployLPAutoBalancerV2Pair {
    using LPPairConfig for LPPairConfig.Pair;

    string public constant REFERENCE_BALANCER = "MAMO_LP_AUTO_BALANCER_V2_WETH_CBBTC";
    string public constant REFERENCE_MODULE = "MAMO_LP_COMPOUND_MODULE_WETH_CBBTC";

    function run() public override returns (LPAutoBalancerV2 lab, LPCompoundModule module) {
        Addresses addresses = _addresses();
        LPPairConfig.Pair memory pair = _pair(addresses);

        address admin = vm.envOr("LP_ADMIN", addresses.getAddress("LUKE"));
        require(admin != address(0), "LP_ADMIN must be set");
        address guardian = vm.envOr("LP_GUARDIAN", admin);
        address rebalancer = vm.envOr("LP_REBALANCER", addresses.getAddress("MAMO_LP_REBALANCER"));

        _assertPairMatchesChain(pair);
        require(!addresses.isAddressSet(_balancerName(pair)), string.concat(_balancerName(pair), " already deployed"));
        (address nfpm, address aero) = _venue(addresses, pair);

        LPAutoBalancerV2 ref = LPAutoBalancerV2(payable(addresses.getAddress(REFERENCE_BALANCER)));
        LPCompoundModule refModule = LPCompoundModule(addresses.getAddress(REFERENCE_MODULE));
        address sequencer = ref.sequencerUptimeFeed();
        uint256 grace = ref.sequencerGracePeriod();
        uint256 delay0 = ref.maxOracleDelay0();
        uint256 delay1 = ref.maxOracleDelay1();
        uint16 swapLoss = ref.swapLossAllowanceBps();
        address checker = address(refModule.slippagePriceChecker());
        uint256 compoundSlippage = refModule.allowedSlippageInBps();
        uint256 rebalanceSlippage = refModule.rebalanceSlippageBps();
        bytes32 appData = refModule.compoundAppData();

        vm.startBroadcast();
        address deployer = msg.sender;
        lab = new LPAutoBalancerV2(deployer, address(0), rebalancer, guardian, nfpm, aero);
        module = new LPCompoundModule(address(lab), aero, deployer);

        lab.setSequencerUptimeFeed(sequencer, grace);
        lab.setMaxOracleDelays(delay0, delay1);
        lab.setSwapLossAllowanceBps(swapLoss);
        lab.setCompoundModule(address(module));
        module.setSlippagePriceChecker(checker);
        module.setSlippage(compoundSlippage);
        module.setRebalanceSlippageBps(rebalanceSlippage);
        module.setCompoundAppData(appData);

        if (admin != deployer) {
            bytes32 adminRole = lab.DEFAULT_ADMIN_ROLE();
            lab.grantRole(adminRole, admin);
            module.grantRole(adminRole, admin);
            lab.renounceRole(adminRole, deployer);
            module.renounceRole(adminRole, deployer);
        }
        vm.stopBroadcast();

        require(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), admin), "admin not granted on balancer");
        require(module.hasRole(module.DEFAULT_ADMIN_ROLE(), admin), "admin not granted on module");
        require(admin == deployer || !lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), deployer), "deployer still balancer admin");
        require(
            admin == deployer || !module.hasRole(module.DEFAULT_ADMIN_ROLE(), deployer), "deployer still module admin"
        );
        require(lab.hasRole(lab.GUARDIAN_ROLE(), guardian), "guardian not granted");
        require(rebalancer == address(0) || lab.hasRole(lab.REBALANCER_ROLE(), rebalancer), "rebalancer not granted");
        require(lab.sequencerUptimeFeed() == sequencer && lab.sequencerGracePeriod() == grace, "sequencer guard");
        require(lab.maxOracleDelay0() == delay0 && lab.maxOracleDelay1() == delay1, "oracle delays");
        require(lab.swapLossAllowanceBps() == swapLoss, "swap loss allowance");
        require(lab.compoundModule() == address(module) && module.balancer() == address(lab), "module not wired");
        require(address(module.slippagePriceChecker()) == checker, "checker");
        require(module.allowedSlippageInBps() == compoundSlippage, "compound slippage");
        require(module.rebalanceSlippageBps() == rebalanceSlippage, "rebalance slippage");
        require(module.compoundAppData() == appData, "appData");

        addresses.addAddress(_balancerName(pair), address(lab), true);
        addresses.addAddress(_moduleName(pair), address(module), true);
        addresses.updateJson();
        addresses.printJSONChanges();

        console.log("=== TEST pair deployment (EOA admin) ===");
        console.log("  pair             :", pair.key);
        console.log("  LPAutoBalancerV2 :", address(lab));
        console.log("  LPCompoundModule :", address(module));
        console.log("  admin / guardian :", admin, guardian);
        console.log("  rebalancer       :", rebalancer);
        console.log("  NEXT: mint the NFT to the admin, then run register(tokenId) as the admin.");
    }

    /// @notice Deposit `tokenId` from the broadcaster (the admin) and register it with the pair envelope.
    function register(uint256 tokenId) public {
        Addresses addresses = _addresses();
        LPPairConfig.Pair memory pair = _pair(addresses);
        LPAutoBalancerV2 lab = LPAutoBalancerV2(payable(addresses.getAddress(_balancerName(pair))));
        INonfungiblePositionManager nfpm = lab.POSITION_MANAGER();

        (,, address t0, address t1, int24 ts,,, uint128 liq,,,,) = nfpm.positions(tokenId);
        require(t0 == pair.token0 && t1 == pair.token1 && ts == pair.tickSpacing, "tokenId is not this pool's position");
        require(liq > 0, "tokenId has no liquidity");

        LPAutoBalancerV2.ManagedPositionV2 memory c;
        c.mainTokenId = tokenId;
        c.pool = pair.pool;
        c.token0 = pair.token0;
        c.token1 = pair.token1;
        c.tickSpacing = pair.tickSpacing;
        c.gauge = pair.gauge;
        c.feeCollector = address(lab);
        c.oracle0 = pair.oracle0;
        c.oracle1 = pair.oracle1;
        c.minWidth = pair.minWidth;
        c.maxWidth = pair.maxWidth;
        c.maxCenterDeviation = pair.maxCenterDeviation;
        c.twapWindow = pair.twapWindow;
        c.maxTickDeviation = pair.maxTickDeviation;
        c.maxRebalanceLossBps = pair.maxRebalanceLossBps;
        c.minRebalanceInterval = pair.minRebalanceInterval;

        vm.startBroadcast();
        address admin = msg.sender;
        require(nfpm.ownerOf(tokenId) == admin, "broadcaster does not hold tokenId");
        require(lab.hasRole(lab.DEFAULT_ADMIN_ROLE(), admin), "broadcaster is not the balancer admin");
        nfpm.safeTransferFrom(admin, address(lab), tokenId);
        lab.registerPosition(c);
        vm.stopBroadcast();

        (uint256 mainTokenId,,,,,,,,,,,,,,,,,,,, bool active) = lab.position();
        require(active && mainTokenId == tokenId, "position not registered");
        console.log("Registered tokenId", tokenId, "on", address(lab));
        console.log("NEXT: the rebalancer calls stake().");
    }

    function _addresses() internal returns (Addresses addresses) {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }

    function _pair(Addresses addresses) internal view returns (LPPairConfig.Pair memory) {
        return LPPairConfig.byKey(addresses, vm.envOr("LP_PAIR", string("WETH_CBBTC_V3_CL10")));
    }

    function _balancerName(LPPairConfig.Pair memory pair) internal pure returns (string memory) {
        return string.concat(pair.balancerName(), "_TEST");
    }

    function _moduleName(LPPairConfig.Pair memory pair) internal pure returns (string memory) {
        return string.concat(pair.moduleName(), "_TEST");
    }
}
