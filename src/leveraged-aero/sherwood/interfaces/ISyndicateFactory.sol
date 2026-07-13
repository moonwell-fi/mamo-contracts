// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./ISyndicateGovernor.sol";

interface ISyndicateFactory {
    // ── Events (Task 26) ──
    event OwnerRotated(address indexed vault, address indexed newOwner);
    event WithdrawalQueueDeployed(address indexed vault, address indexed queue);

    // ── Errors (Task 26) ──
    error VaultStillStaked();

    // ── Errors (V-H3) ──
    error VaultImplMismatch();

    // ── Errors (V-M7) ──
    error InvalidSyndicateConfig();

    // ── Views ──
    function governorOf(address vault) external view returns (address);
    function beacon() external view returns (address);
    function protocolConfig() external view returns (address);
    function priceRouter() external view returns (address);
    function vaultImpl() external view returns (address);
    function vaultToSyndicate(address vault) external view returns (uint256);
    function guardianRegistry() external view returns (address);

    // ── Admin ──
    function rotateOwner(address vault, address newOwner) external;
    function setParamsOverride(address vault, ISyndicateGovernor.GovernorParams calldata params) external;
}
