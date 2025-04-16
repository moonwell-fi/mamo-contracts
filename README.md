# Mamo Contracts 

Enable users to deploy personal strategy contracts and let Mamo Agent manage their funds.

## System Flow

1. Mamo Backend whitelists a strategy implementation.
2. User requests Mamo to deploy a strategy for them.
3. Mamo deploys a strategy and calls `addStrategy` to register the strategy for the user.
4. User deposits funds directly into their strategy.
5. Mamo Backend calls updatePosition if it identifies a better yield in a determined market/vault.
6. Mamo Backend (or anyone) claims rewards on behalf of the strategy.
7. When rewards are claimed, the reward token balance for the strategy contract increases, so bots can swap rewards for the underlying token on behalf of the user using CowSwap:
   - The user must first call `approveCowSwap` to approve the reward token for the vault relayer
   - Cow Swap calls the isValidSignature function on the strategy contract to validate orders
   - The strategy verifies the order parameters and checks that the price matches the Chainlink price within the set slippage tolerance using the SlippagePriceChecker
   - Any bot can fulfill the order as long as the price is valid according to the SlippagePriceChecker
8. Backend (or anyone) can call depositIdleTokens to deposit any underlying funds currently in the contract into the strategies based on the split.
9. Users can withdraw funds directly from the strategy whenever they want.
10. If Mamo wants to upgrade a strategy (for example, to deposit tokens into a new protocol), it can whitelist the new implementation and ask users to upgrade through the MamoStrategyRegistry contract. Users can only upgrade to the latest implementation of the same strategy type.

## Security Considerations & Assumptions

1. Implementation whitelist ensures that only trusted and audited implementations can be used.
2. Strategy implementations can be upgraded, but only to whitelisted implementations of the same strategy type and the upgrade must be initiated by the user.
3. The Mamo Strategy Registry is not upgradeable and the backend can't remove a user strategy. This ensures strategies can always call the Registry to find its owner, and the owner will always be the only address allowed to upgrade a strategy.
4. Strategy contracts have clear ownership semantics, with only the user registered in the Mamo Strategy Registry able to deposit and withdraw funds, while only the backend address from the Mamo Strategy Registry can update positions.
5. Reward token can't be the strategy token.
6. Mamo Registry admin role is a multisig with a timelock.
7. Guardian is a multisig without a timelock.
8. The strategy integrates with Cow Swap through the isValidSignature function, which validates orders according to EIP-1271. Any bot can fulfill orders as long as the price matches the Chainlink price within the set slippage tolerance, as verified by the SlippagePriceChecker contract.
9. The system does not support fee-on-transfer tokens. Using such tokens would result in deposit and withdrawal failures due to balance discrepancies, as the contracts assume that the exact amount of tokens specified is transferred.
