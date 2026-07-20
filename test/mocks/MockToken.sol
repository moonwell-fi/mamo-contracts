// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockToken
 * @notice A minimal ERC20 with configurable decimals and open minting, for unit tests.
 * @dev The repo's existing test/MockERC20.sol is hard-wired to 18 decimals; USDC (6dp) needs a
 *      configurable-decimals mock, hence this one.
 */
contract MockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
