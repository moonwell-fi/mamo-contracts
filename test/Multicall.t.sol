// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Multicall} from "@contracts/Multicall.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMulticall} from "@contracts/interfaces/IMulticall.sol";
import {IStrategy} from "@contracts/interfaces/IStrategy.sol";
import "@forge-std/Test.sol";

/**
 * @title MockStrategy
 * @notice Mock strategy contract for testing purposes
 */
contract MockStrategy is IStrategy {
    uint256 public splitA;
    uint256 public splitB;
    bool public shouldFail;
    string public failureReason;
    address public immutable owner;
    address public immutable mamoCore;

    constructor(address _owner, address _mamoCore) {
        owner = _owner;
        mamoCore = _mamoCore;
    }

    function updatePosition(uint256 _splitA, uint256 _splitB) external override {
        if (shouldFail) {
            revert(failureReason);
        }
        splitA = _splitA;
        splitB = _splitB;
    }

    function deposit(address, uint256) external pure override {
        revert("Not implemented");
    }

    function withdraw(address, uint256) external pure override {
        revert("Not implemented");
    }

    function claimRewards() external pure override {
        revert("Not implemented");
    }

    // Test helper functions
    function setFailure(bool _shouldFail, string memory _reason) external {
        shouldFail = _shouldFail;
        failureReason = _reason;
    }

    function getCurrentSplit() external view returns (uint256, uint256) {
        return (splitA, splitB);
    }
}

/**
 * @title MockPayableContract
 * @notice Mock contract that can receive ETH for testing
 */
contract MockPayableContract {
    uint256 public value1;
    uint256 public value2;
    uint256 public receivedETH;

    function setValue1(uint256 _value) external payable {
        value1 = _value;
        receivedETH += msg.value;
    }

    function setValue2(uint256 _value) external payable {
        value2 = _value;
        receivedETH += msg.value;
    }

    function failingFunction() external pure {
        revert("MockPayableContract: Intentional failure");
    }

    receive() external payable {
        receivedETH += msg.value;
    }
}

/**
 * @title MulticallTest
 * @notice Comprehensive test suite for Multicall contract
 */
