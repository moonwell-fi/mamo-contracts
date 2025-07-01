// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FeeSplitter
 * @notice Minimal contract to split fees between two recipients with a 70/30 split
 * @dev Tokens and recipients are set via constructor, split ratio is hardcoded 70/30
 */
contract FeeSplitter {
    using SafeERC20 for IERC20;

    // Immutable state variables set in constructor
    address public immutable RECIPIENT_1; // 70% recipient
    address public immutable RECIPIENT_2; // 30% recipient
    address public immutable TOKEN_0;
    address public immutable TOKEN_1;

    // Hardcoded split ratios
    uint256 private constant RECIPIENT_1_SHARE = 70; // 70%
    uint256 private constant RECIPIENT_2_SHARE = 30; // 30%
    uint256 private constant TOTAL_SHARE = 100;

    /// @notice Emitted when fees are split
    event FeesSplit(address indexed token, uint256 recipient1Amount, uint256 recipient2Amount);

    /**
     * @notice Constructor to set the tokens and recipients
     * @param _token0 Address of the first token to split
     * @param _token1 Address of the second token to split
     * @param _recipient1 Address of the first recipient (receives 70%)
     * @param _recipient2 Address of the second recipient (receives 30%)
     */
    constructor(address _token0, address _token1, address _recipient1, address _recipient2) {
        require(_token0 != address(0), "TOKEN_0 cannot be zero address");
        require(_token1 != address(0), "TOKEN_1 cannot be zero address");
        require(_recipient1 != address(0), "RECIPIENT_1 cannot be zero address");
        require(_recipient2 != address(0), "RECIPIENT_2 cannot be zero address");
        require(_token0 != _token1, "Tokens must be different");
        require(_recipient1 != _recipient2, "Recipients must be different");

        TOKEN_0 = _token0;
        TOKEN_1 = _token1;
        RECIPIENT_1 = _recipient1;
        RECIPIENT_2 = _recipient2;
    }

    /**
     * @notice Splits the current balance of both tokens between the two recipients
     * @dev Distributes token0 and token1 balances according to the 70/30 split ratio
     */
    function split() external {
        _splitToken(TOKEN_0);
        _splitToken(TOKEN_1);
    }

    /**
     * @notice Internal function to split a specific token's balance
     * @param token The address of the token to split
     */
    function _splitToken(address token) private {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));

        if (balance == 0) {
            return; // Nothing to split
        }

        uint256 recipient1Amount = (balance * RECIPIENT_1_SHARE) / TOTAL_SHARE;
        uint256 recipient2Amount = balance - recipient1Amount; // Ensures all tokens are distributed

        if (recipient1Amount > 0) {
            tokenContract.safeTransfer(RECIPIENT_1, recipient1Amount);
        }

        if (recipient2Amount > 0) {
            tokenContract.safeTransfer(RECIPIENT_2, recipient2Amount);
        }

        emit FeesSplit(token, recipient1Amount, recipient2Amount);
    }
}
