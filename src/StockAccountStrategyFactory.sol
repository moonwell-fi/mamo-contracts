// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "./ERC1967Proxy.sol";
import {StockAccountStrategy} from "./StockAccountStrategy.sol";
import {IBaseStrategy} from "./interfaces/IBaseStrategy.sol";
import {IMamoStrategyRegistry} from "./interfaces/IMamoStrategyRegistry.sol";
import {IStockAccountRegistry} from "./interfaces/IStockAccountRegistry.sol";
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
    uint256 public immutable strategyTypeId;

    event StrategyCreated(address indexed user, address indexed strategy);

    error ZeroAddress();
    error StrategyTypeIdNotSet();
    error NotBackendOrUser();
    error StrategyAlreadyExists(address strategy);
    error AssetMismatch();
    error ImplementationNotWhitelisted();

    /**
     * @param admin Address to grant the DEFAULT_ADMIN_ROLE to
     * @param backend Address to grant the BACKEND_ROLE to
     * @param _mamoStrategyRegistry Address of the MamoStrategyRegistry contract
     * @param _stockRegistry Address of the StockAccountRegistry contract
     * @param _asset Address of the cash asset every account is denominated in
     * @param _cowSettlement Address of the CoW settlement contract
     * @param _strategyTypeId The strategy type ID assigned by the MamoStrategyRegistry
     */
    constructor(
        address admin,
        address backend,
        address _mamoStrategyRegistry,
        address _stockRegistry,
        address _asset,
        address _cowSettlement,
        uint256 _strategyTypeId
    ) {
        if (admin == address(0)) revert ZeroAddress();
        if (backend == address(0)) revert ZeroAddress();
        if (_mamoStrategyRegistry == address(0)) revert ZeroAddress();
        if (_stockRegistry == address(0)) revert ZeroAddress();
        if (_asset == address(0)) revert ZeroAddress();
        if (_cowSettlement == address(0)) revert ZeroAddress();
        if (_strategyTypeId == 0) revert StrategyTypeIdNotSet();
        if (_asset != IStockAccountRegistry(_stockRegistry).asset()) revert AssetMismatch();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BACKEND_ROLE, backend);

        mamoStrategyRegistry = IMamoStrategyRegistry(_mamoStrategyRegistry);
        stockRegistry = _stockRegistry;
        asset = _asset;
        cowSettlement = _cowSettlement;
        strategyTypeId = _strategyTypeId;
    }

    /// @notice The implementation new accounts are deployed with: the registry's latest for this type id
    function strategyImplementation() public view returns (address) {
        return mamoStrategyRegistry.latestImplementationById(strategyTypeId);
    }

    /// @notice Returns the address at which the account of a given user is or would be deployed
    function computeStrategyAddress(address user) public view returns (address) {
        return Create2.computeAddress(_salt(user), keccak256(_proxyBytecode(strategyImplementation())));
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

        address implementation = strategyImplementation();
        if (implementation == address(0)) revert ImplementationNotWhitelisted();

        bytes32 salt = _salt(user);
        bytes memory bytecode = _proxyBytecode(implementation);

        address predicted = Create2.computeAddress(salt, keccak256(bytecode));
        if (predicted.code.length != 0) revert StrategyAlreadyExists(predicted);

        address[] memory existing = mamoStrategyRegistry.getUserStrategies(user);
        for (uint256 i = 0; i < existing.length; i++) {
            if (IBaseStrategy(existing[i]).strategyTypeId() == strategyTypeId) {
                revert StrategyAlreadyExists(existing[i]);
            }
        }

        strategy = Create2.deploy(0, salt, bytecode);

        StockAccountStrategy(payable(strategy)).initialize(
            StockAccountStrategy.InitParams({
                asset: asset,
                cashTargetBps: cashTargetBps,
                cowSettlement: cowSettlement,
                entries: entries,
                mamoStrategyRegistry: address(mamoStrategyRegistry),
                owner: user,
                stockRegistry: stockRegistry,
                strategyTypeId: strategyTypeId
            })
        );

        mamoStrategyRegistry.addStrategy(user, strategy);

        emit StrategyCreated(user, strategy);
    }

    function _salt(address user) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(user));
    }

    function _proxyBytecode(address implementation) private pure returns (bytes memory) {
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, ""));
    }
}
