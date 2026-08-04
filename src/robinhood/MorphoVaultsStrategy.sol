// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";

import {IERC4626} from "@interfaces/IERC4626.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

import {MamoVaultConfig} from "@contracts/robinhood/MamoVaultConfig.sol";
import {IUniswapV3SwapRouter} from "@contracts/robinhood/interfaces/IUniswapV3SwapRouter.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMerkleDistributor {
    function claim(
        address[] calldata accounts,
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata proofs
    ) external;
}

/**
 * @title MorphoVaultsStrategy
 * @notice Per-user strategy that allocates a single ERC20 across N ERC4626 (MetaMorpho) vaults
 * @notice IMPORTANT: This contract does not support fee-on-transfer tokens.
 * @dev The Robinhood Chain counterpart of ERC20MoonwellMorphoStrategy, generalised for a chain where
 *      Morpho is the only lending primitive:
 *      - The fixed {Moonwell mToken, one MetaMorpho vault} pair becomes a dynamic set of ERC4626 vaults
 *        with basis-point weights. The backend rebalances across the set, but only vaults allowlisted in
 *        the multisig-owned MamoVaultConfig are eligible — venue changes are scoped to admin operations.
 *      - User deposits are metered against a global supply cap in MamoVaultConfig.
 *      - Reward compounding swaps through a Uniswap V3 style router with an oracle-derived minimum out
 *        (via SlippagePriceChecker), replacing the CoW Protocol EIP-1271 flow, which does not exist on
 *        Robinhood Chain. Rewards are claimed from a Merkl-style distributor, same as on Base.
 */
