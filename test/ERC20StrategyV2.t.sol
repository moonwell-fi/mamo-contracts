// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {WhitelistNewStrategyImplementation} from "../multisig/mamo-multisig/009_WhitelistNewStrategyImplementation.sol";

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";

import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC20StrategyV2Test is BaseTest {
    address public owner;
    address public backend;
    ERC1967Proxy public usdcStrategyProxy;
    ERC1967Proxy public cbbtcStrategyProxy;
    ERC20MoonwellMorphoStrategy public usdcStrategy;
    ERC20MoonwellMorphoStrategy public cbbtcStrategy;
    ERC20MoonwellMorphoStrategy public newImplementation;
    MamoStrategyRegistry public registry;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork({urlOrAlias: "base", blockNumber: 36224833});

        // create account with old implementation
        string memory usdcFactoryName = "USDC_STRATEGY_FACTORY_DEPRECATED";
        string memory cbbtcFactoryName = "cbBTC_STRATEGY_FACTORY_DEPRECATED";
        StrategyFactory usdcFactory = StrategyFactory(payable(addresses.getAddress(usdcFactoryName)));
        StrategyFactory cbbtcFactory = StrategyFactory(payable(addresses.getAddress(cbbtcFactoryName)));

        owner = makeAddr("owner");
        backend = addresses.getAddress("STRATEGY_MULTICALL");

        vm.startPrank(owner);
        usdcStrategyProxy = ERC1967Proxy(payable(usdcFactory.createStrategyForUser(owner)));
        cbbtcStrategyProxy = ERC1967Proxy(payable(cbbtcFactory.createStrategyForUser(owner)));
        usdcStrategy = ERC20MoonwellMorphoStrategy(payable(address(usdcStrategyProxy)));
        cbbtcStrategy = ERC20MoonwellMorphoStrategy(payable(address(cbbtcStrategyProxy)));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 minutes);

        assertEq(
            usdcStrategyProxy.getImplementation(), addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL_DEPRECATED")
        );
        assertEq(
            cbbtcStrategyProxy.getImplementation(), addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL_DEPRECATED")
        );

        WhitelistNewStrategyImplementation whitelistNewStrategyImplementation = new WhitelistNewStrategyImplementation();
        whitelistNewStrategyImplementation.setAddresses(addresses);
        whitelistNewStrategyImplementation.deploy();
        whitelistNewStrategyImplementation.build();
        whitelistNewStrategyImplementation.simulate();
        whitelistNewStrategyImplementation.validate();

        newImplementation = ERC20MoonwellMorphoStrategy(payable(addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL")));

        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
    }

    function testUpgrade() public {
        vm.startPrank(owner);
        registry.upgradeStrategy(address(usdcStrategyProxy), address(newImplementation));
        registry.upgradeStrategy(address(cbbtcStrategyProxy), address(newImplementation));
        vm.stopPrank();

        assertEq(usdcStrategyProxy.getImplementation(), address(newImplementation), "Implementation should be upgraded");
        assertEq(
            cbbtcStrategyProxy.getImplementation(), address(newImplementation), "Implementation should be upgraded"
        );
    }

    function testBackendCanClaimRewards() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);

        address merkleDistributor = addresses.getAddress("MERKLE_PROTOCOL_DISTRIBUTOR");

        vm.mockCall(
            merkleDistributor,
            abi.encodeWithSignature("claim(address[],address[],uint256[],bytes32[][])"),
            abi.encode(true)
        );

        vm.expectCall(merkleDistributor, abi.encodeWithSignature("claim(address[],address[],uint256[],bytes32[][])"));
        vm.expectEmit(true, true, true, true);
        emit ERC20MoonwellMorphoStrategy.RewardsClaimed(rewardTokens, rewardAmounts);

        vm.startPrank(backend);
        usdcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        cbbtcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.stopPrank();
    }

    function test_RevertIfNotBackend() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);

        vm.startPrank(makeAddr("not_backend"));

        vm.expectRevert("Not backend");
        usdcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);

        vm.expectRevert("Not backend");
        cbbtcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.stopPrank();
    }

    function test_RevertIfRewardTokensAndAmountsLengthMismatch() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        rewardTokens[1] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);
        proofs[1] = new bytes32[](1);
        proofs[1][0] = bytes32(0);

        vm.startPrank(backend);

        vm.expectRevert("Reward tokens and amounts length mismatch");
        usdcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);

        vm.expectRevert("Reward tokens and amounts length mismatch");
        cbbtcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.stopPrank();
    }

    function test_RevertIfRewardTokensAndProofsLengthMismatch() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        rewardTokens[1] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](2);
        rewardAmounts[0] = 1000000000000000000;
        rewardAmounts[1] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);

        vm.startPrank(backend);

        vm.expectRevert("Reward tokens and proofs length mismatch");
        usdcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.expectRevert("Reward tokens and proofs length mismatch");
        cbbtcStrategy.claimRewards(rewardTokens, rewardAmounts, proofs);

        vm.stopPrank();
    }

    function test_FactoryCanCreateStrategy() public {
        string memory usdcFactoryName = "USDC_STRATEGY_FACTORY";
        string memory cbbtcFactoryName = "cbBTC_STRATEGY_FACTORY";
        StrategyFactory usdcFactory = StrategyFactory(payable(addresses.getAddress(usdcFactoryName)));
        StrategyFactory cbbtcFactory = StrategyFactory(payable(addresses.getAddress(cbbtcFactoryName)));

        vm.startPrank(owner);
        usdcFactory.createStrategyForUser(owner);
        cbbtcFactory.createStrategyForUser(owner);
        vm.stopPrank();
    }
}
