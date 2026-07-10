// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal mock of the SlippagePriceChecker surface used by LPCompoundModule tests.
contract MockSlippagePriceChecker {
    bool public priceOk = true;
    uint256 public maxValid = 30 minutes;
    mapping(address => bool) public reward;
    /// @notice How far below oracle the modeled order is priced, in bps (negative = priced ABOVE
    ///         oracle). Mirrors the real checker's STRICT inequality — SlippagePriceChecker uses
    ///         `_minOut > expectedOut·(BPS−bps)/BPS`, so a fixed order at discount d passes iff the
    ///         allowed slippage is strictly greater than d: an exactly-at-oracle order (d = 0) FAILS
    ///         at 0 bps, and only an above-oracle order (d < 0) clears a 0-bps knob.
    int256 public oracleDiscountBps;

    function setPriceOk(bool ok) external {
        priceOk = ok;
    }

    function setOracleDiscountBps(int256 v) external {
        oracleDiscountBps = v;
    }

    function setMaxTimePriceValid(address, uint256 v) external {
        maxValid = v;
    }

    function setRewardToken(address t, bool v) external {
        reward[t] = v;
    }

    function checkPrice(uint256, address, address, uint256, uint256 slippageBps) external view returns (bool) {
        return priceOk && int256(slippageBps) > oracleDiscountBps;
    }

    function isRewardToken(address t) external view returns (bool) {
        return reward[t];
    }

    function maxTimePriceValid(address) external view returns (uint256) {
        return maxValid;
    }
}
