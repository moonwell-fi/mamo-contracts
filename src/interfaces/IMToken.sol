// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface IMToken {
    function underlying() external view returns (address);
    function redeemUnderlying(uint256 amount) external returns(uint256);
    function redeem(uint256 amount) external returns(uint256);
    function mint(uint256 amount) external returns(uint256);
    function balanceOfUnderlying(address owner) external returns(uint256);
}
