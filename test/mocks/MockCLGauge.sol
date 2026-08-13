// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The slice of the position manager this gauge needs for custody.
interface IMockNpmCustody {
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Minimal mock for ICLGauge used in unit tests.
contract MockCLGauge {
    using SafeERC20 for IERC20;

    address public aeroToken;

    // Pool this gauge is bound to (read by _validateAndStore's gauge->pool binding check).
    address public pool;

    /// @notice The position manager to take real ERC-721 custody through. OPT-IN: when unset the gauge
    ///         only tracks the stake set, preserving the behaviour older suites rely on.
    /// @dev Wired by the leveraged-aero suites so a staked NFT is actually OWNED by the gauge, the way
    ///      the real CLGauge holds it. Without custody, `MockNpm` would still authorise the strategy to
    ///      touch a staked position — so a liquidity-touch-before-unstake bug passes the suite and
    ///      reverts on chain.
    address public npm;

    // Amount of AERO to pay out when withdraw() is called
    uint256 public aeroToPayOnWithdraw;

    // Last recorded deposit call
    uint256 public lastDepositedTokenId;
    address public lastDepositor;
    uint256 public depositCallCount;

    // Last recorded withdraw call
    uint256 public lastWithdrawnTokenId;
    address public lastWithdrawCaller;
    uint256 public withdrawCallCount;

    constructor(address aeroToken_) {
        aeroToken = aeroToken_;
    }

    /// @notice Set the pool this gauge reports as its own (for the gauge->pool binding check).
    function setPool(address pool_) external {
        pool = pool_;
    }

    /// @notice Enable real ERC-721 custody through `npm_` (see the `npm` field).
    function setNpm(address npm_) external {
        npm = npm_;
    }

    /// @notice Configure how much AERO to transfer to msg.sender on withdraw.
    function setAeroToPayOnWithdraw(uint256 amount) external {
        aeroToPayOnWithdraw = amount;
    }

    /// @dev Per-depositor stake set, mirroring the real Slipstream `CLGauge._stakes`. Modelled on
    ///      purpose: the previous stub let `withdraw` succeed on an NFT the gauge never held, which
    ///      made an unstaked-but-still-referenced position indistinguishable from a staked one and
    ///      hid a permanent-DoS class of bug from the whole suite.
    mapping(address => mapping(uint256 => bool)) internal _staked;

    error MockCLGaugeNotStaked();

    function deposit(uint256 tokenId) external {
        lastDepositedTokenId = tokenId;
        lastDepositor = msg.sender;
        depositCallCount++;
        _staked[msg.sender][tokenId] = true;
        // Real custody when wired: the gauge pulls the NFT using the approval the depositor just gave.
        if (npm != address(0)) IMockNpmCustody(npm).transferFrom(msg.sender, address(this), tokenId);
    }

    function withdraw(uint256 tokenId) external {
        // The real CLGauge reverts when the caller is not the staked depositor (it transfers the NFT
        // out of the gauge's own custody). Enforced here so a test can observe the orphaned-NFT state.
        if (!_staked[msg.sender][tokenId]) revert MockCLGaugeNotStaked();
        _staked[msg.sender][tokenId] = false;

        lastWithdrawnTokenId = tokenId;
        lastWithdrawCaller = msg.sender;
        withdrawCallCount++;
        if (npm != address(0)) IMockNpmCustody(npm).transferFrom(address(this), msg.sender, tokenId);

        // Simulate auto-claim: transfer AERO to caller (like Aerodrome does)
        if (aeroToPayOnWithdraw > 0) {
            IERC20(aeroToken).safeTransfer(msg.sender, aeroToPayOnWithdraw);
        }
    }

    // Amount of AERO to pay out when getReward() is called
    uint256 public aeroToPayOnGetReward;

    // Last recorded getReward call
    uint256 public lastGetRewardTokenId;
    uint256 public getRewardCallCount;

    /// @notice Configure how much AERO to transfer to msg.sender on getReward.
    function setAeroToPayOnGetReward(uint256 amount) external {
        aeroToPayOnGetReward = amount;
    }

    function getReward(uint256 tokenId) external {
        lastGetRewardTokenId = tokenId;
        getRewardCallCount++;

        // Simulate reward claim: transfer AERO to caller
        if (aeroToPayOnGetReward > 0) {
            IERC20(aeroToken).safeTransfer(msg.sender, aeroToPayOnGetReward);
        }
    }

    // Configurable earned value returned by earned()
    uint256 public earnedAmount;

    /// @notice Configure the value returned by earned().
    function setEarnedAmount(uint256 amount) external {
        earnedAmount = amount;
    }

    function earned(address, uint256) external view returns (uint256) {
        return earnedAmount;
    }

    function rewardToken() external view returns (address) {
        return aeroToken;
    }

    function stakedContains(address depositor, uint256 tokenId) external view returns (bool) {
        return _staked[depositor][tokenId];
    }
}
