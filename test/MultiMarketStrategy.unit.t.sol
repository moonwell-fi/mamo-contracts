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

    /// @dev Underlying the market can actually hand back right now. Everything else is with
    ///      borrowers. Mirrors Compound: a redemption for more than this does NOT revert, it
    ///      returns the nonzero TOKEN_INSUFFICIENT_CASH error code.
    function getCash() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @dev Test hook: move `amount` of underlying out to a borrower, so getCash() < deposits.
    function lendOut(address borrower, uint256 amount) external {
        token.transfer(borrower, amount);
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        require(balanceOf[msg.sender] >= amount, "mToken: insufficient balance");
        if (token.balanceOf(address(this)) < amount) return 9; // TOKEN_INSUFFICIENT_CASH
        balanceOf[msg.sender] -= amount;
        token.transfer(msg.sender, amount);
        return 0;
    }

    function redeem(uint256 amount) external returns (uint256) {
        require(balanceOf[msg.sender] >= amount, "mToken: insufficient balance");
        if (token.balanceOf(address(this)) < amount) return 9; // TOKEN_INSUFFICIENT_CASH
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

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf[owner];
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

/// @dev Registry stand-in with a real BACKEND_ROLE member SET, not a single pinned address, so the
///      index-0 semantics that Sherlock #41 is about can be exercised: `getBackendAddress` still
///      reports member 0 and moves when a member is revoked, while `hasRole` — what the strategy
///      now gates on — does not.
contract MockStrategyRegistry {
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    address[] internal _backends;
    mapping(address => bool) internal _isBackend;

    constructor(address _operator) {
        _grant(_operator);
    }

    function grantBackend(address account) external {
        _grant(account);
    }

    /// @dev Mirrors EnumerableSet.remove: the LAST member is swapped into the vacated slot.
    function revokeBackend(address account) external {
        require(_isBackend[account], "not a backend");
        for (uint256 i = 0; i < _backends.length; i++) {
            if (_backends[i] == account) {
                _backends[i] = _backends[_backends.length - 1];
                _backends.pop();
                break;
            }
        }
        _isBackend[account] = false;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == BACKEND_ROLE && _isBackend[account];
    }

    function getBackendAddress() external view returns (address) {
        return _backends[0];
    }

    function _grant(address account) internal {
        if (_isBackend[account]) return;
        _isBackend[account] = true;
        _backends.push(account);
    }
}

contract MockSlippagePriceChecker {
    mapping(address => bool) internal _notReward;

    function setNotRewardToken(address token, bool notReward) external {
        _notReward[token] = notReward;
    }

    function isRewardToken(address token) external view returns (bool) {
        return !_notReward[token];
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
    function _rewardOrder() internal view returns (bytes memory) {
        return abi.encode(
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
    }

    /// @notice The fee gate applies exactly where the finite-allowance lock does not: a proxy
    ///         carrying a legacy unlimited approval to the CoW relayer. There, and only there, an
    ///         unsettled balance is genuinely reachable by a settlement.
    function test_isValidSignature_refusesUntilTheRewardFeeIsSettled_underLegacyAllowance() public {
        rewardToken.mint(address(strategy), 1000e18);

        // Recreate the pre-upgrade state: anchor at zero, relayer approved without limit.
        // Relayer address hoisted: an external call in argument position is evaluated FIRST and
        // would consume the one-shot prank, leaving the approval attributed to the test contract.
        address relayer = strategy.VAULT_RELAYER();
        vm.prank(address(strategy));
        rewardToken.approve(relayer, type(uint256).max);
        assertEq(strategy.rewardFeeCharged(address(rewardToken)), 0, "anchor should start at zero");

        vm.expectRevert("Reward fee not settled");
        strategy.isValidSignature(bytes32(0), _rewardOrder());

        strategy.sweepRewardFees(address(rewardToken));

        // The sweep re-arms the allowance AT the settled balance, so the gate stops applying and
        // the revert moves on to the ordinary order-binding check (the digest is deliberately wrong).
        vm.expectRevert("bad digest");
        strategy.isValidSignature(bytes32(0), _rewardOrder());
    }

    /// @notice Regression for the dust-donation grief. `pendingRewardFee` is a bps multiplication
    ///         that rounds down, so at compoundFee = 500 the tolerance is 19 wei and a 20-wei
    ///         donation used to round up to a nonzero owed fee and revert the solver's ENTIRE
    ///         batch — repeatable after every sweep for ~20 wei plus gas. What actually secures the
    ///         fee is the finite allowance, not the gate: whatever is donated after a sweep sits
    ///         outside the allowance and no settlement can reach it.
    function test_isValidSignature_dustDonationCannotBlockOrders() public {
        rewardToken.mint(address(strategy), 1000e18);
        strategy.sweepRewardFees(address(rewardToken));

        uint256 settled = rewardToken.balanceOf(address(strategy));
        assertEq(strategy.rewardFeeCharged(address(rewardToken)), settled, "anchor tracks settled balance");
        assertEq(rewardToken.allowance(address(strategy), strategy.VAULT_RELAYER()), settled, "allowance re-armed");

        // 20 wei is the first donation that rounds up to a nonzero owed fee at compoundFee = 500.
        rewardToken.mint(address(strategy), 20);
        assertGt(strategy.pendingRewardFee(address(rewardToken)), 0, "donation does owe a fee");

        // ...and the order is signable anyway: "bad digest" is the ordinary binding check, i.e. the
        // fee gate did not fire. The relayer's reach is unchanged at `settled`.
        vm.expectRevert("bad digest");
        strategy.isValidSignature(bytes32(0), _rewardOrder());
        assertEq(
            rewardToken.allowance(address(strategy), strategy.VAULT_RELAYER()),
            settled,
            "donation is outside the relayer's reach"
        );
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

    // ============ #37 (mToken leg): A FULLY LENT-OUT MARKET IS NOT A FAILED WITHDRAWAL ============

    address internal constant BORROWER = address(0xB0110E4);

    /// @dev Lend out the mToken's entire cash, so it owns the position but can pay nothing.
    function _drainMTokenCash() internal {
        mToken.lendOut(BORROWER, underlying.balanceOf(address(mToken)));
        assertEq(mToken.getCash(), 0, "market has no cash");
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 500e18, "strategy still owns its position");
    }

    /// @notice The headline case. 500/500 across the two markets, the Moonwell market fully lent
    ///         out, owner asks for 400 — an amount the VAULT leg alone covers comfortably. Capping
    ///         the mToken leg only by what the strategy owns made pass 1 ask for 200 the market
    ///         could not pay, and the unguarded `require(redeemUnderlying(...) == 0)` reverted the
    ///         whole call before pass 2 ever reached the vault that had the funds.
    function test_withdraw_succeedsWhenAnMTokenMarketIsOutOfCash() public {
        _deposit(1000e18);
        _drainMTokenCash();

        vm.prank(owner);
        strategy.withdraw(400e18);

        assertEq(underlying.balanceOf(owner), 400e18, "covered entirely from the liquid market");
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 500e18, "illiquid leg untouched");
    }

    /// @notice And when there genuinely is not enough liquidity anywhere, the failure is the
    ///         specific, actionable one rather than the venue's opaque error code.
    function test_withdraw_revertsWithLiquidityMessageWhenNoMarketCanPay() public {
        _deposit(1000e18);
        _drainMTokenCash();

        vm.prank(owner);
        vm.expectRevert("Withdrawal failed: insufficient market liquidity");
        strategy.withdraw(900e18);
    }

    /// @notice The finding's stated consolation — "withdrawAll can still recover the funds" — did
    ///         not hold: the redeem-everything path carried the same unguarded require. It is now
    ///         best-effort, draining what cash exists instead of reverting.
    function test_withdrawAll_drainsAvailableCashWhenAnMTokenIsIlliquid() public {
        _deposit(1000e18);
        // Half the mToken's cash is lent out: 250 recoverable, 250 stuck.
        mToken.lendOut(BORROWER, 250e18);

        vm.prank(owner);
        strategy.withdrawAll();

        assertEq(underlying.balanceOf(owner), 750e18, "vault leg plus the mToken's remaining cash");
        assertEq(mToken.balanceOfUnderlying(address(strategy)), 250e18, "the rest stays lent, still earning");
    }

    /// @notice updatePosition opens with the same sweep, so the revert also blocked every
    ///         rebalance — including the one that repairs splits after a deactivation.
    function test_updatePosition_survivesAnIlliquidMToken() public {
        _deposit(1000e18);
        _drainMTokenCash();

        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 2000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(vault), splitBps: 8000});

        vm.prank(backend);
        strategy.updatePosition(updates);

        assertEq(strategy.marketSplitBps(address(vault)), 8000, "splits applied");
        // The 500 that could be swept was re-split; the stuck 500 stayed in the mToken.
        assertEq(vault.balanceOf(address(strategy)), 400e18, "80% of the recovered balance");
    }

    // ==================== #41: THE BACKEND GATE IS MEMBERSHIP, NOT INDEX 0 ====================

    /// @notice `getBackendAddress()` is `getRoleMember(BACKEND_ROLE, 0)`, and EnumerableSet's
    ///         removal swaps the LAST member into the vacated slot. Revoking an unrelated member
    ///         therefore silently re-points index 0 — which, under the old gate, revoked the real
    ///         operator's access as a side effect of retiring something else.
    function test_backendGate_survivesAnUnrelatedRoleRevocation() public {
        address otherMember = makeAddr("retiredFactory");
        registry.grantBackend(otherMember);
        assertEq(registry.getBackendAddress(), backend, "operator starts at index 0");

        // This is the live topology in miniature: index 0 is held by one principal (today the
        // multicall), with factories behind it. Retiring the index-0 occupant swaps the LAST member
        // into slot 0, so `getBackendAddress()` now names a factory.
        registry.grantBackend(makeAddr("thirdMember"));
        registry.revokeBackend(backend);
        assertTrue(registry.getBackendAddress() != backend, "index 0 moved to a different principal");

        // Re-granting the operator puts it back in the SET but at the end, never at index 0 —
        // under the old gate it would have been permanently locked out with no way to get back in
        // short of revoking every other member. Membership is what the gate reads now.
        registry.grantBackend(backend);
        assertTrue(registry.getBackendAddress() != backend, "still not index 0");

        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(vault), splitBps: 5000});

        vm.prank(backend);
        strategy.updatePosition(updates); // would revert "Not backend" under the index-0 gate
    }

    function test_backendGate_rejectsANonMember() public {
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](2);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 5000});
        updates[1] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(vault), splitBps: 5000});

        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Not backend");
        strategy.updatePosition(updates);
    }

    /// @notice A second role member is a first-class backend, not a second-class one. This is the
    ///         semantic the factory already had; the strategy now agrees with it.
    function test_backendGate_acceptsAnyRoleMember() public {
        address secondOperator = makeAddr("secondOperator");
        registry.grantBackend(secondOperator);

        vm.prank(secondOperator);
        strategy.setFeeRecipient(makeAddr("newRecipient"));
        assertEq(strategy.feeRecipient(), makeAddr("newRecipient"));
    }

    // ==================== migrateV1ToMarketRegistry IS ONE-WAY ====================

    /// @notice A factory-created strategy sits at `_initialized == 1` with both legacy splits at
    ///         zero, so every branch of the migration was skipped and _validateTotalSplit passed
    ///         against the splits it was already initialized with. The owner could therefore
    ///         re-point `marketRegistry` at an arbitrary contract and spoof the market set, the
    ///         active flags and _getTotalBalance for that strategy.
    function test_migrateV1_cannotRepointAnAlreadyConfiguredStrategy() public {
        MarketRegistry hostile = new MarketRegistry(admin, backend, guardian);

        vm.prank(owner);
        vm.expectRevert("Market registry already set");
        strategy.migrateV1ToMarketRegistry(address(hostile));

        assertEq(address(strategy.marketRegistry()), address(marketRegistry), "registry unchanged");
    }

    // ==================== claimRewards SKIPS WHAT IT CANNOT SETTLE ====================

    /// @notice Merkl routinely pays a market's own asset, and a campaign can start paying a token
    ///         before the price checker is configured for it. Either one used to revert the entire
    ///         batch inside _requireRewardToken and strand every other reward in the call.
    function test_claimRewards_skipsUnsettleableTokensInsteadOfRevertingTheBatch() public {
        MockERC20 unconfigured = new MockERC20("Unconfigured", "UNC");
        priceChecker.setNotRewardToken(address(unconfigured), true);

        address[] memory tokens = new address[](3);
        tokens[0] = address(underlying); // the strategy's own asset
        tokens[1] = address(unconfigured); // priced by nothing yet
        tokens[2] = address(rewardToken); // the real reward
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        amounts[2] = 1000e18;
        bytes32[][] memory proofs = new bytes32[][](3);

        vm.prank(backend);
        strategy.claimRewards(tokens, amounts, proofs);

        // The settleable token was settled...
        uint256 expectedFee = (1000e18 * COMPOUND_FEE) / 10000;
        assertEq(rewardToken.balanceOf(feeRecipient), expectedFee, "fee charged on the real reward");
        // ...and the other two simply landed, untaxed and with no relayer allowance armed.
        assertEq(underlying.balanceOf(address(strategy)), 1e18, "underlying kept as principal");
        assertEq(unconfigured.balanceOf(address(strategy)), 2e18, "unconfigured token untouched");
        assertEq(unconfigured.allowance(address(strategy), strategy.VAULT_RELAYER()), 0, "relayer not armed");
    }

    /// @notice A market position is not yield. If an mToken or 4626 share ever picked up a price
    ///         checker entry, the permissionless sweep would tax 5% of the strategy's PRINCIPAL
    ///         shares and approve the relayer for the rest.
    function test_sweepRewardFees_rejectsAMarketShare() public {
        _deposit(1000e18);

        // The price checker says yes to everything unless told otherwise — the mistaken-entry state.
        vm.expectRevert("Market share is not a reward token");
        strategy.sweepRewardFees(address(mToken));

        vm.expectRevert("Market share is not a reward token");
        strategy.sweepRewardFees(address(vault));
    }

    // ==================== depositIdleTokens INSIDE THE DEACTIVATION WINDOW ====================

    /// @notice depositIdleTokens shares depositInternal with deposit(), so the #36 guard governs it
    ///         too: it must refuse while the active allocation is incomplete, and the idle balance
    ///         must survive the refusal rather than being partially placed.
    function test_depositIdleTokens_revertsWhileActiveSplitsAreIncomplete() public {
        vm.prank(backend);
        marketRegistry.deactivateMarket(address(underlying), address(vault));

        underlying.mint(address(strategy), 1000e18);

        vm.expectRevert("Split parameters must add up to SPLIT_TOTAL");
        strategy.depositIdleTokens();

        assertEq(underlying.balanceOf(address(strategy)), 1000e18, "idle balance intact");

        // Repairing the allocation unblocks it.
        MamoMultiMarketStrategy.MarketSplitUpdate[] memory updates = new MamoMultiMarketStrategy.MarketSplitUpdate[](1);
        updates[0] = MamoMultiMarketStrategy.MarketSplitUpdate({market: address(mToken), splitBps: 10000});
        vm.prank(backend);
        strategy.updatePosition(updates);

        assertEq(mToken.balanceOfUnderlying(address(strategy)), 1000e18, "re-deposited by updatePosition");
    }
}
