// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {ITransferAndEarn} from "./interfaces/ITransferAndEarn.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract TransferAndEarn is ITransferAndEarn, IERC721Receiver, Ownable {
    using SafeERC20 for IERC20;

    address public feeCollector;
    mapping(uint256 => bool) public lockedPositions;

    INonfungiblePositionManager private immutable positionManager =
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);

    constructor(address _feeCollector, address _owner) Ownable(_owner) {
        require(_feeCollector != address(0), "Fee collector cannot be zero");
        require(_owner != address(0), "Owner cannot be zero");
        feeCollector = _feeCollector;
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Fee collector cannot be zero");
        feeCollector = _feeCollector;
    }

    // only uniswap v3 position manager can call this
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(positionManager), "Only position manager can call this");
        return this.onERC721Received.selector;
    }

    /// @dev This will allow fees to be collected but not allow the LP to be unlocked
    function add(uint256 tokenId) external {
        require(!lockedPositions[tokenId], "LP already locked");
        require(positionManager.ownerOf(tokenId) == address(this), "this contract doesn't have the LP NFT");

        lockedPositions[tokenId] = true;
    }

    /// @dev Collects fees from the Uniswap V3 pool and transfers them to the fee collector
    function earn(uint256 tokenId) public returns (uint256 amount0, uint256 amount1) {
        require(lockedPositions[tokenId], "LP not locked");

        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                tokenId: tokenId
            })
        );

        (,, address token0, address token1,,,,,,,,) = positionManager.positions(tokenId);

        // Transfer all collected fees to fee collector
        IERC20(token0).safeTransfer(feeCollector, amount0);
        IERC20(token1).safeTransfer(feeCollector, amount1);

        emit ClaimedFees(msg.sender, token0, token1, 0, 0, amount0, amount1);
    }

    function earnMany(uint256[] memory tokenIds)
        external
        returns (uint256[] memory amounts0, uint256[] memory amounts1)
    {
        amounts0 = new uint256[](tokenIds.length);
        amounts1 = new uint256[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            (amounts0[i], amounts1[i]) = earn(tokenIds[i]);
        }
    }

    /// @dev Internal function to handle NFT transfer logic
    function _transfer(uint256 tokenId) internal {
        require(lockedPositions[tokenId], "LP not locked");
        require(positionManager.ownerOf(tokenId) == address(this), "this contract doesn't have the LP NFT");

        // Remove from locked positions
        lockedPositions[tokenId] = false;

        // Transfer NFT back to owner
        positionManager.safeTransferFrom(address(this), owner(), tokenId);

        emit NFTTransferred(tokenId, owner());
    }

    /// @dev Transfers the ERC721 token back to the owner
    function transfer(uint256 tokenId) external onlyOwner {
        _transfer(tokenId);
    }

    /// @dev Transfers multiple ERC721 tokens back to the owner
    function transferMany(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _transfer(tokenIds[i]);
        }
    }
}
