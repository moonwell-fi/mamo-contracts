// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";

import {IERC20MoonwellMorphoStrategy} from "@interfaces/IERC20MoonwellMorphoStrategy.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";

import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IPool} from "@interfaces/IPool.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MamoStakingStrategy
 * @notice A per-user staking strategy for MAMO tokens with automated reward claiming and processing
 * @dev This contract is designed to be used as an implementation for proxies, similar to ERC20MoonwellMorphoStrategy
 */
contract MamoStakingStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice The MultiRewards contract for staking
    IMultiRewards public multiRewards;

    /// @notice The MAMO token contract
    IERC20 public mamoToken;

    /// @notice The MamoStakingRegistry for configuration
    MamoStakingRegistry public stakingRegistry;

    /// @notice The user's allowed slippage in basis points
    uint256 public accountSlippageInBps;

    /// @notice Strategy mode enum
    enum StrategyMode {
        COMPOUND, // Convert reward tokens to MAMO and restake everything
        REINVEST // Restake MAMO, deposit other rewards to ERC20Strategy

    }

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(uint256 amount);
    event RewardTokenProcessed(address indexed rewardToken, uint256 amount, StrategyMode mode);
    event Compounded(uint256 mamoAmount);
    event Reinvested(uint256 mamoAmount);
    event AccountSlippageUpdated(uint256 oldSlippageInBps, uint256 newSlippageInBps);

    /// @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address stakingRegistry;
        address multiRewards;
        address mamoToken;
        uint256 strategyTypeId;
        address owner;
        uint256 allowedSlippageInBps;
    }

    /**
     * @notice Constructor disables initializers in the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Restricts function access to the backend address only
     * @dev Uses the MamoStrategyRegistry to verify the caller is the backend
     */
    modifier onlyBackend() {
        require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
        _;
    }

    /**
     * @notice Initializer function that sets all the parameters
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.stakingRegistry != address(0), "Invalid stakingRegistry address");
        require(params.multiRewards != address(0), "Invalid multiRewards address");
        require(params.mamoToken != address(0), "Invalid mamoToken address");
        require(params.strategyTypeId != 0, "Strategy type id not set");
        require(params.owner != address(0), "Invalid owner address");
        require(params.allowedSlippageInBps <= 2500, "Slippage too high");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        stakingRegistry = MamoStakingRegistry(params.stakingRegistry);
        multiRewards = IMultiRewards(params.multiRewards);
        mamoToken = IERC20(params.mamoToken);
        accountSlippageInBps = params.allowedSlippageInBps;
    }


    /**
     * @notice Set slippage tolerance for this strategy
     * @param slippageInBps The slippage tolerance in basis points (e.g., 100 = 1%)
     */
    function setAccountSlippage(uint256 slippageInBps) external onlyOwner {
        require(slippageInBps <= 2500, "Slippage too high"); // Max 25%
        emit AccountSlippageUpdated(accountSlippageInBps, slippageInBps);
        accountSlippageInBps = slippageInBps;
    }

    /**
     * @notice Deposit MAMO tokens into MultiRewards (permissionless)
     * @param amount The amount of MAMO to deposit
     */
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer MAMO from depositor to this contract
        mamoToken.safeTransferFrom(msg.sender, address(this), amount);

        _stakeMamo(amount);

        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw MAMO tokens from MultiRewards
     * @param amount The amount of MAMO to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");

        // Withdraw from MultiRewards
        multiRewards.withdraw(amount);

        // Transfer withdrawn MAMO to owner
        mamoToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(amount);
    }

    /**
     * @notice Process rewards according to the specified compound mode
     * @param mode The strategy mode to use for processing rewards
     * @param rewardStrategies Array of strategy addresses for each reward token (must match rewardTokens order, only needed for REINVEST mode)
     * @dev We trust the backend to provide the correct user-owned strategies for each reward token
     */
    function processRewards(StrategyMode mode, address[] calldata rewardStrategies) external onlyBackend {
        _claimRewards();

        if (mode == StrategyMode.COMPOUND) {
            _compound();
        } else {
            require(rewardStrategies.length == rewardTokens.length, "Strategies length mismatch");
            _reinvest(rewardStrategies);
        }
    }

    /**
     * @notice Internal function to claim rewards from MultiRewards contract
     */
    function _claimRewards() internal {
        multiRewards.getReward();
    }

    /**
     * @notice Internal function to stake MAMO tokens in MultiRewards
     * @param amount The amount of MAMO to stake
     */
    function _stakeMamo(uint256 amount) internal {
        if (amount == 0) return;

        mamoToken.forceApprove(address(multiRewards), amount);
        multiRewards.stake(amount);
    }

    /**
     * @notice Internal function to compound rewards by converting all rewards to MAMO and restaking
     */
    function _compound() internal {
        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
        ISwapRouter dexRouter = stakingRegistry.dexRouter();
        IQuoter quoter = stakingRegistry.quoter();

        // Process each reward token by swapping to MAMO
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(address(this));

            if (rewardBalance == 0) continue;

            // Swap reward tokens to MAMO
            // Get tickSpacing from the pool
            address poolAddress = rewardTokens[i].pool;
            int24 tickSpacing = _getPoolTickSpacing(poolAddress);

            // Get quote from quoter to calculate minimum amount out with slippage
            (uint256 amountOut,,,) = quoter.quoteExactInputSingle(
                IQuoter.QuoteExactInputSingleParams({
                    tokenIn: address(rewardToken),
                    tokenOut: address(mamoToken),
                    amountIn: rewardBalance,
                    tickSpacing: tickSpacing,
                    sqrtPriceLimitX96: 0
                })
            );

            // Apply slippage tolerance to get minimum amount out
            uint256 accountSlippage = _getAccountSlippage();
            uint256 amountOutMinimum = (amountOut * (10000 - accountSlippage)) / 10000;

            // Approve DEX router to spend reward tokens
            rewardToken.forceApprove(address(dexRouter), rewardBalance);

            // Create swap parameters
            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(rewardToken),
                tokenOut: address(mamoToken),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: rewardBalance,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0 // No price limit
            });

            // Execute swap
            dexRouter.exactInputSingle(swapParams);

            emit RewardTokenProcessed(address(rewardToken), rewardBalance, StrategyMode.COMPOUND);
        }

        // Stake all MAMO
        uint256 totalMamo = mamoToken.balanceOf(address(this));
        _stakeMamo(totalMamo);

        emit Compounded(totalMamo);
    }

    /**
     * @notice Internal function to reinvest rewards by staking MAMO and depositing other rewards to Morpho strategy
     * @param rewardStrategies Array of strategy addresses for each reward token
     */
    function _reinvest(address[] calldata rewardStrategies) internal {
        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
        uint256 mamoBalance = mamoToken.balanceOf(address(this));

        // Stake MAMO
        _stakeMamo(mamoBalance);

        // Process each reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            address strategyAddress = rewardStrategies[i];
            uint256 rewardBalance = rewardToken.balanceOf(address(this));

            if (rewardBalance == 0) continue;

            // Validate strategy ownership - strategy must be owned by the same user as this strategy
            address strategyOwner = Ownable(strategyAddress).owner();
            require(owner() == strategyOwner, "Strategy owner mismatch");

            // Validate strategy token - strategy must handle the same token as the reward token
            IERC20MoonwellMorphoStrategy strategy = IERC20MoonwellMorphoStrategy(strategyAddress);
            require(address(strategy.token()) == address(rewardToken), "Strategy token mismatch");

            // Approve strategy to spend reward tokens and deposit
            rewardToken.forceApprove(strategyAddress, rewardBalance);
            strategy.deposit(rewardBalance);

            emit RewardTokenProcessed(address(rewardToken), rewardBalance, StrategyMode.REINVEST);
        }

        emit Reinvested(mamoBalance);
    }

    /**
     * @notice Get all reward tokens from the registry
     * @return Array of RewardToken structs
     */
    function getRewardTokens() external view returns (MamoStakingRegistry.RewardToken[] memory) {
        return stakingRegistry.getRewardTokens();
    }


    /**
     * @notice Get the slippage tolerance for this strategy
     * @return The slippage tolerance in basis points (falls back to global if not set)
     */
    function getAccountSlippage() external view returns (uint256) {
        return _getAccountSlippage();
    }

    /**
     * @notice Internal function to get the slippage tolerance for this strategy
     * @return The slippage tolerance in basis points (falls back to global if not set)
     */
    function _getAccountSlippage() internal view returns (uint256) {
        return accountSlippageInBps > 0 ? accountSlippageInBps : allowedSlippageInBps;
    }

    /**
     * @notice Internal function to get the tick spacing from a pool contract
     * @param pool The pool address
     * @return tickSpacing The pool tick spacing
     */
    function _getPoolTickSpacing(address pool) internal view returns (int24 tickSpacing) {
        tickSpacing = IPool(pool).tickSpacing();
    }
}
