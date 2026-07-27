// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStrategy} from "@contracts/leveraged-aero/sherwood/interfaces/IStrategy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LeveragedAeroVault
 * @notice Minimal share token + lifecycle driver for ONE vendored
 *         {LeveragedAerodromeCLStrategy} clone. Replaces the Sherwood `SyndicateVault` the vendored
 *         strategy was written against, exposing only the surface that strategy actually consumes:
 *         `asset()`, `owner()`, `totalSupply()`/`transferFrom` (ERC20), `strategyMint`,
 *         `strategyBurn`, and `factory()`.
 * @dev Deliberately NOT ERC-4626 and NOT upgradeable. Deposits and redemptions are serviced by the
 *      STRATEGY (custody model): LPs call `strategy.deposit` / `strategy.redeem` / `requestRedeem`,
 *      the strategy prices them off its own oracle NAV and mints/burns vault shares through the two
 *      hooks below. This contract holds no position and computes no price — it is the share ledger
 *      plus an owner-driven execute/settle lifecycle. Non-upgradeable by design (registry precedent):
 *      the strategy clone is immutable, so a mutable vault behind it would only widen trust.
 *
 *      Ownership is {Ownable2Step}; the owner is expected to be MAMO_MULTISIG. The vendored
 *      strategy's `rescueToVault` reads `Ownable(vault()).owner()`, so the two-step owner IS the
 *      strategy's rescue authority.
 */
