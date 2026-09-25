// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {StockAccountStrategy} from "./StockAccountStrategy.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {IStockAccountStrategy} from "./interfaces/IStockAccountStrategy.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title StockAccountStrategyFactory
 * @notice Factory that deploys one StockAccountStrategy account per user at a deterministic address
 */
contract StockAccountStrategyFactory is AccessControl {
    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    IMamoStrategyRegistry public immutable mamoStrategyRegistry;
    address public immutable stockRegistry;
    address public immutable asset;
    address public immutable cowSettlement;
    address public immutable strategyImplementation;
    uint256 public immutable strategyTypeId;
    address public immutable feeRecipient;

    event StrategyCreated(address indexed user, address indexed strategy);

    error ZeroAddress();
    error StrategyTypeIdNotSet();
    error NotBackendOrUser();
    error StrategyAlreadyExists(address strategy);

    /**
     * @param admin Address to grant the DEFAULT_ADMIN_ROLE to
     * @param backend Address to grant the BACKEND_ROLE to
     * @param _mamoStrategyRegistry Address of the MamoStrategyRegistry contract
     * @param _stockRegistry Address of the StockAccountRegistry contract
     * @param _asset Address of the cash asset every account is denominated in
     * @param _cowSettlement Address of the CoW settlement contract
     * @param _strategyImplementation Address of the StockAccountStrategy implementation
     * @param _strategyTypeId The strategy type ID assigned by the MamoStrategyRegistry
     * @param _feeRecipient Address the management fee of every account is paid to
     */
    constructor(
        address admin,
        address backend,
        address _mamoStrategyRegistry,
        address _stockRegistry,
        address _asset,
        address _cowSettlement,
        address _strategyImplementation,
        uint256 _strategyTypeId,
        address _feeRecipient
    ) {
        if (admin == address(0)) revert ZeroAddress();
        if (backend == address(0)) revert ZeroAddress();
        if (_mamoStrategyRegistry == address(0)) revert ZeroAddress();
        if (_stockRegistry == address(0)) revert ZeroAddress();
        if (_asset == address(0)) revert ZeroAddress();
        if (_cowSettlement == address(0)) revert ZeroAddress();
        if (_strategyImplementation == address(0)) revert ZeroAddress();
        if (_strategyTypeId == 0) revert StrategyTypeIdNotSet();
        if (_feeRecipient == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);

        mamoStrategyRegistry = IMamoStrategyRegistry(_mamoStrategyRegistry);
        stockRegistry = _stockRegistry;
        asset = _asset;
        cowSettlement = _cowSettlement;
        strategyImplementation = _strategyImplementation;
        strategyTypeId = _strategyTypeId;
        feeRecipient = _feeRecipient;
    }

    /// @notice Returns the address at which the account of a given user is or would be deployed
    function computeStrategyAddress(address user) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(user));

        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(strategyImplementation, ""));

        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    /**
     * @notice Deploys and registers the account of a user, callable by the backend or the user
     * @param user The address that will own the account
     * @param entries The initial target basket
     * @param cashTargetBps The share of the account targeted to stay in the asset, in basis points
     * @return strategy The address of the newly created account
     */
    function createStrategyForUser(
        address user,
        IStockAccountStrategy.BasketEntry[] calldata entries,
        uint16 cashTargetBps
    ) external returns (address strategy) {
        if (user == address(0)) revert ZeroAddress();
        if (!hasRole(BACKEND_ROLE, msg.sender) && msg.sender != user) revert NotBackendOrUser();

        address predicted = computeStrategyAddress(user);
        if (predicted.code.length != 0) revert StrategyAlreadyExists(predicted);

        bytes32 salt = keccak256(abi.encodePacked(user));

        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(strategyImplementation, ""));

        strategy = Create2.deploy(0, salt, bytecode);

        StockAccountStrategy(payable(strategy)).initialize(
            StockAccountStrategy.InitParams({
                asset: asset,
                cashTargetBps: cashTargetBps,
                cowSettlement: cowSettlement,
                entries: entries,
                feeRecipient: feeRecipient,
                mamoStrategyRegistry: address(mamoStrategyRegistry),
                owner: user,
                stockRegistry: stockRegistry,
                strategyTypeId: strategyTypeId
            })
        );

        mamoStrategyRegistry.addStrategy(user, strategy);

        emit StrategyCreated(user, strategy);
    }
}
