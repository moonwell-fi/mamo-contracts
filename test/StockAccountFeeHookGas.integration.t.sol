// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RedeployStockAccountSystem} from "../multisig/mamo-multisig/019_RedeployStockAccountSystem.sol";

import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {Test, console} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";
import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

interface IObservations {
    function observations(uint256 index) external view returns (uint32 blockTimestamp, int56, uint160, bool);
}

// ─────────────────────────────────────────────────────────────────────────────
// StockAccountFeeHookGasTest — what `payFees` costs inside the CoW post-hook (HOOK_GAS_LIMIT), against the
// REAL StockAccountPriceChecker and the twelve Aerodrome stock pools 019 lists, at the 019 rehearsal's pinned
// block (no --fork-url, same op-revm reason as StockAccountRedeployTest).
//
// Every listed token with a balance is one pool TWAP read in the valuation, and anyone can send an account one
// raw unit of each, so the hook's worst case is every listed token held. This measures it for k held tokens and
// fits base + marginal per held token + overhead per listed token.
//
// COLD, NOT WARM. A fork test keeps storage warm across calls (setUp's listing probes already read every pool's
// observation ring), so each call is measured with its slots warm and charged 2,000 per distinct slot on top,
// the EIP-2929 cold surcharge. That is a fresh transaction's cost; the calibration pins it to a live node trace.
// In a real settlement the account's own isValidSignature runs the same valuation earlier in the transaction,
// so the hook runs closer to the warm figure, which is logged alongside.
//
// The fee is backdated in storage rather than by vm.warp: warping moves every pool's TWAP window past its newest
// observation, which turns `observe` into its cheap extrapolation branch.
// ─────────────────────────────────────────────────────────────────────────────
contract StockAccountFeeHookGasTest is Test {
    uint256 internal constant PINNED_BLOCK = 52_650_000;
    address internal constant DEPLOYER_EOA = 0xDca82E03057329f53Ed4173429D46B0511E46Fb8;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant NVDAC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;

    /// @dev debug_traceCall of NVDAC_POOL.observe([180, 0]) on a Base node at PINNED_BLOCK, less intrinsic gas
    uint256 internal constant NODE_OBSERVE_GAS = 80_690;
    uint256 internal constant COLD_SLOT_SURCHARGE = 2_000;
    /// @dev The hook target's own cold access, which the trampoline pays outside the hook's gas
    uint256 internal constant TARGET_ACCESS = 2_600;

    uint256 internal constant DEPOSIT = 5_000e6;
    uint256 internal constant LAST_FEE_PAID_SLOT = 55;
    uint256 internal constant FEE_PERIOD = 30 days;
    uint256 internal constant SHORT_LISTING = 4;

    struct Gas {
        uint256 warm;
        uint256 cold;
    }

    RedeployStockAccountSystem internal proposal;
    Addresses internal addresses;
    StockAccountRegistry internal registry;
    StockAccountStrategy internal account;
    address internal usdc;

    /// @dev Listed tokens whose pool wrote an observation inside the TWAP window, so `observe` binary-searches
    address[] internal fresh;
    StockAccountsConfig.TokenListEntry[] internal entries;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        vm.etch(DEPLOYER_EOA, "");
        addresses = PinnedAddresses.loadWithout(
            "./addresses", "./script/stock-accounts/addresses-rehearsal/fee-hook", _liveStockKeys()
        );
        vm.makePersistent(address(addresses));
        addresses.changeAddress("DEPLOYER_EOA", makeAddr("stockAccountsV2Deployer"), false);
        usdc = addresses.getAddress("USDC");

        proposal = new RedeployStockAccountSystem();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
        proposal.deploy();
        proposal.preBuildMock();
        proposal.build();
        proposal.simulate();

        registry = StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY"));
        StockAccountsConfig.TokenListEntry[] memory list = proposal.deployConfig().loadTokenList();
        for (uint256 i = 0; i < list.length; i++) {
            entries.push(list[i]);
            (,, uint16 index,,,) = ICLPool(list[i].pool).slot0();
            (uint32 newest,,,) = IObservations(list[i].pool).observations(index);
            if (block.timestamp - newest <= registry.twapWindow()) fresh.push(list[i].token);
        }

        IStockAccountStrategy.BasketEntry[] memory basket = new IStockAccountStrategy.BasketEntry[](1);
        basket[0] = IStockAccountStrategy.BasketEntry({token: NVDAC, targetBps: 5_000});
        StockAccountStrategyFactory factory =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));
        address user = makeAddr("feeHookGasUser");
        vm.prank(user);
        account = StockAccountStrategy(payable(factory.createStrategyForUser(user, basket, 5_000)));

        deal(usdc, user, DEPOSIT);
        vm.startPrank(user);
        IERC20(usdc).approve(address(account), DEPOSIT);
        account.deposit(DEPOSIT);
        vm.stopPrank();
    }

    function test_feeHookGas_perHeldAndListedToken() public {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 180;
        Gas memory observe = _measure(NVDAC_POOL, abi.encodeCall(ICLPool.observe, (secondsAgos)));
        assertApproxEqAbs(observe.cold, NODE_OBSERVE_GAS, 300, "cold model matches the node trace");

        uint256 listed = entries.length;
        uint256 n = fresh.length;
        assertGe(n, 8, "enough fresh pools to fit");

        uint256 start = vm.snapshotState();
        uint256[] memory cold = new uint256[](n + 1);
        uint256[] memory warm = new uint256[](n + 1);
        console.log("held | stock-path cold | warm | usdc-path cold | getNAV cold");
        for (uint256 k = 0; k <= n; k++) {
            vm.revertToState(start);
            _hold(fresh, k, 1);
            Gas memory usdcFee = _measure(address(account), _payFeesIn(usdc));
            Gas memory nav = _measure(address(account), abi.encodeCall(StockAccountStrategy.getNAV, ()));
            Gas memory stockFee = k == 0 ? usdcFee : _measure(address(account), _payFeesIn(fresh[0]));
            (cold[k], warm[k]) = (stockFee.cold, stockFee.warm);
            console.log(
                string.concat(_s(k), " | ", _s(stockFee.cold), " | ", _s(stockFee.warm), " | ", _s(usdcFee.cold)),
                nav.cold
            );
        }

        vm.revertToState(start);
        _hold(fresh, n, 1e8);
        console.log("all fresh held, one whole share each:", _measure(address(account), _payFeesIn(fresh[0])).cold);

        vm.revertToState(start);
        address[] memory all = new address[](listed);
        for (uint256 i = 0; i < listed; i++) {
            all[i] = entries[i].token;
        }
        _hold(all, listed, 1);
        console.log("all twelve held, stale pools included:", _measure(address(account), _payFeesIn(fresh[0])).cold);

        // Listed but not held: the valuation still reads each token's config and balance
        vm.revertToState(start);
        _hold(fresh, 0, 1);
        uint256 fullListing = _measure(address(account), _payFeesIn(usdc)).cold;
        vm.revertToState(start);
        _delistAllBut(SHORT_LISTING);
        _hold(fresh, 0, 1);
        uint256 perListed = (fullListing - _measure(address(account), _payFeesIn(usdc)).cold) / (listed - SHORT_LISTING);

        (uint256 base, uint256 perHeld) = _fit(cold);
        (uint256 warmBase, uint256 warmPerHeld) = _fit(warm);
        uint256 limit = account.HOOK_GAS_LIMIT();
        uint256 cap = registry.MAX_LISTED_TOKENS();
        uint256 atListing = _worst(base, perHeld, perListed, listed, listed);
        uint256 atCap = base + perHeld * registry.maxPositions() + perListed * (cap - listed);

        console.log("cold fit, k held of 12 listed: base, per held, per listed", base, perHeld, perListed);
        console.log("warm fit, k held of 12 listed: base, per held", warmBase, warmPerHeld);
        console.log(
            "cold worst case, every listed token held: at 12, at the cap",
            atListing,
            _worst(base, perHeld, perListed, listed, cap)
        );
        console.log("cold, a full basket held at the cap", atCap);
        console.log(
            "largest listing within 80% of the hook limit",
            (limit * 8 / 10 + listed * perListed - base) / (perHeld + perListed)
        );
        console.log("hook limit the cap needs for a 20% margin", atCap * 10 / 8);

        assertLe(atListing, limit * 8 / 10, "019's listing, all held, within 80% of the hook limit");
        assertLe(atCap, limit * 8 / 10, "the listing cap, a full basket held, within 80% of the hook limit");
    }

    /// @dev The fit is taken at `listed`; each further listed and held token adds both terms
    function _worst(uint256 base, uint256 perHeld, uint256 perListed, uint256 listed, uint256 n)
        internal
        pure
        returns (uint256)
    {
        return base + n * (perHeld + perListed) - listed * perListed;
    }

    /// @dev Least squares over k = 1..n; k = 0 is the USDC path, which skips the fee-token quote
    function _fit(uint256[] memory y) internal pure returns (uint256 base, uint256 slope) {
        uint256 n = y.length - 1;
        (uint256 sumK, uint256 sumKK, uint256 sumY, uint256 sumKY) = (0, 0, 0, 0);
        for (uint256 k = 1; k <= n; k++) {
            (sumK, sumKK, sumY, sumKY) = (sumK + k, sumKK + k * k, sumY + y[k], sumKY + k * y[k]);
        }
        // y rises with k, so the numerator is positive
        slope = (n * sumKY - sumK * sumY) / (n * sumKK - sumK * sumK);
        base = (sumY - slope * sumK) / n;
    }

    function _hold(address[] memory tokens, uint256 k, uint256 amount) internal {
        for (uint256 i = 0; i < k; i++) {
            MockERC20Decimals(tokens[i]).mint(address(account), amount);
        }

        uint256 backdated = block.timestamp - FEE_PERIOD;
        uint256 word = uint256(vm.load(address(account), bytes32(LAST_FEE_PAID_SLOT)));
        vm.store(address(account), bytes32(LAST_FEE_PAID_SLOT), bytes32((word >> 64 << 64) | backdated));
        assertEq(account.lastFeePaid(), backdated, "lastFeePaid backdated");
    }

    function _delistAllBut(uint256 keep) internal {
        vm.startPrank(addresses.getAddress("MAMO_MULTISIG"));
        for (uint256 i = keep; i < entries.length; i++) {
            registry.setTokenStatus(entries[i].token, IStockAccountRegistry.TokenStatus.Halted);
            registry.delistToken(entries[i].token);
        }
        vm.stopPrank();
        assertEq(registry.allTokens().length, keep, "short listing");
    }

    function _payFeesIn(address token) internal pure returns (bytes memory) {
        return abi.encodeCall(StockAccountStrategy.payFees, (token));
    }

    function _s(uint256 value) internal pure returns (string memory) {
        return vm.toString(value);
    }

    function _measure(address target, bytes memory data) internal returns (Gas memory gas) {
        (uint256 warm, uint256 slots) = this.measureFrame(target, data);
        gas.warm = warm;
        gas.cold = warm + COLD_SLOT_SURCHARGE * slots - TARGET_ACCESS;
    }

    /// @dev External so each measurement gets a fresh memory frame. The warm-up records the slots the call
    ///      touches; after the revert accounts are cold again and slots stay warm, hence the slot surcharge.
    function measureFrame(address target, bytes memory data) external returns (uint256 warm, uint256 slotCount) {
        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        assertTrue(_rawCall(target, data), "warm-up call succeeded");
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.revertToState(snap);

        uint256 before = gasleft();
        bool ok = _rawCall(target, data);
        warm = before - gasleft();
        assertTrue(ok, "measured call succeeded");
        vm.revertToState(snap);

        bytes32[] memory seen = new bytes32[](4096);
        for (uint256 i = 0; i < accesses.length; i++) {
            for (uint256 j = 0; j < accesses[i].storageAccesses.length; j++) {
                Vm.StorageAccess memory access = accesses[i].storageAccesses[j];
                bytes32 key = keccak256(abi.encode(access.account, access.slot));
                if (!_contains(seen, slotCount, key)) seen[slotCount++] = key;
            }
        }
    }

    function _contains(bytes32[] memory list, uint256 length, bytes32 key) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (list[i] == key) return true;
        }
        return false;
    }

    /// @dev No returndata copy, so the caller's memory adds nothing to the measurement
    function _rawCall(address target, bytes memory data) internal returns (bool ok) {
        assembly {
            ok := call(gas(), target, 0, add(data, 0x20), mload(data), 0, 0)
        }
    }

    function _liveStockKeys() internal pure returns (string[] memory names) {
        names = new string[](4);
        names[0] = "STOCK_ACCOUNT_REGISTRY";
        names[1] = "STOCK_ACCOUNT_PRICE_CHECKER";
        names[2] = "STOCK_ACCOUNT_STRATEGY_IMPL";
        names[3] = "STOCK_ACCOUNT_STRATEGY_FACTORY";
    }
}
