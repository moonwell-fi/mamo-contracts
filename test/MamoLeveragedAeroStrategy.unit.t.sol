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

    /// @dev The caller picks the amount rather than the account sweeping everything. This is what
    ///      makes the share cap usable: an account holding more idle USDC than its remaining cap room
    ///      must still be able to deploy the part that fits, because the cap rejects rather than trims.
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

    // ==================== PER-ACCOUNT SHARE CAP ====================

    /// @dev `0` on the vault means unlimited, so the cap never blocks before the multisig acts.
    function testDepositUncappedWhenCapIsZero() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        assertEq(vault.maxSharesPerAccount(), 0, "unlimited by default");
        _deposit(strategy, user, DEPOSIT * 100);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES * 100, "no ceiling applied");
    }

    function testDepositExceedingTheCapReverts() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxSharesPerAccount(EXPECTED_SHARES); // room for exactly DEPOSIT

        usdc.mint(user, DEPOSIT * 2);
        vm.startPrank(user);
        usdc.approve(address(strategy), DEPOSIT * 2);
        vm.expectRevert("Share cap exceeded");
        strategy.deposit(DEPOSIT * 2, 0);
        vm.stopPrank();

        // The revert unwound everything: no shares minted, no USDC taken.
        assertEq(strategy.sharesBalance(), 0, "no shares minted");
        assertEq(usdc.balanceOf(user), DEPOSIT * 2, "no USDC moved");
    }

    /// @dev Landing EXACTLY on the cap is allowed — the bound is inclusive.
    function testDepositExactlyAtTheCapSucceeds() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxSharesPerAccount(EXPECTED_SHARES);
        _deposit(strategy, user, DEPOSIT);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES, "exactly at the cap");
    }

    function testDepositIdleExceedingTheCapRevertsAndLeavesIdleUntouched() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxSharesPerAccount(EXPECTED_SHARES);
        usdc.mint(address(strategy), DEPOSIT * 2);

        vm.prank(user);
        vm.expectRevert("Share cap exceeded");
        strategy.depositIdle(DEPOSIT * 2, 0);

        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT * 2, "idle untouched");
        assertEq(strategy.sharesBalance(), 0, "no shares minted");
    }

    /// @dev The pairing that makes the whole feature work: idle far above the cap room, but the
    ///      backend can still deploy the slice that fits.
    function testBackendCanDeployTheSliceThatFitsUnderTheCap() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxSharesPerAccount(EXPECTED_SHARES);
        usdc.mint(address(strategy), DEPOSIT * 10);

        vm.prank(backend);
        uint256 shares = strategy.depositIdle(DEPOSIT, 0);

        assertEq(shares, EXPECTED_SHARES, "the fitting slice went in");
        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT * 9, "the rest stayed idle");
    }

    /// @dev The cap is measured against the balance HELD, so an exit frees room with no bookkeeping.
    function testWithdrawingFreesCapRoom() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxSharesPerAccount(EXPECTED_SHARES);
        _deposit(strategy, user, DEPOSIT);

        // At the cap — a further deposit is refused.
        usdc.mint(user, DEPOSIT);
        vm.startPrank(user);
        usdc.approve(address(strategy), DEPOSIT);
        vm.expectRevert("Share cap exceeded");
        strategy.deposit(DEPOSIT, 0);

        // Exit half, then the same deposit fits.
        strategy.withdraw(EXPECTED_SHARES / 2, 0);
        strategy.deposit(DEPOSIT / 2, 0);
        vm.stopPrank();
        assertLe(strategy.sharesBalance(), EXPECTED_SHARES, "still within the cap");
    }

    /// @dev Lowering the cap under an existing position must not trap the holder: the cap gates new
    ///      deposits only and every withdrawal path ignores it.
    function testLoweringTheCapDoesNotTrapAnExistingPosition() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT * 4);

        vault.setMaxSharesPerAccount(EXPECTED_SHARES); // now far below the holding

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        strategy.withdrawAll(0);
        assertGt(usdc.balanceOf(user) - before, 0, "exit unaffected by the cap");
        assertEq(strategy.sharesBalance(), 0, "fully exited");
    }

    /**
     * @dev Pins the assumption the share-denominated cap rests on (design D1): shares minted to
     *      ANYONE ELSE — notably the fee recipient on a performance/management crystallise — do not
     *      touch this account's balance, and therefore cannot consume its cap room. If fee-shares
     *      ever started landing on accounts, a share cap would silently tighten on its own and this
     *      test is what would catch it.
     */
    function testFeeShareMintsDoNotConsumeAnAccountsCapRoom() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        vault.setMaxSharesPerAccount(EXPECTED_SHARES);
        _deposit(strategy, user, DEPOSIT / 2);
        uint256 heldBefore = strategy.sharesBalance();

        // The strategy mints fee-shares to a third-party recipient (what a crystallise does).
        vm.prank(address(sherwood));
        vault.strategyMint(thirdParty, EXPECTED_SHARES * 10);

        assertEq(strategy.sharesBalance(), heldBefore, "account balance untouched by a foreign mint");
        // ...and the account's remaining room is unchanged: the rest of its allowance still fits.
        _deposit(strategy, user, DEPOSIT / 2);
        assertEq(strategy.sharesBalance(), EXPECTED_SHARES, "cap room was never consumed");
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

    /// @notice Regression: an anonymous third party must NOT be able to force a fulfilled async
    ///         withdrawal back into the leveraged position (repeatable re-lock griefing) by front-running
    ///         the owner's {claimWithdrawnUsdc} with depositIdle(0). The owner's claim then succeeds.
    function testDepositIdleReLockGriefingBlocked() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        // Backend/keeper fulfills off-band; the withdrawal USDC lands idle on the wrapper.
        sherwood.fulfillRedeem(id);
        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT, "fulfilled USDC idle on wrapper");

        // Attacker front-runs the owner's claim to re-lock the funds — must revert.
        vm.prank(thirdParty);
        vm.expectRevert("Not owner or backend");
        strategy.depositIdle(DEPOSIT, 0);

        // Owner still claims the fulfilled withdrawal.
        vm.prank(user);
        uint256 amount = strategy.claimWithdrawnUsdc();
        assertEq(amount, DEPOSIT);
        assertEq(usdc.balanceOf(user), DEPOSIT, "owner claimed the fulfilled withdrawal");
        assertEq(strategy.sharesBalance(), 0, "not re-locked into the position");
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

    function testFulfillThenClaimWithdrawnUsdc() public {
        MamoLeveragedAeroStrategy strategy = _createStrategy(user);
        _deposit(strategy, user, DEPOSIT);

        vm.prank(user);
        uint256 id = strategy.requestWithdraw(EXPECTED_SHARES, DEPOSIT);

        // Backend/keeper fulfills off-band; USDC lands on the wrapper with no callback.
        sherwood.fulfillRedeem(id);
        assertEq(usdc.balanceOf(address(strategy)), DEPOSIT, "USDC on wrapper");

        vm.expectEmit(false, false, false, true, address(strategy));
        emit UsdcClaimed(DEPOSIT);

        vm.prank(user);
        uint256 amount = strategy.claimWithdrawnUsdc();

        assertEq(amount, DEPOSIT);
        assertEq(usdc.balanceOf(user), DEPOSIT, "owner swept");
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
}
