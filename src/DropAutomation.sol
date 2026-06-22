// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAerodromeGauge} from "./interfaces/IAerodromeGauge.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

/**
 * @notice Interface for the rewards distributor safe module
 */
interface IRewardsDistributorSafeModule {
    /**
     * @notice Adds reward amounts to be distributed
     * @param amountToken1 Amount of MAMO tokens to distribute
     * @param amountToken2 Amount of cbBTC tokens to distribute
     */
    function addRewards(uint256 amountToken1, uint256 amountToken2) external;
}

/**
 * @title DropAutomation
 * @notice Automates weekly reward drops by swapping rewards into MAMO via Aerodrome and
 *         forwarding the resulting MAMO/cbBTC balances to the F-MAMO Safe rewards module.
 */
contract DropAutomation is Ownable {
    using SafeERC20 for IERC20;

    /// @dev MAMO token
    IERC20 public immutable MAMO_TOKEN;

    /// @dev cbBTC token
    IERC20 public immutable CBBTC_TOKEN;

    /// @dev F-MAMO Safe multisig address receiving reward tokens
    address public immutable F_MAMO_SAFE;

    /// @dev Safe module responsible for staging reward distributions
    IRewardsDistributorSafeModule public immutable SAFE_REWARDS_DISTRIBUTOR_MODULE;

    /// @dev Aerodrome CL router used to swap earned rewards into MAMO
    ISwapRouter public immutable AERODROME_CL_ROUTER;

    /// @dev Aerodrome quoter used to fetch swap estimates for slippage protection
    IQuoter public immutable AERODROME_QUOTER;

    /// @notice List of configured Aerodrome gauges for earning rewards
    IAerodromeGauge[] public aerodromeGauges;

    /// @notice Mapping to check if a gauge is configured
    mapping(address => bool) public isConfiguredGauge;

    /// @notice Mapping from gauge address to its index in the aerodromeGauges array
    mapping(address => uint256) public gaugeIndex;

    /// @notice Address authorized to trigger reward drops
    address public dedicatedMsgSender;

    /// @notice Maximum slippage tolerance in basis points applied to each swap
    uint256 public maxSlippageBps;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_SLIPPAGE_CAP_BPS = 500; // 5% maximum allowed slippage
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1% default slippage
    uint256 private constant SWAP_DEADLINE_BUFFER = 300; // 5 minutes deadline buffer for MEV protection
    int24 private constant MAMO_CBBTC_TICK_SPACING = 200; // Tick spacing for MAMO/cbBTC CL pool

    event DropCreated(uint256 mamoAmount, uint256 cbBtcAmount);
    event DedicatedMsgSenderUpdated(address indexed oldSender, address indexed newSender);
    event TokensSwapped(address indexed token, uint256 amountIn, uint256 amountOut);
    event MaxSlippageUpdated(uint256 oldValueBps, uint256 newValueBps);
    event GaugeAdded(address indexed gauge);
    event GaugeRemoved(address indexed gauge);
    event GaugeWithdrawn(address indexed gauge, address indexed recipient, uint256 amount);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event GaugeRewardsClaimed(address indexed gauge);
    event GaugeRewardsClaimFailed(address indexed gauge, bytes reason);

    error NotDedicatedSender();
    error InvalidSlippage();
    error GaugeNotConfigured();
    error InsufficientOutput();

    /**
     * @notice Restricts function access to the dedicated message sender
     * @dev Reverts with NotDedicatedSender if called by any other address
     */
    modifier onlyDedicatedMsgSender() {
        if (msg.sender != dedicatedMsgSender) {
            revert NotDedicatedSender();
        }
        _;
    }

    /**
     * @notice Initializes the DropAutomation contract
     * @param owner_ Address of the contract owner
     * @param dedicatedMsgSender_ Address authorized to trigger reward drops
     * @param mamoToken_ Address of the MAMO token
     * @param cbBtcToken_ Address of the cbBTC token
     * @param fMamoSafe_ Address of the F-MAMO Safe multisig
     * @param safeRewardsDistributorModule_ Address of the rewards distributor module
     * @param aerodromeRouter_ Address of the Aerodrome CL swap router
     * @param aerodromeQuoter_ Address of the Aerodrome quoter for price estimates
     */
    constructor(
        address owner_,
        address dedicatedMsgSender_,
        address mamoToken_,
        address cbBtcToken_,
        address fMamoSafe_,
        address safeRewardsDistributorModule_,
        address aerodromeRouter_,
        address aerodromeQuoter_
    ) Ownable(owner_) {
        require(dedicatedMsgSender_ != address(0), "Invalid dedicated sender");
        require(mamoToken_ != address(0), "Invalid MAMO token");
        require(cbBtcToken_ != address(0), "Invalid cbBTC token");
        require(fMamoSafe_ != address(0), "Invalid F-MAMO safe");
        require(safeRewardsDistributorModule_ != address(0), "Invalid rewards module");
        require(aerodromeRouter_ != address(0), "Invalid Aerodrome router");
        require(aerodromeQuoter_ != address(0), "Invalid Aerodrome quoter");

        dedicatedMsgSender = dedicatedMsgSender_;
        MAMO_TOKEN = IERC20(mamoToken_);
        CBBTC_TOKEN = IERC20(cbBtcToken_);
        F_MAMO_SAFE = fMamoSafe_;
        SAFE_REWARDS_DISTRIBUTOR_MODULE = IRewardsDistributorSafeModule(safeRewardsDistributorModule_);
        AERODROME_CL_ROUTER = ISwapRouter(aerodromeRouter_);
        AERODROME_QUOTER = IQuoter(aerodromeQuoter_);
        maxSlippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    /**
     * @notice Claims rewards from all configured Aerodrome gauges
     * @dev Only callable by the dedicated message sender. Only claims rewards without swapping.
     *      Call this before createDrop(). Iterates through all gauges and calls getReward().
     *      Emits GaugeRewardsClaimed on success.
     */
    function claimGaugeRewards() external onlyDedicatedMsgSender {
        uint256 gaugeCount = aerodromeGauges.length;
        require(gaugeCount > 0, "No gauges configured");

        for (uint256 i = 0; i < gaugeCount; i++) {
            aerodromeGauges[i].getReward(address(this));
            emit GaugeRewardsClaimed(address(aerodromeGauges[i]));
        }
    }

    /**
     * @notice Main automation entry point to swap tokens and create reward drop
     * @param swapTokens_ Array of token addresses to swap
     * @param tickSpacings_ Array of tick spacings for each token's pool
     * @param swapDirectToCbBtc_ Array of booleans indicating if token swaps directly to cbBTC (true) or through MAMO (false)
     * @param minAmountOuts_ Array of minimum output amounts (in final token) for MEV protection
     * @dev Call claimGaugeRewards() before this function to claim gauge rewards.
     *      Swaps all provided tokens and forwards the resulting MAMO/cbBTC to the Safe.
     *      All arrays must be the same length and correspond to each other by index.
     *      minAmountOuts_ should be calculated off-chain based on fair market prices to prevent MEV.
     */
    function createDrop(
        address[] calldata swapTokens_,
        int24[] calldata tickSpacings_,
        bool[] calldata swapDirectToCbBtc_,
        uint256[] calldata minAmountOuts_
    ) external onlyDedicatedMsgSender {
        require(swapTokens_.length == tickSpacings_.length, "Array length mismatch");
        require(swapTokens_.length == swapDirectToCbBtc_.length, "Direct swap array length mismatch");
        require(swapTokens_.length == minAmountOuts_.length, "Min amounts array length mismatch");

        _swapTokensToMamoAndCbBtc(swapTokens_, tickSpacings_, swapDirectToCbBtc_, minAmountOuts_);

        uint256 mamoBalance = MAMO_TOKEN.balanceOf(address(this));
        uint256 cbBtcBalance = CBBTC_TOKEN.balanceOf(address(this));

        require(mamoBalance > 0 || cbBtcBalance > 0, "No rewards to distribute");

        if (mamoBalance > 0) {
            MAMO_TOKEN.safeTransfer(F_MAMO_SAFE, mamoBalance);
        }

        if (cbBtcBalance > 0) {
            CBBTC_TOKEN.safeTransfer(F_MAMO_SAFE, cbBtcBalance);
        }

        SAFE_REWARDS_DISTRIBUTOR_MODULE.addRewards(mamoBalance, cbBtcBalance);

        emit DropCreated(mamoBalance, cbBtcBalance);
    }

    /**
     * @notice Updates the dedicated automation sender address
     * @param newSender Address of the new dedicated sender
     */
    function setDedicatedMsgSender(address newSender) external onlyOwner {
        require(newSender != address(0), "Invalid dedicated sender");
        emit DedicatedMsgSenderUpdated(dedicatedMsgSender, newSender);
        dedicatedMsgSender = newSender;
    }

    /**
     * @notice Updates the maximum allowed slippage for swaps
     * @param newSlippageBps New slippage tolerance in basis points (1-500)
     * @dev Only callable by owner. Must be between 1 and 500 bps (0.01% - 5%)
     */
    function setMaxSlippageBps(uint256 newSlippageBps) external onlyOwner {
        if (newSlippageBps == 0 || newSlippageBps > MAX_SLIPPAGE_CAP_BPS) {
            revert InvalidSlippage();
        }

        emit MaxSlippageUpdated(maxSlippageBps, newSlippageBps);
        maxSlippageBps = newSlippageBps;
    }

    /**
     * @notice Adds an Aerodrome gauge for reward harvesting
     * @param gauge_ Address of the Aerodrome gauge contract
     */
    function addGauge(address gauge_) external onlyOwner {
        require(gauge_ != address(0), "Invalid gauge");
        require(gauge_.code.length > 0, "Gauge not deployed");
        require(!isConfiguredGauge[gauge_], "Gauge already configured");

        // Validate gauge configuration
        require(IAerodromeGauge(gauge_).rewardToken() != address(0), "Invalid reward token");
        require(IAerodromeGauge(gauge_).stakingToken() != address(0), "Invalid staking token");

        // Add gauge to array and mappings
        gaugeIndex[gauge_] = aerodromeGauges.length;
        aerodromeGauges.push(IAerodromeGauge(gauge_));
        isConfiguredGauge[gauge_] = true;

        emit GaugeAdded(gauge_);
    }

    /**
     * @notice Removes an Aerodrome gauge from reward harvesting
     * @param gauge_ Address of the Aerodrome gauge contract to remove
     */
    function removeGauge(address gauge_) external onlyOwner {
        require(isConfiguredGauge[gauge_], "Gauge not configured");

        uint256 index = gaugeIndex[gauge_];
        uint256 lastIndex = aerodromeGauges.length - 1;

        // Move last gauge to the index of gauge being removed
        if (index != lastIndex) {
            IAerodromeGauge lastGauge = aerodromeGauges[lastIndex];
            aerodromeGauges[index] = lastGauge;
            gaugeIndex[address(lastGauge)] = index;
        }

        // Remove last element and clean mappings
        aerodromeGauges.pop();
        delete gaugeIndex[gauge_];
        isConfiguredGauge[gauge_] = false;

        emit GaugeRemoved(gauge_);
    }

    /**
     * @notice Returns the number of configured gauges
     * @return Number of gauges in the array
     */
    function getGaugeCount() external view returns (uint256) {
        return aerodromeGauges.length;
    }

    /**
     * @notice Withdraws staked LP tokens from a specific Aerodrome gauge
     * @param gauge_ Address of the gauge to withdraw from
     * @param amount Amount of LP tokens to withdraw
     * @param recipient Address receiving the withdrawn LP tokens
     */
    function withdrawGauge(address gauge_, uint256 amount, address recipient) external onlyOwner {
        require(isConfiguredGauge[gauge_], "Gauge not configured");
        require(amount > 0, "Amount must be greater than 0");
        require(recipient != address(0), "Invalid recipient");

        IAerodromeGauge gauge = IAerodromeGauge(gauge_);
        uint256 stakedBalance = gauge.balanceOf(address(this));
        require(amount <= stakedBalance, "Insufficient gauge balance");

        gauge.withdraw(amount);

        // Get staking token from gauge and transfer
        address stakingToken = gauge.stakingToken();
        IERC20(stakingToken).safeTransfer(recipient, amount);

        emit GaugeWithdrawn(gauge_, recipient, amount);
    }

    /**
     * @notice Recovers arbitrary ERC20 tokens held by the contract
     * @param token Address of the token to recover
     * @param to Recipient of the recovered tokens
     * @param amount Amount of tokens to recover (0 = withdraw all)
     * @dev Only callable by owner. If amount is 0, withdraws entire balance
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(to != address(0), "Invalid recipient");

        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");

        uint256 transferAmount = amount == 0 ? balance : amount;
        require(transferAmount <= balance, "Insufficient balance");

        tokenContract.safeTransfer(to, transferAmount);

        emit TokensRecovered(token, to, transferAmount);
    }

    /**
     * @notice Swaps provided tokens to MAMO and then to cbBTC
     * @param swapTokens_ Array of token addresses to swap
     * @param tickSpacings_ Array of tick spacings for each token's pool
     * @param swapDirectToCbBtc_ Array of booleans indicating swap routing for each token
     * @param minAmountOuts_ Array of minimum output amounts for MEV protection
     * @dev Swaps tokens based on their routing specified by swapDirectToCbBtc_:
     *      - true: Direct swap to cbBTC (e.g., AERO which has no MAMO pool)
     *      - false: Swap to MAMO first, then MAMO to cbBTC
     *      For each token:
     *      1. Checks the contract's balance
     *      2. Skips if balance is zero
     *      3. Executes appropriate swap path based on routing flag
     *      4. Validates final output meets external minimum for MEV protection
     */
    function _swapTokensToMamoAndCbBtc(
        address[] calldata swapTokens_,
        int24[] calldata tickSpacings_,
        bool[] calldata swapDirectToCbBtc_,
        uint256[] calldata minAmountOuts_
    ) internal {
        uint256 length = swapTokens_.length;
        for (uint256 i = 0; i < length; i++) {
            address token = swapTokens_[i];
            uint256 amountIn = IERC20(token).balanceOf(address(this));
            if (amountIn == 0) {
                continue;
            }

            uint256 finalOutput;
            if (swapDirectToCbBtc_[i]) {
                // Direct swap to cbBTC (e.g., AERO)
                finalOutput = _executeSwap(token, address(CBBTC_TOKEN), amountIn, tickSpacings_[i], minAmountOuts_[i]);
                emit TokensSwapped(token, amountIn, finalOutput);
            } else {
                // Swap to MAMO first, then MAMO to cbBTC
                uint256 mamoReceived = _swapToMamo(token, amountIn, tickSpacings_[i], 0);
                finalOutput = _swapMamoToCbBtc(mamoReceived, 0);
            }

            // Validate final output meets external minimum
            if (finalOutput < minAmountOuts_[i]) {
                revert InsufficientOutput();
            }
        }
    }

    /**
     * @notice Swaps a token to MAMO
     * @param token Address of the token to swap from
     * @param amountIn Amount of tokens to swap
     * @param tickSpacing Tick spacing for the token's pool with MAMO
     * @param externalMinAmountOut External minimum for MEV protection (0 to skip)
     * @return amountOut Amount of MAMO tokens received
     * @dev Uses Aerodrome CL router with slippage protection. Emits TokensSwapped event.
     */
    function _swapToMamo(address token, uint256 amountIn, int24 tickSpacing, uint256 externalMinAmountOut)
        internal
        returns (uint256 amountOut)
    {
        amountOut = _executeSwap(token, address(MAMO_TOKEN), amountIn, tickSpacing, externalMinAmountOut);
        emit TokensSwapped(token, amountIn, amountOut);
    }

    /**
     * @notice Swaps MAMO tokens to cbBTC
     * @param amountIn Amount of MAMO tokens to swap
     * @param externalMinAmountOut External minimum for MEV protection (0 to skip)
     * @return amountOut Amount of cbBTC tokens received
     * @dev Uses Aerodrome CL router with slippage protection.
     *      Uses MAMO_CBBTC_TICK_SPACING (200) for the concentrated liquidity pool.
     *      Emits TokensSwapped event.
     */
    function _swapMamoToCbBtc(uint256 amountIn, uint256 externalMinAmountOut) internal returns (uint256 amountOut) {
        amountOut = _executeSwap(
            address(MAMO_TOKEN), address(CBBTC_TOKEN), amountIn, MAMO_CBBTC_TICK_SPACING, externalMinAmountOut
        );
        emit TokensSwapped(address(MAMO_TOKEN), amountIn, amountOut);
    }

    /**
     * @notice Executes a token swap via Aerodrome CL router
     * @param tokenIn Address of the input token
     * @param tokenOut Address of the output token
     * @param amountIn Amount of input tokens to swap
     * @param tickSpacing Tick spacing for the pool
     * @param externalMinAmountOut External minimum for MEV protection (0 to skip)
     * @return amountOut Amount of output tokens received
     * @dev Core swap logic with dual-layer slippage protection:
     *      1. On-chain slippage check using quoter (protects against normal volatility)
     *      2. External minimum check (protects against MEV/manipulation)
     *      Process:
     *      1. Approves the Aerodrome router to spend input tokens
     *      2. Gets a price quote from the Aerodrome quoter
     *      3. Calculates minimum output based on maxSlippageBps tolerance
     *      4. Uses max(onChainMin, externalMin) as the actual minimum
     *      5. Executes the swap via exactInputSingle
     *      6. Verifies the received amount meets the minimum
     */
    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        int24 tickSpacing,
        uint256 externalMinAmountOut
    ) internal returns (uint256 amountOut) {
        require(tickSpacing > 0, "Invalid tick spacing");

        IERC20(tokenIn).forceApprove(address(AERODROME_CL_ROUTER), amountIn);

        IQuoter.QuoteExactInputSingleParams memory params = IQuoter.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            tickSpacing: tickSpacing,
            sqrtPriceLimitX96: 0
        });

        (uint256 quotedAmountOut,,,) = AERODROME_QUOTER.quoteExactInputSingle(params);
        require(quotedAmountOut > 0, "Invalid quote");

        // Calculate on-chain minimum based on quote and slippage tolerance
        uint256 onChainMinAmountOut = (quotedAmountOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        require(onChainMinAmountOut > 0, "Slippage too high");

        // Use the maximum of on-chain and external minimums for best protection
        uint256 minAmountOut = externalMinAmountOut > onChainMinAmountOut ? externalMinAmountOut : onChainMinAmountOut;

        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tickSpacing: tickSpacing,
            recipient: address(this),
            deadline: block.timestamp + SWAP_DEADLINE_BUFFER,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = AERODROME_CL_ROUTER.exactInputSingle(swapParams);

        require(amountOut >= minAmountOut, "Received less than min amount");
    }
}
