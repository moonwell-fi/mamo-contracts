// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

/**
 * @title MamoStakingRegistry
 * @notice Centralized registry for managing MAMO staking system configuration
 * @dev Provides configuration management for reward tokens, DEX settings, and slippage parameters
 */
contract MamoStakingRegistry is AccessControlEnumerable, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Backend role for configuration management
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    /// @notice Guardian role for emergency pause functionality
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Reward token configuration
    struct RewardToken {
        address token;
        address pool; // Pool address for swapping this token to MAMO
    }

    /// @notice Global reward token configuration
    RewardToken[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => uint256) public rewardTokenToIndex;

    /// @notice Global DEX configuration
    ISwapRouter public dexRouter;
    IQuoter public quoter;

    /// @notice Global slippage configuration
    uint256 public defaultSlippageInBps;

    /// @notice MAMO token address
    address public immutable mamoToken;

    event RewardTokenAdded(address indexed token, address indexed pool);
    event RewardTokenRemoved(address indexed token);
    event RewardTokenPoolUpdated(address indexed token, address indexed oldPool, address indexed newPool);
    event DEXRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event QuoterUpdated(address indexed oldQuoter, address indexed newQuoter);
    event DefaultSlippageUpdated(uint256 oldSlippageInBps, uint256 newSlippageInBps);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Constructor that sets up initial roles and configuration
     * @param admin The address to grant the DEFAULT_ADMIN_ROLE to
     * @param backend The address to grant the BACKEND_ROLE to
     * @param guardian The address to grant the GUARDIAN_ROLE to
     * @param _mamoToken The MAMO token address
     * @param _dexRouter The initial DEX router address
     * @param _quoter The initial quoter address
     * @param _defaultSlippageInBps The initial default slippage in basis points
     */
    constructor(
        address admin,
        address backend,
        address guardian,
        address _mamoToken,
        address _dexRouter,
        address _quoter,
        uint256 _defaultSlippageInBps
    ) {
        require(admin != address(0), "Invalid admin address");
        require(backend != address(0), "Invalid backend address");
        require(guardian != address(0), "Invalid guardian address");
        require(_mamoToken != address(0), "Invalid MAMO token address");
        require(_dexRouter != address(0), "Invalid DEX router address");
        require(_quoter != address(0), "Invalid quoter address");
        require(_defaultSlippageInBps <= 2500, "Default slippage too high");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);
        _grantRole(GUARDIAN_ROLE, guardian);

        mamoToken = _mamoToken;
        dexRouter = ISwapRouter(_dexRouter);
        quoter = IQuoter(_quoter);
        defaultSlippageInBps = _defaultSlippageInBps;
    }

    // ==================== REWARD TOKEN MANAGEMENT ====================

    /**
     * @notice Add a reward token with its pool (backend only)
     * @param token The reward token address to add
     * @param pool The pool address for swapping this token to MAMO
     */
    function addRewardToken(address token, address pool) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(token != address(0), "Invalid token");
        require(pool != address(0), "Invalid pool");
        require(!isRewardToken[token], "Token already added");
        require(token != mamoToken, "Cannot add MAMO token as reward");

        rewardTokenToIndex[token] = rewardTokens.length;
        rewardTokens.push(RewardToken({token: token, pool: pool}));
        isRewardToken[token] = true;

        emit RewardTokenAdded(token, pool);
    }

    /**
     * @notice Remove a reward token (backend only)
     * @param token The reward token address to remove
     */
    function removeRewardToken(address token) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(isRewardToken[token], "Token not found");

        uint256 index = rewardTokenToIndex[token];
        uint256 lastIndex = rewardTokens.length - 1;

        // Move the last element to the deleted spot
        if (index != lastIndex) {
            RewardToken memory lastToken = rewardTokens[lastIndex];
            rewardTokens[index] = lastToken;
            rewardTokenToIndex[lastToken.token] = index;
        }

        // Remove the last element
        rewardTokens.pop();
        delete rewardTokenToIndex[token];
        isRewardToken[token] = false;

        emit RewardTokenRemoved(token);
    }

    /**
     * @notice Update the pool address for a reward token (backend only)
     * @param token The reward token address
     * @param newPool The new pool address
     */
    function updateRewardTokenPool(address token, address newPool) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(isRewardToken[token], "Token not found");
        require(newPool != address(0), "Invalid pool");

        uint256 index = rewardTokenToIndex[token];
        address oldPool = rewardTokens[index].pool;
        rewardTokens[index].pool = newPool;

        emit RewardTokenPoolUpdated(token, oldPool, newPool);
    }

    // ==================== DEX CONFIGURATION ====================

    /**
     * @notice Update DEX router (backend only)
     * @param newRouter The new DEX router address
     */
    function setDEXRouter(ISwapRouter newRouter) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(address(newRouter) != address(0), "Invalid router");

        address oldRouter = address(dexRouter);
        dexRouter = newRouter;

        emit DEXRouterUpdated(oldRouter, address(newRouter));
    }

    /**
     * @notice Set quoter contract (backend only)
     * @param _quoter The quoter contract address
     */
    function setQuoter(IQuoter _quoter) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(address(_quoter) != address(0), "Invalid quoter");

        address oldQuoter = address(quoter);
        quoter = _quoter;

        emit QuoterUpdated(oldQuoter, address(_quoter));
    }

    // ==================== SLIPPAGE CONFIGURATION ====================

    /**
     * @notice Set default slippage tolerance (backend only)
     * @param _defaultSlippageInBps The default slippage tolerance in basis points (e.g., 100 = 1%)
     */
    function setDefaultSlippage(uint256 _defaultSlippageInBps) external onlyRole(BACKEND_ROLE) whenNotPaused {
        require(_defaultSlippageInBps <= 2500, "Slippage too high"); // Max 25%

        uint256 oldSlippage = defaultSlippageInBps;
        defaultSlippageInBps = _defaultSlippageInBps;

        emit DefaultSlippageUpdated(oldSlippage, _defaultSlippageInBps);
    }

    // ==================== VIEW FUNCTIONS ====================

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
     * @notice Get reward token at a specific index
     * @param index The index of the reward token
     * @return The RewardToken struct at the given index
     */
    function getRewardToken(uint256 index) external view returns (RewardToken memory) {
        require(index < rewardTokens.length, "Index out of bounds");
        return rewardTokens[index];
    }

    /**
     * @notice Get the pool address for a specific reward token
     * @param token The reward token address
     * @return The pool address for the token
     */
    function getRewardTokenPool(address token) external view returns (address) {
        require(isRewardToken[token], "Token not found");
        uint256 index = rewardTokenToIndex[token];
        return rewardTokens[index].pool;
    }

    // ==================== RECOVERY FUNCTIONS ====================

    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @dev Only callable by accounts with the DEFAULT_ADMIN_ROLE
     * @param tokenAddress The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address tokenAddress, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(tokenAddress).safeTransfer(to, amount);

        emit TokenRecovered(tokenAddress, to, amount);
    }

    /**
     * @notice Recovers ETH accidentally sent to this contract
     * @dev Only callable by accounts with the DEFAULT_ADMIN_ROLE
     * @param to The address to send the ETH to
     */
    function recoverETH(address payable to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Cannot send to zero address");

        uint256 balance = address(this).balance;
        require(balance > 0, "Empty balance");

        (bool success,) = to.call{value: balance}("");
        require(success, "Transfer failed");

        emit TokenRecovered(address(0), to, balance);
    }

    // ==================== GUARDIAN FUNCTIONS ====================

    /**
     * @notice Pauses the contract in case of emergency
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract after an emergency is resolved
     * @dev Only callable by accounts with the GUARDIAN_ROLE
     */
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }
}