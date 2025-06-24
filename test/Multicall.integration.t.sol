// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {Multicall} from "@contracts/Multicall.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockTargetContract
 * @notice Mock contract for testing multicall functionality
 */
contract MockTargetContract {
    uint256 public value;
    uint256 public receivedETH;
    bool public shouldFail;
    string public failureReason;

    function setValue(uint256 _value) external payable {
        if (shouldFail) {
            revert(failureReason);
        }
        value = _value;
        receivedETH += msg.value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function setFailure(bool _shouldFail, string memory _reason) external {
        shouldFail = _shouldFail;
        failureReason = _reason;
    }

    receive() external payable {
        receivedETH += msg.value;
    }
}

/**
 * @title MulticallIntegrationTest
 * @notice Integration tests for Multicall contract
 */
contract MulticallIntegrationTest is Test {
    Multicall public multicall;
    MockTargetContract public target1;
    MockTargetContract public target2;
    MockTargetContract public target3;

    address public owner;
    address public nonOwner;
    address public newOwner;

    event MulticallExecuted(address indexed initiator, uint256 callsCount);

    function setUp() public {
        owner = makeAddr("owner");
        nonOwner = makeAddr("nonOwner");
        newOwner = makeAddr("newOwner");

        // Deploy contracts
        multicall = new Multicall(owner);
        target1 = new MockTargetContract();
        target2 = new MockTargetContract();
        target3 = new MockTargetContract();

        // Give addresses some ETH for payable tests
        vm.deal(owner, 10 ether);
        vm.deal(nonOwner, 10 ether);
        vm.deal(newOwner, 10 ether);

        // Label contracts for better test output
        vm.label(address(multicall), "Multicall");
        vm.label(address(target1), "Target1");
        vm.label(address(target2), "Target2");
        vm.label(address(target3), "Target3");
        vm.label(owner, "Owner");
        vm.label(nonOwner, "NonOwner");
        vm.label(newOwner, "NewOwner");
    }

    /* ============ CONSTRUCTOR TESTS ============ */

    function testConstructor_Success() public {
        address testOwner = makeAddr("testOwner");
        Multicall testMulticall = new Multicall(testOwner);

        assertEq(testMulticall.owner(), testOwner, "Owner should be set correctly");
    }

    function testConstructor_ZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Multicall(address(0));
    }

    /* ============ OWNERSHIP TESTS ============ */

    function testRenounceOwnership_Reverts() public {
        // Should revert when called by owner
        vm.expectRevert("Multicall: Ownership cannot be revoked");
        vm.prank(owner);
        multicall.renounceOwnership();

        // Should revert when called by non-owner
        vm.expectRevert("Multicall: Ownership cannot be revoked");
        vm.prank(nonOwner);
        multicall.renounceOwnership();
    }

    function testTransferOwnership_Success() public {
        vm.prank(owner);
        multicall.transferOwnership(newOwner);

        assertEq(multicall.owner(), newOwner, "Ownership should be transferred");
    }

    function testTransferOwnership_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        multicall.transferOwnership(newOwner);
    }

    function testTransferOwnership_ZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        vm.prank(owner);
        multicall.transferOwnership(address(0));
    }

    /* ============ MULTICALL FUNCTIONALITY TESTS ============ */

    function testMulticall_Success() public {
        Multicall.Call[] memory calls = new Multicall.Call[](3);

        calls[0] = Multicall.Call({
            target: address(target1),
            data: abi.encodeWithSignature("setValue(uint256)", 100),
            value: 0
        });

        calls[1] = Multicall.Call({
            target: address(target2),
            data: abi.encodeWithSignature("setValue(uint256)", 200),
            value: 0
        });

        calls[2] = Multicall.Call({
            target: address(target3),
            data: abi.encodeWithSignature("setValue(uint256)", 300),
            value: 0
        });

        vm.expectEmit(true, false, false, true);
        emit MulticallExecuted(owner, 3);

        vm.prank(owner);
        multicall.multicall(calls);

        assertEq(target1.getValue(), 100, "Target1 value should be set");
        assertEq(target2.getValue(), 200, "Target2 value should be set");
        assertEq(target3.getValue(), 300, "Target3 value should be set");
    }

    function testMulticall_WithETH() public {
        Multicall.Call[] memory calls = new Multicall.Call[](2);

        calls[0] = Multicall.Call({
            target: address(target1),
            data: abi.encodeWithSignature("setValue(uint256)", 100),
            value: 1 ether
        });

        calls[1] = Multicall.Call({
            target: address(target2),
            data: abi.encodeWithSignature("setValue(uint256)", 200),
            value: 2 ether
        });

        vm.prank(owner);
        multicall.multicall{value: 3 ether}(calls);

        assertEq(target1.getValue(), 100, "Target1 value should be set");
        assertEq(target2.getValue(), 200, "Target2 value should be set");
        assertEq(target1.receivedETH(), 1 ether, "Target1 should receive 1 ETH");
        assertEq(target2.receivedETH(), 2 ether, "Target2 should receive 2 ETH");
    }

    function testMulticall_ExcessETHRefund() public {
        Multicall.Call[] memory calls = new Multicall.Call[](1);

        calls[0] = Multicall.Call({
            target: address(target1),
            data: abi.encodeWithSignature("setValue(uint256)", 100),
            value: 1 ether
        });

        uint256 initialBalance = owner.balance;

        vm.prank(owner);
        multicall.multicall{value: 2 ether}(calls);

        // Should refund 1 ether (2 ether sent - 1 ether used)
        assertEq(owner.balance, initialBalance - 1 ether, "Owner should be refunded excess ETH");
        assertEq(target1.receivedETH(), 1 ether, "Target1 should receive 1 ETH");
    }

    function testMulticall_EmptyCallsArray() public {
        Multicall.Call[] memory calls = new Multicall.Call[](0);

        vm.expectRevert("Multicall: Empty calls array");
        vm.prank(owner);
        multicall.multicall(calls);
    }

    function testMulticall_ZeroTargetAddress() public {
        Multicall.Call[] memory calls = new Multicall.Call[](1);

        calls[0] = Multicall.Call({
            target: address(0),
            data: abi.encodeWithSignature("setValue(uint256)", 100),
            value: 0
        });

        vm.expectRevert("Multicall: Invalid target address");
        vm.prank(owner);
        multicall.multicall(calls);
    }

    function testMulticall_InsufficientETH() public {
        Multicall.Call[] memory calls = new Multicall.Call[](1);

        calls[0] = Multicall.Call({
            target: address(target1),
            data: abi.encodeWithSignature("setValue(uint256)", 100),
            value: 2 ether
        });

        vm.expectRevert("Multicall: Insufficient ETH provided");
        vm.prank(owner);
        multicall.multicall{value: 1 ether}(calls);
    }

    function testMulticall_CallFailure() public {
        // Set target1 to fail
        target1.setFailure(true, "Intentional failure");

        Multicall.Call[] memory calls = new Multicall.Call[](1);

        calls[0] = Multicall.Call({
            target: address(target1),
            data: abi.encodeWithSignature("setValue(uint256)", 100),
            value: 0
        });

        vm.expectRevert("Intentional failure");
        vm.prank(owner);
        multicall.multicall(calls);
    }

    function testMulticall_OnlyOwner() public {
        Multicall.Call[] memory calls = new Multicall.Call[](1);

        calls[0] = Multicall.Call({
            target: address(target1),
            data: abi.encodeWithSignature("setValue(uint256)", 100),
            value: 0
        });

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        multicall.multicall(calls);
    }

    /* ============ REENTRANCY PROTECTION TESTS ============ */

    function testMulticall_ReentrancyProtection() public {
        // Create a malicious contract that tries to reenter
        MaliciousReentrantContract malicious = new MaliciousReentrantContract(address(multicall));

        // Transfer ownership to the malicious contract
        vm.prank(owner);
        multicall.transferOwnership(address(malicious));

        // Try to trigger reentrancy
        vm.prank(address(malicious));
        multicall.multicall(new Multicall.Call[](1));

        // The reentrancy should be prevented
        assertFalse(malicious.attackExecuted(), "Reentrancy attack should be prevented");
    }
}

/**
 * @title MaliciousReentrantContract
 * @notice Contract that attempts reentrancy attacks
 */
contract MaliciousReentrantContract {
    Multicall public immutable multicall;
    bool public attackExecuted;

    constructor(address _multicall) {
        multicall = Multicall(payable(_multicall));
    }

    function multicall(Multicall.Call[] calldata calls) external {
        if (!attackExecuted) {
            attackExecuted = true;
            // Try to call back into the multicall during execution
            multicall.multicall(calls);
        }
    }
} 