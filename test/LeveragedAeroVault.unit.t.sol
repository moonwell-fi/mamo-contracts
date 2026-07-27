// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LeveragedAeroVault} from "@contracts/LeveragedAeroVault.sol";

import {MockToken} from "./mocks/MockToken.sol";
import {MockVaultStrategy} from "./mocks/MockVaultStrategy.sol";

import {Test} from "@forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LeveragedAeroVault unit tests
 * @notice Fork-free unit suite (runs under `make test-unit` / `make leveraged-aero-vault`) for the
 *         vanilla share ledger the vendored leveraged-Aero strategy binds to. The strategy itself is
 *         stubbed by {MockVaultStrategy} — the vault's own surface (decimals offset, share hooks,
 *         fee-config hops, lifecycle, settled exit, rescue) is what is under test.
 */
contract LeveragedAeroVaultUnitTest is Test {
    // ---- events mirrored from LeveragedAeroVault (for vm.expectEmit) ----
    event StrategySet(address indexed strategy);
    event OpenDepositsUpdated(bool open);
    event FeeConfigUpdated(address indexed feeConfig);
    event StrategyActivated(address indexed strategy, uint256 seedAmount);
    event StrategySettled(address indexed strategy);
    event SettledRedeem(address indexed owner, uint256 shares, uint256 assetsOut);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    address public owner = makeAddr("owner");
    address public thirdParty = makeAddr("thirdParty");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public feeConfig = makeAddr("feeConfig");

    MockToken public usdc;
    MockToken public stray;
    LeveragedAeroVault public vault;
    MockVaultStrategy public strategy;

    uint256 internal constant SEED = 10_000e6; // 10k USDC

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        stray = new MockToken("Stray", "STRAY", 18);
        vault = new LeveragedAeroVault(address(usdc), owner, "Leveraged Aero Vault", "lvAERO");
        strategy = new MockVaultStrategy(address(vault), address(usdc));
    }

    // ==================== HELPERS ====================

    function _bind() internal {
        vm.prank(owner);
        vault.setStrategy(address(strategy));
    }

    function _openDeposits() internal {
        vm.prank(owner);
        vault.setOpenDeposits(true);
    }

    /// @dev Binds the strategy, opens deposits, and mints `shares` to `to` through the strategy hook.
    function _bindAndMint(address to, uint256 shares) internal {
        if (vault.strategy() == address(0)) _bind();
        if (!vault.depositsOpen()) _openDeposits();
        strategy.mintShares(to, shares);
    }

    /// @dev Funds `owner` with `amount` USDC and approves the vault to pull it for the seed.
    function _fundOwner(uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.prank(owner);
        usdc.approve(address(vault), amount);
    }

    // ==================== CONSTRUCTION ====================

    function testConstructorWiring() public view {
        assertEq(vault.asset(), address(usdc), "asset");
        assertEq(vault.owner(), owner, "owner");
        assertEq(vault.name(), "Leveraged Aero Vault", "name");
        assertEq(vault.symbol(), "lvAERO", "symbol");
        assertEq(vault.strategy(), address(0), "strategy unset");
        assertFalse(vault.depositsOpen(), "deposits closed by default");
        assertFalse(vault.settled(), "not settled");
        assertEq(vault.feeConfig(), address(0), "fee config unset");
    }

    function testConstructorZeroAssetReverts() public {
        vm.expectRevert("LAV: invalid asset");
        new LeveragedAeroVault(address(0), owner, "n", "s");
    }

    function testConstructorZeroOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LeveragedAeroVault(address(usdc), address(0), "n", "s");
    }

    // ==================== DECIMALS ====================

    function testDecimalsIsAssetPlusSix() public view {
        assertEq(vault.decimals(), 12, "6dp asset -> 12dp shares");
    }

    function testDecimalsTracksAssetDecimals() public {
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18);
        LeveragedAeroVault wethVault = new LeveragedAeroVault(address(weth), owner, "n", "s");
        assertEq(wethVault.decimals(), 24, "18dp asset -> 24dp shares");
    }

    // ==================== SET STRATEGY ====================

    function testSetStrategy() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit StrategySet(address(strategy));

        vm.prank(owner);
        vault.setStrategy(address(strategy));

        assertEq(vault.strategy(), address(strategy), "strategy");
    }

    function testSetStrategyOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.setStrategy(address(strategy));
    }

    function testSetStrategyIsSetOnce() public {
        _bind();

        vm.prank(owner);
        vm.expectRevert("LAV: strategy already set");
        vault.setStrategy(makeAddr("otherStrategy"));
    }

    function testSetStrategyZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert("LAV: invalid strategy");
        vault.setStrategy(address(0));
    }

    // ==================== STRATEGY MINT ====================

    function testStrategyMint() public {
        _bindAndMint(alice, 1_000e12);

        assertEq(vault.balanceOf(alice), 1_000e12, "alice shares");
        assertEq(vault.totalSupply(), 1_000e12, "supply");
    }

    function testStrategyMintOnlyStrategy() public {
        _bind();
        _openDeposits();

        vm.prank(thirdParty);
        vm.expectRevert("LAV: only strategy");
        vault.strategyMint(thirdParty, 1e12);
    }

    function testStrategyMintOnlyStrategyEvenForOwner() public {
        _bind();
        _openDeposits();

        vm.prank(owner);
        vm.expectRevert("LAV: only strategy");
        vault.strategyMint(owner, 1e12);
    }

    function testStrategyMintRequiresOpenDeposits() public {
        _bind();

        vm.expectRevert("LAV: deposits closed");
        strategy.mintShares(alice, 1e12);
    }

    function testStrategyMintRevertsAfterDepositsReclosed() public {
        _bindAndMint(alice, 1e12);

        vm.prank(owner);
        vault.setOpenDeposits(false);

        vm.expectRevert("LAV: deposits closed");
        strategy.mintShares(alice, 1e12);
    }

    function testSetOpenDepositsOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.setOpenDeposits(true);
    }

    function testSetOpenDepositsEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit OpenDepositsUpdated(true);

        vm.prank(owner);
        vault.setOpenDeposits(true);
        assertTrue(vault.depositsOpen(), "open");
    }

    // ==================== STRATEGY BURN ====================

    function testStrategyBurnBurnsOwnBalance() public {
        _bindAndMint(alice, 1_000e12);

        // Alice approves + the strategy pulls the shares, exactly as `redeem` does.
        vm.prank(alice);
        vault.approve(address(strategy), 400e12);
        strategy.pullShares(alice, 400e12);
        assertEq(vault.balanceOf(address(strategy)), 400e12, "escrowed");

        strategy.burnShares(400e12);

        assertEq(vault.balanceOf(address(strategy)), 0, "burned");
        assertEq(vault.balanceOf(alice), 600e12, "alice remainder");
        assertEq(vault.totalSupply(), 600e12, "supply");
    }

    function testStrategyBurnOnlyStrategy() public {
        _bindAndMint(thirdParty, 1e12);

        vm.prank(thirdParty);
        vm.expectRevert("LAV: only strategy");
        vault.strategyBurn(1e12);
    }

    /// @dev Exits must survive a deposit freeze: burn is deliberately NOT gated on `depositsOpen`.
    function testStrategyBurnWorksWhenDepositsClosed() public {
        _bindAndMint(alice, 1_000e12);

        vm.prank(alice);
        vault.approve(address(strategy), 1_000e12);
        strategy.pullShares(alice, 1_000e12);

        vm.prank(owner);
        vault.setOpenDeposits(false);

        strategy.burnShares(1_000e12);
        assertEq(vault.totalSupply(), 0, "supply");
    }

    function testStrategyBurnCannotBurnThirdPartyShares() public {
        _bindAndMint(alice, 1_000e12);

        // The strategy holds nothing, so a burn hits ERC20InsufficientBalance rather than
        // touching alice's balance.
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", address(strategy), 0, 1e12)
        );
        strategy.burnShares(1e12);
        assertEq(vault.balanceOf(alice), 1_000e12, "alice untouched");
    }

    // ==================== FEE CONFIG ====================

    function testFeeConfigUnsetShortCircuits() public view {
        assertEq(vault.factory(), address(0), "factory hop off");
        assertEq(vault.protocolConfig(), address(0), "config off");
    }

    function testFeeConfigSetPointsFactoryAtSelf() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit FeeConfigUpdated(feeConfig);

        vm.prank(owner);
        vault.setFeeConfig(feeConfig);

        assertEq(vault.factory(), address(vault), "factory hop -> self");
        assertEq(vault.protocolConfig(), feeConfig, "config");
    }

    function testFeeConfigCanBeCleared() public {
        vm.startPrank(owner);
        vault.setFeeConfig(feeConfig);
        vault.setFeeConfig(address(0));
        vm.stopPrank();

        assertEq(vault.factory(), address(0), "factory hop off again");
        assertEq(vault.protocolConfig(), address(0), "config cleared");
    }

    function testSetFeeConfigOnlyOwner() public {
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.setFeeConfig(feeConfig);
    }

    // ==================== ACTIVATE ====================

    function testActivateStrategySeedsAndExecutes() public {
        _bind();
        _fundOwner(SEED);

        vm.expectEmit(true, false, false, true, address(vault));
        emit StrategyActivated(address(strategy), SEED);

        vm.prank(owner);
        vault.activateStrategy(SEED);

        assertEq(usdc.balanceOf(address(strategy)), SEED, "seed landed on strategy");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault never custodies the seed");
        assertEq(strategy.seedReceived(), SEED, "strategy saw the seed at execute()");
        assertEq(uint256(strategy.phase()), uint256(MockVaultStrategy.Phase.Executed), "executed");
    }

    function testActivateStrategyOnlyOwner() public {
        _bind();
        usdc.mint(thirdParty, SEED);
        vm.prank(thirdParty);
        usdc.approve(address(vault), SEED);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.activateStrategy(SEED);
    }

    function testActivateStrategyRequiresStrategySet() public {
        _fundOwner(SEED);

        vm.prank(owner);
        vm.expectRevert("LAV: strategy not set");
        vault.activateStrategy(SEED);
    }

    /// @dev The vault imposes no seed floor: a zero seed is forwarded and the STRATEGY decides. The
    ///      real strategy reverts `ExecuteZeroBalance`; this mock records a zero seed instead.
    function testActivateStrategyZeroSeedIsForwardedToStrategy() public {
        _bind();

        vm.prank(owner);
        vault.activateStrategy(0);

        assertEq(strategy.seedReceived(), 0, "zero seed observed by strategy");
        assertEq(uint256(strategy.phase()), uint256(MockVaultStrategy.Phase.Executed), "executed");
    }

    function testActivateStrategyTwiceReverts() public {
        _bind();
        _fundOwner(SEED);

        vm.startPrank(owner);
        vault.activateStrategy(SEED);
        vm.expectRevert("MockStrategy: already executed");
        vault.activateStrategy(0);
        vm.stopPrank();
    }

    // ==================== SETTLE ====================

    function testSettleStrategyPullsRealizedAssets() public {
        _bind();
        _fundOwner(SEED);
        vm.prank(owner);
        vault.activateStrategy(SEED);

        // Simulate a profitable book: the strategy ends with more than it was seeded.
        usdc.mint(address(strategy), 1_000e6);

        vm.expectEmit(true, false, false, false, address(vault));
        emit StrategySettled(address(strategy));

        vm.prank(owner);
        vault.settleStrategy();

        assertTrue(vault.settled(), "settled");
        assertEq(usdc.balanceOf(address(vault)), SEED + 1_000e6, "realized assets in vault");
        assertEq(usdc.balanceOf(address(strategy)), 0, "strategy flat");
    }

    function testSettleStrategyOnlyOwner() public {
        _bind();
        _fundOwner(SEED);
        vm.prank(owner);
        vault.activateStrategy(SEED);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.settleStrategy();
    }

    function testSettleStrategyRequiresStrategySet() public {
        vm.prank(owner);
        vm.expectRevert("LAV: strategy not set");
        vault.settleStrategy();
    }

    // ==================== REDEEM SETTLED ====================

    /// @dev Sets up 1e12 (alice) + 2e12 (bob) shares against a 1000 USDC settled pot.
    function _settledBook() internal {
        _bindAndMint(alice, 1e12);
        strategy.mintShares(bob, 2e12);

        _fundOwner(SEED);
        vm.startPrank(owner);
        vault.activateStrategy(SEED);
        vm.stopPrank();

        // Overwrite the seed so the strategy settles with exactly 1000 USDC of realized assets.
        deal(address(usdc), address(strategy), 1_000e6);

        vm.prank(owner);
        vault.settleStrategy();
    }

    function testRedeemSettledProRataRoundsDown() public {
        _settledBook();
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "pot");

        // alice: 1e12 / 3e12 of 1000e6 = 333.333333... -> 333333333 (floors, stayers keep the dust)
        vm.expectEmit(true, false, false, true, address(vault));
        emit SettledRedeem(alice, 1e12, 333_333_333);

        vm.prank(alice);
        uint256 aliceOut = vault.redeemSettled(1e12);

        assertEq(aliceOut, 333_333_333, "alice payout floors down");
        assertEq(usdc.balanceOf(alice), 333_333_333, "alice paid");
        assertEq(vault.balanceOf(alice), 0, "alice burned");
        assertEq(vault.totalSupply(), 2e12, "supply after alice");

        // bob then takes the whole remainder, including the wei alice's rounding left behind.
        vm.prank(bob);
        uint256 bobOut = vault.redeemSettled(2e12);

        assertEq(bobOut, 666_666_667, "bob absorbs the rounding residual");
        assertEq(aliceOut + bobOut, 1_000e6, "pot fully distributed");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault drained");
        assertEq(vault.totalSupply(), 0, "supply zero");
    }

    function testRedeemSettledPartial() public {
        _settledBook();

        vm.prank(bob);
        uint256 out = vault.redeemSettled(1e12);

        // 1e12 / 3e12 of 1000e6
        assertEq(out, 333_333_333, "partial payout");
        assertEq(vault.balanceOf(bob), 1e12, "bob keeps the rest");
        assertEq(vault.totalSupply(), 2e12, "supply");
    }

    function testRedeemSettledBeforeSettleReverts() public {
        _bindAndMint(alice, 1e12);

        vm.prank(alice);
        vm.expectRevert("LAV: not settled");
        vault.redeemSettled(1e12);
    }

    function testRedeemSettledZeroSharesReverts() public {
        _settledBook();

        vm.prank(alice);
        vm.expectRevert("LAV: zero shares");
        vault.redeemSettled(0);
    }

    function testRedeemSettledWithoutSharesReverts() public {
        _settledBook();

        vm.prank(thirdParty);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", thirdParty, 0, 1e12)
        );
        vault.redeemSettled(1e12);
    }

    function testRedeemSettledEmptyPotBurnsForZero() public {
        _bindAndMint(alice, 1e12);
        _fundOwner(0);
        vm.startPrank(owner);
        vault.activateStrategy(0);
        vault.settleStrategy();
        vm.stopPrank();

        vm.prank(alice);
        uint256 out = vault.redeemSettled(1e12);

        assertEq(out, 0, "nothing to pay");
        assertEq(vault.totalSupply(), 0, "shares burned anyway");
    }

    // ==================== RESCUE ====================

    function testRescueNonAssetToken() public {
        _bindAndMint(alice, 1e12); // shares outstanding: still rescuable
        stray.mint(address(vault), 5e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Rescued(address(stray), thirdParty, 5e18);

        vm.prank(owner);
        vault.rescueERC20(address(stray), thirdParty, 5e18);

        assertEq(stray.balanceOf(thirdParty), 5e18, "rescued");
    }

    function testRescueAssetBlockedWhileSharesOutstanding() public {
        _bindAndMint(alice, 1e12);
        usdc.mint(address(vault), 1_000e6);

        vm.prank(owner);
        vm.expectRevert("LAV: asset reserved for redemptions");
        vault.rescueERC20(address(usdc), thirdParty, 1_000e6);
    }

    function testRescueAssetAllowedWhenNoSharesOutstanding() public {
        usdc.mint(address(vault), 1_000e6);

        vm.prank(owner);
        vault.rescueERC20(address(usdc), thirdParty, 1_000e6);

        assertEq(usdc.balanceOf(thirdParty), 1_000e6, "asset rescued");
    }

    function testRescueAssetAllowedAfterEveryoneExits() public {
        _settledBook();

        vm.prank(alice);
        vault.redeemSettled(1e12);
        vm.prank(bob);
        vault.redeemSettled(2e12);

        // Dust arriving after the last exit is reclaimable.
        usdc.mint(address(vault), 7);
        vm.prank(owner);
        vault.rescueERC20(address(usdc), thirdParty, 7);

        assertEq(usdc.balanceOf(thirdParty), 7, "dust rescued");
    }

    function testRescueOnlyOwner() public {
        stray.mint(address(vault), 1e18);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thirdParty));
        vault.rescueERC20(address(stray), thirdParty, 1e18);
    }

    function testRescueZeroRecipientReverts() public {
        stray.mint(address(vault), 1e18);

        vm.prank(owner);
        vm.expectRevert("LAV: invalid recipient");
        vault.rescueERC20(address(stray), address(0), 1e18);
    }

    // ==================== OWNERSHIP ====================

    /// @dev Ownable2Step: the strategy's `rescueToVault` reads `Ownable(vault).owner()`, so a
    ///      nomination alone must NOT move that authority.
    function testOwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(thirdParty);
        assertEq(vault.owner(), owner, "owner unchanged until accepted");
        assertEq(vault.pendingOwner(), thirdParty, "pending owner");

        vm.prank(thirdParty);
        vault.acceptOwnership();
        assertEq(vault.owner(), thirdParty, "owner moved");
    }
}
