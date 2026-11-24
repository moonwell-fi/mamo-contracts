// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HardenStockPriceChecker} from "../multisig/mamo-multisig/023_HardenStockPriceChecker.sol";

import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ICLPool} from "@interfaces/ICLPool.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";
import {PinnedAddresses} from "@test/utils/PinnedAddresses.sol";

/**
 * @title StockAccountHardenCheckerTest
 * @notice Base-fork rehearsal of multisig proposal 023, then the MOO-1164 drain replayed on a live account
 *         before and after it. Self-forks at a pinned block (no --fork-url, same op-revm reason as 021).
 */
contract StockAccountHardenCheckerTest is Test {
    /// @dev After ANTc was listed (59,618,114) on the live V2 registry
    uint256 internal constant PINNED_BLOCK = 61_320_000;

    /// @dev 7702-delegated on Base; cleared so the rehearsal can broadcast from it
    address internal constant DEPLOYER_EOA = 0xDca82E03057329f53Ed4173429D46B0511E46Fb8;
    address internal constant ANTC = 0xb20000000000000000000016e38FD364d271Ba28;
    address internal constant ANTC_POOL = 0x599C4225FE90214795a0be228D20d7680f8CED15;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    /// @dev The live v2 account the drain was simulated on in MOO-1164
    address internal constant ACCOUNT = 0x67C1887C3dfD73daaf12Df38b6cae829972b53d6;
    /// @dev Floored mean tick and zero-liquidity seconds of the ANTc window at block 59,592,800
    int24 internal constant SWEPT_TICK = -478_551;
    uint160 internal constant SWEPT_ZERO_SECONDS = 103;
    uint32 internal constant WINDOW = 180;

    HardenStockPriceChecker internal proposal;
    Addresses internal addresses;
    StockAccountRegistry internal registry;
    IERC20 internal usdc;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        vm.txGasPrice(0);
        vm.fee(0);

        vm.etch(DEPLOYER_EOA, "");
        addresses = PinnedAddresses.load("./addresses");
        vm.makePersistent(address(addresses));
        addresses.changeAddress("DEPLOYER_EOA", makeAddr("hardenCheckerDeployer"), false);

        registry = StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY"));
        usdc = IERC20(addresses.getAddress("USDC"));
        proposal = new HardenStockPriceChecker();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
        proposal.deploy();
        proposal.preBuildMock();
    }

    function test_hardenStockPriceChecker() public {
        address checker = addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER");

        proposal.build();
        proposal.simulate();
        proposal.validate();

        (address[] memory targets, uint256[] memory values, bytes[] memory args) = proposal.getProposalActions();
        assertEq(targets.length, 1, "one action");
        assertEq(targets[0], address(registry), "target");
        assertEq(values[0], 0, "no ETH");
        assertEq(args[0], abi.encodeWithSignature("setPriceChecker(address)", checker), "calldata");
    }

    /// @notice A dust ANTc balance in the swept window drains the account under the live checker, and moves
    ///         nothing once 023 has executed.
    function test_sweptAntcWindow_drainsBeforeAndNothingAfter() public {
        MockERC20Decimals(ANTC).mint(ACCOUNT, 1);
        MockERC20Decimals(NVDAC).mint(ACCOUNT, 10e8);
        deal(address(usdc), ACCOUNT, 1_000e6);

        address feeRecipient = registry.feeRecipient();
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        uint256 snap = vm.snapshotState();

        _mockSweptWindow();
        IStockAccountStrategy(ACCOUNT).payFeesFromAny();
        assertEq(usdc.balanceOf(ACCOUNT), 0, "live checker: all USDC taken");
        assertEq(IERC20(NVDAC).balanceOf(ACCOUNT), 0, "live checker: every held stock taken");
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore + 1_000e6, "live checker: USDC sent as fee");

        vm.revertToState(snap);
        vm.clearMockedCalls();
        // setPriceChecker re-probes every listed token, so 023 executes in a clean window
        proposal.build();
        proposal.simulate();
        _mockSweptWindow();

        ISlippagePriceChecker checker = registry.priceChecker();
        vm.expectRevert(
            abi.encodeWithSelector(StockAccountPriceChecker.ZeroLiquidityInWindow.selector, ANTC_POOL, WINDOW)
        );
        checker.getExpectedOut(1e8, ANTC, address(usdc));

        IStockAccountStrategy(ACCOUNT).payFeesFromAny();
        assertEq(usdc.balanceOf(ACCOUNT), 1_000e6, "hardened: USDC untouched");
        assertEq(IERC20(NVDAC).balanceOf(ACCOUNT), 10e8, "hardened: stocks untouched");
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore, "hardened: no fee while the valuation is partial");
    }

    /// @dev `observe([180, 0])` answers as the ANTc pool did at block 59,592,800
    function _mockSweptWindow() internal {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = WINDOW;
        int56[] memory cum = new int56[](2);
        cum[1] = int56(SWEPT_TICK) * int56(uint56(WINDOW));
        uint160[] memory secondsPerLiquidity = new uint160[](2);
        secondsPerLiquidity[1] = SWEPT_ZERO_SECONDS << 128;
        vm.mockCall(ANTC_POOL, abi.encodeCall(ICLPool.observe, (secondsAgos)), abi.encode(cum, secondsPerLiquidity));
    }
}
