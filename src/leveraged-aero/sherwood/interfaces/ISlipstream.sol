// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

// Source: aerodrome-finance/slipstream @ f8717faaae6e6717db3c8e3850149c01a79c0603 (main)
//   INonfungiblePositionManager: contracts/periphery/interfaces/INonfungiblePositionManager.sol
//   ICLPool state/constants:     contracts/core/interfaces/pool/ICLPoolState.sol
//                                contracts/core/interfaces/pool/ICLPoolConstants.sol
//                                contracts/core/interfaces/pool/ICLPoolDerivedState.sol
//   ICLGauge:                    contracts/gauge/interfaces/ICLGauge.sol
//
// Key Slipstream deviation from Uniswap V3: pools/positions are keyed by
// `tickSpacing` (not `fee`). MintParams carries `tickSpacing`; there is no
// `fee` field in MintParams.

/// @title Slipstream Non-fungible Position Manager
/// @notice Minimal interface for managing CL positions as NFTs on Aerodrome Slipstream.
interface INonfungiblePositionManager {
    // -------------------------------------------------------------------------
    // Parameter structs (Slipstream-specific — tickSpacing replaces fee)
    // -------------------------------------------------------------------------

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

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    // -------------------------------------------------------------------------
    // Position queries
    // -------------------------------------------------------------------------

    /// @notice Returns the full position state for `tokenId`.
    /// @dev Return order matches the canonical Slipstream NPM (tickSpacing at index 4,
    ///      not fee as in vanilla Uniswap V3).
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// @notice Mints a new NFT position.
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Increases liquidity of an existing position.
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Decreases liquidity; tokens are credited to the position (call `collect` to receive them).
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /// @notice Collects up to `amount0Max`/`amount1Max` of fees owed to the position.
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Burns a fully-withdrawn (liquidity == 0, tokens owed == 0) position NFT.
    function burn(uint256 tokenId) external payable;
}

/// @title Aerodrome Slipstream CL Pool
/// @notice Minimal interface for price/TWAP queries needed by the strategy and valuation contracts.
interface ICLPool {
    /// @notice The current price and tick of the pool.
    /// @return sqrtPriceX96          Current sqrt price as Q64.96.
    /// @return tick                  Current tick (last crossed).
    /// @return observationIndex      Index of the last written oracle observation.
    /// @return observationCardinality Current max number of stored observations.
    /// @return observationCardinalityNext Next max (pending resize).
    /// @return unlocked              Reentrancy lock flag.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    /// @notice Returns cumulative tick and per-liquidity accumulators for each entry in `secondsAgos`.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice The tick spacing of the pool (Slipstream pools are identified by tickSpacing, not fee).
    function tickSpacing() external view returns (int24);

    /// @notice The swap & flash fee in pips (1e-6).
    function fee() external view returns (uint24);

    /// @notice The lower-sorted token of the pair.
    function token0() external view returns (address);

    /// @notice The higher-sorted token of the pair.
    function token1() external view returns (address);

    /// @notice The gauge address associated with this pool (set by the Voter on first epoch).
    function gauge() external view returns (address);
}

/// @title Aerodrome Slipstream CL Gauge
/// @notice Minimal interface for staking NFT positions and claiming AERO rewards.
interface ICLGauge {
    /// @notice Deposits (stakes) a CL position NFT into the gauge to receive emissions.
    /// @param tokenId The NFT token ID to stake.
    function deposit(uint256 tokenId) external;

    /// @notice Withdraws (unstakes) a CL position NFT from the gauge.
    /// @dev Outstanding rewards are collected automatically on withdrawal.
    /// @param tokenId The NFT token ID to unstake.
    function withdraw(uint256 tokenId) external;

    /// @notice Claims accumulated rewards for a specific position.
    /// @param tokenId The NFT token ID to claim rewards for.
    function getReward(uint256 tokenId) external;

    /// @notice The ERC-20 token distributed as gauge rewards (AERO on Base).
    function rewardToken() external view returns (address);
}

/// @title Aerodrome Slipstream CL Swap Router
/// @notice Minimal swap interface — tickSpacing-keyed (NOT fee-keyed, unlike Uniswap V3).
interface ICLSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /// @notice Swaps as little as possible of `tokenIn` for exactly `amountOut` of `tokenOut`.
    ///         Reverts if more than `amountInMaximum` of `tokenIn` would be required.
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}
