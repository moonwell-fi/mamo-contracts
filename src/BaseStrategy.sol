// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseStrategy} from "@interfaces/IBaseStrategy.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BaseStrategy
 * @notice Base contract for all strategy implementations
 * @dev Provides common functionality for all strategy contracts including
 *      registry reference, upgrade authorization, and token recovery
 */
contract BaseStrategy is Initializable, UUPSUpgradeable, IBaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice Reference to the Mamo Strategy Registry contract
    IMamoStrategyRegistry public mamoStrategyRegistry;

    /// @notice The strategy type ID that identifies this strategy's implementation
    uint256 public strategyTypeId;

    /// @notice Emitted when tokens are recovered from the contract
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Restricts function access to the strategy owner only
     * @dev Uses the MamoStrategyRegistry to verify ownership
     */
    modifier onlyStrategyOwner() {
        require(mamoStrategyRegistry.isUserStrategy(msg.sender, address(this)), "Not strategy owner");
        _;
    }

    /**
     * @notice Allows the contract to receive ETH
     */
    receive() external payable {}

    /**
     * @notice Recovers ERC20 tokens accidentally sent to this contract
     * @dev Only callable by the user who owns this strategy
     * @param tokenAddress The address of the token to recover
     * @param to The address to send the tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address tokenAddress, address to, uint256 amount) external onlyStrategyOwner {
        require(to != address(0), "Cannot send to zero address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(tokenAddress).safeTransfer(to, amount);

        emit TokenRecovered(tokenAddress, to, amount);
    }

    /**
     * @notice Recovers ETH accidentally sent to this contract
     * @dev Only callable by the user who owns this strategy
     * @param to The address to send the ETH to
     */
    function recoverETH(address payable to) external onlyStrategyOwner {
        require(to != address(0), "Cannot send to zero address");

        uint256 balance = address(this).balance;
        require(balance > 0, "Empty balance");

        (bool success,) = to.call{value: balance}("");
        require(success, "Transfer failed");

        emit TokenRecovered(address(0), to, balance);
    }

    /**
     * @notice Internal function that authorizes an upgrade to a new implementation
     * @dev Only callable by Mamo Strategy Registry contract
     */
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == address(mamoStrategyRegistry), "Only Mamo Strategy Registry can call");
    }

    /**
     * @notice Initializes the BaseStrategy contract
     * @param _mamoStrategyRegistry Address of the MamoStrategyRegistry contract
     * @param _strategyTypeId The unique identifier for this strategy type
     */
    function __BaseStrategy_init(address _mamoStrategyRegistry, uint256 _strategyTypeId) internal onlyInitializing {
        mamoStrategyRegistry = IMamoStrategyRegistry(_mamoStrategyRegistry);
        strategyTypeId = _strategyTypeId;
    }
}
