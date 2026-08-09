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

/// @dev Just the strategy's NAV read, for {LeveragedAeroVault.previewSharesForAssets}. Declared
///      locally rather than added to the vendored `IStrategy`, because every stand-in that
///      implements that interface would then have to grow the selector too.
interface IStrategyNav {
    function nav() external view returns (uint256);
}

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

    /// @notice Ceiling on the shares ONE per-user account may hold — a global allocation guardrail,
    ///         identical for every account. `0` (the deploy default) == UNLIMITED.
    ///
    /// @dev THIS VALUE IS STORED HERE BUT ENFORCED IN THE ACCOUNT
    ///      ({MamoLeveragedAeroStrategy}), for two reasons:
    ///
    ///        1. Only an account knows a single user's share balance; this vault sees just the
    ///           aggregate ledger.
    ///        2. Enforcing it in {strategyMint} would also catch FEE-SHARE crystallisations, which
    ///           the strategy performs best-effort inside a try/catch — a cap-blocked fee mint would
    ///           silently defer fees forever instead of reverting. That is the same hazard
    ///           {depositsOpen} already carries, and it is not one to duplicate.
    ///
    ///      It lives on the VAULT (rather than the factory or the registry) because every account
    ///      already holds this address — it derives `vaultShares` from `strategy.vault()` — so no
    ///      account needs a new pointer, and one owner transaction covers the whole user base.
    ///
    ///      DENOMINATION IS SHARES (12dp), NOT USDC. An account's share balance cannot drift on its
    ///      own (fee-shares mint to the fee recipient, never to accounts), so the cap needs no
    ///      oracle and withdrawals free room automatically. The trade-off is that the cap's DOLLAR
    ///      meaning drifts UPWARD as the fund earns: `shares = assets × (supply + 1e6) / (nav + 1)`,
    ///      so a richer book mints fewer shares per dollar and a fixed share cap admits more dollars.
    ///      Use {previewSharesForAssets} to derive the number to set; never hand-compute the 12dp
    ///      figure.
    ///
    ///      `0` means unlimited rather than frozen so a fresh deployment is not bricked before the
    ///      owner acts; the freeze case is already served by {depositsOpen}.
    uint256 public maxSharesPerAccount;

    // ==================== EVENTS ====================

    event StrategySet(address indexed strategy);
    event OpenDepositsUpdated(bool open);
    event MaxSharesPerAccountSet(uint256 maxShares);
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
     * @notice Bind an ALREADY-initialized strategy clone. Set-once: the share ledger's integrity
     *         rests entirely on `msg.sender == strategy`, so a rotatable pointer would let a future
     *         owner mint freely against existing holders.
     * @dev The clone must already point back here (`strategy_.vault() == address(this)`). Binding a
     *      clone initialized against a DIFFERENT vault would hand this ledger's mint/burn hooks to a
     *      contract pricing another book — the only way to catch that is to ask the clone.
     */
    function setStrategy(address strategy_) external onlyOwner {
        _bind(strategy_);
    }

    /**
     * @notice Deploy an ERC-1167 clone of `template`, initialize it against THIS vault, and bind it
     *         — atomically, in one owner transaction.
     * @dev Closes the init/bind race the two-transaction flow leaves open: a clone deployed and left
     *      uninitialized can be `initialize`d by anyone (the template's constructor only locks the
     *      TEMPLATE), so between a bare `Clones.clone` and the owner's `initialize` a front-runner
     *      can seize the proposer role. Cloning + initializing + binding in one call removes the gap;
     *      `_bind` re-checks the binding, so this cannot bind a foreign-vault clone either.
     * @param template  The strategy template to clone (its constructor locked its own `initialize`).
     * @param proposer_ The proposer role for the new clone.
     * @param initData  ABI-encoded strategy-specific init params.
     * @return clone    The deployed, initialized and bound clone.
     */
    function cloneAndBind(address template, address proposer_, bytes calldata initData)
        external
        onlyOwner
        returns (address clone)
    {
        require(strategy == address(0), "LAV: strategy already set");
        clone = Clones.clone(template);
        IStrategy(clone).initialize(address(this), proposer_, initData);
        _bind(clone);
    }

    /// @dev Shared set-once bind. Both entrypoints route here so the checks can never drift apart.
    function _bind(address strategy_) private {
        require(strategy == address(0), "LAV: strategy already set");
        require(strategy_ != address(0), "LAV: invalid strategy");
        require(IStrategy(strategy_).vault() == address(this), "LAV: strategy not bound to this vault");
        strategy = strategy_;
        emit StrategySet(strategy_);
    }

    /// @notice Open / close new share issuance. Redemptions are unaffected (see {strategyBurn}).
    function setOpenDeposits(bool open) external onlyOwner {
        depositsOpen = open;
        emit OpenDepositsUpdated(open);
    }

    /// @notice Set the per-account share ceiling every {MamoLeveragedAeroStrategy} account enforces.
    ///         `0` == unlimited. Takes effect immediately for every account, including existing ones.
    /// @dev Derive `maxShares` from {previewSharesForAssets} rather than hand-computing it — shares
    ///      are 12dp against a 6dp asset, so an off-by-1e6 sets a ceiling a million times wrong.
    ///      Lowering the cap below a holder's existing balance does NOT unwind or trap them: the cap
    ///      gates new deposits only, and every withdrawal path is independent of it.
    /// @param maxShares New ceiling in vault shares (12dp); `0` disables the cap.
    function setMaxSharesPerAccount(uint256 maxShares) external onlyOwner {
        maxSharesPerAccount = maxShares;
        emit MaxSharesPerAccountSet(maxShares);
    }

    /// @notice ADVISORY: the shares a deposit of `assets` USDC would mint at CURRENT pricing — the
    ///         one canonical conversion for choosing the {setMaxSharesPerAccount} argument.
    /// @dev Mirrors the strategy's own deposit formula
    ///      (`mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navNet + 1)`) against the live book.
    ///      POINT-IN-TIME, NOT A PEG: the answer moves with NAV and supply, so a cap set from it
    ///      represents that dollar figure only at the instant it was read (see the drift note on
    ///      {maxSharesPerAccount}). Reverts if the strategy's NAV is unpriceable, exactly as a real
    ///      deposit would — it is a preview of a deposit, and inherits its fail-closed posture.
    /// @param assets USDC (6dp) to convert.
    /// @return shares Vault shares (12dp) that amount would mint right now.
    function previewSharesForAssets(uint256 assets) external view returns (uint256 shares) {
        require(strategy != address(0), "LAV: strategy unset");
        // `SHARES_VIRTUAL_OFFSET` is 1e6 in the strategy; it is the same 6-decimal step `decimals()`
        // documents, so it is derived here rather than duplicated as a second magic constant.
        uint256 offset = 10 ** (decimals() - IERC20Metadata(asset).decimals());
        shares = Math.mulDiv(assets, totalSupply() + offset, IStrategyNav(strategy).nav() + 1);
    }

    /// @notice Point the strategy's protocol-fee lookup at a config contract, or clear it
    ///         (`address(0)` → fees off). Read live by the strategy on every crystallise.
    /// @dev OWNER-TRUSTED, and deliberately unvalidated + mutable. The pointed-at contract supplies
    ///      both `protocolFeeBps()` and `protocolFeeRecipient()` LIVE on every crystallise — no cap,
    ///      no timelock, no snapshot — so an owner may raise the protocol fee or redirect the
    ///      recipient with effect from the next accrual. The management + performance ceilings are
    ///      enforced at strategy init and are NOT affected; this is the protocol leg only. The owner
    ///      is expected to be MAMO_MULTISIG. Blast radius the other way too: a config whose reads
    ///      REVERT hard-reverts `compound()` / `_settle()` / the redeem skim (those reads are
    ///      deliberately un-try'd), so point this only at a contract known to answer.
    function setFeeConfig(address feeConfig_) external onlyOwner {
        feeConfig = feeConfig_;
        emit FeeConfigUpdated(feeConfig_);
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
     *
     *      - The ASSET is claimable only once `totalSupply() == 0`: pre-settlement any asset balance
     *        is dust/donations, and post-settlement it is the {redeemSettled} pot, so the owner may
     *        not touch it while a single share is outstanding.
     *      - The vault's OWN share token is never rescuable. The strategy custodies live shares
     *        (`requestRedeem` escrows, and the shares it pulls mid-`redeem`); a share balance that
     *        reaches this contract is someone's un-burned claim on the pot, not a stray, so
     *        forwarding it to an owner-chosen address would be an exfiltration of depositor value.
     *        Escrowed shares are recovered by their owner through the strategy's `cancelRedeem`.
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "LAV: invalid recipient");
        require(token != address(this), "LAV: cannot rescue shares");
        require(token != asset || totalSupply() == 0, "LAV: asset reserved for redemptions");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
