// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "../BatchExecutorLib.sol";

interface ISyndicateVault {
    // ── Errors ──
    error InvalidOwner();
    error InvalidExecutorImpl();
    error NotActiveAgent();
    error SimulationFailed();
    error InvalidDepositor();
    error DepositorAlreadyApproved();
    error DepositorNotApproved();
    error NotApprovedDepositor();
    error AgentAlreadyRegistered();
    error AgentNotActive();
    /// @notice PR #324 review R4 — registering this agent would push
    ///         `_agentSet.length()` past `MAX_AGENTS_PER_VAULT`. Bound for the
    ///         `rotateOwnership` deactivation loop.
    error AgentCapExceeded();
    error InvalidAgentRegistry();
    error NotAgentOwner();
    error NotGovernor();
    error RedemptionsLocked();
    error DepositsLocked();
    error InvalidAgentAddress();
    error TransferFailed();
    error ZeroAddress();
    error CannotRescueAsset();
    error NotFactory();
    error GovernorNotSet();
    error ExecutorCodehashMismatch();
    error InvalidAsset();
    /// @notice `transferPerformanceFee` was called with an `amount` exceeding
    ///         the vault's balance of `asset_`.
    error AmountExceedsBalance();
    error WithdrawalQueueNotSet();
    error WithdrawalQueueAlreadySet();
    error InsufficientShares();
    error RedemptionsNotLocked();
    error QueueReserveBreached();
    error NotQueue();
    error ZeroAssets();
    error SharesLocked();
    error NotActiveStrategy();
    /// @notice `setAgentFeeBps` was called with `bps > MAX_AGENT_FEE_BPS`.
    error AgentFeeTooHigh();

    // ── Init Params ──
    struct InitParams {
        address asset;
        string name;
        string symbol;
        address owner;
        address executorImpl;
        bool openDeposits;
        address agentRegistry;
        uint256 managementFeeBps;
    }

    // ── Per-Agent Config ──
    struct AgentConfig {
        uint256 agentId; // ERC-8004 identity token ID
        address agentAddress; // Agent wallet address
        bool active;
    }

    // ── Depositor Whitelist ──
    function approveDepositor(address depositor) external;
    function removeDepositor(address depositor) external;
    function approveDepositors(address[] calldata depositors) external;
    function isApprovedDepositor(address depositor) external view returns (bool);
    function approvedDepositorsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory);
    function setOpenDeposits(bool open) external;
    function openDeposits() external view returns (bool);

    // ── Views ──
    // `getAgentConfig` dropped to fit MAX_AGENTS_PER_VAULT cap under
    // EIP-170. Use `isAgent(addr)` for the auth check.
    function getAgentCount() external view returns (uint256);
    function agentsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory);
    function isAgent(address agentAddress) external view returns (bool);

    // ── Factory ──
    function factory() external view returns (address);

    // ── Governor ──
    function executeGovernorBatch(BatchExecutorLib.Call[] calldata calls) external;
    function owner() external view returns (address);
    function transferPerformanceFee(address asset, address to, uint256 amount) external;
    function governor() external view returns (address);
    function redemptionsLocked() external view returns (bool);
    function managementFeeBps() external view returns (uint256);
    /// @notice Vault-owner-set agent performance fee (basis points). Defaults
    ///         to 5% (500) at vault creation. Snapshotted onto a proposal at
    ///         propose time and clamped to `maxPerformanceFeeBps` at settlement.
    function agentFeeBps() external view returns (uint256);
    /// @notice Set the agent performance fee (owner only). Capped at
    ///         `MAX_AGENT_FEE_BPS` (15%). Reverts with `AgentFeeTooHigh` above.
    function setAgentFeeBps(uint256 bps) external;
    /// @notice Convenience view that resolves the active strategy through the
    ///         governor (`getProposal(activePid).strategy`). Returns
    ///         `address(0)` when no proposal is active or when the active
    ///         proposal opted out of live NAV.
    function activeStrategyAdapter() external view returns (address);

    // ── Async Withdrawal Queue ──
    function setWithdrawalQueue(address queue) external; // factory-only, set-once
    function withdrawalQueue() external view returns (address);
    function requestRedeem(uint256 shares, address owner_) external returns (uint256 requestId);
    function requestDeposit(uint256 assets, address receiver) external returns (uint256 requestId);
    function pendingQueueShares() external view returns (uint256);
    function reservedQueueAssets() external view returns (uint256);
    function settleRedeem(uint256 shares, uint256 assets, address to) external; // queue-only
    function settleDeposit(uint256 shares, address to) external; // queue-only
    function onProposalSettled(uint256 proposalId) external; // governor-only
    function strategyMint(address to, uint256 shares) external; // active-strategy-only
    function strategyBurn(uint256 shares) external; // active-strategy-only

    // ── Rescue ──
    function rescueEth(address payable to, uint256 amount) external;
    function rescueERC20(address token, address to, uint256 amount) external;
    function rescueERC721(address token, uint256 tokenId, address to) external;

    // ── Admin (syndicate creator) ──
    function registerAgent(uint256 agentId, address agentAddress) external;
    function removeAgent(address agentAddress) external;
    function pause() external;
    function unpause() external;

    // ── Events ──
    event AgentRegistered(uint256 indexed agentId, address indexed agentAddress);
    event AgentRemoved(address indexed agentAddress);
    event DepositorApproved(address indexed depositor);
    event DepositorRemoved(address indexed depositor);
    event OpenDepositsUpdated(bool open);
    /// @notice Emitted when the vault owner updates the agent performance fee.
    event AgentFeeUpdated(uint256 bps);
    /// @notice Emitted whenever the governor drives a strategy batch into the
    ///         vault via `executeGovernorBatch`. `callCount` is the number of
    ///         sub-calls fanned out by `BatchExecutorLib.executeBatch`.
    /// @dev V-M9: subgraphs and monitors previously had to observe strategy
    ///      execution indirectly via downstream protocol events (Moonwell /
    ///      Aerodrome / Uniswap). Emitting here gives a first-class
    ///      vault-level execution marker.
    event GovernorBatchExecuted(address indexed governor, uint256 callCount);
    event WithdrawalQueueSet(address indexed queue);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    event DepositRequested(uint256 indexed requestId, address indexed receiver, uint256 assets);
}
