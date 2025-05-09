// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "@forge-std/Test.sol";
import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";

import {IERC7802} from "@contracts/interfaces/IERC7802.sol";
import {MAMO2} from "@contracts/token/Mamo2.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MAMO2UnitTest is Test {
    MAMO2 public mamo2Logic;
    MAMO2 public mamo2Proxy;
    address public owner;
    address public recipient;
    address public superchainTokenBridge;

    // Constants
    string public constant NAME = "MAMO2";
    string public constant SYMBOL = "MAMO2";
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    function setUp() public {
        owner = address(this);
        recipient = makeAddr("recipient");
        superchainTokenBridge = 0x4200000000000000000000000000000000000028;

        // Deploy logic contract
        mamo2Logic = new MAMO2();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(MAMO2.initialize.selector, NAME, SYMBOL, recipient);

        ERC1967Proxy proxy = new ERC1967Proxy(address(mamo2Logic), initData);

        mamo2Proxy = MAMO2(address(proxy));

        vm.label(address(mamo2Logic), "MAMO2 Logic");
        vm.label(address(mamo2Proxy), "MAMO2 Proxy");
        vm.label(recipient, "Recipient");
        vm.label(superchainTokenBridge, "Superchain Token Bridge");
    }

    function testInitialization() public {
        assertEq(mamo2Proxy.name(), NAME, "incorrect name");
        assertEq(mamo2Proxy.symbol(), SYMBOL, "incorrect symbol");
        assertEq(mamo2Proxy.totalSupply(), MAX_SUPPLY, "incorrect total supply");
        assertEq(mamo2Proxy.balanceOf(recipient), MAX_SUPPLY, "incorrect recipient balance");
    }

    function testInitializeLogicContractFails() public {
        vm.expectRevert();
        mamo2Logic.initialize(NAME, SYMBOL, recipient);
    }

    function testReinitializationFails() public {
        // Attempt to call initialize again on the proxy contract
        /// error InvalidInitialization
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        mamo2Proxy.initialize(NAME, SYMBOL, recipient);
    }

    function testSupportsInterface() public {
        assertTrue(mamo2Proxy.supportsInterface(type(IERC7802).interfaceId), "should support IERC7802");
        assertTrue(mamo2Proxy.supportsInterface(type(IERC20).interfaceId), "should support IERC20");
        assertTrue(mamo2Proxy.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
        assertFalse(mamo2Proxy.supportsInterface(bytes4(0xffffffff)), "should not support random interface");
    }

    function testCrosschainMintUnauthorizedFails() public {
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(MAMO2.NotSuperchainTokenBridge.selector);
        mamo2Proxy.crosschainMint(recipient, 100);
    }

    function testCrosschainMintAuthorizedSucceeds() public {
        uint256 initialBalance = mamo2Proxy.balanceOf(recipient);
        uint256 initialTotalSupply = mamo2Proxy.totalSupply();
        uint256 mintAmount = 100;

        vm.prank(superchainTokenBridge);
        mamo2Proxy.crosschainMint(recipient, mintAmount);

        assertEq(mamo2Proxy.balanceOf(recipient), initialBalance + mintAmount, "incorrect balance after mint");
        assertEq(mamo2Proxy.totalSupply(), initialTotalSupply + mintAmount, "incorrect total supply after mint");
    }

    function testCrosschainBurnUnauthorizedFails() public {
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(MAMO2.NotSuperchainTokenBridge.selector);
        mamo2Proxy.crosschainBurn(recipient, 100);
    }

    function testCrosschainBurnAuthorizedSucceeds() public {
        uint256 burnAmount = 100;

        // First, ensure recipient has enough tokens to burn
        assertGt(mamo2Proxy.balanceOf(recipient), burnAmount, "recipient should have enough tokens to burn");

        uint256 initialBalance = mamo2Proxy.balanceOf(recipient);
        uint256 initialTotalSupply = mamo2Proxy.totalSupply();

        vm.prank(superchainTokenBridge);
        mamo2Proxy.crosschainBurn(recipient, burnAmount);

        assertEq(mamo2Proxy.balanceOf(recipient), initialBalance - burnAmount, "incorrect balance after burn");
        assertEq(mamo2Proxy.totalSupply(), initialTotalSupply - burnAmount, "incorrect total supply after burn");
    }

    function testUpdateOverride() public {
        // Test that _update is correctly overridden by transferring tokens
        uint256 transferAmount = 100;

        // First, transfer some tokens to this contract
        vm.prank(recipient);
        mamo2Proxy.transfer(address(this), transferAmount);

        assertEq(mamo2Proxy.balanceOf(address(this)), transferAmount, "incorrect balance after transfer");

        // Now transfer to another address
        address newRecipient = makeAddr("newRecipient");
        mamo2Proxy.transfer(newRecipient, transferAmount);

        assertEq(mamo2Proxy.balanceOf(address(this)), 0, "balance should be 0 after transfer");
        assertEq(mamo2Proxy.balanceOf(newRecipient), transferAmount, "new recipient should have received tokens");
    }

    function testCrosschainMintEmitsEvent() public {
        uint256 mintAmount = 100;

        vm.expectEmit(true, true, true, true);
        emit IERC7802.CrosschainMint(recipient, mintAmount, superchainTokenBridge);

        vm.prank(superchainTokenBridge);
        mamo2Proxy.crosschainMint(recipient, mintAmount);
    }

    function testCrosschainBurnEmitsEvent() public {
        uint256 burnAmount = 100;

        vm.expectEmit(true, true, true, true);
        emit IERC7802.CrosschainBurn(recipient, burnAmount, superchainTokenBridge);

        vm.prank(superchainTokenBridge);
        mamo2Proxy.crosschainBurn(recipient, burnAmount);
    }

    function testVotingPower() public {
        // Test that voting power is correctly tracked
        uint256 transferAmount = 1000;
        address voter = makeAddr("voter");

        // Transfer tokens to voter
        vm.prank(recipient);
        mamo2Proxy.transfer(voter, transferAmount);

        // Check voting power
        assertEq(mamo2Proxy.getVotes(voter), 0, "initial voting power should be 0");

        // Delegate to self
        vm.prank(voter);
        mamo2Proxy.delegate(voter);

        // Check voting power after delegation
        assertEq(mamo2Proxy.getVotes(voter), transferAmount, "voting power should match balance after delegation");
    }

    function testPermit() public {
        address spender = makeAddr("spender");
        address tokenOwner = makeAddr("tokenOwner");
        uint256 privateKey = 0xA11CE;
        address signer = vm.addr(privateKey);

        // Transfer tokens to signer
        vm.prank(recipient);
        mamo2Proxy.transfer(signer, 1000);

        uint256 value = 100;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 domainSeparator = mamo2Proxy.DOMAIN_SEPARATOR();
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypehash, signer, spender, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        mamo2Proxy.permit(signer, spender, value, deadline, v, r, s);

        assertEq(mamo2Proxy.allowance(signer, spender), value, "allowance should be set after permit");
        assertEq(mamo2Proxy.nonces(signer), 1, "nonce should be incremented after permit");
    }
}
