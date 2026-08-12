// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";
import {SlippagePriceChecker} from "@contracts/SlippagePriceChecker.sol";

import {Test} from "@forge-std/Test.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

/// @notice Mocks-only unit coverage for the two audit fixes on SlippagePriceChecker: the
///         implementation initializer lock (Sherlock #44) and the reward-token latch that made a
///         mistaken configuration permanent.
contract SlippagePriceCheckerUnitTest is Test {
    SlippagePriceChecker public implementation;
    SlippagePriceChecker public checker;

    address public owner = makeAddr("owner");
    address public rewardToken = makeAddr("rewardToken");
    address public underlying = makeAddr("underlying");
    address public feed = makeAddr("chainlinkFeed");

    function setUp() public {
        implementation = new SlippagePriceChecker();
        checker = SlippagePriceChecker(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeWithSelector(SlippagePriceChecker.initialize.selector, owner)
                )
            )
        );
    }

    function _configure(address from, address to, uint256 maxTime) internal {
        ISlippagePriceChecker.TokenFeedConfiguration[] memory configs =
            new ISlippagePriceChecker.TokenFeedConfiguration[](1);
        configs[0] =
            ISlippagePriceChecker.TokenFeedConfiguration({chainlinkFeed: feed, reverse: false, heartbeat: 3600});

        vm.startPrank(owner);
        checker.addTokenConfiguration(from, to, configs);
        checker.setMaxTimePriceValid(from, maxTime);
        vm.stopPrank();
    }

    // ==================== #44: THE IMPLEMENTATION CANNOT BE CLAIMED ====================

    /// @notice Without the constructor lock the first caller of initialize() on the IMPLEMENTATION
    ///         becomes its owner and gets every onlyOwner entry point on that address. The live
    ///         pre-fix implementation (0x413C38B68fe730F2bC30d8Cde965967D1C7BC599) reports
    ///         `owner() == address(0)` on Base today, i.e. it is claimable by anyone.
    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        implementation.initialize(makeAddr("attacker"));

        assertEq(implementation.owner(), address(0), "implementation stays ownerless");
    }

    function test_proxyIsUnaffectedByTheImplementationLock() public view {
        assertEq(checker.owner(), owner, "proxy initialized its own storage");
    }

    // ==================== isRewardToken IS NO LONGER A ONE-WAY LATCH ====================

    /// @notice `isRewardToken` is defined as `maxTimePriceValid[token] > 0`, and nothing could ever
    ///         set that back to zero: setMaxTimePriceValid rejects a zero value and
    ///         removeTokenConfiguration only clears the pair mapping. A token configured once
    ///         therefore stayed a reward token forever — which in MamoMultiMarketStrategy is
    ///         standing permission to charge a compound fee on it permissionlessly and approve the
    ///         CoW relayer for the remainder.
    function test_removeTokenConfigurationAloneDoesNotRetireTheToken() public {
        _configure(rewardToken, underlying, 3600);
        assertTrue(checker.isRewardToken(rewardToken));

        vm.prank(owner);
        checker.removeTokenConfiguration(rewardToken, underlying);

        assertFalse(checker.isTokenPairConfigured(rewardToken, underlying), "pair is gone");
        assertTrue(checker.isRewardToken(rewardToken), "but the token-level flag survives, by design");
    }

    function test_clearRewardTokenClosesTheLatch() public {
        _configure(rewardToken, underlying, 3600);
        assertTrue(checker.isRewardToken(rewardToken));

        vm.prank(owner);
        checker.clearRewardToken(rewardToken);

        assertFalse(checker.isRewardToken(rewardToken), "token retired");
    }

    /// @notice The flag is keyed by fromToken while configurations are keyed by the PAIR, so
    ///         clearing it as a side effect of removing one pair would silently invalidate every
    ///         other pair the same token still has. Retiring the token is therefore explicit.
    function test_removingOnePairLeavesSiblingPairsUsable() public {
        address otherToToken = makeAddr("otherToToken");
        _configure(rewardToken, underlying, 3600);
        _configure(rewardToken, otherToToken, 3600);

        vm.prank(owner);
        checker.removeTokenConfiguration(rewardToken, underlying);

        assertTrue(checker.isTokenPairConfigured(rewardToken, otherToToken), "sibling pair still priced");
    }

    function test_clearRewardTokenIsOwnerOnly() public {
        _configure(rewardToken, underlying, 3600);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", makeAddr("stranger")));
        checker.clearRewardToken(rewardToken);
    }

    function test_clearRewardTokenRejectsAnUnconfiguredToken() public {
        vm.prank(owner);
        vm.expectRevert("Token not configured");
        checker.clearRewardToken(makeAddr("neverConfigured"));
    }
}
