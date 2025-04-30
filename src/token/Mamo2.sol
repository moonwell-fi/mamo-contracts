// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165, IERC7802} from "@contracts/interfaces/IERC7802.sol";
import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {ERC20VotesUpgradeable} from
    "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/NoncesUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title MAMO
/// @notice The MAMO token is SuperERC20 compatible
contract MAMO2 is ERC20Upgradeable, ERC20PermitUpgradeable, ERC20VotesUpgradeable, IERC7802 {
    error NotSuperchainTokenBridge();

    /// @notice Address of the SuperchainTokenBridge predeploy.
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    /// @notice maximum supply is 1 billion tokens
    uint256 internal constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice logic contract cannot be initialized
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name, string memory symbol, address recipient) public initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        _mint(recipient, MAX_SUPPLY);
    }

    function nonces(address owner)
        public
        view
        virtual
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
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
