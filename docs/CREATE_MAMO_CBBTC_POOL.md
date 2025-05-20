# CreateMamoCbBTCPool Script

This script creates a new liquidity pool pairing MAMO and cbBTC tokens on Aerodrome, then sends the resulting NFT to the BurnAndEarn contract.

## Overview

The script performs the following operations:

1. Creates a new pool by calling `mint` on the AERODROME_POSITION_MANAGER
2. Immediately sends the NFT received to BURN_AND_EARN
3. Calls the `add` function on BURN_AND_EARN to register the NFT

## Addresses Used

The script uses the following addresses from the 8453.json file:
- MAMO: The MAMO token address
- cbBTC: The cbBTC token address
- AERODROME_POSITION_MANAGER: The Aerodrome position manager contract
- BURN_AND_EARN: The BurnAndEarn contract

## Implementation Details

### Pool Creation
The script creates a new pool by calling the `mint` function on the AERODROME_POSITION_MANAGER with the following parameters:
- token0, token1: MAMO and cbBTC (sorted by address)
- fee: Standard fee tier
- tickLower, tickUpper: Price range for the position
- amount0Desired, amount1Desired: Liquidity amounts
- amount0Min, amount1Min: Minimum amounts to prevent slippage
- recipient: Initially set to the script's address
- deadline: Current timestamp plus buffer

### NFT Transfer and Registration
After creating the pool, the script:
1. Approves the NFT for transfer to BURN_AND_EARN
2. Transfers the NFT to BURN_AND_EARN
3. Calls the `add` function on BURN_AND_EARN with the tokenId

### Validation
The script validates that:
- The NFT is owned by BURN_AND_EARN
- The position is registered in BURN_AND_EARN

## Usage

Run the script with:

```bash
forge script script/CreateMamoCbBTCPool.s.sol --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --broadcast
```

Replace `<RPC_URL>` with your Base chain RPC URL and `<PRIVATE_KEY>` with your private key.