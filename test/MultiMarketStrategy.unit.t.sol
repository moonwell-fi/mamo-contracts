// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";
import {MarketRegistry} from "@contracts/MarketRegistry.sol";

import {Test} from "@forge-std/Test.sol";
import {MarketType} from "@interfaces/IMarketRegistry.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./MockERC20.sol";

// ==================== MOCKS ====================

/// @dev Minimal Moonwell mToken: 1:1 with the underlying, no interest.
contract MockMToken {
    MockERC20 public immutable token;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 _token) {
        token = _token;
    }

    function underlying() external view returns (address) {
        return address(token);
    }

    function mint(uint256 amount) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        return 0;
    }

    function balanceOfUnderlying(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        require(balanceOf[msg.sender] >= amount, "mToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
        return 0;
    }

    function redeem(uint256 amount) external returns (uint256) {
        require(balanceOf[msg.sender] >= amount, "mToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
        return 0;
    }
}

/// @dev Minimal ERC4626 with a configurable withdrawal fee. Shares are 1:1 with deposited assets,
///      so convertToAssets (fee-free, per EIP-4626) and previewRedeem (fee-inclusive) differ by
///      exactly the fee — which is the whole point of MOO-739.
contract MockERC4626Vault {
    MockERC20 public immutable token;
    uint256 public withdrawalFeeBps;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 _token) {
        token = _token;
    }

    function setWithdrawalFeeBps(uint256 feeBps) external {
        withdrawalFeeBps = feeBps;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares - (shares * withdrawalFeeBps) / 10000;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return previewRedeem(balanceOf[owner]);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), assets);
        balanceOf[receiver] += assets;
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        uint256 denominator = 10000 - withdrawalFeeBps;
        uint256 shares = (assets * 10000 + denominator - 1) / denominator;
        require(balanceOf[owner] >= shares, "vault: insufficient shares");
        balanceOf[owner] -= shares;
        token.transfer(receiver, assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(balanceOf[owner] >= shares, "vault: insufficient shares");
        uint256 assets = previewRedeem(shares);
        balanceOf[owner] -= shares;
        token.transfer(receiver, assets);
        return assets;
    }
}

contract MockStrategyRegistry {
    address public strategyOperator;

    constructor(address _operator) {
        strategyOperator = _operator;
    }

    function getBackendAddress() external view returns (address) {
        return strategyOperator;
    }
}

contract MockSlippagePriceChecker {
    function isRewardToken(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Stateless on purpose so it can be vm.etch'd at the hardcoded distributor address.
contract MockMerkleDistributor {
    function claim(
        address[] calldata accounts,
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata
    ) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            MockERC20(rewardTokens[i]).mint(accounts[i], rewardAmounts[i]);
        }
    }
}

// ==================== TESTS ====================

