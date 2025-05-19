// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165, IERC7802} from "@contracts/interfaces/IERC7802.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title MAMO
/// @notice Mamo implements IERC7802 for unified cross-chain fungibility across the Superchain.
contract MAMO is ERC20, ERC20Permit, ERC20Votes, IERC7802 {
    error NotSuperchainTokenBridge();

    /// @notice Address of the SuperchainTokenBridge predeploy.
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    /// @notice maximum supply is 1 billion tokens
    uint256 internal constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice Constructor replaces the initialize function
    constructor(string memory name, string memory symbol, address recipient) ERC20(name, symbol) ERC20Permit(name) {
        _mint(recipient, MAX_SUPPLY);
    }

    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function crosschainMint(address _to, uint256 _amount) external {
        if (msg.sender != SUPERCHAIN_TOKEN_BRIDGE) revert NotSuperchainTokenBridge();

        _mint(_to, _amount);

        emit CrosschainMint(_to, _amount, msg.sender);
    }

    function crosschainBurn(address _from, uint256 _amount) external {
        if (msg.sender != SUPERCHAIN_TOKEN_BRIDGE) revert NotSuperchainTokenBridge();

        _burn(_from, _amount);

        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    function supportsInterface(bytes4 _interfaceId) public view virtual returns (bool) {
        return _interfaceId == type(IERC7802).interfaceId || _interfaceId == type(IERC20).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }
}
