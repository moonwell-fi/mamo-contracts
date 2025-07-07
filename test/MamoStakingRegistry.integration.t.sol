// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {MockPool} from "./mocks/MockPool.sol";
import {MamoStakingRegistry} from "@contracts/MamoStakingRegistry.sol";

import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";
import {MamoStakingDeployment} from "@multisig/005_MamoStakingDeployment.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MamoStakingRegistryIntegrationTest is Test {
    Addresses public addresses;
    MamoStakingRegistry public stakingRegistry;

    address public admin;
    address public backend;
    address public guardian;
    address public mamoToken;

    address public rewardToken1;
    address public rewardToken2;
    address public pool1;
    address public pool2;

    uint256 public constant DEFAULT_SLIPPAGE = 100; // 1%
    uint256 public constant MAX_SLIPPAGE = 2500; // 25%

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));

        // Create addresses instance
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);

        // Use the multisig deployment script to deploy all contracts
        MamoStakingDeployment deploymentScript = new MamoStakingDeployment();
        deploymentScript.setAddresses(addresses);

        // Deploy the staking system
        deploymentScript.deploy();
        deploymentScript.build();
        deploymentScript.simulate();
        deploymentScript.validate();

        // Get the deployed registry
        stakingRegistry = MamoStakingRegistry(addresses.getAddress("MAMO_STAKING_REGISTRY"));

        // Get key addresses
        admin = addresses.getAddress("MAMO_MULTISIG");
        backend = addresses.getAddress("MAMO_STAKING_BACKEND");
        guardian = addresses.getAddress("MAMO_MULTISIG"); // Same as admin
        mamoToken = addresses.getAddress("MAMO");

        // Create mock contracts for testing
        rewardToken1 = addresses.getAddress("USDC"); // Use real token contract
        rewardToken2 = addresses.getAddress("WETH"); // Use real token contract

        // Deploy mock pool contracts
        MockPool mockPool1 = new MockPool(rewardToken1, mamoToken);
        MockPool mockPool2 = new MockPool(rewardToken2, mamoToken);
        pool1 = address(mockPool1);
        pool2 = address(mockPool2);
    }

    // ========== DEPLOYMENT TESTS ==========

    function testDeploymentWasSuccessful() public {
        // Verify contract state
        assertTrue(address(stakingRegistry) != address(0), "Registry should be deployed");
        assertEq(stakingRegistry.mamoToken(), mamoToken, "Should have correct MAMO token");
        assertTrue(address(stakingRegistry.dexRouter()) != address(0), "Should have DEX router");
        assertTrue(address(stakingRegistry.quoter()) != address(0), "Should have quoter");
        assertEq(stakingRegistry.defaultSlippageInBps(), DEFAULT_SLIPPAGE, "Should have correct default slippage");
        assertEq(stakingRegistry.MAX_SLIPPAGE_IN_BPS(), MAX_SLIPPAGE, "Should have correct max slippage");
    }

    function testRolesWereGrantedCorrectly() public {
        // Check admin role
        assertTrue(
            stakingRegistry.hasRole(stakingRegistry.DEFAULT_ADMIN_ROLE(), admin), "Admin should have DEFAULT_ADMIN_ROLE"
        );

        // Check backend role
        assertTrue(stakingRegistry.hasRole(stakingRegistry.BACKEND_ROLE(), backend), "Backend should have BACKEND_ROLE");

        // Check guardian role
        assertTrue(
            stakingRegistry.hasRole(stakingRegistry.GUARDIAN_ROLE(), guardian), "Guardian should have GUARDIAN_ROLE"
        );
    }

    function testInitialRewardTokensSetup() public {
        // Check that cbBTC was added as a reward token during deployment
        address cbBTC = addresses.getAddress("cbBTC");
        assertTrue(stakingRegistry.isRewardToken(cbBTC), "cbBTC should be a reward token");
        assertEq(stakingRegistry.getRewardTokenCount(), 1, "Should have 1 reward token initially");

        MamoStakingRegistry.RewardToken[] memory tokens = stakingRegistry.getRewardTokens();
        assertEq(tokens.length, 1, "Reward tokens array should have 1 element");
        assertEq(tokens[0].token, cbBTC, "First token should be cbBTC");
    }

    // ========== REWARD TOKEN MANAGEMENT TESTS - HAPPY PATH ==========

    function testAddRewardToken() public {
        vm.startPrank(backend);

        vm.expectEmit(true, true, false, true);
        emit RewardTokenAdded(rewardToken1, pool1);
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        vm.stopPrank();

        // Verify token was added
        assertTrue(stakingRegistry.isRewardToken(rewardToken1), "Token should be marked as reward token");
        assertEq(stakingRegistry.getRewardTokenCount(), 2, "Should have 2 reward tokens"); // +1 from cbBTC
        assertEq(stakingRegistry.getRewardTokenPool(rewardToken1), pool1, "Should have correct pool");
    }

    function testAddMultipleRewardTokens() public {
        vm.startPrank(backend);

        // Add first token
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        // Add second token
        stakingRegistry.addRewardToken(rewardToken2, pool2);

        vm.stopPrank();

        // Verify both tokens (plus cbBTC from deployment)
        assertEq(stakingRegistry.getRewardTokenCount(), 3, "Should have 3 reward tokens");
        assertTrue(stakingRegistry.isRewardToken(rewardToken1), "Token1 should be reward token");
        assertTrue(stakingRegistry.isRewardToken(rewardToken2), "Token2 should be reward token");
    }

    function testRemoveRewardToken() public {
        // First add a token
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);
        vm.stopPrank();

        // Verify it was added
        assertTrue(stakingRegistry.isRewardToken(rewardToken1), "Token should be added");
        assertEq(stakingRegistry.getRewardTokenCount(), 2, "Should have 2 tokens"); // +1 from cbBTC

        // Remove the token
        vm.startPrank(backend);
        vm.expectEmit(true, false, false, true);
        emit RewardTokenRemoved(rewardToken1);
        stakingRegistry.removeRewardToken(rewardToken1);
        vm.stopPrank();

        // Verify it was removed
        assertFalse(stakingRegistry.isRewardToken(rewardToken1), "Token should be removed");
        assertEq(stakingRegistry.getRewardTokenCount(), 1, "Should have 1 token left"); // cbBTC remains
    }

    function testUpdateRewardTokenPool() public {
        // Add a token first
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);
        vm.stopPrank();

        // Update its pool to pool2 (which is a real contract)
        vm.startPrank(backend);
        vm.expectEmit(true, true, true, true);
        emit RewardTokenPoolUpdated(rewardToken1, pool1, pool2);
        stakingRegistry.updateRewardTokenPool(rewardToken1, pool2);
        vm.stopPrank();

        // Verify update
        assertEq(stakingRegistry.getRewardTokenPool(rewardToken1), pool2, "Pool should be updated");
    }

    // ========== REWARD TOKEN MANAGEMENT TESTS - UNHAPPY PATH ==========

    function testAddRewardTokenRevertsWhenInvalidToken() public {
        vm.startPrank(backend);
        vm.expectRevert("Invalid token");
        stakingRegistry.addRewardToken(address(0), pool1);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenInvalidPool() public {
        vm.startPrank(backend);
        vm.expectRevert("Invalid pool");
        stakingRegistry.addRewardToken(rewardToken1, address(0));
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenTokenAlreadyAdded() public {
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        vm.expectRevert("Token already added");
        stakingRegistry.addRewardToken(rewardToken1, pool2);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenTokenIsMAMO() public {
        vm.startPrank(backend);
        vm.expectRevert("Cannot add MAMO token as reward");
        stakingRegistry.addRewardToken(mamoToken, pool1);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenPoolSameAsToken() public {
        vm.startPrank(backend);
        vm.expectRevert("Pool cannot be same as token");
        stakingRegistry.addRewardToken(rewardToken1, rewardToken1);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenNotBackend() public {
        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.addRewardToken(rewardToken1, pool1);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenPaused() public {
        // Pause the contract
        vm.startPrank(guardian);
        stakingRegistry.pause();
        vm.stopPrank();

        // Try to add token
        vm.startPrank(backend);
        vm.expectRevert();
        stakingRegistry.addRewardToken(rewardToken1, pool1);
        vm.stopPrank();
    }

    function testRemoveRewardTokenRevertsWhenTokenNotFound() public {
        vm.startPrank(backend);
        vm.expectRevert("Token not found");
        stakingRegistry.removeRewardToken(rewardToken1);
        vm.stopPrank();
    }

    function testRemoveRewardTokenRevertsWhenNotBackend() public {
        // Add token first
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);
        vm.stopPrank();

        // Try to remove as non-backend
        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.removeRewardToken(rewardToken1);
        vm.stopPrank();
    }

    function testUpdateRewardTokenPoolRevertsWhenTokenNotFound() public {
        vm.startPrank(backend);
        vm.expectRevert("Token not found");
        stakingRegistry.updateRewardTokenPool(rewardToken1, pool2);
        vm.stopPrank();
    }

    function testUpdateRewardTokenPoolRevertsWhenInvalidPool() public {
        // Add token first
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        vm.expectRevert("Invalid pool");
        stakingRegistry.updateRewardTokenPool(rewardToken1, address(0));
        vm.stopPrank();
    }

    function testUpdateRewardTokenPoolRevertsWhenPoolSameAsToken() public {
        // Add token first
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        vm.expectRevert("Pool cannot be same as token");
        stakingRegistry.updateRewardTokenPool(rewardToken1, rewardToken1);
        vm.stopPrank();
    }

    function testUpdateRewardTokenPoolRevertsWhenPoolIsMAMOToken() public {
        // Add token first
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        vm.expectRevert("Pool cannot be MAMO token");
        stakingRegistry.updateRewardTokenPool(rewardToken1, mamoToken);
        vm.stopPrank();
    }

    function testUpdateRewardTokenPoolRevertsWhenPoolAlreadySet() public {
        // Add token first
        vm.startPrank(backend);
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        vm.expectRevert("Pool already set");
        stakingRegistry.updateRewardTokenPool(rewardToken1, pool1);
        vm.stopPrank();
    }

    function testUpdateRewardTokenPoolRevertsWhenPoolNotContract() public {
        // Use cbBTC which is already added during deployment
        address realToken = addresses.getAddress("cbBTC");

        // Try to update to an EOA (non-contract)
        address eoaAddress = makeAddr("eoaAddress");
        vm.startPrank(backend);
        vm.expectRevert("Pool must be a contract");
        stakingRegistry.updateRewardTokenPool(realToken, eoaAddress);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenPoolIsMAMOToken() public {
        vm.startPrank(backend);
        vm.expectRevert("Pool cannot be MAMO token");
        stakingRegistry.addRewardToken(rewardToken1, mamoToken);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenTokenNotContract() public {
        // Try to add an EOA as token
        address eoaToken = makeAddr("eoaToken");
        address realPool = addresses.getAddress("cbBTC");

        vm.startPrank(backend);
        vm.expectRevert("Token must be a contract");
        stakingRegistry.addRewardToken(eoaToken, realPool);
        vm.stopPrank();
    }

    function testAddRewardTokenRevertsWhenPoolNotContract() public {
        // Try to add an EOA as pool - use WETH since cbBTC is already added in deployment
        address realToken = addresses.getAddress("WETH");
        address eoaPool = makeAddr("eoaPool");

        vm.startPrank(backend);
        vm.expectRevert("Pool must be a contract");
        stakingRegistry.addRewardToken(realToken, eoaPool);
        vm.stopPrank();
    }

    // ========== DEX CONFIGURATION TESTS ==========

    function testSetDEXRouter() public {
        address newRouter = makeAddr("newRouter");
        address oldRouter = address(stakingRegistry.dexRouter());

        vm.startPrank(backend);
        vm.expectEmit(true, true, false, true);
        emit DEXRouterUpdated(oldRouter, newRouter);
        stakingRegistry.setDEXRouter(ISwapRouter(newRouter));
        vm.stopPrank();

        assertEq(address(stakingRegistry.dexRouter()), newRouter, "DEX router should be updated");
    }

    function testSetDEXRouterRevertsWhenInvalidRouter() public {
        vm.startPrank(backend);
        vm.expectRevert("Invalid router");
        stakingRegistry.setDEXRouter(ISwapRouter(address(0)));
        vm.stopPrank();
    }

    function testSetDEXRouterRevertsWhenNotBackend() public {
        address newRouter = makeAddr("newRouter");
        address randomUser = makeAddr("randomUser");

        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.setDEXRouter(ISwapRouter(newRouter));
        vm.stopPrank();
    }

    function testSetDEXRouterRevertsWhenSameRouter() public {
        address currentRouter = address(stakingRegistry.dexRouter());

        vm.startPrank(backend);
        vm.expectRevert("Router already set");
        stakingRegistry.setDEXRouter(ISwapRouter(currentRouter));
        vm.stopPrank();
    }

    function testSetQuoter() public {
        address newQuoter = makeAddr("newQuoter");
        address oldQuoter = address(stakingRegistry.quoter());

        vm.startPrank(backend);
        vm.expectEmit(true, true, false, true);
        emit QuoterUpdated(oldQuoter, newQuoter);
        stakingRegistry.setQuoter(IQuoter(newQuoter));
        vm.stopPrank();

        assertEq(address(stakingRegistry.quoter()), newQuoter, "Quoter should be updated");
    }

    function testSetQuoterRevertsWhenInvalidQuoter() public {
        vm.startPrank(backend);
        vm.expectRevert("Invalid quoter");
        stakingRegistry.setQuoter(IQuoter(address(0)));
        vm.stopPrank();
    }

    function testSetQuoterRevertsWhenNotBackend() public {
        address newQuoter = makeAddr("newQuoter");
        address randomUser = makeAddr("randomUser");

        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.setQuoter(IQuoter(newQuoter));
        vm.stopPrank();
    }

    function testSetQuoterRevertsWhenSameQuoter() public {
        address currentQuoter = address(stakingRegistry.quoter());

        vm.startPrank(backend);
        vm.expectRevert("Quoter already set");
        stakingRegistry.setQuoter(IQuoter(currentQuoter));
        vm.stopPrank();
    }

    // ========== SLIPPAGE CONFIGURATION TESTS ==========

    function testSetDefaultSlippage() public {
        uint256 newSlippage = 200; // 2%

        vm.startPrank(backend);
        vm.expectEmit(true, true, false, true);
        emit DefaultSlippageUpdated(DEFAULT_SLIPPAGE, newSlippage);
        stakingRegistry.setDefaultSlippage(newSlippage);
        vm.stopPrank();

        assertEq(stakingRegistry.defaultSlippageInBps(), newSlippage, "Default slippage should be updated");
    }

    function testSetDefaultSlippageRevertsWhenTooHigh() public {
        vm.startPrank(backend);
        vm.expectRevert("Slippage too high");
        stakingRegistry.setDefaultSlippage(MAX_SLIPPAGE + 1);
        vm.stopPrank();
    }

    function testSetDefaultSlippageRevertsWhenNotBackend() public {
        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.setDefaultSlippage(200);
        vm.stopPrank();
    }

    function testSetDefaultSlippageAtMaximumAllowed() public {
        vm.startPrank(backend);
        stakingRegistry.setDefaultSlippage(MAX_SLIPPAGE);
        vm.stopPrank();

        assertEq(stakingRegistry.defaultSlippageInBps(), MAX_SLIPPAGE, "Should allow maximum slippage");
    }

    // ========== VIEW FUNCTION TESTS ==========

    function testGetRewardTokenAtValidIndex() public {
        // cbBTC should be at index 0 from deployment
        MamoStakingRegistry.RewardToken memory token = stakingRegistry.getRewardToken(0);
        address cbBTC = addresses.getAddress("cbBTC");
        assertEq(token.token, cbBTC, "Should return cbBTC as first token");
    }

    function testGetRewardTokenRevertsAtInvalidIndex() public {
        vm.expectRevert("Index out of bounds");
        stakingRegistry.getRewardToken(99); // Way out of bounds
    }

    function testGetRewardTokenPoolRevertsWhenTokenNotFound() public {
        vm.expectRevert("Token not found");
        stakingRegistry.getRewardTokenPool(rewardToken1);
    }

    // ========== PAUSE/UNPAUSE TESTS ==========

    function testPauseByGuardian() public {
        vm.startPrank(guardian);
        stakingRegistry.pause();
        vm.stopPrank();

        assertTrue(stakingRegistry.paused(), "Contract should be paused");
    }

    function testUnpauseByGuardian() public {
        // Pause first
        vm.startPrank(guardian);
        stakingRegistry.pause();
        assertTrue(stakingRegistry.paused(), "Contract should be paused");

        // Then unpause
        stakingRegistry.unpause();
        vm.stopPrank();

        assertFalse(stakingRegistry.paused(), "Contract should be unpaused");
    }

    function testPauseRevertsWhenNotGuardian() public {
        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.pause();
        vm.stopPrank();
    }

    function testUnpauseRevertsWhenNotGuardian() public {
        // Pause first
        vm.startPrank(guardian);
        stakingRegistry.pause();
        vm.stopPrank();

        // Try to unpause as non-guardian
        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.unpause();
        vm.stopPrank();
    }

    function testOperationsRevertWhenPaused() public {
        // Pause the contract
        vm.startPrank(guardian);
        stakingRegistry.pause();
        vm.stopPrank();

        // All backend operations should revert
        vm.startPrank(backend);

        vm.expectRevert();
        stakingRegistry.addRewardToken(rewardToken1, pool1);

        vm.expectRevert();
        stakingRegistry.setDefaultSlippage(200);

        vm.expectRevert();
        stakingRegistry.setDEXRouter(ISwapRouter(makeAddr("newRouter")));

        vm.expectRevert();
        stakingRegistry.setQuoter(IQuoter(makeAddr("newQuoter")));

        vm.stopPrank();
    }

    // ========== RECOVERY FUNCTION TESTS ==========

    function testRecoverERC20() public {
        address token = makeAddr("testToken");
        address recipient = makeAddr("recipient");
        uint256 amount = 1000e18;

        // Mock token balance and transfer
        vm.mockCall(token, abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount), abi.encode(true));

        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(token, recipient, amount);
        stakingRegistry.recoverERC20(token, recipient, amount);
        vm.stopPrank();
    }

    function testRecoverERC20RevertsWhenNotAdmin() public {
        address token = makeAddr("testToken");
        address recipient = makeAddr("recipient");
        uint256 amount = 1000e18;
        address randomUser = makeAddr("randomUser");

        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.recoverERC20(token, recipient, amount);
        vm.stopPrank();
    }

    function testRecoverERC20RevertsWhenZeroAddress() public {
        address token = makeAddr("testToken");
        uint256 amount = 1000e18;

        vm.startPrank(admin);
        vm.expectRevert("Cannot send to zero address");
        stakingRegistry.recoverERC20(token, address(0), amount);
        vm.stopPrank();
    }

    function testRecoverERC20RevertsWhenZeroAmount() public {
        address token = makeAddr("testToken");
        address recipient = makeAddr("recipient");

        vm.startPrank(admin);
        vm.expectRevert("Amount must be greater than 0");
        stakingRegistry.recoverERC20(token, recipient, 0);
        vm.stopPrank();
    }

    function testRecoverETH() public {
        address payable recipient = payable(makeAddr("recipient"));
        uint256 amount = 1 ether;

        // Give the contract some ETH
        vm.deal(address(stakingRegistry), amount);

        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(0), recipient, amount);
        stakingRegistry.recoverETH(recipient);
        vm.stopPrank();

        assertEq(address(stakingRegistry).balance, 0, "Contract should have no ETH left");
    }

    function testRecoverETHRevertsWhenNotAdmin() public {
        address payable recipient = payable(makeAddr("recipient"));
        address randomUser = makeAddr("randomUser");

        vm.startPrank(randomUser);
        vm.expectRevert();
        stakingRegistry.recoverETH(recipient);
        vm.stopPrank();
    }

    function testRecoverETHRevertsWhenZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert("Cannot send to zero address");
        stakingRegistry.recoverETH(payable(address(0)));
        vm.stopPrank();
    }

    function testRecoverETHRevertsWhenEmptyBalance() public {
        address payable recipient = payable(makeAddr("recipient"));

        vm.startPrank(admin);
        vm.expectRevert("Empty balance");
        stakingRegistry.recoverETH(recipient);
        vm.stopPrank();
    }

    // Event declarations
    event RewardTokenAdded(address indexed token, address indexed pool);
    event RewardTokenRemoved(address indexed token);
    event RewardTokenPoolUpdated(address indexed token, address indexed oldPool, address indexed newPool);
    event DEXRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event QuoterUpdated(address indexed oldQuoter, address indexed newQuoter);
    event DefaultSlippageUpdated(uint256 oldSlippageInBps, uint256 newSlippageInBps);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
}
