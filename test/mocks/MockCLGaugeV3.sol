// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal mock of the Slipstream V3 CLGauge surface: no `rewardToken()`, no `getReward`,
///         no `earned(address,uint256)`. Claims go through `claimEmissions(account, recipient, ids)`,
///         which, like the real gauge, requires `msg.sender == account` and every id to be staked.
contract MockCLGaugeV3 {
    using SafeERC20 for IERC20;

    address public immutable emissionToken;
    address public pool;

    /// @notice AERO paid per claimed token id (claimEmissions) and per withdraw.
    uint256 public aeroPerId;
    /// @notice Value returned by `earned` for any staked set; `earnedReverts` makes it revert.
    uint256 public earnedAmount;
    bool public earnedReverts;

    uint256 public claimCallCount;
    uint256 public lastClaimIdCount;
    address public lastClaimRecipient;

    mapping(address => mapping(uint256 => bool)) internal _staked;

    constructor(address emissionToken_) {
        emissionToken = emissionToken_;
    }

    function setPool(address pool_) external {
        pool = pool_;
    }

    /// @notice Position manager reported via `nft()` (for the gauge->NFPM binding check).
    address public nft;

    function setNft(address nft_) external {
        nft = nft_;
    }

    function setAeroPerId(uint256 amount) external {
        aeroPerId = amount;
    }

    function setEarned(uint256 amount, bool reverts) external {
        earnedAmount = amount;
        earnedReverts = reverts;
    }

    function deposit(uint256 tokenId) external {
        _staked[msg.sender][tokenId] = true;
    }

    function withdraw(uint256 tokenId) external {
        require(_staked[msg.sender][tokenId], "NA");
        _staked[msg.sender][tokenId] = false;
        if (aeroPerId > 0) IERC20(emissionToken).safeTransfer(msg.sender, aeroPerId);
    }

    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external {
        require(msg.sender == account, "NA");
        for (uint256 i; i < tokenIds.length; i++) {
            require(_staked[account][tokenIds[i]], "NA");
        }
        claimCallCount++;
        lastClaimIdCount = tokenIds.length;
        lastClaimRecipient = recipient;
        uint256 amount = aeroPerId * tokenIds.length;
        if (amount > 0) IERC20(emissionToken).safeTransfer(recipient, amount);
    }

    function earned(address account, uint256[] memory tokenIds) external view returns (uint256) {
        require(!earnedReverts, "earned");
        for (uint256 i; i < tokenIds.length; i++) {
            require(_staked[account][tokenIds[i]], "NA");
        }
        return earnedAmount;
    }

    /// @notice Exists only for LPPositionLib.isV3Gauge, which probes it to classify the gauge.
    function depositBlock(uint256) external pure returns (uint256) {}

    function stakedContains(address depositor, uint256 tokenId) external view returns (bool) {
        return _staked[depositor][tokenId];
    }
}
