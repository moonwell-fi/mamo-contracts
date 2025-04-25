pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {xERC20} from "@contracts/token/xERC20.sol";
import {MintLimits} from "@contracts/token/MintLimits.sol";
import {ConfigurablePauseGuardian} from "@contracts/token/ConfigurablePauseGuardian.sol";
import {IERC7802, IERC165} from "@contracts/interfaces/IERC7802.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IXERC20} from "@contracts/interfaces/IXERC20.sol";

/// @title MAMO
/// @notice The MAMO token is xERC20 and SuperERC20 compatible
contract MAMO is
    xERC20,
    Ownable2StepUpgradeable,
    ConfigurablePauseGuardian,
    IERC7802
{
    using SafeCast for uint256;

    /// @notice maximum supply is 1 billion tokens 
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice maximum rate limit per second is 25k
    uint128 public constant MAX_RATE_LIMIT_PER_SECOND = 25_000 * 1e18;

    /// @notice minimum buffer cap
    uint112 public constant MIN_BUFFER_CAP = 1_000 * 1e18;

    /// @notice the maximum time the token can be paused for
    uint256 public constant MAX_PAUSE_DURATION = 30 days;

       /// @notice Address of the SuperchainTokenBridge predeploy.
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    /// @notice logic contract cannot be initialized
    constructor() {
        _disableInitializers();
    }

    /// @dev on token's native chain, the lockbox must have its bufferCap set to uint112 max
    /// @notice initialize the xWELL token
    /// @param tokenName The name of the token
    /// @param tokenSymbol The symbol of the token
    /// @param tokenOwner The owner of the token, Temporal Governor on Base, Timelock on Moonbeam
    /// @param newRateLimits The rate limits for the token
    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        address tokenOwner,
        MintLimits.RateLimitMidPointInfo[] memory newRateLimits,
        uint128 newPauseDuration,
        address newPauseGuardian
    ) external initializer {
        require(
            newPauseDuration <= MAX_PAUSE_DURATION,
            "xWELL: pause duration too long"
        );
        __ERC20_init(tokenName, tokenSymbol);
        // TODO maybe add permit here

        __Ownable_init(tokenOwner);
        _addLimits(newRateLimits);

        /// pausing
        __Pausable_init(); /// not really needed, but seems like good form
        _grantGuardian(newPauseGuardian); /// set the pause guardian
        _updatePauseDuration(newPauseDuration);

    }



    ///  ------------------------------------------------------------
    ///  ------------------------------------------------------------
    ///  ------------------- Overridden Pure Hooks ------------------
    ///  ------------------------------------------------------------
    ///  ------------------------------------------------------------

    /// @notice maximum supply is 5 billion tokens if all WELL holders migrate to xWELL
    function maxSupply() public pure override returns (uint256) {
        return MAX_SUPPLY;
    }

    /// @notice the maximum amount of time the token can be paused for
    function maxPauseDuration() public pure override returns (uint256) {
        return MAX_PAUSE_DURATION;
    }

    /// @notice the maximum rate limit per second
    function maxRateLimitPerSecond() public pure override returns (uint128) {
        return MAX_RATE_LIMIT_PER_SECOND;
    }

    function minBufferCap() public pure override returns (uint112) {
        return MIN_BUFFER_CAP;
    }



    /// -------------------------------------------------------------
    /// -------------------------------------------------------------
    /// ---------------------- Bridge Functions ---------------------
    /// -------------------------------------------------------------
    /// -------------------------------------------------------------

    /// @notice Mints tokens for a user
    /// @dev Can only be called by a minter
    /// @param user The address of the user who needs tokens minted
    /// @param amount The amount of tokens being minted
    function mint(address user, uint256 amount) public override whenNotPaused {
        super.mint(user, amount);
    }

    /// @notice Burns tokens for a user
    /// @dev Can only be called by a minter
    /// @param user The address of the user who needs tokens burned
    /// @param amount The amount of tokens being burned
    function burn(address user, uint256 amount) public override whenNotPaused {
        /// burn user's tokens
        super.burn(user, amount);
    }

    /// @notice Allows the SuperchainTokenBridge to mint tokens.
    /// @param _to     Address to mint tokens to.
    /// @param _amount Amount of tokens to mint.
    function crosschainMint(address _to, uint256 _amount) external whenNotPaused {
        require(msg.sender == SUPERCHAIN_TOKEN_BRIDGE, "Only SuperchainTokenBridge can call this function");

        _mint(_to, _amount);

        emit CrosschainMint(_to, _amount, msg.sender);
    }

    /// @notice Allows the SuperchainTokenBridge to burn tokens.
    /// @param _from   Address to burn tokens from.
    /// @param _amount Amount of tokens to burn.
    function crosschainBurn(address _from, uint256 _amount) external whenNotPaused {
        require(msg.sender == SUPERCHAIN_TOKEN_BRIDGE, "Only SuperchainTokenBridge can call this function");

        _burn(_from, _amount);

        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    /// -------------------------------------------------------------
    /// -------------------------------------------------------------
    /// ---------------------- Admin Functions ----------------------
    /// -------------------------------------------------------------
    /// -------------------------------------------------------------

    /// @dev can only be called if the bridge already has a buffer cap
    /// @notice conform to the xERC20 setLimits interface
    /// @param bridge the bridge we are setting the limits of
    /// @param newBufferCap the new buffer cap, uint112 max for unlimited
    function setBufferCap(
        address bridge,
        uint256 newBufferCap
    ) public onlyOwner {
        _setBufferCap(bridge, newBufferCap.toUint112());

        emit BridgeLimitsSet(bridge, newBufferCap);
    }

    /// @dev can only be called if the bridge already has a buffer cap
    /// @notice set rate limit per second for a bridge
    /// @param bridge the bridge we are setting the limits of
    /// @param newRateLimitPerSecond the new rate limit per second
    function setRateLimitPerSecond(
        address bridge,
        uint128 newRateLimitPerSecond
    ) external onlyOwner {
        _setRateLimitPerSecond(bridge, newRateLimitPerSecond);
    }

    /// @notice grant new pause guardian
    /// @dev can only be called when unpaused, otherwise the
    /// contract can be paused again
    /// @param newPauseGuardian the new pause guardian
    function grantPauseGuardian(
        address newPauseGuardian
    ) external onlyOwner whenNotPaused {
        _grantGuardian(newPauseGuardian);
    }

    /// @notice unpauses this contract, only callable by owner
    /// allows the owner to unpause the contract when the guardian has paused
    function ownerUnpause() external onlyOwner whenPaused {
        /// granting guardian to address 0 removes the current guardian and
        /// unpauses the contract by setting PauseStartTime to 0
        _grantGuardian(address(0));
    }

    /// @notice update the pause duration
    /// can be called while the contract is paused, extending the pause duration
    /// this should only happen during an emergency where more time is needed
    /// before an upgrade.
    /// @param newPauseDuration the new pause duration
    function setPauseDuration(uint128 newPauseDuration) external onlyOwner {
        require(
            newPauseDuration <= MAX_PAUSE_DURATION,
            "xWELL: pause duration too long"
        );
        _updatePauseDuration(newPauseDuration);
    }

    /// @notice add a new bridge to the currently active bridges
    /// @param newBridge the bridge to add
    function addBridge(
        RateLimitMidPointInfo memory newBridge
    ) external onlyOwner {
        _addLimit(newBridge);
    }

    /// @notice add new bridges to the currently active bridges
    /// @param newBridges the bridges to add
    function addBridges(
        RateLimitMidPointInfo[] memory newBridges
    ) external onlyOwner {
        _addLimits(newBridges);
    }

    /// @notice remove a bridge from the currently active bridges
    /// deleting its buffer stored, buffer cap, mid point and last
    /// buffer used time
    /// @param bridge the bridge to remove
    function removeBridge(address bridge) external onlyOwner {
        _removeLimit(bridge);
    }

    /// @notice remove a set of bridges from the currently active bridges
    /// deleting its buffer stored, buffer cap, mid point and last
    /// buffer used time
    /// @param bridges the bridges to remove
    function removeBridges(address[] memory bridges) external onlyOwner {
        _removeLimits(bridges);
    }

   /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) public view virtual returns (bool) {
        return _interfaceId == type(IERC7802).interfaceId || _interfaceId == type(IERC20).interfaceId
            || _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IXERC20).interfaceId;
    }
  
}
