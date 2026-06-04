// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockCLGauge} from "./mocks/MockCLGauge.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {LPAutoBalancer} from "@contracts/LPAutoBalancer.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Mocks — inline (reusing same shape as LPAutoBalancerRebalance.unit.t.sol)
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Configurable mock for the destination pool's tickSpacing check.
contract MockDestCLPool is ICLPool {
    int24 public _tickSpacing;

    constructor(int24 ts) {
        _tickSpacing = ts;
    }

    function setTickSpacing(int24 ts) external {
        _tickSpacing = ts;
    }

    function tickSpacing() external view returns (int24) {
        return _tickSpacing;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (0, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata)
        external
        pure
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128 = new uint160[](2);
    }

    function token0() external pure returns (address) {
        return address(0);
    }

    function token1() external pure returns (address) {
        return address(0);
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }
}

/// @dev Source pool — ICLPool implementation used for the existing registered position.
///      tickSpacing is fixed at 200 (matches the registered slot).
contract MockSourceCLPool is ICLPool {
    function tickSpacing() external pure returns (int24) {
        return 200;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (0, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata)
        external
        pure
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128)
    {
        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128 = new uint160[](2);
    }

    function token0() external pure returns (address) {
        return address(0);
    }

    function token1() external pure returns (address) {
        return address(0);
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }
}

