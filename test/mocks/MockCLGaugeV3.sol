// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal mock of the Slipstream V3 CLGauge surface: no `rewardToken()`, no `getReward`,
///         no `earned(address,uint256)`. Claims go through `claimEmissions(account, recipient, ids)`,
///         which, like the real gauge, requires `msg.sender == account`, every id staked, and a
///         non-empty list unless the account has deferred emissions (`NS`).
contract MockCLGaugeV3 {
    using SafeERC20 for IERC20;

    address public immutable emissionToken;
    address public pool;

    /// @notice AERO paid per claimed token id (claimEmissions) and per withdraw.
    uint256 public aeroPerId;
    /// @notice `earned` returns this per listed id, plus the account's deferred emissions.
    uint256 public earnedPerId;
    bool public earnedReverts;

    mapping(address => uint256) public deferredEmissions;

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

    function setEarned(uint256 perId, bool reverts) external {
        earnedPerId = perId;
        earnedReverts = reverts;
    }

    /// @notice Simulate a failed withdraw-time mint that left `amount` deferred for `account`.
    function setDeferred(address account, uint256 amount) external {
        deferredEmissions[account] = amount;
    }

    function deposit(uint256 tokenId) external {
        _staked[msg.sender][tokenId] = true;
    }

    function withdraw(uint256 tokenId) external {
        require(_staked[msg.sender][tokenId], "NA");
        _staked[msg.sender][tokenId] = false;
        if (aeroPerId > 0) IERC20(emissionToken).safeTransfer(msg.sender, aeroPerId);
    }

    /// @notice Mirrors the factory's `emergencyWithdrawEnabled()` gate (off by default, as on Base).
    bool public emergencyEnabled;

    function setEmergencyEnabled(bool enabled) external {
        emergencyEnabled = enabled;
    }

    /// @notice Like the real gauge: flag gate (`NE`), then only the stake owner (`NA`); skips the voter.
    function emergencyWithdraw(uint256 tokenId) external {
        require(emergencyEnabled, "NE");
        require(_staked[msg.sender][tokenId], "NA");
        _staked[msg.sender][tokenId] = false;
    }

    function claimEmissions(address account, address recipient, uint256[] calldata tokenIds) external {
        require(msg.sender == account, "NA");
        for (uint256 i; i < tokenIds.length; i++) {
            require(_staked[account][tokenIds[i]], "NA");
        }
        require(tokenIds.length > 0 || deferredEmissions[account] > 0, "NS");
        claimCallCount++;
        lastClaimIdCount = tokenIds.length;
        lastClaimRecipient = recipient;
        uint256 amount = aeroPerId * tokenIds.length + deferredEmissions[account];
        delete deferredEmissions[account];
        if (amount > 0) IERC20(emissionToken).safeTransfer(recipient, amount);
    }

    function earned(address account, uint256[] memory tokenIds) external view returns (uint256) {
        require(!earnedReverts, "earned");
        for (uint256 i; i < tokenIds.length; i++) {
            require(_staked[account][tokenIds[i]], "NA");
        }
        return earnedPerId * tokenIds.length + deferredEmissions[account];
    }

    /// @notice Exists only for LPPositionLib.isV3Gauge, which probes it to classify the gauge.
    function depositBlock(uint256) external pure returns (uint256) {}

    function stakedContains(address depositor, uint256 tokenId) external view returns (bool) {
        return _staked[depositor][tokenId];
    }
}
