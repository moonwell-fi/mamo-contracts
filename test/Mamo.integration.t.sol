// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "@forge-std/Test.sol";

import {MAMO} from "@contracts/Mamo.sol";
import {IERC7802} from "@contracts/interfaces/IERC7802.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MamoDeployScript} from "@script/MamoDeploy.s.sol";

import {Addresses} from "@addresses/Addresses.sol";

contract MamoIntegrationTest is MamoDeployScript {
    MAMO public mamo;

    Addresses public addresses;

    // Constants
    string public constant NAME = "Mamo";
    string public constant SYMBOL = "MAMO";

    function setUp() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);

        if (addresses.isAddressSet("MAMO")) {
            mamo = MAMO(addresses.getAddress("MAMO"));
        } else {
            mamo = deployMamo(addresses);
        }
    }

    function testInitialization() public view {
        assertEq(mamo.name(), NAME, "incorrect name");
        assertEq(mamo.symbol(), SYMBOL, "incorrect symbol");
        assertEq(mamo.totalSupply(), MAX_SUPPLY, "incorrect total supply");
        assertEq(mamo.decimals(), 18, "incorrect decimals");
    }

    function testSupportsInterface() public view {
        assertTrue(mamo.supportsInterface(type(IERC7802).interfaceId), "should support IERC7802");
        assertTrue(mamo.supportsInterface(type(IERC20).interfaceId), "should support IERC20");
        assertTrue(mamo.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
        assertFalse(mamo.supportsInterface(bytes4(0xffffffff)), "should not support random interface");
    }

    function testCrosschainMintUnauthorizedFails() public {
        address recipient = makeAddr("recipient");
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(MAMO.NotSuperchainTokenBridge.selector);
        mamo.crosschainMint(recipient, 100 * 1e18);
    }

    function testCrosschainMintAuthorizedSucceeds() public {
        address recipient = makeAddr("recipient");
        uint256 initialBalance = mamo.balanceOf(recipient);
        uint256 initialTotalSupply = mamo.totalSupply();
        uint256 mintAmount = 100;

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        mamo.crosschainMint(recipient, mintAmount);

        assertEq(mamo.balanceOf(recipient), initialBalance + mintAmount, "incorrect balance after mint");
        assertEq(mamo.totalSupply(), initialTotalSupply + mintAmount, "incorrect total supply after mint");
    }

    function testCrosschainBurnUnauthorizedFails() public {
        address recipient = makeAddr("recipient");
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        vm.prank(unauthorizedCaller);
        vm.expectRevert(MAMO.NotSuperchainTokenBridge.selector);
        mamo.crosschainBurn(recipient, 100 * 1e18);
    }

    function testCrosschainBurnAuthorizedSucceeds() public {
        address recipient = makeAddr("recipient");
        uint256 burnAmount = 100;
        deal(address(mamo), recipient, burnAmount * 1e18);

        uint256 initialBalance = mamo.balanceOf(recipient);
        uint256 initialTotalSupply = mamo.totalSupply();

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        mamo.crosschainBurn(recipient, burnAmount);

        assertEq(mamo.balanceOf(recipient), initialBalance - burnAmount, "incorrect balance after burn");
        assertEq(mamo.totalSupply(), initialTotalSupply - burnAmount, "incorrect total supply after burn");
    }

    function testBurn() public {
        // Test that a user can burn their own tokens
        address burner = makeAddr("burner");
        uint256 burnAmount = 100 * 1e18;

        // Give tokens to the burner
        deal(address(mamo), burner, burnAmount);

        uint256 initialBalance = mamo.balanceOf(burner);
        uint256 initialTotalSupply = mamo.totalSupply();

        // Burn tokens
        vm.prank(burner);
        mamo.burn(burnAmount);

        // Verify balances
        assertEq(mamo.balanceOf(burner), initialBalance - burnAmount, "incorrect balance after burn");
        assertEq(mamo.totalSupply(), initialTotalSupply - burnAmount, "incorrect total supply after burn");
    }

    function testBurnFrom() public {
        // Test that a user can burn tokens from another account with allowance
        address owner = makeAddr("owner");
        address spender = makeAddr("spender");
        uint256 burnAmount = 100 * 1e18;

        // Give tokens to the owner
        deal(address(mamo), owner, burnAmount);

        uint256 initialBalance = mamo.balanceOf(owner);
        uint256 initialTotalSupply = mamo.totalSupply();

        // Approve spender
        vm.prank(owner);
        mamo.approve(spender, burnAmount);

        // Burn tokens
        vm.prank(spender);
        mamo.burnFrom(owner, burnAmount);

        // Verify balances
        assertEq(mamo.balanceOf(owner), initialBalance - burnAmount, "incorrect balance after burn");
        assertEq(mamo.totalSupply(), initialTotalSupply - burnAmount, "incorrect total supply after burn");
        assertEq(mamo.allowance(owner, spender), 0, "allowance should be spent");
    }

    function testBurnFromInsufficientAllowanceFails() public {
        // Test that burnFrom fails when allowance is insufficient
        address owner = makeAddr("owner");
        address spender = makeAddr("spender");
        uint256 burnAmount = 100 * 1e18;

        // Give tokens to the owner
        deal(address(mamo), owner, burnAmount);

        // Approve less than burn amount
        vm.prank(owner);
        mamo.approve(spender, burnAmount - 1);

        // Attempt to burn more than allowed
        vm.prank(spender);
        // Use expectRevert without specific message since OpenZeppelin uses custom errors
        vm.expectRevert();
        mamo.burnFrom(owner, burnAmount);
    }

    function testUpdateOverride() public {
        // Test that _update is correctly overridden by transferring tokens
        uint256 transferAmount = 100;

        // First, transfer some tokens to this contract
        address newRecipient = makeAddr("newRecipient");
        deal(address(mamo), address(this), transferAmount);

        assertEq(mamo.balanceOf(address(this)), transferAmount, "incorrect balance after transfer");

        // Now transfer to another address
        mamo.transfer(newRecipient, transferAmount);

        assertEq(mamo.balanceOf(address(this)), 0, "balance should be 0 after transfer");
        assertEq(mamo.balanceOf(newRecipient), transferAmount, "recipient should have received tokens");
    }

    function testCrosschainMintEmitsEvent() public {
        address recipient = makeAddr("recipient");
        uint256 mintAmount = 100;

        vm.expectEmit(true, true, true, true);
        emit IERC7802.CrosschainMint(recipient, mintAmount, SUPERCHAIN_TOKEN_BRIDGE);

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        mamo.crosschainMint(recipient, mintAmount);
    }

    function testCrosschainBurnEmitsEvent() public {
        address recipient = makeAddr("recipient");
        uint256 burnAmount = 100;
        deal(address(mamo), recipient, burnAmount);

        vm.expectEmit(true, true, true, true);
        emit IERC7802.CrosschainBurn(recipient, burnAmount, SUPERCHAIN_TOKEN_BRIDGE);

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        mamo.crosschainBurn(recipient, burnAmount);
    }

    function testVotingPower() public {
        // Test that voting power is correctly tracked
        uint256 transferAmount = 1000;
        address voter = makeAddr("voter");
        deal(address(mamo), voter, transferAmount);

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
        uint256 value = 100;
        uint256 deadline = block.timestamp + 1 hours;

        deal(address(mamo), signer, value * 1e18);

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
