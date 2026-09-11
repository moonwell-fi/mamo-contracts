// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";

import {IGPv2Settlement} from "@interfaces/IGPv2Settlement.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StockAccountStrategy
 * @notice A per-user account holding a cash asset and tokenized stock positions against a target basket
 * @dev This contract is designed to be used as an implementation for proxies
 */
contract StockAccountStrategy is BaseStrategy, IStockAccountStrategy {
    using SafeERC20 for IERC20;

    uint16 internal constant TOTAL_BPS = 10_000;

    /// @notice The cash leg of the account, also the unit of account for every valuation
    IERC20 public asset;

    /// @notice Registry holding the token allowlist and the account wide limits
    IStockAccountRegistry public stockRegistry;

    /// @notice EIP-712 domain separator read from the CoW settlement contract at initialization
    bytes32 public cowDomainSeparator;

    /// @notice CoW contract that pulls tokens out of this account when an order settles
    address public cowVaultRelayer;

    /// @notice Share of the account targeted to stay in the asset, in basis points
    uint16 public cashTargetBps;

    /// @notice Slippage override in basis points, zero means use the registry cap
    uint16 public accountSlippageBps;

    BasketEntry[] internal _entries;

    struct InitParams {
        address asset;
        uint16 cashTargetBps;
        address cowSettlement;
        BasketEntry[] entries;
        address mamoStrategyRegistry;
        address owner;
        address stockRegistry;
        uint256 strategyTypeId;
    }

    /**
     * @notice Initializer that sets all the parameters and the initial basket
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.asset != address(0), "Invalid asset address");
        require(params.cowSettlement != address(0), "Invalid settlement address");
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.stockRegistry != address(0), "Invalid stock registry address");
        require(params.strategyTypeId != 0, "Strategy type id not set");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        asset = IERC20(params.asset);
        stockRegistry = IStockAccountRegistry(params.stockRegistry);
        cowDomainSeparator = IGPv2Settlement(params.cowSettlement).domainSeparator();
        cowVaultRelayer = IGPv2Settlement(params.cowSettlement).vaultRelayer();

        _setBasket(params.entries, params.cashTargetBps);
    }

    /**
     * @notice Funds the account with the asset, callable by anyone
     * @param amount The amount of the asset to pull from the caller
     */
    function deposit(uint256 amount) external override {
        require(amount > 0, "Amount must be greater than 0");

        asset.safeTransferFrom(msg.sender, address(this), amount);
        _checkDepositCap();

        emit Deposit(amount);
    }

    /**
     * @notice Funds the account with an active listed token, callable by anyone
     * @param token The token to pull from the caller
     * @param amount The amount of the token to pull from the caller
     */
    function depositToken(address token, uint256 amount) external override {
        require(amount > 0, "Amount must be greater than 0");
        require(stockRegistry.tokenConfig(token).status == IStockAccountRegistry.TokenStatus.Active, "Token not active");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _checkDepositCap();

        emit DepositToken(token, amount);
    }

    /**
     * @notice Sends a token held by the account to the owner without selling anything
     * @param token The token to send, the asset included
     * @param amount The amount to send
     */
    function withdrawToken(address token, uint256 amount) external override onlyOwner {
        require(amount > 0, "Amount must be greater than 0");

        IERC20(token).safeTransfer(owner(), amount);

        emit WithdrawToken(token, amount);
    }

    /// @notice Sends every balance held by the account to the owner without selling anything
    function withdrawAllInKind() external override onlyOwner {
        address to = owner();

        uint256 assetBalance = asset.balanceOf(address(this));
        if (assetBalance > 0) {
            asset.safeTransfer(to, assetBalance);
            emit WithdrawToken(address(asset), assetBalance);
        }

        address[] memory tokens = stockRegistry.allTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                IERC20(tokens[i]).safeTransfer(to, balance);
                emit WithdrawToken(tokens[i], balance);
            }
        }
    }

    /**
     * @notice Replaces the target basket
     * @param entries The target weight of each token, tokens are removed by omitting them
     * @param newCashTargetBps The share targeted to stay in the asset, in basis points
     */
    function setBasket(BasketEntry[] calldata entries, uint16 newCashTargetBps) external override onlyOwner {
        _setBasket(entries, newCashTargetBps);
    }

    /**
     * @notice Sets the slippage this account tolerates on swaps
     * @param bps The slippage in basis points, zero to follow the registry cap
     */
    function setAccountSlippage(uint16 bps) external override onlyOwner {
        require(bps <= stockRegistry.maxBackendSlippageBps(), "Slippage exceeds maximum");

        emit SlippageUpdated(accountSlippageBps, bps);

        accountSlippageBps = bps;
    }

    /**
     * @notice Grants the CoW vault relayer an unlimited allowance so orders can settle, callable by anyone
     * @param token The asset or a listed token
     */
    function approveCowRelayer(address token) external override {
        require(
            token == address(asset) || stockRegistry.tokenConfig(token).status != IStockAccountRegistry.TokenStatus.None,
            "Token not listed"
        );

        IERC20(token).forceApprove(cowVaultRelayer, type(uint256).max);
    }

    function withdraw(uint256, uint16) external virtual override onlyOwner {
        revert("Not implemented");
    }

    function withdrawAll(uint16) external virtual override onlyOwner {
        revert("Not implemented");
    }

    function previewWithdraw(uint256, uint16)
        external
        view
        virtual
        override
        returns (address[] memory, uint256[] memory, uint256, uint256)
    {
        revert("Not implemented");
    }

    /// @notice Value of everything the account holds, in asset units, at registry reference prices
    function getNAV() public view override returns (uint256 valueUsdc) {
        valueUsdc = asset.balanceOf(address(this));

        address[] memory tokens = stockRegistry.allTokens();
        ISlippagePriceChecker priceChecker = stockRegistry.priceChecker();

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                valueUsdc += priceChecker.getExpectedOut(balance, tokens[i], address(asset));
            }
        }
    }

    /// @notice Current and target weight of every listed token, in basis points of the account value
    function getWeights()
        external
        view
        override
        returns (address[] memory tokens, uint256[] memory currentBps, uint256[] memory targetBps)
    {
        tokens = stockRegistry.allTokens();
        currentBps = new uint256[](tokens.length);
        targetBps = new uint256[](tokens.length);

        ISlippagePriceChecker priceChecker = stockRegistry.priceChecker();
        uint256[] memory values = new uint256[](tokens.length);
        uint256 nav = asset.balanceOf(address(this));

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                values[i] = priceChecker.getExpectedOut(balance, tokens[i], address(asset));
                nav += values[i];
            }
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            currentBps[i] = nav == 0 ? 0 : (values[i] * TOTAL_BPS) / nav;
            targetBps[i] = _targetBps(tokens[i]);
        }
    }

    /// @notice The target basket and the cash target
    function getBasket() external view override returns (BasketEntry[] memory entries, uint16) {
        return (_entries, cashTargetBps);
    }

    /// @notice The listed tokens this account currently holds a balance of
    function heldTokens() external view override returns (address[] memory) {
        address[] memory tokens = stockRegistry.allTokens();
        uint256 count;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).balanceOf(address(this)) > 0) {
                count++;
            }
        }

        address[] memory held = new address[](count);
        uint256 next;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).balanceOf(address(this)) > 0) {
                held[next++] = tokens[i];
            }
        }

        return held;
    }

    /// @notice The slippage that applies to this account, capped by the registry
    function getAccountSlippage() external view override returns (uint16) {
        uint16 cap = stockRegistry.maxBackendSlippageBps();
        return accountSlippageBps == 0 || accountSlippageBps > cap ? cap : accountSlippageBps;
    }

    function _setBasket(BasketEntry[] calldata entries, uint16 newCashTargetBps) internal {
        require(entries.length <= stockRegistry.maxPositions(), "Too many positions");

        uint16 minTargetBps = stockRegistry.minTargetBps();
        uint256 total;

        for (uint256 i = 0; i < entries.length; i++) {
            require(entries[i].targetBps >= minTargetBps, "Weight below minimum");
            require(
                stockRegistry.tokenConfig(entries[i].token).status == IStockAccountRegistry.TokenStatus.Active,
                "Token not active"
            );

            for (uint256 j = 0; j < i; j++) {
                require(entries[j].token != entries[i].token, "Duplicate token");
            }

            total += entries[i].targetBps;
        }

        require(total + newCashTargetBps == TOTAL_BPS, "Weights must total 10000");

        delete _entries;

        for (uint256 i = 0; i < entries.length; i++) {
            _entries.push(entries[i]);
        }

        cashTargetBps = newCashTargetBps;

        emit BasketUpdated(entries, newCashTargetBps);
    }

    function _checkDepositCap() internal view {
        require(getNAV() <= stockRegistry.maxStrategyDeposit(), "Deposit cap exceeded");
    }

    function _targetBps(address token) internal view returns (uint16) {
        for (uint256 i = 0; i < _entries.length; i++) {
            if (_entries[i].token == token) {
                return _entries[i].targetBps;
            }
        }

        return 0;
    }
}
