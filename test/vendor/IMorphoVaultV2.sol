// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Errors raised by Morpho Vault V2's gates, mirrored from vault-v2 `src/libraries/ErrorsLib.sol`
///         so tests can assert on the exact selectors the real bytecode reverts with.
error CannotReceiveShares();

error CannotSendShares();

error CannotReceiveAssets();

error CannotSendAssets();

/**
 * @title IMorphoVaultV2
 * @notice Subset of Morpho's `IVaultV2` used by the Robinhood Chain tests
 * @dev Mirrors https://github.com/morpho-org/vault-v2 `src/interfaces/IVaultV2.sol` at commit
 *      b1e9005c5d7a1c99eaa909dde02a365886faac07. Only the members the tests actually touch are
 *      declared, to keep the surface reviewable.
 */
interface IMorphoVaultV2 {
    // --- ERC20 / ERC4626 ---
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address onBehalf) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256);

    // --- The V2 quirk: these are hardcoded to zero ---
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);

    // --- V2 specific state ---
    function virtualShares() external view returns (uint256);
    function owner() external view returns (address);
    function curator() external view returns (address);
    function isAllocator(address account) external view returns (bool);
    function receiveSharesGate() external view returns (address);
    function sendSharesGate() external view returns (address);
    function receiveAssetsGate() external view returns (address);
    function sendAssetsGate() external view returns (address);
    function maxRate() external view returns (uint64);
    function lastUpdate() external view returns (uint64);
    function _totalAssets() external view returns (uint128);
    function firstTotalAssets() external view returns (uint256);
    function performanceFee() external view returns (uint96);
    function canReceiveShares(address account) external view returns (bool);
    function canSendShares(address account) external view returns (bool);

    // --- Roles ---
    function setOwner(address newOwner) external;
    function setCurator(address newCurator) external;
    function setName(string memory newName) external;
    function setSymbol(string memory newSymbol) external;

    // --- Curator (timelocked; timelocks default to zero so submit + call is atomic) ---
    function submit(bytes memory data) external;
    function setIsAllocator(address account, bool newIsAllocator) external;
    function setReceiveSharesGate(address newReceiveSharesGate) external;
    function setSendSharesGate(address newSendSharesGate) external;
    function setPerformanceFee(uint256 newPerformanceFee) external;
    function setPerformanceFeeRecipient(address newPerformanceFeeRecipient) external;

    // --- Allocator ---
    function setMaxRate(uint256 newMaxRate) external;

    // --- Accounting ---
    function accrueInterest() external;
    function accrueInterestView()
        external
        view
        returns (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares);
}

/// @notice Subset of Morpho's reference `WhitelistReceiveSharesGate`
interface IMorphoWhitelistGate {
    function roleSetter() external view returns (address);
    function isWhitelister(address account) external view returns (bool);
    function isWhitelisted(address account) external view returns (bool);
    function canReceiveShares(address account) external view returns (bool);
    function setIsWhitelister(address account, bool newIsWhitelister) external;
    function setIsWhitelisted(address account, bool newIsWhitelisted) external;
}
