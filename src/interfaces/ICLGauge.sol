// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface ICLGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
    function earned(address account, uint256 tokenId) external view returns (uint256);
    function rewardToken() external view returns (address);
    function pool() external view returns (address);
    /// @notice The position manager whose NFTs this gauge accepts (same signature on V1 and V3).
    function nft() external view returns (address);
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
}

/// @notice The Slipstream V3 CLGauge surface that differs from `ICLGauge`. V3 drops `getReward`,
///         `earned(address,uint256)` and `rewardToken()` (emissions are minted by the LeafVoter);
///         `deposit`, `withdraw`, `pool`, `nft` and `stakedContains` keep the `ICLGauge` signatures.
interface ICLGaugeV3 {
    /// @notice Claims the listed positions' emissions plus the account's deferred emissions.
    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external;
    function earned(address account, uint256[] memory tokenIds) external view returns (uint256);
    /// @notice Block of the position's deposit. V3-only: used to tell the gauge versions apart.
    function depositBlock(uint256 tokenId) external view returns (uint256);
}
