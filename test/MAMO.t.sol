// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "@forge-std/Test.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@test/BaseTest.t.sol";

contract MAMOUnitTest is BaseTest {
    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        mamoProxy.transferOwnership(address(this));
        mamoProxy.acceptOwnership();
    }

    function testSetup() public view {
        // ERC20Permit has a DOMAIN_SEPARATOR function, but it's not exposed in the MAMO contract
        // Instead, we'll check other EIP-712 related functions
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
        ) = mamoProxy.eip712Domain();
        assertEq(fields, hex"0f", "incorrect fields");
        assertEq(version, "1", "incorrect version");
        assertEq(chainId, block.chainid, "incorrect chain id");
        assertEq(salt, bytes32(0), "incorrect salt");
        assertEq(verifyingContract, address(mamoProxy), "incorrect verifying contract");
        assertEq(name, "MAMO", "incorrect name from eip712Domain()");
        assertEq(mamoProxy.name(), "MAMO", "incorrect name");
        assertEq(mamoProxy.symbol(), "MAMO", "incorrect symbol");
        assertEq(mamoProxy.totalSupply(), 0, "incorrect total supply");
        assertEq(mamoProxy.owner(), address(this), "incorrect owner");
        assertEq(mamoProxy.pendingOwner(), address(0), "incorrect pending owner");
        assertEq(mamoProxy.CLOCK_MODE(), "mode=timestamp", "incorrect clock mode");
        assertEq(mamoProxy.clock(), block.timestamp, "incorrect timestamp");
        assertEq(mamoProxy.maxSupply(), 1_000_000_000 * 1e18, "incorrect max supply");
        assertEq(
            mamoProxy.bufferCap(address(wormholeBridgeAdapterProxy)),
            type(uint112).max,
            "incorrect bridge adapter buffer cap"
        );

        /// PROXY OWNERSHIP

        /// proxy admin starts off as this address
        assertEq(
            proxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(address(mamoProxy))),
            address(proxyAdmin),
            "incorrect proxy admin"
        );

        /// PAUSING
        assertEq(mamoProxy.pauseGuardian(), pauseGuardian, "incorrect pause guardian");
        assertEq(mamoProxy.pauseStartTime(), 0, "incorrect pause start time");
        assertEq(mamoProxy.pauseDuration(), pauseDuration, "incorrect pause duration");
        assertFalse(mamoProxy.paused(), "incorrectly paused");
        assertFalse(mamoProxy.pauseUsed(), "pause should not be used");
    }

    function testInitializationFailsPauseDurationGtMax() public {
        uint256 maxPauseDuration = mamoProxy.MAX_PAUSE_DURATION();

        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,address,(uint112,uint128,address)[],uint128,address)",
            "MAMO",
            "MAMO",
            owner,
            new MintLimits.RateLimitMidPointInfo[](0),
            /// empty array as it will fail anyway
            uint128(maxPauseDuration + 1),
            pauseGuardian
        );

        vm.expectRevert("MAMO: pause duration too long");
        new TransparentUpgradeableProxy(address(mamoLogic), address(proxyAdmin), initData);
    }

    function testPendingOwnerAccepts() public {
        mamoProxy.transferOwnership(owner);

        vm.prank(owner);
        mamoProxy.acceptOwnership();

        assertEq(mamoProxy.owner(), owner, "incorrect owner");
        assertEq(mamoProxy.pendingOwner(), address(0), "incorrect pending owner");
    }

    function testInitializeLogicContractFails() public {
        vm.expectRevert("Initializable: contract is already initialized");
        mamoLogic.initialize(
            "MAMO",
            "MAMO",
            owner,
            new MintLimits.RateLimitMidPointInfo[](0),
            /// empty array as it will fail anyway
            pauseDuration,
            pauseGuardian
        );
    }

    function testTransferToTokenContractFails() public {
        testLockboxCanMint(1);

        vm.expectRevert("xERC20: cannot transfer to token contract");
        mamoProxy.transfer(address(mamoProxy), 1);
    }

    function testMintOverMaxSupplyFails() public {
        uint256 maxSupply = mamoProxy.maxSupply();

        vm.prank(address(wormholeBridgeAdapterProxy));
        vm.expectRevert("xERC20: max supply exceeded");
        mamoProxy.mint(address(wormholeBridgeAdapterProxy), maxSupply + 1);
    }

    function testLockboxCanMint(uint112 mintAmount) public {
        mintAmount = uint112(_bound(mintAmount, 1, mamoProxy.maxSupply()));

        _bridgeCanMint(mintAmount);
    }

    function testLockboxCanMintTo(address to, uint112 mintAmount) public {
        /// cannot transfer to the proxy contract
        to = to == address(mamoProxy) ? address(this) : address(103131212121482329);

        mintAmount = uint112(_bound(mintAmount, 1, mamoProxy.maxSupply()));

        _bridgeCanMintTo(to, mintAmount);
    }

    function testLockboxCanMintBurnTo(uint112 mintAmount) public {
        address to = address(this);

        mintAmount = uint112(_bound(mintAmount, 1, mamoProxy.maxSupply()));

        _bridgeCanMintTo(to, mintAmount);
        _bridgeCanBurnTo(to, mintAmount);
    }

    function testLockBoxCanBurn(uint112 burnAmount) public {
        burnAmount = uint112(_bound(burnAmount, 1, mamoProxy.maxSupply()));

        testLockboxCanMint(burnAmount);
        _bridgeCanBurn(burnAmount);
    }

    function testLockBoxCanMintBurn(uint112 mintAmount) public {
        mintAmount = uint112(_bound(mintAmount, 1, mamoProxy.maxSupply()));

        _bridgeCanMint(mintAmount);
        _bridgeCanBurn(mintAmount);

        assertEq(mamoProxy.totalSupply(), 0, "incorrect total supply");
    }

    /// ACL

    function testGrantGuardianNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.grantPauseGuardian(address(0));
    }

    function testSetPauseDurationNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.setPauseDuration(0);
    }

    function testSetBufferCapNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.setBufferCap(address(0), 0);
    }

    function testSetRateLimitPerSecondNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.setRateLimitPerSecond(address(0), 0);
    }

    function testAddBridgeNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.addBridge(MintLimits.RateLimitMidPointInfo({bridge: address(0), rateLimitPerSecond: 0, bufferCap: 0}));
    }

    function testAddBridgesNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.addBridges(new MintLimits.RateLimitMidPointInfo[](0));
    }

    function testRemoveBridgeNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.removeBridge(address(0));
    }

    function testRemoveBridgesNonOwnerReverts() public {
        testPendingOwnerAccepts();
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.removeBridges(new address[](0));
    }

    function testGrantGuardianOwnerSucceeds(address newPauseGuardian) public {
        mamoProxy.grantPauseGuardian(newPauseGuardian);
        assertEq(mamoProxy.pauseGuardian(), newPauseGuardian, "incorrect pause guardian");
    }

    function testGrantPauseGuardianWhilePausedFails() public {
        vm.prank(pauseGuardian);
        mamoProxy.pause();
        assertTrue(mamoProxy.paused(), "contract not paused");
        address newPauseGuardian = address(0xffffffff);

        vm.expectRevert("Pausable: paused");
        mamoProxy.grantPauseGuardian(newPauseGuardian);
        assertTrue(mamoProxy.paused(), "contract not paused");
    }

    function testUpdatePauseDurationSucceeds() public {
        uint128 newDuration = 8 days;
        mamoProxy.setPauseDuration(newDuration);
        assertEq(mamoProxy.pauseDuration(), newDuration, "incorrect pause duration");
    }

    function testUpdatePauseDurationGtMaxPauseDurationFails() public {
        uint128 newDuration = uint128(mamoProxy.MAX_PAUSE_DURATION() + 1);
        vm.expectRevert("MAMO: pause duration too long");

        mamoProxy.setPauseDuration(newDuration);
    }

    function testSetBufferCapOwnerSucceeds(uint112 bufferCap) public {
        bufferCap = uint112(_bound(bufferCap, mamoProxy.MIN_BUFFER_CAP() + 1, type(uint112).max));

        mamoProxy.setBufferCap(address(wormholeBridgeAdapterProxy), bufferCap);
        assertEq(mamoProxy.bufferCap(address(wormholeBridgeAdapterProxy)), bufferCap, "incorrect buffer cap");
    }

    function testSetBufferCapZeroFails() public {
        uint112 bufferCap = 0;

        vm.expectRevert("MintLimits: bufferCap cannot be 0");
        mamoProxy.setBufferCap(address(wormholeBridgeAdapterProxy), bufferCap);
    }

    function testSetRateLimitPerSecondOwnerSucceeds(uint128 newRateLimitPerSecond) public {
        newRateLimitPerSecond = uint128(_bound(newRateLimitPerSecond, 1, mamoProxy.MAX_RATE_LIMIT_PER_SECOND()));
        mamoProxy.setRateLimitPerSecond(address(wormholeBridgeAdapterProxy), newRateLimitPerSecond);

        assertEq(
            mamoProxy.rateLimitPerSecond(address(wormholeBridgeAdapterProxy)),
            newRateLimitPerSecond,
            "incorrect rate limit per second"
        );
    }

    /// add a new bridge and rate limit
    function testAddNewBridgeOwnerSucceeds(address bridge, uint128 newRateLimitPerSecond, uint112 newBufferCap)
        public
    {
        mamoProxy.removeBridge(address(wormholeBridgeAdapterProxy));

        if (mamoProxy.buffer(bridge) != 0) {
            mamoProxy.removeBridge(bridge);
        }

        /// bound input so bridge is not zero address
        bridge = address(uint160(_bound(uint256(uint160(bridge)), 1, type(uint160).max)));

        newRateLimitPerSecond = uint128(_bound(newRateLimitPerSecond, 1, mamoProxy.MAX_RATE_LIMIT_PER_SECOND()));
        newBufferCap = uint112(_bound(newBufferCap, mamoProxy.MIN_BUFFER_CAP() + 1, type(uint112).max));

        MintLimits.RateLimitMidPointInfo memory newBridge = MintLimits.RateLimitMidPointInfo({
            bridge: bridge,
            bufferCap: newBufferCap,
            rateLimitPerSecond: newRateLimitPerSecond
        });

        mamoProxy.addBridge(newBridge);

        assertEq(mamoProxy.rateLimitPerSecond(bridge), newRateLimitPerSecond, "incorrect rate limit per second");

        assertEq(mamoProxy.bufferCap(bridge), newBufferCap, "incorrect buffer cap");
    }

    /// add a new bridge and rate limit
    function testAddNewBridgesOwnerSucceeds(address bridge, uint128 newRateLimitPerSecond, uint112 newBufferCap)
        public
    {
        mamoProxy.removeBridge(address(wormholeBridgeAdapterProxy));

        bridge = address(uint160(_bound(uint256(uint160(bridge)), 1, type(uint160).max)));
        newRateLimitPerSecond = uint128(_bound(newRateLimitPerSecond, 1, mamoProxy.MAX_RATE_LIMIT_PER_SECOND()));
        newBufferCap = uint112(_bound(newBufferCap, mamoProxy.MIN_BUFFER_CAP() + 1, type(uint112).max));

        MintLimits.RateLimitMidPointInfo[] memory newBridge = new MintLimits.RateLimitMidPointInfo[](1);

        newBridge[0].bridge = bridge;
        newBridge[0].bufferCap = newBufferCap;
        newBridge[0].rateLimitPerSecond = newRateLimitPerSecond;

        mamoProxy.addBridges(newBridge);

        assertEq(mamoProxy.rateLimitPerSecond(bridge), newRateLimitPerSecond, "incorrect rate limit per second");

        assertEq(mamoProxy.bufferCap(bridge), newBufferCap, "incorrect buffer cap");
    }

    function testAddNewBridgeWithExistingLimitFails() public {
        address newBridge = address(0x1111777777);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = 20_000_000 * 1e18;

        testAddNewBridgeOwnerSucceeds(newBridge, rateLimitPerSecond, bufferCap);

        MintLimits.RateLimitMidPointInfo memory bridge = MintLimits.RateLimitMidPointInfo({
            bridge: newBridge,
            bufferCap: bufferCap,
            rateLimitPerSecond: rateLimitPerSecond
        });

        vm.expectRevert("MintLimits: rate limit already exists");
        mamoProxy.addBridge(bridge);
    }

    function testAddNewBridgeWithBufferBelowMinFails() public {
        address newBridge = address(0x1111777777);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = mamoProxy.MIN_BUFFER_CAP();

        MintLimits.RateLimitMidPointInfo memory bridge = MintLimits.RateLimitMidPointInfo({
            bridge: newBridge,
            bufferCap: bufferCap,
            rateLimitPerSecond: rateLimitPerSecond
        });

        vm.expectRevert("MintLimits: buffer cap below min");
        mamoProxy.addBridge(bridge);
    }

    function testSetBridgeBufferBelowMinFails() public {
        address newBridge = address(0x1111777777);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = mamoProxy.MIN_BUFFER_CAP();
        testAddNewBridgeOwnerSucceeds(newBridge, rateLimitPerSecond, bufferCap + 1);

        vm.expectRevert("MintLimits: buffer cap below min");
        mamoProxy.setBufferCap(newBridge, bufferCap);
    }

    function testAddNewBridgeOverMaxRateLimitPerSecondFails() public {
        address newBridge = address(0x1111777777);
        uint112 bufferCap = 20_000_000 * 1e18;

        MintLimits.RateLimitMidPointInfo memory bridge = MintLimits.RateLimitMidPointInfo({
            bridge: newBridge,
            bufferCap: bufferCap,
            rateLimitPerSecond: uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND() + 1)
        });

        vm.expectRevert("MintLimits: rateLimitPerSecond too high");
        mamoProxy.addBridge(bridge);
    }

    function testSetExistingBridgeOverMaxRateLimitPerSecondFails() public {
        uint128 maxRateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());

        vm.expectRevert("MintLimits: rateLimitPerSecond too high");
        mamoProxy.setRateLimitPerSecond(address(wormholeBridgeAdapterProxy), maxRateLimitPerSecond + 1);
    }

    function testAddNewBridgeInvalidAddressFails() public {
        address newBridge = address(0);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = 20_000_000 * 1e18;

        MintLimits.RateLimitMidPointInfo memory bridge = MintLimits.RateLimitMidPointInfo({
            bridge: newBridge,
            bufferCap: bufferCap,
            rateLimitPerSecond: rateLimitPerSecond
        });

        vm.expectRevert("MintLimits: invalid bridge address");
        mamoProxy.addBridge(bridge);
    }

    function testAddNewBridgeBufferCapZeroFails() public {
        uint112 bufferCap = 0;
        address newBridge = address(100);
        uint128 rateLimitPerSecond = 1_000 * 1e18;

        MintLimits.RateLimitMidPointInfo memory bridge = MintLimits.RateLimitMidPointInfo({
            bridge: newBridge,
            bufferCap: bufferCap,
            rateLimitPerSecond: rateLimitPerSecond
        });

        vm.expectRevert("MintLimits: buffer cap below min");
        mamoProxy.addBridge(bridge);
    }

    function testSetRateLimitOnNonExistentBridgeFails(uint128 newRateLimitPerSecond) public {
        newRateLimitPerSecond = uint128(_bound(newRateLimitPerSecond, 1, mamoProxy.MAX_RATE_LIMIT_PER_SECOND()));

        vm.expectRevert("MintLimits: non-existent rate limit");
        mamoProxy.setRateLimitPerSecond(address(0), newRateLimitPerSecond);
    }

    function testSetBufferCapOnNonExistentBridgeFails(uint112 newBufferCap) public {
        newBufferCap = uint112(_bound(newBufferCap, 1, type(uint112).max));
        vm.expectRevert("MintLimits: non-existent rate limit");
        mamoProxy.setBufferCap(address(0), newBufferCap);
    }

    function testRemoveBridgeOwnerSucceeds() public {
        mamoProxy.removeBridge(address(wormholeBridgeAdapterProxy));

        assertEq(mamoProxy.bufferCap(address(wormholeBridgeAdapterProxy)), 0, "incorrect buffer cap");
        assertEq(
            mamoProxy.rateLimitPerSecond(address(wormholeBridgeAdapterProxy)), 0, "incorrect rate limit per second"
        );
        assertEq(mamoProxy.buffer(address(wormholeBridgeAdapterProxy)), 0, "incorrect buffer");
    }

    function testCannotRemoveNonExistentBridge() public {
        vm.expectRevert("MintLimits: cannot remove non-existent rate limit");
        mamoProxy.removeBridge(address(0));
    }

    function testCannotRemoveNonExistentBridges() public {
        vm.expectRevert("MintLimits: cannot remove non-existent rate limit");
        mamoProxy.removeBridges(new address[](2));
    }

    function testRemoveBridgesOwnerSucceeds() public {
        address[] memory bridges = new address[](2);
        bridges[0] = address(10000);
        bridges[1] = address(10001);

        {
            MintLimits.RateLimitMidPointInfo memory newBridge = MintLimits.RateLimitMidPointInfo({
                bridge: bridges[0],
                bufferCap: 10_000e18,
                rateLimitPerSecond: mamoProxy.minBufferCap() + 1
            });

            mamoProxy.addBridge(newBridge);

            assertEq(mamoProxy.bufferCap(bridges[0]), 10_000e18, "incorrect buffer cap");
            assertEq(
                mamoProxy.rateLimitPerSecond(bridges[0]),
                mamoProxy.minBufferCap() + 1,
                "incorrect rate limit per second"
            );
        }
        {
            MintLimits.RateLimitMidPointInfo memory newBridge = MintLimits.RateLimitMidPointInfo({
                bridge: bridges[1],
                bufferCap: 10_000e18,
                rateLimitPerSecond: mamoProxy.minBufferCap() + 1
            });

            mamoProxy.addBridge(newBridge);

            assertEq(mamoProxy.bufferCap(bridges[1]), 10_000e18, "incorrect buffer cap");
            assertEq(
                mamoProxy.rateLimitPerSecond(bridges[1]),
                mamoProxy.minBufferCap() + 1,
                "incorrect rate limit per second"
            );
        }

        mamoProxy.removeBridges(bridges);

        for (uint256 i = 0; i < bridges.length; i++) {
            assertEq(mamoProxy.bufferCap(bridges[i]), 0, "incorrect buffer cap");
            assertEq(mamoProxy.rateLimitPerSecond(bridges[i]), 0, "incorrect rate limit per second");
            assertEq(mamoProxy.buffer(bridges[i]), 0, "incorrect buffer");
        }
    }

    function testDepleteBufferBridgeSucceeds() public {
        address bridge = address(0xeeeee);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = 20_000_000 * 1e18;

        testAddNewBridgeOwnerSucceeds(bridge, rateLimitPerSecond, bufferCap);

        uint256 amount = 100_000 * 1e18;

        vm.prank(bridge);
        mamoProxy.mint(address(this), amount);

        mamoProxy.approve(bridge, amount);

        uint256 buffer = mamoProxy.buffer(bridge);
        uint256 userStartingBalance = mamoProxy.balanceOf(address(this));
        uint256 startingTotalSupply = mamoProxy.totalSupply();

        vm.prank(bridge);
        mamoProxy.burn(address(this), amount);

        assertEq(mamoProxy.buffer(bridge), buffer + amount, "incorrect buffer amount");
        assertEq(mamoProxy.balanceOf(address(this)), userStartingBalance - amount, "incorrect user balance");
        assertEq(mamoProxy.allowance(address(this), bridge), 0, "incorrect allowance");
        assertEq(startingTotalSupply - mamoProxy.totalSupply(), amount, "incorrect total supply");
    }

    function testReplenishBufferBridgeSucceeds() public {
        address bridge = address(0xeeeee);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = 20_000_000 * 1e18;

        testAddNewBridgeOwnerSucceeds(bridge, rateLimitPerSecond, bufferCap);

        uint256 amount = 100_000 * 1e18;

        uint256 buffer = mamoProxy.buffer(bridge);
        uint256 userStartingBalance = mamoProxy.balanceOf(address(this));
        uint256 startingTotalSupply = mamoProxy.totalSupply();

        vm.prank(bridge);
        mamoProxy.mint(address(this), amount);

        assertEq(mamoProxy.buffer(bridge), buffer - amount, "incorrect buffer amount");
        assertEq(mamoProxy.totalSupply() - startingTotalSupply, amount, "incorrect total supply");
        assertEq(mamoProxy.balanceOf(address(this)) - userStartingBalance, amount, "incorrect user balance");
    }

    function testReplenishBufferBridgeByZeroFails() public {
        address bridge = address(0xeeeee);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = 20_000_000 * 1e18;

        testAddNewBridgeOwnerSucceeds(bridge, rateLimitPerSecond, bufferCap);

        vm.prank(bridge);
        vm.expectRevert("MintLimits: deplete amount cannot be 0");
        mamoProxy.mint(address(this), 0);
    }

    function testDepleteBufferBridgeByZeroFails() public {
        address bridge = address(0xeeeee);
        uint128 rateLimitPerSecond = uint128(mamoProxy.MAX_RATE_LIMIT_PER_SECOND());
        uint112 bufferCap = 20_000_000 * 1e18;

        testAddNewBridgeOwnerSucceeds(bridge, rateLimitPerSecond, bufferCap);

        vm.prank(bridge);
        vm.expectRevert("MintLimits: replenish amount cannot be 0");
        mamoProxy.burn(address(this), 0);
    }

    function testDepleteBufferNonBridgeByOneFails() public {
        address bridge = address(0xeeeee);

        vm.prank(bridge);
        vm.expectRevert("RateLimited: buffer cap overflow");
        mamoProxy.burn(address(this), 1);
    }

    function testReplenishBufferNonBridgeByOneFails() public {
        address bridge = address(0xeeeee);

        vm.prank(bridge);
        vm.expectRevert("RateLimited: rate limit hit");
        mamoProxy.mint(address(this), 1);
    }

    function testMintFailsWhenPaused() public {
        vm.prank(pauseGuardian);
        mamoProxy.pause();
        assertTrue(mamoProxy.paused());

        vm.prank(address(wormholeBridgeAdapterProxy));
        vm.expectRevert("Pausable: paused");
        mamoProxy.mint(address(wormholeBridgeAdapterProxy), 1);
    }

    function testOwnerCanUnpause() public {
        vm.prank(pauseGuardian);
        mamoProxy.pause();
        assertTrue(mamoProxy.paused());

        mamoProxy.ownerUnpause();
        assertFalse(mamoProxy.paused(), "contract not unpaused");
        assertEq(mamoProxy.pauseStartTime(), 0, "contract not unpaused");
        assertEq(mamoProxy.pauseGuardian(), address(0), "guardian not kicked after owner unpause");
    }

    function testOwnerUnpauseFailsNotPaused() public {
        vm.expectRevert("Pausable: not paused");
        mamoProxy.ownerUnpause();
    }

    function testNonOwnerUnpauseFails() public {
        vm.prank(address(10000000000));
        vm.expectRevert("Ownable: caller is not the owner");
        mamoProxy.ownerUnpause();
    }

    function testMintSucceedsAfterPauseDuration() public {
        testMintFailsWhenPaused();

        vm.warp(mamoProxy.pauseDuration() + block.timestamp + 1);

        assertFalse(mamoProxy.paused());
        testLockboxCanMint(0);
        /// let function choose amount to mint at random
    }

    function testBurnFailsWhenPaused() public {
        vm.prank(pauseGuardian);
        mamoProxy.pause();
        assertTrue(mamoProxy.paused());

        vm.prank(address(wormholeBridgeAdapterProxy));
        vm.expectRevert("Pausable: paused");
        mamoProxy.burn(address(wormholeBridgeAdapterProxy), 1);
    }

    function tesBurnSucceedsAfterPauseDuration() public {
        testBurnFailsWhenPaused();

        vm.warp(mamoProxy.pauseDuration() + block.timestamp + 1);

        assertFalse(mamoProxy.paused());

        /// mint, then burn after pause is up
        testLockBoxCanBurn(0);
        /// let function choose amount to burn at random
    }

    function testIncreaseAllowance(uint256 amount) public {
        address to = makeAddr("to");
        uint256 startingAllowance = mamoProxy.allowance(address(this), to);

        mamoProxy.increaseAllowance(to, amount);

        assertEq(mamoProxy.allowance(address(this), to), startingAllowance + amount, "incorrect allowance");
    }

    function testDecreaseAllowance(uint256 amount) public {
        address to = makeAddr("to");
        testIncreaseAllowance(amount);

        amount /= 2;

        uint256 startingAllowance = mamoProxy.allowance(address(this), to);

        mamoProxy.decreaseAllowance(to, amount);

        assertEq(mamoProxy.allowance(address(this), to), startingAllowance - amount, "incorrect allowance");
    }

    //    function testPermit(uint256 amount) public {
    //        address spender = address(wormholeBridgeAdapterProxy);
    //        uint256 deadline = 5000000000; // timestamp far in the future
    //        uint256 ownerPrivateKey = 0xA11CE;
    //        address owner = vm.addr(ownerPrivateKey);
    //
    //        SigUtils.Permit memory permit =
    //            SigUtils.Permit({owner: owner, spender: spender, value: amount, nonce: 0, deadline: deadline});
    //
    //        bytes32 digest = sigUtils.getTypedDataHash(permit);
    //
    //        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
    //
    //        mamoProxy.permit(owner, spender, amount, deadline, v, r, s);
    //
    //        assertEq(mamoProxy.allowance(owner, spender), amount, "incorrect allowance");
    //        assertEq(mamoProxy.nonces(owner), 1, "incorrect nonce");
    //    }
    // Helper functions for testing bridge functionality
    function _bridgeCanMint(uint112 mintAmount) internal {
        uint256 startingTotalSupply = mamoProxy.totalSupply();
        uint256 startingBalance = mamoProxy.balanceOf(address(this));

        vm.prank(address(wormholeBridgeAdapterProxy));
        mamoProxy.mint(address(this), mintAmount);

        assertEq(mamoProxy.totalSupply(), startingTotalSupply + mintAmount, "incorrect total supply");
        assertEq(mamoProxy.balanceOf(address(this)), startingBalance + mintAmount, "incorrect balance");
    }

    function _bridgeCanMintTo(address to, uint112 mintAmount) internal {
        uint256 startingTotalSupply = mamoProxy.totalSupply();
        uint256 startingBalance = mamoProxy.balanceOf(to);

        vm.prank(address(wormholeBridgeAdapterProxy));
        mamoProxy.mint(to, mintAmount);

        assertEq(mamoProxy.totalSupply(), startingTotalSupply + mintAmount, "incorrect total supply");
        assertEq(mamoProxy.balanceOf(to), startingBalance + mintAmount, "incorrect balance");
    }

    function _bridgeCanBurn(uint112 burnAmount) internal {
        uint256 startingTotalSupply = mamoProxy.totalSupply();
        uint256 startingBalance = mamoProxy.balanceOf(address(this));

        mamoProxy.approve(address(wormholeBridgeAdapterProxy), burnAmount);

        vm.prank(address(wormholeBridgeAdapterProxy));
        mamoProxy.burn(address(this), burnAmount);

        assertEq(mamoProxy.totalSupply(), startingTotalSupply - burnAmount, "incorrect total supply");
        assertEq(mamoProxy.balanceOf(address(this)), startingBalance - burnAmount, "incorrect balance");
    }

    function _bridgeCanBurnTo(address to, uint112 burnAmount) internal {
        uint256 startingTotalSupply = mamoProxy.totalSupply();
        uint256 startingBalance = mamoProxy.balanceOf(to);

        vm.prank(to);
        mamoProxy.approve(address(wormholeBridgeAdapterProxy), burnAmount);

        vm.prank(address(wormholeBridgeAdapterProxy));
        mamoProxy.burn(to, burnAmount);

        assertEq(mamoProxy.totalSupply(), startingTotalSupply - burnAmount, "incorrect total supply");
        assertEq(mamoProxy.balanceOf(to), startingBalance - burnAmount, "incorrect balance");
    }
}
