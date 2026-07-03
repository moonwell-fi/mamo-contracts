// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILPAutoBalancerV2} from "@interfaces/ILPAutoBalancerV2.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {GPv2Order} from "@libraries/GPv2Order.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LPCompoundModule
/// @notice Isolates all CowSwap / EIP-1271 concerns for a single LPAutoBalancerV2, keeping the
///         balancer under the 24 KB / via_ir budget. Validates reward-only AERO -> token0|token1
///         compound orders. Settled underlying is delivered to the balancer (receiver == balancer)
///         so it folds into the main+alt at the next rebalanceUsingAlt(); this module never custodies the
///         swap proceeds. The balancer's compound() forwards the compound share of AERO here.
contract LPCompoundModule is AccessControlEnumerable {
    using SafeERC20 for IERC20;
    using GPv2Order for GPv2Order.Data;

    /// @notice CowSwap GPv2Settlement domain separator (Base) — mirrors ERC20MoonwellMorphoStrategy.
    bytes32 public constant DOMAIN_SEPARATOR = 0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b;
    /// @notice EIP-1271 magic value returned for a valid order.
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    /// @notice CowSwap vault relayer that pulls sell tokens on settlement.
    address public constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    /// @notice Upper bound on allowedSlippageInBps.
    uint256 public constant MAX_SLIPPAGE_IN_BPS = 2500;

    /// @notice The single LPAutoBalancerV2 this module serves. Underlying tokens are read from it live.
    address public immutable balancer;
    /// @notice The reward token compounded into the underlying (never token0/token1).
    address public immutable AERO;

    /// @notice Chainlink-backed price checker bounding AERO -> underlying min-out.
    ISlippagePriceChecker public slippagePriceChecker;
    /// @notice Allowed slippage for the compound swap, in bps (<= MAX_SLIPPAGE_IN_BPS).
    uint256 public allowedSlippageInBps;
    /// @notice Expected CowSwap appData hash for compound orders.
    bytes32 public compoundAppData;

    error ZeroAddress();
    error CheckerNotSet();

    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event SlippagePriceCheckerUpdated(address checker);
    event CompoundAppDataUpdated(bytes32 appData);

    /// @param balancer_ the LPAutoBalancerV2 this module serves (immutable)
    /// @param aero_ the reward token to compound
    /// @param admin_ the Safe managing slippage / appData / approval
    constructor(address balancer_, address aero_, address admin_) {
        if (balancer_ == address(0) || aero_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        balancer = balancer_;
        AERO = aero_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Set the price checker bounding the compound swap.
    function setSlippagePriceChecker(address checker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (checker == address(0)) revert ZeroAddress();
        slippagePriceChecker = ISlippagePriceChecker(checker);
        emit SlippagePriceCheckerUpdated(checker);
    }

    /// @notice Set the allowed compound-swap slippage (bps).
    function setSlippage(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newBps <= MAX_SLIPPAGE_IN_BPS, "slippage too high");
        emit SlippageUpdated(allowedSlippageInBps, newBps);
        allowedSlippageInBps = newBps;
    }

    /// @notice Set the expected CowSwap appData hash for compound orders.
    function setCompoundAppData(bytes32 appData) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compoundAppData = appData;
        emit CompoundAppDataUpdated(appData);
    }

    /// @notice Pre-approve the CowSwap relayer to pull this module's AERO.
    function approveCowSwap() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(slippagePriceChecker) == address(0)) revert CheckerNotSet();
        require(slippagePriceChecker.isRewardToken(AERO), "Token not allowed");
        IERC20(AERO).forceApprove(VAULT_RELAYER, type(uint256).max);
    }

    /// @notice EIP-1271 validation for CowSwap compound orders (AERO -> token0|token1, reward-only).
    /// @dev Reads token0/token1 live from the balancer so the check survives a setPool re-point.
    function isValidSignature(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4) {
        GPv2Order.Data memory o = abi.decode(encodedOrder, (GPv2Order.Data));
        require(o.hash(DOMAIN_SEPARATOR) == orderDigest, "bad digest");
        require(o.kind == GPv2Order.KIND_SELL, "must be sell");
        require(!o.partiallyFillable, "must be fill-or-kill");
        require(o.sellTokenBalance == GPv2Order.BALANCE_ERC20, "sell must be erc20");
        require(o.buyTokenBalance == GPv2Order.BALANCE_ERC20, "buy must be erc20");
        require(address(o.sellToken) == AERO, "sellToken must be AERO");
        address t0 = ILPAutoBalancerV2(balancer).token0();
        address t1 = ILPAutoBalancerV2(balancer).token1();
        require(address(o.buyToken) == t0 || address(o.buyToken) == t1, "buyToken must be underlying");
        require(o.receiver == balancer, "receiver must be balancer");
        require(o.feeAmount == 0, "fee must be zero");
        require(o.appData == compoundAppData, "bad appData");
        require(o.validTo >= block.timestamp + 5 minutes, "expires too soon");
        require(
            o.validTo <= block.timestamp + slippagePriceChecker.maxTimePriceValid(address(o.sellToken)),
            "expires too far"
        );
        require(
            slippagePriceChecker.checkPrice(
                o.sellAmount, address(o.sellToken), address(o.buyToken), o.buyAmount, allowedSlippageInBps
            ),
            "price check failed"
        );
        return MAGIC_VALUE;
    }

    /// @notice EIP-1271 validation for principal-rebalance orders. The balancer's
    ///         isValidSignature delegates here. Orders validate ONLY while the balancer
    ///         reports rebalanceInFlight, must swap between the two pool underlyings
    ///         (either direction), deliver to the balancer, and pass the price checker.
    function validateRebalanceOrder(bytes32 orderDigest, bytes calldata encodedOrder) external view returns (bytes4) {
        require(ILPAutoBalancerV2(balancer).rebalanceInFlight(), "no rebalance in flight");
        GPv2Order.Data memory o = abi.decode(encodedOrder, (GPv2Order.Data));
        require(o.hash(DOMAIN_SEPARATOR) == orderDigest, "bad digest");
        require(o.kind == GPv2Order.KIND_SELL, "must be sell");
        require(!o.partiallyFillable, "must be fill-or-kill");
        require(o.sellTokenBalance == GPv2Order.BALANCE_ERC20, "sell must be erc20");
        require(o.buyTokenBalance == GPv2Order.BALANCE_ERC20, "buy must be erc20");
        address t0 = ILPAutoBalancerV2(balancer).token0();
        address t1 = ILPAutoBalancerV2(balancer).token1();
        require(
            (address(o.sellToken) == t0 || address(o.sellToken) == t1)
                && (address(o.buyToken) == t0 || address(o.buyToken) == t1)
                && address(o.sellToken) != address(o.buyToken),
            "tokens must be distinct underlying"
        );
        require(o.receiver == balancer, "receiver must be balancer");
        require(o.feeAmount == 0, "fee must be zero");
        require(o.appData == compoundAppData, "bad appData");
        require(o.validTo >= block.timestamp + 5 minutes, "expires too soon");
        require(
            o.validTo <= block.timestamp + slippagePriceChecker.maxTimePriceValid(address(o.sellToken)),
            "expires too far"
        );
        require(
            slippagePriceChecker.checkPrice(
                o.sellAmount, address(o.sellToken), address(o.buyToken), o.buyAmount, allowedSlippageInBps
            ),
            "price check failed"
        );
        return MAGIC_VALUE;
    }
}
