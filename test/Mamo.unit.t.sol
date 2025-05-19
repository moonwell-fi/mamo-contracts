// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "@forge-std/Test.sol";

import {IERC7802} from "@contracts/interfaces/IERC7802.sol";
import {MAMO} from "@contracts/token/Mamo.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MamoUnitTest is Test {
    MAMO public mamo;
    address public recipient;
    address public superchainTokenBridge;

    // Constants
    string public constant NAME = "MAMO";
    string public constant SYMBOL = "MAMO";
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    function setUp() public {
        recipient = makeAddr("recipient");
        superchainTokenBridge = 0x4200000000000000000000000000000000000028;

        // Deploy non-upgradeable contract directly with constructor parameters
        mamo = new MAMO(NAME, SYMBOL, recipient);

        vm.label(address(mamo), "MAMO");
        vm.label(recipient, "Recipient");
        vm.label(superchainTokenBridge, "Superchain Token Bridge");
    }

    function testInitialization() public view {
        assertEq(mamo.name(), NAME, "incorrect name");
        assertEq(mamo.symbol(), SYMBOL, "incorrect symbol");
        assertEq(mamo.totalSupply(), MAX_SUPPLY, "incorrect total supply");
        assertEq(mamo.balanceOf(recipient), MAX_SUPPLY, "incorrect recipient balance");
        assertEq(mamo.decimals(), 18, "incorrect decimals");
    }

    function testSupportsInterface() public view {
        assertTrue(mamo.supportsInterface(type(IERC7802).interfaceId), "should support IERC7802");
        assertTrue(mamo.supportsInterface(type(IERC20).interfaceId), "should support IERC20");
        assertTrue(mamo.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
        assertFalse(mamo.supportsInterface(bytes4(0xffffffff)), "should not support random interface");
    }

    function testCrosschainMintUnauthorizedFails() public {
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(MAMO.NotSuperchainTokenBridge.selector);
        mamo.crosschainMint(recipient, 100);
    }

    function testCrosschainMintAuthorizedSucceeds() public {
        uint256 initialBalance = mamo.balanceOf(recipient);
        uint256 initialTotalSupply = mamo.totalSupply();
        uint256 mintAmount = 100;

        vm.prank(superchainTokenBridge);
        mamo.crosschainMint(recipient, mintAmount);

        assertEq(mamo.balanceOf(recipient), initialBalance + mintAmount, "incorrect balance after mint");
        assertEq(mamo.totalSupply(), initialTotalSupply + mintAmount, "incorrect total supply after mint");
    }

    function testCrosschainBurnUnauthorizedFails() public {
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(MAMO.NotSuperchainTokenBridge.selector);
        mamo.crosschainBurn(recipient, 100);
    }

    function testCrosschainBurnAuthorizedSucceeds() public {
        uint256 burnAmount = 100;

        // First, ensure recipient has enough tokens to burn
        assertGt(mamo.balanceOf(recipient), burnAmount, "recipient should have enough tokens to burn");

        uint256 initialBalance = mamo.balanceOf(recipient);
        uint256 initialTotalSupply = mamo.totalSupply();

        vm.prank(superchainTokenBridge);
        mamo.crosschainBurn(recipient, burnAmount);

        assertEq(mamo.balanceOf(recipient), initialBalance - burnAmount, "incorrect balance after burn");
        assertEq(mamo.totalSupply(), initialTotalSupply - burnAmount, "incorrect total supply after burn");
    }

    function testUpdateOverride() public {
        // Test that _update is correctly overridden by transferring tokens
        uint256 transferAmount = 100;

        // First, transfer some tokens to this contract
        vm.prank(recipient);
        mamo.transfer(address(this), transferAmount);

        assertEq(mamo.balanceOf(address(this)), transferAmount, "incorrect balance after transfer");

        // Now transfer to another address
        address newRecipient = makeAddr("newRecipient");
        mamo.transfer(newRecipient, transferAmount);

        assertEq(mamo.balanceOf(address(this)), 0, "balance should be 0 after transfer");
        assertEq(mamo.balanceOf(newRecipient), transferAmount, "new recipient should have received tokens");
    }

    function testCrosschainMintEmitsEvent() public {
        uint256 mintAmount = 100;

        vm.expectEmit(true, true, true, true);
        emit IERC7802.CrosschainMint(recipient, mintAmount, superchainTokenBridge);

        vm.prank(superchainTokenBridge);
        mamo.crosschainMint(recipient, mintAmount);
    }

    function testCrosschainBurnEmitsEvent() public {
        uint256 burnAmount = 100;

        vm.expectEmit(true, true, true, true);
        emit IERC7802.CrosschainBurn(recipient, burnAmount, superchainTokenBridge);

        vm.prank(superchainTokenBridge);
        mamo.crosschainBurn(recipient, burnAmount);
    }

    function testVotingPower() public {
        // Test that voting power is correctly tracked
        uint256 transferAmount = 1000;
        address voter = makeAddr("voter");

        // Transfer tokens to voter
        vm.prank(recipient);
        mamo.transfer(voter, transferAmount);

        // Check voting power
        assertEq(mamo.getVotes(voter), 0, "initial voting power should be 0");

        // Delegate to self
        vm.prank(voter);
        mamo.delegate(voter);

        // Check voting power after delegation
        assertEq(mamo.getVotes(voter), transferAmount, "voting power should match balance after delegation");
    }

    function testPermit() public {
        address spender = makeAddr("spender");
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);

        // Transfer tokens to signer
        vm.prank(recipient);
        mamo.transfer(signer, 1000);

        uint256 value = 100;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 domainSeparator = mamo.DOMAIN_SEPARATOR();
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypehash, signer, spender, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        mamo.permit(signer, spender, value, deadline, v, r, s);

        assertEq(mamo.allowance(signer, spender), value, "allowance should be set after permit");
        assertEq(mamo.nonces(signer), 1, "nonce should be incremented after permit");
    }
}
