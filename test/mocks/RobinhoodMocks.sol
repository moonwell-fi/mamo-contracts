// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUniswapV3SwapRouter} from "@contracts/robinhood/interfaces/IUniswapV3SwapRouter.sol";
import {MockERC20} from "@test/MockERC20.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Plain OZ ERC4626 vault. Yield is simulated by minting underlying directly to the vault.
contract MockERC4626 is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}
}

/// @notice Minimal stand-in for MamoStrategyRegistry: backend address + user→strategy records
contract MockStrategyRegistry {
    address public backend;
    mapping(address => mapping(address => bool)) private _userStrategies;

    constructor(address _backend) {
        backend = _backend;
    }

    function getBackendAddress() external view returns (address) {
        return backend;
    }

    function setUserStrategy(address user, address strategy, bool isStrategy) external {
        _userStrategies[user][strategy] = isStrategy;
    }

    function isUserStrategy(address user, address strategy) external view returns (bool) {
        return _userStrategies[user][strategy];
    }

    function updateStrategyOwner(address newOwner) external {}
}

/// @notice Oracle stub: expectedOut = amountIn * rate / 1e18 per (from, to) pair
contract MockSlippagePriceChecker {
    mapping(address => bool) public isRewardToken;
    mapping(address => mapping(address => uint256)) public rate;

    function setRewardToken(address token, bool allowed) external {
        isRewardToken[token] = allowed;
    }

    function setRate(address fromToken, address toToken, uint256 rate1e18) external {
        rate[fromToken][toToken] = rate1e18;
    }

    function getExpectedOut(uint256 amountIn, address fromToken, address toToken) external view returns (uint256) {
        return (amountIn * rate[fromToken][toToken]) / 1e18;
    }
}

/// @notice Router stub: pays out tokenOut at execRate, enforcing amountOutMinimum like Uniswap V3
contract MockSwapRouter is IUniswapV3SwapRouter {
    using SafeERC20 for IERC20;

    // execution rate per (tokenIn, tokenOut), 1e18-scaled — set below oracle rate to simulate slippage
    mapping(address => mapping(address => uint256)) public execRate;

    function setExecRate(address tokenIn, address tokenOut, uint256 rate1e18) external {
        execRate[tokenIn][tokenOut] = rate1e18;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        amountOut = (params.amountIn * execRate[params.tokenIn][params.tokenOut]) / 1e18;
        require(amountOut >= params.amountOutMinimum, "Too little received");

        MockERC20(params.tokenOut).mint(msg.sender, amountOut);
    }
}

/// @notice Distributor stub: mints the claimed amounts to the accounts, ignoring proofs
contract MockMerkleDistributor {
    function claim(
        address[] calldata accounts,
        address[] calldata rewardTokens,
        uint256[] calldata rewardAmounts,
        bytes32[][] calldata
    ) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            MockERC20(rewardTokens[i]).mint(accounts[i], rewardAmounts[i]);
        }
    }
}
