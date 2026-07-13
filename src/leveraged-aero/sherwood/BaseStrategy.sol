// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Position} from "./interfaces/IPriceRouter.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BaseStrategy
 * @notice Abstract base for strategy contracts. The vault calls execute() and
 *         settle() via batch calls — the strategy pulls tokens, deploys them
 *         into DeFi, and returns them on settlement.
 *
 *   Designed for Clones (ERC-1167) — deploy template once, clone per proposal.
 *
 *   Typical batch calls from the governor:
 *     Execute: [approve(strategy, amount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 *
 *   The strategy holds custody of position tokens (e.g., mUSDC) during the
 *   strategy period. On settlement, underlying returns to the vault.
 *
 *   Proposer can update tunable params (slippage, amounts) between execute
 *   and settle — no new proposal needed.
 */
abstract contract BaseStrategy is IStrategy {
    using SafeERC20 for IERC20;

    // ── Errors ──
    error AlreadyInitialized();
    error NotProposer();
    error NotVault();
    error NotExecuted();
    error AlreadyExecuted();
    error AlreadySettled();
    error ZeroAddress();

    // ── State ──
    enum State {
        Pending,
        Executed,
        Settled
    }

    // slot 0: reserved for HyperCore FirstStorageSlot registration.
    // HyperliquidGridStrategy._initialize() writes address(this) here so HC
    // reads slot 0 post-block and confirms it equals the contract address.
    // Other strategies leave this as address(0) — no functional impact.
    address internal _hcSelf;
    address private _vault;
    address private _proposer;
    State internal _state;
    bool private _initialized;

    /**
     * @notice Disables `initialize` on the template itself so an attacker
     *         can't front-run a clone deploy with their own init.
     * @dev Constructors are NOT executed for ERC-1167 minimal proxies, so
     *      `Clones.clone(template)` produces a clone with `_initialized = false`,
     *      keeping atomic `cloneAndInit` flows working. Only the template
     *      contract — deployed via `new` — is permanently locked.
     */
    constructor() {
        _initialized = true;
    }

    modifier onlyProposer() {
        if (msg.sender != _proposer) revert NotProposer();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != _vault) revert NotVault();
        _;
    }

    /// @inheritdoc IStrategy
    /// @dev Stamps `_hcSelf = address(this)` at slot 0 BEFORE delegating to
    ///      `_initialize` so HyperCore's FirstStorageSlot finalize variant
    ///      always sees the correct value. Foolproof for every strategy that
    ///      inherits BaseStrategy — strategy-specific `_initialize` overrides
    ///      cannot forget the stamp. Slot 0 is reserved for this purpose at
    ///      the storage layout level (see `_hcSelf` declaration above);
    ///      non-Hyperliquid strategies pay the cost (one SSTORE) but get
    ///      consistent layout in exchange.
    function initialize(address vault_, address proposer_, bytes calldata data) external {
        if (_initialized) revert AlreadyInitialized();
        if (vault_ == address(0)) revert ZeroAddress();
        if (proposer_ == address(0)) revert ZeroAddress();
        _initialized = true;
        _hcSelf = address(this);
        _vault = vault_;
        _proposer = proposer_;
        _state = State.Pending;

        _initialize(data);
    }

    /// @notice Slot 0 contents — used by HyperCore FirstStorageSlot variant.
    ///         Should equal `address(this)` after `initialize`. Diagnostic only.
    function hcSelf() external view returns (address) {
        return _hcSelf;
    }

    /// @inheritdoc IStrategy
    function execute() external onlyVault {
        if (_state != State.Pending) revert AlreadyExecuted();
        _state = State.Executed;
        _execute();
    }

    /// @inheritdoc IStrategy
    function settle() external onlyVault {
        if (_state != State.Executed) revert NotExecuted();
        _state = State.Settled;
        _settle();
    }

    /// @inheritdoc IStrategy
    function updateParams(bytes calldata data) external virtual onlyProposer {
        if (_state != State.Executed) revert NotExecuted();
        _updateParams(data);
    }

    /// @inheritdoc IStrategy
    function vault() public view returns (address) {
        return _vault;
    }

    /// @inheritdoc IStrategy
    function proposer() public view returns (address) {
        return _proposer;
    }

    /// @inheritdoc IStrategy
    function executed() external view returns (bool) {
        return _state == State.Executed;
    }

    /// @notice Current lifecycle state
    function state() external view returns (State) {
        return _state;
    }

    /// @inheritdoc IStrategy
    /// @dev Default: no instant-priceable positions (queue-only / Lane B).
    ///      Strategies whose positions the PriceRouter can value override this.
    function positions() external view virtual returns (Position[] memory) {
        return new Position[](0);
    }

    /// @inheritdoc IStrategy
    /// @dev Default: governor distributes settle-fees. Self-fee'd strategies override to `true`.
    ///      NOTE: `true` makes the governor skip ALL settle-fees (protocol + guardian + agent +
    ///      management) — a self-fee'd strategy MUST self-collect the protocol fee itself (see
    ///      LeveragedAerodromeCLStrategy's `protocolFeeOwed` leg) or the protocol earns nothing.
    function selfManagesFees() external view virtual returns (bool) {
        return false;
    }

    // ── Internal helpers ──

    /// @notice Pull tokens from the vault into this strategy
    function _pullFromVault(address token, uint256 amount) internal {
        IERC20(token).safeTransferFrom(_vault, address(this), amount);
    }

    /// @notice Push tokens from this strategy back to the vault
    function _pushToVault(address token, uint256 amount) internal {
        IERC20(token).safeTransfer(_vault, amount);
    }

    /// @notice Push entire balance of a token back to the vault
    function _pushAllToVault(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(_vault, bal);
    }

    // ── Abstract hooks for concrete strategies ──

    /// @notice Strategy-specific initialization (decode params from data)
    function _initialize(bytes calldata data) internal virtual;

    /// @notice Execute the strategy — pull tokens, deploy into DeFi
    function _execute() internal virtual;

    /// @notice Settle the strategy — unwind positions, push tokens back to vault
    function _settle() internal virtual;

    /// @notice Update tunable parameters (decode from data)
    function _updateParams(bytes calldata data) internal virtual;
}