contract MorphoVaultsStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice Total basis points used for split calculations (100%)
    uint256 public constant SPLIT_TOTAL = 10000;

    /// @notice The maximum allowed slippage in basis points
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500;

    /// @notice The maximum allowed compound fee in basis points
    uint256 public constant MAX_COMPOUND_FEE = 1000;

    /// @notice Reference to the ERC20 token this strategy allocates
    IERC20 public token;

    /// @notice Shared multisig-owned config: vault allowlist + supply cap
    MamoVaultConfig public vaultConfig;

    /// @notice Oracle-based price checker used to bound reward swaps
    ISlippagePriceChecker public slippagePriceChecker;

    /// @notice Uniswap V3 style router used for reward swaps
    IUniswapV3SwapRouter public dexRouter;

    /// @notice Merkl-style distributor rewards are claimed from
    address public merkleDistributor;

    /// @notice Current vault set the position is spread across
    address[] public vaults;

    /// @notice Basis-point weight per vault, parallel to `vaults`, sums to SPLIT_TOTAL
    uint256[] public weightsBps;

    /// @notice The allowed slippage for reward swaps in basis points
    uint256 public allowedSlippageInBps;

    /// @notice The compound fee in basis points, skimmed from swapped rewards
    uint256 public compoundFee;

    /// @notice The fee recipient address
    address public feeRecipient;

    event Deposit(address indexed asset, uint256 amount);
    event DepositIdle(address indexed asset, uint256 amount);
    event Withdraw(address indexed asset, uint256 amount);
    event PositionUpdated(address[] vaults, uint256[] weightsBps);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);
    event RewardsClaimed(address[] rewardTokens, uint256[] rewardAmounts);
    event RewardsCompounded(address indexed rewardToken, uint256 amountIn, uint256 amountOut, uint256 feeAmount);

    /// @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address token;
        address vaultConfig;
        address slippagePriceChecker;
        address dexRouter;
        address merkleDistributor;
        address feeRecipient;
        uint256 strategyTypeId;
        address owner;
        uint256 allowedSlippageInBps;
        uint256 compoundFee;
        address[] vaults;
        uint256[] weightsBps;
    }

    /**
     * @notice Restricts function access to the backend address only
     */
    modifier onlyBackend() {
        require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
        _;
    }

    // ==================== INITIALIZER ====================

    /**
     * @notice Initializer function that sets all the parameters
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.token != address(0), "Invalid token address");
        require(params.vaultConfig != address(0), "Invalid vaultConfig address");
        require(params.slippagePriceChecker != address(0), "Invalid slippagePriceChecker address");
        require(params.dexRouter != address(0), "Invalid dexRouter address");
        require(params.merkleDistributor != address(0), "Invalid merkleDistributor address");
        require(params.feeRecipient != address(0), "Invalid fee recipient address");
        require(params.strategyTypeId != 0, "Strategy type id not set");
        require(params.allowedSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");
        require(params.compoundFee <= MAX_COMPOUND_FEE, "Compound fee exceeds maximum");
        require(MamoVaultConfig(params.vaultConfig).asset() == params.token, "Config asset mismatch");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        token = IERC20(params.token);
        vaultConfig = MamoVaultConfig(params.vaultConfig);
        slippagePriceChecker = ISlippagePriceChecker(params.slippagePriceChecker);
        dexRouter = IUniswapV3SwapRouter(params.dexRouter);
        merkleDistributor = params.merkleDistributor;
        feeRecipient = params.feeRecipient;
        allowedSlippageInBps = params.allowedSlippageInBps;
        compoundFee = params.compoundFee;

        _setAllocations(params.vaults, params.weightsBps);
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Sets a new slippage tolerance value
     * @param _newSlippageInBps The new slippage tolerance in basis points
     */
    function setSlippage(uint256 _newSlippageInBps) external onlyOwner {
        require(_newSlippageInBps <= MAX_SLIPPAGE_IN_BPS, "Slippage exceeds maximum");

        emit SlippageUpdated(allowedSlippageInBps, _newSlippageInBps);
        allowedSlippageInBps = _newSlippageInBps;
    }

    /**
     * @notice Withdraws funds from the strategy
     * @dev Pulls idle balance first, then withdraws from vaults in order until the amount is covered,
     *      so it stays robust when actual vault balances have drifted from the target weights
     * @param amount The amount to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(getTotalBalance() >= amount, "Withdrawal amount exceeds available balance in strategy");

        uint256 idleBalance = token.balanceOf(address(this));

        if (idleBalance < amount) {
            uint256 remaining = amount - idleBalance;

            for (uint256 i = 0; i < vaults.length && remaining > 0; i++) {
                IERC4626 vault = IERC4626(vaults[i]);
                // NOTE: Morpho Vault V2 returns 0 from maxWithdraw/maxDeposit by design, so available
                // liquidity is derived from the share balance instead of the max* views
                uint256 available = vault.convertToAssets(vault.balanceOf(address(this)));
                if (available == 0) continue;

                uint256 toWithdraw = remaining > available ? available : remaining;
                vault.withdraw(toWithdraw, address(this), address(this));
                remaining -= toWithdraw;
            }
        }

        require(token.balanceOf(address(this)) >= amount, "Withdrawal failed: insufficient funds");

        vaultConfig.recordWithdraw(amount);

        token.safeTransfer(msg.sender, amount);

        emit Withdraw(address(token), amount);
    }

    /**
     * @notice Withdraws all funds from the strategy
     */
    function withdrawAll() external onlyOwner {
        _redeemAllFromVaults();

        uint256 finalBalance = token.balanceOf(address(this));
        require(finalBalance > 0, "No tokens to withdraw");

        vaultConfig.recordWithdraw(finalBalance);

        token.safeTransfer(msg.sender, finalBalance);

        emit Withdraw(address(token), finalBalance);
    }

    // ==================== BACKEND FUNCTIONS ====================

    /**
     * @notice Rebalances the position to a new vault set and weights
     * @dev Only vaults allowlisted in the MamoVaultConfig are eligible, so the backend can move funds
     *      freely between approved venues but can never introduce a new venue on its own
     * @param newVaults The new vault set
     * @param newWeightsBps The new basis-point weights, parallel to newVaults
     */
    function updatePosition(address[] calldata newVaults, uint256[] calldata newWeightsBps) external onlyBackend {
        _redeemAllFromVaults();

        uint256 totalTokenBalance = token.balanceOf(address(this));
        require(totalTokenBalance > 0, "Nothing to rebalance");

        _setAllocations(newVaults, newWeightsBps);

        _depositInternal(totalTokenBalance);

        emit PositionUpdated(newVaults, newWeightsBps);
    }

    /**
     * @notice Claims rewards from the Merkl-style distributor on behalf of this strategy
     * @param rewardTokens The addresses of the reward tokens
     * @param rewardAmounts The amounts of the reward tokens
     * @param proofs The proofs of the reward tokens
     */
    function claimRewards(
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata proofs
    ) external onlyBackend {
        require(rewardTokens.length == rewardAmounts.length, "Reward tokens and amounts length mismatch");
        require(rewardTokens.length == proofs.length, "Reward tokens and proofs length mismatch");

        address[] memory accounts = new address[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            accounts[i] = address(this);
        }

        IMerkleDistributor(merkleDistributor).claim(accounts, rewardTokens, rewardAmounts, proofs);

        emit RewardsClaimed(rewardTokens, rewardAmounts);
    }

    /**
     * @notice Swaps the full balance of a reward token into the strategy token and redeposits it
     * @dev Replaces the CoW Protocol flow on chains without CoW. The minimum output is derived from the
     *      oracle price via SlippagePriceChecker, so the backend chooses WHEN to swap and through WHICH
     *      fee tier, but can never accept a worse price than the oracle-bounded slippage allows.
     * @param rewardToken The reward token to compound
     * @param poolFee The Uniswap V3 fee tier to route through
     * @param backendMinOut Backend-supplied minimum output; the effective floor is the max of this and
     *        the oracle floor, so neither a careless keeper nor a manipulated pool can realize rewards
     *        below the bound (the two-sided floor pattern from the audited LeveragedAero compound path)
     */
    function compoundRewards(address rewardToken, uint24 poolFee, uint256 backendMinOut) external onlyBackend {
        require(rewardToken != address(token), "Cannot compound the strategy token");
        require(slippagePriceChecker.isRewardToken(rewardToken), "Token not configured as reward");

        uint256 amountIn = IERC20(rewardToken).balanceOf(address(this));
        require(amountIn > 0, "No rewards to compound");

        uint256 expectedOut = slippagePriceChecker.getExpectedOut(amountIn, rewardToken, address(token));
        uint256 oracleFloor = (expectedOut * (SPLIT_TOTAL - allowedSlippageInBps)) / SPLIT_TOTAL;
        uint256 minOut = backendMinOut > oracleFloor ? backendMinOut : oracleFloor;

        IERC20(rewardToken).forceApprove(address(dexRouter), amountIn);

        uint256 amountOut = dexRouter.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: rewardToken,
                tokenOut: address(token),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 feeAmount = (amountOut * compoundFee) / SPLIT_TOTAL;
        if (feeAmount > 0) {
            token.safeTransfer(feeRecipient, feeAmount);
        }

        _depositInternal(amountOut - feeAmount);

        emit RewardsCompounded(rewardToken, amountIn, amountOut, feeAmount);
    }

    /**
     * @notice Sets a new fee recipient address
     * @param _newFeeRecipient The new fee recipient address
     */
    function setFeeRecipient(address _newFeeRecipient) external onlyBackend {
        require(_newFeeRecipient != address(0), "Invalid fee recipient address");

        emit FeeRecipientUpdated(feeRecipient, _newFeeRecipient);
        feeRecipient = _newFeeRecipient;
    }

    // ==================== PERMISSIONLESS FUNCTIONS ====================

    /**
     * @notice Deposits funds into the strategy
     * @dev Metered against the family-wide supply cap in MamoVaultConfig
     * @param amount The amount of tokens to deposit
     */
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        token.safeTransferFrom(msg.sender, address(this), amount);

        vaultConfig.recordDeposit(amount);

        _depositInternal(amount);

        emit Deposit(address(token), amount);
    }

    /**
     * @notice Deposits any idle token balance into the vaults based on the current weights
     * @dev Permissionless. Idle balance originates from compounded rewards, not user principal,
     *      so it is not metered against the supply cap.
     * @return amount The amount of tokens deposited
     */
    function depositIdleTokens() external returns (uint256) {
        uint256 tokenBalance = token.balanceOf(address(this));
        require(tokenBalance > 0, "No tokens to deposit");

        _depositInternal(tokenBalance);

        emit DepositIdle(address(token), tokenBalance);

        return tokenBalance;
    }

    // ======================= VIEW FUNCTIONS ==========================

    /**
     * @notice Gets the total balance of tokens across all vaults plus the idle balance
     */
    function getTotalBalance() public view returns (uint256) {
        uint256 total = token.balanceOf(address(this));

        for (uint256 i = 0; i < vaults.length; i++) {
            IERC4626 vault = IERC4626(vaults[i]);
            uint256 shares = vault.balanceOf(address(this));
            if (shares > 0) {
                total += vault.convertToAssets(shares);
            }
        }

        return total;
    }

    /**
     * @notice Returns the current vault set and weights
     */
    function getAllocations() external view returns (address[] memory, uint256[] memory) {
        return (vaults, weightsBps);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Validates and stores a new vault set and weights
     */
    function _setAllocations(address[] memory newVaults, uint256[] memory newWeightsBps) internal {
        require(newVaults.length > 0, "Empty vault set");
        require(newVaults.length == newWeightsBps.length, "Vaults and weights length mismatch");

        uint256 weightSum;
        for (uint256 i = 0; i < newVaults.length; i++) {
            require(vaultConfig.isAllowedVault(newVaults[i]), "Vault not allowlisted");
            require(newWeightsBps[i] > 0, "Zero weight");

            for (uint256 j = 0; j < i; j++) {
                require(newVaults[j] != newVaults[i], "Duplicate vault");
            }

            weightSum += newWeightsBps[i];
        }
        require(weightSum == SPLIT_TOTAL, "Weights must add up to SPLIT_TOTAL");

        vaults = newVaults;
        weightsBps = newWeightsBps;
    }

    /**
     * @notice Deposits tokens across the vault set according to the current weights
     */
    function _depositInternal(uint256 amount) internal {
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 target = (amount * weightsBps[i]) / SPLIT_TOTAL;
            if (target == 0) continue;

            token.forceApprove(vaults[i], target);
            IERC4626(vaults[i]).deposit(target, address(this));
        }
    }

    /**
     * @notice Redeems every share in every vault in the current set
     */
    function _redeemAllFromVaults() internal {
        for (uint256 i = 0; i < vaults.length; i++) {
            IERC4626 vault = IERC4626(vaults[i]);
            uint256 shares = vault.balanceOf(address(this));
            if (shares > 0) {
                vault.redeem(shares, address(this), address(this));
            }
        }
    }
}
