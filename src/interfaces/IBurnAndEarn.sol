// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IBurnAndEarn {
    /// @notice Emitted when fees are claimed
    /// @param claimer The address of the claimer
    /// @param token0 The address of the token0
    /// @param token1 The address of the token1
    /// @param creatorAmount0 The amount of creator token0 claimed
    /// @param creatorAmount1 The amount of creator token1 claimed
    /// @param totalAmount0 The total amount of token0 claimed
    /// @param totalAmount1 The total amount of token1 claimed
    event ClaimedFees(
        address indexed claimer,
        address indexed token0,
        address indexed token1,
        uint256 creatorAmount0,
        uint256 creatorAmount1,
        uint256 totalAmount0,
        uint256 totalAmount1
    );

    struct LPFeeInfo {
        address creatorAddress;
        uint256 creatorFeeBps;
        bool isLocked;
    }

    function add(uint256 tokenId) external;

    function earn(uint256 tokenId) external returns (uint256 amount0, uint256 amount1);

    function earnMany(uint256[] calldata tokenIds)
        external
        returns (uint256[] memory amounts0, uint256[] memory amounts1);

    function feeCollector() external view returns (address);
}
