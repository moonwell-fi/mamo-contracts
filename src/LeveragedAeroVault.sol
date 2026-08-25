// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStrategy} from "@contracts/leveraged-aero/sherwood/interfaces/IStrategy.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev The strategy's NAV read, declared locally so stand-ins for the vendored `IStrategy` need not
///      grow the selector.
interface IStrategyNav {
    function nav() external view returns (uint256);
}

/// @dev The vendored strategy's operator-rotation hook, declared locally for the {IStrategyNav} reason.
interface IStrategyProposer {
    function setProposer(address newProposer) external;
}

/**
 * @title LeveragedAeroVault
 * @notice Minimal share token + lifecycle driver for ONE vendored
 *         {LeveragedAerodromeCLStrategy} clone. Replaces the Sherwood `SyndicateVault` the vendored
 *         strategy was written against, exposing only the surface that strategy actually consumes:
 *         `asset()`, `owner()`, `totalSupply()`/`transferFrom` (ERC20), `strategyMint` and
 *         `strategyBurn`.
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

    /// @notice FUND CAPACITY: ceiling on the strategy's total NAV, in USDC (6dp), over the whole book,
    ///         not a per-user limit. `0` (the deploy default) == UNLIMITED; {depositsOpen} freezes.
    /// @dev Enforced in the strategy's `deposit` (pre-deposit, against the pre-deposit NAV; crossing
    ///      deposits rejected, not trimmed), NOT in {strategyMint} — that also serves
    ///      best-effort FEE-SHARE mints, which capacity must never gate or fees defer forever.
    uint256 public maxTotalAssets;

    // ==================== EVENTS ====================

    event StrategySet(address indexed strategy);
    event OpenDepositsUpdated(bool open);
    event MaxTotalAssetsSet(uint256 maxAssets);
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
     * @dev The offset is LOAD-BEARING, not cosmetic. The vendored strategy prices every deposit
     *      through an ERC-4626-style virtual offset hardcoded as `SHARES_VIRTUAL_OFFSET = 1e6`,
     *      i.e. `shares = assets × (supply + 1e6) / (nav + 1)`. Against a zero supply AND a zero
     *      NAV that collapses to `assets × 1e6` — exactly a 6-decimal step up from the 6dp asset,
     *      which is the rate {activateStrategy} mints the seed at so later deposits price against a
     *      book whose supply and NAV agree. Returning anything but `assetDecimals + 6` makes the
     *      share token's advertised denomination disagree with the units the strategy mints.
     */
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(asset).decimals() + 6;
    }

    /// @notice Disabled: the owner is the strategy's rescue authority and the only lifecycle driver
    ///         (`activateStrategy` / `settleStrategy`), so renouncing would strand the book.
    function renounceOwnership() public pure override {
        revert("LAV: renounce disabled");
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

    // ==================== OWNER: WIRING ====================

    // NOTE: no `setStrategy` by design — {cloneAndBind} is the only path the strategy pointer is ever
    // set by, which closes the front-run window a separate deploy-then-bind flow left open.

    /**
     * @notice Atomically deploy an ERC-1167 clone of `template`, initialize it against THIS vault, and
     *         bind it. Set-once: the share ledger rests entirely on `msg.sender == strategy`, so a
     *         rotatable pointer would let a future owner mint against existing holders.
     * @dev Front-run-proof: `BaseStrategy.initialize` gates on `msg.sender == vault_`, so only this call
     *      can initialize a clone pointed here, and `_bind` re-checks the binding.
     */
    function cloneAndBind(address template, address proposer_, bytes calldata initData)
        external
        onlyOwner
        returns (address clone)
    {
        clone = Clones.clone(template);
        IStrategy(clone).initialize(address(this), proposer_, initData);
        _bind(clone);
    }

    /// @dev The set-once bind; sole caller is {cloneAndBind}.
    function _bind(address strategy_) private {
        require(strategy == address(0), "LAV: strategy already set");
        // DEAD BELT: `Clones.clone` never returns the zero address, so the only caller cannot reach this.
        require(strategy_ != address(0), "LAV: invalid strategy");
        require(IStrategy(strategy_).vault() == address(this), "LAV: strategy not bound to this vault");
        strategy = strategy_;
        emit StrategySet(strategy_);
    }

    /**
     * @notice Rotate the bound strategy's operator (proposer) key. The strategy rejects zero.
     * @dev Not fund-moving: `onlyProposer` can neither raise leverage (`setTargetLtv` is admin-only)
     *      nor move tokens, so this is deliberately not set-once. Does NOT move `Layout.feeRecipient`,
     *      an init-only field, so it is not a complete key-compromise response.
     */
    function setProposer(address newProposer) external onlyOwner {
        address strategy_ = strategy;
        require(strategy_ != address(0), "LAV: strategy not set");
        IStrategyProposer(strategy_).setProposer(newProposer);
    }

    /// @notice Open / close new share issuance. Redemptions are unaffected (see {strategyBurn}).
    function setOpenDeposits(bool open) external onlyOwner {
        depositsOpen = open;
        emit OpenDepositsUpdated(open);
    }

    /// @notice Set the fund's capacity ceiling over the whole book, in USDC (6dp); `0` == unlimited.
    /// @dev Takes effect on the next deposit. Lowering it below current NAV unwinds and traps nobody —
    ///      it only closes new deposits; every withdrawal path is independent of it.
    function setMaxTotalAssets(uint256 maxAssets) external onlyOwner {
        maxTotalAssets = maxAssets;
        emit MaxTotalAssetsSet(maxAssets);
    }

    /// @notice ADVISORY: USDC that could still be deposited before the capacity ceiling is reached.
    /// @dev Point-in-time reading, not a reservation. `0` == at or above the ceiling, and
    ///      `type(uint256).max` == cap disabled. Reverts when NAV is unpriceable (fail-closed).
    function remainingCapacity() external view returns (uint256 assets) {
        uint256 cap = maxTotalAssets;
        if (cap == 0) return type(uint256).max; // unlimited
        require(strategy != address(0), "LAV: strategy unset");
        uint256 navNow = IStrategyNav(strategy).nav();
        return navNow >= cap ? 0 : cap - navNow;
    }

    /// @notice ADVISORY: the shares a deposit of `assets` USDC (6dp) would mint at CURRENT pricing —
    ///         the canonical assets->shares conversion for UI and slippage (`minShares`) sizing.
    /// @dev Point-in-time, not a peg; reverts when NAV is unpriceable, like the deposit's own
    ///      `NavUnpriceable`. A LOWER bound, not upper: `deposit`'s post-crystallise supply is `>=`
    ///      this one, so the real mint is `>=` this figure.
    function previewSharesForAssets(uint256 assets) external view returns (uint256 shares) {
        require(strategy != address(0), "LAV: strategy unset");
        uint256 supply = totalSupply();
        uint256 navNow = IStrategyNav(strategy).nav();
        // Fail closed: `nav()` FLOORS to 0 instead of reverting, so without this the denominator
        // collapses to 1 and the preview overstates by ~1e9-1e12x. Reachable post-`settleStrategy`.
        // `supply == 0` legitimately prices at nav 0, as in deposit.
        require(navNow > 0 || supply == 0, "LAV: nav unpriceable");
        // `SHARES_VIRTUAL_OFFSET` is 1e6 in the strategy: the same 6-decimal step `decimals()` documents.
        uint256 offset = 10 ** (decimals() - IERC20Metadata(asset).decimals());
        shares = Math.mulDiv(assets, supply + offset, navNow + 1);
    }

    // ==================== OWNER: LIFECYCLE ====================

    /**
     * @notice Seed the strategy, drive it Pending → Executed, and mint the seeder the genesis
     *         shares backing that seed.
     * @dev The seed is pulled from the CALLER (owner) straight to the strategy — the vault never
     *      custodies it. A seed is mandatory in practice: the strategy's `_supplyCollateral` reads
     *      its OWN asset balance and reverts `ExecuteZeroBalance` at 0, so `seedAmount == 0` fails
     *      inside `execute()`, not here. Calling from this contract is what satisfies the strategy's
     *      `onlyVault` (a raw `msg.sender == vault` compare).
     *
     *      The mint is NOT optional bookkeeping. The seed raises the strategy's NAV while supply is
     *      still 0, and the strategy prices deposits as `shares = assets × (supply + 1e6)/(nav + 1)`
     *      — so an unminted seed makes the FIRST depositor mint against `supply == 0` but a nonzero
     *      NAV, handing them ~100% of a book they only half funded. Minting at the genesis rate
     *      (`seedAmount × 10 ** offset`, the same `assets × 1e6` the strategy's own formula produces
     *      on a truly empty book) keeps supply and NAV in step, so the next depositor mints a fair
     *      claim. Deliberately `_mint`, not {strategyMint}: this is the owner's own capital going in
     *      at a fixed, un-priced rate, so it is not subject to the {depositsOpen} issuance gate.
     *
     *      Minted AFTER `execute()` so a strategy that reverts on activation leaves no shares behind.
     * @param seedAmount Asset units (6dp) to transfer to the strategy before executing.
     */
    function activateStrategy(uint256 seedAmount) external onlyOwner {
        address strategy_ = strategy;
        require(strategy_ != address(0), "LAV: strategy not set");
        IERC20(asset).safeTransferFrom(msg.sender, strategy_, seedAmount);
        IStrategy(strategy_).execute();
        _mint(msg.sender, seedAmount * 10 ** (decimals() - IERC20Metadata(asset).decimals()));
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
     * @dev Any third-party token, any time — the vault is a plain transfer target for the strategy's
     *      `rescueToVault` sweeps, and those airdrops/strays back no shares. Two exclusions:
     *      - The ASSET is claimable only once every EXTERNAL share is gone, since post-settlement it is
     *        the {redeemSettled} pot. The test is `totalSupply() == balanceOf(address(this))`, not
     *        `totalSupply() == 0`, which one wei of dead-weight shares sent here would brick forever;
     *        strategy-escrowed shares still count as external and hold the gate shut.
     *      - The vault's OWN share token is never rescuable: a share balance here is an un-burned claim
     *        or a fee-share mint, so sweeping it would exfiltrate depositor value.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "LAV: invalid recipient");
        require(token != address(this), "LAV: cannot rescue shares");
        require(token != asset || totalSupply() == balanceOf(address(this)), "LAV: asset reserved for redemptions");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
