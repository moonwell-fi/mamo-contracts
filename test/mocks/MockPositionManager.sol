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

    // Last recorded approve call
    address public lastApprovedTo;
    uint256 public lastApprovedTokenId;
    uint256 public approveCallCount;

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
}
