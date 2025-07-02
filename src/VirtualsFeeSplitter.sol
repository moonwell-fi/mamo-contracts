// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISwapRouterV2} from "@interfaces/ISwapRouterV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title VirtualsFeeSplitter
 * @notice Swaps virtuals tokens to cbBTC and distributes both MAMO and cbBTC to a single recipient
 * @dev Swaps virtuals to cbBTC via Aerodrome V2, then sends both MAMO and cbBTC to recipient
 */
contract VirtualsFeeSplitter is Ownable {
    using SafeERC20 for IERC20;

    // Token addresses
    address public immutable MAMO_TOKEN;
    address public immutable VIRTUALS_TOKEN;
    address public immutable CBBTC_TOKEN;

    // Aerodrome V2 router address
    address public immutable AERODROME_ROUTER;

    // Single recipient
    address public immutable RECIPIENT;

    // Router interface
    ISwapRouterV2 private immutable aerodromeRouter;

    // Swap deadline buffer (5 minutes)
    uint256 private constant DEADLINE_BUFFER = 300;

    // Slippage configuration (default 5% = 500 basis points)
    uint256 public slippageBps = 500; // 5%
    uint256 private constant MAX_SLIPPAGE_BPS = 1000; // 10% maximum
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Emitted when MAMO tokens are distributed
    event MamoDistributed(uint256 amount);

    /// @notice Emitted when virtuals tokens are swapped to cbBTC
    event VirtualsSwapped(uint256 virtualsAmount, uint256 cbbtcReceived);

    /// @notice Emitted when cbBTC is distributed
    event CbBtcDistributed(uint256 amount);

    /// @notice Emitted when slippage is updated
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);

    /**
     * @notice Constructor to set owner, recipients, and token addresses
     * @param _owner Address of the contract owner
     * @param _recipient Address of the recipient (receives all tokens)
     * @param _mamoToken Address of the MAMO token
     * @param _virtualsToken Address of the virtuals token
     * @param _cbbtcToken Address of the cbBTC token
     * @param _aerodromeRouter Address of the Aerodrome V2 router
     */
    constructor(
        address _owner,
        address _recipient,
        address _mamoToken,
        address _virtualsToken,
        address _cbbtcToken,
        address _aerodromeRouter
    ) Ownable(_owner) {
        require(_recipient != address(0), "Recipient cannot be zero address");
        require(_mamoToken != address(0), "MAMO token cannot be zero address");
        require(_virtualsToken != address(0), "Virtuals token cannot be zero address");
        require(_cbbtcToken != address(0), "cbBTC token cannot be zero address");
        require(_aerodromeRouter != address(0), "Router cannot be zero address");

        RECIPIENT = _recipient;
        MAMO_TOKEN = _mamoToken;
        VIRTUALS_TOKEN = _virtualsToken;
        CBBTC_TOKEN = _cbbtcToken;
        AERODROME_ROUTER = _aerodromeRouter;
        aerodromeRouter = ISwapRouterV2(_aerodromeRouter);
    }

    /**
     * @notice Swaps virtuals to cbBTC and distributes both MAMO and cbBTC to recipient
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
     * @notice Internal function to distribute MAMO tokens
     */
    function _distributeMamo() private {
        IERC20 mamoToken = IERC20(MAMO_TOKEN);
        uint256 mamoBalance = mamoToken.balanceOf(address(this));

        if (mamoBalance == 0) {
            return; // Nothing to distribute
        }

        mamoToken.safeTransfer(RECIPIENT, mamoBalance);
        emit MamoDistributed(mamoBalance);
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

        // Create swap route: VIRTUALS -> cbBTC
        ISwapRouterV2.Route[] memory routes = new ISwapRouterV2.Route[](1);
        routes[0] = ISwapRouterV2.Route({
            from: VIRTUALS_TOKEN,
            to: CBBTC_TOKEN,
            stable: false, // volatile pair
            factory: address(0) // use default factory
        });

        // Get quote for the swap using Aerodrome getAmountsOut
        uint256[] memory amounts = aerodromeRouter.getAmountsOut(virtualsBalance, routes);
        uint256 quotedAmountOut = amounts[1];

        // Calculate minimum amount out with slippage protection
        uint256 minAmountOut = (quotedAmountOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;

        // Approve router to spend virtuals tokens
        IERC20(VIRTUALS_TOKEN).forceApprove(AERODROME_ROUTER, virtualsBalance);

        // Perform the swap using Aerodrome swapExactTokensForTokens
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;
        uint256[] memory swapAmounts =
            aerodromeRouter.swapExactTokensForTokens(virtualsBalance, minAmountOut, routes, address(this), deadline);

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
        cbbtcToken.safeTransfer(RECIPIENT, amount);
        emit CbBtcDistributed(amount);
    }
}
