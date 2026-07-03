// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal mock of the SlippagePriceChecker surface used by LPCompoundModule tests.
contract MockSlippagePriceChecker {
    bool public priceOk = true;
    uint256 public maxValid = 30 minutes;
    mapping(address => bool) public reward;
    /// @notice Minimum slippage bps the caller must allow for checkPrice to pass — models an
    ///         order priced exactly this far below oracle (the real check is monotonic in
    ///         slippage: a fixed order passes iff allowed slippage >= its oracle discount).
    uint256 public minSlippageToPass;

    function setPriceOk(bool ok) external {
        priceOk = ok;
    }

    function setMinSlippageToPass(uint256 v) external {
        minSlippageToPass = v;
    }

    function setMaxTimePriceValid(address, uint256 v) external {
        maxValid = v;
    }

    function setRewardToken(address t, bool v) external {
        reward[t] = v;
    }

    function checkPrice(uint256, address, address, uint256, uint256 slippageBps) external view returns (bool) {
        return priceOk && slippageBps >= minSlippageToPass;
    }

    function isRewardToken(address t) external view returns (bool) {
        return reward[t];
    }

    function maxTimePriceValid(address) external view returns (uint256) {
        return maxValid;
    }
}
