// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStrategyWithOwnership, StrategyFactory} from "@contracts/StrategyFactory.sol";
import {Test} from "@forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC20
 * @notice A simple mock ERC20 token for testing
 */
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external virtual override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");

        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);

        return true;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(_balances[from] >= amount, "ERC20: transfer amount exceeds balance");

        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

/**
 * @title MockFailingERC20
 * @notice A mock ERC20 token that fails on transfers for testing error conditions
 */
contract MockFailingERC20 is MockERC20 {
    bool public shouldFail = true;

    constructor() MockERC20("Failing Token", "FAIL", 18) {}

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (shouldFail) {
            revert("Transfer failed");
        }
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (shouldFail) {
            revert("Transfer failed");
        }
        uint256 currentAllowance = this.allowance(from, msg.sender);
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");

        _transfer(from, to, amount);
        _approve(from, msg.sender, currentAllowance - amount);

        return true;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }
}

/**
 * @title MockStrategy
 * @notice A mock strategy contract for testing the StrategyFactory
 */
contract MockStrategy is IStrategyWithOwnership, Ownable {
    IERC20 public immutable token;
    uint256 public totalDeposited;

    constructor(address _token, address _owner) Ownable(_owner) {
        token = IERC20(_token);
    }

    function deposit(uint256 amount) external override {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer tokens from caller to this contract
        token.transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
    }

    function withdraw(uint256 amount) external onlyOwner {
        require(amount <= totalDeposited, "Insufficient balance");
        totalDeposited -= amount;
        token.transfer(msg.sender, amount);
    }

    function withdrawAll() external onlyOwner {
        uint256 amount = totalDeposited;
        totalDeposited = 0;
        token.transfer(msg.sender, amount);
    }

    function getTotalBalance() external view returns (uint256) {
        return totalDeposited;
    }

    function owner() public view override(IStrategyWithOwnership, Ownable) returns (address) {
        return Ownable.owner();
    }

    function transferOwnership(address newOwner) public override(IStrategyWithOwnership, Ownable) onlyOwner {
        Ownable.transferOwnership(newOwner);
    }

    function mamoCore() external pure returns (address) {
        return address(0); // Mock implementation
    }

    function withdraw(address asset, uint256 amount) external onlyOwner {
        require(asset == address(token), "Invalid asset");
        require(amount <= totalDeposited, "Insufficient balance");
        totalDeposited -= amount;
        token.transfer(msg.sender, amount);
    }

    function updatePosition(uint256 splitA, uint256 splitB) external view onlyOwner {
        // Mock implementation - do nothing
        require(splitA + splitB == 10000, "Invalid splits");
    }

    function claimRewards() external onlyOwner {
        // Mock implementation - do nothing
    }
}

/**
 * @title MockRejectETH
 * @notice A mock contract that rejects all ETH transfers
 */
contract MockRejectETH {
// This contract has no receive or fallback function,
// so it will reject all ETH transfers
}

/**
 * @title StrategyFactoryTest
 * @notice Unit tests for the StrategyFactory contract
 */
