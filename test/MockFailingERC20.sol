// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title MockFailingERC20
 * @notice A mock ERC20 token that fails on transfer
 * @dev Used for testing the failure case in recoverERC20 function
 */
contract MockFailingERC20 {
    // Basic ERC20 state
    mapping(address => uint256) private _balances;

    // Always fail on transfer
    function transfer(address, uint256) external pure returns (bool) {
        revert("Transfer failed");
    }

    // Mock function to set balance
    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    // View function to check balance
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}
