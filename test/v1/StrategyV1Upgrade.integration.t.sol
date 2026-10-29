// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeV1Strategies} from "../../multisig/mamo-multisig/020_UpgradeV1StrategiesClaimFeeVaultOnlyUsdc.sol";
import {BaseTest} from "../BaseTest.t.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/v1/ERC20MoonwellMorphoStrategy.sol";
import {StrategyFactory} from "@contracts/v1/StrategyFactory.sol";

import {Vm} from "@forge-std/Vm.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMToken} from "@interfaces/IMToken.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

interface IMetaMorphoQueue {
    function MORPHO() external view returns (address);
    function withdrawQueueLength() external view returns (uint256);
    function withdrawQueue(uint256) external view returns (bytes32);
}

interface IMorphoMarket {
    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
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
    /// @dev Deprecated factory 0x1Eeb…E286 StrategyCreated log at block 32,040,908, still on first-gen impl 0x5fAB…3A35
    address internal constant GEN1_PROXY = 0xC06C044378528D97C96138A385473cF6a746f5Cd;
    address internal constant GEN1_OWNER = 0xDe29a250A94F8d277DBDd1A449b912860539DAaf;

    UpgradeV1Strategies internal upgrade;
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
        // Frozen pre-020 book: the live one moves to contracts that do not exist at the pin
        vm.setEnv("ADDRESSES_PATH", "./addresses/rehearsal-020");
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses/rehearsal-020", chainIds);
        vm.makePersistent(address(addresses));

        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        liveFactory = StrategyFactory(addresses.getAddress("USDC_STRATEGY_FACTORY")); // pre-proposal book
        usdc = IERC20(addresses.getAddress("USDC"));
        mToken = IMToken(addresses.getAddress("MOONWELL_USDC"));
        vault = IERC20(addresses.getAddress("USDC_METAMORPHO_VAULT"));
        xwell = addresses.getAddress("xWELL_PROXY");
        backend = registry.getBackendAddress();
        assertEq(mToken.getCash(), 0, "pin must sit where Moonwell USDC has no cash");

