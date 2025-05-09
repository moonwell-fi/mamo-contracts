// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockFailingERC20
 * @notice A mock ERC20 token that fails on certain operations for testing purposes
 */
contract MockFailingERC20 {
    mapping(address => uint256) private _balances;

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function balanceOfUnderlying(address account) external view returns (uint256) {
        return _balances[account];
    }

    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("Transfer failed");
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("TransferFrom failed");
    }

    function approve(address, uint256) external pure returns (bool) {
        revert("Approve failed");
    }

    function redeem(uint256) external pure returns (uint256) {
        revert("Redeem failed");
    }

    function redeemUnderlying(uint256) external pure {
        revert("RedeemUnderlying failed");
    }
}
