// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
import {ISwapRouterV2} from "@interfaces/ISwapRouterV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VirtualsFeeSplitter
 * @notice Advanced fee splitter that swaps virtuals tokens to cbBTC and distributes both MAMO and cbBTC
 * @dev Swaps virtuals to cbBTC via Aerodrome V2, then splits both MAMO and cbBTC 70/30 between recipients
 */
contract VirtualsFeeSplitter is Ownable {
    using SafeERC20 for IERC20;

    // Token addresses (hardcoded constants)
    address private constant MAMO_TOKEN = 0x7300B37DfdfAb110d83290A29DfB31B1740219fE;
    address private constant VIRTUALS_TOKEN = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address private constant CBBTC_TOKEN = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant WETH_TOKEN = 0x4200000000000000000000000000000000000006; // Base WETH

    // Aerodrome V2 router address (hardcoded constant)
    address private constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    // Split ratios (hardcoded 70/30)
    uint256 private constant RECIPIENT_1_SHARE = 70; // 70%
    uint256 private constant RECIPIENT_2_SHARE = 30; // 30%
    uint256 private constant TOTAL_SHARE = 100;

    // Recipients
    address public immutable RECIPIENT_1; // 70% recipient
    address public immutable RECIPIENT_2; // 30% recipient

    // Router interface
    ISwapRouterV2 private immutable aerodromeRouter;

    // Swap deadline buffer (5 minutes)
    uint256 private constant DEADLINE_BUFFER = 300;

    // Slippage configuration (default 5% = 500 basis points)
    uint256 public slippageBps = 500; // 5%
    uint256 private constant MAX_SLIPPAGE_BPS = 1000; // 10% maximum
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Emitted when MAMO tokens are distributed
    event MamoDistributed(uint256 recipient1Amount, uint256 recipient2Amount);

    /// @notice Emitted when virtuals tokens are swapped to cbBTC
    event VirtualsSwapped(uint256 virtualsAmount, uint256 cbbtcReceived);

    /// @notice Emitted when cbBTC is distributed
    event CbBtcDistributed(uint256 recipient1Amount, uint256 recipient2Amount);

    /// @notice Emitted when slippage is updated
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    /**
     * @notice Constructor to set owner and recipients
     * @param _owner Address of the contract owner
     * @param _recipient1 Address of the first recipient (receives 70%)
     * @param _recipient2 Address of the second recipient (receives 30%)
     */
    constructor(address _owner, address _recipient1, address _recipient2) Ownable(_owner) {
        require(_recipient1 != address(0), "RECIPIENT_1 cannot be zero address");
        require(_recipient2 != address(0), "RECIPIENT_2 cannot be zero address");
        require(_recipient1 != _recipient2, "Recipients must be different");

        RECIPIENT_1 = _recipient1;
        RECIPIENT_2 = _recipient2;
        aerodromeRouter = ISwapRouterV2(AERODROME_ROUTER);

        // Approve router to spend virtuals tokens
        IERC20(VIRTUALS_TOKEN).forceApprove(AERODROME_ROUTER, type(uint256).max);
    }

    /**
     * @notice Swaps virtuals to cbBTC and distributes both MAMO and cbBTC to recipients
     * @dev This function can only be called by the owner
     */
    function swapAndCollect() external onlyOwner {
        // 1. Distribute MAMO tokens
        _distributeMamo();

        // 2. Swap virtuals to cbBTC and distribute
        _swapVirtualsAndDistribute();
    }

    /**
     * @notice Updates the slippage tolerance for swaps (only owner)
     * @param _slippageBps New slippage in basis points (e.g., 500 = 5%)
     */
    function setSlippage(uint256 _slippageBps) external onlyOwner {
        require(_slippageBps <= MAX_SLIPPAGE_BPS, "Slippage too high");

        uint256 oldSlippage = slippageBps;
        slippageBps = _slippageBps;

        emit SlippageUpdated(oldSlippage, _slippageBps);
    }

    /**
     * @notice Emergency function to recover stuck tokens (only owner)
     * @param token Address of the token to recover
     * @param to Address to send recovered tokens
     * @param amount Amount of tokens to recover
     */
    function emergencyRecover(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Updates the approval for virtuals token spending (only owner)
     * @dev Useful if approval needs to be reset
     */
    function updateVirtualsApproval() external onlyOwner {
        IERC20(VIRTUALS_TOKEN).forceApprove(AERODROME_ROUTER, type(uint256).max);
    }

    /**
     * @notice Internal function to distribute MAMO tokens
     */
    function _distributeMamo() private {
        IERC20 mamoToken = IERC20(MAMO_TOKEN);
        uint256 mamoBalance = mamoToken.balanceOf(address(this));

        if (mamoBalance == 0) {
            return; // Nothing to distribute
        }

        uint256 recipient1Amount = (mamoBalance * RECIPIENT_1_SHARE) / TOTAL_SHARE;
        uint256 recipient2Amount = mamoBalance - recipient1Amount; // Ensures all tokens are distributed

        if (recipient1Amount > 0) {
            mamoToken.safeTransfer(RECIPIENT_1, recipient1Amount);
        }

        if (recipient2Amount > 0) {
            mamoToken.safeTransfer(RECIPIENT_2, recipient2Amount);
        }

        emit MamoDistributed(recipient1Amount, recipient2Amount);
    }

    /**
     * @notice Internal function to swap virtuals to cbBTC and distribute
     */
    function _swapVirtualsAndDistribute() private {
        IERC20 virtualsToken = IERC20(VIRTUALS_TOKEN);
        uint256 virtualsBalance = virtualsToken.balanceOf(address(this));

        if (virtualsBalance == 0) {
            return; // Nothing to swap
        }

        // Create swap path: VIRTUALS -> cbBTC
        address[] memory path = new address[](2);
        path[0] = VIRTUALS_TOKEN;
        path[1] = CBBTC_TOKEN;

        // Get quote for the swap using V2 getAmountsOut
        uint256[] memory amounts = aerodromeRouter.getAmountsOut(virtualsBalance, path);
        uint256 quotedAmountOut = amounts[1];

        // Calculate minimum amount out with slippage protection
        uint256 minAmountOut = (quotedAmountOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;

        // Perform the swap using V2 swapExactTokensForTokens
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;
        uint256[] memory swapAmounts = aerodromeRouter.swapExactTokensForTokens(
            virtualsBalance,
            minAmountOut,
            path,
            address(this),
            deadline
        );

        uint256 cbbtcReceived = swapAmounts[1];
        emit VirtualsSwapped(virtualsBalance, cbbtcReceived);

        // Distribute the received cbBTC
        if (cbbtcReceived > 0) {
            _distributeCbBtc(cbbtcReceived);
        }
    }

    /**
     * @notice Internal function to distribute cbBTC tokens
     * @param amount Amount of cbBTC to distribute
     */
    function _distributeCbBtc(uint256 amount) private {
        IERC20 cbbtcToken = IERC20(CBBTC_TOKEN);

        uint256 recipient1Amount = (amount * RECIPIENT_1_SHARE) / TOTAL_SHARE;
        uint256 recipient2Amount = amount - recipient1Amount; // Ensures all tokens are distributed

        if (recipient1Amount > 0) {
            cbbtcToken.safeTransfer(RECIPIENT_1, recipient1Amount);
        }

        if (recipient2Amount > 0) {
            cbbtcToken.safeTransfer(RECIPIENT_2, recipient2Amount);
        }

        emit CbBtcDistributed(recipient1Amount, recipient2Amount);
    }

    /**
     * @notice View function to get token addresses
     */
    function getTokenAddresses() external pure returns (address mamo, address virtuals, address cbbtc) {
        return (MAMO_TOKEN, VIRTUALS_TOKEN, CBBTC_TOKEN);
    }

    /**
     * @notice View function to get Aerodrome router address
     */
    function getAerodromeRouter() external pure returns (address router) {
        return AERODROME_ROUTER;
    }

    /**
     * @notice View function to get split ratios
     */
    function getSplitRatios() external pure returns (uint256 recipient1Share, uint256 recipient2Share) {
        return (RECIPIENT_1_SHARE, RECIPIENT_2_SHARE);
    }

    /**
     * @notice View function to get current slippage configuration
     */
    function getSlippage() external view returns (uint256 slippageBasisPoints, uint256 maxSlippageBasisPoints) {
        return (slippageBps, MAX_SLIPPAGE_BPS);
    }
}
