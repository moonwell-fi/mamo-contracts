// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGPv2SettlementLike {
    struct Trade {
        uint256 sellTokenIndex;
        uint256 buyTokenIndex;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        uint256 flags;
        uint256 executedAmount;
        bytes signature;
    }

    struct Interaction {
        address target;
        uint256 value;
        bytes callData;
    }

    function settle(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        Trade[] calldata trades,
        Interaction[][3] calldata interactions
    ) external;
}

interface IStockRegistryLike {
    function tokenConfig(address token)
        external
        view
        returns (uint8 status, uint8 source, address pool, address feed);
}

interface IPoolLike {
    function tickSpacing() external view returns (int24);
}

/// @title SettlementHelper
/// @notice Vnet-only CoW solver that settles stock account orders, so the whole settlement path runs
///         on the Tenderly node where the B20 stock token precompiles are executable.
contract SettlementHelper {
    /// @dev sell kind, fill-or-kill, erc20 balances both sides, EIP-1271 signing scheme.
    uint256 internal constant EIP1271_SELL_FOK_FLAGS = 0x40;

    IGPv2SettlementLike public immutable settlement;
    ISwapRouter public immutable router;
    IStockRegistryLike public immutable stockRegistry;
    address public immutable asset;

    error TokensMustDiffer();
    error OrdersMustOppose();
    error ZeroClearingPrice();

    constructor(
        IGPv2SettlementLike settlement_,
        ISwapRouter router_,
        IStockRegistryLike stockRegistry_,
        address asset_
    ) {
        settlement = settlement_;
        router = router_;
        stockRegistry = stockRegistry_;
        asset = asset_;
    }

    /// @notice Settles one account order, the settlement sourcing the buy token from the stocks pool
    /// @param account The stock account that owns the order and validates it through EIP-1271
    /// @param order The order the account signed
    /// @param clearingSell Uniform clearing price of the sell token
    /// @param clearingBuy Uniform clearing price of the buy token
    function settleSell(address account, GPv2Order.Data calldata order, uint256 clearingSell, uint256 clearingBuy)
        external
    {
        if (clearingSell == 0 || clearingBuy == 0) revert ZeroClearingPrice();
        if (address(order.sellToken) == address(order.buyToken)) revert TokensMustDiffer();

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = order.sellToken;
        tokens[1] = order.buyToken;

        uint256[] memory prices = new uint256[](2);
        prices[0] = clearingSell;
        prices[1] = clearingBuy;

        IGPv2SettlementLike.Trade[] memory trades = new IGPv2SettlementLike.Trade[](1);
        trades[0] = _trade(account, order, 0, 1);

        uint256 buyOwed = (order.sellAmount * clearingSell) / clearingBuy;

        settlement.settle(tokens, prices, trades, _swapInteractions(order, buyOwed));
    }

    /// @notice Settles two accounts on opposite sides of the same pair against each other, no venue touched
    /// @param accountA The account selling `orderA.sellToken`
    /// @param orderA The order of `accountA`
    /// @param accountB The account selling `orderA.buyToken`
    /// @param orderB The order of `accountB`, whose sell amount must equal `orderA.buyAmount`
    function settleBatch(
        address accountA,
        GPv2Order.Data calldata orderA,
        address accountB,
        GPv2Order.Data calldata orderB
    ) external {
        if (
            address(orderA.sellToken) != address(orderB.buyToken)
                || address(orderA.buyToken) != address(orderB.sellToken)
        ) revert OrdersMustOppose();

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = orderA.sellToken;
        tokens[1] = orderA.buyToken;

        uint256[] memory prices = new uint256[](2);
        prices[0] = orderA.buyAmount;
        prices[1] = orderA.sellAmount;

        IGPv2SettlementLike.Trade[] memory trades = new IGPv2SettlementLike.Trade[](2);
        trades[0] = _trade(accountA, orderA, 0, 1);
        trades[1] = _trade(accountB, orderB, 1, 0);

        IGPv2SettlementLike.Interaction[][3] memory interactions;
        interactions[0] = new IGPv2SettlementLike.Interaction[](0);
        interactions[1] = new IGPv2SettlementLike.Interaction[](0);
        interactions[2] = new IGPv2SettlementLike.Interaction[](0);

        settlement.settle(tokens, prices, trades, interactions);
    }

    /// @notice The EIP-712 digest the settlement will ask the account to validate
    function digest(GPv2Order.Data memory order, bytes32 domainSeparator) external pure returns (bytes32) {
        return GPv2Order.hash(order, domainSeparator);
    }

    /// @notice The bytes the account decodes in `isValidSignature`
    function encodeOrder(GPv2Order.Data memory order) public pure returns (bytes memory) {
        return abi.encode(order);
    }

    /// @notice The trade signature field: the owner address followed by the encoded order
    function encodeSignature(address account, GPv2Order.Data memory order) public pure returns (bytes memory) {
        return abi.encodePacked(account, abi.encode(order));
    }

    function _trade(address account, GPv2Order.Data calldata order, uint256 sellIndex, uint256 buyIndex)
        internal
        pure
        returns (IGPv2SettlementLike.Trade memory)
    {
        return IGPv2SettlementLike.Trade({
            sellTokenIndex: sellIndex,
            buyTokenIndex: buyIndex,
            receiver: order.receiver,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: EIP1271_SELL_FOK_FLAGS,
            executedAmount: 0,
            signature: encodeSignature(account, order)
        });
    }

    function _swapInteractions(GPv2Order.Data calldata order, uint256 buyOwed)
        internal
        view
        returns (IGPv2SettlementLike.Interaction[][3] memory interactions)
    {
        interactions[0] = new IGPv2SettlementLike.Interaction[](0);
        interactions[2] = new IGPv2SettlementLike.Interaction[](0);
        interactions[1] = new IGPv2SettlementLike.Interaction[](2);

        interactions[1][0] = IGPv2SettlementLike.Interaction({
            target: address(order.sellToken),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(router), order.sellAmount))
        });

        interactions[1][1] = IGPv2SettlementLike.Interaction({
            target: address(router),
            value: 0,
            callData: abi.encodeCall(
                ISwapRouter.exactInputSingle,
                (
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: address(order.sellToken),
                        tokenOut: address(order.buyToken),
                        tickSpacing: _tickSpacing(address(order.sellToken), address(order.buyToken)),
                        recipient: address(settlement),
                        deadline: block.timestamp,
                        amountIn: order.sellAmount,
                        amountOutMinimum: buyOwed,
                        sqrtPriceLimitX96: 0
                    })
                )
            )
        });
    }

    function _tickSpacing(address sellToken, address buyToken) internal view returns (int24) {
        (,, address pool,) = stockRegistry.tokenConfig(sellToken == asset ? buyToken : sellToken);
        return IPoolLike(pool).tickSpacing();
    }
}
