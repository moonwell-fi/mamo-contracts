// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseStrategy} from "@contracts/BaseStrategy.sol";
import {MamoMultiMarketStrategy} from "@contracts/MamoMultiMarketStrategy.sol";

import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";
import {IMamoMultiMarketStrategy} from "@interfaces/IMamoMultiMarketStrategy.sol";
import {IMamoStrategyRegistry} from "@interfaces/IMamoStrategyRegistry.sol";

import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IPool} from "@interfaces/IPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MamoStakingStrategy
 * @notice A per-user staking strategy for MAMO tokens with automated reward claiming and processing
 * @dev This contract is designed to be used as an implementation for proxies, similar to MamoMultiMarketStrategy
 */
contract MamoStakingStrategy is Initializable, UUPSUpgradeable, BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice Furthest into the future a caller-supplied compound() deadline may sit.
    /// @dev Without an upper bound, `compound(type(uint256).max)` silently restores the tautology
    ///      the caller-supplied deadline exists to remove, leaving no on-chain trace that the
    ///      protection was bypassed. Sized to the SlippagePriceChecker's max order lifetime
    ///      (maxTimePriceValid == 1 hours), since a swap authorised past the point its reference
    ///      price expires is not protected by that price.
    uint256 public constant MAX_COMPOUND_DEADLINE = 1 hours;

    /**
     * @notice Hard ceiling this strategy will accept for a candidate registry's default slippage
     * @dev Deliberately a strategy-side constant rather than a read of the candidate's own
     *      MAX_SLIPPAGE_IN_BPS(): bounding a candidate against a number the candidate itself reports
     *      is circular, and a replacement registry answering 10000 would pass such a check while
     *      driving compound()'s amountOutMinimum to zero with the honest checker and honest router
     *      still in place. Mirrors MamoStakingRegistry.MAX_SLIPPAGE_IN_BPS; if that policy ever
     *      changes, this constant is the second place to change.
     */
    uint256 public constant MAX_REGISTRY_SLIPPAGE_IN_BPS = 2500;

    /// @notice The MultiRewards contract for staking
    IMultiRewards public multiRewards;

    /// @notice The MAMO token contract
    IERC20 public mamoToken;

    /// @notice The MamoStakingRegistry for configuration
    MamoStakingRegistry public stakingRegistry;

    /// @notice The user's allowed slippage in basis points
    uint256 public accountSlippageInBps;

    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed token, uint256 amount);
    event CompoundRewardTokenProcessed(address indexed rewardToken, uint256 amountIn, uint256 amountOut);
    event ReinvestRewardTokenProcessed(address indexed rewardToken, uint256 amount);
    event Compounded(uint256 mamoAmount);
    event Reinvested(uint256 mamoAmount);
    event AccountSlippageUpdated(uint256 oldSlippageInBps, uint256 newSlippageInBps);
    event StakingRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Initialization parameters struct to avoid stack too deep errors
    struct InitParams {
        address mamoStrategyRegistry;
        address stakingRegistry;
        address multiRewards;
        address mamoToken;
        uint256 strategyTypeId;
        address owner;
    }

    /**
     * @notice Constructor disables initializers in the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Restricts function access to the backend address, and only while the registry is live
     * @dev Uses the MamoStakingRegistry to verify the caller is the backend. The registry pause is
     *      the guardian's emergency stop for exactly the scenarios these functions are exposed to
     *      (faulty router, bad price-checker configuration, compromised reinvest destination), so
     *      backend-driven operations must stop with it. Owner-facing exits (withdraw, withdrawAll,
     *      withdrawRewards) deliberately do NOT use this modifier: users must always be able to
     *      leave during an incident.
     */
    modifier onlyBackend() {
        require(stakingRegistry.hasRole(stakingRegistry.BACKEND_ROLE(), msg.sender), "Not backend");
        require(!stakingRegistry.paused(), "Registry paused");
        _;
    }

    /**
     * @notice Initializer function that sets all the parameters
     * @dev This is used instead of a constructor since the contract is designed to be used with proxies
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.mamoStrategyRegistry != address(0), "Invalid mamoStrategyRegistry address");
        require(params.stakingRegistry != address(0), "Invalid stakingRegistry address");
        require(params.multiRewards != address(0), "Invalid multiRewards address");
        require(params.mamoToken != address(0), "Invalid mamoToken address");
        require(params.strategyTypeId != 0, "Strategy type id not set");
        require(params.owner != address(0), "Invalid owner address");

        __BaseStrategy_init(params.mamoStrategyRegistry, params.strategyTypeId, params.owner);

        stakingRegistry = MamoStakingRegistry(params.stakingRegistry);
        multiRewards = IMultiRewards(params.multiRewards);
        mamoToken = IERC20(params.mamoToken);
    }

    /**
     * @notice Repoints this strategy at a different MamoStakingRegistry
     * @dev MamoStakingRegistry is NOT upgradeable — plain constructor, no proxy — so any fix to it
     *      ships as a fresh deployment. Without this function `stakingRegistry` was write-once in
     *      initialize(), which stranded every existing strategy on the registry it was born with:
     *      registry-side remediations could never reach the deployed fleet, and a strategy pointed at
     *      a registry missing a selector compound() needs was permanently bricked for compounding.
     *
     * @dev TWO authorised callers, and the pairing is the security argument.
     *
     *      (1) The CURRENT registry's DEFAULT_ADMIN_ROLE — this grants that role no capability it does
     *      not already hold. It can already call setDEXRouter, setSlippagePriceChecker and
     *      setDefaultSlippage on the registry every strategy reads, so it already decides which router
     *      receives the reward-token allowance in compound() and what minimum-out floor applies.
     *      Gating instead on MamoStrategyRegistry's admin WOULD be an escalation: that role cannot
     *      presently change a strategy's behaviour without the owner opting into an upgrade. This is
     *      the arm that makes a fleet-wide migration one batched transaction.
     *
     *      (2) This strategy's OWNER — the escape hatch. See the body: without it the first use of the
     *      admin arm is irrevocable, because the gate reads the slot it writes. The owner arm is
     *      additive, never a veto: it does not gate, delay or reorder (1).
     *
     * @dev Deliberately not gated on the registry's pause state. Migrating off a broken registry is
     *      remediation, and a registry can be broken in ways that make unpausing impossible.
     *
     * @dev Cannot reach the staked principal, and the reason is NOT the onlyOwner withdraw paths. A
     *      registry listing MAMO in getRewardTokens() is forbidden by MamoStakingRegistry, but an
     *      arbitrary contract passed here is bound by no such rule. What actually holds the line is
     *      the explicit `rewardTokens[i].token != mamoTokenAddr` guard in compound(): MAMO is a
     *      genuine MultiRewards reward token on both live instances, so getReward() really does pull
     *      MAMO in on every compound, and without that guard a registry could list it and route staked
     *      principal through the swap. The blast radius that remains is reward routing during
     *      compound(), which is the current admin's existing reach.
     *
     * @param newStakingRegistry The registry to point at
     */
    function setStakingRegistry(address newStakingRegistry) external {
        MamoStakingRegistry currentRegistry = stakingRegistry;

        // OWNER ESCAPE HATCH, and it is load-bearing rather than defensive. The admin arm below reads
        // `stakingRegistry` — the very slot this function writes — so without an alternative caller the
        // FIRST use of this function is irrevocable: point a strategy at a contract whose hasRole()
        // answers false for everyone (or reverts) and the pointer freezes permanently, for the staking
        // admin, for MAMO_MULTISIG and for this contract's owner alike. Recovery would then need a
        // fixed implementation whitelisted under a fresh type id plus a per-strategy upgradeStrategy
        // opt-in from every owner — precisely the un-migratable-fleet dead end this function exists to
        // escape, recreated. Every other capability the staking admin holds is revocable (setDEXRouter
        // and setSlippagePriceChecker can be called again, grantRole has revokeRole); this one would
        // not be, which is why it needs an escape and they do not.
        //
        // `||` short-circuits, so the owner arm never touches the current registry. That matters: the
        // state this hatch exists for is one where currentRegistry.hasRole() itself reverts, which
        // would take an owner-second ordering down with it.
        //
        // Not a veto on the admin: the owner arm is additive and does not gate, delay or reorder the
        // batched fleet-wide migration. It only means no single key can permanently strand a user —
        // New-1 goes from "unrecoverable" to "the affected owner fixes it in one transaction".
        bool byOwner = msg.sender == owner();
        require(
            byOwner || currentRegistry.hasRole(currentRegistry.DEFAULT_ADMIN_ROLE(), msg.sender),
            "Not staking registry admin"
        );

        require(newStakingRegistry != address(0), "Invalid staking registry");
        require(newStakingRegistry != address(currentRegistry), "Staking registry already set");
        require(newStakingRegistry.code.length != 0, "Staking registry not a contract");

        // Probe the WHOLE surface this strategy reads at runtime before committing, not just the two
        // selectors that caused the last incident. A contract implementing only dexRouter() and
        // slippagePriceChecker() passes a narrow probe and still bricks the owner's own exit:
        // withdrawAll()/withdrawRewards() revert on a missing getRewardTokens(), and since
        // multiRewards.getReward() is only ever called from registry-reading functions, unclaimed
        // rewards are stranded. This needs no malice — an honest v3 registry that renames or drops any
        // of these passes a two-selector probe and bricks the fleet.
        //
        // Raw staticcalls with an explicit returndata check throughout, because a typed call against a
        // contract missing the selector reverts in THIS frame with no data and is indistinguishable
        // from an internal bug.
        require(_readsAddress(newStakingRegistry, "slippagePriceChecker()"), "Staking registry has no price checker");
        require(_readsAddress(newStakingRegistry, "dexRouter()"), "Staking registry has no DEX router");
        require(_readsWord(newStakingRegistry, "BACKEND_ROLE()"), "Staking registry has no backend role");
        require(_readsWord(newStakingRegistry, "DEFAULT_ADMIN_ROLE()"), "Staking registry has no admin role");
        require(_readsWord(newStakingRegistry, "paused()"), "Staking registry has no pause state");
        require(_readsWord(newStakingRegistry, "MAX_SLIPPAGE_IN_BPS()"), "Staking registry has no slippage cap");

        // hasRole is probed UNCONDITIONALLY, not merely as part of the admin arm below: compound()
        // gates on it every call, so a registry missing it bricks compounding even on the owner arm.
        // Any (role, account) pair exercises the selector; the ANSWER is irrelevant here.
        bytes memory hasRoleCall = abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), address(0));
        (bool okHasRole, bytes memory retHasRole) = newStakingRegistry.staticcall(hasRoleCall);
        require(okHasRole && retHasRole.length == 32, "Staking registry has no hasRole");

        // getRewardTokens() returns a dynamic array: ABI head is a 32-byte offset plus a 32-byte
        // length, so anything shorter than 64 bytes cannot be a well-formed encoding of one.
        (bool okRewards, bytes memory retRewards) =
            newStakingRegistry.staticcall(abi.encodeWithSignature("getRewardTokens()"));
        require(okRewards && retRewards.length >= 64, "Staking registry has no reward tokens");

        // The MAMO token is what this strategy stakes; a registry disagreeing about it would price
        // and route swaps for a different asset than the one held.
        (bool ok, bytes memory ret) = newStakingRegistry.staticcall(abi.encodeWithSignature("mamoToken()"));
        require(ok && ret.length == 32, "Staking registry has no MAMO token");
        require(abi.decode(ret, (address)) == address(mamoToken), "Staking registry MAMO token mismatch");

        // getAccountSlippage() falls back to the registry's default whenever the owner never set one —
        // the common case — and compound() spends it as `(10000 - slippage)`. An unbounded default is
        // therefore a zero minimum-out (or, above 10000, an underflow that DoSes compound outright)
        // reachable with the honest price checker and honest router still in place, i.e. with no
        // attacker-authored contract on chain for monitoring to notice.
        (bool okSlip, bytes memory retSlip) =
            newStakingRegistry.staticcall(abi.encodeWithSignature("defaultSlippageInBps()"));
        require(okSlip && retSlip.length == 32, "Staking registry has no default slippage");
        require(abi.decode(retSlip, (uint256)) <= MAX_REGISTRY_SLIPPAGE_IN_BPS, "Staking registry slippage too high");

        // On the ADMIN arm only, require the caller still administers the destination. This costs an
        // honest migration nothing (whoever prepares the new registry holds its admin role) and makes
        // the admin path structurally non-one-way: an admin cannot hand the strategy to a registry
        // they do not control. Deliberately NOT applied to the owner arm — an owner who points their
        // own strategy somewhere useless can point it back, and can already withdraw everything.
        if (!byOwner) {
            require(_isAdminOn(newStakingRegistry, msg.sender), "Not admin on new staking registry");
        }

        stakingRegistry = MamoStakingRegistry(newStakingRegistry);

        emit StakingRegistryUpdated(address(currentRegistry), newStakingRegistry);
    }

    /**
     * @notice Whether `target` answers `signature` with a non-zero address
     * @dev Fails closed: a missing selector returns empty returndata, which reads as false rather
     *      than bubbling an undecodable revert out of the caller's frame.
     */
    function _readsAddress(address target, string memory signature) private view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        if (!ok || ret.length != 32) {
            return false;
        }
        return abi.decode(ret, (address)) != address(0);
    }

    /**
     * @notice Whether `target` answers `signature` with a single 32-byte word
     * @dev Presence check only — the VALUE is not constrained, because for these selectors any word
     *      is legitimate (a role hash may be zero, as DEFAULT_ADMIN_ROLE is; `paused()` may be either
     *      boolean). What is being ruled out is the missing selector, which reverts at the call site
     *      later instead of here.
     */
    function _readsWord(address target, string memory signature) private view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        return ok && ret.length == 32;
    }

    /**
     * @notice Whether `account` holds DEFAULT_ADMIN_ROLE on `target`
     * @dev Two raw staticcalls rather than typed calls, for the same reason as the probes above: the
     *      candidate is untrusted, and a missing selector must read as "no" rather than bubbling
     *      undecodable revert data. Callers must have already established that both selectors exist.
     */
    function _isAdminOn(address target, address account) private view returns (bool) {
        (bool okRole, bytes memory retRole) = target.staticcall(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));
        if (!okRole || retRole.length != 32) {
            return false;
        }
        bytes32 adminRole = abi.decode(retRole, (bytes32));
        bytes memory hasRoleCall = abi.encodeWithSignature("hasRole(bytes32,address)", adminRole, account);
        (bool ok, bytes memory ret) = target.staticcall(hasRoleCall);
        if (!ok || ret.length != 32) {
            return false;
        }
        return abi.decode(ret, (bool));
    }

    /**
     * @notice Set slippage tolerance for this strategy
     * @param slippageInBps The slippage tolerance in basis points (e.g., 100 = 1%)
     */
    function setAccountSlippage(uint256 slippageInBps) external onlyOwner {
        require(slippageInBps <= stakingRegistry.MAX_SLIPPAGE_IN_BPS(), "Slippage too high");

        emit AccountSlippageUpdated(accountSlippageInBps, slippageInBps);
        accountSlippageInBps = slippageInBps;
    }

    /**
     * @notice Get the slippage tolerance for this strategy
     * @return The slippage tolerance in basis points (falls back to global if not set)
     */
    function getAccountSlippage() public view returns (uint256) {
        return accountSlippageInBps > 0 ? accountSlippageInBps : stakingRegistry.defaultSlippageInBps();
    }

    /**
     * @notice Deposit MAMO tokens into MultiRewards (permissionless)
     * @param amount The amount of MAMO to deposit
     */
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer MAMO from depositor to this contract
        mamoToken.safeTransferFrom(msg.sender, address(this), amount);

        _stakeMamo(amount);

        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw MAMO tokens from MultiRewards
     * @param amount The amount of MAMO to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");

        // Withdraw from MultiRewards
        multiRewards.withdraw(amount);

        // Transfer withdrawn MAMO to owner
        mamoToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(address(mamoToken), amount);
    }

    /**
     * @notice Withdraw all staked MAMO tokens from MultiRewards and claim rewards
     */
    function withdrawAll() external onlyOwner {
        uint256 stakedBalance = multiRewards.balanceOf(address(this));
        require(stakedBalance > 0, "No tokens to withdraw");

        // Exit from MultiRewards (withdraws all staked tokens and claims rewards)
        multiRewards.exit();

        // Transfer all MAMO tokens (original stake + any MAMO rewards) to owner
        uint256 mamoBalance = mamoToken.balanceOf(address(this));
        if (mamoBalance > 0) {
            mamoToken.safeTransfer(msg.sender, mamoBalance);
            emit Withdrawn(address(mamoToken), mamoBalance);
        }

        // Transfer all claimed reward tokens to owner
        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(address(this));
            if (rewardBalance > 0) {
                rewardToken.safeTransfer(msg.sender, rewardBalance);
                emit Withdrawn(address(rewardToken), rewardBalance);
            }
        }
    }

    /**
     * @notice Withdraw all available rewards without affecting staked balance
     * @dev Claims all reward tokens and transfers them to the owner
     */
    function withdrawRewards() external onlyOwner {
        multiRewards.getReward();

        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();

        // Loop through all reward tokens and transfer to owner
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(address(this));
            if (rewardBalance > 0) {
                rewardToken.safeTransfer(msg.sender, rewardBalance);
                emit Withdrawn(address(rewardToken), rewardBalance);
            }
        }
    }

    /**
     * @notice Compound all available rewards by converting them to MAMO and restaking
     * @dev Claims rewards and then compounds them. Can be called independently.
     * @param deadline Unix timestamp after which the swaps must no longer execute. Taken from the
     *        caller because `block.timestamp + N` computed inside the transaction is tautological:
     *        a pending compound() would stay valid forever and eventually execute against whatever
     *        market exists when it is finally mined.
     */
    function compound(uint256 deadline) external onlyBackend {
        require(deadline >= block.timestamp, "Deadline in the past");
        require(deadline <= block.timestamp + MAX_COMPOUND_DEADLINE, "Deadline too far in the future");

        multiRewards.getReward();

        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
        ISwapRouter dexRouter = stakingRegistry.dexRouter();
        ISlippagePriceChecker priceChecker = stakingRegistry.slippagePriceChecker();
        uint256 accountSlippage = getAccountSlippage();
        address mamoTokenAddr = address(mamoToken);

        // Process each reward token by swapping to MAMO
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            // The staked principal is protected HERE, explicitly, and this is the only thing
            // protecting it. MamoStakingRegistry forbids listing MAMO as a reward token, but
            // setStakingRegistry accepts any contract satisfying the probes, and MAMO is a real
            // MultiRewards reward token on both live instances — so getReward() genuinely brings MAMO
            // onto this contract and `balanceOf` below would sweep the staked position into a swap.
            // Before this require the bound rested entirely on `received = after - before` underflowing
            // when tokenIn == tokenOut: correct, but accidental, unstated, and one refactor away from
            // being optimised into a silent loss. Fail closed rather than skip, so a registry that
            // lists MAMO is a loud, diagnosable revert instead of a partially-processed compound.
            require(rewardTokens[i].token != mamoTokenAddr, "Reward token is MAMO");

            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(address(this));

            if (rewardBalance == 0) continue;

            // Swap reward tokens to MAMO
            // Get tickSpacing from the pool
            address poolAddress = rewardTokens[i].pool;
            int24 tickSpacing = IPool(poolAddress).tickSpacing();

            // Compute reference output from Chainlink-based price checker.
            // This anchors the slippage check to an off-pool oracle so that pool-price
            // manipulation (sandwich attacks) cannot bypass the minimum-out guard the
            // way an in-pool quoter call would.
            uint256 expectedOut = priceChecker.getExpectedOut(rewardBalance, address(rewardToken), mamoTokenAddr);
            uint256 amountOutMinimum = (expectedOut * (10000 - accountSlippage)) / 10000;

            // Approve DEX router to spend reward tokens
            rewardToken.forceApprove(address(dexRouter), rewardBalance);

            // Create swap parameters
            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(rewardToken),
                tokenOut: address(mamoToken),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: deadline,
                amountIn: rewardBalance,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0 // No price limit
            });

            // Measure what this contract actually received rather than trusting the router's return
            // value: amountOutMinimum would otherwise be enforced only by the router's own code, so
            // a buggy router, a router upgrade, or non-standard return semantics would silently
            // defeat the slippage protection this strategy believes it is applying.
            uint256 mamoBalanceBefore = IERC20(mamoTokenAddr).balanceOf(address(this));

            dexRouter.exactInputSingle(swapParams);

            uint256 received = IERC20(mamoTokenAddr).balanceOf(address(this)) - mamoBalanceBefore;
            require(received >= amountOutMinimum, "Insufficient MAMO received");

            // Measure the input side too, for the same reason as the output side: the event is the
            // feed off-chain reconciliation uses to compare claimed against swapped, so emitting the
            // requested balance would let an under-pulling router drift that reconciliation silently
            // — and reconciliation is the natural monitor for a malicious-router incident.
            // Unguarded subtraction on purpose: a post-swap balance above the pre-swap balance means
            // the router sent reward tokens in rather than taking them, which is not a state this
            // strategy should continue through.
            uint256 pulled = rewardBalance - rewardToken.balanceOf(address(this));

            // Leave no standing allowance behind if the router pulled less than it was approved for.
            rewardToken.forceApprove(address(dexRouter), 0);

            emit CompoundRewardTokenProcessed(address(rewardToken), pulled, received);
        }

        // Stake all MAMO
        uint256 totalMamo = mamoToken.balanceOf(address(this));
        _stakeMamo(totalMamo);

        emit Compounded(totalMamo);
    }

    /**
     * @notice Reinvest rewards by staking MAMO and depositing other rewards to ERC20 strategies
     * @param rewardStrategies Array of strategy addresses for each reward token (must match rewardTokens order)
     * @dev Claims rewards and then reinvests them. We trust the backend to provide correct user-owned strategies.
     */
    function reinvest(address[] calldata rewardStrategies) external onlyBackend {
        multiRewards.getReward();

        MamoStakingRegistry.RewardToken[] memory rewardTokens = stakingRegistry.getRewardTokens();
        require(rewardStrategies.length == rewardTokens.length, "Strategies length mismatch");

        uint256 mamoBalance = mamoToken.balanceOf(address(this));

        // Stake MAMO
        _stakeMamo(mamoBalance);

        // Process each reward token
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            IERC20 rewardToken = IERC20(rewardTokens[i].token);
            uint256 rewardBalance = rewardToken.balanceOf(address(this));

            if (rewardBalance == 0) continue;

            address strategyAddress = rewardStrategies[i];

            // Validate strategy ownership - strategy must be owned by the same user as this strategy
            address strategyOwner = Ownable(strategyAddress).owner();
            require(owner() == strategyOwner, "Strategy owner mismatch");

            // Validate strategy is whitelisted in the registry
            require(mamoStrategyRegistry.isUserStrategy(owner(), strategyAddress), "Strategy not registered");

            // Validate strategy token - strategy must handle the same token as the reward token
            IMamoMultiMarketStrategy strategy = IMamoMultiMarketStrategy(strategyAddress);
            require(address(strategy.token()) == address(rewardToken), "Strategy token mismatch");

            // Approve strategy to spend reward tokens and deposit
            rewardToken.forceApprove(strategyAddress, rewardBalance);
            strategy.deposit(rewardBalance);

            emit ReinvestRewardTokenProcessed(address(rewardToken), rewardBalance);
        }

        emit Reinvested(mamoBalance);
    }

    /**
     * @notice Internal function to stake MAMO tokens in MultiRewards
     * @param amount The amount of MAMO to stake
     */
    function _stakeMamo(uint256 amount) internal {
        if (amount == 0) return;

        mamoToken.forceApprove(address(multiRewards), amount);
        multiRewards.stake(amount);
    }
}