contract MultiMarketStrategyUnitTest is Test {
    address internal constant MERKLE_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    uint256 internal constant COMPOUND_FEE = 500; // 5%

    MamoMultiMarketStrategy public strategy;
    MarketRegistry public marketRegistry;
    MockStrategyRegistry public registry;
    MockSlippagePriceChecker public priceChecker;

    MockERC20 public underlying;
    MockERC20 public rewardToken;
    MockMToken public mToken;
    MockERC4626Vault public vault;

    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");
    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND");
        rewardToken = new MockERC20("Reward", "RWD");
        mToken = new MockMToken(underlying);
        vault = new MockERC4626Vault(underlying);

        registry = new MockStrategyRegistry(backend);
        priceChecker = new MockSlippagePriceChecker();
        marketRegistry = new MarketRegistry(admin, backend, guardian);

        vm.startPrank(backend);
        marketRegistry.addMarket(address(underlying), address(mToken), MarketType.MTOKEN);
        marketRegistry.addMarket(address(underlying), address(vault), MarketType.ERC4626);
        vm.stopPrank();

        vm.etch(MERKLE_DISTRIBUTOR, address(new MockMerkleDistributor()).code);

        uint256[] memory splits = new uint256[](2);
        splits[0] = 5000;
        splits[1] = 5000;
        strategy = _deployStrategy(splits);
    }

    function _deployStrategy(uint256[] memory splits) internal returns (MamoMultiMarketStrategy) {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(rewardToken);

        MamoMultiMarketStrategy implementation = new MamoMultiMarketStrategy();
        bytes memory data = abi.encodeWithSelector(
            MamoMultiMarketStrategy.initialize.selector,
            MamoMultiMarketStrategy.InitParams({
                mamoStrategyRegistry: address(registry),
                token: address(underlying),
                slippagePriceChecker: address(priceChecker),
                feeRecipient: feeRecipient,
                strategyTypeId: 1,
                rewardTokens: rewardTokens,
                owner: owner,
                hookGasLimit: 100000,
                allowedSlippageInBps: 100,
                compoundFee: COMPOUND_FEE,
                marketRegistry: address(marketRegistry),
                defaultSplitBps: splits
            })
        );

        return MamoMultiMarketStrategy(payable(address(new ERC1967Proxy(address(implementation), data))));
    }

    function _deposit(uint256 amount) internal {
        underlying.mint(owner, amount);
        vm.startPrank(owner);
        underlying.approve(address(strategy), amount);
        strategy.deposit(amount);
        vm.stopPrank();
    }

    function _claim(uint256 amount) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        vm.prank(backend);
        strategy.claimRewards(tokens, amounts, proofs);
    }

    // ==================== MOO-724: THE COMPOUND FEE IS ACTUALLY COLLECTED ====================

    /// @notice The fee is settled at claim time, in a state-changing call, not in a CoW pre-hook
    ///         that could never execute.
    function test_claimRewards_collectsFeeToRecipient() public {
        uint256 claimed = 1000e18;
        uint256 expectedFee = (claimed * COMPOUND_FEE) / 10000;

        _claim(claimed);

        assertEq(rewardToken.balanceOf(feeRecipient), expectedFee, "fee recipient paid exactly the compound fee");
        assertEq(rewardToken.balanceOf(address(strategy)), claimed - expectedFee, "strategy keeps the net amount");
    }

    /// @notice The second half of the finding: reward tokens are plain balances and
    ///         BaseStrategy.recoverERC20 is an unconditional owner exit. Collecting at claim time
    ///         means the owner can only ever reach the post-fee balance.
    function test_claimRewards_feeCannotBeReclaimedByOwner() public {
        uint256 claimed = 1000e18;
        uint256 expectedFee = (claimed * COMPOUND_FEE) / 10000;

        _claim(claimed);

        // The owner cannot sweep the fee: it is no longer held by the strategy.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(strategy), claimed - expectedFee, claimed
            )
        );
        strategy.recoverERC20(address(rewardToken), owner, claimed);

        vm.prank(owner);
        strategy.recoverERC20(address(rewardToken), owner, claimed - expectedFee);

        assertEq(rewardToken.balanceOf(owner), claimed - expectedFee, "owner only ever gets the net amount");
        assertEq(rewardToken.balanceOf(feeRecipient), expectedFee, "fee is untouched");
        assertEq(rewardToken.balanceOf(address(strategy)), 0);
    }

    /// @notice The whole point of MOO-724 / Sherlock #49: Merkl's `claim` is PERMISSIONLESS, so
    ///         anyone (the owner first among them) can pull this strategy's rewards straight from
    ///         the distributor and the tokens land here without claimRewards ever running. A fee
    ///         charged on the claimRewards delta is therefore charged on nothing.
    function test_rewardsArrivingOutsideClaimRewards_stillPayTheFee() public {
        uint256 arrived = 1000e18;
        uint256 expectedFee = (arrived * COMPOUND_FEE) / 10000;

        // Not a claimRewards call — the tokens simply show up, exactly as they would after a
        // third party called distributor.claim(strategy, ...).
        rewardToken.mint(address(strategy), arrived);
        assertEq(rewardToken.balanceOf(feeRecipient), 0, "nothing charged yet");
        assertEq(strategy.pendingRewardFee(address(rewardToken)), expectedFee, "the fee is owed");

        strategy.sweepRewardFees(address(rewardToken));

        assertEq(rewardToken.balanceOf(feeRecipient), expectedFee, "fee collected on the balance");
        assertEq(rewardToken.balanceOf(address(strategy)), arrived - expectedFee);
        assertEq(strategy.pendingRewardFee(address(rewardToken)), 0, "nothing left owing");
    }

    /// @notice A second sweep must not charge the same balance twice.
    function test_sweepRewardFees_isIdempotent() public {
        rewardToken.mint(address(strategy), 1000e18);

        strategy.sweepRewardFees(address(rewardToken));
        uint256 afterFirst = rewardToken.balanceOf(feeRecipient);

        assertEq(strategy.sweepRewardFees(address(rewardToken)), 0, "second sweep charges nothing");
        assertEq(rewardToken.balanceOf(feeRecipient), afterFirst, "fee recipient unchanged");
    }

    /// @notice The subtle half. Once a CoW order has drained the settled balance, the recorded
    ///         "already charged" anchor is stale-high, and the next batch of rewards would hide
    ///         behind it — permanently, since the owner controls when the permissionless claim
    ///         happens. The relayer allowance is what makes the outflow visible: it falls by
    ///         exactly what was pulled, and the sweep credits that against the anchor.
    function test_rewardsArrivingAfterASwap_stillPayTheFee() public {
        uint256 firstBatch = 1000e18;
        rewardToken.mint(address(strategy), firstBatch);
        strategy.sweepRewardFees(address(rewardToken));

        uint256 feeAfterFirst = rewardToken.balanceOf(feeRecipient);
        uint256 sellable = rewardToken.balanceOf(address(strategy));
        assertEq(
            rewardToken.allowance(address(strategy), strategy.VAULT_RELAYER()),
            sellable,
            "relayer armed at exactly the settled balance"
        );

        // CoW settles the order: the vault relayer pulls the whole sellable balance.
        vm.prank(strategy.VAULT_RELAYER());
        rewardToken.transferFrom(address(strategy), makeAddr("cowSettlement"), sellable);
        assertEq(rewardToken.balanceOf(address(strategy)), 0);

        // Next epoch's rewards land by the permissionless route, smaller than what just left.
        uint256 secondBatch = 400e18;
        uint256 expectedSecondFee = (secondBatch * COMPOUND_FEE) / 10000;
        rewardToken.mint(address(strategy), secondBatch);

        assertEq(strategy.pendingRewardFee(address(rewardToken)), expectedSecondFee, "second batch owes its fee");
        strategy.sweepRewardFees(address(rewardToken));

        assertEq(
            rewardToken.balanceOf(feeRecipient) - feeAfterFirst, expectedSecondFee, "second batch was charged in full"
        );
    }

    /// @notice The gate: no reward token can be swapped out while it still owes a fee.
    function test_isValidSignature_refusesUntilTheRewardFeeIsSettled() public {
        rewardToken.mint(address(strategy), 1000e18);

        bytes memory encodedOrder = abi.encode(
            GPv2Order.Data({
                sellToken: IERC20(address(rewardToken)),
                buyToken: IERC20(address(underlying)),
                receiver: address(strategy),
                sellAmount: 1000e18,
                buyAmount: 1,
                validTo: uint32(block.timestamp + 1 hours),
                appData: keccak256(bytes('{"appCode":"Mamo","metadata":{},"version":"1.3.0"}')),
                feeAmount: 0,
                kind: GPv2Order.KIND_SELL,
                partiallyFillable: false,
                sellTokenBalance: GPv2Order.BALANCE_ERC20,
                buyTokenBalance: GPv2Order.BALANCE_ERC20
            })
        );

        vm.expectRevert("Reward fee not settled");
        strategy.isValidSignature(bytes32(0), encodedOrder);

        strategy.sweepRewardFees(address(rewardToken));

        // Same order, same (deliberately wrong) digest: the fee gate no longer stops it, so the
        // revert moves on to the ordinary order-binding check.
        vm.expectRevert("bad digest");
        strategy.isValidSignature(bytes32(0), encodedOrder);
    }

    /// @notice Sherlock #49, the recovery route. recoverERC20 is an unconditional owner exit, so
    ///         it has to settle the fee before it hands anything over — and settle again after,
    ///         or the recovered amount would become free headroom for the next batch.
    function test_recoverERC20_cannotEscapeTheRewardFee() public {
        uint256 arrived = 1000e18;
        uint256 expectedFee = (arrived * COMPOUND_FEE) / 10000;
        rewardToken.mint(address(strategy), arrived);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(strategy), arrived - expectedFee, arrived
            )
        );
        strategy.recoverERC20(address(rewardToken), owner, arrived);

        vm.prank(owner);
        strategy.recoverERC20(address(rewardToken), owner, arrived - expectedFee);

        assertEq(rewardToken.balanceOf(feeRecipient), expectedFee, "fee was taken before the owner was paid");
        assertEq(rewardToken.balanceOf(owner), arrived - expectedFee, "owner only gets the remainder");
        assertEq(rewardToken.balanceOf(address(strategy)), 0);

        // The recovery must not leave headroom the next batch can hide behind.
        uint256 secondBatch = 300e18;
        rewardToken.mint(address(strategy), secondBatch);
        assertEq(
            strategy.pendingRewardFee(address(rewardToken)),
            (secondBatch * COMPOUND_FEE) / 10000,
            "the batch after a recovery still owes its fee"
        );
    }

    function test_sweepRewardFees_rejectsTheStrategyToken() public {
        // Approving the CoW relayer on the underlying would put every user deposit in reach of an
        // order, so the strategy's own asset can never be settled as a reward.
        vm.expectRevert("Not a reward token");
        strategy.sweepRewardFees(address(underlying));
    }

    function test_claimRewards_repeatedClaimsChargeOnlyTheNewDelta() public {
        _claim(1000e18);
        _claim(400e18);

        assertEq(rewardToken.balanceOf(feeRecipient), (1400e18 * COMPOUND_FEE) / 10000);
        assertEq(rewardToken.balanceOf(address(strategy)), 1400e18 - (1400e18 * COMPOUND_FEE) / 10000);
    }

    // ==================== MOO-738(a): DEPOSIT DOES NOT MISALLOCATE ====================

    /// @notice With a market deactivated the active splits no longer total 10,000. The
    ///         last-market branch is a dust sink; letting it run here would hand it the whole
    ///         allocation of the deactivated market instead of the 50% it is configured for.
    function test_deposit_revertsWhileActiveSplitsAreIncomplete() public {
        _deposit(1000e18);

        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(vault));

        underlying.mint(owner, 1000e18);
        vm.startPrank(owner);
        underlying.approve(address(strategy), 1000e18);
        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        strategy.deposit(1000e18);
        vm.stopPrank();

        // The mToken keeps exactly its configured half — nothing was over-allocated to it.
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 500e18);
    }

    /// @notice The zero-balance branch. A strategy that happens to hold nothing when a market is
    ///         deactivated is stuck: deposit() refuses to run while the active splits are
    ///         incomplete, and updatePosition() is the only way to complete them — so if it also
    ///         refuses at zero balance the strategy can never be funded again. Note this is not
    ///         reachable by funding first: the sibling test below is the funded path, which is
    ///         exactly the branch that hid this.
    function test_updatePosition_repairsSplitsOnAnUnfundedStrategy() public {
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(vault));

        // Nothing was ever deposited.
        assertEq(underlying.balanceOf(address(strategy)), 0);

        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 10000});
        vm.prank(backend);
        strategy.updatePosition(updates);

        assertEq(strategy.marketSplitBps(address(mToken)), 10000, "splits repaired");
        assertEq(strategy.marketSplitBps(address(vault)), 0, "deactivated market zeroed");

        // And the strategy is usable again.
        _deposit(1000e18);
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 1000e18);
    }

    function test_deposit_worksAgainOnceAllocationIsRestored() public {
        _deposit(1000e18);

        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(vault));

        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 10000});
        vm.prank(backend);
        strategy.updatePosition(updates);

        _deposit(1000e18);
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 2000e18);
    }

    // ==================== MOO-738(b) + MOO-739: WITHDRAW SURVIVES REAL BALANCES ====================

    /// @notice A 1% ERC4626 exit fee makes the vault leg unable to deliver its configured share.
    ///         The pro-rata loop must cap at capacity and carry the shortfall, not revert.
    function test_withdraw_withErc4626ExitFee() public {
        vault.setWithdrawalFeeBps(100); // 1%
        _deposit(1000e18);

        // 500 in the mToken, 500 of shares in the vault worth 495 after the exit fee.
        uint256 deliverable = 500e18 + 495e18;

        vm.prank(owner);
        strategy.withdraw(deliverable);

        assertEq(underlying.balanceOf(owner), deliverable, "owner receives the full requested amount");
    }

    /// @notice MOO-739: the total must be the amount the shares can actually deliver. With
    ///         convertToAssets the strategy would have accepted 1000e18 here and then reverted
    ///         inside the vault.
    function test_withdraw_totalBalanceIsNetOfExitFees() public {
        vault.setWithdrawalFeeBps(100);
        _deposit(1000e18);

        vm.prank(owner);
        vm.expectRevert("Withdrawal amount exceeds available balance in strategy");
        strategy.withdraw(1000e18);
    }

    /// @notice During the deactivate-then-updatePosition window the active splits describe only
    ///         part of the position. The sweep pass must reach the inactive market's funds.
    function test_withdraw_duringDeactivationWindow() public {
        _deposit(1000e18);

        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(vault));

        vm.prank(owner);
        strategy.withdraw(800e18);

        assertEq(underlying.balanceOf(owner), 800e18, "withdraw covered from wherever the funds are");
    }

    /// @notice Balance drift alone used to be enough: an mToken holding slightly less than its
    ///         configured share made the fixed pro-rata split revert.
    function test_withdraw_withBalanceDrift() public {
        _deposit(1000e18);

        // Simulate the vault leg having grown relative to the mToken leg.
        vm.prank(address(strategy));
        mToken.redeemUnderlying(100e18);
        vm.prank(address(strategy));
        underlying.approve(address(vault), 100e18);
        vm.prank(address(strategy));
        vault.deposit(100e18, address(strategy));

        assertEq(mToken.balanceOfUnderlying(address(strategy)), 400e18);
        assertEq(vault.balanceOf(address(strategy)), 600e18);

        vm.prank(owner);
        strategy.withdraw(900e18);

        assertEq(underlying.balanceOf(owner), 900e18);
    }

    function test_withdrawAll_stillDrainsEverything() public {
        vault.setWithdrawalFeeBps(100);
        _deposit(1000e18);

        vm.prank(owner);
        strategy.withdrawAll();

        assertEq(underlying.balanceOf(owner), 995e18);
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 0);
        assertEq(vault.balanceOf(address(strategy)), 0);
    }

    // ==================== MOO-724: ORDER VALIDATION NO LONGER PINS A FEE HOOK ====================

    function test_expectedAppData_hasNoHooks() public view {
        (string memory doc, bytes32 hash) = strategy.expectedAppData();
        assertEq(doc, '{"appCode":"Mamo","metadata":{},"version":"1.3.0"}');
        assertEq(hash, keccak256(bytes(doc)));
    }
}
