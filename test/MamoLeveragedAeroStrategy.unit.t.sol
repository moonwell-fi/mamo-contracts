// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoLeveragedAeroStrategy} from "@contracts/MamoLeveragedAeroStrategy.sol";
import {MamoLeveragedAeroStrategyFactory} from "@contracts/MamoLeveragedAeroStrategyFactory.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";

import {ILeveragedAeroCLStrategy} from "@interfaces/ILeveragedAeroCLStrategy.sol";

import {MockLeveragedAeroCLStrategy} from "./mocks/MockLeveragedAeroCLStrategy.sol";
import {MockSyndicateVault} from "./mocks/MockSyndicateVault.sol";
import {MockToken} from "./mocks/MockToken.sol";

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MamoLeveragedAeroStrategy unit tests
 * @notice Fork-free unit suite (runs under `make test-unit`) for the per-user wrapper account and its
 *         factory, exercised against mocks of the (undeployed) Sherwood vault + strategy.
 */
contract MamoLeveragedAeroStrategyUnitTest is Test {
    // ---- events mirrored from the production contracts (for vm.expectEmit) ----
    event Deposit(address indexed depositor, uint256 assets, uint256 shares);
    event Withdraw(address indexed owner, uint256 shares, uint256 assetsOut);
    event WithdrawRequested(uint256 indexed id, uint256 shares, uint256 minAssetsOut);
    event WithdrawCancelled(uint256 indexed id);
    event WithdrawEmergency(uint256 indexed id, uint256 assetsOut);
    event UsdcClaimed(uint256 amount);
    event StrategyCreated(address indexed user, address indexed strategy);
    event StrategyOwnerUpdated(address indexed strategy, address indexed oldOwner, address indexed newOwner);

    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public user = makeAddr("user");
    address public thirdParty = makeAddr("thirdParty");

    MockToken public usdc;
    MockSyndicateVault public vault;
    MockLeveragedAeroCLStrategy public sherwood;
    MamoStrategyRegistry public registry;
    MamoLeveragedAeroStrategy public impl;
    MamoLeveragedAeroStrategyFactory public factory;
    uint256 public typeId;

    // Convenience: 1000 USDC (6dp) deposits to 1000 whole shares (12dp) at par.
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant EXPECTED_SHARES = 1_000e12;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        vault = new MockSyndicateVault();
        sherwood = new MockLeveragedAeroCLStrategy(address(vault), address(usdc));
        vault.setStrategy(address(sherwood));

        registry = new MamoStrategyRegistry(admin, backend, guardian);

        impl = new MamoLeveragedAeroStrategy();

        vm.prank(admin);
        typeId = registry.whitelistImplementation(address(impl), 0);

        factory = new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(registry), address(impl), typeId, address(sherwood), address(usdc)
        );

        vm.prank(admin);
        registry.grantRole(BACKEND_ROLE, address(factory));
    }

    // ==================== HELPERS ====================

    function _createStrategy(address forUser) internal returns (MamoLeveragedAeroStrategy) {
        vm.prank(backend);
        address strategy = factory.createStrategyForUser(forUser);
        return MamoLeveragedAeroStrategy(payable(strategy));
    }

    /// @dev Funds `from` with `amount` USDC and approves the strategy to pull it.
    function _fundAndApprove(address from, address strategy, uint256 amount) internal {
        usdc.mint(from, amount);
        vm.prank(from);
        usdc.approve(strategy, amount);
    }

    function _deposit(MamoLeveragedAeroStrategy strategy, address from, uint256 amount)
        internal
        returns (uint256 shares)
    {
        _fundAndApprove(from, address(strategy), amount);
        vm.prank(from);
        shares = strategy.deposit(amount, 0);
    }

    // ==================== FACTORY: CREATE ====================

    function testCreateAsBackend() public {
        address predicted = factory.computeStrategyAddress(user);

        vm.expectEmit(true, true, false, true, address(factory));
        emit StrategyCreated(user, predicted);

        vm.prank(backend);
        address strategy = factory.createStrategyForUser(user);

        assertEq(strategy, predicted, "address mismatch");
        assertTrue(registry.isUserStrategy(user, strategy), "not registered");
        assertEq(MamoLeveragedAeroStrategy(payable(strategy)).owner(), user, "owner");
        assertEq(MamoLeveragedAeroStrategy(payable(strategy)).strategyTypeId(), typeId, "typeId");
        assertEq(ERC1967Proxy(payable(strategy)).getImplementation(), address(impl), "impl");
    }

    function testCreateAsUserThemselves() public {
        vm.prank(user);
        address strategy = factory.createStrategyForUser(user);
        assertTrue(registry.isUserStrategy(user, strategy));
    }

    function testCreateAsThirdPartyReverts() public {
        vm.prank(thirdParty);
        vm.expectRevert("Only backend or user can create strategy");
        factory.createStrategyForUser(user);
    }

    function testCreateDuplicateReverts() public {
        _createStrategy(user);

        vm.prank(backend);
        vm.expectRevert("Strategy already exists");
        factory.createStrategyForUser(user);
    }

    function testCreateZeroUserReverts() public {
        vm.prank(backend);
        vm.expectRevert("Invalid user address");
        factory.createStrategyForUser(address(0));
    }

    // ==================== FACTORY: CONSTRUCTOR VALIDATION ====================

    function testConstructorZeroAdminReverts() public {
        vm.expectRevert("Invalid admin address");
        new MamoLeveragedAeroStrategyFactory(
            address(0), backend, address(registry), address(impl), typeId, address(sherwood), address(usdc)
        );
    }

    function testConstructorZeroBackendReverts() public {
        vm.expectRevert("Invalid mamoBackend address");
        new MamoLeveragedAeroStrategyFactory(
            admin, address(0), address(registry), address(impl), typeId, address(sherwood), address(usdc)
        );
    }

    function testConstructorZeroRegistryReverts() public {
        vm.expectRevert("Invalid mamoStrategyRegistry address");
        new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(0), address(impl), typeId, address(sherwood), address(usdc)
        );
    }

    function testConstructorZeroImplementationReverts() public {
        vm.expectRevert("Invalid strategyImplementation address");
        new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(registry), address(0), typeId, address(sherwood), address(usdc)
        );
    }

    function testConstructorNonContractImplementationReverts() public {
        // makeAddr derives from a publicly-known private key; on a Base fork the well-known "eoa"
        // address carries an EIP-7702 delegation (non-empty code), so force-clear it to keep this
        // test deterministic in both fork and non-fork runs (CI's Basic Tests job forks Base).
        address eoa = makeAddr("eoa");
        vm.etch(eoa, "");

        vm.expectRevert("Implementation must be a contract");
        new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(registry), eoa, typeId, address(sherwood), address(usdc)
        );
    }

    function testConstructorZeroTypeIdReverts() public {
        vm.expectRevert("Strategy type id not set");
        new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(registry), address(impl), 0, address(sherwood), address(usdc)
        );
    }

    function testConstructorZeroSherwoodReverts() public {
        vm.expectRevert("Invalid sherwoodStrategy address");
        new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(registry), address(impl), typeId, address(0), address(usdc)
        );
    }

    function testConstructorZeroUsdcReverts() public {
        vm.expectRevert("Invalid usdc address");
        new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(registry), address(impl), typeId, address(sherwood), address(0)
        );
    }

    // ==================== DEPOSIT ====================

    function testDepositHappyPath() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _fundAndApprove(user, address(strategy), DEPOSIT);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit Deposit(user, DEPOSIT, EXPECTED_SHARES);

        vm.prank(user);
        uint256 shares = strategy.deposit(DEPOSIT, 0);

        assertEq(shares, EXPECTED_SHARES, "shares returned");
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES, "wrapper share balance");
        assertEq(vault.balanceOf(address(strategy)), EXPECTED_SHARES, "vault share balance");
        assertEq(usdc.balanceOf(user), 0, "USDC pulled");
        assertEq(usdc.balanceOf(address(sherwood)), DEPOSIT, "USDC held by sherwood");
    }

    function testDepositPermissionlessFromThirdParty() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _fundAndApprove(thirdParty, address(strategy), DEPOSIT);

        vm.prank(thirdParty);
        strategy.deposit(DEPOSIT, 0);

        // Shares are always custodied by the wrapper regardless of who funds.
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES);
    }

    function testDepositZeroAmountReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vm.prank(user);
        vm.expectRevert("Amount must be greater than 0");
        strategy.deposit(0, 0);
    }

    function testDepositMinSharesReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _fundAndApprove(user, address(strategy), DEPOSIT);

        vm.prank(user);
        vm.expectRevert("MockSherwood: min shares");
        strategy.deposit(DEPOSIT, EXPECTED_SHARES + 1);
    }

    function testDepositWhilePendingReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        sherwood.setState(ILeveragedAeroCLStrategy.State.Pending);
        _fundAndApprove(user, address(strategy), DEPOSIT);

        vm.prank(user);
        vm.expectRevert("MockSherwood: not executed");
        strategy.deposit(DEPOSIT, 0);
    }

    function testDepositWhileVaultPausedReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setPaused(true);
        _fundAndApprove(user, address(strategy), DEPOSIT);

        vm.prank(user);
        vm.expectRevert("MockVault: paused");
        strategy.deposit(DEPOSIT, 0);
    }

    // ==================== PARTIAL IDLE DEPOSIT ====================

    /// @dev The caller picks the amount, so an account can still deploy just the part that fits the cap.
    function testDepositIdleDepositsOnlyTheRequestedAmount() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        usdc.mint(address(strategy), DEPOSIT * 3);

        vm.prank(user);
        uint256 shares = strategy.depositIdle(DEPOSIT, 0);

        assertEq(shares, EXPECTED_SHARES, "only the requested amount was deposited");
        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT * 2, "the remainder stays idle");
    }

    /// @dev The idle remainder is not stranded — the owner's existing claim path still reaches it.
    function testIdleRemainderStaysOwnerWithdrawable() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        usdc.mint(address(strategy), DEPOSIT * 3);

        vm.prank(user);
        strategy.depositIdle(DEPOSIT, 0);

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        uint256 claimed = strategy.claimWithdrawnUsdc();
        assertEq(claimed, DEPOSIT * 2, "remainder claimable");
        assertEq(usdc.balanceOf(user) - before, DEPOSIT * 2, "paid to the owner");
    }

    function testDepositIdleAboveTheIdleBalanceReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        usdc.mint(address(strategy), DEPOSIT);

        vm.prank(user);
        vm.expectRevert("Insufficient idle USDC");
        strategy.depositIdle(DEPOSIT + 1, 0);
    }

    // ==================== FUND CAPACITY CAP ====================

    /// @dev `0` on the vault means unlimited, so capacity never blocks before the multisig acts.
    function testDepositUncappedWhenCapacityIsZero() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        assertEq(vault.maxTotalAssets(), 0, "unlimited by default");
        _deposit(strategy, user, DEPOSIT * 100);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES * 100, "no ceiling applied");
    }

    /// @dev The ceiling is on the FUND, not the account: a full book refuses a deposit from any account.
    function testDepositIsRefusedOnceTheFundIsFullEvenFromAnEmptyAccount() public {
        MamoLeveragedAeroStrategy first = _createStrategy(user);
        vault.setMaxTotalAssets(DEPOSIT); // capacity == exactly one DEPOSIT
        _deposit(first, user, DEPOSIT); // fund now full
        sherwood.setNav(DEPOSIT);

        MamoLeveragedAeroStrategy second = _createStrategy(thirdParty);
        usdc.mint(thirdParty, DEPOSIT);
        vm.startPrank(thirdParty);
        usdc.approve(address(second), DEPOSIT);
        vm.expectRevert();
        second.deposit(DEPOSIT, 0);
        vm.stopPrank();

        assertEq(second.sharesBalance(), 0, "no shares minted");
        assertEq(usdc.balanceOf(thirdParty), DEPOSIT, "no USDC moved");
    }

    /// @dev `depositIdle` funnels into the same vault deposit, and the revert leaves the idle withdrawable.
    function testDepositIdleIsRefusedOnceTheFundIsFullAndLeavesIdleUntouched() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxTotalAssets(DEPOSIT);
        _deposit(strategy, user, DEPOSIT); // fund now full
        sherwood.setNav(DEPOSIT);

        usdc.mint(address(strategy), DEPOSIT);

        vm.prank(user);
        vm.expectRevert();
        strategy.depositIdle(DEPOSIT, 0);

        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT, "idle untouched, not stranded");

        vm.prank(user);
        strategy.claimWithdrawnUsdc();
        assertEq(usdc.balanceOf(address(strategy)), 0, "owner recovered the idle USDC");
    }

    /// @dev Landing EXACTLY on the ceiling is allowed — the bound is inclusive.
    function testDepositExactlyAtCapacitySucceeds() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxTotalAssets(DEPOSIT);
        _deposit(strategy, user, DEPOSIT);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES, "exactly at capacity");
    }

    /// @dev Revert-don't-trim: a deposit that would CROSS the ceiling is rejected outright, not trimmed.
    function testDepositCrossingCapacityIsRejectedOutrightNotTrimmed() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxTotalAssets(DEPOSIT);

        usdc.mint(user, DEPOSIT * 2);
        vm.startPrank(user);
        usdc.approve(address(strategy), DEPOSIT * 2);
        vm.expectRevert();
        strategy.deposit(DEPOSIT * 2, 0);
        vm.stopPrank();

        assertEq(strategy.sharesBalance(), 0, "no shares minted");
        assertEq(usdc.balanceOf(user), DEPOSIT * 2, "no USDC moved");
        _deposit(strategy, user, DEPOSIT);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES, "the fitting amount goes in");
    }

    /// @dev Capacity gates DEPOSITS only: lowering it under a live book cannot unwind or trap anyone.
    function testLoweringCapacityDoesNotTrapExistingHolders() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT * 4);
        sherwood.setNav(DEPOSIT * 4);

        vault.setMaxTotalAssets(DEPOSIT); // now far below the live book

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        strategy.withdrawAll(0);
        assertGt(usdc.balanceOf(user) - before, 0, "exit unaffected by capacity");
        assertEq(strategy.sharesBalance(), 0, "fully exited");
    }

    /// @dev The ceiling is measured against live NAV, not a high-water mark, so withdrawing frees capacity.
    function testWithdrawingFreesCapacityForOtherDepositors() public {
        MamoLeveragedAeroStrategy first = _createStrategy(user);
        vault.setMaxTotalAssets(DEPOSIT);
        _deposit(first, user, DEPOSIT);
        sherwood.setNav(DEPOSIT); // full

        vm.prank(user);
        first.withdrawAll(0);
        sherwood.setNav(0); // the book emptied out

        MamoLeveragedAeroStrategy second = _createStrategy(thirdParty);
        _deposit(second, thirdParty, DEPOSIT);
        assertEq(second.sharesBalance(), EXPECTED_SHARES, "freed capacity is reusable");
    }

    // ==================== DEPOSIT IDLE ====================

    function testDepositIdleSweepsInDirectTransfer() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        // Plain-transfer USDC directly to the account (no approve/deposit).
        usdc.mint(address(strategy), DEPOSIT);

        vm.prank(user);
        uint256 shares = strategy.depositIdle(DEPOSIT, 0);

        assertEq(shares, EXPECTED_SHARES);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES);
        assertEq(usdc.balanceOf(address(strategy)), 0, "idle USDC swept");
    }

    function testDepositIdleEmptyReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vm.prank(user);
        vm.expectRevert("Amount must be greater than 0");
        strategy.depositIdle(0, 0);
    }

    function testDepositIdleAsBackendSucceeds() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        usdc.mint(address(strategy), DEPOSIT);

        // The registry backend (getBackendAddress) is a trusted actor and may nudge idle USDC in.
        assertEq(registry.getBackendAddress(), backend, "backend is registry backend");
        vm.prank(backend);
        uint256 shares = strategy.depositIdle(DEPOSIT, 0);

        assertEq(shares, EXPECTED_SHARES);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES);
        assertEq(usdc.balanceOf(address(strategy)), 0, "idle USDC swept");
    }

    function testDepositIdleAsThirdPartyReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        usdc.mint(address(strategy), DEPOSIT);

        vm.prank(thirdParty);
        vm.expectRevert("Not owner or backend");
        strategy.depositIdle(DEPOSIT, 0);
    }

    /// @notice The re-lock grief this used to guard against (front-run the owner's claim with depositIdle
    ///         and push a fulfilled withdrawal back into the leveraged position) is now STRUCTURALLY
    ///         impossible: the fulfil pays the owner in the same transaction, so there is never a window
    ///         in which the proceeds sit on the account waiting to be re-locked. The third-party access
    ///         control is still asserted, on a balance that is fresh money rather than proceeds.
    function testAFulfilledWithdrawalCannotBeReLockedBecauseItNeverRestsHere() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        // Backend/keeper fulfills off-band; the withdrawal USDC goes STRAIGHT to the owner.
        sherwood.fulfillRedeem(id, 0);
        assertEq(usdc.balanceOf(address(strategy)), 0, "no window: nothing rests on the wrapper");
        assertEq(usdc.balanceOf(user), DEPOSIT, "the owner already has it");
        assertEq(strategy.sharesBalance(), 0, "and the position is gone");

        // An anonymous third party still cannot nudge idle USDC in, proceeds or not.
        usdc.mint(address(strategy), DEPOSIT);
        vm.prank(thirdParty);
        vm.expectRevert("Not owner or backend");
        strategy.depositIdle(DEPOSIT, 0);
    }

    // ==================== WITHDRAW (FAST PATH) ====================

    function testWithdrawHappyPath() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit Withdraw(user, EXPECTED_SHARES, DEPOSIT);

        vm.prank(user);
        uint256 assetsOut = strategy.withdraw(EXPECTED_SHARES, DEPOSIT);

        assertEq(assetsOut, DEPOSIT, "assetsOut");
        assertEq(usdc.balanceOf(user), DEPOSIT, "owner paid");
        assertEq(strategy.sharesBalance(), 0, "shares burned");
    }

    function testWithdrawAllHappyPath() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 assetsOut = strategy.withdrawAll(DEPOSIT);

        assertEq(assetsOut, DEPOSIT);
        assertEq(usdc.balanceOf(user), DEPOSIT);
        assertEq(strategy.sharesBalance(), 0);
    }

    function testWithdrawProfitScenario() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        // 10% profit: each share worth more USDC. Fund the mock with the extra USDC to pay it out.
        sherwood.setPricePerShareE18(1.1e18);
        usdc.mint(address(sherwood), DEPOSIT); // ample liquidity

        uint256 expected = (DEPOSIT * 11) / 10;
        vm.prank(user);
        uint256 assetsOut = strategy.withdrawAll(expected);
        assertEq(assetsOut, expected, "profit paid out");
        assertEq(usdc.balanceOf(user), expected);
    }

    function testWithdrawOnlyOwnerReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", thirdParty));
        strategy.withdraw(EXPECTED_SHARES, 0);
    }

    function testWithdrawZeroSharesReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vm.prank(user);
        vm.expectRevert("Amount must be greater than 0");
        strategy.withdraw(0, 0);
    }

    function testWithdrawAllNoSharesReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vm.prank(user);
        vm.expectRevert("No shares to withdraw");
        strategy.withdrawAll(0);
    }

    function testWithdrawFastPathBlockedReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        sherwood.setFastPathBlocked(true);

        vm.prank(user);
        vm.expectRevert("FastRedeemExceedsLtv");
        strategy.withdraw(EXPECTED_SHARES, 0);
    }

    /// @notice Redemptions must keep working while the vault is paused: pausing gates deposits (mint) but
    ///         NOT burns, mirroring the real SyndicateVault where redeems stay open while paused.
    function testWithdrawWhileVaultPausedSucceeds() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vault.setPaused(true);

        vm.prank(user);
        uint256 assetsOut = strategy.withdraw(EXPECTED_SHARES, DEPOSIT);

        assertEq(assetsOut, DEPOSIT, "fast withdraw pays out while paused");
        assertEq(usdc.balanceOf(user), DEPOSIT, "owner paid while paused");
        assertEq(strategy.sharesBalance(), 0, "shares burned while paused");
    }

    function testWithdrawAllWhileVaultPausedSucceeds() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vault.setPaused(true);

        vm.prank(user);
        uint256 assetsOut = strategy.withdrawAll(DEPOSIT);

        assertEq(assetsOut, DEPOSIT, "withdrawAll pays out while paused");
        assertEq(usdc.balanceOf(user), DEPOSIT, "owner paid while paused");
        assertEq(strategy.sharesBalance(), 0, "shares burned while paused");
    }

    function testWithdrawMinAssetsOutReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        vm.expectRevert("MockSherwood: min assets out");
        strategy.withdraw(EXPECTED_SHARES, DEPOSIT + 1);
    }

    // ==================== ASYNC REDEEM ====================

    function testRequestWithdrawEscrowsShares() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit WithdrawRequested(0, EXPECTED_SHARES, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        assertEq(id, 0, "first id");
        assertEq(strategy.sharesBalance(), 0, "shares escrowed off the wrapper");
        assertEq(vault.balanceOf(address(sherwood)), EXPECTED_SHARES, "shares held by sherwood");
    }

    function testRequestWithdrawZeroReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vm.prank(user);
        vm.expectRevert("Amount must be greater than 0");
        strategy.requestWithdraw(0, 0);
    }

    function testRequestWithdrawOnlyOwnerReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", thirdParty));
        strategy.requestWithdraw(EXPECTED_SHARES, 0);
    }

    function testCancelWithdrawReturnsShares() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit WithdrawCancelled(id);

        vm.prank(user);
        strategy.cancelWithdraw(id);

        assertEq(strategy.sharesBalance(), EXPECTED_SHARES, "shares returned to wrapper");
    }

    /// @notice THE FIX. `requestWithdraw` names `owner()` as the pooled request's recipient, so the
    ///         backend's fulfil pays the user DIRECTLY — one transaction, no USDC parked on the account
    ///         and no second claim call. `claimWithdrawnUsdc` then has nothing to sweep.
    function testFulfillPaysTheOwnerDirectlyWithNoClaimStep() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        // Backend/keeper fulfills off-band; the payee is the account's owner, not the account.
        sherwood.fulfillRedeem(id, 0);

        assertEq(usdc.balanceOf(user), DEPOSIT, "owner paid by the fulfil itself");
        assertEq(usdc.balanceOf(address(strategy)), 0, "nothing parked on the account");

        vm.prank(user);
        vm.expectRevert("No USDC to claim");
        strategy.claimWithdrawnUsdc();
    }

    /// @notice The recipient stored on the pooled request IS the account's owner, so the payee is
    ///         observable off the pooled strategy without trusting the account's own bookkeeping.
    function testRequestWithdrawStoresTheOwnerAsTheRecipient() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        ILeveragedAeroCLStrategy.RedeemRequest memory r = sherwood.redeemRequest(id);
        assertEq(r.owner, address(strategy), "the ACCOUNT is the requester (it can cancel)");
        assertEq(r.recipient, user, "...and the USER is the payee");
    }

    /// @notice A fulfil never touches the escrowed-share side of the account: the shares leave at request
    ///         time and the payout skips the account entirely, so the account is left completely flat.
    function testFulfillLeavesTheAccountCompletelyFlat() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);
        sherwood.fulfillRedeem(id, 0);

        assertEq(strategy.sharesBalance(), 0, "no shares");
        assertEq(usdc.balanceOf(address(strategy)), 0, "no USDC");
    }

    function testClaimWithdrawnUsdcEmptyReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vm.prank(user);
        vm.expectRevert("No USDC to claim");
        strategy.claimWithdrawnUsdc();
    }

    function testEmergencyWithdrawBeforeWindowReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        vm.prank(user);
        vm.expectRevert("MockSherwood: fulfill window not elapsed");
        strategy.emergencyWithdraw(id, DEPOSIT);
    }

    function testEmergencyWithdrawAfterWindowForwardsToOwner() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        vm.warp(block.timestamp + 2 days + 1);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit WithdrawEmergency(id, DEPOSIT);

        vm.prank(user);
        uint256 assetsOut = strategy.emergencyWithdraw(id, DEPOSIT);

        assertEq(assetsOut, DEPOSIT);
        assertEq(usdc.balanceOf(user), DEPOSIT, "forwarded to owner");
    }

    // ==================== SETTLED STATE ====================

    function testSettledBlocksDepositWithdrawRequest() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        sherwood.setState(ILeveragedAeroCLStrategy.State.Settled);

        _fundAndApprove(user, address(strategy), DEPOSIT);
        vm.prank(user);
        vm.expectRevert("MockSherwood: not executed");
        strategy.deposit(DEPOSIT, 0);

        vm.prank(user);
        vm.expectRevert("MockSherwood: not executed");
        strategy.withdraw(EXPECTED_SHARES, 0);

        vm.prank(user);
        vm.expectRevert("MockSherwood: not executed");
        strategy.requestWithdraw(EXPECTED_SHARES, 0);
    }

    function testSettledStillAllowsCancel() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        sherwood.setState(ILeveragedAeroCLStrategy.State.Settled);

        vm.prank(user);
        strategy.cancelWithdraw(id);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES);
    }

    function testSettledOwnerCanRecoverShares() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        sherwood.setState(ILeveragedAeroCLStrategy.State.Settled);

        // Escape hatch: pull the raw vault shares out to the owner.
        vm.prank(user);
        strategy.recoverERC20(address(vault), user, EXPECTED_SHARES);

        assertEq(vault.balanceOf(user), EXPECTED_SHARES, "shares recovered to owner");
        assertEq(strategy.sharesBalance(), 0);
    }

    // ==================== OWNERSHIP / UPGRADE ====================

    function testTransferOwnershipMirrorsIntoRegistry() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        address newOwner = makeAddr("newOwner");

        vm.prank(user);
        strategy.transferOwnership(newOwner);

        assertEq(strategy.owner(), newOwner, "owner updated");
        assertFalse(registry.isUserStrategy(user, address(strategy)), "old owner cleared");
        assertTrue(registry.isUserStrategy(newOwner, address(strategy)), "new owner set");
    }

    function testUpgradeToSecondImplementation() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);

        MamoLeveragedAeroStrategy impl2 = new MamoLeveragedAeroStrategy();
        vm.prank(admin);
        registry.whitelistImplementation(address(impl2), typeId);

        vm.prank(user);
        registry.upgradeStrategy(address(strategy), address(impl2));

        assertEq(ERC1967Proxy(payable(address(strategy))).getImplementation(), address(impl2));
    }

    function testUpgradeByNonOwnerReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);

        MamoLeveragedAeroStrategy impl2 = new MamoLeveragedAeroStrategy();
        vm.prank(admin);
        registry.whitelistImplementation(address(impl2), typeId);

        vm.prank(thirdParty);
        vm.expectRevert("Caller is not the owner of the strategy");
        registry.upgradeStrategy(address(strategy), address(impl2));
    }

    // ==================== VIEWS ====================

    function testPreviewWithdrawPassThrough() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);

        (uint256 assetsOut, bool fastOk) = strategy.previewWithdraw(EXPECTED_SHARES);
        assertEq(assetsOut, DEPOSIT, "preview assets");
        assertTrue(fastOk, "fastOk when not blocked");

        sherwood.setFastPathBlocked(true);
        (, bool fastOk2) = strategy.previewWithdraw(EXPECTED_SHARES);
        assertFalse(fastOk2, "fastOk false when blocked");
    }

    function testStrategyStatePassThrough() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        assertEq(uint8(strategy.strategyState()), uint8(ILeveragedAeroCLStrategy.State.Executed));

        sherwood.setState(ILeveragedAeroCLStrategy.State.Settled);
        assertEq(uint8(strategy.strategyState()), uint8(ILeveragedAeroCLStrategy.State.Settled));
    }

    function testComputeStrategyAddressMatches() public {
        address predicted = factory.computeStrategyAddress(user);
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        assertEq(address(strategy), predicted);
    }

    // ====== THE BACKEND GATE, AFTER DIRECT-PAY FULFILS (the F11 finding's root cause is gone) ======
    //
    // F11 was "the backend can push a fulfilled withdrawal back into the leveraged position". Its
    // precondition was that a fulfil PARKED USDC on the account. Now the pooled strategy pays `owner()`
    // directly, so that precondition can never hold and the `"Unclaimed withdrawal proceeds"` gate is
    // gone. These tests pin the replacement invariant: no withdrawal proceeds ever rest here, so idle
    // USDC on the account is always fresh money the backend is meant to deposit — and a completed
    // request can never strand a tracked id.

    function _fulfilledRequest(MamoLeveragedAeroStrategy strategy) internal returns (uint256 id) {
        vm.prank(user);
        id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);
        sherwood.fulfillRedeem(id, 0);
    }

    /// @dev (1) THE ROOT-CAUSE FIX. A fulfil leaves the backend nothing to re-lock, because the proceeds
    ///      were paid to the owner and never touched this account.
    function testAFulfilLeavesNoProceedsForTheBackendToRedeposit() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        _fulfilledRequest(strategy);

        assertEq(usdc.balanceOf(user), DEPOSIT, "the owner was paid by the fulfil");
        assertEq(usdc.balanceOf(address(strategy)), 0, "nothing here for the backend to reach");

        // There is literally nothing to deposit; the amount check is the only thing that can fire.
        vm.prank(backend);
        vm.expectRevert("Amount must be greater than 0");
        strategy.depositIdle(0, 0);
    }

    /// @dev (2) An OUTSTANDING request holds shares escrowed on the pooled strategy, which the backend
    ///      cannot reach at all, so it must not gate the backend's ordinary duty.
    function testAnOutstandingRequestDoesNotBlockTheBackend() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        vm.prank(user);
        strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        usdc.mint(address(strategy), DEPOSIT);
        assertFalse(strategy.hasSettledRequest(), "nothing has settled yet");

        vm.prank(backend);
        uint256 shares = strategy.depositIdle(DEPOSIT, 0);
        assertEq(shares, EXPECTED_SHARES, "the backend's ordinary duty still works");
    }

    /// @dev (3) THE GATE-DEADLOCK REGRESSION. A settled request must never block the backend: with
    ///      direct-pay fulfils there is no claim to wait for, so a gate keyed on `settled` would shut
    ///      permanently. The backend's own call prunes and proceeds.
    function testASettledRequestDoesNotPermanentlyBlockTheBackend() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        _fulfilledRequest(strategy);

        // The completed id is still tracked, and NO owner call has happened to prune it.
        assertEq(strategy.openRequestIds().length, 1, "the completed id is still tracked");
        assertTrue(strategy.hasSettledRequest(), "...and reads settled");

        usdc.mint(address(strategy), DEPOSIT); // fresh money, plain-transferred in
        vm.prank(backend);
        uint256 shares = strategy.depositIdle(DEPOSIT, 0);

        assertEq(shares, EXPECTED_SHARES, "the backend was not blocked");
        assertEq(strategy.openRequestIds().length, 0, "and its call pruned the stale id");
        assertFalse(strategy.hasSettledRequest(), "nothing settled is tracked any more");
    }

    /// @dev (4) The owner's own nudge behaves identically — it prunes and is never gated.
    function testTheOwnerMayDepositIdleAfterAFulfilAndThatPrunes() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        _fulfilledRequest(strategy);

        usdc.mint(address(strategy), DEPOSIT);
        vm.prank(user);
        strategy.depositIdle(DEPOSIT, 0);

        assertFalse(strategy.hasSettledRequest(), "the owner's call pruned the settled id");
        assertEq(strategy.openRequestIds().length, 0, "...and untracked it");
    }

    /// @dev (5) A cancel returns SHARES, not USDC, so its id must stop being tracked — by id only.
    function testCancelUntracksItsOwnRequest() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);
        vm.prank(user);
        strategy.cancelWithdraw(id);

        assertEq(strategy.openRequestIds().length, 0, "cancelled id untracked");
        assertFalse(strategy.hasUnclaimedWithdrawal(), "and it never counted as unclaimed");
    }

    /// @dev (6) The emergency path pays the owner straight through, so its id is disposed of too.
    function testEmergencyWithdrawUntracksItsOwnRequest() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(user);
        strategy.emergencyWithdraw(id, DEPOSIT);

        assertEq(strategy.openRequestIds().length, 0, "emergency-redeemed id untracked");
        assertFalse(strategy.hasUnclaimedWithdrawal(), "nothing unclaimed: the owner was paid directly");
    }

    /// @dev (7) The `recoverERC20`-without-pruning deadlock is gone with the gate it deadlocked: draining
    ///      the account's USDC by the blunt hatch leaves a stale tracked id, and that blocks nothing.
    function testRecoverERC20LeavesAStaleIdThatBlocksNothing() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        _fulfilledRequest(strategy);

        usdc.mint(address(strategy), DEPOSIT); // unrelated idle USDC for the hatch to drain
        vm.prank(user);
        strategy.recoverERC20(address(usdc), user, DEPOSIT);
        assertTrue(strategy.hasSettledRequest(), "the completed id is still tracked");

        // Formerly the deadlock. The backend proceeds anyway, and prunes on the way through.
        usdc.mint(address(strategy), DEPOSIT);
        vm.prank(backend);
        strategy.depositIdle(DEPOSIT, 0);
        assertFalse(strategy.hasSettledRequest(), "pruned in passing");
    }

    /// @dev (8) Mixed idle needs no all-or-nothing rule any more: none of the account's idle USDC can be
    ///      withdrawal proceeds, so the backend deposits what it is asked to and leaves the rest.
    function testMixedIdleNoLongerBlocksTheBackend() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        _fulfilledRequest(strategy);

        usdc.mint(address(strategy), DEPOSIT * 2);

        vm.prank(backend);
        uint256 shares = strategy.depositIdle(DEPOSIT, 0);
        assertEq(shares, EXPECTED_SHARES, "the requested slice went in");
        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT, "the rest stays idle and owner-withdrawable");
    }

    function testPruneKeepsUnsettledIdsAndDropsSettledOnes() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT * 3);

        vm.startPrank(user);
        uint256 a = strategy.requestWithdraw(EXPECTED_SHARES, 0);
        uint256 b = strategy.requestWithdraw(EXPECTED_SHARES, 0);
        uint256 c = strategy.requestWithdraw(EXPECTED_SHARES, 0);
        vm.stopPrank();
        assertEq(strategy.openRequestIds().length, 3, "three tracked");

        sherwood.fulfillRedeem(a, 0);
        sherwood.fulfillRedeem(c, 0);

        vm.prank(user);
        strategy.syncRedeemRequests();

        uint256[] memory left = strategy.openRequestIds();
        assertEq(left.length, 1, "only the unsettled one survives");
        assertEq(left[0], b, "...and it is the right one");
        assertFalse(strategy.hasSettledRequest(), "nothing settled is tracked any more");
    }

    function testOpenRequestIdsTracksTheLifecycle() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        assertEq(strategy.openRequestIds().length, 0, "nothing tracked at rest");

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);
        uint256[] memory open = strategy.openRequestIds();
        assertEq(open.length, 1, "tracked on request");
        assertEq(open[0], id, "the id it returned");
        assertFalse(strategy.hasSettledRequest(), "outstanding != settled");

        sherwood.fulfillRedeem(id, 0);
        assertTrue(strategy.hasSettledRequest(), "fulfilled == settled: the frontend's completion signal");
        assertEq(strategy.openRequestIds().length, 1, "still tracked until the next call prunes");

        vm.prank(user);
        strategy.syncRedeemRequests();
        assertEq(strategy.openRequestIds().length, 0, "disposed of");
    }

    /// @dev The legacy name is retained for ABI compatibility and must keep agreeing with the accurate one.
    function testHasUnclaimedWithdrawalIsAnAliasOfHasSettledRequest() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);
        assertEq(strategy.hasUnclaimedWithdrawal(), strategy.hasSettledRequest(), "at rest");

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);
        assertEq(strategy.hasUnclaimedWithdrawal(), strategy.hasSettledRequest(), "outstanding");

        sherwood.fulfillRedeem(id, 0);
        assertTrue(strategy.hasUnclaimedWithdrawal(), "settled");
        assertEq(strategy.hasUnclaimedWithdrawal(), strategy.hasSettledRequest(), "settled");
    }

    /// @dev A completed request must not consume the {MAX_OPEN_REQUESTS} budget: with no claim step to
    ///      force a prune, a request-only user would otherwise be permanently locked out after 16 exits.
    function testSettledRequestsDoNotConsumeTheOpenRequestBudget() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        uint256 max = strategy.MAX_OPEN_REQUESTS();
        _deposit(strategy, user, DEPOSIT * (max + 1));

        // Fill the whole budget, THEN fulfil every one of them off-band — no owner call in between, so
        // nothing prunes and the tracked set is full of completed requests.
        uint256[] memory ids = new uint256[](max);
        for (uint256 i; i < max; ++i) {
            vm.prank(user);
            ids[i] = strategy.requestWithdraw(EXPECTED_SHARES, 0);
        }
        for (uint256 i; i < max; ++i) {
            sherwood.fulfillRedeem(ids[i], 0);
        }
        assertEq(strategy.openRequestIds().length, max, "all still tracked, all settled");

        // The next request prunes the completed ones instead of hitting the cap.
        vm.prank(user);
        strategy.requestWithdraw(EXPECTED_SHARES, 0);
        assertEq(strategy.openRequestIds().length, 1, "only the new, outstanding request is tracked");
    }

    /// @dev (11) The hatch is OWNER-only — a backend-callable prune would clear the backend's own gate.
    function testSyncRedeemRequestsIsOwnerOnly() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", backend));
        strategy.syncRedeemRequests();

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", thirdParty));
        strategy.syncRedeemRequests();
    }

    /// @dev (12) The tracked set is bounded, so the gate's scan cannot be griefed into unbounded gas.
    function testTooManyOpenRequestsIsRefused() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        uint256 max = strategy.MAX_OPEN_REQUESTS();
        _deposit(strategy, user, DEPOSIT * (max + 1));

        vm.startPrank(user);
        for (uint256 i; i < max; ++i) {
            strategy.requestWithdraw(EXPECTED_SHARES, 0);
        }
        vm.expectRevert("Too many open requests");
        strategy.requestWithdraw(EXPECTED_SHARES, 0);
        vm.stopPrank();

        assertEq(strategy.openRequestIds().length, max, "capped at the ceiling");
    }
}