        upgrade = new UpgradeV1Strategies();
        vm.makePersistent(address(upgrade));
        upgrade.run();
        vm.setEnv("ADDRESSES_PATH", "./addresses");
        newImpl = ERC20MoonwellMorphoStrategy(payable(upgrade.addresses().getAddress("MOONWELL_MORPHO_STRATEGY_IMPL")));
        factory = StrategyFactory(upgrade.addresses().getAddress("USDC_STRATEGY_FACTORY"));
        assertEq(factory.feeRecipient(), addresses.getAddress("MAMO_MULTISIG"), "factory fee recipient");
    }

    function test_liveFactory_canNoLongerCreate() public {
        address user = makeAddr("user");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(liveFactory), registry.BACKEND_ROLE()
            )
        );
        vm.prank(user);
        liveFactory.createStrategyForUser(user);
    }

    function test_newAccount_vaultOnly_withdrawsAtZeroCash() public {
        address user = makeAddr("user");
        vm.prank(user);
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(factory.createStrategyForUser(user)));
        assertEq(s.feeRecipient(), addresses.getAddress("MAMO_MULTISIG"));

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

        uint256 underlyingLeft = mToken.balanceOfUnderlying(FUNDED_PROXY);
        vm.startPrank(FUNDED_OWNER);
        s.withdraw(50e6);
        vm.expectEmit(FUNDED_PROXY);
        emit ERC20MoonwellMorphoStrategy.MoonwellRedeemLimited(0, mBalance, underlyingLeft);
        s.withdrawAll();
        vm.stopPrank();
        assertEq(vault.balanceOf(FUNDED_PROXY), 0);
        assertEq(IERC20(address(mToken)).balanceOf(FUNDED_PROXY), mBalance);
        assertApproxEqAbs(usdc.balanceOf(FUNDED_OWNER), 100e6, 1);
    }

    function test_partialCash_redeemsExactlyTheCashIntoTheVault() public {
        uint256 cash = 1e4; // below the proxy's ~0.053 USDC position, so the redeem is partial
        deal(address(usdc), address(mToken), cash);
        assertEq(mToken.getCash(), cash);
        ERC20MoonwellMorphoStrategy s = _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        uint256 underlyingBefore = mToken.balanceOfUnderlying(FUNDED_PROXY);
        assertLt(cash, underlyingBefore);

        vm.recordLogs();
        vm.prank(backend);
        s.updatePosition(0, 10_000);

        assertEq(mToken.getCash(), 0);
        assertApproxEqAbs(underlyingBefore - mToken.balanceOfUnderlying(FUNDED_PROXY), cash, 1);
        assertApproxEqAbs(IERC4626(address(vault)).maxWithdraw(FUNDED_PROXY), cash, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != FUNDED_PROXY) continue;
            if (logs[i].topics[0] != ERC20MoonwellMorphoStrategy.MoonwellRedeemLimited.selector) continue;
            (uint256 redeemed, uint256 mLeft, uint256 left) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(redeemed, cash);
            assertEq(mLeft, IERC20(address(mToken)).balanceOf(FUNDED_PROXY));
            assertEq(left, underlyingBefore - cash);
            found = true;
        }
        assertTrue(found);
    }

    function test_firstGenerationProxy_upgradesStraightToV1() public {
        assertEq(ERC1967Proxy(payable(GEN1_PROXY)).getImplementation(), 0x5fAB373f43079CE488C2b8579751791982C03A35);
        ERC20MoonwellMorphoStrategy s = _upgrade(GEN1_PROXY, GEN1_OWNER);
        assertEq(s.compoundFee(), 500);
        assertEq(address(s.token()), address(usdc));
        uint256 mBalance = IERC20(address(mToken)).balanceOf(GEN1_PROXY);

        vm.prank(backend);
        s.updatePosition(0, 10_000);
        _deposit(s, GEN1_OWNER, 100e6);
        assertApproxEqAbs(IERC4626(address(vault)).maxWithdraw(GEN1_PROXY), 100e6, 1);

        vm.prank(GEN1_OWNER);
        s.withdrawAll();
        assertEq(vault.balanceOf(GEN1_PROXY), 0);
        assertEq(IERC20(address(mToken)).balanceOf(GEN1_PROXY), mBalance);
        assertApproxEqAbs(usdc.balanceOf(GEN1_OWNER), 100e6, 1);
    }

    function test_withdraw_shiftsToTheVaultButNeverPastWhatMoonwellCanPay() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        vm.prank(backend);
        s.updatePosition(0, 10_000);
        _deposit(s, FUNDED_OWNER, 100e6);
        uint256 vaultMax = IERC4626(address(vault)).maxWithdraw(FUNDED_PROXY);

        uint256 snapshot = vm.snapshotState();
        vm.prank(FUNDED_OWNER);
        s.withdraw(vaultMax);
        vm.revertToState(snapshot);

        vm.prank(FUNDED_OWNER);
        vm.expectRevert("Moonwell cannot pay the remainder now");
        s.withdraw(vaultMax + 1);

        deal(address(usdc), address(mToken), 1e6);
        uint256 mBalance = IERC20(address(mToken)).balanceOf(FUNDED_PROXY);
        vm.prank(FUNDED_OWNER);
        s.withdraw(vaultMax + 1);
        assertLt(IERC20(address(mToken)).balanceOf(FUNDED_PROXY), mBalance);
        assertEq(usdc.balanceOf(FUNDED_OWNER), vaultMax + 1);
    }

    function test_claimRewards_refusesADuplicateToken() public {
        address distributor = addresses.getAddress("MERKLE_PROTOCOL_DISTRIBUTOR");
        vm.etch(distributor, type(MockMerkl).runtimeCode);
        deal(xwell, distributor, 1_000e18);
        ERC20MoonwellMorphoStrategy s = _upgrade(EMPTY_PROXY, EMPTY_OWNER);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (xwell, xwell);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (100e18, 200e18);
        vm.prank(backend);
        vm.expectRevert("Duplicate reward token");
        s.claimRewards(tokens, amounts, new bytes32[][](2));

        // Unique but descending by address: accepted
        address morpho = addresses.getAddress("MORPHO");
        deal(morpho, distributor, 1_000e18);
        (tokens[0], tokens[1]) = (morpho, xwell);
        vm.prank(backend);
        s.claimRewards(tokens, amounts, new bytes32[][](2));

        // Non-adjacent duplicate: refused
        tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (xwell, morpho, xwell);
        amounts = new uint256[](3);
        (amounts[0], amounts[1], amounts[2]) = (300e18, 300e18, 400e18);
        vm.prank(backend);
        vm.expectRevert("Duplicate reward token");
        s.claimRewards(tokens, amounts, new bytes32[][](3));
    }

    function test_onlyBackend_isRoleMembership() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(EMPTY_PROXY, EMPTY_OWNER);
        vm.prank(address(factory)); // any BACKEND_ROLE member, not only index 0
        s.updatePosition(0, 10_000);
        vm.prank(addresses.getAddress("MAMO_BACKEND")); // the operator EOA holds no role today
        vm.expectRevert("Not backend");
        s.updatePosition(0, 10_000);
        vm.prank(EMPTY_OWNER);
        vm.expectRevert("Not backend");
        s.updatePosition(0, 10_000);
    }

    function test_withdrawAll_allInDryMoonwell_keepsTheEventAndDoesNotRevert() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        uint256 mBalance = mToken.balanceOf(FUNDED_PROXY);
        uint256 underlying = mToken.balanceOfUnderlying(FUNDED_PROXY);
        vm.recordLogs();
        vm.expectEmit(true, true, true, true);
        emit ERC20MoonwellMorphoStrategy.MoonwellRedeemLimited(0, mBalance, underlying);
        vm.prank(FUNDED_OWNER);
        s.withdrawAll();
        assertEq(mToken.balanceOf(FUNDED_PROXY), mBalance, "position stays until Moonwell has cash");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            bool isWithdraw = logs[i].topics[0] == ERC20MoonwellMorphoStrategy.Withdraw.selector;
            assertFalse(logs[i].emitter == FUNDED_PROXY && isWithdraw, "no transfer, no Withdraw event");
        }
    }

    function test_wethDustCash_skipsARedeemThatWouldBurnZeroMTokens() public {
        // 10000 / 0 like the live WETH factory
        (ERC20MoonwellMorphoStrategy s, IERC20 weth, IMToken mweth) = _wethAccount(10_000);
        deal(address(weth), address(mweth), 1e8); // 0.1 gwei of cash burns zero mTokens at WETH's exchange rate
        vm.prank(backend);
        s.updatePosition(0, 10_000);
        assertEq(s.splitVault(), 10_000);
        assertGt(mweth.balanceOf(address(s)), 0, "dust cash is skipped, position stays");
    }

    function test_withdraw_wethDustMoonwellLegShiftsToTheVault() public {
        (ERC20MoonwellMorphoStrategy s, IERC20 weth, IMToken mweth) = _wethAccount(5_000);
        uint256 mBalance = mweth.balanceOf(address(s));
        vm.prank(s.owner());
        s.withdraw(3e8); // the 1.5e8 Moonwell half would burn zero mTokens
        assertEq(mweth.balanceOf(address(s)), mBalance);
        assertEq(weth.balanceOf(s.owner()), 3e8);
    }

    /// @dev A type-4 account on the new implementation with 1 ether deposited at the given Moonwell split
    function _wethAccount(uint256 splitMToken)
        internal
        returns (ERC20MoonwellMorphoStrategy s, IERC20 weth, IMToken mweth)
    {
        StrategyFactory live = StrategyFactory(addresses.getAddress("WETH_STRATEGY_FACTORY"));
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = xwell;
        rewardTokens[1] = addresses.getAddress("MORPHO");
        StrategyFactory wethFactory = new StrategyFactory(
            address(registry),
            live.mamoBackend(),
            live.mToken(),
            live.metaMorphoVault(),
            live.token(),
            live.slippagePriceChecker(),
            registry.latestImplementationById(4),
            live.feeRecipient(),
            splitMToken,
            10_000 - splitMToken,
            4,
            live.hookGasLimit(),
            live.allowedSlippageInBps(),
            live.compoundFee(),
            rewardTokens
        );
        bytes32 role = registry.BACKEND_ROLE();
        vm.prank(addresses.getAddress("MAMO_MULTISIG"));
        registry.grantRole(role, address(wethFactory));
        address user = makeAddr("wethUser");
        vm.prank(user);
        s = ERC20MoonwellMorphoStrategy(payable(wethFactory.createStrategyForUser(user)));
        weth = IERC20(live.token());
        mweth = IMToken(live.mToken());
        deal(address(weth), user, 1 ether);
        vm.startPrank(user);
        weth.approve(address(s), 1 ether);
        s.deposit(1 ether);
        vm.stopPrank();
    }

    function test_vaultShort_withdrawAllAndUpdatePositionTakeWhatTheVaultCanPay() public {
        address user = makeAddr("user");
        vm.prank(user);
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(factory.createStrategyForUser(user)));
        _deposit(s, user, 1_000e6);

        // Leave 100 USDC of liquidity in each market as MetaMorpho sees it, for both maxRedeem and redeem
        IMetaMorphoQueue mm = IMetaMorphoQueue(address(vault));
        IMorphoMarket morpho = IMorphoMarket(mm.MORPHO());
        for (uint256 i; i < mm.withdrawQueueLength(); i++) {
            bytes32 id = mm.withdrawQueue(i);
            (uint128 supply, uint128 supplyShares,, uint128 borrowShares,, uint128 fee) = morpho.market(id);
            vm.mockCall(
                address(morpho),
                abi.encodeCall(IMorphoMarket.market, (id)),
                abi.encode(supply, supplyShares, supply - 100e6, borrowShares, block.timestamp, fee)
            );
        }
        IERC4626 v = IERC4626(address(vault));
        assertLt(v.maxWithdraw(address(s)), 600e6);

        uint256 shares = vault.balanceOf(address(s));
        uint256 redeemable = v.maxRedeem(address(s));
        vm.expectEmit(address(s));
        emit ERC20MoonwellMorphoStrategy.VaultRedeemLimited(redeemable, shares - redeemable);
        vm.prank(backend);
        s.updatePosition(0, 10_000);

        uint256 maxOut = v.maxWithdraw(address(s));
        shares = vault.balanceOf(address(s));
        redeemable = v.maxRedeem(address(s));
        uint256 paid = v.previewRedeem(redeemable);
        assertLt(maxOut, 600e6);
        vm.expectEmit(address(s));
        emit ERC20MoonwellMorphoStrategy.VaultRedeemLimited(redeemable, shares - redeemable);
        vm.prank(user);
        s.withdrawAll();
        assertEq(usdc.balanceOf(user), paid);
        assertApproxEqAbs(usdc.balanceOf(user), maxOut, 1); // redeem floors maxRedeem's shares once more
        assertEq(vault.balanceOf(address(s)), shares - redeemable);
        assertGt(shares - redeemable, 0);
    }

    function test_initializeVaultSplit_pointsAFundedLegacyProxyAtTheVault() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        uint256 mBalance = mToken.balanceOf(FUNDED_PROXY);
        vm.prank(FUNDED_OWNER); // the app sends this right after the upgrade
        s.initializeVaultSplit();
        assertEq(s.splitMToken(), 0);
        assertEq(s.splitVault(), 10_000);
        assertEq(mToken.balanceOf(FUNDED_PROXY), mBalance, "nothing moved");
        _deposit(s, FUNDED_OWNER, 100e6);
        assertGt(vault.balanceOf(FUNDED_PROXY), 0, "new deposit lands in the vault");
        assertEq(mToken.balanceOf(FUNDED_PROXY), mBalance, "Moonwell share untouched");

        uint256 maxOut = IERC4626(address(vault)).maxWithdraw(FUNDED_PROXY);
        vm.startPrank(FUNDED_OWNER);
        vm.expectRevert("Moonwell cannot pay the remainder now"); // the vault is drained, Moonwell has no cash
        s.withdraw(maxOut + 1);
        s.withdraw(maxOut);
        s.withdrawAll(); // best-effort: pays nothing more, leaves the Moonwell share in place
        assertEq(mToken.balanceOf(FUNDED_PROXY), mBalance, "Moonwell share still in place");
        // Some Moonwell cash back, below the share: part 2 reaches it without a re-split
        deal(address(usdc), address(mToken), 10_000);
        s.withdraw(10_000);
        vm.stopPrank();
    }

    function test_initializeVaultSplit_ownerOnly_runsOnce_usdcOnly() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(EMPTY_PROXY, EMPTY_OWNER);
        address stranger = makeAddr("stranger");
        address[2] memory notOwners = [stranger, backend];
        for (uint256 i; i < 2; i++) {
            vm.prank(notOwners[i]);
            vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", notOwners[i]));
            s.initializeVaultSplit();
        }
        vm.prank(EMPTY_OWNER);
        s.initializeVaultSplit();
        assertEq(s.splitVault(), 10_000);
        vm.prank(EMPTY_OWNER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        s.initializeVaultSplit();

        StrategyFactory f = StrategyFactory(upgrade.addresses().getAddress("cbBTC_STRATEGY_FACTORY"));
        address user = makeAddr("cbBTC");
        vm.startPrank(user);
        ERC20MoonwellMorphoStrategy c = ERC20MoonwellMorphoStrategy(payable(f.createStrategyForUser(user)));
        vm.expectRevert("Not a USDC account");
        c.initializeVaultSplit();
        vm.stopPrank();
    }

    function test_unupgradedLegacyProxy_depositStillGoesToMoonwell() public {
        // Why the app gates deposits until upgrade + initializeVaultSplit
        ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(FUNDED_PROXY));
        uint256 mBalance = mToken.balanceOf(FUNDED_PROXY);
        _deposit(s, FUNDED_OWNER, 100e6);
        assertGt(mToken.balanceOf(FUNDED_PROXY), mBalance);
        assertEq(vault.balanceOf(FUNDED_PROXY), 0);
    }

    function test_emptyLegacyProxy_fullLifecycle() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(EMPTY_PROXY, EMPTY_OWNER);
        vm.prank(backend);
        s.updatePosition(0, 10_000);
        _deposit(s, EMPTY_OWNER, 100e6);
        assertGt(vault.balanceOf(EMPTY_PROXY), 0);
        assertEq(mToken.balanceOf(EMPTY_PROXY), 0);

        vm.startPrank(EMPTY_OWNER);
        s.withdraw(40e6);
        assertEq(mToken.balanceOf(EMPTY_PROXY), 0);
        s.withdrawAll();
        vm.stopPrank();
        assertEq(vault.balanceOf(EMPTY_PROXY), 0);
        assertEq(mToken.balanceOf(EMPTY_PROXY), 0);
        assertApproxEqAbs(usdc.balanceOf(EMPTY_OWNER), 100e6, 1);
    }

    function test_newCbBtcAndWethAccounts_defaultToMoonwell() public {
        string[2] memory assets = ["cbBTC", "WETH"];
        uint256[2] memory amounts = [uint256(0.01e8), 1e18];
        for (uint256 i; i < 2; i++) {
            StrategyFactory f =
                StrategyFactory(upgrade.addresses().getAddress(string.concat(assets[i], "_STRATEGY_FACTORY")));
            address user = makeAddr(assets[i]);
            vm.prank(user);
            ERC20MoonwellMorphoStrategy s = ERC20MoonwellMorphoStrategy(payable(f.createStrategyForUser(user)));
            IERC20 asset = s.token();
            deal(address(asset), user, amounts[i]);
            vm.startPrank(user);
            asset.approve(address(s), amounts[i]);
            s.deposit(amounts[i]);
            assertGt(IERC20(address(s.mToken())).balanceOf(address(s)), 0);
            assertEq(IERC20(address(s.metaMorphoVault())).balanceOf(address(s)), 0);
            s.withdrawAll();
            vm.stopPrank();
            assertApproxEqRel(asset.balanceOf(user), amounts[i], 1e13); // mToken exchange-rate rounding
        }
    }

    function test_fundedLegacyProxy_withdrawUpToMoonwellCash_beforeVaultSplit() public {
        // The deployed withdraw path is intact for accounts still on 10000/0
        ERC20MoonwellMorphoStrategy s = _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        assertEq(s.splitMToken(), 10_000);
        deal(address(usdc), address(mToken), 10_000); // sets the balance: equals adding only because setUp pins cash at 0
        uint256 ownerBefore = usdc.balanceOf(FUNDED_OWNER);
        vm.startPrank(FUNDED_OWNER);
        vm.expectRevert("Moonwell cannot pay the remainder now"); // no vault balance to shift the excess to
        s.withdraw(10_001);
        s.withdraw(10_000);
        vm.stopPrank();
        assertEq(usdc.balanceOf(FUNDED_OWNER) - ownerBefore, 10_000);
    }

    function test_fundedLegacyProxy_vaultSplit_thenCashReturns_compounderMigratesAndOwnerExits() public {
        ERC20MoonwellMorphoStrategy s = _upgrade(FUNDED_PROXY, FUNDED_OWNER);
        vm.prank(FUNDED_OWNER);
        s.initializeVaultSplit();
        _deposit(s, FUNDED_OWNER, 100e6);
        uint256 total = mToken.balanceOfUnderlying(FUNDED_PROXY) + IERC4626(address(vault)).maxWithdraw(FUNDED_PROXY);
        deal(address(usdc), address(mToken), 1e6); // Moonwell can now pay the whole share
        vm.prank(backend);
        s.updatePosition(0, 10_000);
        assertEq(mToken.balanceOf(FUNDED_PROXY), 0, "Moonwell share moved to the vault");
        uint256 ownerBefore = usdc.balanceOf(FUNDED_OWNER);
        vm.prank(FUNDED_OWNER);
        s.withdrawAll();
        assertApproxEqAbs(usdc.balanceOf(FUNDED_OWNER) - ownerBefore, total, 3);
    }

    function test_implementation_refusesInitialize() public {
        ERC20MoonwellMorphoStrategy.InitParams memory params;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        newImpl.initialize(params);
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