contract StrategyFactoryTest is Test {
    StrategyFactory public factory;
    MockERC20 public usdc;
    MockStrategy public strategy1;
    MockStrategy public strategy2;
    MockStrategy public strategy3;

    address public owner;
    address public user1;
    address public user2;

    // Events from StrategyFactory
    event StrategyAdded(address indexed strategy);
    event StrategyClaimed(address indexed user, address indexed strategy, uint256 amount);
    event StrategyClaimedForAddress(address indexed beneficiary, address indexed strategy);
    event MinimumClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);

    function setUp() public {
        // Create test addresses
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock USDC token (6 decimals like real USDC)
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy StrategyFactory
        factory = new StrategyFactory(address(usdc), owner);

        // Deploy mock strategies owned by the factory
        strategy1 = new MockStrategy(address(usdc), address(factory));
        strategy2 = new MockStrategy(address(usdc), address(factory));
        strategy3 = new MockStrategy(address(usdc), address(factory));

        // Label addresses for better trace output
        vm.label(address(factory), "StrategyFactory");
        vm.label(address(usdc), "USDC");
        vm.label(address(strategy1), "Strategy1");
        vm.label(address(strategy2), "Strategy2");
        vm.label(address(strategy3), "Strategy3");
        vm.label(owner, "Owner");
        vm.label(user1, "User1");
        vm.label(user2, "User2");
    }

    function testConstructorWithValidParameters() public {
        StrategyFactory newFactory = new StrategyFactory(address(usdc), owner);

        assertEq(address(newFactory.usdc()), address(usdc), "USDC address should be set correctly");
        assertEq(newFactory.owner(), owner, "Owner should be set correctly");
        assertEq(newFactory.getAvailableStrategiesCount(), 0, "Initial strategy count should be 0");
    }

    function testRevertIfConstructorWithZeroUSDCAddress() public {
        vm.expectRevert("Invalid USDC address");
        new StrategyFactory(address(0), owner);
    }

    function testOwnerCanAddStrategy() public {
        // Verify initial state
        assertEq(factory.getAvailableStrategiesCount(), 0, "Initial strategy count should be 0");

        // Owner adds a strategy
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(factory));
        emit StrategyAdded(address(strategy1));
        factory.add(address(strategy1));

        // Verify the strategy was added
        assertEq(factory.getAvailableStrategiesCount(), 1, "Strategy count should be 1");

        address[] memory strategies = factory.getAvailableStrategies();
        assertEq(strategies.length, 1, "Strategies array should have 1 element");
        assertEq(strategies[0], address(strategy1), "First strategy should be strategy1");
        assertEq(factory.strategies(0), address(strategy1), "Strategy at index 0 should be strategy1");
    }

    function testOwnerCanAddMultipleStrategies() public {
        // Add multiple strategies
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        factory.add(address(strategy3));
        vm.stopPrank();

        // Verify all strategies were added
        assertEq(factory.getAvailableStrategiesCount(), 3, "Strategy count should be 3");

        address[] memory strategies = factory.getAvailableStrategies();
        assertEq(strategies.length, 3, "Strategies array should have 3 elements");
        assertEq(strategies[0], address(strategy1), "First strategy should be strategy1");
        assertEq(strategies[1], address(strategy2), "Second strategy should be strategy2");
        assertEq(strategies[2], address(strategy3), "Third strategy should be strategy3");
    }

    function testRevertIfNonOwnerAddsStrategy() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.add(address(strategy1));

        // Verify no strategy was added
        assertEq(factory.getAvailableStrategiesCount(), 0, "Strategy count should remain 0");
    }

    function testRevertIfAddZeroAddressStrategy() public {
        vm.prank(owner);
        vm.expectRevert("Invalid strategy address");
        factory.add(address(0));

        // Verify no strategy was added
        assertEq(factory.getAvailableStrategiesCount(), 0, "Strategy count should remain 0");
    }

    function testRevertIfAddStrategyNotOwnedByFactory() public {
        // Create a strategy owned by someone else
        MockStrategy independentStrategy = new MockStrategy(address(usdc), user1);

        vm.prank(owner);
        vm.expectRevert("Factory must be the owner of the strategy");
        factory.add(address(independentStrategy));

        // Verify no strategy was added
        assertEq(factory.getAvailableStrategiesCount(), 0, "Strategy count should remain 0");
    }

    function testUserCanClaimStrategy() public {
        // Setup: Add a strategy and mint USDC to user
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 claimAmount = 1000 * 10 ** 6; // 1000 USDC
        usdc.mint(user1, claimAmount);

        // User approves factory to spend USDC
        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);

        // Verify initial state
        assertEq(factory.getAvailableStrategiesCount(), 1, "Should have 1 strategy available");
        assertEq(usdc.balanceOf(user1), claimAmount, "User should have USDC");
        assertEq(strategy1.owner(), address(factory), "Strategy should be owned by factory");

        // User claims the strategy
        vm.prank(user1);
        vm.expectEmit(true, true, false, true, address(factory));
        emit StrategyClaimed(user1, address(strategy1), claimAmount);
        factory.claim(claimAmount);

        // Verify the claim was successful
        assertEq(factory.getAvailableStrategiesCount(), 0, "Should have 0 strategies available");
        assertEq(usdc.balanceOf(user1), 0, "User's USDC should be transferred");
        assertEq(strategy1.owner(), user1, "Strategy should now be owned by user");
        assertEq(strategy1.getTotalBalance(), claimAmount, "Strategy should have the deposited amount");
    }

    function testClaimStrategyPopsFromEnd() public {
        // Setup: Add multiple strategies
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        factory.add(address(strategy3));
        vm.stopPrank();

        uint256 claimAmount = 1000 * 10 ** 6; // 1000 USDC
        usdc.mint(user1, claimAmount);

        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);

        // Verify initial order
        address[] memory initialStrategies = factory.getAvailableStrategies();
        assertEq(initialStrategies[0], address(strategy1));
        assertEq(initialStrategies[1], address(strategy2));
        assertEq(initialStrategies[2], address(strategy3));

        // User claims a strategy - should get the last one (strategy3)
        vm.prank(user1);
        factory.claim(claimAmount);

        // Verify strategy3 was claimed and removed from the end
        assertEq(factory.getAvailableStrategiesCount(), 2, "Should have 2 strategies remaining");
        assertEq(strategy3.owner(), user1, "Strategy3 should be owned by user");

        address[] memory remainingStrategies = factory.getAvailableStrategies();
        assertEq(remainingStrategies.length, 2);
        assertEq(remainingStrategies[0], address(strategy1));
        assertEq(remainingStrategies[1], address(strategy2));
    }

    function testRevertIfClaimWithNoStrategiesAvailable() public {
        uint256 claimAmount = 1000 * 10 ** 6; // 1000 USDC
        usdc.mint(user1, claimAmount);

        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);

        // Attempt to claim when no strategies are available
        vm.prank(user1);
        vm.expectRevert("No strategies available");
        factory.claim(claimAmount);
    }

    function testRevertIfClaimWithInsufficientAmount() public {
        // Setup: Add a strategy
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 insufficientAmount = 0.5 * 10 ** 6; // 0.5 USDC (less than minimum)
        usdc.mint(user1, insufficientAmount);

        vm.prank(user1);
        usdc.approve(address(factory), insufficientAmount);

        // Attempt to claim with insufficient amount
        vm.prank(user1);
        vm.expectRevert("Amount must be at least minimum claim amount");
        factory.claim(insufficientAmount);

        // Verify strategy wasn't claimed
        assertEq(factory.getAvailableStrategiesCount(), 1, "Strategy should still be available");
        assertEq(strategy1.owner(), address(factory), "Strategy should still be owned by factory");
    }

    function testRevertIfClaimWithInsufficientBalance() public {
        // Setup: Add a strategy
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 claimAmount = 1000 * 10 ** 6; // 1000 USDC
        // Don't mint USDC to user, so they don't have sufficient balance

        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);

        // Attempt to claim should fail due to insufficient balance
        vm.prank(user1);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        factory.claim(claimAmount);
    }

    function testRevertIfClaimWithInsufficientAllowance() public {
        // Setup: Add a strategy and mint USDC to user
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 claimAmount = 1000 * 10 ** 6; // 1000 USDC
        usdc.mint(user1, claimAmount);

        // Don't approve factory to spend USDC

        // Attempt to claim should fail due to insufficient allowance
        vm.prank(user1);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        factory.claim(claimAmount);
    }

    function testRevertIfOwnershipTransferFails() public {
        // Create a strategy that will reject ownership transfer
        MockStrategy faultyStrategy = new MockStrategy(address(usdc), address(this)); // Owned by test contract

        // Transfer ownership to factory first
        faultyStrategy.transferOwnership(address(factory));

        vm.prank(owner);
        factory.add(address(faultyStrategy));

        uint256 claimAmount = 1000 * 10 ** 6; // 1000 USDC
        usdc.mint(user1, claimAmount);

        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);

        // Override the owner() function to return factory address even after transfer
        // This simulates a scenario where ownership transfer appears to succeed but doesn't
        vm.mockCall(
            address(faultyStrategy), abi.encodeWithSelector(Ownable.owner.selector), abi.encode(address(factory))
        );

        // Attempt to claim should fail ownership verification
        vm.prank(user1);
        vm.expectRevert("Ownership transfer failed");
        factory.claim(claimAmount);

        vm.clearMockedCalls();
    }

    function testClaimMinimumAmount() public {
        // Setup: Add a strategy
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 minAmount = factory.minimumClaimAmount(); // Use the public getter
        usdc.mint(user1, minAmount);

        vm.prank(user1);
        usdc.approve(address(factory), minAmount);

        // Should successfully claim with minimum amount
        vm.prank(user1);
        factory.claim(minAmount);

        assertEq(strategy1.owner(), user1, "Strategy should be owned by user");
        assertEq(strategy1.getTotalBalance(), minAmount, "Strategy should have the minimum amount");
    }

    function testGetAvailableStrategiesCount() public {
        // Initially should be 0
        assertEq(factory.getAvailableStrategiesCount(), 0, "Initial count should be 0");

        // Add strategies and verify count increases
        vm.startPrank(owner);
        factory.add(address(strategy1));
        assertEq(factory.getAvailableStrategiesCount(), 1, "Count should be 1");

        factory.add(address(strategy2));
        assertEq(factory.getAvailableStrategiesCount(), 2, "Count should be 2");

        factory.add(address(strategy3));
        assertEq(factory.getAvailableStrategiesCount(), 3, "Count should be 3");
        vm.stopPrank();

        // Claim a strategy and verify count decreases
        uint256 claimAmount = 1000 * 10 ** 6;
        usdc.mint(user1, claimAmount);
        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);
        vm.prank(user1);
        factory.claim(claimAmount);

        assertEq(factory.getAvailableStrategiesCount(), 2, "Count should be 2 after claim");
    }

    function testGetAvailableStrategies() public {
        // Initially should return empty array
        address[] memory strategies = factory.getAvailableStrategies();
        assertEq(strategies.length, 0, "Initial array should be empty");

        // Add strategies and verify array content
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        factory.add(address(strategy3));
        vm.stopPrank();

        strategies = factory.getAvailableStrategies();
        assertEq(strategies.length, 3, "Array should have 3 elements");
        assertEq(strategies[0], address(strategy1), "First element should be strategy1");
        assertEq(strategies[1], address(strategy2), "Second element should be strategy2");
        assertEq(strategies[2], address(strategy3), "Third element should be strategy3");

        // Claim a strategy and verify array updates
        uint256 claimAmount = 1000 * 10 ** 6;
        usdc.mint(user1, claimAmount);
        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);
        vm.prank(user1);
        factory.claim(claimAmount);

        strategies = factory.getAvailableStrategies();
        assertEq(strategies.length, 2, "Array should have 2 elements after claim");
        assertEq(strategies[0], address(strategy1), "First element should still be strategy1");
        assertEq(strategies[1], address(strategy2), "Second element should still be strategy2");
    }

    function testStrategiesPublicArray() public {
        // Add strategies
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        vm.stopPrank();

        // Test direct access to public array
        assertEq(factory.strategies(0), address(strategy1), "Strategy at index 0 should be strategy1");
        assertEq(factory.strategies(1), address(strategy2), "Strategy at index 1 should be strategy2");
    }

    function testOwnerCanRecoverERC20() public {
        // Create a mock token and send it to the factory
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        uint256 tokenAmount = 1000 * 10 ** 18;
        mockToken.mint(address(factory), tokenAmount);

        // Verify factory has the tokens
        assertEq(mockToken.balanceOf(address(factory)), tokenAmount, "Factory should have the tokens");

        // Owner recovers the tokens
        address recipient = makeAddr("recipient");
        vm.prank(owner);
        factory.recoverERC20(address(mockToken), recipient, tokenAmount);

        // Verify tokens were recovered
        assertEq(mockToken.balanceOf(recipient), tokenAmount, "Recipient should have received the tokens");
        assertEq(mockToken.balanceOf(address(factory)), 0, "Factory should have no tokens left");
    }

    function testRevertIfNonOwnerRecoverERC20() public {
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        uint256 tokenAmount = 1000 * 10 ** 18;
        mockToken.mint(address(factory), tokenAmount);

        address recipient = makeAddr("recipient");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.recoverERC20(address(mockToken), recipient, tokenAmount);

        // Verify tokens weren't recovered
        assertEq(mockToken.balanceOf(address(factory)), tokenAmount, "Factory should still have the tokens");
    }

    function testRevertIfRecoverERC20ToZeroAddress() public {
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        uint256 tokenAmount = 1000 * 10 ** 18;
        mockToken.mint(address(factory), tokenAmount);

        vm.prank(owner);
        vm.expectRevert("Cannot send to zero address");
        factory.recoverERC20(address(mockToken), address(0), tokenAmount);
    }

    function testRevertIfRecoverERC20ZeroAmount() public {
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18);
        uint256 tokenAmount = 1000 * 10 ** 18;
        mockToken.mint(address(factory), tokenAmount);

        address recipient = makeAddr("recipient");

        vm.prank(owner);
        vm.expectRevert("Amount must be greater than 0");
        factory.recoverERC20(address(mockToken), recipient, 0);
    }

    function testOwnerCanRecoverETH() public {
        // Send ETH to the factory
        uint256 ethAmount = 1 ether;
        vm.deal(address(factory), ethAmount);

        // Verify factory has the ETH
        assertEq(address(factory).balance, ethAmount, "Factory should have the ETH");

        // Owner recovers the ETH
        address payable recipient = payable(makeAddr("recipient"));
        uint256 initialBalance = recipient.balance;

        vm.prank(owner);
        factory.recoverETH(recipient);

        // Verify ETH was recovered
        assertEq(recipient.balance, initialBalance + ethAmount, "Recipient should have received the ETH");
        assertEq(address(factory).balance, 0, "Factory should have no ETH left");
    }

    function testRevertIfNonOwnerRecoverETH() public {
        uint256 ethAmount = 1 ether;
        vm.deal(address(factory), ethAmount);

        address payable recipient = payable(makeAddr("recipient"));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.recoverETH(recipient);

        // Verify ETH wasn't recovered
        assertEq(address(factory).balance, ethAmount, "Factory should still have the ETH");
    }

    function testRevertIfRecoverETHToZeroAddress() public {
        uint256 ethAmount = 1 ether;
        vm.deal(address(factory), ethAmount);

        vm.prank(owner);
        vm.expectRevert("Cannot send to zero address");
        factory.recoverETH(payable(address(0)));
    }

    function testRevertIfRecoverETHNoBalance() public {
        // Ensure factory has no ETH
        assertEq(address(factory).balance, 0, "Factory should have no ETH");

        address payable recipient = payable(makeAddr("recipient"));

        vm.prank(owner);
        vm.expectRevert("Empty balance");
        factory.recoverETH(recipient);
    }

    function testRevertIfRecoverETHTransferFails() public {
        // Deploy a contract that rejects ETH transfers
        MockRejectETH rejectContract = new MockRejectETH();

        uint256 ethAmount = 1 ether;
        vm.deal(address(factory), ethAmount);

        vm.prank(owner);
        vm.expectRevert("Transfer failed");
        factory.recoverETH(payable(address(rejectContract)));

        // Verify ETH remains in factory
        assertEq(address(factory).balance, ethAmount, "Factory should still have the ETH");
    }

    function testRevertIfERC20TransferFails() public {
        // Deploy a failing token
        MockFailingERC20 failingToken = new MockFailingERC20();
        uint256 tokenAmount = 1000 * 10 ** 18;

        // Manually set balance without using transfer (to bypass the failing transfer)
        vm.store(
            address(failingToken),
            keccak256(abi.encode(address(factory), 0)), // balances mapping slot 0
            bytes32(tokenAmount)
        );

        address recipient = makeAddr("recipient");

        vm.prank(owner);
        vm.expectRevert("Transfer failed");
        factory.recoverERC20(address(failingToken), recipient, tokenAmount);
    }

    function testMultipleUsersClaimStrategies() public {
        // Setup: Add multiple strategies
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        factory.add(address(strategy3));
        vm.stopPrank();

        // Setup users with USDC
        uint256 claimAmount = 1000 * 10 ** 6;
        usdc.mint(user1, claimAmount);
        usdc.mint(user2, claimAmount);

        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);
        vm.prank(user2);
        usdc.approve(address(factory), claimAmount);

        // User1 claims a strategy
        vm.prank(user1);
        factory.claim(claimAmount);

        assertEq(factory.getAvailableStrategiesCount(), 2, "Should have 2 strategies remaining");
        assertEq(strategy3.owner(), user1, "User1 should own strategy3");

        // User2 claims another strategy
        vm.prank(user2);
        factory.claim(claimAmount);

        assertEq(factory.getAvailableStrategiesCount(), 1, "Should have 1 strategy remaining");
        assertEq(strategy2.owner(), user2, "User2 should own strategy2");

        // Only strategy1 should remain
        address[] memory remaining = factory.getAvailableStrategies();
        assertEq(remaining.length, 1);
        assertEq(remaining[0], address(strategy1));
    }

    function testFactoryWorkflowFromStartToFinish() public {
        // 1. Deploy factory (done in setUp)
        assertEq(factory.getAvailableStrategiesCount(), 0);

        // 2. Owner adds strategies
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        vm.stopPrank();

        assertEq(factory.getAvailableStrategiesCount(), 2);

        // 3. Users claim strategies
        uint256 claimAmount = 1000 * 10 ** 6;
        usdc.mint(user1, claimAmount);
        usdc.mint(user2, claimAmount);

        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);
        vm.prank(user1);
        factory.claim(claimAmount);

        vm.prank(user2);
        usdc.approve(address(factory), claimAmount);
        vm.prank(user2);
        factory.claim(claimAmount);

        // 4. All strategies should be claimed
        assertEq(factory.getAvailableStrategiesCount(), 0);
        assertEq(strategy2.owner(), user1);
        assertEq(strategy1.owner(), user2);

        // 5. Users should have deposited funds in their strategies
        assertEq(strategy1.getTotalBalance(), claimAmount);
        assertEq(strategy2.getTotalBalance(), claimAmount);

        // 6. Factory should have no USDC left (it transferred all to strategies)
        assertEq(usdc.balanceOf(address(factory)), 0);
    }

    function testClaimWithExactMinimumAmount() public {
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 minAmount = factory.minimumClaimAmount(); // Use the public getter
        usdc.mint(user1, minAmount);

        vm.prank(user1);
        usdc.approve(address(factory), minAmount);
        vm.prank(user1);
        factory.claim(minAmount);

        assertEq(strategy1.owner(), user1);
        assertEq(strategy1.getTotalBalance(), minAmount);
    }

    function testClaimWithLargeAmount() public {
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 largeAmount = 1000000 * 10 ** 6; // 1 million USDC
        usdc.mint(user1, largeAmount);

        vm.prank(user1);
        usdc.approve(address(factory), largeAmount);
        vm.prank(user1);
        factory.claim(largeAmount);

        assertEq(strategy1.owner(), user1);
        assertEq(strategy1.getTotalBalance(), largeAmount);
    }

    function testAddSameStrategyTwice() public {
        vm.startPrank(owner);
        factory.add(address(strategy1));

        // Adding the same strategy again should revert
        vm.expectRevert("Strategy already exists");
        factory.add(address(strategy1));
        vm.stopPrank();

        assertEq(factory.getAvailableStrategiesCount(), 1);

        address[] memory strategies = factory.getAvailableStrategies();
        assertEq(strategies[0], address(strategy1));
    }

    function testOwnerCanClaimForAddress() public {
        // Setup: Add a strategy
        vm.prank(owner);
        factory.add(address(strategy1));

        address beneficiary = makeAddr("beneficiary");

        // Verify initial state
        assertEq(factory.getAvailableStrategiesCount(), 1, "Should have 1 strategy available");
        assertEq(strategy1.owner(), address(factory), "Strategy should be owned by factory");

        // Owner claims strategy for beneficiary
        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(factory));
        emit StrategyClaimedForAddress(beneficiary, address(strategy1));
        factory.claimForAddress(beneficiary);

        // Verify the claim was successful
        assertEq(factory.getAvailableStrategiesCount(), 0, "Should have 0 strategies available");
        assertEq(strategy1.owner(), beneficiary, "Strategy should now be owned by beneficiary");
        assertEq(strategy1.getTotalBalance(), 0, "Strategy should have no balance (no deposit)");
    }

    function testRevertIfNonOwnerClaimsForAddress() public {
        vm.prank(owner);
        factory.add(address(strategy1));

        address beneficiary = makeAddr("beneficiary");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.claimForAddress(beneficiary);

        // Verify no claim occurred
        assertEq(factory.getAvailableStrategiesCount(), 1, "Should still have 1 strategy available");
        assertEq(strategy1.owner(), address(factory), "Strategy should still be owned by factory");
    }

    function testRevertIfClaimForZeroAddress() public {
        vm.prank(owner);
        factory.add(address(strategy1));

        vm.prank(owner);
        vm.expectRevert("Invalid beneficiary address");
        factory.claimForAddress(address(0));

        // Verify no claim occurred
        assertEq(factory.getAvailableStrategiesCount(), 1, "Should still have 1 strategy available");
        assertEq(strategy1.owner(), address(factory), "Strategy should still be owned by factory");
    }

    function testRevertIfClaimForAddressWithNoStrategies() public {
        address beneficiary = makeAddr("beneficiary");

        vm.prank(owner);
        vm.expectRevert("No strategies available");
        factory.claimForAddress(beneficiary);
    }

    function testClaimForAddressPopsFromEnd() public {
        // Setup: Add multiple strategies
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        factory.add(address(strategy3));
        vm.stopPrank();

        address beneficiary = makeAddr("beneficiary");

        // Verify initial order
        address[] memory initialStrategies = factory.getAvailableStrategies();
        assertEq(initialStrategies[0], address(strategy1));
        assertEq(initialStrategies[1], address(strategy2));
        assertEq(initialStrategies[2], address(strategy3));

        // Owner claims strategy for beneficiary - should get the last one (strategy3)
        vm.prank(owner);
        factory.claimForAddress(beneficiary);

        // Verify strategy3 was claimed and removed from the end
        assertEq(factory.getAvailableStrategiesCount(), 2, "Should have 2 strategies remaining");
        assertEq(strategy3.owner(), beneficiary, "Strategy3 should be owned by beneficiary");

        address[] memory remainingStrategies = factory.getAvailableStrategies();
        assertEq(remainingStrategies.length, 2);
        assertEq(remainingStrategies[0], address(strategy1));
        assertEq(remainingStrategies[1], address(strategy2));
    }

    function testClaimForAddressOwnershipTransferFails() public {
        // Create a strategy that will reject ownership transfer
        MockStrategy faultyStrategy = new MockStrategy(address(usdc), address(this)); // Owned by test contract

        // Transfer ownership to factory first
        faultyStrategy.transferOwnership(address(factory));

        vm.prank(owner);
        factory.add(address(faultyStrategy));

        address beneficiary = makeAddr("beneficiary");

        // Override the owner() function to return factory address even after transfer
        // This simulates a scenario where ownership transfer appears to succeed but doesn't
        vm.mockCall(
            address(faultyStrategy), abi.encodeWithSelector(Ownable.owner.selector), abi.encode(address(factory))
        );

        // Attempt to claim should fail ownership verification
        vm.prank(owner);
        vm.expectRevert("Ownership transfer failed");
        factory.claimForAddress(beneficiary);

        vm.clearMockedCalls();
    }

    function testOwnerCanSetMinimumClaimAmount() public {
        // Check initial minimum claim amount
        assertEq(factory.minimumClaimAmount(), 1e6, "Initial minimum should be 1 USDC");

        uint256 newMinimum = 5e6; // 5 USDC

        // Owner sets new minimum
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(factory));
        emit MinimumClaimAmountUpdated(1e6, newMinimum);
        factory.setMinimumClaimAmount(newMinimum);

        // Verify minimum was updated
        assertEq(factory.minimumClaimAmount(), newMinimum, "Minimum should be updated");
    }

    function testRevertIfNonOwnerSetsMinimumClaimAmount() public {
        uint256 newMinimum = 5e6; // 5 USDC

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.setMinimumClaimAmount(newMinimum);

        // Verify minimum wasn't changed
        assertEq(factory.minimumClaimAmount(), 1e6, "Minimum should remain unchanged");
    }

    function testClaimWithUpdatedMinimumAmount() public {
        // Setup: Add a strategy and update minimum
        vm.prank(owner);
        factory.add(address(strategy1));

        uint256 newMinimum = 5e6; // 5 USDC
        vm.prank(owner);
        factory.setMinimumClaimAmount(newMinimum);

        // Try to claim with old minimum (should fail)
        uint256 oldMinimum = 1e6;
        usdc.mint(user1, oldMinimum);
        vm.prank(user1);
        usdc.approve(address(factory), oldMinimum);

        vm.prank(user1);
        vm.expectRevert("Amount must be at least minimum claim amount");
        factory.claim(oldMinimum);

        // Claim with new minimum (should succeed)
        usdc.mint(user1, newMinimum - oldMinimum); // mint the difference
        vm.prank(user1);
        usdc.approve(address(factory), newMinimum);

        vm.prank(user1);
        factory.claim(newMinimum);

        assertEq(strategy1.owner(), user1, "Strategy should be owned by user");
        assertEq(strategy1.getTotalBalance(), newMinimum, "Strategy should have the new minimum amount");
    }

    function testMixedClaimAndClaimForAddress() public {
        // Setup: Add multiple strategies
        vm.startPrank(owner);
        factory.add(address(strategy1));
        factory.add(address(strategy2));
        factory.add(address(strategy3));
        vm.stopPrank();

        // User claims a strategy normally
        uint256 claimAmount = 1000 * 10 ** 6;
        usdc.mint(user1, claimAmount);
        vm.prank(user1);
        usdc.approve(address(factory), claimAmount);
        vm.prank(user1);
        factory.claim(claimAmount);

        assertEq(strategy3.owner(), user1, "User1 should own strategy3");
        assertEq(strategy3.getTotalBalance(), claimAmount, "Strategy3 should have deposit");

        // Owner claims for an address
        address beneficiary = makeAddr("beneficiary");
        vm.prank(owner);
        factory.claimForAddress(beneficiary);

        assertEq(strategy2.owner(), beneficiary, "Beneficiary should own strategy2");
        assertEq(strategy2.getTotalBalance(), 0, "Strategy2 should have no deposit");

        // Only strategy1 should remain
        assertEq(factory.getAvailableStrategiesCount(), 1, "Should have 1 strategy remaining");
        address[] memory remaining = factory.getAvailableStrategies();
        assertEq(remaining[0], address(strategy1));
    }

    function testGetMinimumClaimAmountAfterUpdate() public {
        // Test that the public getter works correctly
        assertEq(factory.minimumClaimAmount(), 1e6, "Initial minimum should be 1 USDC");

        vm.prank(owner);
        factory.setMinimumClaimAmount(2e6);

        assertEq(factory.minimumClaimAmount(), 2e6, "Minimum should be updated to 2 USDC");
    }
}
