// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@interfaces/IERC4626.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";

import {IERC173} from "@interfaces/IERC173.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title MamoVaultConfig
 * @notice Shared, multisig-owned configuration for a family of MorphoVaultsStrategy instances on a single asset
 * @dev Two responsibilities, both scoped to admin/multisig control rather than the backend:
 *      1. The venue allowlist: the set of ERC4626 vaults the backend is allowed to allocate user funds
 *         across. The backend rebalances freely WITHIN this set; only the owner (multisig, ideally behind
 *         a timelock) can add or remove venues.
 *      2. The supply cap: a limit on total user deposits across every strategy of this family, so exposure
 *         to a young chain's venues can be grown deliberately.
 *      Strategies self-report deposits/withdrawals; the config verifies the caller is a genuine registered
 *      Mamo strategy via the MamoStrategyRegistry before trusting the report.
 */
contract MamoVaultConfig is Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Upper bound on the number of allowlisted vaults, keeps strategy-side loops bounded
    uint256 public constant MAX_VAULTS = 10;

    /// @notice The underlying asset every allowlisted vault must use
    address public immutable asset;

    /// @notice Registry used to authenticate strategies reporting deposit/withdraw flows
    IMamoStrategyRegistry public immutable mamoStrategyRegistry;

    /// @notice Cap on total tracked user deposits across all strategies of this family (0 = uncapped)
    uint256 public supplyCap;

    /// @notice Sum of tracked user deposits across all strategies
    uint256 public totalDeposited;

    /// @notice Tracked user deposits per strategy, so withdrawals can never underflow the global total
    mapping(address => uint256) public trackedDeposits;

    EnumerableSet.AddressSet private _vaults;

    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    event SupplyCapUpdated(uint256 oldCap, uint256 newCap);
    event DepositRecorded(address indexed strategy, uint256 amount, uint256 totalDeposited);
    event WithdrawRecorded(address indexed strategy, uint256 amount, uint256 totalDeposited);

    /**
     * @param _asset The underlying asset of this strategy family
     * @param _mamoStrategyRegistry The MamoStrategyRegistry used to authenticate strategies
     * @param _owner The admin multisig (ideally behind a timelock)
     * @param _supplyCap Initial supply cap in asset terms (0 = uncapped)
     */
    constructor(address _asset, address _mamoStrategyRegistry, address _owner, uint256 _supplyCap) Ownable(_owner) {
        require(_asset != address(0), "Invalid asset address");
        require(_mamoStrategyRegistry != address(0), "Invalid registry address");

        asset = _asset;
        mamoStrategyRegistry = IMamoStrategyRegistry(_mamoStrategyRegistry);
        supplyCap = _supplyCap;
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Adds a vault to the allowlist
     * @dev Only callable by the owner. The vault must be an ERC4626 vault on this config's asset.
     * @param vault The vault to allow
     */
    function addVault(address vault) external onlyOwner {
        require(vault != address(0), "Invalid vault address");
        require(IERC4626(vault).asset() == asset, "Vault asset mismatch");
        require(_vaults.length() < MAX_VAULTS, "Max vaults reached");
        require(_vaults.add(vault), "Vault already allowed");

        emit VaultAdded(vault);
    }

    /**
     * @notice Removes a vault from the allowlist
     * @dev Removal blocks NEW allocations to the vault. Funds already in the vault stay withdrawable;
     *      the backend is expected to rotate strategies out of it via updatePosition.
     * @param vault The vault to remove
     */
    function removeVault(address vault) external onlyOwner {
        require(_vaults.remove(vault), "Vault not allowed");

        emit VaultRemoved(vault);
    }

    /**
     * @notice Sets the supply cap
     * @dev A cap below totalDeposited blocks new deposits without forcing exits
     * @param _supplyCap The new cap in asset terms (0 = uncapped)
     */
    function setSupplyCap(uint256 _supplyCap) external onlyOwner {
        emit SupplyCapUpdated(supplyCap, _supplyCap);
        supplyCap = _supplyCap;
    }

    // ==================== STRATEGY FUNCTIONS ====================

    /**
     * @notice Records a user deposit and enforces the supply cap
     * @dev Callable only by registered Mamo strategies
     * @param amount The deposited amount in asset terms
     */
    function recordDeposit(uint256 amount) external onlyStrategy {
        require(supplyCap == 0 || totalDeposited + amount <= supplyCap, "Supply cap exceeded");

        trackedDeposits[msg.sender] += amount;
        totalDeposited += amount;

        emit DepositRecorded(msg.sender, amount, totalDeposited);
    }

    /**
     * @notice Records a user withdrawal, freeing cap capacity
     * @dev Clamps down to the strategy's tracked amount so yield withdrawals can't underflow the
     *      global total or free more capacity than the strategy consumed
     * @param amount The withdrawn amount in asset terms
     */
    function recordWithdraw(uint256 amount) external onlyStrategy {
        uint256 tracked = trackedDeposits[msg.sender];
        uint256 clamped = amount > tracked ? tracked : amount;

        trackedDeposits[msg.sender] = tracked - clamped;
        totalDeposited -= clamped;

        emit WithdrawRecorded(msg.sender, clamped, totalDeposited);
    }

    /**
     * @notice Records a full exit, releasing the strategy's entire tracked principal
     * @dev ERC-4626 rounds down on both entry and exit, so once the share price moves off 1.0 a full
     *      round trip realizes slightly less than the tracked principal. Debiting the realized amount
     *      would strand the difference in totalDeposited forever — trackedDeposits has no other write
     *      path — and every later round trip would ratchet it further. A full exit therefore frees the
     *      whole tracked amount rather than the realized one.
     */
    function recordFullExit() external onlyStrategy {
        uint256 tracked = trackedDeposits[msg.sender];

        trackedDeposits[msg.sender] = 0;
        totalDeposited -= tracked;

        emit WithdrawRecorded(msg.sender, tracked, totalDeposited);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Checks whether a vault is on the allowlist
     */
    function isAllowedVault(address vault) external view returns (bool) {
        return _vaults.contains(vault);
    }

    /**
     * @notice Returns the full vault allowlist
     */
    function getVaults() external view returns (address[] memory) {
        return _vaults.values();
    }

    /**
     * @notice Remaining deposit capacity under the cap (max uint if uncapped)
     */
    function remainingCapacity() external view returns (uint256) {
        if (supplyCap == 0) return type(uint256).max;
        return supplyCap > totalDeposited ? supplyCap - totalDeposited : 0;
    }

    /**
     * @dev A caller is a genuine strategy iff the registry has it recorded for its current owner.
     *      Only the registry backend can create that record, so it can't be spoofed.
     */
    modifier onlyStrategy() {
        require(
            mamoStrategyRegistry.isUserStrategy(IERC173(msg.sender).owner(), msg.sender),
            "Caller is not a registered strategy"
        );
        _;
    }
}
