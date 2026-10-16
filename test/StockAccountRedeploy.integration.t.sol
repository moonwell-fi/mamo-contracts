// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RedeployStockAccountSystem} from "../multisig/mamo-multisig/019_RedeployStockAccountSystem.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

/// @dev The live v1 account's exits, which predate the bounded exit signatures
interface IStockAccountV1 {
    function deposit(uint256 amount) external;
    function withdraw(uint256 usdcAmount, uint16 maxSlippageBps) external;
    function withdrawAllInKind() external;
    function getNAV() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// StockAccountRedeployTest — Base-fork rehearsal of proposal 019 (redeploy under type id 7, retire v1),
// self-forked at a PINNED block (no --fork-url, same op-revm reason as StockAccountSystemSetupTest).
//
// WHAT THIS DRIVES
//   1. a v1 account opened through the LIVE v1 factory and funded, before the batch;
//   2. proposal 019 hook by hook (deploy, preBuildMock, build, simulate, validate), the recorded batch,
//      and the post-conditions restated here;
//   3. a v2 account for the same user: create, deposit, a bounded cash withdrawal, withdrawAllInKind;
//   4. the v1 account after the pause: the v1 factory can no longer create, and both v1 exits work.
//
// WHAT THIS DOES NOT DRIVE
//   THE STOCKS, AS TOKENS. All twelve are node-native (code 0xEF), so nothing can deposit, transfer or
//   sell them in a fork; 019's preBuildMock stands in for their `decimals()`/`balanceOf()` reads, and
//   their pool leg stays real. cbBTC is off the list, so the lifecycle is USDC-only.
//   THE COW ORDER PATH. `isValidSignature` needs a STOCK_ORDER_SIGNER signature (ops key). On v1 it now
//   fails twice over: the signer is a dead address and `registry.paused()`, which it reads, is true.
// ─────────────────────────────────────────────────────────────────────────────
contract StockAccountRedeployTest is Test {
    /// @dev v1 live with 13 listings (cbBTC Halted), slots 1-5 set, 6 and 7 empty, counter at 4
    uint256 internal constant PINNED_BLOCK = 52_650_000;

    address internal constant DEPLOYER_EOA = 0xDca82E03057329f53Ed4173429D46B0511E46Fb8;
    address internal constant DEAD_SIGNER = 0x000000000000000000000000000000000000dEaD;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;

    uint16 internal constant WITHDRAW_SLIPPAGE_BPS = 500;
    uint256 internal constant V1_DEPOSIT = 1_000e6;
    uint256 internal constant V1_WITHDRAWAL = 400e6;
    uint256 internal constant V2_DEPOSIT = 5_000e6;
    uint256 internal constant V2_WITHDRAWAL = 1_000e6;

    RedeployStockAccountSystem internal proposal;
    Addresses internal addresses;
    MamoStrategyRegistry internal mamoRegistry;

    address internal usdc;
    address internal deployer = makeAddr("stockAccountsV2Deployer");
    address internal user = makeAddr("stockAccountsUser");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        /// @dev The deployer carries an EIP-7702 delegation, which FPS reads as a contract; a nonce-0
        ///      throwaway then deploys into CREATE slots the book cannot already record
        vm.etch(DEPLOYER_EOA, "");
        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));
        addresses.changeAddress("DEPLOYER_EOA", deployer, false);

        usdc = addresses.getAddress("USDC");
        mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        proposal = new RedeployStockAccountSystem();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
    }

    function test_redeploy_v2Lifecycle_andV1ExitAfterPause() public {
        proposal.deploy();
        // The stand-in must exist before a v1 deposit can value the account
        proposal.preBuildMock();

        IStockAccountV1 v1Account = _openV1Account();
        assertEq(
            mamoRegistry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 is the strategy multicall before 019"
        );

        proposal.build();
        proposal.simulate();
        proposal.validate();

        _proveRecordedBatch();
        _proveBatchPostConditions();
        _proveV2Lifecycle();
        _proveV1ExitAfterPause(v1Account);
    }

    function _basket() internal pure returns (IStockAccountStrategy.BasketEntry[] memory entries) {
        entries = new IStockAccountStrategy.BasketEntry[](1);
        entries[0] = IStockAccountStrategy.BasketEntry({token: NVDAC, targetBps: 5_000});
    }

    function _openV1Account() internal returns (IStockAccountV1 account) {
        StockAccountStrategyFactory v1Factory =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));

        vm.prank(user);
        account = IStockAccountV1(v1Factory.createStrategyForUser(user, _basket(), 5_000));

        deal(usdc, user, V1_DEPOSIT);
        vm.startPrank(user);
        IERC20(usdc).approve(address(account), V1_DEPOSIT);
        account.deposit(V1_DEPOSIT);
        vm.stopPrank();

        assertEq(account.getNAV(), V1_DEPOSIT, "v1 account funded");
    }

    function _proveRecordedBatch() internal view {
        (address[] memory targets, uint256[] memory values, bytes[] memory args) = proposal.getProposalActions();
        StockAccountsConfig.TokenListEntry[] memory entries = proposal.deployConfig().loadTokenList();

        address registryV2 = addresses.getAddress("STOCK_ACCOUNT_REGISTRY_V2");
        address registryV1 = addresses.getAddress("STOCK_ACCOUNT_REGISTRY");

        assertEq(entries.length, 12, "twelve stocks on the list");
        assertEq(targets.length, 6 + entries.length, "four wiring actions, twelve listings, two v1 actions");

        address[4] memory wiringTargets =
            [registryV2, address(mamoRegistry), address(mamoRegistry), address(mamoRegistry)];
        bytes4[4] memory wiringSelectors = [
            StockAccountRegistry.setPriceChecker.selector,
            MamoStrategyRegistry.whitelistImplementation.selector,
            IAccessControl.grantRole.selector,
            IAccessControl.revokeRole.selector
        ];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(targets[i], wiringTargets[i], "wiring target");
            assertEq(bytes4(args[i]), wiringSelectors[i], "wiring selector");
        }

        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(targets[4 + i], registryV2, "listing target");
            assertEq(bytes4(args[4 + i]), StockAccountRegistry.listToken.selector, "listing selector");
            assertEq(_firstAddressArgument(args[4 + i]), entries[i].token, "listToken targets the real token address");
        }

        uint256 last = targets.length - 1;
        assertEq(targets[last - 1], registryV1, "signer rotation targets the v1 registry");
        assertEq(bytes4(args[last - 1]), StockAccountRegistry.setOrderSigner.selector, "signer rotation selector");
        assertEq(_firstAddressArgument(args[last - 1]), DEAD_SIGNER, "v1 signer set to the dead address");
        assertEq(targets[last], registryV1, "pause targets the v1 registry");
        assertEq(bytes4(args[last]), StockAccountRegistry.pause.selector, "pause selector");

        for (uint256 i = 0; i < values.length; i++) {
            assertEq(values[i], 0, "no action moves ETH");
        }
    }

    function _firstAddressArgument(bytes memory data) internal pure returns (address argument) {
        assembly {
            argument := mload(add(data, 36))
        }
    }

    function _proveBatchPostConditions() internal view {
        bytes32 backendRole = mamoRegistry.BACKEND_ROLE();

        assertEq(proposal.strategyTypeId(), 7, "type id 7");
        assertEq(
            mamoRegistry.latestImplementationById(7),
            addresses.getAddress("STOCK_ACCOUNT_STRATEGY_IMPL_V2"),
            "v2 implementation at slot 7"
        );
        assertEq(mamoRegistry.latestImplementationById(6), address(0), "slot 6 still reserved");
        assertEq(
            mamoRegistry.latestImplementationById(5), 0x17Fff4d4E628fc17C4e01B1E781A368Bc33444e5, "slot 5 untouched"
        );
        assertEq(
            mamoRegistry.latestImplementationById(4), 0x6C8577fa9B10807f7485f6476C2AFE0B8d61D1e7, "slot 4 untouched"
        );

        assertTrue(
            mamoRegistry.hasRole(backendRole, addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY_V2")),
            "v2 factory holds BACKEND_ROLE"
        );
        assertFalse(
            mamoRegistry.hasRole(backendRole, addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY")),
            "v1 factory revoked"
        );
        assertEq(
            mamoRegistry.getBackendAddress(),
            addresses.getAddress("STRATEGY_MULTICALL"),
            "BACKEND_ROLE index 0 did not move"
        );
        assertTrue(StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY")).paused(), "v1 paused");
    }

    function _proveV2Lifecycle() internal {
        StockAccountStrategyFactory factory =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY_V2"));

        address predicted = factory.computeStrategyAddress(user);
        assertEq(predicted.code.length, 0, "nothing at the predicted address yet");

        // The same user holds a v1 account: the duplicate check matches on type id, so 5 does not block 7
        vm.prank(user);
        StockAccountStrategy account =
            StockAccountStrategy(payable(factory.createStrategyForUser(user, _basket(), 5_000)));

        assertEq(address(account), predicted, "account at the predicted address");
        assertEq(account.owner(), user, "account owned by the user");
        assertEq(account.strategyTypeId(), 7, "account carries type id 7");
        assertEq(mamoRegistry.getUserStrategies(user).length, 2, "the user holds a v1 and a v2 account");

        deal(usdc, user, V2_DEPOSIT);
        vm.startPrank(user);
        IERC20(usdc).approve(address(account), V2_DEPOSIT);
        account.deposit(V2_DEPOSIT);
        vm.stopPrank();
        assertEq(account.getNAV(), V2_DEPOSIT, "v2 account funded");

        (address[] memory toSell,,,) = account.previewWithdraw(V2_WITHDRAWAL, WITHDRAW_SLIPPAGE_BPS);
        assertEq(toSell.length, 0, "a cash-covered withdrawal plans no sells");

        uint256 before = IERC20(usdc).balanceOf(user);
        vm.prank(user);
        account.withdraw(
            V2_WITHDRAWAL, WITHDRAW_SLIPPAGE_BPS, new address[](0), new uint256[](0), block.timestamp + 10 minutes
        );
        assertEq(IERC20(usdc).balanceOf(user) - before, V2_WITHDRAWAL, "bounded withdrawal paid out");

        vm.prank(user);
        account.withdrawAllInKind();
        assertEq(IERC20(usdc).balanceOf(user) - before, V2_DEPOSIT, "the rest swept in kind");
        assertEq(account.principal(), 0, "principal cleared");
        assertEq(account.getNAV(), 0, "account empty");
    }

    function _proveV1ExitAfterPause(IStockAccountV1 account) internal {
        address v1Factory = addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY");
        address lateUser = makeAddr("v1LateUser");
        bytes32 backendRole = mamoRegistry.BACKEND_ROLE();

        vm.prank(lateUser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, v1Factory, backendRole)
        );
        StockAccountStrategyFactory(v1Factory).createStrategyForUser(lateUser, _basket(), 5_000);

        uint256 before = IERC20(usdc).balanceOf(user);
        vm.prank(user);
        account.withdraw(V1_WITHDRAWAL, WITHDRAW_SLIPPAGE_BPS);
        assertEq(IERC20(usdc).balanceOf(user) - before, V1_WITHDRAWAL, "v1 cash withdrawal works after the pause");

        vm.prank(user);
        account.withdrawAllInKind();
        assertEq(IERC20(usdc).balanceOf(user) - before, V1_DEPOSIT, "v1 in-kind exit works after the pause");
        assertEq(account.getNAV(), 0, "v1 account empty");
    }
}
