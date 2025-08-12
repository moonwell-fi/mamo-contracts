// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "@forge-std/Test.sol";

import {TransferAndEarn} from "@contracts/TransferAndEarn.sol";

import {INonfungiblePositionManager} from "@contracts/interfaces/INonfungiblePositionManager.sol";
import {ITransferAndEarn} from "@contracts/interfaces/ITransferAndEarn.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockNonfungiblePositionManager {
    mapping(uint256 => address) public ownerOfMapping;
    mapping(uint256 => PositionInfo) public positionsMapping;

    struct PositionInfo {
        address token0;
        address token1;
    }

    function setOwner(uint256 tokenId, address owner) external {
        ownerOfMapping[tokenId] = owner;
    }

    function setPosition(uint256 tokenId, address token0, address token1) external {
        positionsMapping[tokenId] = PositionInfo(token0, token1);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return ownerOfMapping[tokenId];
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        PositionInfo memory position = positionsMapping[tokenId];
        return (0, address(0), position.token0, position.token1, 0, 0, 0, 0, 0, 0, 0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = 100e6; // Mock USDC amount
        amount1 = 50e6; // Mock token1 amount

        // Mock transfer tokens to recipient
        if (positionsMapping[params.tokenId].token0 != address(0)) {
            MockERC20(positionsMapping[params.tokenId].token0).mint(params.recipient, amount0);
            MockERC20(positionsMapping[params.tokenId].token1).mint(params.recipient, amount1);
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOfMapping[tokenId] == from, "Not owner");
        ownerOfMapping[tokenId] = to;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TransferAndEarnUnitTest is Test {
    TransferAndEarn public transferAndEarn;
    MockNonfungiblePositionManager public mockPositionManager;
    MockERC20 public mockToken0;
    MockERC20 public mockToken1;

    address public owner;
    address public feeCollector;
    address public user;

    uint256 public constant TOKEN_ID_1 = 1;
    uint256 public constant TOKEN_ID_2 = 2;
    address public constant POSITION_MANAGER_ADDRESS = 0x827922686190790b37229fd06084350E74485b72;

    event NFTTransferred(uint256 indexed tokenId, address indexed recipient);

    function setUp() public {
        owner = makeAddr("owner");
        feeCollector = makeAddr("feeCollector");
        user = makeAddr("user");

        // Deploy mock contracts
        mockPositionManager = new MockNonfungiblePositionManager();
        mockToken0 = new MockERC20();
        mockToken1 = new MockERC20();

        // Override the immutable position manager using vm.etch before deploying
        bytes memory mockCode = address(mockPositionManager).code;
        vm.etch(POSITION_MANAGER_ADDRESS, mockCode);

        // Deploy TransferAndEarn contract
        vm.prank(owner);
        transferAndEarn = new TransferAndEarn(feeCollector, owner);

        // Set up mock data - need to call on the etched address
        MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).setOwner(TOKEN_ID_1, address(transferAndEarn));
        MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).setOwner(TOKEN_ID_2, address(transferAndEarn));
        MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).setPosition(
            TOKEN_ID_1, address(mockToken0), address(mockToken1)
        );
        MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).setPosition(
            TOKEN_ID_2, address(mockToken0), address(mockToken1)
        );

        vm.label(address(transferAndEarn), "TransferAndEarn");
        vm.label(owner, "Owner");
        vm.label(feeCollector, "FeeCollector");
        vm.label(user, "User");
    }

    function testInitialization() public view {
        assertEq(transferAndEarn.feeCollector(), feeCollector, "incorrect fee collector");
        assertEq(transferAndEarn.owner(), owner, "incorrect owner");
    }

    function testSetFeeCollector() public {
        address newFeeCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        transferAndEarn.setFeeCollector(newFeeCollector);

        assertEq(transferAndEarn.feeCollector(), newFeeCollector, "fee collector not updated");
    }

    function testSetFeeCollectorZeroAddressFails() public {
        vm.prank(owner);
        vm.expectRevert("Fee collector cannot be zero");
        transferAndEarn.setFeeCollector(address(0));
    }

    function testSetFeeCollectorUnauthorizedFails() public {
        address newFeeCollector = makeAddr("newFeeCollector");

        vm.prank(user);
        vm.expectRevert();
        transferAndEarn.setFeeCollector(newFeeCollector);
    }

    function testOnERC721ReceivedFromPositionManager() public {
        vm.prank(POSITION_MANAGER_ADDRESS);
        bytes4 selector = transferAndEarn.onERC721Received(address(0), address(0), TOKEN_ID_1, "");
        assertEq(selector, transferAndEarn.onERC721Received.selector, "incorrect selector returned");
    }

    function testOnERC721ReceivedUnauthorizedFails() public {
        vm.prank(user);
        vm.expectRevert("Only position manager can call this");
        transferAndEarn.onERC721Received(address(0), address(0), TOKEN_ID_1, "");
    }

    function testAdd() public {
        transferAndEarn.add(TOKEN_ID_1);

        assertTrue(transferAndEarn.lockedPositions(TOKEN_ID_1), "position should be locked");
    }

    function testAddAlreadyLockedFails() public {
        transferAndEarn.add(TOKEN_ID_1);

        vm.expectRevert("LP already locked");
        transferAndEarn.add(TOKEN_ID_1);
    }

    function testAddNotOwnedByContractFails() public {
        MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).setOwner(TOKEN_ID_1, user);

        vm.expectRevert("this contract doesn't have the LP NFT");
        transferAndEarn.add(TOKEN_ID_1);
    }

    function testEarn() public {
        transferAndEarn.add(TOKEN_ID_1);

        vm.expectEmit(true, true, true, true);
        emit ITransferAndEarn.ClaimedFees(address(this), address(mockToken0), address(mockToken1), 0, 0, 100e6, 50e6);

        (uint256 amount0, uint256 amount1) = transferAndEarn.earn(TOKEN_ID_1);

        assertEq(amount0, 100e6, "incorrect amount0");
        assertEq(amount1, 50e6, "incorrect amount1");
        assertEq(mockToken0.balanceOf(feeCollector), 100e6, "fee collector should receive token0");
        assertEq(mockToken1.balanceOf(feeCollector), 50e6, "fee collector should receive token1");
    }

    function testEarnNotLockedFails() public {
        vm.expectRevert("LP not locked");
        transferAndEarn.earn(TOKEN_ID_1);
    }

    function testEarnMany() public {
        transferAndEarn.add(TOKEN_ID_1);
        transferAndEarn.add(TOKEN_ID_2);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_1;
        tokenIds[1] = TOKEN_ID_2;

        (uint256[] memory amounts0, uint256[] memory amounts1) = transferAndEarn.earnMany(tokenIds);

        assertEq(amounts0.length, 2, "incorrect amounts0 length");
        assertEq(amounts1.length, 2, "incorrect amounts1 length");
        assertEq(amounts0[0], 100e6, "incorrect amount0 for token 1");
        assertEq(amounts0[1], 100e6, "incorrect amount0 for token 2");
        assertEq(amounts1[0], 50e6, "incorrect amount1 for token 1");
        assertEq(amounts1[1], 50e6, "incorrect amount1 for token 2");
    }

    function testTransfer() public {
        transferAndEarn.add(TOKEN_ID_1);

        vm.expectEmit(true, true, false, false);
        emit NFTTransferred(TOKEN_ID_1, owner);

        vm.prank(owner);
        transferAndEarn.transfer(TOKEN_ID_1);

        assertFalse(transferAndEarn.lockedPositions(TOKEN_ID_1), "position should be unlocked");
        assertEq(
            MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).ownerOf(TOKEN_ID_1),
            owner,
            "NFT should be transferred to owner"
        );
    }

    function testTransferNotLockedFails() public {
        vm.prank(owner);
        vm.expectRevert("LP not locked");
        transferAndEarn.transfer(TOKEN_ID_1);
    }

    function testTransferUnauthorizedFails() public {
        transferAndEarn.add(TOKEN_ID_1);

        vm.prank(user);
        vm.expectRevert();
        transferAndEarn.transfer(TOKEN_ID_1);
    }

    function testTransferMany() public {
        transferAndEarn.add(TOKEN_ID_1);
        transferAndEarn.add(TOKEN_ID_2);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_1;
        tokenIds[1] = TOKEN_ID_2;

        vm.expectEmit(true, true, false, false);
        emit NFTTransferred(TOKEN_ID_1, owner);
        vm.expectEmit(true, true, false, false);
        emit NFTTransferred(TOKEN_ID_2, owner);

        vm.prank(owner);
        transferAndEarn.transferMany(tokenIds);

        assertFalse(transferAndEarn.lockedPositions(TOKEN_ID_1), "position 1 should be unlocked");
        assertFalse(transferAndEarn.lockedPositions(TOKEN_ID_2), "position 2 should be unlocked");
        assertEq(
            MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).ownerOf(TOKEN_ID_1),
            owner,
            "NFT 1 should be transferred to owner"
        );
        assertEq(
            MockNonfungiblePositionManager(POSITION_MANAGER_ADDRESS).ownerOf(TOKEN_ID_2),
            owner,
            "NFT 2 should be transferred to owner"
        );
    }

    function testTransferManyUnauthorizedFails() public {
        transferAndEarn.add(TOKEN_ID_1);
        transferAndEarn.add(TOKEN_ID_2);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_1;
        tokenIds[1] = TOKEN_ID_2;

        vm.prank(user);
        vm.expectRevert();
        transferAndEarn.transferMany(tokenIds);
    }
}
