// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICLGauge} from "@interfaces/ICLGauge.sol";
import {ICLPool} from "@interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";

import {IPriceFeed} from "@interfaces/IPriceFeed.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {FixedPoint96} from "@libraries/uniswap/FixedPoint96.sol";
import {FullMath} from "@libraries/uniswap/FullMath.sol";
import {LiquidityAmounts} from "@libraries/uniswap/LiquidityAmounts.sol";
import {TickMath} from "@libraries/uniswap/TickMath.sol";

/// @title LPAutoBalancer
/// @notice Safe-governed, multi-position Aerodrome CL rebalancer. Holds position NFTs,
///         re-ranges them with on-chain-computed ticks, stakes for AERO emissions, and
///         skims fees/emissions to the weekly drop. See docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md
contract LPAutoBalancer is AccessControlEnumerable, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_SLIPPAGE_CAP_BPS = 500;
    uint16 public constant MAX_LOSS_CAP_BPS = 500;
    uint256 public constant SWAP_DEADLINE_BUFFER = 300;

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    ISwapRouter public immutable SWAP_ROUTER;
    IQuoter public immutable QUOTER;
    address public immutable AERO;

    uint256 public maxOracleDelay;

    struct ManagedPosition {
        uint256 tokenId;
        address pool;
        address token0;
        address token1;
        int24 tickSpacing;
        address gauge;
        bool staked;
        address feeCollector;
        address oracle0;
        address oracle1;
        uint8 swapPolicy; // 0 = either; 1 = counter-asset only (never sell protectedToken); 2 = protected only
        address protectedToken;
        uint24 minWidth;
        uint24 maxWidth;
        uint24 maxCenterDeviation;
        uint16 maxSlippageBps;
        uint32 twapWindow;
        int24 maxTickDeviation;
        uint16 maxRebalanceLossBps;
        uint256 minRebalanceInterval;
        uint256 lastRebalance;
        bool active;
    }

    mapping(uint256 => ManagedPosition) public positions;
    uint256 public nextSlotId;

    error ZeroAddress();
    error SlippageCapExceeded();
    error LossCapExceeded();
    error InvalidWidth();
    error OracleRequired();
    error InvalidConfig();
    error NotActive();
    error NotHeld();

    event PositionRegistered(uint256 indexed slotId, address indexed pool, uint256 indexed tokenId);
    event PositionDeregistered(uint256 indexed slotId, address indexed to);

    constructor(
        address admin_,
        address manager_,
        address rebalancer_,
        address guardian_,
        address positionManager_,
        address swapRouter_,
        address quoter_,
        address aero_
    ) {
        if (
            admin_ == address(0) || positionManager_ == address(0) || swapRouter_ == address(0) || quoter_ == address(0)
                || aero_ == address(0)
        ) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (manager_ != address(0)) _grantRole(MANAGER_ROLE, manager_);
        if (rebalancer_ != address(0)) _grantRole(REBALANCER_ROLE, rebalancer_);
        if (guardian_ != address(0)) _grantRole(GUARDIAN_ROLE, guardian_);

        POSITION_MANAGER = INonfungiblePositionManager(positionManager_);
        SWAP_ROUTER = ISwapRouter(swapRouter_);
        QUOTER = IQuoter(quoter_);
        AERO = aero_;
        maxOracleDelay = 26 hours;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(POSITION_MANAGER), "Only position manager");
        return this.onERC721Received.selector;
    }

    /// @notice Register a position NFT already held by this contract.
    /// @param config Full position configuration. `active`, `staked`, and `lastRebalance` are
    ///               overridden by `_store` regardless of the values supplied here.
    /// @return slotId The slot index assigned to this position.
    function registerPosition(ManagedPosition calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 slotId)
    {
        if (config.maxSlippageBps > MAX_SLIPPAGE_CAP_BPS) revert SlippageCapExceeded();
        if (config.maxRebalanceLossBps > MAX_LOSS_CAP_BPS) revert LossCapExceeded();
        if (config.pool == address(0) || config.token0 == address(0) || config.token1 == address(0)) {
            revert InvalidConfig();
        }
        if (config.oracle0 == address(0) || config.oracle1 == address(0)) revert OracleRequired();
        if (config.twapWindow == 0 || config.maxTickDeviation <= 0) revert InvalidConfig();
        int24 spacing = config.tickSpacing;
        if (spacing <= 0) revert InvalidConfig();
        if (
            config.minWidth == 0 || config.minWidth > config.maxWidth || config.minWidth % uint24(spacing) != 0
                || config.maxWidth % uint24(spacing) != 0
        ) revert InvalidWidth();
        if (POSITION_MANAGER.ownerOf(config.tokenId) != address(this)) revert NotHeld();

        slotId = nextSlotId++;
        _store(slotId, config);
        emit PositionRegistered(slotId, config.pool, config.tokenId);
    }

    /// @notice Deregister a position and transfer its NFT to `to`.
    ///         Requires the position to not be staked (unstake first via Task 13).
    function deregisterPosition(uint256 slotId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ManagedPosition storage p = positions[slotId];
        if (!p.active) revert NotActive();
        // NOTE: staked-unstake handling is added in Task 13 (_unstake does not exist yet).
        // For now, require not staked so we never silently strand a staked NFT.
        require(!p.staked, "unstake first");
        POSITION_MANAGER.safeTransferFrom(address(this), to, p.tokenId);
        p.active = false;
        emit PositionDeregistered(slotId, to);
    }

    /// @dev Copies every field from `config` into `positions[slotId]`, but forces
    ///      `active = true`, `staked = false`, and `lastRebalance = 0`.
    function _store(uint256 slotId, ManagedPosition calldata config) private {
        ManagedPosition storage p = positions[slotId];
        p.tokenId = config.tokenId;
        p.pool = config.pool;
        p.token0 = config.token0;
        p.token1 = config.token1;
        p.tickSpacing = config.tickSpacing;
        p.gauge = config.gauge;
        p.staked = false; // forced
        p.feeCollector = config.feeCollector;
        p.oracle0 = config.oracle0;
        p.oracle1 = config.oracle1;
        p.swapPolicy = config.swapPolicy;
        p.protectedToken = config.protectedToken;
        p.minWidth = config.minWidth;
        p.maxWidth = config.maxWidth;
        p.maxCenterDeviation = config.maxCenterDeviation;
        p.maxSlippageBps = config.maxSlippageBps;
        p.twapWindow = config.twapWindow;
        p.maxTickDeviation = config.maxTickDeviation;
        p.maxRebalanceLossBps = config.maxRebalanceLossBps;
        p.minRebalanceInterval = config.minRebalanceInterval;
        p.lastRebalance = 0; // forced
        p.active = true; // forced
    }
}
