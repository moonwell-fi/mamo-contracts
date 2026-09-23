// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployStockAccountSystem} from "../multisig/mamo-multisig/016_DeployStockAccountSystem.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {StockAccountPriceChecker} from "@contracts/StockAccountPriceChecker.sol";
import {StockAccountRegistry} from "@contracts/StockAccountRegistry.sol";
import {StockAccountStrategy} from "@contracts/StockAccountStrategy.sol";
import {StockAccountStrategyFactory} from "@contracts/StockAccountStrategyFactory.sol";

import {Test} from "@forge-std/Test.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";
import {IStockAccountRegistry} from "@interfaces/IStockAccountRegistry.sol";
import {IStockAccountStrategy} from "@interfaces/IStockAccountStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// StockAccountSystemSetupTest — REAL Base-fork rehearsal of proposal 016, the mainnet deployment of
// the stock accounts system, followed by a user lifecycle on the result.
//
// Mirrors LeveragedAeroSystemSetup.integration.t.sol: PINNED fork created in setUp with the op-revm
// Isthmus workaround, and the test owns the FPS `Addresses` book.
//
// NO --fork-url on the make target: foundry 1.7.x would init the OP-stack L1Block handler against
// the CLI fork and panic before the in-test vm.fee(0) workaround runs. The fork is created here.
//
// WHAT THIS DRIVES, END TO END, AGAINST REAL MAINNET STATE
//   1. proposal 016, hook by hook in the order `run()` would: deploy (registry, price checker,
//      account implementation, factory as the deployer), preBuildMock, build (the Safe batch, really
//      executed so FPS can record it), simulate (the batch re-executed through a Safe + MultiSend),
//      validate.
//   2. the post-conditions again in this test's own body, so a 016 regression fails here and not only
//      inside the proposal's own validate().
//   3. a real cbBTC account: predict the address, create it, deposit USDC, deposit cbBTC, read NAV and
//      weights priced through the existing SlippagePriceChecker pair THIS BATCH configured, withdraw
//      cash, take the cbBTC back in kind, then settle a management fee after a one-year warp.
//
// WHAT THIS DELIBERATELY DOES NOT DRIVE
//   THE FOUR B20 STOCKS, AS TOKENS. Their onchain code is the single reserved byte 0xEF, which revm
//   refuses to execute, so nothing can call them inside a fork — no balance, no transfer, no swap.
//   016's preBuildMock stands a minimal ERC20 in over each of them for the reads the system makes
//   (`decimals()` in the listing probe and the TWAP scaling, `balanceOf()` in valuation); their POOL
//   leg — token0/token1/observe on the live Aerodrome Slipstream pools — and the whole quote
//   arithmetic stay real and unmocked, which is what `validateTokenList`'s non-zero quote proves.
//   cbBTC is the one launch token that is an ordinary contract, so it is the one the lifecycle can
//   prove with no stand-in at all, and it is what this test drives.
//
//   THE WITHDRAWAL SELL PATH. The cash withdrawal here is covered by idle USDC on purpose, so no swap
//   runs. Selling cbBTC into the live Slipstream router is already covered, at this same pinned block
//   and against the same pool, by test/StockAccountRouterSwap.integration.t.sol; re-running it here
//   would prove nothing extra about the deployment.
//
//   THE COW ORDER PATH. `isValidSignature` needs an order signed by STOCK_ORDER_SIGNER, whose key is
//   held by ops. The wiring it depends on is asserted instead (the registry's `orderSigner`, the
//   factory's `cowSettlement`).
// ─────────────────────────────────────────────────────────────────────────────

