// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IStockAccountStrategy {
    struct BasketEntry {
        address token;
        uint16 targetBps;
    }

    event Deposit(uint256 amount);
    event DepositToken(address indexed token, uint256 amount);
    event Withdraw(uint256 usdcOut, uint256 sold);
    event WithdrawToken(address indexed token, uint256 amount);
    event BasketUpdated(BasketEntry[] entries, uint16 cashTargetBps);
    event SlippageUpdated(uint16 oldBps, uint16 newBps);
    event FeesAccrued(uint256 elapsed);
    event FeesCollected(address indexed token, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    error ZeroAddress();
    error StrategyTypeIdNotSet();
    error FeeExceedsMaximum();
    error NotBackend();
    error ZeroAmount();
    error TokenNotActive(address token);
    error TokenNotListed(address token);
    error AccountBelowMinimum(uint256 nav);
    error DepositCapExceeded(uint256 nav);
    error ExceedsAvailable(address token);
    error TooManyPositions();
    error WeightBelowMinimum(address token);
    error DuplicateToken(address token);
    error WeightsMustTotal(uint256 total);
    error SlippageExceedsMaximum();
    error NothingToCollect();
    error InsufficientBalance();
    error InsufficientProceeds();
    error EmptyBalance();
    error OrderHashMismatch();
    error InvalidBackendSignature();
    error OrderMustBeSell();
    error OrderMustBeFillOrKill();
    error OrderBalancesMustBeErc20();
    error OrderReceiverMismatch();
    error OrderFeeMustBeZero();
    error InvalidAppData();
    error OrderExpiresTooSoon();
    error OrderExpiresTooLate();
    error TokensMustDiffer();
    error SellTokenNotSellable(address token);
    error BuyTokenNotActive(address token);
    error SellExceedsBalance();
    error SellLeavesTokenBelowRange(address token);
    error BuyLeavesTokenAboveRange(address token);
    error PriceCheckFailed();
    error RegistryPaused();

    function deposit(uint256 amount) external;

    function depositToken(address token, uint256 amount) external;

    function withdraw(uint256 usdcAmount, uint16 maxSlippageBps) external;

    function withdrawAll(uint16 maxSlippageBps) external;

    function withdrawToken(address token, uint256 amount) external;

    function withdrawAllInKind() external;

    function setBasket(BasketEntry[] calldata entries, uint16 cashTargetBps) external;

    function setAccountSlippage(uint16 bps) external;

    function setFeeRecipient(address newRecipient) external;

    function approveCowRelayer(address token) external;

    function accrueManagementFee() external;

    function collectFees(address token) external;

    function getNAV() external view returns (uint256 valueUsdc);

    function getWeights()
        external
        view
        returns (address[] memory tokens, uint256[] memory currentBps, uint256[] memory targetBps);

    function getBasket() external view returns (BasketEntry[] memory entries, uint16 cashTargetBps);

    function heldTokens() external view returns (address[] memory);

    function previewWithdraw(uint256 usdcAmount, uint16 maxSlippageBps)
        external
        view
        returns (address[] memory tokensToSell, uint256[] memory amounts, uint256 referenceValue, uint256 minProceeds);

    function getAccountSlippage() external view returns (uint16);

    function feeOwed(address token) external view returns (uint256);
}
