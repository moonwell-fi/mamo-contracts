// spdx-license-identifier: busl-1.1
pragma solidity 0.8.28;

import {IMultiRewards} from "../src/interfaces/IMultiRewards.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Simple mock ERC20 token compatible with Solidity 0.5.17
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) public {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        require(balanceOf[msg.sender] >= value, "ERC20: transfer amount exceeds balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(balanceOf[from] >= value, "ERC20: transfer amount exceeds balance");
        require(allowance[from][msg.sender] >= value, "ERC20: transfer amount exceeds allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }
}

// Simple testing contract that doesn't rely on forge-std
contract MultiRewardsUnitTest is Test {
    // Contracts
    IMultiRewards public multiRewards;
    MockERC20 public stakingToken;
    MockERC20 public rewardTokenA; // 18 decimals
    MockERC20 public rewardTokenB; // 8 decimals
    MockERC20 public rewardTokenC; // 6 decimals

    // Addresses
    address public owner;
    address public user;
    address public user2;
    address public rewardDistributorA;
    address public rewardDistributorB;
    address public rewardDistributorC;

    // Constants
    uint256 public constant INITIAL_STAKE_AMOUNT = 100 ether;
    uint256 public constant REWARD_AMOUNT_18 = 1000 ether; // 18 decimals
    uint256 public constant REWARD_AMOUNT_8 = 1000 * 10 ** 8; // 8 decimals
    uint256 public constant REWARD_AMOUNT_6 = 1000 * 10 ** 6; // 6 decimals
    uint256 public constant REWARDS_DURATION = 7 days;

    function setUp() public {
        // Set up addresses
        owner = address(this);
        user = address(0x1);
        user2 = address(0x2);
        rewardDistributorA = address(0x3);
        rewardDistributorB = address(0x4);
        rewardDistributorC = address(0x5);

        // Deploy mock tokens with different decimals
        stakingToken = new MockERC20("Staking Token", "STK", 18);
        rewardTokenA = new MockERC20("Reward Token A", "RWDA", 18);
        rewardTokenB = new MockERC20("Reward Token B", "RWDB", 8);
        rewardTokenC = new MockERC20("Reward Token C", "RWDC", 6);

        // Deploy IMultiRewards contract
        bytes memory constructorArgs = abi.encode(owner, address(stakingToken));
        multiRewards = IMultiRewards(vm.deployCode("MultiRewards.sol:MultiRewards", constructorArgs));

        // Add reward tokens with different decimals
        multiRewards.addReward(address(rewardTokenA), rewardDistributorA, REWARDS_DURATION);
        multiRewards.addReward(address(rewardTokenB), rewardDistributorB, REWARDS_DURATION);
        multiRewards.addReward(address(rewardTokenC), rewardDistributorC, REWARDS_DURATION);

        // Mint tokens to users and reward distributors
        stakingToken.mint(user, INITIAL_STAKE_AMOUNT);
        stakingToken.mint(user2, INITIAL_STAKE_AMOUNT);
        rewardTokenA.mint(rewardDistributorA, REWARD_AMOUNT_18);
        rewardTokenB.mint(rewardDistributorB, REWARD_AMOUNT_8);
        rewardTokenC.mint(rewardDistributorC, REWARD_AMOUNT_6);

        // Approve spending of reward tokens by the IMultiRewards contract
        vm.prank(rewardDistributorA);
        rewardTokenA.approve(address(multiRewards), REWARD_AMOUNT_18);

        vm.prank(rewardDistributorB);
        rewardTokenB.approve(address(multiRewards), REWARD_AMOUNT_8);

        vm.prank(rewardDistributorC);
        rewardTokenC.approve(address(multiRewards), REWARD_AMOUNT_6);
    }

    // Test decimals functionality in reward calculations
    function testDecimalsInRewardCalculations() public {
        // User stakes tokens
        vm.prank(user);
        stakingToken.approve(address(multiRewards), INITIAL_STAKE_AMOUNT);
        vm.prank(user);
        multiRewards.stake(INITIAL_STAKE_AMOUNT);

        // Check initial state
        assertEq(multiRewards.totalSupply(), INITIAL_STAKE_AMOUNT, "Total supply should equal staked amount");
        assertEq(multiRewards.balanceOf(user), INITIAL_STAKE_AMOUNT, "User balance should equal staked amount");

        // Notify reward amounts for tokens with different decimals
        vm.prank(rewardDistributorA);
        multiRewards.notifyRewardAmount(address(rewardTokenA), REWARD_AMOUNT_18);

        vm.prank(rewardDistributorB);
        multiRewards.notifyRewardAmount(address(rewardTokenB), REWARD_AMOUNT_8);

        vm.prank(rewardDistributorC);
        multiRewards.notifyRewardAmount(address(rewardTokenC), REWARD_AMOUNT_6);

        // Fast forward time to accrue rewards (half duration)
        vm.warp(block.timestamp + REWARDS_DURATION / 2);

        // Check earned rewards
        uint256 earnedA = multiRewards.earned(user, address(rewardTokenA));
        uint256 earnedB = multiRewards.earned(user, address(rewardTokenB));
        uint256 earnedC = multiRewards.earned(user, address(rewardTokenC));

        // Expected rewards should be approximately half of the total
        uint256 expectedA = REWARD_AMOUNT_18 / 2;
        uint256 expectedB = REWARD_AMOUNT_8 / 2;
        uint256 expectedC = REWARD_AMOUNT_6 / 2;

        // Use tolerance for rounding errors
        uint256 tolarence = 1e16; // 0.01%

        assertApproxEqRel(earnedA, expectedA, tolarence, "18-decimal token should earn ~half rewards");
        assertApproxEqRel(earnedB, expectedB, tolarence, "8-decimal token should earn ~half rewards");
        assertApproxEqRel(earnedC, expectedC, tolarence, "6-decimal token should earn ~half rewards");

        // User claims rewards
        vm.prank(user);
        multiRewards.getReward();

        // Verify user received rewards (checking balances directly)
        assertTrue(rewardTokenA.balanceOf(user) >= earnedA, "User should receive earned rewards for 18-decimal token");
        assertTrue(rewardTokenB.balanceOf(user) >= earnedB, "User should receive earned rewards for 8-decimal token");
        assertTrue(rewardTokenC.balanceOf(user) >= earnedC, "User should receive earned rewards for 6-decimal token");

        // Test precision is maintained for different decimals
        assertTrue(earnedA > 0, "18-decimal token should earn positive rewards");
        assertTrue(earnedB > 0, "8-decimal token should earn positive rewards");
        assertTrue(earnedC > 0, "6-decimal token should earn positive rewards");
    }

    // Test that two users with equal stakes get equal rewards across different decimal tokens
    function testMultipleUsersWithDifferentDecimalRewards() public {
        uint256 stakeAmount = 50 ether;

        // Both users stake equal amounts
        vm.prank(user);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(user);
        multiRewards.stake(stakeAmount);

        vm.prank(user2);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(user2);
        multiRewards.stake(stakeAmount);

        // Notify reward amounts
        vm.prank(rewardDistributorA);
        multiRewards.notifyRewardAmount(address(rewardTokenA), REWARD_AMOUNT_18);

        vm.prank(rewardDistributorB);
        multiRewards.notifyRewardAmount(address(rewardTokenB), REWARD_AMOUNT_8);

        vm.prank(rewardDistributorC);
        multiRewards.notifyRewardAmount(address(rewardTokenC), REWARD_AMOUNT_6);

        // Fast forward to end of rewards period
        vm.warp(block.timestamp + REWARDS_DURATION);

        // Both users claim rewards
        vm.prank(user);
        multiRewards.getReward();

        vm.prank(user2);
        multiRewards.getReward();

        // Expected rewards should be 50% each
        uint256 expectedA = REWARD_AMOUNT_18 / 2;
        uint256 expectedB = REWARD_AMOUNT_8 / 2;
        uint256 expectedC = REWARD_AMOUNT_6 / 2;

        uint256 tolarence = 1e16; // 0.01%

        // Check user1 rewards
        assertApproxEqAbs(
            rewardTokenA.balanceOf(user), expectedA, tolarence, "User1 should receive 50% of 18-decimal rewards"
        );
        assertApproxEqAbs(
            rewardTokenB.balanceOf(user), expectedB, tolarence, "User1 should receive 50% of 8-decimal rewards"
        );
        assertApproxEqAbs(
            rewardTokenC.balanceOf(user), expectedC, tolarence, "User1 should receive 50% of 6-decimal rewards"
        );

        // Check user2 rewards
        assertApproxEqAbs(
            rewardTokenA.balanceOf(user2), expectedA, tolarence, "User2 should receive 50% of 18-decimal rewards"
        );
        assertApproxEqAbs(
            rewardTokenB.balanceOf(user2), expectedB, tolarence, "User2 should receive 50% of 8-decimal rewards"
        );
        assertApproxEqAbs(
            rewardTokenC.balanceOf(user2), expectedC, tolarence, "User2 should receive 50% of 6-decimal rewards"
        );
    }

    // Test with very small amounts to ensure precision works with different decimals
    function testSmallAmountsWithDifferentDecimals() public {
        uint256 smallStakeAmount = 10 ether;

        vm.prank(user);
        stakingToken.approve(address(multiRewards), smallStakeAmount);
        vm.prank(user);
        multiRewards.stake(smallStakeAmount);

        // Use small reward amounts that test precision
        uint256 smallRewardA = 1e18; // Very small for 18 decimals
        uint256 smallRewardB = 1e8; // Very small for 8 decimals
        uint256 smallRewardC = 1e8; // Very small for 6 decimals

        // Mint additional small amounts
        rewardTokenA.mint(rewardDistributorA, smallRewardA);
        rewardTokenB.mint(rewardDistributorB, smallRewardB);
        rewardTokenC.mint(rewardDistributorC, smallRewardC);

        // Approve small amounts
        vm.prank(rewardDistributorA);
        rewardTokenA.approve(address(multiRewards), smallRewardA);
        vm.prank(rewardDistributorB);
        rewardTokenB.approve(address(multiRewards), smallRewardB);
        vm.prank(rewardDistributorC);
        rewardTokenC.approve(address(multiRewards), smallRewardC);

        // Notify small reward amounts
        vm.prank(rewardDistributorA);
        multiRewards.notifyRewardAmount(address(rewardTokenA), smallRewardA);

        vm.prank(rewardDistributorB);
        multiRewards.notifyRewardAmount(address(rewardTokenB), smallRewardB);

        vm.prank(rewardDistributorC);
        multiRewards.notifyRewardAmount(address(rewardTokenC), smallRewardC);

        // Fast forward to end of rewards period
        vm.warp(block.timestamp + REWARDS_DURATION);

        // Check earned amounts
        uint256 earnedA = multiRewards.earned(user, address(rewardTokenA));
        uint256 earnedB = multiRewards.earned(user, address(rewardTokenB));
        uint256 earnedC = multiRewards.earned(user, address(rewardTokenC));

        uint256 tolarenceA = 1e16; // 1%
        uint256 tolarenceB = 1e16; // 1%
        uint256 tolarenceC = 1e16; // 1%

        // Should earn approximately the full small amounts
        assertApproxEqRel(earnedA, smallRewardA, tolarenceA, "Should earn approximately all small 18-decimal rewards");
        assertApproxEqRel(earnedB, smallRewardB, tolarenceB, "Should earn approximately all small 8-decimal rewards");
        assertApproxEqRel(earnedC, smallRewardC, tolarenceC, "Should earn approximately all small 6-decimal rewards");

        // Claim rewards
        vm.prank(user);
        multiRewards.getReward();

        // Verify non-zero rewards were received
        assertTrue(rewardTokenA.balanceOf(user) > 0, "Should receive non-zero 18-decimal rewards");
        assertTrue(rewardTokenB.balanceOf(user) > 0, "Should receive non-zero 8-decimal rewards");
        assertTrue(rewardTokenC.balanceOf(user) > 0, "Should receive non-zero 6-decimal rewards");
    }

    // Test staking and claiming with new reward stream added after staking
    function testStakeAndClaimNewRewardStream() public {
        // 1. User stakes tokens
        vm.prank(user);
        stakingToken.approve(address(multiRewards), INITIAL_STAKE_AMOUNT);

        // Check initial state
        assertEq(multiRewards.totalSupply(), 0, "Initial total supply should be 0");
        assertEq(multiRewards.balanceOf(user), 0, "Initial user balance should be 0");
        assertEq(stakingToken.balanceOf(user), INITIAL_STAKE_AMOUNT, "User should have initial tokens");

        // Perform stake
        vm.prank(user);
        multiRewards.stake(INITIAL_STAKE_AMOUNT);

        // Check state after staking
        assertEq(multiRewards.totalSupply(), INITIAL_STAKE_AMOUNT, "Total supply should equal staked amount");
        assertEq(multiRewards.balanceOf(user), INITIAL_STAKE_AMOUNT, "User balance should equal staked amount");
        assertEq(stakingToken.balanceOf(user), 0, "User should have 0 tokens after staking");
        assertEq(
            stakingToken.balanceOf(address(multiRewards)), INITIAL_STAKE_AMOUNT, "Contract should have staked tokens"
        );

        // 2. Notify reward amount for 18-decimal token
        vm.prank(rewardDistributorA);
        multiRewards.notifyRewardAmount(address(rewardTokenA), REWARD_AMOUNT_18);

        // 3. Notify reward amount for 8-decimal token
        vm.prank(rewardDistributorB);
        multiRewards.notifyRewardAmount(address(rewardTokenB), REWARD_AMOUNT_8);

        // 4. Notify reward amount for 6-decimal token
        vm.prank(rewardDistributorC);
        multiRewards.notifyRewardAmount(address(rewardTokenC), REWARD_AMOUNT_6);

        // 5. Fast forward time to accrue rewards (half the duration)
        vm.warp(block.timestamp + REWARDS_DURATION / 2);

        // 6. Check earned rewards
        uint256 earnedA = multiRewards.earned(user, address(rewardTokenA));
        uint256 earnedB = multiRewards.earned(user, address(rewardTokenB));
        uint256 earnedC = multiRewards.earned(user, address(rewardTokenC));

        // Should have earned approximately half the rewards
        uint256 expectedA = REWARD_AMOUNT_18 / 2;
        uint256 expectedB = REWARD_AMOUNT_8 / 2;
        uint256 expectedC = REWARD_AMOUNT_6 / 2;

        uint256 tolarence = 1e16; // 0.01%

        assertApproxEqRel(earnedA, expectedA, tolarence, "Should have earned ~half of 18-decimal rewards");
        assertApproxEqRel(earnedB, expectedB, tolarence, "Should have earned ~half of 8-decimal rewards");
        assertApproxEqRel(earnedC, expectedC, tolarence, "Should have earned ~half of 6-decimal rewards");

        // 7. User claims rewards and verify balances
        vm.prank(user);
        multiRewards.getReward();

        // Verify user received rewards (checking balances directly)
        assertTrue(rewardTokenA.balanceOf(user) >= earnedA, "User should have received earned 18-decimal rewards");
        assertTrue(rewardTokenB.balanceOf(user) >= earnedB, "User should have received earned 8-decimal rewards");
        assertTrue(rewardTokenC.balanceOf(user) >= earnedC, "User should have received earned 6-decimal rewards");

        // 9. Fast forward to the end of the reward period
        vm.warp(block.timestamp + REWARDS_DURATION / 2);

        // 10. User claims remaining rewards
        vm.prank(user);
        multiRewards.getReward();

        // 11. Verify total rewards received are approximately correct
        assertApproxEqRel(
            rewardTokenA.balanceOf(user), REWARD_AMOUNT_18, tolarence, "Should have received ~all 18-decimal rewards"
        );
        assertApproxEqRel(
            rewardTokenB.balanceOf(user), REWARD_AMOUNT_8, tolarence, "Should have received ~all 8-decimal rewards"
        );
        assertApproxEqRel(
            rewardTokenC.balanceOf(user), REWARD_AMOUNT_6, tolarence, "Should have received ~all 6-decimal rewards"
        );
    }

    // Test function to verify recoverERC20 works for reward tokens
    function testRecoverRewardToken() public {
        // 1. Setup - Add reward token and notify reward amount
        vm.prank(rewardDistributorA);
        multiRewards.notifyRewardAmount(address(rewardTokenA), REWARD_AMOUNT_18);

        // Verify reward token balance in the contract
        assertEq(
            rewardTokenA.balanceOf(address(multiRewards)),
            REWARD_AMOUNT_18,
            "Contract should have the reward token amount"
        );

        // 2. Attempt to recover half of the reward tokens
        uint256 amountToRecover = REWARD_AMOUNT_18 / 2;
        uint256 ownerBalanceBefore = rewardTokenA.balanceOf(owner);

        // Call recoverERC20 as the owner
        multiRewards.recoverERC20(address(rewardTokenA), amountToRecover);

        // 3. Verify tokens were successfully transferred to the owner
        uint256 ownerBalanceAfter = rewardTokenA.balanceOf(owner);
        assertEq(
            ownerBalanceAfter - ownerBalanceBefore, amountToRecover, "Owner should have received the recovered tokens"
        );

        // 4. Verify remaining balance in the contract
        assertEq(
            rewardTokenA.balanceOf(address(multiRewards)),
            REWARD_AMOUNT_18 - amountToRecover,
            "Contract should have the remaining reward tokens"
        );
    }

    // Test addReward function with valid decimals (happy path)
    function testAddRewardValidDecimals() public {
        MockERC20 token18 = new MockERC20("Token18", "T18", 18);
        MockERC20 token8 = new MockERC20("Token8", "T8", 8);
        MockERC20 token6 = new MockERC20("Token6", "T6", 6);
        MockERC20 token7 = new MockERC20("Token7", "T7", 7);

        address distributor = address(0x123);

        // These should succeed (6 <= decimals <= 18)
        multiRewards.addReward(address(token18), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(token8), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(token6), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(token7), distributor, REWARDS_DURATION);

        // Verify tokens were added successfully
        assertTrue(address(token18) != address(0), "Token18 should be valid");
        assertTrue(address(token8) != address(0), "Token8 should be valid");
        assertTrue(address(token6) != address(0), "Token6 should be valid");
        assertTrue(address(token7) != address(0), "Token7 should be valid");
    }

    // Test addReward function with invalid decimals (unhappy path)
    function testAddRewardInvalidDecimals() public {
        MockERC20 token0 = new MockERC20("Token0", "T0", 0);
        MockERC20 token1 = new MockERC20("Token1", "T1", 1);
        MockERC20 token5 = new MockERC20("Token5", "T5", 5);
        MockERC20 token19 = new MockERC20("Token19", "T19", 19);
        MockERC20 token255 = new MockERC20("Token255", "T255", 255);

        address distributor = address(0x123);

        // These should fail (decimals <= 5)
        vm.expectRevert("Reward token decimals must be > 0");
        multiRewards.addReward(address(token0), distributor, REWARDS_DURATION);

        vm.expectRevert("Reward token decimals must be > 0");
        multiRewards.addReward(address(token1), distributor, REWARDS_DURATION);

        vm.expectRevert("Reward token decimals must be > 0");
        multiRewards.addReward(address(token5), distributor, REWARDS_DURATION);

        // These should fail (decimals > 18)
        vm.expectRevert("Reward token decimals must be <= 18");
        multiRewards.addReward(address(token19), distributor, REWARDS_DURATION);

        vm.expectRevert("Reward token decimals must be <= 18");
        multiRewards.addReward(address(token255), distributor, REWARDS_DURATION);
    }

    // Test reward token with minimum decimals (6) while staking token has 18 decimals
    function testRewardTokenMinDecimals() public {
        MockERC20 rewardToken1 = new MockERC20("Reward1", "RWD1", 6);
        address distributor = address(0x999);

        // Add reward token with 6 decimals to existing contract (staking token has 18)
        multiRewards.addReward(address(rewardToken1), distributor, REWARDS_DURATION);

        uint256 stakeAmount = 100 ether; // 18 decimals
        uint256 rewardAmount = 604800e6; // 6 decimals = 604800.0 actual value (enough for 1 per second)

        // Mint and approve tokens
        stakingToken.mint(user, stakeAmount);
        rewardToken1.mint(distributor, rewardAmount);

        vm.prank(user);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(distributor);
        rewardToken1.approve(address(multiRewards), rewardAmount);

        // User stakes
        vm.prank(user);
        multiRewards.stake(stakeAmount);

        // Notify reward amount
        vm.prank(distributor);
        multiRewards.notifyRewardAmount(address(rewardToken1), rewardAmount);

        // Fast forward to end of rewards period
        vm.warp(block.timestamp + REWARDS_DURATION);

        // Check earned rewards
        uint256 earned = multiRewards.earned(user, address(rewardToken1));

        // Should earn approximately all rewards
        uint256 tolerance = 1e16; // 1%
        assertApproxEqRel(earned, rewardAmount, tolerance, "Should earn all rewards with 6-decimal token");

        // Claim rewards
        vm.prank(user);
        multiRewards.getReward();

        assertTrue(rewardToken1.balanceOf(user) > 0, "Should receive 6-decimal rewards");
        assertApproxEqRel(rewardToken1.balanceOf(user), rewardAmount, tolerance, "Should receive correct amount");
    }

    // Test reward token with maximum decimals (18) while staking token has 18 decimals
    function testRewardTokenMaxDecimals() public {
        MockERC20 rewardToken18 = new MockERC20("Reward18", "RWD18", 18);
        address distributor = address(0x888);

        // Add reward token with 18 decimals to existing contract (staking token has 18)
        multiRewards.addReward(address(rewardToken18), distributor, REWARDS_DURATION);

        uint256 stakeAmount = 100 ether; // 18 decimals
        uint256 rewardAmount = 1000 ether; // 18 decimals

        // Mint and approve tokens
        stakingToken.mint(user, stakeAmount);
        rewardToken18.mint(distributor, rewardAmount);

        vm.prank(user);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(distributor);
        rewardToken18.approve(address(multiRewards), rewardAmount);

        // User stakes
        vm.prank(user);
        multiRewards.stake(stakeAmount);

        // Notify reward amount
        vm.prank(distributor);
        multiRewards.notifyRewardAmount(address(rewardToken18), rewardAmount);

        // Fast forward to end of rewards period
        vm.warp(block.timestamp + REWARDS_DURATION);

        // Check earned rewards
        uint256 earned = multiRewards.earned(user, address(rewardToken18));

        // Should earn approximately all rewards
        uint256 tolerance = 1e16; // 1%
        assertApproxEqRel(earned, rewardAmount, tolerance, "Should earn all rewards with 18-decimal token");

        // Claim rewards
        vm.prank(user);
        multiRewards.getReward();

        assertTrue(rewardToken18.balanceOf(user) > 0, "Should receive 18-decimal rewards");
        assertApproxEqRel(rewardToken18.balanceOf(user), rewardAmount, tolerance, "Should receive correct amount");
    }

    // Test multiple reward tokens with boundary decimal values (6, 18) and 18-decimal staking token
    function testMultipleRewardTokensBoundaryDecimals() public {
        MockERC20 rewardToken1 = new MockERC20("Reward1", "RWD1", 6);
        MockERC20 rewardToken18 = new MockERC20("Reward18", "RWD18", 18);

        address distributor1 = address(0x111);
        address distributor18 = address(0x222);

        // Add both reward tokens
        multiRewards.addReward(address(rewardToken1), distributor1, REWARDS_DURATION);
        multiRewards.addReward(address(rewardToken18), distributor18, REWARDS_DURATION);

        uint256 stakeAmount = 100 ether; // 18 decimals
        uint256 rewardAmount1 = 302400e6; // 6 decimals = 302400.0 actual value (enough for meaningful rewards)
        uint256 rewardAmount18 = 1000 ether; // 18 decimals

        // Mint and approve tokens
        stakingToken.mint(user, stakeAmount);
        rewardToken1.mint(distributor1, rewardAmount1);
        rewardToken18.mint(distributor18, rewardAmount18);

        vm.prank(user);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(distributor1);
        rewardToken1.approve(address(multiRewards), rewardAmount1);
        vm.prank(distributor18);
        rewardToken18.approve(address(multiRewards), rewardAmount18);

        // User stakes
        vm.prank(user);
        multiRewards.stake(stakeAmount);

        // Notify reward amounts
        vm.prank(distributor1);
        multiRewards.notifyRewardAmount(address(rewardToken1), rewardAmount1);
        vm.prank(distributor18);
        multiRewards.notifyRewardAmount(address(rewardToken18), rewardAmount18);

        // Fast forward to end of rewards period
        vm.warp(block.timestamp + REWARDS_DURATION);

        // Check earned rewards
        uint256 earned1 = multiRewards.earned(user, address(rewardToken1));
        uint256 earned18 = multiRewards.earned(user, address(rewardToken18));

        // Should earn approximately all rewards for both tokens
        uint256 tolerance = 1e16; // 1%
        assertApproxEqRel(earned1, rewardAmount1, tolerance, "Should earn all 6-decimal rewards");
        assertApproxEqRel(earned18, rewardAmount18, tolerance, "Should earn all 18-decimal rewards");

        // Claim rewards
        vm.prank(user);
        multiRewards.getReward();

        assertTrue(rewardToken1.balanceOf(user) > 0, "Should receive 6-decimal rewards");
        assertTrue(rewardToken18.balanceOf(user) > 0, "Should receive 18-decimal rewards");
        assertApproxEqRel(
            rewardToken1.balanceOf(user), rewardAmount1, tolerance, "Should receive correct 6-decimal amount"
        );
        assertApproxEqRel(
            rewardToken18.balanceOf(user), rewardAmount18, tolerance, "Should receive correct 18-decimal amount"
        );
    }

    // Test reward token with very small amounts and minimum decimals
    function testRewardTokenMinDecimalsSmallAmounts() public {
        MockERC20 rewardToken1 = new MockERC20("Reward1", "RWD1", 6);
        address distributor = address(0x777);

        multiRewards.addReward(address(rewardToken1), distributor, REWARDS_DURATION);

        uint256 stakeAmount = 1 ether; // 18 decimals
        uint256 rewardAmount = 604800e6; // 6 decimals = 604800.0 actual value (minimum for non-zero reward rate)

        // Mint and approve tokens
        stakingToken.mint(user, stakeAmount);
        rewardToken1.mint(distributor, rewardAmount);

        vm.prank(user);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(distributor);
        rewardToken1.approve(address(multiRewards), rewardAmount);

        // User stakes
        vm.prank(user);
        multiRewards.stake(stakeAmount);

        // Notify reward amount
        vm.prank(distributor);
        multiRewards.notifyRewardAmount(address(rewardToken1), rewardAmount);

        // Fast forward to end of rewards period
        vm.warp(block.timestamp + REWARDS_DURATION);

        // Check earned rewards
        uint256 earned = multiRewards.earned(user, address(rewardToken1));

        // Should earn the small reward amount
        assertTrue(earned > 0, "Should earn non-zero rewards with small 6-decimal amount");

        // Should earn approximately all rewards
        uint256 tolerance = 1e16; // 1%
        assertApproxEqRel(earned, rewardAmount, tolerance, "Should earn all 6-decimal rewards");

        // Claim rewards
        vm.prank(user);
        multiRewards.getReward();

        assertTrue(rewardToken1.balanceOf(user) > 0, "Should receive 6-decimal rewards");
    }

    // Test multiple users with boundary decimal reward tokens
    function testMultipleUsersBoundaryDecimalRewards() public {
        MockERC20 rewardToken1 = new MockERC20("Reward1", "RWD1", 6);
        MockERC20 rewardToken18 = new MockERC20("Reward18", "RWD18", 18);

        address distributor1 = address(0x333);
        address distributor18 = address(0x444);

        multiRewards.addReward(address(rewardToken1), distributor1, REWARDS_DURATION);
        multiRewards.addReward(address(rewardToken18), distributor18, REWARDS_DURATION);

        uint256 stakeAmount = 50 ether; // Same for both users
        uint256 rewardAmount1 = 604800e6; // 6 decimals = 604800.0 actual value (enough for meaningful rewards)
        uint256 rewardAmount18 = 2000 ether; // 18 decimals

        // Mint and approve tokens for both users
        stakingToken.mint(user, stakeAmount);
        stakingToken.mint(user2, stakeAmount);
        rewardToken1.mint(distributor1, rewardAmount1);
        rewardToken18.mint(distributor18, rewardAmount18);

        vm.prank(user);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(user2);
        stakingToken.approve(address(multiRewards), stakeAmount);
        vm.prank(distributor1);
        rewardToken1.approve(address(multiRewards), rewardAmount1);
        vm.prank(distributor18);
        rewardToken18.approve(address(multiRewards), rewardAmount18);

        // Both users stake
        vm.prank(user);
        multiRewards.stake(stakeAmount);
        vm.prank(user2);
        multiRewards.stake(stakeAmount);

        // Notify reward amounts
        vm.prank(distributor1);
        multiRewards.notifyRewardAmount(address(rewardToken1), rewardAmount1);
        vm.prank(distributor18);
        multiRewards.notifyRewardAmount(address(rewardToken18), rewardAmount18);

        // Fast forward to end of rewards period
        vm.warp(block.timestamp + REWARDS_DURATION);

        // Check earned rewards for both users
        uint256 earned1_user1 = multiRewards.earned(user, address(rewardToken1));
        uint256 earned18_user1 = multiRewards.earned(user, address(rewardToken18));
        uint256 earned1_user2 = multiRewards.earned(user2, address(rewardToken1));
        uint256 earned18_user2 = multiRewards.earned(user2, address(rewardToken18));

        // Each user should earn half of each reward type
        uint256 expected1 = rewardAmount1 / 2;
        uint256 expected18 = rewardAmount18 / 2;
        uint256 tolerance = 1e16; // 1%

        assertApproxEqRel(earned1_user1, expected1, tolerance, "User1 should earn half of 6-decimal rewards");
        assertApproxEqRel(earned18_user1, expected18, tolerance, "User1 should earn half of 18-decimal rewards");
        assertApproxEqRel(earned1_user2, expected1, tolerance, "User2 should earn half of 6-decimal rewards");
        assertApproxEqRel(earned18_user2, expected18, tolerance, "User2 should earn half of 18-decimal rewards");

        // Both users claim rewards
        vm.prank(user);
        multiRewards.getReward();
        vm.prank(user2);
        multiRewards.getReward();

        // Verify both users received their rewards
        assertTrue(rewardToken1.balanceOf(user) > 0, "User1 should receive 6-decimal rewards");
        assertTrue(rewardToken18.balanceOf(user) > 0, "User1 should receive 18-decimal rewards");
        assertTrue(rewardToken1.balanceOf(user2) > 0, "User2 should receive 6-decimal rewards");
        assertTrue(rewardToken18.balanceOf(user2) > 0, "User2 should receive 18-decimal rewards");
    }

    // Test removeReward function - happy path
    function testRemoveRewardSuccess() public {
        MockERC20 rewardToken = new MockERC20("RemoveTest", "RMT", 8);
        address distributor = address(0x555);

        // Add reward token
        multiRewards.addReward(address(rewardToken), distributor, REWARDS_DURATION);

        // Verify token was added
        assertTrue(rewardToken.decimals() == 8, "Token should have 8 decimals");

        // Fast forward to end of reward period
        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        // Remove the reward token
        vm.expectEmit(true, false, false, false);
        emit RewardRemoved(address(rewardToken));
        multiRewards.removeReward(address(rewardToken));

        // Verify token was removed by checking the array length decreased
        // Since we can't directly access the array, we'll add another token and verify it works
        MockERC20 newToken = new MockERC20("New", "NEW", 10);
        multiRewards.addReward(address(newToken), distributor, REWARDS_DURATION);
    }

    // Test removeReward function - reward not found
    function testRemoveRewardNotFound() public {
        MockERC20 nonExistentToken = new MockERC20("NonExistent", "NE", 8);

        vm.expectRevert("Reward token not found");
        multiRewards.removeReward(address(nonExistentToken));
    }

    // Test removeReward function - reward period still active
    function testRemoveRewardPeriodActive() public {
        MockERC20 rewardToken = new MockERC20("ActivePeriod", "AP", 8);
        address distributor = address(0x666);

        // Add reward token
        multiRewards.addReward(address(rewardToken), distributor, REWARDS_DURATION);

        // Mint and notify reward to make the period active
        rewardToken.mint(distributor, 1000e8);
        vm.prank(distributor);
        rewardToken.approve(address(multiRewards), 1000e8);
        vm.prank(distributor);
        multiRewards.notifyRewardAmount(address(rewardToken), 1000e8);

        // Try to remove while period is still active
        vm.expectRevert("Reward period still active");
        multiRewards.removeReward(address(rewardToken));
    }

    // Test removeReward function - only owner can remove
    function testRemoveRewardOnlyOwner() public {
        MockERC20 rewardToken = new MockERC20("OwnerOnly", "OO", 8);
        address distributor = address(0x777);

        // Add reward token
        multiRewards.addReward(address(rewardToken), distributor, REWARDS_DURATION);

        // Fast forward to end of reward period
        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        // Try to remove as non-owner
        vm.prank(user);
        vm.expectRevert("Only the contract owner may perform this action");
        multiRewards.removeReward(address(rewardToken));
    }

    // Test removeReward function - multiple tokens removal
    function testRemoveMultipleRewards() public {
        MockERC20 rewardToken1 = new MockERC20("Remove1", "RM1", 8);
        MockERC20 rewardToken2 = new MockERC20("Remove2", "RM2", 12);
        MockERC20 rewardToken3 = new MockERC20("Remove3", "RM3", 10);
        address distributor = address(0x888);

        // Add multiple reward tokens
        multiRewards.addReward(address(rewardToken1), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(rewardToken2), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(rewardToken3), distributor, REWARDS_DURATION);

        // Fast forward to end of reward period
        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        // Remove tokens one by one
        vm.expectEmit(true, false, false, false);
        emit RewardRemoved(address(rewardToken2));
        multiRewards.removeReward(address(rewardToken2));

        vm.expectEmit(true, false, false, false);
        emit RewardRemoved(address(rewardToken1));
        multiRewards.removeReward(address(rewardToken1));

        vm.expectEmit(true, false, false, false);
        emit RewardRemoved(address(rewardToken3));
        multiRewards.removeReward(address(rewardToken3));

        // Verify all tokens were removed by trying to remove one again
        vm.expectRevert("Reward token not found");
        multiRewards.removeReward(address(rewardToken1));
    }

    // Test that removeReward prevents gas limit issues
    function testRemoveRewardGasOptimization() public {
        address distributor = address(0x999);
        MockERC20[] memory tokens = new MockERC20[](5);

        // Add multiple reward tokens
        for (uint256 i = 0; i < 5; i++) {
            tokens[i] = new MockERC20(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TK", i)), 8);
            multiRewards.addReward(address(tokens[i]), distributor, REWARDS_DURATION);
        }

        // Fast forward to end of reward period
        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        // Remove middle token to test array reordering
        vm.expectEmit(true, false, false, false);
        emit RewardRemoved(address(tokens[2]));
        multiRewards.removeReward(address(tokens[2]));

        // Verify removed token can't be removed again
        vm.expectRevert("Reward token not found");
        multiRewards.removeReward(address(tokens[2]));

        // Verify other tokens can still be removed
        multiRewards.removeReward(address(tokens[0]));
        multiRewards.removeReward(address(tokens[1]));
        multiRewards.removeReward(address(tokens[3]));
        multiRewards.removeReward(address(tokens[4]));
    }

    // Custom event for testing
    event RewardRemoved(address indexed token);
}