contract StockAccountSystemSetupTest is Test {
    /// @dev The pin the other two stock fork suites use (StockAccountPriceChecker, StockAccountRouterSwap).
    ///      At this block the strategy type slot 5 is free, `nextStrategyTypeId()` reads 4, the cbBTC/USDC
    ///      pair is NOT yet configured on CHAINLINK_SWAP_CHECKER_PROXY, and every `isContract` entry of
    ///      addresses/8453.json already has code — so 016's preconditions hold exactly as written.
    uint256 internal constant PINNED_BLOCK = 51_651_514;

    uint16 internal constant CBBTC_TARGET_BPS = 5_000;
    uint16 internal constant CASH_TARGET_BPS = 5_000;
    uint16 internal constant WITHDRAW_SLIPPAGE_BPS = 500;

    uint256 internal constant USDC_DEPOSIT = 5_000e6;
    uint256 internal constant CBBTC_DEPOSIT = 0.04e8;
    uint256 internal constant CASH_WITHDRAWAL = 1_000e6;

    /// @dev A sanity band on one whole cbBTC in USDC. Wide enough never to be a price bet, narrow
    ///      enough that a mis-scaled or mis-routed quote cannot sit inside it.
    uint256 internal constant CBBTC_MIN_PRICE = 20_000e6;
    uint256 internal constant CBBTC_MAX_PRICE = 500_000e6;

    /// @dev PROD `managementFeeBps`, charged on the account value over a full year.
    uint16 internal constant MANAGEMENT_FEE_BPS = 100;

    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    DeployStockAccountSystem internal proposal;
    Addresses internal addresses;

    address internal multisig;
    address internal usdc;
    address internal deployer = makeAddr("stockAccountsDeployer");
    address internal user = makeAddr("stockAccountsUser");

    function setUp() public {
        // PIN THE BLOCK (mandatory) — deterministic fork.
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), PINNED_BLOCK);
        // op-revm Isthmus operator-fee workaround, same as the other stock fork suites.
        vm.txGasPrice(0);
        vm.fee(0);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(_bookWithoutTheLiveDeployment(), chainIds);
        vm.makePersistent(address(addresses));

        // A throwaway deployer: the real DEPLOYER_EOA's next CREATE slots at any given block are
        // addresses the book may already record, and FPS refuses to register an address twice. A
        // nonce-0 EOA deploys into free slots. Nothing in the proposal depends on WHO deploys.
        addresses.changeAddress("DEPLOYER_EOA", deployer, false);

        multisig = addresses.getAddress("MAMO_MULTISIG");
        usdc = addresses.getAddress("USDC");

        proposal = new DeployStockAccountSystem();
        proposal.setPrimaryForkId(vm.activeFork());
        proposal.setAddresses(addresses);
    }

    struct BookEntry {
        address addr;
        bool isContract;
        string name;
    }

    /// @dev The live 016 contracts have no code at the pinned block, so the rehearsal drops them from the book
    function _bookWithoutTheLiveDeployment() internal returns (string memory dir) {
        dir = "./script/stock-accounts/addresses-rehearsal";
        vm.createDir(dir, true);

        BookEntry[] memory entries = abi.decode(vm.parseJson(vm.readFile("./addresses/8453.json")), (BookEntry[]));
        string memory json = "[";
        bool first = true;

        for (uint256 i = 0; i < entries.length; i++) {
            bytes32 name = keccak256(bytes(entries[i].name));
            if (
                name == keccak256("STOCK_ACCOUNT_REGISTRY") || name == keccak256("STOCK_ACCOUNT_PRICE_CHECKER")
                    || name == keccak256("STOCK_ACCOUNT_STRATEGY_IMPL")
                    || name == keccak256("STOCK_ACCOUNT_STRATEGY_FACTORY")
            ) continue;

            json = string.concat(
                json,
                first ? "" : ",",
                '{"addr":"',
                vm.toString(entries[i].addr),
                '","name":"',
                entries[i].name,
                '","isContract":',
                entries[i].isContract ? "true" : "false",
                "}"
            );
            first = false;
        }

        vm.writeFile(string.concat(dir, "/8453.json"), string.concat(json, "]"));
    }

    /// @dev One test, not several: the deployment, the batch and the user lifecycle are strictly
    ///      sequential, and each stage's preconditions ARE the previous stage's post-conditions.
    ///      Splitting them would re-run the whole deployment per case and prove nothing extra.
    function test_stockAccountSystemSetup_andUserLifecycle() public {
        _runProposal();
        _proveRecordedBatch();
        _proveBatchPostConditions();
        _proveUserLifecycle();
    }

    // ─── stage 1: proposal 016, hook by hook ─────────────────────────────────

    function _runProposal() internal {
        proposal.deploy();
        proposal.preBuildMock();
        proposal.build();
        proposal.simulate();
        proposal.validate();
    }

    // ─── stage 2: what the Safe will actually be asked to sign ───────────────

    /// @dev The batch itself, in order. The point of the stand-in in `preBuildMock` is that all five
    ///      listings reach this array; without it the four B20 ones revert inside `build` and the Safe
    ///      would be handed a four-call batch that silently lists nothing. The listing calldata is
    ///      checked to target the REAL token addresses, which is what the Safe sends.
    function _proveRecordedBatch() internal view {
        (address[] memory targets, uint256[] memory values, bytes[] memory args) = proposal.getProposalActions();

        address stockRegistry = addresses.getAddress("STOCK_ACCOUNT_REGISTRY");
        address mamoRegistry = addresses.getAddress("MAMO_STRATEGY_REGISTRY");
        address existingChecker = addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY");

        assertEq(targets.length, 10, "ten actions: 1 repoint + 2 registry + 2 feed config + 5 listings");

        address[10] memory expectedTargets = [
            stockRegistry,
            mamoRegistry,
            mamoRegistry,
            existingChecker,
            existingChecker,
            stockRegistry,
            stockRegistry,
            stockRegistry,
            stockRegistry,
            stockRegistry
        ];
        bytes4[10] memory expectedSelectors = [
            StockAccountRegistry.setPriceChecker.selector,
            MamoStrategyRegistry.whitelistImplementation.selector,
            bytes4(keccak256("grantRole(bytes32,address)")),
            ISlippagePriceChecker.addTokenConfiguration.selector,
            ISlippagePriceChecker.setMaxTimePriceValid.selector,
            StockAccountRegistry.listToken.selector,
            StockAccountRegistry.listToken.selector,
            StockAccountRegistry.listToken.selector,
            StockAccountRegistry.listToken.selector,
            StockAccountRegistry.listToken.selector
        ];

        for (uint256 i = 0; i < targets.length; i++) {
            assertEq(targets[i], expectedTargets[i], "action target");
            assertEq(values[i], 0, "no action moves ETH");
            assertEq(bytes4(args[i]), expectedSelectors[i], "action selector");
        }

        // The cbBTC pair is configured before cbBTC is listed, which is the ordering the listing probe
        // depends on, and every listing names the token the committed config names.
        address[5] memory listed = [
            0xb200000000000000000000C2e324d24d7eEcd1fb, // AAPLc
            0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, // cbBTC
            0xb2000000000000000000002D0BA3164cc74f58B7, // GOOGLc
            0xb2000000000000000000008bC8786B856E61707C, // METAc
            0xb20000000000000000000078ee7ce2fE4908108C // NVDAc
        ];
        for (uint256 i = 0; i < listed.length; i++) {
            assertEq(_firstAddressArgument(args[5 + i]), listed[i], "listToken targets the real token address");
        }
        assertEq(_firstAddressArgument(args[3]), listed[1], "the configured pair is cbBTC's");
    }

    /// @dev The first ABI word of a call's arguments, read as an address.
    function _firstAddressArgument(bytes memory data) internal pure returns (address argument) {
        assembly {
            argument := mload(add(data, 36))
        }
    }

    // ─── stage 3: the post-conditions, restated outside the proposal ─────────

    function _proveBatchPostConditions() internal view {
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        StockAccountRegistry stockRegistry = StockAccountRegistry(addresses.getAddress("STOCK_ACCOUNT_REGISTRY"));
        address implementation = addresses.getAddress("STOCK_ACCOUNT_STRATEGY_IMPL");
        address factory = addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY");
        uint256 typeId = proposal.strategyTypeId();

        assertEq(typeId, 5, "the launch strategy type id");
        assertEq(
            address(stockRegistry.priceChecker()),
            addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER"),
            "registry repointed at the real checker"
        );
        assertEq(mamoRegistry.latestImplementationById(typeId), implementation, "implementation whitelisted at type 5");
        assertTrue(mamoRegistry.hasRole(mamoRegistry.BACKEND_ROLE(), factory), "factory holds BACKEND_ROLE");
        assertEq(stockRegistry.allTokens().length, 5, "all five launch tokens listed");

        // The guard the proposal exists to make safe: the four live slots are untouched. Pinned by the
        // values Base actually held at this block, not by a snapshot this test took itself.
        assertEq(
            mamoRegistry.latestImplementationById(1), 0x4007EFfCE837701Fdd90017Ab747fefD58aAD98B, "slot 1 untouched"
        );
        assertEq(
            mamoRegistry.latestImplementationById(2), 0x7240519388ACD7632FF38753F514fcC993AbED09, "slot 2 untouched"
        );
        assertEq(
            mamoRegistry.latestImplementationById(3), 0x26ba1566bba5660eecCc6C052e953E945BF28550, "slot 3 untouched"
        );
        assertEq(
            mamoRegistry.latestImplementationById(4), 0x6C8577fa9B10807f7485f6476C2AFE0B8d61D1e7, "slot 4 untouched"
        );

        // cbBTC is priceable through the pair the batch configured on the EXISTING checker, and the
        // quote lands in a band no mis-scaling survives.
        uint256 oneCbBTC = StockAccountPriceChecker(addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER")).getExpectedOut(
            1e8, CBBTC, usdc
        );
        assertGt(oneCbBTC, CBBTC_MIN_PRICE, "one cbBTC should be worth more than the floor");
        assertLt(oneCbBTC, CBBTC_MAX_PRICE, "one cbBTC should be worth less than the ceiling");
    }

    // ─── stage 4: a real user, on the deployed system ────────────────────────

    function _proveUserLifecycle() internal {
        StockAccountStrategyFactory factory =
            StockAccountStrategyFactory(addresses.getAddress("STOCK_ACCOUNT_STRATEGY_FACTORY"));
        MamoStrategyRegistry mamoRegistry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        address predicted = factory.computeStrategyAddress(user);
        assertEq(predicted.code.length, 0, "nothing deployed at the predicted address yet");

        IStockAccountStrategy.BasketEntry[] memory entries = new IStockAccountStrategy.BasketEntry[](1);
        entries[0] = IStockAccountStrategy.BasketEntry({token: CBBTC, targetBps: CBBTC_TARGET_BPS});

        vm.prank(user);
        StockAccountStrategy account =
            StockAccountStrategy(payable(factory.createStrategyForUser(user, entries, CASH_TARGET_BPS)));

        assertEq(address(account), predicted, "account deployed at the predicted address");
        assertEq(account.owner(), user, "account owned by the user");
        assertEq(account.strategyTypeId(), proposal.strategyTypeId(), "account carries the launch type id");
        assertTrue(mamoRegistry.isUserStrategy(user, address(account)), "account registered with the Mamo registry");

        _proveDepositAndValuation(account);
        _proveWithdrawal(account);
        _proveFeeSettlement(account);
    }

    function _proveDepositAndValuation(StockAccountStrategy account) internal {
        StockAccountPriceChecker checker = StockAccountPriceChecker(addresses.getAddress("STOCK_ACCOUNT_PRICE_CHECKER"));

        deal(usdc, user, USDC_DEPOSIT);
        vm.startPrank(user);
        IERC20(usdc).approve(address(account), USDC_DEPOSIT);
        account.deposit(USDC_DEPOSIT);
        vm.stopPrank();

        // A real cbBTC position, in kind: the token is an ordinary ERC20, so nothing is stood in here.
        deal(CBBTC, user, CBBTC_DEPOSIT);
        vm.startPrank(user);
        IERC20(CBBTC).approve(address(account), CBBTC_DEPOSIT);
        account.depositToken(CBBTC, CBBTC_DEPOSIT);
        vm.stopPrank();

        uint256 cbbtcValue = checker.getExpectedOut(CBBTC_DEPOSIT, CBBTC, usdc);
        assertGt(cbbtcValue, 0, "the cbBTC leg should be worth something");
        assertEq(account.getNAV(), USDC_DEPOSIT + cbbtcValue, "NAV is the cash leg plus the priced cbBTC leg");

        (address[] memory tokens, uint256[] memory currentBps, uint256[] memory targetBps) = account.getWeights();
        assertEq(tokens.length, 5, "weights cover every listed token");

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == CBBTC) {
                assertEq(targetBps[i], CBBTC_TARGET_BPS, "cbBTC target weight");
                assertEq(
                    currentBps[i], (cbbtcValue * 10_000) / account.getNAV(), "cbBTC current weight tracks its value"
                );
            } else {
                // The four B20 stocks: listed, targeted at nothing, and held at nothing.
                assertEq(targetBps[i], 0, "unbasketed token target weight");
                assertEq(currentBps[i], 0, "unbasketed token current weight");
            }
        }

        address[] memory held = account.heldTokens();
        assertEq(held.length, 1, "only cbBTC is held");
        assertEq(held[0], CBBTC, "the held token is cbBTC");
    }

    function _proveWithdrawal(StockAccountStrategy account) internal {
        // Covered by idle cash, so the sell path is not taken — asserted through the preview rather
        // than inferred (see the header for why the sell path is out of scope here).
        (address[] memory toSell,,,) = account.previewWithdraw(CASH_WITHDRAWAL, WITHDRAW_SLIPPAGE_BPS);
        assertEq(toSell.length, 0, "a cash-covered withdrawal plans no sells");

        uint256 before = IERC20(usdc).balanceOf(user);
        vm.prank(user);
        account.withdraw(CASH_WITHDRAWAL, WITHDRAW_SLIPPAGE_BPS);
        assertEq(IERC20(usdc).balanceOf(user) - before, CASH_WITHDRAWAL, "the owner received the cash");

        // Take the cbBTC back in kind, which leaves the account holding cash only.
        before = IERC20(CBBTC).balanceOf(user);
        vm.prank(user);
        account.withdrawToken(CBBTC, CBBTC_DEPOSIT);
        assertEq(IERC20(CBBTC).balanceOf(user) - before, CBBTC_DEPOSIT, "the owner received the cbBTC");
        assertEq(IERC20(CBBTC).balanceOf(address(account)), 0, "no cbBTC left in the account");
        assertEq(account.getNAV(), USDC_DEPOSIT - CASH_WITHDRAWAL, "NAV is the remaining cash");
    }

    /// @dev Warped a full year AFTER the cbBTC leg is gone, on purpose: the account then values itself
    ///      out of its own USDC balance and reads no oracle, so the warp cannot age a Chainlink answer
    ///      past its heartbeat and turn a fee assertion into an oracle-staleness revert.
    function _proveFeeSettlement(StockAccountStrategy account) internal {
        address feeRecipient = addresses.getAddress("F-MAMO");
        assertEq(account.feeRecipient(), feeRecipient, "the account pays its fee to F-MAMO");
        assertEq(account.feeDue(), 0, "nothing is owed before any time passes");

        uint256 nav = account.getNAV();
        vm.warp(block.timestamp + 365 days);

        uint256 expectedFee = (nav * MANAGEMENT_FEE_BPS) / 10_000;
        assertEq(account.feeDue(), expectedFee, "a year of the annual fee on the account value");
        assertEq(account.feeDueIn(usdc), expectedFee, "the fee settles one-for-one in the cash asset");

        uint256 before = IERC20(usdc).balanceOf(feeRecipient);
        account.payFees(usdc);

        assertEq(IERC20(usdc).balanceOf(feeRecipient) - before, expectedFee, "the fee reached the recipient");
        assertEq(account.lastFeePaid(), uint64(block.timestamp), "the fee clock caught up");
        assertEq(account.feeDue(), 0, "nothing is owed right after settling");
        assertEq(account.getNAV(), nav - expectedFee, "the fee came out of the account");
    }
}