/// @dev Mock position manager for migrate tests.
///      Supports the full lifecycle: collect (two-slot: fees then principal),
///      decreaseLiquidity, mint, burn, approve, safeTransferFrom, ownerOf.
contract MockMigratePM {
    using SafeERC20 for IERC20;

    address public mockOwner;

    // approve
    address public lastApprovedTo;
    uint256 public lastApprovedTokenId;
    uint256 public approveCallCount;

    // burn
    uint256 public lastBurnedTokenId;
    uint256 public burnCallCount;

    // decreaseLiquidity
    uint256 public decreaseCallCount;

    // collect
    uint256 public collectCallCount;

    // mint
    uint256 public lastMintedTokenId;
    uint256 public mintCallCount;

    struct PositionData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address token0;
        address token1;
    }

    mapping(uint256 => PositionData) internal _positions;

    // Collect staging: slot 0 = skimFees, slot 1 = principal
    address public collectToken0;
    address public collectToken1;
    uint256[2] public collectAmounts0;
    uint256[2] public collectAmounts1;

    uint256 public nextMintTokenId;
    uint128 public nextMintLiquidity;

    constructor(address owner_) {
        mockOwner = owner_;
    }

    function setMockOwner(address owner_) external {
        mockOwner = owner_;
    }

    function setPosition(uint256 tokenId, int24 tl, int24 tu, uint128 liq, address t0, address t1) external {
        _positions[tokenId] = PositionData({tickLower: tl, tickUpper: tu, liquidity: liq, token0: t0, token1: t1});
    }

    function setCollectTokens(address t0, address t1) external {
        collectToken0 = t0;
        collectToken1 = t1;
    }

    /// slot=0 -> skimFees amounts; slot=1 -> principal amounts after decrease
    function setCollectSequence(uint256 fee0, uint256 fee1, uint256 princ0, uint256 princ1) external {
        collectAmounts0[0] = fee0;
        collectAmounts1[0] = fee1;
        collectAmounts0[1] = princ0;
        collectAmounts1[1] = princ1;
    }

    function setNextMintResult(uint256 newTokenId, uint128 liq) external {
        nextMintTokenId = newTokenId;
        nextMintLiquidity = liq;
        // Pre-register position so any post-mint lookup works
        _positions[newTokenId] =
            PositionData({tickLower: -100, tickUpper: 100, liquidity: liq, token0: address(0), token1: address(0)});
    }

    function ownerOf(uint256) external view returns (address) {
        return mockOwner;
    }

    function approve(address to, uint256 tokenId) external {
        lastApprovedTo = to;
        lastApprovedTokenId = tokenId;
        approveCallCount++;
    }

    function safeTransferFrom(address, address, uint256) external {}

    function burn(uint256 tokenId) external {
        lastBurnedTokenId = tokenId;
        burnCallCount++;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        PositionData storage pd = _positions[tokenId];
        return (0, address(0), pd.token0, pd.token1, 0, pd.tickLower, pd.tickUpper, pd.liquidity, 0, 0, 0, 0);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata)
        external
        returns (uint256, uint256)
    {
        decreaseCallCount++;
        return (0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 slot = collectCallCount < 2 ? collectCallCount : 1;
        collectCallCount++;

        amount0 = collectAmounts0[slot];
        amount1 = collectAmounts1[slot];

        if (amount0 > 0 && collectToken0 != address(0)) {
            IERC20(collectToken0).safeTransfer(params.recipient, amount0);
        }
        if (amount1 > 0 && collectToken1 != address(0)) {
            IERC20(collectToken1).safeTransfer(params.recipient, amount1);
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256, uint256)
    {
        mintCallCount++;
        tokenId = nextMintTokenId;
        liquidity = nextMintLiquidity;
        lastMintedTokenId = tokenId;
    }
}

/// @dev Minimal swap router stub.
contract MockMigrateSwapRouter is ISwapRouter {
    uint256 public amountOutToReturn;
    bool public wasCalled;

    function setAmountOutToReturn(uint256 a) external {
        amountOutToReturn = a;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256) {
        wasCalled = true;
        return amountOutToReturn;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("stub");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("stub");
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) {
        revert("stub");
    }
}

/// @dev Minimal quoter stub.
contract MockMigrateQuoter is IQuoter {
    uint256 public quotedOut;

    function setQuotedOut(uint256 a) external {
        quotedOut = a;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory)
        external
        view
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        return (quotedOut, 0, 0, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main test contract
// ─────────────────────────────────────────────────────────────────────────────

contract LPAutoBalancerMigrateTest is Test {
    LPAutoBalancer lab;
    MockMigratePM mockPM;
    MockSourceCLPool srcPool;
    MockDestCLPool destPool;
    MockCLGauge srcGauge;
    MockCLGauge destGauge;
    MockMigrateSwapRouter mockRouter;
    MockMigrateQuoter mockQuoter;
    MockERC20 mockAero;
    MockERC20 tok0;
    MockERC20 tok1;
    MockPriceFeed feed0;
    MockPriceFeed feed1;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address rebalancer = makeAddr("rebalancer");
    address guardian = makeAddr("guardian");
    address feeCollector = makeAddr("feeCollector");

    uint256 constant OLD_TOKEN_ID = 10;
    uint256 constant NEW_TOKEN_ID = 11;

    // Source pool tickSpacing = 200; dest pool tickSpacing = 100 (different pool, same pair for unit test)
    int24 constant SRC_TICK_SPACING = 200;
    int24 constant DEST_TICK_SPACING = 100;

    function setUp() public {
        tok0 = new MockERC20("Token0", "TK0");
        tok1 = new MockERC20("Token1", "TK1");
        mockAero = new MockERC20("Aerodrome", "AERO");

        srcPool = new MockSourceCLPool();
        destPool = new MockDestCLPool(DEST_TICK_SPACING);
        srcGauge = new MockCLGauge(address(mockAero));
        destGauge = new MockCLGauge(address(mockAero));
        mockRouter = new MockMigrateSwapRouter();
        mockQuoter = new MockMigrateQuoter();

        mockPM = new MockMigratePM(address(0));

        lab = new LPAutoBalancer(
            admin,
            manager,
            rebalancer,
            guardian,
            address(mockPM),
            address(mockRouter),
            address(mockQuoter),
            address(mockAero)
        );

        mockPM.setMockOwner(address(lab));

        feed0 = new MockPriceFeed(1e8, 8, block.timestamp);
        feed1 = new MockPriceFeed(1e8, 8, block.timestamp);

        // Set up old position in PM
        mockPM.setPosition(OLD_TOKEN_ID, -200, 200, 1e18, address(tok0), address(tok1));
        mockPM.setNextMintResult(NEW_TOKEN_ID, 1e18);
        mockPM.setCollectTokens(address(tok0), address(tok1));
    }

    // ---- helpers -------------------------------------------------------------

    function _registerSlot(bool withSrcGauge) internal returns (uint256 slotId) {
        LPAutoBalancer.ManagedPosition memory cfg = LPAutoBalancer.ManagedPosition({
            tokenId: OLD_TOKEN_ID,
            pool: address(srcPool),
            token0: address(tok0),
            token1: address(tok1),
            tickSpacing: SRC_TICK_SPACING,
            gauge: withSrcGauge ? address(srcGauge) : address(0),
            staked: false,
            feeCollector: feeCollector,
            oracle0: address(feed0),
            oracle1: address(feed1),
            swapPolicy: 0,
            protectedToken: address(0),
            minWidth: 200,
            maxWidth: 2000,
            maxCenterDeviation: 400,
            maxSlippageBps: 100,
            twapWindow: 1800,
            maxTickDeviation: 200,
            maxRebalanceLossBps: 100,
            minRebalanceInterval: 0,
            lastRebalance: 0,
            active: false
        });
        vm.prank(admin);
        slotId = lab.registerPosition(cfg);
    }

    /// @dev Build a valid MigrateParams for migrating to destPool (same pair, different spacing).
    ///      tickLower=-100, tickUpper=100 are aligned to DEST_TICK_SPACING=100.
    function _defaultMigrateParams() internal view returns (LPAutoBalancer.MigrateParams memory) {
        return LPAutoBalancer.MigrateParams({
            destPool: address(destPool),
            destToken0: address(tok0),
            destToken1: address(tok1),
            destTickSpacing: DEST_TICK_SPACING,
            destGauge: address(0),
            tickLower: -100,
            tickUpper: 100,
            swapTokenIn: address(tok0), // swapAmountIn=0 so token is unused but must be valid
            swapAmountIn: 0,
            swapMinAmountOut: 0,
            amount0MinDecrease: 0,
            amount1MinDecrease: 0,
            amount0MinMint: 0,
            amount1MinMint: 0,
            deadline: block.timestamp + 3600
        });
    }

    /// @dev Stage collect: slot 0 (skimFees) zero, slot 1 (principal) given amounts.
    ///      Mint tokens into PM so transfers succeed.
    function _stagePrincipal(uint256 princ0, uint256 princ1) internal {
        tok0.mint(address(mockPM), princ0);
        tok1.mint(address(mockPM), princ1);
        mockPM.setCollectSequence(0, 0, princ0, princ1);
    }

    // -------------------------------------------------------------------------
    // Test 1: Non-admin callers revert with AccessControlUnauthorizedAccount
    // -------------------------------------------------------------------------

    function test_migrate_revertNonAdmin() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);
        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();

        bytes32 adminRole = lab.DEFAULT_ADMIN_ROLE();

        // rebalancer cannot call migrate
        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rebalancer, adminRole)
        );
        lab.migrate(slotId, params);

        // manager cannot call migrate
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, adminRole)
        );
        lab.migrate(slotId, params);

        // random address cannot call migrate
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, rando, adminRole)
        );
        lab.migrate(slotId, params);
    }

    // -------------------------------------------------------------------------
    // Test 2: destPool not a contract -> InvalidConfig
    // -------------------------------------------------------------------------

    function test_migrate_revertDestPoolNotContract() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();
        params.destPool = makeAddr("notAContract"); // EOA, code.length == 0

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.migrate(slotId, params);
    }

    // -------------------------------------------------------------------------
    // Test 3: destTickSpacing mismatch -> InvalidConfig
    // -------------------------------------------------------------------------

    function test_migrate_revertTickSpacingMismatch() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        // destPool returns DEST_TICK_SPACING=100, but params says 200
        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();
        params.destTickSpacing = 200; // mismatch with destPool.tickSpacing()=100

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.migrate(slotId, params);
    }

    // -------------------------------------------------------------------------
    // Test 4: inverted ticks -> InvalidConfig
    // -------------------------------------------------------------------------

    function test_migrate_revertInvertedTicks() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();
        params.tickLower = 100;
        params.tickUpper = 100; // equal => invalid

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.migrate(slotId, params);
    }

    // -------------------------------------------------------------------------
    // Test 5: Happy path — unstaked, no swap, no destGauge
    // -------------------------------------------------------------------------

    function test_migrate_happy() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();

        vm.expectEmit(true, false, false, true);
        emit LPAutoBalancer.Migrated(slotId, address(srcPool), address(destPool), OLD_TOKEN_ID, NEW_TOKEN_ID);

        vm.prank(admin);
        lab.migrate(slotId, params);

        // slot updated to destination
        (
            uint256 storedTokenId,
            address storedPool,
            address storedToken0,
            address storedToken1,
            int24 storedTickSpacing,
            address storedGauge,
            bool storedStaked,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 storedLastRebalance,
        ) = lab.positions(slotId);

        assertEq(storedTokenId, NEW_TOKEN_ID, "tokenId not updated");
        assertEq(storedPool, address(destPool), "pool not updated");
        assertEq(storedToken0, address(tok0), "token0 not updated");
        assertEq(storedToken1, address(tok1), "token1 not updated");
        assertEq(storedTickSpacing, DEST_TICK_SPACING, "tickSpacing not updated");
        assertEq(storedGauge, address(0), "gauge should be address(0)");
        assertFalse(storedStaked, "staked should be false");
        assertEq(storedLastRebalance, block.timestamp, "lastRebalance not updated");

        // old NFT burned
        assertEq(mockPM.lastBurnedTokenId(), OLD_TOKEN_ID, "wrong burned token");
        assertEq(mockPM.burnCallCount(), 1, "burn not called once");

        // lab holds no token dust
        assertEq(tok0.balanceOf(address(lab)), 0, "lab holds tok0 dust");
        assertEq(tok1.balanceOf(address(lab)), 0, "lab holds tok1 dust");
    }

    // -------------------------------------------------------------------------
    // Test 6: With destGauge — restakes into destination gauge
    // -------------------------------------------------------------------------

    function test_migrate_withDestGauge_restakes() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();
        params.destGauge = address(destGauge);

        vm.expectEmit(true, true, true, true);
        emit LPAutoBalancer.Staked(slotId, NEW_TOKEN_ID, address(destGauge));

        vm.expectEmit(true, false, false, true);
        emit LPAutoBalancer.Migrated(slotId, address(srcPool), address(destPool), OLD_TOKEN_ID, NEW_TOKEN_ID);

        vm.prank(admin);
        lab.migrate(slotId, params);

        // staked = true, gauge = destGauge
        (,,,,, address storedGauge, bool storedStaked,,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertTrue(storedStaked, "should be staked after migration");
        assertEq(storedGauge, address(destGauge), "gauge not updated to destGauge");

        // destGauge.deposit was called with new token id
        assertEq(destGauge.lastDepositedTokenId(), NEW_TOKEN_ID, "destGauge deposit wrong tokenId");
        assertEq(destGauge.depositCallCount(), 1, "destGauge deposit not called once");
    }

    // -------------------------------------------------------------------------
    // Test 7: Staked in old gauge -> unstakes first, AERO forwarded to feeCollector
    // -------------------------------------------------------------------------

    function test_migrate_staked_unstakesFirst() public {
        uint256 slotId = _registerSlot(true); // withSrcGauge=true

        // Stake the position
        vm.prank(rebalancer);
        lab.stake(slotId);

        {
            (,,,,,, bool stakedBefore,,,,,,,,,,,,,,,) = lab.positions(slotId);
            assertTrue(stakedBefore, "should be staked before migrate");
        }

        // Gauge pays AERO on withdraw
        uint256 aeroAmount = 7e18;
        mockAero.mint(address(srcGauge), aeroAmount);
        srcGauge.setAeroToPayOnWithdraw(aeroAmount);

        _stagePrincipal(1e18, 1e18);

        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();

        vm.prank(admin);
        lab.migrate(slotId, params);

        // AERO forwarded to feeCollector during _unstake
        assertEq(mockAero.balanceOf(feeCollector), aeroAmount, "AERO not forwarded to feeCollector");
        assertEq(mockAero.balanceOf(address(lab)), 0, "lab should not hold AERO");

        // srcGauge.withdraw was called
        assertEq(srcGauge.withdrawCallCount(), 1, "srcGauge.withdraw not called");
        assertEq(srcGauge.lastWithdrawnTokenId(), OLD_TOKEN_ID, "wrong token unstaked");

        // migration completed — slot points to dest
        (uint256 storedTokenId, address storedPool,,,,, bool storedStaked,,,,,,,,,,,,,,,) = lab.positions(slotId);
        assertEq(storedTokenId, NEW_TOKEN_ID, "tokenId not updated after migrate-from-staked");
        assertEq(storedPool, address(destPool), "pool not updated after migrate-from-staked");
        assertFalse(storedStaked, "should not be staked (no destGauge)");
    }

    // -------------------------------------------------------------------------
    // Test 8: NotActive guard — inactive slot reverts
    // -------------------------------------------------------------------------

    function test_migrate_revertNotActive() public {
        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.NotActive.selector);
        lab.migrate(99, params); // slot 99 was never registered
    }

    // -------------------------------------------------------------------------
    // Test 9: zero dest token address -> InvalidConfig
    // -------------------------------------------------------------------------

    function test_migrate_revertZeroDestToken() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();
        params.destToken0 = address(0);

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.migrate(slotId, params);

        params.destToken0 = address(tok0);
        params.destToken1 = address(0);

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.migrate(slotId, params);
    }

    // -------------------------------------------------------------------------
    // Test 10: swapAmountIn > 0 but swapTokenIn is not a position token -> InvalidConfig
    // -------------------------------------------------------------------------

    function test_migrate_revertInvalidSwapTokenIn() public {
        uint256 slotId = _registerSlot(false);
        _stagePrincipal(1e18, 1e18);

        LPAutoBalancer.MigrateParams memory params = _defaultMigrateParams();
        params.swapAmountIn = 1e18;
        params.swapTokenIn = makeAddr("randomToken"); // neither tok0 nor tok1

        vm.prank(admin);
        vm.expectRevert(LPAutoBalancer.InvalidConfig.selector);
        lab.migrate(slotId, params);
    }
}
