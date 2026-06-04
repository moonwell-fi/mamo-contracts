// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "@interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal mock for INonfungiblePositionManager used in unit tests.
contract MockPositionManager {
    using SafeERC20 for IERC20;
    // Configurable owner returned by ownerOf

    address public mockOwner;

    // Last recorded safeTransferFrom call
    address public lastFrom;
    address public lastTo;
    uint256 public lastTokenId;
    uint256 public transferCallCount;

    // Last recorded approve call
    address public lastApprovedTo;
    uint256 public lastApprovedTokenId;
    uint256 public approveCallCount;

    // Configurable collect return values
    uint256 public collectAmount0;
    uint256 public collectAmount1;
    address public collectToken0;
    address public collectToken1;

    // Last recorded collect call
    uint256 public lastCollectTokenId;
    address public lastCollectRecipient;
    uint256 public collectCallCount;

    constructor(address owner_) {
        mockOwner = owner_;
    }

    function setMockOwner(address owner_) external {
        mockOwner = owner_;
    }

    function ownerOf(uint256) external view returns (address) {
        return mockOwner;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        lastFrom = from;
        lastTo = to;
        lastTokenId = tokenId;
        transferCallCount++;
    }

    function approve(address to, uint256 tokenId) external {
        lastApprovedTo = to;
        lastApprovedTokenId = tokenId;
        approveCallCount++;
    }

    /// @notice Configure collect to return (amount0, amount1) and transfer from (token0, token1).
    function setCollectConfig(address token0_, address token1_, uint256 amount0_, uint256 amount1_) external {
        collectToken0 = token0_;
        collectToken1 = token1_;
        collectAmount0 = amount0_;
        collectAmount1 = amount1_;
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        lastCollectTokenId = params.tokenId;
        lastCollectRecipient = params.recipient;
        collectCallCount++;

        amount0 = collectAmount0;
        amount1 = collectAmount1;

        // Transfer tokens to recipient so the contract can forward them
        if (amount0 > 0 && collectToken0 != address(0)) {
            IERC20(collectToken0).safeTransfer(params.recipient, amount0);
        }
        if (amount1 > 0 && collectToken1 != address(0)) {
            IERC20(collectToken1).safeTransfer(params.recipient, amount1);
        }
    }
}
