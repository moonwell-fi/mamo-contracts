// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IXERC20} from "@contracts/interfaces/IXERC20.sol";
import {MintLimits} from "@contracts/token/MintLimits.sol";
import {ERC20VotesUpgradeable} from
    "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title xERC20
/// @notice A contract that allows minting and burning of tokens for cross-chain transfers
/// @dev This contract is a xERC20 version with a rate limit buffer
/// @dev This contract is a xERC20 version compatible with ERC20VotesUpgradeable
abstract contract xERC20 is IXERC20, MintLimits, ERC20VotesUpgradeable {
    using SafeCast for uint256;

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// -------------------- View Functions ------------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    /// @notice Returns the max limit of a minter
    /// @param minter The minter we are viewing the limits of
    /// @return limit The limit the minter has
    function mintingMaxLimitOf(address minter) external view returns (uint256 limit) {
        return bufferCap(minter);
    }

    /// @notice Returns the max limit of a bridge
    /// @param bridge the bridge we are viewing the limits of
    /// @return limit The limit the bridge has
    function burningMaxLimitOf(address bridge) external view returns (uint256 limit) {
        return bufferCap(bridge);
    }

    /// @notice Returns the current limit of a minter
    /// @param minter The minter we are viewing the limits of
    /// @return limit The limit the minter has
    function mintingCurrentLimitOf(address minter) external view returns (uint256 limit) {
        return buffer(minter);
    }

    /// @notice Returns the current limit of a bridge
    /// @param bridge the bridge we are viewing the limits of
    /// @return limit The limit the bridge has
    function burningCurrentLimitOf(address bridge) external view returns (uint256 limit) {
        /// buffer <= bufferCap, so this can never revert, just return 0
        return bufferCap(bridge) - buffer(bridge);
    }

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// --------------------- Bridge Functions ---------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    /// @notice Mints tokens for a user
    /// @dev Can only be called by a minter
    /// @param user The address of the user who needs tokens minted
    /// @param amount The amount of tokens being minted
    function mint(address user, uint256 amount) public virtual {
        /// first deplete buffer for the minter if not at max
        _depleteBuffer(msg.sender, amount);

        require(totalSupply() <= maxSupply(), "xERC20: max supply exceeded");

        _mint(user, amount);
    }

    /// @notice Burns tokens for a user
    /// @dev Can only be called by a minter
    /// @param user The address of the user who needs tokens burned
    /// @param amount The amount of tokens being burned
    function burn(address user, uint256 amount) public virtual {
        /// first replenish buffer for the minter if not at max
        /// unauthorized sender reverts
        _replenishBuffer(msg.sender, amount);

        /// deplete bridge's allowance
        _spendAllowance(user, msg.sender, amount);

        /// burn user's tokens
        _burn(user, amount);
    }

    //// ------------------------------------------------------------
    //// ------------------------------------------------------------
    //// ------------- Internal Override Functions ------------------
    //// ------------------------------------------------------------
    //// ------------------------------------------------------------

    /// @notice maximum supply is 1 billion tokens
    function maxSupply() public pure virtual returns (uint256);

    /// @notice the maximum amount of time the token can be paused for
    function maxPauseDuration() public pure virtual returns (uint256);

    /// @notice hook to stop users from transferring tokens to the xERC20 contract
    /// @param from the address to transfer from
    /// @param to the address to transfer to
    /// @param amount the amount to transfer
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        require(to != address(this), "xERC20: cannot transfer to token contract");
    }

    /// --------------------------------------------------------
    /// --------------------------------------------------------
    /// -------------------- clock override --------------------
    /// --------------------------------------------------------
    /// --------------------------------------------------------

    /// @notice override the clock in ERC20 Votes to use block timestamp
    /// now all checkpoints use unix timestamp instead of block number
    function clock() public view override returns (uint48) {
        /// do not safe cast, overflow will not happen for billions of years
        /// Given that the Unix Epoch started in 1970, adding these years to 1970 gives a theoretical year:
        /// 1970 + 8,923,292,862.77 ≈ Year 8,923,292,883,832
        return uint48(block.timestamp);
    }

    /// @dev Machine-readable description of the clock as specified in EIP-6372.
    /// https://eips.ethereum.org/EIPS/eip-6372
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view override returns (string memory) {
        // Check that the clock is correctly modified
        require(clock() == uint48(block.timestamp), "Incorrect clock");

        return "mode=timestamp";
    }
}
