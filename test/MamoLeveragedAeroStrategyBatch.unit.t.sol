// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {MamoLeveragedAeroStrategy} from "@contracts/MamoLeveragedAeroStrategy.sol";
import {MamoLeveragedAeroStrategyFactory} from "@contracts/MamoLeveragedAeroStrategyFactory.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";

import {MockLeveragedAeroCLStrategy} from "./mocks/MockLeveragedAeroCLStrategy.sol";
import {MockSyndicateVault} from "./mocks/MockSyndicateVault.sol";
import {MockToken} from "./mocks/MockToken.sol";

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockSmartWallet
 * @notice Minimal stand-in for an EIP-5792 / ERC-4337 smart-contract wallet, modelling the one
 *         property that actually matters to the batched deposit path: the wallet CONTRACT is
 *         `msg.sender` for every leg, and the batch is all-or-nothing.
 *
 * @dev Declared in the test file rather than test/mocks/ deliberately — a `Mock*.sol` there matches
 *      neither `--skip s.sol` nor `--no-match-coverage t.sol`, so it would silently land in the
 *      coverage report (see the note above `coverage:` in the Makefile).
 */
contract MockSmartWallet {
    struct Call {
        address target;
        bytes data;
    }

    /// @notice Executes `calls` in order, bubbling the first failure so the whole batch reverts.
    function executeBatch(Call[] calldata calls) external {
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/**
 * @title Batched (sponsored) deposit calldata — MamoLeveragedAeroStrategy
 * @notice Fork-free suite proving the exact call sequence a smart wallet submits for a first-time
 *         Boosted USDC deposit, so the frontend and the paymaster policy can be built against a
 *         known-good batch rather than against a guess. Relates to BE-04 (paymaster policy) and
 *         FE-05 (deposit end-to-end).
 *
 *         The batch is three legs, all sent by the WALLET CONTRACT:
 *
 *           1. USDC.approve(account, assets)          <- to an address that does not exist yet
 *           2. factory.createStrategyForUser(wallet)  <- CREATE2, address fixed in advance
 *           3. account.deposit(assets, minShares)     <- pulls the USDC approved in leg 1
 *
 *         Leg 1 targeting a counterfactual address is the part that looks wrong and is not: an
 *         ERC-20 allowance is just a mapping entry, so it can be written before the spender has
 *         code, and it is still there when leg 3 runs. Getting this sequence wrong is the
 *         difference between a working sponsored deposit and a user-visible revert, which is why
 *         it is pinned here rather than discovered in manual QA.
 *
 *         Real sponsorship cannot be exercised on the QA vnet at all (Coinbase Smart Wallet runs
 *         its own bundler against real chains), so this suite covers everything EXCEPT the
 *         sponsorship layer itself.
 */
contract MamoLeveragedAeroStrategyBatchUnitTest is Test {
    event StrategyCreated(address indexed user, address indexed strategy);

    bytes32 public constant BACKEND_ROLE = keccak256("BACKEND_ROLE");

    address public admin = makeAddr("admin");
    address public backend = makeAddr("backend");
    address public guardian = makeAddr("guardian");

    MockToken public usdc;
    MockSyndicateVault public vault;
    MockLeveragedAeroCLStrategy public sherwood;
    MamoStrategyRegistry public registry;
    MamoLeveragedAeroStrategy public impl;
    MamoLeveragedAeroStrategyFactory public factory;
    MockSmartWallet public wallet;
    uint256 public typeId;

    /// @dev 1000 USDC (6dp) deposits to 1000 whole shares (12dp) at the mock's default par price.
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant EXPECTED_SHARES = 1_000e12;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        vault = new MockSyndicateVault();
        sherwood = new MockLeveragedAeroCLStrategy(address(vault), address(usdc));
        vault.setStrategy(address(sherwood));

        registry = new MamoStrategyRegistry(admin, backend, guardian);
        impl = new MamoLeveragedAeroStrategy();

        vm.prank(admin);
        typeId = registry.whitelistImplementation(address(impl), 0);

        factory = new MamoLeveragedAeroStrategyFactory(
            admin, backend, address(registry), address(impl), typeId, address(sherwood), address(usdc)
        );

        vm.prank(admin);
        registry.grantRole(BACKEND_ROLE, address(factory));

        wallet = new MockSmartWallet();
        usdc.mint(address(wallet), DEPOSIT);
    }

    // ==================== HELPERS ====================

    /// @notice The three legs of a first-time sponsored deposit, in submission order.
    function _firstDepositBatch(address account, uint256 assets, uint256 minShares)
        internal
        view
        returns (MockSmartWallet.Call[] memory calls)
    {
        calls = new MockSmartWallet.Call[](3);
        calls[0] =
            MockSmartWallet.Call({target: address(usdc), data: abi.encodeCall(IERC20.approve, (account, assets))});
        calls[1] = MockSmartWallet.Call({
            target: address(factory),
            data: abi.encodeCall(MamoLeveragedAeroStrategyFactory.createStrategyForUser, (address(wallet)))
        });
        calls[2] = MockSmartWallet.Call({
            target: account, data: abi.encodeCall(MamoLeveragedAeroStrategy.deposit, (assets, minShares))
        });
    }

    /// @dev The derivation an off-chain caller (frontend, paymaster policy) performs with nothing
    ///      but the factory address, the implementation address and the user address.
    function _predictAccount(address user) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(user));
        bytes memory bytecode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(impl), ""));
        return vm.computeCreate2Address(salt, keccak256(bytecode), address(factory));
    }

    // ==================== THE CANONICAL BATCH ====================

    /// @notice The whole point: approve → create → deposit, submitted as one batch by the wallet.
    function test_FirstDepositBatch_Succeeds() public {
        address account = factory.computeStrategyAddress(address(wallet));

        // The approve in leg 1 is written against an address with no code yet.
        assertEq(account.code.length, 0, "account should not exist before the batch");

        MockSmartWallet.Call[] memory calls = _firstDepositBatch(account, DEPOSIT, EXPECTED_SHARES);

        vm.expectEmit(true, true, false, false);
        emit StrategyCreated(address(wallet), account);
        wallet.executeBatch(calls);

        MamoLeveragedAeroStrategy created = MamoLeveragedAeroStrategy(payable(account));
        assertGt(account.code.length, 0, "account not deployed");
        assertEq(created.owner(), address(wallet), "wallet must own the account it funded");
        assertEq(created.sharesBalance(), EXPECTED_SHARES, "shares not custodied by the account");
        assertEq(usdc.balanceOf(address(wallet)), 0, "USDC not pulled from the wallet");
        assertEq(usdc.balanceOf(account), 0, "no USDC should sit idle in the account");
    }

    /// @notice Creating before approving works too — the legs are order-independent apart from
    ///         deposit going last. Worth pinning: wallets and SDKs assemble batches differently.
    function test_FirstDepositBatch_CreateBeforeApprove_AlsoSucceeds() public {
        address account = factory.computeStrategyAddress(address(wallet));

        MockSmartWallet.Call[] memory calls = new MockSmartWallet.Call[](3);
        calls[0] = MockSmartWallet.Call({
            target: address(factory),
            data: abi.encodeCall(MamoLeveragedAeroStrategyFactory.createStrategyForUser, (address(wallet)))
        });
        calls[1] =
            MockSmartWallet.Call({target: address(usdc), data: abi.encodeCall(IERC20.approve, (account, DEPOSIT))});
        calls[2] = MockSmartWallet.Call({
            target: account, data: abi.encodeCall(MamoLeveragedAeroStrategy.deposit, (DEPOSIT, EXPECTED_SHARES))
        });

        wallet.executeBatch(calls);
        assertEq(MamoLeveragedAeroStrategy(payable(account)).sharesBalance(), EXPECTED_SHARES);
    }

    /// @notice A returning user's batch is two legs — the account already exists, and re-running the
    ///         create leg would revert the whole batch.
    function test_SecondDepositBatch_OmitsCreateLeg() public {
        address account = factory.computeStrategyAddress(address(wallet));
        wallet.executeBatch(_firstDepositBatch(account, DEPOSIT, EXPECTED_SHARES));

        usdc.mint(address(wallet), DEPOSIT);
        MockSmartWallet.Call[] memory calls = new MockSmartWallet.Call[](2);
        calls[0] =
            MockSmartWallet.Call({target: address(usdc), data: abi.encodeCall(IERC20.approve, (account, DEPOSIT))});
        calls[1] = MockSmartWallet.Call({
            target: account, data: abi.encodeCall(MamoLeveragedAeroStrategy.deposit, (DEPOSIT, EXPECTED_SHARES))
        });

        wallet.executeBatch(calls);
        assertEq(MamoLeveragedAeroStrategy(payable(account)).sharesBalance(), 2 * EXPECTED_SHARES);
    }

    // ==================== FAILURE MODES THE FRONTEND CAN HIT ====================

    /// @notice THE DANGEROUS ONE. Omitting the create leg on a first-time deposit does NOT revert —
    ///         the transaction succeeds and silently does nothing. A raw `call` to an address with
    ///         no code returns success with empty returndata, and wallets batch with raw calls (the
    ///         `extcodesize` check that would catch this is inserted by Solidity's high-level call
    ///         syntax, which is not in the path). The user gets a green transaction, no shares, and
    ///         their USDC still in the wallet.
    ///
    ///         So the frontend cannot rely on a revert to tell it the account was missing: it MUST
    ///         branch on `account.code.length == 0` and include the create leg itself. Sponsorship
    ///         makes this worse, not better — the paymaster pays for the empty transaction too.
    function test_FirstDepositBatch_WithoutCreateLeg_SilentlyNoOps() public {
        address account = factory.computeStrategyAddress(address(wallet));

        MockSmartWallet.Call[] memory calls = new MockSmartWallet.Call[](2);
        calls[0] =
            MockSmartWallet.Call({target: address(usdc), data: abi.encodeCall(IERC20.approve, (account, DEPOSIT))});
        calls[1] = MockSmartWallet.Call({
            target: account, data: abi.encodeCall(MamoLeveragedAeroStrategy.deposit, (DEPOSIT, EXPECTED_SHARES))
        });

        wallet.executeBatch(calls); // succeeds

        assertEq(account.code.length, 0, "no account was created");
        assertEq(usdc.balanceOf(address(wallet)), DEPOSIT, "USDC never moved");
        assertEq(usdc.allowance(address(wallet), account), DEPOSIT, "a dangling allowance is all that is left");
    }

    /// @notice Re-running the create leg for an existing account reverts the batch, which is why the
    ///         frontend has to branch on `account.code.length` rather than always including it.
    function test_CreateLeg_OnExistingAccount_RevertsBatch() public {
        address account = factory.computeStrategyAddress(address(wallet));
        wallet.executeBatch(_firstDepositBatch(account, DEPOSIT, EXPECTED_SHARES));

        usdc.mint(address(wallet), DEPOSIT);
        vm.expectRevert("Strategy already exists");
        wallet.executeBatch(_firstDepositBatch(account, DEPOSIT, EXPECTED_SHARES));
    }

    /// @notice A too-tight minShares reverts the deposit and therefore unwinds the account creation
    ///         — no orphan account is left registered for a batch that failed.
    function test_DepositLegFailure_UnwindsAccountCreation() public {
        address account = factory.computeStrategyAddress(address(wallet));

        vm.expectRevert();
        wallet.executeBatch(_firstDepositBatch(account, DEPOSIT, EXPECTED_SHARES + 1));

        assertEq(account.code.length, 0, "failed batch must not leave an account behind");
        assertEq(usdc.balanceOf(address(wallet)), DEPOSIT);
    }

    /// @notice Approving the wrong address (a mis-derived account) fails closed at the deposit leg.
    function test_ApproveToWrongAccount_RevertsBatch() public {
        address account = factory.computeStrategyAddress(address(wallet));
        address wrong = makeAddr("wrongAccount");

        MockSmartWallet.Call[] memory calls = _firstDepositBatch(account, DEPOSIT, EXPECTED_SHARES);
        calls[0] = MockSmartWallet.Call({target: address(usdc), data: abi.encodeCall(IERC20.approve, (wrong, DEPOSIT))});

        vm.expectRevert();
        wallet.executeBatch(calls);
        assertEq(usdc.balanceOf(address(wallet)), DEPOSIT);
    }

    // ==================== WHAT THE PAYMASTER POLICY CAN RELY ON ====================

    /// @notice The account address is derivable off-chain from (factory, implementation, user) alone,
    ///         before it is deployed. That is what lets a paymaster policy be a RULE
    ///         (`to == computeStrategyAddress(sender)`) instead of an allowlist that grows per user.
    function test_AccountAddressIsDerivableOffChain() public {
        address predicted = _predictAccount(address(wallet));
        assertEq(predicted, factory.computeStrategyAddress(address(wallet)), "off-chain derivation diverged");

        wallet.executeBatch(_firstDepositBatch(predicted, DEPOSIT, EXPECTED_SHARES));
        assertGt(predicted.code.length, 0, "predicted address is where the account actually landed");
    }

    /// @notice Distinct users get distinct accounts, so a per-sender rule cannot be shared or reused.
    function test_AccountAddressIsPerUser() public {
        MockSmartWallet other = new MockSmartWallet();
        assertTrue(
            factory.computeStrategyAddress(address(wallet)) != factory.computeStrategyAddress(address(other)),
            "accounts must not collide across users"
        );
    }

    /// @notice A wallet cannot create — and therefore cannot get a sponsored call routed to — an
    ///         account owned by somebody else. The factory gate is `backend || msg.sender == user`.
    function test_WalletCannotCreateAccountForAnotherUser() public {
        MockSmartWallet other = new MockSmartWallet();

        MockSmartWallet.Call[] memory calls = new MockSmartWallet.Call[](1);
        calls[0] = MockSmartWallet.Call({
            target: address(factory),
            data: abi.encodeCall(MamoLeveragedAeroStrategyFactory.createStrategyForUser, (address(other)))
        });

        vm.expectRevert("Only backend or user can create strategy");
        wallet.executeBatch(calls);
    }

    /// @notice The backend can still pre-create an account for a user, which leaves the wallet's
    ///         batch as the two-leg returning-user shape.
    function test_BackendPreCreatedAccount_LeavesTwoLegBatch() public {
        vm.prank(backend);
        address account = factory.createStrategyForUser(address(wallet));

        MockSmartWallet.Call[] memory calls = new MockSmartWallet.Call[](2);
        calls[0] =
            MockSmartWallet.Call({target: address(usdc), data: abi.encodeCall(IERC20.approve, (account, DEPOSIT))});
        calls[1] = MockSmartWallet.Call({
            target: account, data: abi.encodeCall(MamoLeveragedAeroStrategy.deposit, (DEPOSIT, EXPECTED_SHARES))
        });

        wallet.executeBatch(calls);
        MamoLeveragedAeroStrategy created = MamoLeveragedAeroStrategy(payable(account));
        assertEq(created.owner(), address(wallet), "backend pre-creation must still leave the user as owner");
        assertEq(created.sharesBalance(), EXPECTED_SHARES);
    }

    // ==================== HAND-OFF ====================

    /// @notice Prints the batch the frontend should produce, so BE/FE can diff their encoder against
    ///         a sequence this suite proves works. Run with:
    ///         forge test --match-test test_PrintFirstDepositBatchCalldata -vv
    function test_PrintFirstDepositBatchCalldata() public view {
        address account = factory.computeStrategyAddress(address(wallet));
        MockSmartWallet.Call[] memory calls = _firstDepositBatch(account, DEPOSIT, EXPECTED_SHARES);

        console.log("--- first-time sponsored deposit batch (sender = the smart wallet) ---");
        console.log("wallet (sender) ", address(wallet));
        console.log("factory         ", address(factory));
        console.log("implementation  ", address(impl));
        console.log("account (CREATE2)", account);
        for (uint256 i; i < calls.length; ++i) {
            console.log("leg", i, "target", calls[i].target);
            console.logBytes(calls[i].data);
        }
    }
}
