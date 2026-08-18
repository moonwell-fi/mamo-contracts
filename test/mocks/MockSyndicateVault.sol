// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockSyndicateVault
 * @notice Minimal stand-in for the (undeployed, un-vendored) Sherwood SyndicateVault share token.
 * @dev A plain 12-decimal ERC20 whose mint/burn entrypoints are gated to a single configured
 *      strategy address, mirroring how the real vault only lets its strategy mint/burn shares.
 *      A settable `paused` flag blocks {strategyMint} (deposits) but deliberately NOT
 *      {strategyBurn} (burns / redemptions) — matching the real vault, where redemptions keep
 *      working while the vault is paused.
 */
contract MockSyndicateVault is ERC20 {
    /// @notice The only address permitted to mint/burn shares.
    address public strategy;

    /// @notice When true, {strategyMint} reverts (deposits blocked); burns are unaffected.
    bool public paused;

    /// @notice Capacity ceiling (USDC 6dp), `0` == unlimited; the selector must exist even when unused,
    ///         since the strategy calls it typed.
    uint256 public maxTotalAssets;

    constructor() ERC20("Mock Syndicate Vault", "svUSDC") {}

    function setMaxTotalAssets(uint256 maxAssets) external {
        maxTotalAssets = maxAssets;
    }

    function decimals() public pure override returns (uint8) {
        return 12;
    }

    function setStrategy(address strategy_) external {
        strategy = strategy_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    modifier onlyStrategy() {
        require(msg.sender == strategy, "MockVault: only strategy");
        _;
    }

    /// @notice Mints `shares` to `to`. Reverts while paused.
    function strategyMint(address to, uint256 shares) external onlyStrategy {
        require(!paused, "MockVault: paused");
        _mint(to, shares);
    }

    /// @notice Burns `shares` from the calling strategy's own balance. Allowed while paused.
    function strategyBurn(uint256 shares) external onlyStrategy {
        _burn(msg.sender, shares);
    }
}
