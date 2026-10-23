// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "../BaseTest.t.sol";
import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/v1/ERC20MoonwellMorphoStrategy.sol";
import {StrategyFactory} from "@contracts/v1/StrategyFactory.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Merkl stand-in: pays each account its cumulative amount minus what it already paid
contract MockMerkl {
    mapping(address => mapping(address => uint256)) public paid;

    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata
    ) external {
        for (uint256 i; i < users.length; i++) {
            uint256 owed = amounts[i] - paid[users[i]][tokens[i]];
            paid[users[i]][tokens[i]] = amounts[i];
            IERC20(tokens[i]).transfer(users[i], owed);
        }
    }
}

contract StrategyV1UpgradeTest is BaseTest {
    using GPv2Order for GPv2Order.Data;

    /// @dev Recent block where Moonwell USDC getCash() == 0 (fully borrowed), so any Moonwell redeem reverts
    uint256 internal constant PINNED_BLOCK = 52_946_409;
    /// @dev Live USDC factory StrategyCreated logs (blocks 40M-42M), first with MOONWELL_USDC.balanceOf > 0
    address internal constant FUNDED_PROXY = 0x891a1A6a5838fC4239dE32ae02F00f7a6C60356C;
    address internal constant FUNDED_OWNER = 0x082784c86D4D6E9cA0E19e93da1F78B116bd8307;
    /// @dev Same logs (blocks 52.5M-52.95M), first with no mToken, vault or USDC balance
    address internal constant EMPTY_PROXY = 0x835CcBa42DfDC7E57b2eB015F3B9BA37391e2275;
    address internal constant EMPTY_OWNER = 0xE0539c243946181F8298255e0500380B9579093d;

    MamoStrategyRegistry internal registry;
    StrategyFactory internal liveFactory;
    StrategyFactory internal factory;
    ERC20MoonwellMorphoStrategy internal newImpl;
    IERC20 internal usdc;
    IMToken internal mToken;
    IERC20 internal vault;
    address internal xwell;
    address internal backend;

    function setUp() public override {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);
        super.setUp();

        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        liveFactory = StrategyFactory(addresses.getAddress("USDC_STRATEGY_FACTORY"));
        usdc = IERC20(addresses.getAddress("USDC"));
        mToken = IMToken(addresses.getAddress("MOONWELL_USDC"));
        vault = IERC20(addresses.getAddress("USDC_METAMORPHO_VAULT"));
        xwell = addresses.getAddress("xWELL_PROXY");
        backend = registry.getBackendAddress();
        address multisig = addresses.getAddress("MAMO_MULTISIG");
        assertEq(mToken.getCash(), 0, "pin must sit where Moonwell USDC has no cash");

        newImpl = new ERC20MoonwellMorphoStrategy();
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = xwell;
        rewardTokens[1] = addresses.getAddress("MORPHO");
        factory = new StrategyFactory(
            address(registry),
            liveFactory.mamoBackend(),
            address(mToken),
            address(vault),
            address(usdc),
            liveFactory.slippagePriceChecker(),
            address(newImpl),
            multisig,
            0,
            10_000,
            1,
            liveFactory.hookGasLimit(),
            liveFactory.allowedSlippageInBps(),
            liveFactory.compoundFee(),
            rewardTokens
        );

        vm.startPrank(multisig);
        registry.whitelistImplementation(address(newImpl), 1);
        registry.grantRole(registry.BACKEND_ROLE(), address(factory));
        vm.stopPrank();
    }

    function test_liveFactory_canNoLongerCreate() public {
        address user = makeAddr("user");
        vm.prank(user);
        vm.expectRevert("Not latest implementation");
        liveFactory.createStrategyForUser(user);
    }

    function test_newAccount_vaultOnly_withdrawsAtZeroCash() public {
        address user = makeAddr("user");
        vm.prank(user);
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(factory.createStrategyForUser(user)));

        _deposit(s, user, 1_000e6);
        assertGt(vault.balanceOf(address(s)), 0);
        assertEq(IERC20(address(mToken)).balanceOf(address(s)), 0);

        vm.startPrank(user);
        s.withdraw(500e6);
        s.withdrawAll();
        vm.stopPrank();
        assertEq(vault.balanceOf(address(s)), 0);
        assertApproxEqAbs(usdc.balanceOf(user), 1_000e6, 1);
    }

    function test_fundedLegacyProxy_movesToVault_leavesMTokenInPlace() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        uint256 mBalance = IERC20(address(mToken)).balanceOf(FUNDED_PROXY);
        assertGt(mBalance, 0);

        vm.prank(backend);
        s.updatePosition(0, 10_000);
        assertEq(IERC20(address(mToken)).balanceOf(FUNDED_PROXY), mBalance);
        assertEq(s.splitMToken(), 0);
        assertEq(s.splitVault(), 10_000);

        _deposit(s, FUNDED_OWNER, 100e6);
        assertGt(vault.balanceOf(FUNDED_PROXY), 0);

        vm.startPrank(FUNDED_OWNER);
        s.withdraw(50e6);
        s.withdrawAll();
        vm.stopPrank();
        assertEq(vault.balanceOf(FUNDED_PROXY), 0);
        assertEq(IERC20(address(mToken)).balanceOf(FUNDED_PROXY), mBalance);
        assertApproxEqAbs(usdc.balanceOf(FUNDED_OWNER), 100e6, 1);
    }

    function test_emptyLegacyProxy_updatePositionNoLongerReverts() public {
        vm.prank(backend);
        vm.expectRevert("Nothing to rebalance");
        ERC20MoonwellMorphoStrategy(payable(EMPTY_PROXY)).updatePosition(0, 10_000);

        ERC20MoonwellMorphoStrategy s = _upgrade(EMPTY_PROXY, EMPTY_OWNER);
        vm.prank(backend);
        s.updatePosition(0, 10_000);
        assertEq(s.splitMToken(), 0);
        assertEq(s.splitVault(), 10_000);
    }

    function test_claimRewards_chargesCompoundFeeOnTheClaimDeltaOnly() public {
        address distributor = addresses.getAddress("MERKLE_PROTOCOL_DISTRIBUTOR");
        vm.etch(distributor, type(MockMerkl).runtimeCode);
        deal(xwell, distributor, 1_000e18);

        ERC20MoonwellMorphoStrategy s = _upgrade(EMPTY_PROXY, EMPTY_OWNER);
        deal(xwell, EMPTY_PROXY, 7e18); // pre-existing balance, never charged
        address recipient = s.feeRecipient();

        address[] memory tokens = new address[](1);
        tokens[0] = xwell;
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory fees = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);

        // Cumulative 100 then 150 then 150 again: fee on 100, then 50, then nothing
        uint256[3] memory cumulative = [uint256(100e18), 150e18, 150e18];
        uint256[3] memory paidOut = [uint256(100e18), 50e18, 0];
        for (uint256 i; i < 3; i++) {
            amounts[0] = cumulative[i];
            fees[0] = (paidOut[i] * s.compoundFee()) / 10_000;
            uint256 recipientBefore = IERC20(xwell).balanceOf(recipient);
            uint256 strategyBefore = IERC20(xwell).balanceOf(EMPTY_PROXY);

            vm.expectEmit(EMPTY_PROXY);
            emit ERC20MoonwellMorphoStrategy.CompoundFeeCollected(recipient, tokens, fees);
            vm.prank(backend);
            s.claimRewards(tokens, amounts, proofs);

            assertEq(IERC20(xwell).balanceOf(recipient) - recipientBefore, fees[0]);
            assertEq(IERC20(xwell).balanceOf(EMPTY_PROXY) - strategyBefore, paidOut[i] - fees[0]);
        }
        assertEq(IERC20(xwell).balanceOf(EMPTY_PROXY), 7e18 + 150e18 - (150e18 * s.compoundFee()) / 10_000);
    }

    function test_isValidSignature_acceptsOnlyTheHookFreeAppData() public {
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(FUNDED_PROXY));
        uint256 sellAmount = 1_000e18;
        // The document the old implementation required: a transferFrom pre-hook paying the fee
        bytes memory hook = abi.encodeCall(
            IERC20.transferFrom, (FUNDED_PROXY, s.feeRecipient(), (sellAmount * s.compoundFee()) / 10_000)
        );
        string memory oldDoc = string.concat(
            '{"appCode":"Mamo","metadata":{"hooks":{"pre":[{"callData":"',
            vm.toString(hook),
            '","gasLimit":"',
            vm.toString(s.hookGasLimit()),
            '","target":"',
            Strings.toHexString(uint160(xwell), 20),
            '"}],"version":"0.1.0"}},"version":"1.3.0"}'
        );
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(xwell),
            buyToken: usdc,
            receiver: FUNDED_PROXY,
            sellAmount: sellAmount,
            buyAmount: s.slippagePriceChecker().getExpectedOut(sellAmount, xwell, address(usdc)),
            validTo: uint32(block.timestamp + 29 minutes),
            appData: keccak256(bytes(oldDoc)),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        // Before the upgrade the hooked document is the one that validates
        assertEq(s.isValidSignature(order.hash(s.DOMAIN_SEPARATOR()), abi.encode(order)), bytes4(0x1626ba7e));

        _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        (, bytes32 hash) = s.expectedAppData();
        assertEq(hash, keccak256(bytes('{"appCode":"Mamo","metadata":{},"version":"1.3.0"}')));
        bytes32 digest = order.hash(s.DOMAIN_SEPARATOR());
        vm.expectRevert("Invalid app data");
        s.isValidSignature(digest, abi.encode(order));

        order.appData = hash;
        assertEq(s.isValidSignature(order.hash(s.DOMAIN_SEPARATOR()), abi.encode(order)), bytes4(0x1626ba7e));
    }

    function _upgrade(address proxy, address owner) internal returns (ERC20MoonwellMorphoStrategy) {
        vm.prank(owner);
        registry.upgradeStrategy(proxy, address(newImpl));
        assertEq(ERC1967Proxy(payable(proxy)).getImplementation(), address(newImpl));
        return ERC20MoonwellMorphoStrategy(payable(proxy));
    }

    function _deposit(ERC20MoonwellMorphoStrategy s, address owner, uint256 amount) internal {
        deal(address(usdc), owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(s), amount);
        s.deposit(amount);
        vm.stopPrank();
    }
}
