# Weekly Rewards Campaigns Guide

This guide explains how to set up weekly rewards campaigns using the `RewardsDistributorSafeModule.sol` contract for two different scenarios:

1. **MAMO + cbBTC Campaign**: Distributing both MAMO and cbBTC tokens as rewards
2. **VIRTUALS-only Campaign**: Distributing only VIRTUALS tokens as rewards

## Overview

The `RewardsDistributorSafeModule` is a Safe module that enables time-locked reward distribution to MultiRewards contracts. It implements a state machine with built-in delays for security and supports distributing two different tokens simultaneously.

### Key Components

- **Safe Module**: Executes transactions on behalf of the Safe
- **MultiRewards Contract**: Receives and distributes rewards to stakers
- **Time Lock**: 24-hour delay between setting and executing rewards
- **Admin Role**: Can add rewards (typically the F-MAMO address)
- **Safe Role**: Can update configuration and pause/unpause

## Campaign Types

### 1. MAMO + cbBTC Campaign

This campaign distributes both MAMO and cbBTC tokens as weekly rewards.

#### Prerequisites

- Ensure the Safe has sufficient MAMO and cbBTC token balances
- Module must be enabled on the Safe
- Admin must have the correct permissions

#### Setup Process

1. **Fund the Safe**
   ```solidity
   // Example amounts for weekly distribution
   uint256 mamoAmount = 1000e18;    // 1,000 MAMO tokens
   uint256 cbbtcAmount = 0.1e8;     // 0.1 cbBTC (8 decimals)
   ```

2. **Add Rewards**
   ```solidity
   // Called by admin (F-MAMO address)
   module.addRewards(mamoAmount, cbbtcAmount);
   ```

3. **Wait for Time Lock**
   - Wait 24 hours (or configured `notifyDelay`) after adding rewards
   - Monitor state: `UNINITIALIZED` → `NOT_READY` → `PENDING_EXECUTION`

4. **Execute Rewards**
   ```solidity
   // Anyone can call this after time lock expires
   module.notifyRewards();
   ```

#### State Flow
```
UNINITIALIZED → NOT_READY → PENDING_EXECUTION → EXECUTED
```

### 2. VIRTUALS-only Campaign

This campaign distributes only VIRTUALS tokens, with MAMO amount set to 0.

#### Prerequisites

- Ensure the Safe has sufficient VIRTUALS token balance
- Module must be enabled on the Safe
- Admin must have the correct permissions

#### Setup Process

1. **Fund the Safe**
   ```solidity
   // Example amounts for weekly distribution
   uint256 mamoAmount = 0;           // No MAMO rewards
   uint256 virtualsAmount = 1000e18; // 1,000 VIRTUALS tokens
   ```

2. **Add Rewards**
   ```solidity
   // Called by admin (F-MAMO address)
   module.addRewards(0, virtualsAmount);
   ```

3. **Wait for Time Lock**
   - Same 24-hour delay applies
   - State transitions: `UNINITIALIZED` → `PENDING_EXECUTION`

4. **Execute Rewards**
   ```solidity
   // Anyone can call this after time lock expires
   module.notifyRewards();
   ```

## Configuration Parameters

### Time Constants

```solidity
uint256 public constant MIN_REWARDS_DURATION = 7 days;   // Minimum reward period
uint256 public constant MAX_REWARDS_DURATION = 30 days;  // Maximum reward period
uint256 public constant MIN_NOTIFY_DELAY = 1 days;      // Minimum time lock
uint256 public constant MAX_NOTIFY_DELAY = 30 days;     // Maximum time lock
```

### Current Settings

- **Reward Duration**: 7 days (weekly distribution)
- **Notify Delay**: 24 hours (time lock for security)

## Weekly Campaign Workflow

### Week 1 Setup
1. **Monday**: Admin calls `addRewards()` with week's allocation
2. **Tuesday**: After 24h delay, anyone calls `notifyRewards()`
3. **Tuesday-Monday**: Rewards distributed over 7 days to stakers

### Week 2 Setup
1. **Tuesday**: Admin calls `addRewards()` for next week
2. **Wednesday**: After 24h delay, anyone calls `notifyRewards()`
3. **Wednesday-Tuesday**: Next week's rewards distributed

## Security Features

### Access Control
- **Admin Role**: Can add rewards (set to F-MAMO address)
- **Safe Role**: Can update configuration, pause/unpause
- **Permissionless Execution**: Anyone can call `notifyRewards()` after time lock

### Time Lock Protection
- 24-hour minimum delay between setting and executing rewards
- Prevents immediate malicious actions
- Allows time for review and intervention

### State Machine Validation
- Prevents double-execution of rewards
- Ensures proper sequence of operations
- Clear state transitions and validations

## Common Operations

### Check Current State
```solidity
RewardState state = module.getCurrentState();
// UNINITIALIZED, NOT_READY, PENDING_EXECUTION, or EXECUTED
```

### Check Pending Rewards
```solidity
(uint256 token1Amount, uint256 token2Amount, uint256 notifyAfter, bool isNotified) = 
    module.pendingRewards();
```

### Emergency Pause
```solidity
// Only Safe can call
module.pause();   // Stops addRewards() and notifyRewards()
module.unpause(); // Resumes normal operation
```

## Example Test Scenarios

### VIRTUALS Campaign Test
```solidity
// From test file - VIRTUALS-only campaign
uint256 MAMO_REWARD_AMOUNT = 0;
uint256 VIRTUALS_REWARD_AMOUNT = 1e18;

// Fund Safe with VIRTUALS only
deal(address(virtualsToken), address(safe), VIRTUALS_REWARD_AMOUNT);

// Add rewards
vm.prank(admin);
module.addRewards(MAMO_REWARD_AMOUNT, VIRTUALS_REWARD_AMOUNT);

// Wait and execute
vm.warp(storedUnlockTime + 1);
module.notifyRewards();
```

## Troubleshooting

### Common Issues

1. **"Pending rewards waiting to be executed"**
   - Previous rewards not yet executed
   - Wait for time lock or execute pending rewards

2. **"Insufficient token balance"**
   - Safe doesn't have enough tokens
   - Transfer tokens to Safe before adding rewards

3. **"Only admin can call this function"**
   - Wrong address calling `addRewards()`
   - Use F-MAMO address as admin

4. **"Rewards not in pending state"**
   - Time lock not expired yet
   - Check `getExecutionTimestamp()` for ready time

### State Debugging
```solidity
// Check when rewards can be executed
uint256 executeAt = module.getExecutionTimestamp();

// Check current state
RewardState state = module.getCurrentState();
```

## Best Practices

1. **Fund Safe First**: Always ensure sufficient token balances before adding rewards
2. **Monitor State**: Check state transitions and execution timestamps
3. **Weekly Routine**: Establish consistent timing for weekly campaigns
4. **Emergency Procedures**: Know how to pause/unpause in emergencies
5. **Balance Monitoring**: Regularly check Safe token balances
6. **Event Monitoring**: Listen for `RewardAdded` and `RewardsNotified` events

## Integration with MultiRewards

The module automatically:
- Approves tokens for MultiRewards contract
- Adds reward tokens if not already configured
- Sets reward duration (7 days for weekly campaigns)
- Notifies MultiRewards of new reward amounts
- Handles both single-token and dual-token campaigns seamlessly