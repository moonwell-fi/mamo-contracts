// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Position} from "@contracts/leveraged-aero/sherwood/interfaces/IPriceRouter.sol";
import {IStrategy} from "@contracts/leveraged-aero/sherwood/interfaces/IStrategy.sol";
import {ISyndicateVault} from "@contracts/leveraged-aero/sherwood/interfaces/ISyndicateVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockVaultStrategy
 * @notice Minimal {IStrategy} stand-in for the vendored {LeveragedAerodromeCLStrategy}, used by the
 *         {LeveragedAeroVault} unit suite.
 * @dev Mirrors only what the vault touches: the `onlyVault`-gated execute/settle lifecycle, and the
 *      two share hooks the real strategy drives (`strategyMint` / `strategyBurn`, exposed here as
 *      test-only passthroughs). {execute} records the asset balance it was seeded with so the vault's
 *      `activateStrategy` transfer can be asserted; {settle} pushes the whole asset balance back to
 *      the vault, matching the real strategy's `_pushAllToVault` on settlement.
 */
contract MockVaultStrategy is IStrategy {
    using SafeERC20 for IERC20;

    enum Phase {
        Pending,
        Executed,
        Settled
    }

    address private _vault;
    address private _proposer;

    /// @notice The strategy's unit of account (USDC in production).
    address public immutable assetToken;

    /// @notice Lifecycle phase, driven by the vault.
    Phase public phase;

    /// @notice Asset balance observed at {execute} — the seed `activateStrategy` transferred in.
    uint256 public seedReceived;

    constructor(address vault_, address asset_) {
        _vault = vault_;
        _proposer = msg.sender;
        assetToken = asset_;
    }

    modifier onlyVault() {
        require(msg.sender == _vault, "MockStrategy: only vault");
        _;
    }

    // ==================== ISTRATEGY ====================

    function initialize(address vault_, address proposer_, bytes calldata) external {
        _vault = vault_;
        _proposer = proposer_;
    }

    function execute() external onlyVault {
        require(phase == Phase.Pending, "MockStrategy: already executed");
        phase = Phase.Executed;
        seedReceived = IERC20(assetToken).balanceOf(address(this));
    }

    function settle() external onlyVault {
        require(phase == Phase.Executed, "MockStrategy: not executed");
        phase = Phase.Settled;
        uint256 bal = IERC20(assetToken).balanceOf(address(this));
        if (bal > 0) IERC20(assetToken).safeTransfer(_vault, bal);
    }

    function updateParams(bytes calldata) external {}

    function vault() external view returns (address) {
        return _vault;
    }

    function proposer() external view returns (address) {
        return _proposer;
    }

    function name() external pure returns (string memory) {
        return "Mock Vault Strategy";
    }

    function positions() external pure returns (Position[] memory) {
        return new Position[](0);
    }

    function selfManagesFees() external pure returns (bool) {
        return true;
    }

    // ==================== TEST-ONLY VAULT-HOOK DRIVERS ====================

    /// @notice Drives `vault.strategyMint` as the real strategy does on deposit / fee crystallise.
    function mintShares(address to, uint256 shares) external {
        ISyndicateVault(_vault).strategyMint(to, shares);
    }

    /// @notice Drives `vault.strategyBurn` as the real strategy does after pulling a redeemer's shares.
    function burnShares(uint256 shares) external {
        ISyndicateVault(_vault).strategyBurn(shares);
    }

    /// @notice Pulls `shares` from `from` (needs a prior vault-side approval), mirroring redeem.
    function pullShares(address from, uint256 shares) external {
        IERC20(_vault).safeTransferFrom(from, address(this), shares);
    }
}
