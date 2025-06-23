// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountRegistry} from "@contracts/AccountRegistry.sol";

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoAccount} from "@contracts/MamoAccount.sol";

import {IDEXRouter} from "@interfaces/IDEXRouter.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
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

    /// @notice The ERC20MoonwellMorphoStrategy for reinvest mode
    ERC20MoonwellMorphoStrategy public immutable morphoStrategy;

    /// @notice The compound fee in basis points (immutable)
    uint256 public immutable compoundFee;

    /// @notice Dynamic reward token management
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;

    /// @notice Configurable DEX router
    IDEXRouter public dexRouter;

    /// @notice Mapping of account to compound mode
    mapping(address => CompoundMode) public accountCompoundMode;

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
     * @param _morphoStrategy The ERC20MoonwellMorphoStrategy contract
     * @param _compoundFee The compound fee in basis points
     */
    constructor(
        address admin,
        address backend,
        address guardian,
        AccountRegistry _registry,
        IMultiRewards _multiRewards,
        IERC20 _mamoToken,
        IDEXRouter _dexRouter,
        ERC20MoonwellMorphoStrategy _morphoStrategy,
        uint256 _compoundFee
    ) {
        require(admin != address(0), "Invalid admin address");
        require(backend != address(0), "Invalid backend address");
        require(guardian != address(0), "Invalid guardian address");
        require(address(_registry) != address(0), "Invalid registry");
        require(address(_multiRewards) != address(0), "Invalid multiRewards");
        require(address(_mamoToken) != address(0), "Invalid mamoToken");
        require(address(_dexRouter) != address(0), "Invalid dexRouter");
        require(address(_morphoStrategy) != address(0), "Invalid morphoStrategy");
        require(_compoundFee <= 1000, "Fee too high"); // Max 10%

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);
        _grantRole(GUARDIAN_ROLE, guardian);

        registry = _registry;
        multiRewards = _multiRewards;
        mamoToken = _mamoToken;
        dexRouter = _dexRouter;
        morphoStrategy = _morphoStrategy;
        compoundFee = _compoundFee;
    }

    modifier onlyAccountOwner(address account) {
        require(Ownable(account).owner() == msg.sender, "Not account owner");
        _;
    }

    /**
     * @notice Add a reward token (backend only)
     * @param token The reward token address to add
     */
    function addRewardToken(address token) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(token != address(0), "Invalid token");
        require(!isRewardToken[token], "Token already added");

        rewardTokens.push(token);
        isRewardToken[token] = true;

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
            if (rewardTokens[i] == token) {
                rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
                rewardTokens.pop();
                break;
            }
        }

        isRewardToken[token] = false;

        emit RewardTokenRemoved(token);
    }

    /**
     * @notice Update DEX router (backend only)
     * @param newRouter The new DEX router address
     */
    function setDEXRouter(IDEXRouter newRouter) external onlyRole(BACKEND_ROLE) {
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

        // Transfer MAMO from depositor to this contract
        mamoToken.safeTransferFrom(msg.sender, address(this), amount);

        // Approve and stake in MultiRewards on behalf of account
        mamoToken.safeApprove(address(multiRewards), amount);

        // Call stake through the account's execute function
        bytes memory stakeData = abi.encodeWithSelector(IMultiRewards.stake.selector, amount);

        MamoAccount(account).execute(address(multiRewards), stakeData);

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

        MamoAccount(account).execute(address(multiRewards), withdrawData);

        // Transfer withdrawn MAMO to account owner
        mamoToken.safeTransfer(msg.sender, amount);

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
        MamoAccount(account).execute(address(multiRewards), getRewardData);

        // Get MAMO balance
        uint256 mamoBalance = mamoToken.balanceOf(account);
        uint256[] memory rewardAmounts = new uint256[](rewardTokens.length);

        // Process each reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i]);
            uint256 rewardBalance = rewardToken.balanceOf(account);
            rewardAmounts[i] = rewardBalance;

            if (rewardBalance == 0) continue;

            // Calculate and transfer fee
            uint256 rewardFee = (rewardBalance * compoundFee) / 10000;
            if (rewardFee > 0) {
                bytes memory transferFeeData =
                    abi.encodeWithSelector(IERC20.transfer.selector, registry.feeCollector(), rewardFee);
                MamoAccount(account).execute(address(rewardToken), transferFeeData);
            }

            // Swap remaining reward tokens to MAMO
            uint256 remainingReward = rewardBalance - rewardFee;
            if (remainingReward > 0 && address(rewardToken) != address(mamoToken)) {
                // Approve DEX router to spend reward tokens
                bytes memory approveData =
                    abi.encodeWithSelector(IERC20.approve.selector, address(dexRouter), remainingReward);
                MamoAccount(account).execute(address(rewardToken), approveData);

                // Swap tokens
                bytes memory swapData = abi.encodeWithSelector(
                    IDEXRouter.swapExactTokensForTokens.selector,
                    remainingReward,
                    0, // Accept any amount of MAMO
                    _getPath(address(rewardToken), address(mamoToken)),
                    account,
                    block.timestamp + 300
                );
                MamoAccount(account).execute(address(dexRouter), swapData);
            }
        }

        // Handle MAMO fee
        if (mamoBalance > 0) {
            uint256 mamoFee = (mamoBalance * compoundFee) / 10000;
            if (mamoFee > 0) {
                bytes memory transferMamoFeeData =
                    abi.encodeWithSelector(IERC20.transfer.selector, registry.feeCollector(), mamoFee);
                MamoAccount(account).execute(address(mamoToken), transferMamoFeeData);
            }
        }

        // Stake all MAMO
        uint256 totalMamo = mamoToken.balanceOf(account);
        if (totalMamo > 0) {
            // Approve MultiRewards to spend MAMO
            bytes memory approveData = abi.encodeWithSelector(IERC20.approve.selector, address(multiRewards), totalMamo);
            MamoAccount(account).execute(address(mamoToken), approveData);

            // Stake MAMO
            bytes memory stakeData = abi.encodeWithSelector(IMultiRewards.stake.selector, totalMamo);
            MamoAccount(account).execute(address(multiRewards), stakeData);
        }

        emit Compounded(account, mamoBalance, rewardAmounts);
    }

    /**
     * @notice Internal function to reinvest rewards by staking MAMO and depositing other rewards to Morpho strategy
     * @param account The account address
     */
    function _reinvest(address account) internal {
        // Claim rewards through account
        bytes memory getRewardData = abi.encodeWithSelector(IMultiRewards.getReward.selector);
        MamoAccount(account).execute(address(multiRewards), getRewardData);

        // Get MAMO balance
        uint256 mamoBalance = mamoToken.balanceOf(account);
        uint256[] memory rewardAmounts = new uint256[](rewardTokens.length);

        // Handle MAMO fee and staking
        if (mamoBalance > 0) {
            uint256 mamoFee = (mamoBalance * compoundFee) / 10000;
            if (mamoFee > 0) {
                bytes memory transferMamoFeeData =
                    abi.encodeWithSelector(IERC20.transfer.selector, registry.feeCollector(), mamoFee);
                MamoAccount(account).execute(address(mamoToken), transferMamoFeeData);
            }

            // Stake remaining MAMO
            uint256 remainingMamo = mamoBalance - mamoFee;
            if (remainingMamo > 0) {
                // Approve MultiRewards to spend MAMO
                bytes memory approveData =
                    abi.encodeWithSelector(IERC20.approve.selector, address(multiRewards), remainingMamo);
                MamoAccount(account).execute(address(mamoToken), approveData);

                // Stake MAMO
                bytes memory stakeData = abi.encodeWithSelector(IMultiRewards.stake.selector, remainingMamo);
                MamoAccount(account).execute(address(multiRewards), stakeData);
            }
        }

        // Process each reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i]);
            uint256 rewardBalance = rewardToken.balanceOf(account);
            rewardAmounts[i] = rewardBalance;

            if (rewardBalance == 0 || address(rewardToken) == address(mamoToken)) continue;

            // Calculate and transfer fee
            uint256 rewardFee = (rewardBalance * compoundFee) / 10000;
            if (rewardFee > 0) {
                bytes memory transferFeeData =
                    abi.encodeWithSelector(IERC20.transfer.selector, registry.feeCollector(), rewardFee);
                MamoAccount(account).execute(address(rewardToken), transferFeeData);
            }

            // Deposit remaining reward tokens to Morpho strategy
            uint256 remainingReward = rewardBalance - rewardFee;
            if (remainingReward > 0) {
                // Approve Morpho strategy to spend reward tokens
                bytes memory approveData =
                    abi.encodeWithSelector(IERC20.approve.selector, address(morphoStrategy), remainingReward);
                MamoAccount(account).execute(address(rewardToken), approveData);

                // Deposit to Morpho strategy
                bytes memory depositData =
                    abi.encodeWithSelector(ERC20MoonwellMorphoStrategy.deposit.selector, remainingReward);
                MamoAccount(account).execute(address(morphoStrategy), depositData);
            }
        }

        emit Reinvested(account, mamoBalance, rewardAmounts);
    }

    /**
     * @notice Get all reward tokens
     * @return Array of reward token addresses
     */
    function getRewardTokens() external view returns (address[] memory) {
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
     * @notice Internal function to get swap path between two tokens
     * @param tokenA The input token
     * @param tokenB The output token
     * @return path The swap path
     */
    function _getPath(address tokenA, address tokenB) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
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
