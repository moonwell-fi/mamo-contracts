// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title ICLPositionManager
/// @notice Aerodrome Slipstream NonfungiblePositionManager interface.
///         Differs from Uniswap v3: uses `int24 tickSpacing` instead of `uint24 fee`,
///         and appends `uint160 sqrtPriceX96` at the end of MintParams.
///         Verified against deployed PM 0x827922686190790b37229fd06084350E74485b72 on Base
///         (selector 0xb5007d1f = keccak("mint((address,address,int24,int24,int24,uint256,uint256,uint256,uint256,address,uint256,uint160))")[0:4]).
interface ICLPositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}
