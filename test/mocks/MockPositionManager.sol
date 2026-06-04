// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal mock for INonfungiblePositionManager used in unit tests.
contract MockPositionManager {
    // Configurable owner returned by ownerOf
    address public mockOwner;

    // Last recorded safeTransferFrom call
    address public lastFrom;
    address public lastTo;
    uint256 public lastTokenId;
    uint256 public transferCallCount;

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
}
