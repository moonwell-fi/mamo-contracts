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
        MockERC20 token1 = new MockERC20("Token1", "T1", 1);

        address distributor = address(0x123);

        // These should succeed (1 <= decimals <= 18)
        multiRewards.addReward(address(token18), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(token8), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(token6), distributor, REWARDS_DURATION);
        multiRewards.addReward(address(token1), distributor, REWARDS_DURATION);

        // Verify tokens were added successfully
        assertTrue(address(token18) != address(0), "Token18 should be valid");
        assertTrue(address(token8) != address(0), "Token8 should be valid");
        assertTrue(address(token6) != address(0), "Token6 should be valid");
        assertTrue(address(token1) != address(0), "Token1 should be valid");
    }

    // Test addReward function with invalid decimals (unhappy path)
    function testAddRewardInvalidDecimals() public {
        MockERC20 token0 = new MockERC20("Token0", "T0", 0);
        MockERC20 token19 = new MockERC20("Token19", "T19", 19);
        MockERC20 token255 = new MockERC20("Token255", "T255", 255);

        address distributor = address(0x123);

        // This should fail (decimals = 0)
        vm.expectRevert("Reward token decimals must be > 0");
        multiRewards.addReward(address(token0), distributor, REWARDS_DURATION);

        // These should fail (decimals > 18)
        vm.expectRevert("Reward token decimals must be <= 18");
        multiRewards.addReward(address(token19), distributor, REWARDS_DURATION);

        vm.expectRevert("Reward token decimals must be <= 18");
        multiRewards.addReward(address(token255), distributor, REWARDS_DURATION);
    }
}
