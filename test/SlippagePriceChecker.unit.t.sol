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

    /// @notice The latch was: `isRewardToken` == `maxTimePriceValid[token] > 0`, with nothing able to
    ///         set that back to zero — setMaxTimePriceValid rejected zero and removeTokenConfiguration
    ///         only cleared the pair mapping. A token configured once stayed a reward token forever,
    ///         which in MamoMultiMarketStrategy is standing permission to charge a compound fee on it
    ///         permissionlessly and approve the CoW relayer for the remainder.
    ///
    /// @dev MERGE (#74 into #73): this test asserted that removal leaves the flag standing "by
    ///      design". That was right under the old definition; #74's MOO-726 change is precisely that a
    ///      token with no configured pairs must stop passing the gate, so removeTokenConfiguration now
    ///      clears the flag once the counted-pair count reaches zero. The original intent — removing
    ///      ONE pair must not invalidate a token's other pairs — is untouched and is covered by
    ///      test_removingOnePairLeavesSiblingPairsUsable below.
    function test_removingTheLastPairRetiresTheToken() public {
        _configure(rewardToken, underlying, 3600);
        assertTrue(checker.isRewardToken(rewardToken));

        vm.prank(owner);
        checker.removeTokenConfiguration(rewardToken, underlying);

        assertFalse(checker.isTokenPairConfigured(rewardToken, underlying), "pair is gone");
        assertFalse(checker.isRewardToken(rewardToken), "and the token is no longer a reward token");
        assertEq(checker.maxTimePriceValid(rewardToken), 0, "legacy flag cleared with the last pair");
    }

    /// @notice `clearRewardToken` refuses to run while counted pairs remain, rather than no-op.
    /// @dev Post-merge `isRewardToken` reads `configuredPairCount > 0 || maxTimePriceValid > 0`, so
    ///      zeroing the flag with pairs still counted would return successfully and change the answer
    ///      not at all. A silent no-op is the worst outcome for the operator reaching for this, so the
    ///      precondition makes it a revert.
    function test_clearRewardTokenRequiresPairsRemovedFirst() public {
        _configure(rewardToken, underlying, 3600);

        vm.prank(owner);
        vm.expectRevert("Remove pair configurations first");
        checker.clearRewardToken(rewardToken);

        assertTrue(checker.isRewardToken(rewardToken), "still a reward token, as the revert implies");
    }

    /// @notice The residual-flag case `clearRewardToken` still exists for.
    /// @dev A token can carry a non-zero legacy flag with zero counted pairs: set directly, or left
    ///      behind by a configuration predating `configuredPairCount`. `removeTokenConfiguration`
    ///      cannot reach that — there is no pair to remove — so this is the call that retires it.
    function test_clearRewardTokenClosesTheLegacyLatch() public {
        vm.prank(owner);
        checker.setMaxTimePriceValid(rewardToken, 3600);

        assertEq(checker.configuredPairCount(rewardToken), 0, "no counted pairs, only the legacy flag");
        assertTrue(checker.isRewardToken(rewardToken), "the flag alone makes it a reward token");

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