contract LeveragedAeroVault is ERC20, Ownable2Step {
    using SafeERC20 for IERC20;

    // ==================== IMMUTABLES ====================

    /// @notice The ERC-20 the strategy accounts in (USDC, 6dp). Also the redemption payout token.
    /// @dev Named `asset` so the auto-generated getter satisfies the strategy's
    ///      `IERC4626(vault()).asset()` init check (`AssetMismatch` otherwise).
    address public immutable asset;

    // ==================== STATE ====================

    /// @notice The single bound {LeveragedAerodromeCLStrategy} clone. Set once, never rotated.
    address public strategy;

    /// @notice Gates {strategyMint}. False blocks all new share issuance (deposits + fee-shares).
    bool public depositsOpen;

    /// @notice Set by {settleStrategy}; unlocks {redeemSettled}. One-way.
    bool public settled;

    /// @notice Optional protocol-fee config, surfaced to the strategy via {protocolConfig}.
    ///         `address(0)` (the deploy default) == fees OFF.
    address public feeConfig;

    // ==================== EVENTS ====================

    event StrategySet(address indexed strategy);
    event OpenDepositsUpdated(bool open);
    event FeeConfigUpdated(address indexed feeConfig);
    event StrategyActivated(address indexed strategy, uint256 seedAmount);
    event StrategySettled(address indexed strategy);
    event SettledRedeem(address indexed owner, uint256 shares, uint256 assetsOut);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /**
     * @param asset_  The strategy's unit of account (USDC, 6dp).
     * @param owner_  Initial owner (MAMO_MULTISIG in production).
     * @param name_   ERC-20 name of the share token.
     * @param symbol_ ERC-20 symbol of the share token.
     */
    constructor(address asset_, address owner_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {
        require(asset_ != address(0), "LAV: invalid asset");
        asset = asset_;
    }

    // ==================== ERC20 ====================

    /**
     * @notice Share decimals: the asset's decimals plus a fixed 6-decimal offset (USDC 6dp → 12dp
     *         shares).
     * @dev The offset is LOAD-BEARING, not cosmetic. The vendored strategy prices the genesis
     *      deposit through an ERC-4626-style virtual offset hardcoded as
     *      `SHARES_VIRTUAL_OFFSET = 1e6`, i.e. `shares = assets × (supply + 1e6) / (nav + 1)`. On an
     *      empty book that mints `assets × 1e6` shares — exactly a 6-decimal step up from the 6dp
     *      asset. Returning anything but `assetDecimals + 6` makes the share token's advertised
     *      denomination disagree with the units the strategy actually mints.
     */
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(asset).decimals() + 6;
    }

    // ==================== STRATEGY SHARE HOOKS ====================

    /**
     * @notice Mint `shares` to `to`. Called by the strategy on an LP deposit and on a fee-share
     *         crystallise.
     * @dev The `msg.sender == strategy` check is the SOLE protection against arbitrary share
     *      inflation — this contract performs no pricing of its own and takes the strategy's share
     *      count on faith. Gated on {depositsOpen} so the owner can freeze issuance (which also
     *      defers fee-share mints; the strategy's crystallise is best-effort and tolerates the
     *      revert).
     */
    function strategyMint(address to, uint256 shares) external {
        require(msg.sender == strategy, "LAV: only strategy");
        require(depositsOpen, "LAV: deposits closed");
        _mint(to, shares);
    }

    /**
     * @notice Burn `shares` from the strategy's own balance, after it has pulled them from the
     *         redeemer via `transferFrom`.
     * @dev Deliberately NOT gated on {depositsOpen} (nor on any pause): exits must keep working
     *      during an incident. Burning only from `msg.sender` means the strategy can never destroy
     *      a third party's shares.
     */
    function strategyBurn(uint256 shares) external {
        require(msg.sender == strategy, "LAV: only strategy");
        _burn(msg.sender, shares);
    }

    // ==================== FEE CONFIG ====================

    /**
     * @notice Sherwood-shaped fee-config discovery hop. The strategy resolves the protocol-fee
     *         config as `ISyndicateFactory(vault.factory()).protocolConfig()`; this vault plays both
     *         roles, so it points the first hop back at itself once a {feeConfig} exists.
     * @return `address(this)` when a fee config is set, `address(0)` otherwise (fees off — the
     *         strategy's null-check short-circuits before the second hop).
     */
    function factory() external view returns (address) {
        return feeConfig == address(0) ? address(0) : address(this);
    }

    /// @notice Second hop of the fee-config lookup. The returned contract must implement
    ///         `protocolFeeBps()` + `protocolFeeRecipient()`; `address(0)` == protocol fee off.
    function protocolConfig() external view returns (address) {
        return feeConfig;
    }

    // ==================== OWNER: WIRING ====================

    /**
     * @notice Bind the strategy clone. Set-once: the share ledger's integrity rests entirely on
     *         `msg.sender == strategy`, so a rotatable pointer would let a future owner mint freely
     *         against existing holders.
     */
    function setStrategy(address strategy_) external onlyOwner {
        require(strategy == address(0), "LAV: strategy already set");
        require(strategy_ != address(0), "LAV: invalid strategy");
        strategy = strategy_;
        emit StrategySet(strategy_);
    }

    /// @notice Open / close new share issuance. Redemptions are unaffected (see {strategyBurn}).
    function setOpenDeposits(bool open) external onlyOwner {
        depositsOpen = open;
        emit OpenDepositsUpdated(open);
    }

    /// @notice Point the strategy's protocol-fee lookup at a config contract, or clear it
    ///         (`address(0)` → fees off). Read live by the strategy on every crystallise.
    function setFeeConfig(address feeConfig_) external onlyOwner {
        feeConfig = feeConfig_;
        emit FeeConfigUpdated(feeConfig_);
    }

    // ==================== OWNER: LIFECYCLE ====================

    /**
     * @notice Seed the strategy and drive it Pending → Executed.
     * @dev The seed is pulled from the CALLER (owner) straight to the strategy — the vault never
     *      custodies it. A seed is mandatory in practice: the strategy's `_supplyCollateral` reads
     *      its OWN asset balance and reverts `ExecuteZeroBalance` at 0, so `seedAmount == 0` fails
     *      inside `execute()`, not here. Calling from this contract is what satisfies the strategy's
     *      `onlyVault` (a raw `msg.sender == vault` compare).
     * @param seedAmount Asset units (6dp) to transfer to the strategy before executing.
     */
    function activateStrategy(uint256 seedAmount) external onlyOwner {
        address strategy_ = strategy;
        require(strategy_ != address(0), "LAV: strategy not set");
        IERC20(asset).safeTransferFrom(msg.sender, strategy_, seedAmount);
        IStrategy(strategy_).execute();
        emit StrategyActivated(strategy_, seedAmount);
    }

    /**
     * @notice Drive the strategy Executed → Settled: it unwinds the whole levered book and pushes
     *         the realized asset balance here, then holders exit via {redeemSettled}.
     * @dev One-way. The strategy's own state machine rejects a second `settle()`, and {settled}
     *      never clears — the vault has no path back to an active book.
     */
    function settleStrategy() external onlyOwner {
        address strategy_ = strategy;
        require(strategy_ != address(0), "LAV: strategy not set");
        IStrategy(strategy_).settle();
        settled = true;
        emit StrategySettled(strategy_);
    }

    // ==================== POST-SETTLE EXIT ====================

    /**
     * @notice Burn `shares` for a pro-rata slice of the vault's settled asset balance.
     * @dev This is the ONLY exit after settlement. The strategy's `_settle` pushes all realized
     *      assets here while holders still hold their shares, and its own `redeem` /
     *      `fulfillRedeem` paths are gated on `State.Executed` — without this function every holder
     *      would be stranded. Payout is computed on the PRE-burn supply and PRE-transfer balance
     *      (`shares × balance / supply`, rounding down, in the stayers' favour), then shares are
     *      burned before the transfer (CEI).
     * @param shares Shares to burn (12dp for a 6dp asset).
     * @return assetsOut Asset units paid to the caller.
     */
    function redeemSettled(uint256 shares) external returns (uint256 assetsOut) {
        require(settled, "LAV: not settled");
        require(shares > 0, "LAV: zero shares");
        uint256 supply = totalSupply();
        require(supply > 0, "LAV: no shares outstanding");

        assetsOut = (shares * IERC20(asset).balanceOf(address(this))) / supply;
        _burn(msg.sender, shares);
        if (assetsOut > 0) IERC20(asset).safeTransfer(msg.sender, assetsOut);

        emit SettledRedeem(msg.sender, shares, assetsOut);
    }

    // ==================== RESCUE ====================

    /**
     * @notice Sweep a token out of the vault.
     * @dev Any non-asset token, any time — the vault is a plain transfer target for the strategy's
     *      `rescueToVault` sweeps, and those airdrops/strays back no shares. The ASSET is claimable
     *      only once `totalSupply() == 0`: pre-settlement any asset balance is dust/donations, and
     *      post-settlement it is the {redeemSettled} pot, so the owner may not touch it while a
     *      single share is outstanding.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "LAV: invalid recipient");
        require(token != asset || totalSupply() == 0, "LAV: asset reserved for redemptions");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