contract MulticallTest is Test {
    Multicall public multicall;
    MockStrategy public strategy1;
    MockStrategy public strategy2;
    MockStrategy public strategy3;
    MockPayableContract public payableContract1;
    MockPayableContract public payableContract2;

    address public strategyOwner = makeAddr("strategyOwner");
    address public mamoCore = makeAddr("mamoCore");
    address public multicallOwner = makeAddr("multicallOwner");
    address public nonOwner = makeAddr("nonOwner");

    // Test parameters
    uint256 public constant SPLIT_MOONWELL = 6000; // 60%
    uint256 public constant SPLIT_MORPHO = 4000; // 40%

    event MulticallExecuted(address indexed initiator, uint256 callsCount);

    function setUp() public {
        // Deploy contracts
        multicall = new Multicall(multicallOwner);
        strategy1 = new MockStrategy(strategyOwner, mamoCore);
        strategy2 = new MockStrategy(strategyOwner, mamoCore);
        strategy3 = new MockStrategy(strategyOwner, mamoCore);
        payableContract1 = new MockPayableContract();
        payableContract2 = new MockPayableContract();

        // Give multicallOwner and nonOwner some ETH for payable tests
        vm.deal(multicallOwner, 10 ether);
        vm.deal(nonOwner, 10 ether);

        // Label contracts for better test output
        vm.label(address(multicall), "Multicall");
        vm.label(address(strategy1), "Strategy1");
        vm.label(address(strategy2), "Strategy2");
        vm.label(address(strategy3), "Strategy3");
        vm.label(address(payableContract1), "PayableContract1");
        vm.label(address(payableContract2), "PayableContract2");
        vm.label(multicallOwner, "MulticallOwner");
        vm.label(nonOwner, "NonOwner");
    }

    /* ============ CONSTRUCTOR AND OWNERSHIP TESTS ============ */

    function testConstructor_Success() public {
        address owner = makeAddr("testOwner");
        Multicall testMulticall = new Multicall(owner);

        assertEq(testMulticall.owner(), owner, "Owner should be set correctly");
    }

    function testConstructor_ZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Multicall(address(0));
    }

    function testOwnership_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(multicallOwner);
        multicall.transferOwnership(newOwner);

        assertEq(multicall.owner(), newOwner, "Ownership should be transferred");
    }

    function testOwnership_OnlyOwnerCanTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        multicall.transferOwnership(newOwner);
    }

    /* ============ ACCESS CONTROL TESTS ============ */

    function testAccessControl_GenericMulticall() public {
        Multicall.Call[] memory calls = new Multicall.Call[](1);
        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        // Should fail when called by non-owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        multicall.multicall(calls);

        // Should succeed when called by owner
        vm.prank(multicallOwner);
        multicall.multicall(calls);
    }

    /* ============ GENERIC MULTICALL TESTS ============ */

    function testGenericMulticall_Success() public {
        Multicall.Call[] memory calls = new Multicall.Call[](3);

        // First call: updatePosition on strategy1
        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        // Second call: setValue1 on payableContract1 with ETH
        calls[1] = Multicall.Call({
            target: address(payableContract1),
            data: abi.encodeWithSignature("setValue1(uint256)", 100),
            value: 1 ether
        });

        // Third call: setValue2 on payableContract2
        calls[2] = Multicall.Call({
            target: address(payableContract2),
            data: abi.encodeWithSignature("setValue2(uint256)", 200),
            value: 0
        });

        vm.expectEmit(true, false, false, true);
        emit MulticallExecuted(multicallOwner, 3);

        vm.prank(multicallOwner);
        multicall.multicall{value: 1 ether}(calls);

        // Verify results
        (uint256 splitA, uint256 splitB) = strategy1.getCurrentSplit();
        assertEq(splitA, SPLIT_MOONWELL, "Strategy1 splitA incorrect");
        assertEq(splitB, SPLIT_MORPHO, "Strategy1 splitB incorrect");
        assertEq(payableContract1.value1(), 100, "PayableContract1 value1 incorrect");
        assertEq(payableContract1.receivedETH(), 1 ether, "PayableContract1 should receive ETH");
        assertEq(payableContract2.value2(), 200, "PayableContract2 value2 incorrect");
    }

    function testGenericMulticall_EmptyArray() public {
        Multicall.Call[] memory calls = new Multicall.Call[](0);

        vm.expectRevert("Multicall: Empty calls array");
        vm.prank(multicallOwner);
        multicall.multicall(calls);
    }

    function testGenericMulticall_InvalidTarget() public {
        Multicall.Call[] memory calls = new Multicall.Call[](1);
        calls[0] = Multicall.Call({
            target: address(0),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        vm.expectRevert("Multicall: Invalid target address");
        vm.prank(multicallOwner);
        multicall.multicall(calls);
    }

    function testGenericMulticall_CallFailure() public {
        Multicall.Call[] memory calls = new Multicall.Call[](2);

        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        calls[1] = Multicall.Call({
            target: address(payableContract1),
            data: abi.encodeWithSignature("failingFunction()"),
            value: 0
        });

        vm.expectRevert("MockPayableContract: Intentional failure");
        vm.prank(multicallOwner);
        multicall.multicall(calls);

        // Verify that strategy1 was NOT updated due to revert (all state changes are reverted)
        (uint256 splitA, uint256 splitB) = strategy1.getCurrentSplit();
        assertEq(splitA, 0, "Strategy1 should not be updated due to revert");
        assertEq(splitB, 0, "Strategy1 should not be updated due to revert");
    }

    function testGenericMulticall_MultipleStrategies() public {
        Multicall.Call[] memory calls = new Multicall.Call[](3);

        // Update multiple strategies using multicall
        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        calls[1] = Multicall.Call({
            target: address(strategy2),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        calls[2] = Multicall.Call({
            target: address(strategy3),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        vm.expectEmit(true, false, false, true);
        emit MulticallExecuted(multicallOwner, 3);

        vm.prank(multicallOwner);
        multicall.multicall(calls);

        // Verify all strategies were updated
        (uint256 split1A, uint256 split1B) = strategy1.getCurrentSplit();
        (uint256 split2A, uint256 split2B) = strategy2.getCurrentSplit();
        (uint256 split3A, uint256 split3B) = strategy3.getCurrentSplit();

        assertEq(split1A, SPLIT_MOONWELL, "Strategy1 splitA incorrect");
        assertEq(split1B, SPLIT_MORPHO, "Strategy1 splitB incorrect");
        assertEq(split2A, SPLIT_MOONWELL, "Strategy2 splitA incorrect");
        assertEq(split2B, SPLIT_MORPHO, "Strategy2 splitB incorrect");
        assertEq(split3A, SPLIT_MOONWELL, "Strategy3 splitA incorrect");
        assertEq(split3B, SPLIT_MORPHO, "Strategy3 splitB incorrect");
    }

    /* ============ EDGE CASES AND INTEGRATION TESTS ============ */

    function testGenericMulticall_ZeroSplits() public {
        Multicall.Call[] memory calls = new Multicall.Call[](1);
        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", 0, 0),
            value: 0
        });

        vm.prank(multicallOwner);
        multicall.multicall(calls);

        (uint256 splitA, uint256 splitB) = strategy1.getCurrentSplit();
        assertEq(splitA, 0, "Strategy splitA should be 0");
        assertEq(splitB, 0, "Strategy splitB should be 0");
    }

    function testGenericMulticall_MaxSplits() public {
        uint256 maxSplit = type(uint256).max;

        Multicall.Call[] memory calls = new Multicall.Call[](1);
        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", maxSplit, maxSplit),
            value: 0
        });

        vm.prank(multicallOwner);
        multicall.multicall(calls);

        (uint256 splitA, uint256 splitB) = strategy1.getCurrentSplit();
        assertEq(splitA, maxSplit, "Strategy splitA should be max");
        assertEq(splitB, maxSplit, "Strategy splitB should be max");
    }

    function testLargeScale_GenericMulticall() public {
        // Test with a larger number of strategies
        uint256 strategyCount = 50;
        Multicall.Call[] memory calls = new Multicall.Call[](strategyCount);

        for (uint256 i = 0; i < strategyCount; i++) {
            address strategyAddr = address(new MockStrategy(strategyOwner, mamoCore));
            calls[i] = Multicall.Call({
                target: strategyAddr,
                data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
                value: 0
            });
        }

        vm.expectEmit(true, false, false, true);
        emit MulticallExecuted(multicallOwner, strategyCount);

        vm.prank(multicallOwner);
        multicall.multicall(calls);

        // Spot check a few strategies
        MockStrategy firstStrategy = MockStrategy(calls[0].target);
        MockStrategy lastStrategy = MockStrategy(calls[strategyCount - 1].target);

        (uint256 split1A, uint256 split1B) = firstStrategy.getCurrentSplit();
        (uint256 split2A, uint256 split2B) = lastStrategy.getCurrentSplit();

        assertEq(split1A, SPLIT_MOONWELL, "First strategy incorrect");
        assertEq(split1B, SPLIT_MORPHO, "First strategy incorrect");
        assertEq(split2A, SPLIT_MOONWELL, "Last strategy incorrect");
        assertEq(split2B, SPLIT_MORPHO, "Last strategy incorrect");
    }

    /* ============ FUZZ TESTS ============ */

    function testFuzz_multicall(uint256 splitMoonwell, uint256 splitMorpho, uint8 strategyCount) public {
        // Bound inputs to reasonable values
        strategyCount = uint8(bound(strategyCount, 1, 20));
        splitMoonwell = bound(splitMoonwell, 0, type(uint128).max);
        splitMorpho = bound(splitMorpho, 0, type(uint128).max);

        // Create calls array
        Multicall.Call[] memory calls = new Multicall.Call[](strategyCount);
        for (uint256 i = 0; i < strategyCount; i++) {
            address strategyAddr = address(new MockStrategy(strategyOwner, mamoCore));
            calls[i] = Multicall.Call({
                target: strategyAddr,
                data: abi.encodeWithSignature("updatePosition(uint256,uint256)", splitMoonwell, splitMorpho),
                value: 0
            });
        }

        vm.prank(multicallOwner);
        multicall.multicall(calls);

        // Verify all strategies were updated correctly
        for (uint256 i = 0; i < strategyCount; i++) {
            MockStrategy strategy = MockStrategy(calls[i].target);
            (uint256 actualSplitA, uint256 actualSplitB) = strategy.getCurrentSplit();
            assertEq(actualSplitA, splitMoonwell, "Fuzz: splitA incorrect");
            assertEq(actualSplitB, splitMorpho, "Fuzz: splitB incorrect");
        }
    }

    /* ============ ETH VALIDATION AND REFUND TESTS ============ */

    function testETHValidation_ExactAmount() public {
        Multicall.Call[] memory calls = new Multicall.Call[](2);

        calls[0] = Multicall.Call({
            target: address(payableContract1),
            data: abi.encodeWithSignature("setValue1(uint256)", 100),
            value: 1 ether
        });

        calls[1] = Multicall.Call({
            target: address(payableContract2),
            data: abi.encodeWithSignature("setValue2(uint256)", 200),
            value: 0.5 ether
        });

        uint256 initialBalance = multicallOwner.balance;

        vm.prank(multicallOwner);
        multicall.multicall{value: 1.5 ether}(calls);

        // Verify contracts received the correct amounts
        assertEq(payableContract1.receivedETH(), 1 ether, "Contract1 should receive 1 ether");
        assertEq(payableContract2.receivedETH(), 0.5 ether, "Contract2 should receive 0.5 ether");

        // Verify no refund (exact amount provided)
        assertEq(multicallOwner.balance, initialBalance - 1.5 ether, "Owner should pay exactly 1.5 ether");
    }

    function testETHValidation_ExcessAmount() public {
        Multicall.Call[] memory calls = new Multicall.Call[](2);

        calls[0] = Multicall.Call({
            target: address(payableContract1),
            data: abi.encodeWithSignature("setValue1(uint256)", 100),
            value: 1 ether
        });

        calls[1] = Multicall.Call({
            target: address(payableContract2),
            data: abi.encodeWithSignature("setValue2(uint256)", 200),
            value: 0.5 ether
        });

        uint256 initialBalance = multicallOwner.balance;

        vm.prank(multicallOwner);
        multicall.multicall{value: 2 ether}(calls); // Sending 2 ether for 1.5 ether worth of calls

        // Verify contracts received the correct amounts
        assertEq(payableContract1.receivedETH(), 1 ether, "Contract1 should receive 1 ether");
        assertEq(payableContract2.receivedETH(), 0.5 ether, "Contract2 should receive 0.5 ether");

        // Verify refund of excess 0.5 ether
        assertEq(
            multicallOwner.balance, initialBalance - 1.5 ether, "Owner should only pay 1.5 ether (0.5 ether refunded)"
        );
    }

    function testETHValidation_InsufficientAmount() public {
        Multicall.Call[] memory calls = new Multicall.Call[](2);

        calls[0] = Multicall.Call({
            target: address(payableContract1),
            data: abi.encodeWithSignature("setValue1(uint256)", 100),
            value: 1 ether
        });

        calls[1] = Multicall.Call({
            target: address(payableContract2),
            data: abi.encodeWithSignature("setValue2(uint256)", 200),
            value: 0.5 ether
        });

        uint256 initialBalance = multicallOwner.balance;

        // Try to send only 1 ether for 1.5 ether worth of calls
        vm.expectRevert("Multicall: Insufficient ETH provided");
        vm.prank(multicallOwner);
        multicall.multicall{value: 1 ether}(calls);

        // Verify no state changes occurred
        assertEq(payableContract1.receivedETH(), 0, "Contract1 should not receive any ETH");
        assertEq(payableContract2.receivedETH(), 0, "Contract2 should not receive any ETH");
        assertEq(multicallOwner.balance, initialBalance, "Owner balance should be unchanged");
    }

    function testETHValidation_ZeroValueCalls() public {
        Multicall.Call[] memory calls = new Multicall.Call[](2);

        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        calls[1] = Multicall.Call({
            target: address(strategy2),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        uint256 initialBalance = multicallOwner.balance;

        vm.prank(multicallOwner);
        multicall.multicall{value: 1 ether}(calls); // Sending excess ETH for zero-value calls

        // Verify strategies were updated
        (uint256 split1A, uint256 split1B) = strategy1.getCurrentSplit();
        (uint256 split2A, uint256 split2B) = strategy2.getCurrentSplit();
        assertEq(split1A, SPLIT_MOONWELL, "Strategy1 should be updated");
        assertEq(split2A, SPLIT_MOONWELL, "Strategy2 should be updated");
        assertEq(split1B, SPLIT_MORPHO, "Strategy1 should be updated");
        assertEq(split2B, SPLIT_MORPHO, "Strategy2 should be updated");

        // Verify full refund (all calls had zero value)
        assertEq(multicallOwner.balance, initialBalance, "Owner should get full refund");
    }

    function testETHValidation_MixedValueCalls() public {
        Multicall.Call[] memory calls = new Multicall.Call[](3);

        calls[0] = Multicall.Call({
            target: address(strategy1),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        calls[1] = Multicall.Call({
            target: address(payableContract1),
            data: abi.encodeWithSignature("setValue1(uint256)", 100),
            value: 0.3 ether
        });

        calls[2] = Multicall.Call({
            target: address(strategy2),
            data: abi.encodeWithSignature("updatePosition(uint256,uint256)", SPLIT_MOONWELL, SPLIT_MORPHO),
            value: 0
        });

        uint256 initialBalance = multicallOwner.balance;

        vm.prank(multicallOwner);
        multicall.multicall{value: 1 ether}(calls); // Sending 1 ether for 0.3 ether worth of calls

        // Verify strategies were updated
        (uint256 split1A, uint256 split1B) = strategy1.getCurrentSplit();
        (uint256 split2A, uint256 split2B) = strategy2.getCurrentSplit();
        assertEq(split1A, SPLIT_MOONWELL, "Strategy1 should be updated");
        assertEq(split2A, SPLIT_MOONWELL, "Strategy2 should be updated");
        assertEq(split1B, SPLIT_MORPHO, "Strategy1 should be updated");
        assertEq(split2B, SPLIT_MORPHO, "Strategy2 should be updated");

        // Verify payable contract received ETH
        assertEq(payableContract1.receivedETH(), 0.3 ether, "PayableContract should receive 0.3 ether");

        // Verify refund of excess 0.7 ether
        assertEq(
            multicallOwner.balance, initialBalance - 0.3 ether, "Owner should only pay 0.3 ether (0.7 ether refunded)"
        );
    }
}
