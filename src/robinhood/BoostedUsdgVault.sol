// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@interfaces/IERC4626.sol";

import {
    IMorphoBlue,
    IMorphoOracle,
    Id,
    Market,
    MarketParams,
    MarketParamsLib,
    Position
} from "@contracts/robinhood/interfaces/IMorphoBlue.sol";
import {IUniswapV3SwapRouter} from "@contracts/robinhood/interfaces/IUniswapV3SwapRouter.sol";
import {MorphoBlueMath} from "@contracts/robinhood/libraries/MorphoBlueMath.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BoostedUsdgVault
 * @notice Boosted USDG: a POOLED, share-based vault that loops a yield-bearing collateral against a USDG
 *         borrow on Morpho Blue at a persisted target LTV. Wave 2 of Mamo on Robinhood Chain
 *         (`docs/ROBINHOOD_CHAIN_SPEC.md` §2 idea #3, `docs/ROBINHOOD_PLAN.md` §3 + §6).
 *
 * @notice IMPORTANT: this contract does not support fee-on-transfer tokens.
 *
 * @dev WHY POOLED, NOT PER-USER
 *      Every other Mamo strategy on this chain is per-user, which is a safety feature there (a stock-token
 *      issuer can freeze one user's contract, not the book). A levered book cannot be sliced that way: the
 *      loop only works if the collateral and the debt sit in ONE Morpho Blue position, so leverage is
 *      maintained once for everyone rather than N times. Depositors therefore hold pro-rata SHARES of a
 *      single position, priced at NAV/share.
 *
 * @dev WHAT IS DELIBERATELY SIMPLIFIED (this is a prototype proving mechanics, not audited code)
 *      1. WITHDRAWALS ARE SYNCHRONOUS. `redeem` unwinds the caller's pro-rata slice of the position inside
 *         the transaction and pays out. If the position cannot free that much in one transaction — the
 *         collateral venue is illiquid, or the position sits so close to the ceiling that each iteration can
 *         only peel off dust — the call reverts on `minAssetsOut` and the user must redeem in tranches. The
 *         audited Boosted USDC answer is the `LeveragedAeroVault` Pending/Executed/Settled ledger with
 *         permissionless `redeemSettled`; porting it is explicitly OUT OF MVP SCOPE and is the single largest
 *         piece of production work this contract defers.
 *      2. FEES ARE HWM-BY-DILUTION, NOT CRYSTALLIZED PER DEPOSITOR. `harvest()` charges the performance fee
 *         on NAV/share growth above a single vault-wide high-water mark by minting shares to `feeRecipient`.
 *         That is correct in aggregate and needs no asset movement, but a depositor who enters below the HWM
 *         is diluted for growth that happened before them. Production ports the audited `LeveragedAeroFees`
 *         crystallization library, which tracks an entry HWM per depositor.
 *      3. ONE ACTIVE MARKET AT A TIME. The admin allowlist is append-only and the vault runs exactly one
 *         Blue market; switching venues requires the position to be flat first. A multi-market book needs
 *         per-market accounting the MVP does not carry.
 *      4. THE ORACLE BOUND IS THE MARKET'S OWN ORACLE. Swap floors are derived from the same `price()` that
 *         decides liquidation, which is self-consistent but means an oracle compromise breaks both at once.
 *         Production crosses it against an independent Chainlink feed (`SlippagePriceChecker`) and adds the
 *         staleness policy from plan §5.
 *      5. NO FLASH-LOAN ONE-SHOT. Blue's `flashLoan` is in the interface but unused: with the ERC-4626
 *         collateral route the iterative loop has zero price impact and converges in a handful of steps, so a
 *         callback surface would add attack area for no gain at MVP sizes.
 *
 * @dev THE LESSONS THIS CARRIES OVER FROM THE AUDITED LEVERAGED-AERO WORK
 *      - TARGET PERSISTENCE. `targetLtvBps` is STATE, not an argument to the mover. `adjustLeverage()` takes
 *        no target: it moves the position toward the stored one and stops. A keeper that re-invokes it
 *        converges, and a step that runs out of iterations, liquidity or health headroom leaves the target
 *        untouched so the next call resumes instead of silently adopting whatever it managed to reach.
 *      - TWO-SIDED CONVERSION FLOOR. Every leg is bounded by `max(oracle floor at the backend's tolerance,
 *        oracle floor at the admin's ceiling)`: the backend picks the tolerance and may only TIGHTEN it, and
 *        `maxSlippageBps` is a hard admin ceiling it cannot loosen. (The audited compound path expresses this
 *        as `max(backendMinOut, oracleFloor)` on an absolute amount; that form does not compose with an
 *        N-iteration loop whose per-leg sizes are only known mid-transaction, so the same guarantee is
 *        expressed in bps here.)
 *      - ADMIN-SCOPED VENUES. The backend chooses WHEN and HOW FAR to lever, never WHERE: markets are
 *        allowlisted by the owner multisig, append-only.
 *      - DEPOSIT CAP. Exposure to a young chain's credit venue is grown deliberately, not by whoever arrives.
 *      - PAUSE IS ONE-DIRECTIONAL. The guardian can stop money coming in and leverage going up; it can never
 *        stop a user getting out or a keeper unwinding.
 *
 * @dev THE COLLATERAL ROUTE, AND WHY IT IS NOT ONLY A DEX SWAP
 *      A loop needs to turn borrowed USDG into more collateral. The obvious route is a Uniswap swap, and it
 *      is supported. But on Robinhood Chain the three USDG-loan markets with real borrow liquidity are
 *      collateralized by USDe, syrupUSDG and spUSDG, and NONE of them has a usable USDG DEX pool: syrup and
 *      spUSDG have no pool at any fee tier, and the USDe pools hold dust. What spUSDG (Spark Savings USDG)
 *      does have is an on-chain PRIMARY market — it is itself an ERC-4626 vault over USDG — and its Blue
 *      oracle reads that very exchange rate, so minting collateral through it is exact rather than merely
 *      cheap. The route is therefore a per-market admin choice: `ERC4626` mints/redeems at the venue,
 *      `DEX` swaps through SwapRouter02. Both are bounded by the same oracle floor.
 */
contract BoostedUsdgVault is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    /// @notice How the vault converts between the loan asset and the collateral asset
    enum CollateralRoute {
        /// @dev Unset — an unlisted market
        NONE,
        /// @dev The collateral token is itself an ERC-4626 vault over the loan asset: mint and redeem at par
        ERC4626,
        /// @dev Swap through a Uniswap V3 style router at a fixed fee tier
        DEX
    }

    /// @notice A market the owner has approved the vault to operate in
    struct MarketConfig {
        MarketParams params;
        CollateralRoute route;
        /// @dev Uniswap fee tier, DEX route only
        uint24 poolFee;
        bool listed;
    }

    // ==================== CONSTANTS ====================

    /// @notice Basis-point denominator
    uint256 public constant BPS = 10000;

    uint256 internal constant WAD = 1e18;

    /// @notice Hard cap on the performance fee (20%)
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2000;

    /// @notice Hard cap on the admin's conversion-slippage ceiling (25%)
    uint256 public constant MAX_SLIPPAGE_CEILING_BPS = 2500;

    /// @notice Minimum gap the vault's own LTV ceiling must keep below the market's liquidation LTV
    /// @dev A vault allowed to sit at LLTV is a vault that liquidates on the first tick of borrow interest.
    uint256 public constant MIN_LLTV_BUFFER_BPS = 500;

    /// @notice Extra margin kept below LLTV while unwinding a position that is already above `maxLtvBps`
    uint256 public constant UNWIND_SAFETY_BPS = 100;

    /// @notice Upper bound on loop iterations per call, so no operation can be gas-griefed unbounded
    uint256 public constant MAX_LOOP_ITERATIONS = 8;

    /// @notice The loop stops once it is within 0.1% of the target — chasing the last basis point costs more
    ///         gas than it earns
    uint256 internal constant CONVERGENCE_DIVISOR = 1000;

    // ==================== IMMUTABLES ====================

    /// @notice The loan asset users deposit and are paid in (USDG on Robinhood Chain)
    IERC20 public immutable asset;

    /// @notice The Morpho Blue singleton
    IMorphoBlue public immutable morpho;

    /// @dev Share/asset decimal offset, mirroring Morpho Vault V2's `virtualShares`: a 6-decimal asset mints
    ///      18-decimal shares. Also the inflation-attack guard on an empty vault.
    uint256 internal immutable virtualShares;

    // ==================== STORAGE ====================

    /// @notice Append-only list of allowlisted market ids
    Id[] public listedMarkets;

    /// @notice Config per market id
    mapping(Id => MarketConfig) internal marketConfigs;

    /// @notice The single market the vault currently runs
    Id public activeMarketId;

    /// @notice Uniswap V3 style router used by DEX-route markets
    IUniswapV3SwapRouter public dexRouter;

    /// @notice Backend keeper allowed to move leverage
    address public backend;

    /// @notice Guardian allowed to pause (multisig without timelock)
    address public guardian;

    /// @notice Performance fee recipient
    address public feeRecipient;

    /// @notice Cap on `totalAssets()` at deposit time (0 = uncapped)
    uint256 public supplyCap;

    /// @notice The vault's own LTV ceiling, always at least `MIN_LLTV_BUFFER_BPS` below the market's LLTV
    uint256 public maxLtvBps;

    /// @notice The persisted leverage target the backend converges toward
    uint256 public targetLtvBps;

    /// @notice Admin ceiling on conversion slippage; the backend may only ask for something tighter
    uint256 public maxSlippageBps;

    /// @notice Performance fee in basis points of NAV growth above the high-water mark
    uint256 public performanceFeeBps;

    /// @notice Assets per 1e18 shares at the last fee crystallization
    uint256 public highWaterMark;

    /// @notice When true, deposits and levering up are blocked; withdrawals and delevering are not
    bool public paused;

    // ==================== EVENTS ====================

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Redeem(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event MarketListed(Id indexed id, address indexed collateralToken, CollateralRoute route, uint256 lltv);
    event ActiveMarketUpdated(Id indexed oldId, Id indexed newId);
    event TargetLtvUpdated(uint256 oldTargetBps, uint256 newTargetBps);
    event LeverageAdjusted(uint256 ltvBeforeBps, uint256 ltvAfterBps, uint256 targetBps);
    event Deleveraged(uint256 ltvBeforeBps, uint256 collateralRemaining, uint256 debtRemaining);
    event Harvested(uint256 sharePrice, uint256 highWaterMark, uint256 feeShares);
    event CollateralAcquired(uint256 assetsIn, uint256 collateralOut);
    event CollateralLiquidated(uint256 collateralIn, uint256 assetsOut);
    event SupplyCapUpdated(uint256 oldCap, uint256 newCap);
    event MaxLtvUpdated(uint256 oldMaxLtvBps, uint256 newMaxLtvBps);
    event MaxSlippageUpdated(uint256 oldSlippageBps, uint256 newSlippageBps);
    event PerformanceFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event BackendUpdated(address indexed oldBackend, address indexed newBackend);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event PausedSet(bool paused);

    // ==================== MODIFIERS ====================

    modifier onlyBackend() {
        require(msg.sender == backend, "Not backend");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Vault is paused");
        _;
    }

    modifier hasActiveMarket() {
        require(Id.unwrap(activeMarketId) != bytes32(0), "No active market");
        _;
    }

    /**
     * @param _asset The loan asset (USDG)
     * @param _morpho The Morpho Blue singleton
     * @param _owner The admin multisig (ideally behind a timelock)
     * @param _name ERC20 name of the share token
     * @param _symbol ERC20 symbol of the share token
     */
    constructor(address _asset, address _morpho, address _owner, string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
        Ownable(_owner)
    {
        require(_asset != address(0), "Invalid asset address");
        require(_morpho != address(0), "Invalid morpho address");

        uint8 assetDecimals = IERC20Metadata(_asset).decimals();
        require(assetDecimals <= 18, "Asset decimals above 18");

        asset = IERC20(_asset);
        morpho = IMorphoBlue(_morpho);
        virtualShares = 10 ** (18 - assetDecimals);
    }

    /// @notice Shares are always 18 decimals regardless of the asset's, mirroring Morpho Vault V2
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // ==================== OWNER FUNCTIONS ====================

    /**
     * @notice Allowlists a Morpho Blue market and the route used to convert into its collateral
     * @dev Append-only by design: a listing is a governance decision that survives the backend. Removing a
     *      venue is not a listing operation — the owner switches `activeMarketId` away from it, which is only
     *      possible once the position is flat.
     * @param params The market's full params; the vault derives the id itself
     * @param route How to convert the loan asset into this market's collateral
     * @param poolFee Uniswap fee tier for a DEX route (ignored otherwise)
     */
    function addMarket(MarketParams calldata params, CollateralRoute route, uint24 poolFee) external onlyOwner {
        require(params.loanToken == address(asset), "Loan token mismatch");
        require(params.collateralToken != address(0), "Invalid collateral token");
        require(params.oracle != address(0), "Invalid oracle");
        require(params.irm != address(0), "Invalid irm");
        require(params.lltv > 0 && params.lltv < WAD, "Invalid lltv");
        require(route != CollateralRoute.NONE, "Invalid collateral route");

        Id id = params.id();
        require(!marketConfigs[id].listed, "Market already listed");
        require(morpho.market(id).lastUpdate != 0, "Market does not exist on Morpho");
        require(IMorphoOracle(params.oracle).price() > 0, "Oracle price unavailable");

        if (route == CollateralRoute.ERC4626) {
            require(IERC4626(params.collateralToken).asset() == address(asset), "Collateral vault asset mismatch");
        } else {
            require(poolFee != 0, "Pool fee not set");
        }

        marketConfigs[id] = MarketConfig({params: params, route: route, poolFee: poolFee, listed: true});
        listedMarkets.push(id);

        emit MarketListed(id, params.collateralToken, route, params.lltv);
    }

    /**
     * @notice Points the vault at one of the allowlisted markets
     * @dev Requires the current position to be flat. Moving a levered book between markets in one transaction
     *      would need an atomic migration path the MVP does not have, and silently stranding collateral in
     *      the old market is worse than refusing.
     */
    function setActiveMarket(Id id) external onlyOwner {
        require(marketConfigs[id].listed, "Market not listed");

        Id oldId = activeMarketId;
        if (Id.unwrap(oldId) != bytes32(0)) {
            Position memory p = morpho.position(oldId, address(this));
            require(p.collateral == 0 && p.borrowShares == 0, "Position not flat");
        }

        require(maxLtvBps + MIN_LLTV_BUFFER_BPS <= _lltvBps(marketConfigs[id].params), "Max LTV too close to LLTV");

        activeMarketId = id;
        targetLtvBps = 0;

        emit ActiveMarketUpdated(oldId, id);
    }

    /// @notice Sets the cap on `totalAssets()` enforced at deposit time (0 = uncapped)
    /// @dev A cap below current assets blocks new deposits without forcing anyone out.
    function setSupplyCap(uint256 newCap) external onlyOwner {
        emit SupplyCapUpdated(supplyCap, newCap);
        supplyCap = newCap;
    }

    /**
     * @notice Sets the vault's LTV ceiling
     * @dev The ceiling must clear the active market's LLTV by `MIN_LLTV_BUFFER_BPS`. Lowering it below the
     *      current LTV is allowed and is the intended de-risking lever: it does not revert the position, it
     *      makes the next `adjustLeverage()` unwind toward the new ceiling.
     */
    function setMaxLtv(uint256 newMaxLtvBps) external onlyOwner {
        if (Id.unwrap(activeMarketId) != bytes32(0)) {
            require(
                newMaxLtvBps + MIN_LLTV_BUFFER_BPS <= _lltvBps(marketConfigs[activeMarketId].params),
                "Max LTV too close to LLTV"
            );
        }
        require(newMaxLtvBps < BPS, "Max LTV too high");

        emit MaxLtvUpdated(maxLtvBps, newMaxLtvBps);
        maxLtvBps = newMaxLtvBps;

        if (targetLtvBps > newMaxLtvBps) {
            emit TargetLtvUpdated(targetLtvBps, newMaxLtvBps);
            targetLtvBps = newMaxLtvBps;
        }
    }

    /// @notice Sets the hard ceiling on conversion slippage the backend can never loosen
    function setMaxSlippage(uint256 newSlippageBps) external onlyOwner {
        require(newSlippageBps <= MAX_SLIPPAGE_CEILING_BPS, "Slippage exceeds maximum");

        emit MaxSlippageUpdated(maxSlippageBps, newSlippageBps);
        maxSlippageBps = newSlippageBps;
    }

    /// @notice Sets the performance fee charged on NAV/share growth above the high-water mark
    function setPerformanceFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_PERFORMANCE_FEE_BPS, "Performance fee exceeds maximum");

        emit PerformanceFeeUpdated(performanceFeeBps, newFeeBps);
        performanceFeeBps = newFeeBps;
    }

    /// @notice Sets the performance fee recipient (the flywheel hook: point this at the FeeSplitter)
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid fee recipient address");

        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Sets the backend keeper allowed to move leverage
    function setBackend(address newBackend) external onlyOwner {
        require(newBackend != address(0), "Invalid backend address");

        emit BackendUpdated(backend, newBackend);
        backend = newBackend;
    }

    /// @notice Sets the pause guardian
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Sets the Uniswap V3 style router used by DEX-route markets
    function setDexRouter(address newRouter) external onlyOwner {
        emit DexRouterUpdated(address(dexRouter), newRouter);
        dexRouter = IUniswapV3SwapRouter(newRouter);
    }

    /// @notice Lifts a pause. Only the owner can, so a compromised guardian cannot re-open the vault.
    function unpause() external onlyOwner {
        paused = false;
        emit PausedSet(false);
    }

    // ==================== GUARDIAN FUNCTIONS ====================

    /**
     * @notice Blocks deposits and levering up
     * @dev Never blocks `redeem`, `deleverage` or `harvest`: a pause that traps users is a worse failure than
     *      whatever prompted it.
     */
    function pause() external {
        require(msg.sender == guardian || msg.sender == owner(), "Not guardian");

        paused = true;
        emit PausedSet(true);
    }

    // ==================== BACKEND FUNCTIONS ====================

    /**
     * @notice Sets the persisted leverage target without moving the position
     * @dev Separated from the mover on purpose. The target is a policy decision that outlives any single
     *      keeper transaction; `adjustLeverage()` is the execution that chases it.
     */
    function setTargetLtv(uint256 newTargetLtvBps) external onlyBackend {
        require(newTargetLtvBps <= maxLtvBps, "Target LTV above maximum");

        emit TargetLtvUpdated(targetLtvBps, newTargetLtvBps);
        targetLtvBps = newTargetLtvBps;
    }

    /**
     * @notice Sets a target, deploys any idle assets into collateral, and levers toward the target
     * @dev The entry point for a fresh position or after a large deposit. Equivalent to `setTargetLtv`
     *      followed by `adjustLeverage`, in one keeper transaction.
     * @param newTargetLtvBps The target LTV to persist
     * @param maxIterations Loop bound, capped at `MAX_LOOP_ITERATIONS`
     * @param backendSlippageBps The backend's conversion tolerance; must be inside `maxSlippageBps`
     */
    function openLeverage(uint256 newTargetLtvBps, uint256 maxIterations, uint256 backendSlippageBps)
        external
        onlyBackend
        nonReentrant
        whenNotPaused
        hasActiveMarket
    {
        require(newTargetLtvBps > 0, "Target LTV not set");
        require(newTargetLtvBps <= maxLtvBps, "Target LTV above maximum");

        emit TargetLtvUpdated(targetLtvBps, newTargetLtvBps);
        targetLtvBps = newTargetLtvBps;

        _adjust(maxIterations, backendSlippageBps);
    }

    /**
     * @notice Moves the position one step toward the PERSISTED target, in whichever direction is needed
     * @dev Takes no target: that is the point. A step that runs out of iterations, market liquidity or health
     *      headroom converges partially and leaves `targetLtvBps` alone, so re-invoking picks up where it
     *      stopped. This is the `adjustLeverage` target-persistence lesson from the audited Boosted USDC
     *      work — an operation that adopted whatever LTV it happened to reach would silently redefine the
     *      product's risk every time a keeper hit a gas or liquidity edge.
     */
    function adjustLeverage(uint256 maxIterations, uint256 backendSlippageBps)
        external
        onlyBackend
        nonReentrant
        whenNotPaused
        hasActiveMarket
    {
        _adjust(maxIterations, backendSlippageBps);
    }

    /**
     * @notice Unwinds the whole position back to idle loan assets and zeroes the target
     * @dev Deliberately callable while paused: risk-off must never depend on the vault being open.
     */
    function deleverage(uint256 maxIterations, uint256 backendSlippageBps)
        external
        onlyBackend
        nonReentrant
        hasActiveMarket
    {
        uint256 ltvBefore = ltvBps();

        if (targetLtvBps != 0) {
            emit TargetLtvUpdated(targetLtvBps, 0);
            targetLtvBps = 0;
        }

        _adjust(maxIterations, backendSlippageBps);

        MarketParams memory params = marketConfigs[activeMarketId].params;

        emit Deleveraged(ltvBefore, morpho.position(activeMarketId, address(this)).collateral, _debt(params));
    }

    /**
     * @notice Crystallizes the performance fee on NAV/share growth above the high-water mark
     * @dev Fee is paid by MINTING shares to `feeRecipient` (dilution), so no assets leave the position and
     *      the loop never has to be unwound to pay it. The HWM is then reset to the POST-dilution share
     *      price, which is the net high-water mark: a second harvest with no growth in between charges
     *      nothing.
     *
     *      Restricted to the backend on purpose. A permissionless harvest lets anyone ratchet the HWM up at a
     *      transient NAV peak — repeatedly crystallizing on oracle noise would tax depositors for volatility
     *      rather than for performance.
     */
    function harvest() external onlyBackend nonReentrant returns (uint256 feeShares) {
        _accrue();

        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 total = totalAssets();
        uint256 currentSharePrice = _convertToAssets(WAD, total, supply);

        if (currentSharePrice > highWaterMark && performanceFeeBps > 0 && feeRecipient != address(0)) {
            uint256 gain = ((currentSharePrice - highWaterMark) * supply) / WAD;
            uint256 fee = (gain * performanceFeeBps) / BPS;

            if (fee > 0 && total > fee) {
                feeShares = (fee * supply) / (total - fee);
                if (feeShares > 0) _mint(feeRecipient, feeShares);
            }
        }

        if (currentSharePrice > highWaterMark) {
            highWaterMark = _convertToAssets(WAD, total, totalSupply());
        }

        emit Harvested(currentSharePrice, highWaterMark, feeShares);
    }

    // ==================== USER FUNCTIONS ====================

    /**
     * @notice Deposits loan assets and mints shares priced at the current NAV/share
     * @dev Deposits land IDLE. Deploying them into the loop is a separate keeper operation, which keeps the
     *      deposit path cheap, keeps it working when the collateral venue is momentarily unusable, and stops
     *      a depositor from paying another depositor's conversion cost.
     */
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(assets > 0, "Amount must be greater than 0");
        require(receiver != address(0), "Invalid receiver");

        _accrue();

        uint256 supplyBefore = totalSupply();
        uint256 total = totalAssets();

        require(supplyCap == 0 || total + assets <= supplyCap, "Supply cap exceeded");

        shares = _convertToShares(assets, total, supplyBefore);
        require(shares > 0, "Zero shares");

        // an emptied vault re-seeds its high-water mark on the next deposit rather than carrying a stale one
        if (supplyBefore == 0) highWaterMark = 0;

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        if (highWaterMark == 0) highWaterMark = _convertToAssets(WAD, totalAssets(), totalSupply());

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Burns shares and pays out the caller's pro-rata slice of NAV
     * @dev Unwinds a PRO-RATA slice of the Blue position — `shares/totalSupply` of both the collateral and
     *      the debt — so the LTV the remaining holders are left with is the LTV they had before. The payout
     *      is what that unwind actually realizes plus the caller's share of idle assets, which means the
     *      conversion cost of an exit is borne by the person exiting rather than by the people who stayed.
     *
     *      `minAssetsOut` is the caller's protection: a redemption the position cannot unwind in one
     *      transaction realizes less than NAV and must revert rather than silently short the caller. See the
     *      contract NatSpec for why the async settlement ledger is out of MVP scope.
     */
    function redeem(uint256 shares, address receiver, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 assets)
    {
        require(shares > 0, "Amount must be greater than 0");
        require(receiver != address(0), "Invalid receiver");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");

        _accrue();

        uint256 supplyBefore = totalSupply();
        uint256 idleBefore = asset.balanceOf(address(this));
        uint256 ltvBefore = ltvBps();

        // the caller's share of the cash that is already sitting here
        assets = (idleBefore * shares) / supplyBefore;

        // plus whatever unwinding their slice of the position realizes
        assets += _unwindProRata(shares, supplyBefore);

        require(assets >= minAssetsOut, "Insufficient assets out");
        require(assets > 0, "Nothing to redeem");

        _burn(msg.sender, shares);
        asset.safeTransfer(receiver, assets);

        _requireHealthy(ltvBefore);

        emit Redeem(msg.sender, receiver, assets, shares);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Net asset value: idle loan assets + collateral valued at the market oracle - accrued debt
     * @dev The debt leg is accrual-aware (`MorphoBlueMath.expectedBorrowAssets`), so NAV is the same whether
     *      or not anyone has poked the market since the last block that touched it.
     */
    function totalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this));

        if (Id.unwrap(activeMarketId) == bytes32(0)) return total;

        MarketParams memory params = marketConfigs[activeMarketId].params;

        total += _collateralValue(params);

        uint256 debt = _debt(params);
        return total > debt ? total - debt : 0;
    }

    /// @notice Idle (undeployed) loan assets held by the vault
    function idleAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Collateral held in the active Blue market, in collateral-token units
    function collateralBalance() public view returns (uint256) {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return 0;
        return morpho.position(activeMarketId, address(this)).collateral;
    }

    /// @notice The oracle value of the vault's collateral, in loan-asset units
    function collateralValue() public view returns (uint256) {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return 0;
        return _collateralValue(marketConfigs[activeMarketId].params);
    }

    /// @notice The vault's accrued USDG debt in the active market
    function debtAssets() public view returns (uint256) {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return 0;
        return _debt(marketConfigs[activeMarketId].params);
    }

    /// @notice Current loan-to-value in basis points (0 with no debt, max uint with debt and no collateral)
    function ltvBps() public view returns (uint256) {
        uint256 debt = debtAssets();
        if (debt == 0) return 0;

        uint256 value = collateralValue();
        if (value == 0) return type(uint256).max;

        return (debt * BPS) / value;
    }

    /**
     * @notice Blue's own health measure, WAD-scaled: `collateral * price * lltv / debt`
     * @dev Below 1e18 the position is liquidatable. Max uint means no debt.
     */
    function healthFactor() public view returns (uint256) {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return type(uint256).max;

        MarketParams memory params = marketConfigs[activeMarketId].params;
        uint256 debt = _debt(params);
        if (debt == 0) return type(uint256).max;

        return (MorphoBlueMath.wMulDown(_collateralValue(params), params.lltv) * WAD) / debt;
    }

    /// @notice The active market's liquidation LTV in basis points
    function lltvBps() public view returns (uint256) {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return 0;
        return _lltvBps(marketConfigs[activeMarketId].params);
    }

    /// @notice Remaining deposit capacity under the supply cap (max uint if uncapped)
    function remainingCapacity() external view returns (uint256) {
        if (supplyCap == 0) return type(uint256).max;
        uint256 total = totalAssets();
        return supplyCap > total ? supplyCap - total : 0;
    }

    /// @notice Free borrow liquidity in the active market, in loan-asset units
    function marketLiquidity() public view returns (uint256) {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return 0;

        Market memory m = morpho.market(activeMarketId);
        return m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0;
    }

    /// @notice Shares that would be minted for `assets` right now
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets, totalAssets(), totalSupply());
    }

    /// @notice Assets `shares` are worth right now, ignoring unwind cost
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, totalAssets(), totalSupply());
    }

    /// @notice Assets per 1e18 shares — the number the high-water mark tracks
    function sharePrice() external view returns (uint256) {
        return _convertToAssets(WAD, totalAssets(), totalSupply());
    }

    /// @notice The config of an allowlisted market
    function getMarketConfig(Id id) external view returns (MarketConfig memory) {
        return marketConfigs[id];
    }

    /// @notice The params of the active market
    function activeMarketParams() external view returns (MarketParams memory) {
        return marketConfigs[activeMarketId].params;
    }

    /// @notice Number of allowlisted markets
    function listedMarketsLength() external view returns (uint256) {
        return listedMarkets.length;
    }

    // ==================== INTERNAL: LEVERAGE ENGINE ====================

    /// @dev Moves the position toward `targetLtvBps`, up or down, and asserts the result is acceptable
    function _adjust(uint256 maxIterations, uint256 backendSlippageBps) internal {
        _accrue();

        uint256 ltvBefore = ltvBps();
        uint256 iterations = _iterations(maxIterations);
        uint256 slippage = _validateSlippage(backendSlippageBps);

        MarketParams memory params = marketConfigs[activeMarketId].params;
        uint256 target = targetLtvBps;

        if (target == 0) {
            // a zero target is a full unwind, not a ratio to converge on
            _reducePosition(
                params, morpho.position(activeMarketId, address(this)).collateral, _debt(params), iterations, slippage
            );
        } else {
            // idle assets belong in the position before any LTV comparison is meaningful
            uint256 idle = asset.balanceOf(address(this));
            if (idle > 0) _supplyCollateral(params, _acquireCollateral(params, idle, slippage));

            uint256 value = _collateralValue(params);
            uint256 debt = _debt(params);
            uint256 currentLtv = value == 0 ? 0 : (debt * BPS) / value;

            if (currentLtv < target) {
                _leverToTarget(params, target, iterations, slippage);
            } else if (currentLtv > target) {
                // shrink both legs by the same amount so the ratio lands on the target:
                // (debt - r) / (value - r) == target  =>  r = (debt * BPS - target * value) / (BPS - target)
                uint256 reduceBy = ((debt * BPS) - (target * value)) / (BPS - target);
                _reducePosition(params, _toCollateral(params, reduceBy), reduceBy, iterations, slippage);
            }
        }

        _requireHealthy(ltvBefore);

        emit LeverageAdjusted(ltvBefore, ltvBps(), target);
    }

    /**
     * @dev The lever-up loop: borrow → convert → supply, repeated until the target is met.
     *
     *      Each iteration borrows the smaller of (what is still missing to reach the target) and (what the
     *      vault's own LTV ceiling allows against the collateral it holds RIGHT NOW). The second bound is
     *      what makes the loop iterative at all: the borrowed assets only become collateral after they are
     *      converted, so a single borrow can never reach a target above the ceiling in one step. Convergence
     *      is geometric, which is why a bound of `MAX_LOOP_ITERATIONS` is enough in practice.
     */
    function _leverToTarget(MarketParams memory params, uint256 target, uint256 iterations, uint256 slippage) internal {
        for (uint256 i = 0; i < iterations; i++) {
            uint256 value = _collateralValue(params);
            uint256 debt = _debt(params);
            if (value <= debt) break;

            uint256 equity = value - debt;
            // final state: value = equity / (1 - t), debt = value * t
            uint256 targetDebt = (equity * target) / (BPS - target);
            if (debt >= targetDebt) break;

            uint256 want = targetDebt - debt;
            if (want <= targetDebt / CONVERGENCE_DIVISOR) break;

            uint256 ceiling = (value * maxLtvBps) / BPS;
            uint256 headroom = ceiling > debt ? ceiling - debt : 0;
            if (want > headroom) want = headroom;

            uint256 liquidity = marketLiquidity();
            if (want > liquidity) want = liquidity;
            if (want == 0) break;

            morpho.borrow(params, want, 0, address(this), address(this));
            _supplyCollateral(params, _acquireCollateral(params, want, slippage));
        }
    }

    /**
     * @dev The unwind loop: withdraw collateral → convert → repay, repeated until the requested slice is off
     *      the book. Repayment is greedy, so every iteration lowers the LTV before the next withdrawal,
     *      which widens the health headroom and makes the loop converge.
     *
     *      Surplus loan assets (whatever is left after `debtToRepay` is satisfied) stay idle in the vault —
     *      that surplus IS the equity being released, and `redeem` measures it directly rather than trusting
     *      an oracle estimate of what the unwind should have produced.
     * @param collateralToRemove Collateral-token units to take off the book
     * @param debtToRepay Loan-asset units of debt to retire
     */
    function _reducePosition(
        MarketParams memory params,
        uint256 collateralToRemove,
        uint256 debtToRepay,
        uint256 iterations,
        uint256 slippage
    ) internal {
        if (collateralToRemove == 0) return;

        uint256 removed;
        uint256 repaid;

        for (uint256 i = 0; i < iterations && removed < collateralToRemove; i++) {
            uint256 safe = _maxWithdrawableCollateral(params);
            if (safe == 0) break;

            uint256 step = collateralToRemove - removed;
            if (step > safe) step = safe;

            morpho.withdrawCollateral(params, step, address(this), address(this));
            removed += step;

            uint256 realized = _liquidateCollateral(params, step, slippage);

            if (repaid < debtToRepay) {
                uint256 repayAmount = debtToRepay - repaid;
                if (repayAmount > realized) repayAmount = realized;
                repaid += _repay(params, repayAmount);
            }
        }
    }

    /// @dev Unwinds `shares/supply` of both legs and returns the loan assets the unwind newly realized
    function _unwindProRata(uint256 shares, uint256 supply) internal returns (uint256) {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return 0;

        MarketParams memory params = marketConfigs[activeMarketId].params;
        uint256 collateral = morpho.position(activeMarketId, address(this)).collateral;
        if (collateral == 0) return 0;

        uint256 idleBefore = asset.balanceOf(address(this));

        _reducePosition(
            params,
            (collateral * shares) / supply,
            (_debt(params) * shares) / supply,
            MAX_LOOP_ITERATIONS,
            maxSlippageBps
        );

        uint256 idleAfter = asset.balanceOf(address(this));
        return idleAfter > idleBefore ? idleAfter - idleBefore : 0;
    }

    /**
     * @dev Collateral the vault may peel off in a single iteration, bounded by `LLTV - UNWIND_SAFETY_BPS`.
     *
     *      Without a flash loan, unwinding is necessarily peel-then-repay: the only source of loan assets to
     *      repay with is the collateral itself, so collateral has to come off the book BEFORE the debt it is
     *      about to retire does. That transiently raises the LTV, which is why the bound here is the market's
     *      own liquidation threshold (less a safety margin) rather than `maxLtvBps`.
     *
     *      Two reasons that is the right bound and not a loosening of the risk policy:
     *      - The excursion is atomic. Nothing outside the transaction can observe or act on it, and the
     *        position is never liquidatable at any point inside it — `UNWIND_SAFETY_BPS` keeps it strictly
     *        under LLTV, and Blue would revert the withdrawal otherwise. All external entry points are
     *        `nonReentrant`, so no callback can re-enter mid-unwind.
     *      - Bounding by `maxLtvBps` instead would make the function return ZERO exactly when the vault most
     *        needs to unwind: a position that has drifted above the ceiling through borrow interest or a
     *        price move would compute no withdrawable collateral and be unable to repair itself. A levered
     *        vault that cannot deleverage while distressed is the failure mode, not the safeguard.
     */
    function _maxWithdrawableCollateral(MarketParams memory params) internal view returns (uint256) {
        uint256 collateral = morpho.position(activeMarketId, address(this)).collateral;

        uint256 debt = _debt(params);
        if (debt == 0) return collateral;

        uint256 value = _collateralValue(params);
        if (value == 0) return 0;

        uint256 ceiling = _lltvBps(params);
        ceiling = ceiling > UNWIND_SAFETY_BPS ? ceiling - UNWIND_SAFETY_BPS : 0;
        if (ceiling == 0) return 0;

        uint256 requiredValue = (debt * BPS) / ceiling;
        if (value <= requiredValue) return 0;

        uint256 withdrawable = _toCollateral(params, value - requiredValue);

        return withdrawable > collateral ? collateral : withdrawable;
    }

    // ==================== INTERNAL: CONVERSIONS ====================

    /**
     * @dev Turns loan assets into collateral, never accepting less than the oracle floor.
     *
     *      The floor is derived from the MARKET'S OWN oracle, which is the honest reference for a levered
     *      position: it is the same price that decides whether the position is liquidatable, so a conversion
     *      that clears the floor cannot leave the vault worse off in the only accounting that can liquidate
     *      it. See the contract NatSpec for what production adds on top.
     */
    function _acquireCollateral(MarketParams memory params, uint256 assets, uint256 slippage)
        internal
        returns (uint256 collateralOut)
    {
        if (assets == 0) return 0;

        MarketConfig storage config = marketConfigs[activeMarketId];
        uint256 minOut = (_toCollateral(params, assets) * (BPS - slippage)) / BPS;

        if (config.route == CollateralRoute.ERC4626) {
            asset.forceApprove(params.collateralToken, assets);
            collateralOut = IERC4626(params.collateralToken).deposit(assets, address(this));
        } else {
            require(address(dexRouter) != address(0), "Dex router not set");

            asset.forceApprove(address(dexRouter), assets);
            collateralOut = dexRouter.exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: address(asset),
                    tokenOut: params.collateralToken,
                    fee: config.poolFee,
                    recipient: address(this),
                    amountIn: assets,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        require(collateralOut >= minOut, "Collateral out below oracle floor");

        emit CollateralAcquired(assets, collateralOut);
    }

    /// @dev Turns collateral back into loan assets, never accepting less than the oracle floor
    function _liquidateCollateral(MarketParams memory params, uint256 collateral, uint256 slippage)
        internal
        returns (uint256 assetsOut)
    {
        if (collateral == 0) return 0;

        MarketConfig storage config = marketConfigs[activeMarketId];
        uint256 minOut = (_toValue(params, collateral) * (BPS - slippage)) / BPS;

        if (config.route == CollateralRoute.ERC4626) {
            assetsOut = IERC4626(params.collateralToken).redeem(collateral, address(this), address(this));
        } else {
            require(address(dexRouter) != address(0), "Dex router not set");

            IERC20(params.collateralToken).forceApprove(address(dexRouter), collateral);
            assetsOut = dexRouter.exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: params.collateralToken,
                    tokenOut: address(asset),
                    fee: config.poolFee,
                    recipient: address(this),
                    amountIn: collateral,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        require(assetsOut >= minOut, "Assets out below oracle floor");

        emit CollateralLiquidated(collateral, assetsOut);
    }

    function _supplyCollateral(MarketParams memory params, uint256 collateral) internal {
        if (collateral == 0) return;

        IERC20(params.collateralToken).forceApprove(address(morpho), collateral);
        morpho.supplyCollateral(params, collateral, address(this), "");
    }

    /**
     * @dev Repays up to `maxAssets` of debt, returning what was actually repaid.
     *      A repayment that would cover the whole position is executed by SHARES, which is the only way to
     *      zero a Blue position: repaying by assets always leaves a share of dust behind, and dust debt keeps
     *      `deleverage()` from ever reporting a flat book.
     */
    function _repay(MarketParams memory params, uint256 maxAssets) internal returns (uint256) {
        if (maxAssets == 0) return 0;

        Position memory p = morpho.position(activeMarketId, address(this));
        if (p.borrowShares == 0) return 0;

        uint256 outstanding = _debt(params);

        if (maxAssets >= outstanding) {
            asset.forceApprove(address(morpho), outstanding);
            (uint256 assetsRepaid,) = morpho.repay(params, 0, p.borrowShares, address(this), "");
            return assetsRepaid;
        }

        asset.forceApprove(address(morpho), maxAssets);
        morpho.repay(params, maxAssets, 0, address(this), "");
        return maxAssets;
    }

    // ==================== INTERNAL: ACCOUNTING ====================

    /// @dev Brings the active market's stored interest up to date before any operation reads it
    function _accrue() internal {
        if (Id.unwrap(activeMarketId) == bytes32(0)) return;
        morpho.accrueInterest(marketConfigs[activeMarketId].params);
    }

    function _debt(MarketParams memory params) internal view returns (uint256) {
        return MorphoBlueMath.expectedBorrowAssets(
            params, morpho.market(activeMarketId), morpho.position(activeMarketId, address(this)).borrowShares
        );
    }

    function _collateralValue(MarketParams memory params) internal view returns (uint256) {
        uint256 collateral = morpho.position(activeMarketId, address(this)).collateral;
        if (collateral == 0) return 0;

        return _toValue(params, collateral);
    }

    /// @dev Collateral-token units -> loan-asset value, at Blue's 1e36 oracle scale
    function _toValue(MarketParams memory params, uint256 collateral) internal view returns (uint256) {
        return
            MorphoBlueMath.mulDivDown(
                collateral, IMorphoOracle(params.oracle).price(), MorphoBlueMath.ORACLE_PRICE_SCALE
            );
    }

    /// @dev Loan-asset value -> collateral-token units
    function _toCollateral(MarketParams memory params, uint256 value) internal view returns (uint256) {
        uint256 price = IMorphoOracle(params.oracle).price();
        require(price > 0, "Oracle price unavailable");

        return MorphoBlueMath.mulDivDown(value, MorphoBlueMath.ORACLE_PRICE_SCALE, price);
    }

    function _lltvBps(MarketParams memory params) internal pure returns (uint256) {
        return (params.lltv * BPS) / WAD;
    }

    /**
     * @dev The invariant every state-changing operation must leave behind.
     *
     *      "At or below the ceiling" is the normal rule. "Strictly better than it started" is the escape
     *      hatch that lets a position which has already drifted above the ceiling — through borrow interest
     *      or a collateral price move, neither of which the vault controls — be unwound at all. Without it a
     *      drifted vault would refuse every operation that could save it. The absolute floor is Blue's own:
     *      the position must remain strictly inside the liquidation threshold.
     */
    function _requireHealthy(uint256 ltvBefore) internal view {
        uint256 ltvAfter = ltvBps();
        if (ltvAfter == 0) return;

        require(ltvAfter <= maxLtvBps || ltvAfter < ltvBefore, "LTV above maximum");
        require(ltvAfter < lltvBps(), "Position not healthy");
    }

    function _iterations(uint256 requested) internal pure returns (uint256) {
        require(requested > 0, "Iterations must be greater than 0");
        return requested > MAX_LOOP_ITERATIONS ? MAX_LOOP_ITERATIONS : requested;
    }

    /// @dev The two-sided floor in bps form: the backend picks the tolerance, the admin caps it
    function _validateSlippage(uint256 backendSlippageBps) internal view returns (uint256) {
        require(backendSlippageBps <= maxSlippageBps, "Slippage exceeds maximum");
        return backendSlippageBps;
    }

    function _convertToShares(uint256 assets, uint256 total, uint256 supply) internal view returns (uint256) {
        return MorphoBlueMath.mulDivDown(assets, supply + virtualShares, total + 1);
    }

    function _convertToAssets(uint256 shares, uint256 total, uint256 supply) internal view returns (uint256) {
        return MorphoBlueMath.mulDivDown(shares, total + 1, supply + virtualShares);
    }
}
