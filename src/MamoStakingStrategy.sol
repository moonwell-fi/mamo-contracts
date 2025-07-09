// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";

import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";
import {IERC20MoonwellMorphoStrategy} from "@interfaces/IERC20MoonwellMorphoStrategy.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";

import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IPool} from "@interfaces/IPool.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed token, uint256 amount);
    event CompoundRewardTokenProcessed(address indexed rewardToken, uint256 amountIn, uint256 amountOut);
    event ReinvestRewardTokenProcessed(address indexed rewardToken, uint256 amount);
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
        require(stakingRegistry.hasRole(stakingRegistry.BACKEND_ROLE(), msg.sender), "Not backend");
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

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        stakingRegistry = MamoStakingRegistry(params.stakingRegistry);
        multiRewards = IMultiRewards(params.multiRewards);
        mamoToken = IERC20(params.mamoToken);
    }

    /**
     * @notice Set slippage tolerance for this strategy
     * @param slippageInBps The slippage tolerance in basis points (e.g., 100 = 1%)
     */
    function setAccountSlippage(uint256 slippageInBps) external onlyOwner {
        require(slippageInBps <= stakingRegistry.MAX_SLIPPAGE_IN_BPS(), "Slippage too high");

        emit AccountSlippageUpdated(accountSlippageInBps, slippageInBps);
        accountSlippageInBps = slippageInBps;
    }

    /**
     * @notice Get the slippage tolerance for this strategy
     * @return The slippage tolerance in basis points (falls back to global if not set)
     */
    function getAccountSlippage() public view returns (uint256) {
        return accountSlippageInBps > 0 ? accountSlippageInBps : stakingRegistry.defaultSlippageInBps();
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

        emit Withdrawn(address(mamoToken), amount);
    }

    /**
     * @notice Withdraw all staked MAMO tokens from MultiRewards and claim rewards
     */
    function withdrawAll() external onlyOwner {
        uint256 stakedBalance = multiRewards.balanceOf(address(this));
        require(stakedBalance > 0, "No tokens to withdraw");

        // Exit from MultiRewards (withdraws all staked tokens and claims rewards)
        multiRewards.exit();

        // Transfer all MAMO tokens (original stake + any MAMO rewards) to owner
        uint256 mamoBalance = mamoToken.balanceOf(address(this));
        if (mamoBalance > 0) {
            mamoToken.safeTransfer(msg.sender, mamoBalance);
            emit Withdrawn(address(mamoToken), mamoBalance);
        }

        // Transfer all claimed reward tokens to owner
        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(address(this));
            if (rewardBalance > 0) {
                rewardToken.safeTransfer(msg.sender, rewardBalance);
                emit Withdrawn(address(rewardToken), rewardBalance);
            }
        }
    }

    /**
     * @notice Compound all available rewards by converting them to MAMO and restaking
     * @dev Claims rewards and then compounds them. Can be called independently.
     */
    function compound() external onlyBackend {
        multiRewards.getReward();

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
            int24 tickSpacing = IPool(poolAddress).tickSpacing();

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
            uint256 accountSlippage = getAccountSlippage();
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

            // Execute swap and capture actual amount out
            uint256 actualAmountOut = dexRouter.exactInputSingle(swapParams);

            emit CompoundRewardTokenProcessed(address(rewardToken), rewardBalance, actualAmountOut);
        }

        // Stake all MAMO
        uint256 totalMamo = mamoToken.balanceOf(address(this));
        _stakeMamo(totalMamo);

        emit Compounded(totalMamo);
    }

    /**
     * @notice Reinvest rewards by staking MAMO and depositing other rewards to ERC20 strategies
     * @param rewardStrategies Array of strategy addresses for each reward token (must match rewardTokens order)
     * @dev Claims rewards and then reinvests them. We trust the backend to provide correct user-owned strategies.
     */
    function reinvest(address[] calldata rewardStrategies) external onlyBackend {
        multiRewards.getReward();

        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
        require(rewardStrategies.length == rewardTokens.length, "Strategies length mismatch");

        uint256 mamoBalance = mamoToken.balanceOf(address(this));

        // Stake MAMO
        _stakeMamo(mamoBalance);

        // Process each reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(address(this));

            if (rewardBalance == 0) continue;

            address strategyAddress = rewardStrategies[i];

            // Validate strategy ownership - strategy must be owned by the same user as this strategy
            address strategyOwner = Ownable(strategyAddress).owner();
            require(owner() == strategyOwner, "Strategy owner mismatch");

            // Validate strategy is whitelisted in the registry
            require(mamoStrategyRegistry.isUserStrategy(owner(), strategyAddress), "Strategy not registered");

            // Validate strategy token - strategy must handle the same token as the reward token
            IERC20MoonwellMorphoStrategy strategy = IERC20MoonwellMorphoStrategy(strategyAddress);
            require(address(strategy.token()) == address(rewardToken), "Strategy token mismatch");

            // Approve strategy to spend reward tokens and deposit
            rewardToken.forceApprove(strategyAddress, rewardBalance);
            strategy.deposit(rewardBalance);

            emit ReinvestRewardTokenProcessed(address(rewardToken), rewardBalance);
        }

        emit Reinvested(mamoBalance);
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
}
