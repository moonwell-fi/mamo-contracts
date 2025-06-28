// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountRegistry} from "@contracts/AccountRegistry.sol";

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";

import {IPool} from "@interfaces/IPool.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IMulticall} from "@interfaces/IMulticall.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MamoStakingStrategy
 * @notice Executes automated reward claiming and processing logic with enhanced capabilities
 * @dev Supports multiple reward tokens, permissionless deposits, and configurable DEX routing
 */
contract MamoStakingStrategy is AccessControlEnumerable, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Backend role for strategy management
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Guardian role for emergency pause functionality
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice The AccountRegistry contract for permission management
    AccountRegistry public immutable registry;

    /// @notice The MultiRewards contract for staking
    IMultiRewards public immutable multiRewards;

    /// @notice The MAMO token contract
    IERC20 public immutable mamoToken;

    /// @notice Reward token configuration
    struct RewardToken {
        address token;
        address strategy;
        address pool; // Pool address for swapping this token to MAMO
    }

    /// @notice Dynamic reward token management
    RewardToken[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => address) public tokenToStrategy;

    /// @notice Configurable DEX router
    ISwapRouter public dexRouter;

    /// @notice Mapping of account to compound mode
    mapping(address => CompoundMode) public accountCompoundMode;

    /// @notice Compound mode enum
    enum CompoundMode {
        COMPOUND, // Convert reward tokens to MAMO and restake everything
        REINVEST // Restake MAMO, deposit other rewards to ERC20Strategy

    }

    event Deposited(address indexed account, address indexed depositor, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Compounded(address indexed account, uint256 mamoAmount, uint256[] rewardAmounts);
    event Reinvested(address indexed account, uint256 mamoAmount, uint256[] rewardAmounts);
    event CompoundModeUpdated(address indexed account, CompoundMode newMode);
    event RewardTokenAdded(address indexed token);
    event RewardTokenRemoved(address indexed token);
    event DEXRouterUpdated(address indexed oldRouter, address indexed newRouter);

    /**
     * @notice Constructor sets up the strategy with required contracts and parameters
     * @param admin The address to grant the DEFAULT_ADMIN_ROLE to
     * @param backend The address to grant the BACKEND_ROLE to
     * @param guardian The address to grant the GUARDIAN_ROLE to
     * @param _registry The AccountRegistry contract
     * @param _multiRewards The MultiRewards contract
     * @param _mamoToken The MAMO token contract
     * @param _dexRouter The initial DEX router contract
     */
    constructor(
        address admin,
        address backend,
        address guardian,
        AccountRegistry _registry,
        IMultiRewards _multiRewards,
        IERC20 _mamoToken,
        ISwapRouter _dexRouter
    ) {
        require(admin != address(0), "Invalid admin address");
        require(backend != address(0), "Invalid backend address");
        require(guardian != address(0), "Invalid guardian address");
        require(address(_registry) != address(0), "Invalid registry");
        require(address(_multiRewards) != address(0), "Invalid multiRewards");
        require(address(_mamoToken) != address(0), "Invalid mamoToken");
        require(address(_dexRouter) != address(0), "Invalid dexRouter");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);
        _grantRole(GUARDIAN_ROLE, guardian);

        registry = _registry;
        multiRewards = _multiRewards;
        mamoToken = _mamoToken;
        dexRouter = _dexRouter;
    }

    modifier onlyAccountOwner(address account) {
        require(account != address(0), "Invalid account");
        require(Ownable(account).owner() == msg.sender, "Not account owner");
        _;
    }

    /**
     * @notice Add a reward token with its strategy and pool (backend only)
     * @param token The reward token address to add
     * @param strategy The strategy contract address for this token
     * @param pool The pool address for swapping this token to MAMO
     */
    function addRewardToken(address token, address strategy, address pool)
        external
        onlyRole(BACKEND_ROLE)
        whenNotPaused
    {
        require(token != address(0), "Invalid token");
        require(strategy != address(0), "Invalid strategy");
        require(pool != address(0), "Invalid pool");
        require(!isRewardToken[token], "Token already added");
        require(token != address(mamoToken), "Cannot add staking token as a reward token");

        rewardTokens.push(RewardToken({token: token, strategy: strategy, pool: pool}));
        isRewardToken[token] = true;
        tokenToStrategy[token] = strategy;

        emit RewardTokenAdded(token);
    }

    /**
     * @notice Remove a reward token (backend only)
     * @param token The reward token address to remove
     */
    function removeRewardToken(address token) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(isRewardToken[token], "Token not found");

        // Find and remove token from array
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i].token == token) {
                rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
                rewardTokens.pop();
                break;
            }
        }

        isRewardToken[token] = false;
        delete tokenToStrategy[token];

        emit RewardTokenRemoved(token);
    }

    /**
     * @notice Update DEX router (backend only)
     * @param newRouter The new DEX router address
     */
    function setDEXRouter(ISwapRouter newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(newRouter) != address(0), "Invalid router");

        address oldRouter = address(dexRouter);
        dexRouter = newRouter;

        emit DEXRouterUpdated(oldRouter, address(newRouter));
    }

    /**
     * @notice Set compound mode for an account
     * @param account The account address
     * @param mode The compound mode to set
     */
    function setCompoundMode(address account, CompoundMode mode) external onlyAccountOwner(account) whenNotPaused {
        accountCompoundMode[account] = mode;
        emit CompoundModeUpdated(account, mode);
    }

    /**
     * @notice Deposit MAMO tokens into MultiRewards on behalf of account (permissionless)
     * @param account The account address
     * @param amount The amount of MAMO to deposit
     */
    function deposit(address account, uint256 amount) external whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");
        require(account != address(0), "Invalid account");

        // Transfer MAMO from depositor to account
        mamoToken.safeTransferFrom(msg.sender, account, amount);

        // Approve and stake in MultiRewards on behalf of account
        bytes memory approveData = abi.encodeWithSelector(IERC20.approve.selector, address(multiRewards), amount);
        bytes memory stakeData = abi.encodeWithSelector(IMultiRewards.stake.selector, amount);

        // Call stake through the account's multicall function
        IMulticall.Call[] memory calls = new IMulticall.Call[](2);
        calls[0] = IMulticall.Call({target: address(mamoToken), data: approveData, value: 0});
        calls[1] = IMulticall.Call({target: address(multiRewards), data: stakeData, value: 0});
        MamoAccount(account).multicall(calls);

        emit Deposited(account, msg.sender, amount);
    }

    /**
     * @notice Withdraw MAMO tokens from MultiRewards on behalf of account
     * @param account The account address
     * @param amount The amount of MAMO to withdraw
     */
    function withdraw(address account, uint256 amount) external onlyAccountOwner(account) whenNotPaused {
        require(amount > 0, "Amount must be greater than 0");

        // Call withdraw through the account's execute function
        bytes memory withdrawData = abi.encodeWithSelector(IMultiRewards.withdraw.selector, amount);

        IMulticall.Call[] memory calls = new IMulticall.Call[](2);
        calls[0] = IMulticall.Call({target: address(multiRewards), data: withdrawData, value: 0});

        // Transfer withdrawn MAMO to account owner
        calls[1] = IMulticall.Call({
            target: address(mamoToken),
            data: abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amount),
            value: 0
        });

        MamoAccount(account).multicall(calls);

        emit Withdrawn(account, amount);
    }

    /**
     * @notice Process rewards according to the account's preferred compound mode
     * @param account The account address
     */
    function processRewards(address account) external onlyRole(BACKEND_ROLE) whenNotPaused {
        CompoundMode accountMode = accountCompoundMode[account];
        if (accountMode == CompoundMode.COMPOUND) {
            _compound(account);
        } else {
            _reinvest(account);
        }
    }

    /**
     * @notice Internal function to compound rewards by converting all rewards to MAMO and restaking
     * @param account The account address
     */
    function _compound(address account) internal {
        // Claim rewards through account
        bytes memory getRewardData = abi.encodeWithSelector(IMultiRewards.getReward.selector);
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: address(multiRewards), data: getRewardData, value: 0});
        MamoAccount(account).multicall(calls);

        uint256[] memory rewardAmounts = new uint256[](rewardTokens.length);

        // Process each reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(account);
            rewardAmounts[i] = rewardBalance;

            if (rewardBalance == 0) continue;

            // Swap reward tokens to MAMO
            uint256 remainingReward = rewardBalance;
            if (remainingReward > 0) {
                // Get tickSpacing from the pool
                address poolAddress = rewardTokens[i].pool;
                int24 tickSpacing = _getPoolTickSpacing(poolAddress);

                // Approve DEX router to spend reward tokens and swap using SwapRouter
                bytes memory approveData =
                    abi.encodeWithSelector(IERC20.approve.selector, address(dexRouter), remainingReward);

                // Create swap parameters
                ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(rewardToken),
                    tokenOut: address(mamoToken),
                    tickSpacing: tickSpacing,
                    recipient: account,
                    deadline: block.timestamp + 300,
                    amountIn: remainingReward,
                    amountOutMinimum: 0, // Accept any amount of MAMO
                    sqrtPriceLimitX96: 0 // No price limit
                });

                bytes memory swapData = abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, swapParams);

                IMulticall.Call[] memory swapCalls = new IMulticall.Call[](2);
                swapCalls[0] = IMulticall.Call({target: address(rewardToken), data: approveData, value: 0});
                swapCalls[1] = IMulticall.Call({target: address(dexRouter), data: swapData, value: 0});
                MamoAccount(account).multicall(swapCalls);
            }
        }

        // Stake all MAMO
        uint256 totalMamo = mamoToken.balanceOf(account);
        if (totalMamo > 0) {
            // Approve MultiRewards to spend MAMO and stake in a single multicall
            bytes memory approveData = abi.encodeWithSelector(IERC20.approve.selector, address(multiRewards), totalMamo);
            bytes memory stakeData = abi.encodeWithSelector(IMultiRewards.stake.selector, totalMamo);

            IMulticall.Call[] memory mamoCalls = new IMulticall.Call[](2);
            mamoCalls[0] = IMulticall.Call({target: address(mamoToken), data: approveData, value: 0});
            mamoCalls[1] = IMulticall.Call({target: address(multiRewards), data: stakeData, value: 0});
            MamoAccount(account).multicall(mamoCalls);
        }

        emit Compounded(account, totalMamo, rewardAmounts);
    }

    /**
     * @notice Internal function to reinvest rewards by staking MAMO and depositing other rewards to Morpho strategy
     * @param account The account address
     */
    function _reinvest(address account) internal {
        // Claim rewards through account
        bytes memory getRewardData = abi.encodeWithSelector(IMultiRewards.getReward.selector);
        IMulticall.Call[] memory calls = new IMulticall.Call[](1);
        calls[0] = IMulticall.Call({target: address(multiRewards), data: getRewardData, value: 0});
        MamoAccount(account).multicall(calls);

        // Get MAMO balance
        uint256 mamoBalance = mamoToken.balanceOf(account);
        uint256[] memory rewardAmounts = new uint256[](rewardTokens.length);

        // Stake MAMO
        if (mamoBalance > 0) {
            // Approve MultiRewards to spend MAMO and stake in a single multicall
            bytes memory approveData =
                abi.encodeWithSelector(IERC20.approve.selector, address(multiRewards), mamoBalance);
            bytes memory stakeData = abi.encodeWithSelector(IMultiRewards.stake.selector, mamoBalance);

            IMulticall.Call[] memory mamoStakeCalls = new IMulticall.Call[](2);
            mamoStakeCalls[0] = IMulticall.Call({target: address(mamoToken), data: approveData, value: 0});
            mamoStakeCalls[1] = IMulticall.Call({target: address(multiRewards), data: stakeData, value: 0});
            MamoAccount(account).multicall(mamoStakeCalls);
        }

        // Process each reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            address strategyAddress = rewardTokens[i].strategy;
            uint256 rewardBalance = rewardToken.balanceOf(account);
            rewardAmounts[i] = rewardBalance;

            if (rewardBalance == 0) continue;

            // Deposit reward tokens to the configured strategy
            if (rewardBalance > 0) {
                // Validate strategy ownership - strategy must be owned by the same user as the account
                address accountOwner = Ownable(account).owner();
                address strategyOwner = Ownable(strategyAddress).owner();
                require(accountOwner == strategyOwner, "Strategy owner mismatch");

                // Approve strategy to spend reward tokens and deposit in a single multicall
                bytes memory approveData =
                    abi.encodeWithSelector(IERC20.approve.selector, strategyAddress, rewardBalance);
                bytes memory depositData =
                    abi.encodeWithSelector(ERC20MoonwellMorphoStrategy.deposit.selector, rewardBalance);

                IMulticall.Call[] memory strategyCalls = new IMulticall.Call[](2);
                strategyCalls[0] = IMulticall.Call({target: address(rewardToken), data: approveData, value: 0});
                strategyCalls[1] = IMulticall.Call({target: strategyAddress, data: depositData, value: 0});
                MamoAccount(account).multicall(strategyCalls);
            }
        }

        emit Reinvested(account, mamoBalance, rewardAmounts);
    }

    /**
     * @notice Get all reward tokens
     * @return Array of RewardToken structs
     */
    function getRewardTokens() external view returns (RewardToken[] memory) {
        return rewardTokens;
    }

    /**
     * @notice Get the number of reward tokens
     * @return The number of reward tokens
     */
    function getRewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    /**
     * @notice Internal function to get the tick spacing from a pool contract
     * @param pool The pool address
     * @return tickSpacing The pool tick spacing
     */
    function _getPoolTickSpacing(address pool) internal view returns (int24 tickSpacing) {
        tickSpacing = IPool(pool).tickSpacing();
    }

    /**
     * @notice Pause the strategy (guardian only)
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the strategy (guardian only)
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}
