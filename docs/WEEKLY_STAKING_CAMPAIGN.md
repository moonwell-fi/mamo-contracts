# Weekly Rewards Campaigns Guide

This guide explains how to set up weekly rewards campaigns using the `RewardsDistributorSafeModule.sol` contract for two different scenarios:

1. **MAMO + cbBTC Campaign**: Distributing both MAMO and cbBTC tokens as rewards
2. **VIRTUALS-only Campaign**: Distributing only VIRTUALS tokens as rewards

## Overview

The `RewardsDistributorSafeModule` is a Safe module that enables time-locked reward distribution to MultiRewards contracts. It implements a state machine with built-in delays for security and supports distributing two different tokens simultaneously.

## Campaign Types

### 1. MAMO + cbBTC Campaign

This campaign distributes both MAMO and cbBTC tokens as weekly rewards.

#### Prerequisites

- Ensure the Safe has sufficient MAMO and cbBTC token balances
- Admin must have the correct permissions

#### Setup Process

1. **Fund the Safe**
   ```solidity
   // Example amounts for weekly distribution
   uint256 mamoAmount = 1000e18;    // 1,000 MAMO tokens
   uint256 cbbtcAmount = 0.1e8;     // 0.1 cbBTC (8 decimals)
   ```

2. **Add Rewards**

This should be done before Tuesday 8 AM
   ```solidity
   // Called by admin (F-MAMO address)
   module.addRewards(mamoAmount, cbbtcAmount);
   ```

4. **Execute Rewards**
Check `pendingRewards()` to see when the rewards can be executed (notifyAfter)

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

3. **Execute Rewards**
   ```solidity
   // Anyone can call this after time lock expires
   module.notifyRewards();
   ```

This should be done before Tuesday 8 AM

## Contract Addresses

### Rewards Distributor Contracts on Base Mainnet

- **REWARDS_DISTRIBUTOR_MAMO_CBBTC**: `0x9Df761AEB0D09ed631F336565806fE26D65C470b`
- **REWARDS_DISTRIBUTOR_MAMO_VIRTUALS**: `0x6f85D661961c9A265776E2A3CCFcdf3a542d6Da2`

Go to basescan and connect the Safe using WalletConnect