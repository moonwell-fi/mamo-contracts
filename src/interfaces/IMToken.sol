// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IMToken {
    function underlying() external view returns (address);
    function redeemUnderlying(uint256 amount) external returns (uint256);
    function redeem(uint256 amount) external returns (uint256);
    function mint(uint256 amount) external returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
    function balanceOf(address owner) external returns (uint256);
    /// @notice Underlying tokens the market currently holds, i.e. the ceiling on any single redemption
    /// @dev Compound-style markets reject a redemption for more than this with the
    ///      TOKEN_INSUFFICIENT_CASH error code rather than reverting, so a caller that does not read
    ///      it first turns "this market is fully lent out" into a hard revert of the whole call.
    function getCash() external view returns (uint256);
}
