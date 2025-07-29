# Weekly Rewards Campaigns Guide

This guide explains how to set up weekly rewards campaigns using the `RewardsDistributorSafeModule.sol` contract for two different scenarios:

1. **MAMO + cbBTC Campaign**: Distributing both MAMO and cbBTC tokens as rewards
2. **VIRTUALS-only Campaign**: Distributing only VIRTUALS tokens as rewards

## Overview

The `RewardsDistributorSafeModule` is a Safe module that enables time-locked reward distribution to MultiRewards contracts. It implements a state machine with built-in delays for security and supports distributing two different tokens simultaneously.

## Campaign Types

### 1. MAMO + cbBTC Campaign

This campaign distributes both MAMO and cbBTC tokens as weekly rewards.


#### Setup Process

1. Go to basescan and connect the Safe using WalletConnect

2. Call **Add Rewards** (Before Tuesday 8 AM)
   ```solidity
   // Called by F-MAMO
   module.addRewards(mamoAmount, cbbtcAmount);
   ```

3. Check `pendingRewards()` to see when the rewards can be executed (notifyAfter). This is around 8 AM 

4. Call **Execute Rewards**

   ```solidity
   // Anyone can call this after time lock expires
   module.notifyRewards();
   ```

### 2. VIRTUALS-only Campaign

This campaign distributes only VIRTUALS tokens, with MAMO amount set to 0.


#### Setup Process

1. Go to basescan and connect the Safe using WalletConnect

2. Call **Add Rewards** (Before Tuesday 8 AM)
   ```solidity
   // Called by F-MAMO
   module.addRewards(0, virtualsAmount);
   ```

3. Check `pendingRewards()` to see when the rewards can be executed (notifyAfter). This is around 8 AM 

4. Call **Execute Rewards**

   ```solidity
   // Anyone can call this after time lock expires
   module.notifyRewards();
   ```

### Rewards Distributor Contracts on Base Mainnet

- **REWARDS_DISTRIBUTOR_MAMO_CBBTC**: `0xFAbe701fdD289E0b1938238c48eDe86b02757f85`
- **REWARDS_DISTRIBUTOR_MAMO_VIRTUALS**: `0x6f85D661961c9A265776E2A3CCFcdf3a542d6Da2`
