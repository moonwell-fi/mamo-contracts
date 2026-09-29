// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DropAutomationV2} from "@contracts/DropAutomationV2.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";
import {IQuoter} from "@interfaces/IQuoter.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";

contract MockQuoter {
    MockSwapRouter internal immutable router;

    constructor(MockSwapRouter router_) {
        router = router_;
    }

    function quoteExactInputSingle(IQuoter.QuoteExactInputSingleParams memory p)
        external
        view
        returns (uint256, uint160, uint32, uint256)
    {
        return ((p.amountIn * router.rate(p.tokenIn, p.tokenOut)) / 1e18, 0, 0, 0);
    }
}

contract MockGauge {
    address public stakingToken = address(1);
    uint256 public claims;

    function getReward(address) external {
        claims++;
    }
}

contract DropAutomationV2UnitTest is Test {
    uint256 internal constant DURATION = 7 days;

    address internal owner = makeAddr("owner");
    address internal sender = makeAddr("sender");

    MockERC20Decimals internal mamo = new MockERC20Decimals("MAMO", 18);
    MockERC20Decimals internal cbBtc = new MockERC20Decimals("cbBTC", 8);
    MockERC20Decimals internal stock = new MockERC20Decimals("NVDAc", 8);
    MockERC20Decimals internal weth = new MockERC20Decimals("WETH", 18);

    IMultiRewards internal multiRewards;
    MockSwapRouter internal router = new MockSwapRouter();
    DropAutomationV2 internal drop;

    function setUp() public {
        multiRewards = IMultiRewards(vm.deployCode("MultiRewards.sol:MultiRewards", abi.encode(owner, address(mamo))));

        address[] memory rewardTokens = new address[](3);
        rewardTokens[0] = address(mamo);
        rewardTokens[1] = address(cbBtc);
        rewardTokens[2] = address(stock);

        drop = new DropAutomationV2(
            owner,
            sender,
            address(mamo),
            address(cbBtc),
            address(multiRewards),
            address(router),
            address(new MockQuoter(router)),
            rewardTokens
        );

        vm.startPrank(owner);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            multiRewards.addReward(rewardTokens[i], address(drop), DURATION);
        }
        vm.stopPrank();

        // A staker, so reward accrual is live
        mamo.mint(address(this), 1e18);
        mamo.approve(address(multiRewards), 1e18);
        multiRewards.stake(1e18);
    }

    function test_createDrop_fundsEachRewardToken() public {
        mamo.mint(address(drop), 1_000e18);
        stock.mint(address(drop), 5e8);

        _createDrop();

        assertEq(mamo.balanceOf(address(multiRewards)), 1e18 + 1_000e18 - 1_000e18 % DURATION, "on top of the stake");
        assertEq(stock.balanceOf(address(multiRewards)), 5e8 - 5e8 % DURATION);
        assertEq(stock.balanceOf(address(drop)), 5e8 % DURATION, "the remainder waits for the next drop");
        assertEq(multiRewards.getRewardForDuration(address(stock)), 5e8 - 5e8 % DURATION);
        (,, uint256 cbBtcPeriodFinish,,,) = multiRewards.rewardData(address(cbBtc));
        assertEq(cbBtcPeriodFinish, 0, "a zero balance is skipped");
    }

    function test_createDrop_topsUpARunningPeriod() public {
        stock.mint(address(drop), 7e8);
        _createDrop();
        (,,, uint256 firstRate,,) = multiRewards.rewardData(address(stock));

        skip(3 days);
        stock.mint(address(drop), 7e8);
        uint256 topUp = stock.balanceOf(address(drop)) - stock.balanceOf(address(drop)) % DURATION;
        _createDrop();

        (,, uint256 periodFinish, uint256 rate,,) = multiRewards.rewardData(address(stock));
        assertEq(periodFinish, block.timestamp + DURATION);
        assertEq(rate, (topUp + 4 days * firstRate) / DURATION, "the leftover rolls into the new period");
    }

    function test_createDrop_failingTokenDoesNotBlockTheRest() public {
        vm.prank(owner);
        drop.addRewardToken(address(weth));
        weth.mint(address(drop), 1e18);
        stock.mint(address(drop), 5e8);

        vm.expectEmit(true, false, false, false);
        emit DropAutomationV2.RewardNotifyFailed(address(weth), "");
        _createDrop();

        assertEq(weth.balanceOf(address(drop)), 1e18, "held for the next drop");
        assertEq(stock.balanceOf(address(drop)), 5e8 % DURATION);
    }

    function test_createDrop_dustWaitsForTheNextDrop() public {
        mamo.mint(address(drop), 1e18);
        stock.mint(address(drop), DURATION - 1);

        _createDrop();

        assertEq(stock.balanceOf(address(drop)), DURATION - 1);
    }

    function test_createDrop_revertsWhenNothingIsFunded() public {
        vm.expectRevert(DropAutomationV2.NothingToDistribute.selector);
        _createDrop();
    }

    function test_createDrop_swapsIntoCbBtc() public {
        weth.mint(address(drop), 1e18);
        cbBtc.mint(address(router), 1e8);
        router.setRate(address(weth), address(cbBtc), 3e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        (int24[] memory ticks, bool[] memory direct, uint256[] memory mins) = _swapArgs(true, 3e6);

        vm.prank(sender);
        drop.createDrop(tokens, ticks, direct, mins);

        assertEq(cbBtc.balanceOf(address(multiRewards)), 3e6 - 3e6 % DURATION);

        weth.mint(address(drop), 1e18);
        (ticks, direct, mins) = _swapArgs(true, 3e6 + 1);
        vm.prank(sender);
        vm.expectRevert(DropAutomationV2.InsufficientOutput.selector);
        drop.createDrop(tokens, ticks, direct, mins);
    }

    function test_createDrop_skipsASwapThatDustWouldZero() public {
        weth.mint(address(drop), 1);
        mamo.mint(address(drop), 1e18);
        router.setRate(address(weth), address(cbBtc), 3e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        (int24[] memory ticks, bool[] memory direct, uint256[] memory mins) = _swapArgs(true, 0);

        vm.prank(sender);
        drop.createDrop(tokens, ticks, direct, mins);

        assertEq(weth.balanceOf(address(drop)), 1, "left unswapped");
        assertEq(mamo.balanceOf(address(drop)), 1e18 % DURATION, "the drop still ran");
    }

    function test_createDrop_neverSwapsARewardToken() public {
        stock.mint(address(drop), 5e8);

        address[] memory tokens = new address[](1);
        tokens[0] = address(stock);
        (int24[] memory ticks, bool[] memory direct, uint256[] memory mins) = _swapArgs(true, 0);

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(DropAutomationV2.RewardTokenNotSwappable.selector, address(stock)));
        drop.createDrop(tokens, ticks, direct, mins);
    }

    function test_gauges() public {
        MockGauge gauge = new MockGauge();

        vm.prank(owner);
        drop.addGauge(address(gauge));
        vm.prank(sender);
        drop.claimGaugeRewards();
        assertEq(gauge.claims(), 1);

        vm.prank(owner);
        drop.removeGauge(address(gauge));
        assertEq(drop.getGauges().length, 0);
    }

    function test_accessControl() public {
        vm.expectRevert(DropAutomationV2.NotDedicatedSender.selector);
        drop.createDrop(new address[](0), new int24[](0), new bool[](0), new uint256[](0));

        vm.expectRevert(DropAutomationV2.NotSelf.selector);
        drop.notifyReward(address(mamo), 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        drop.addRewardToken(address(weth));
    }

    function _createDrop() internal {
        vm.prank(sender);
        drop.createDrop(new address[](0), new int24[](0), new bool[](0), new uint256[](0));
    }

    function _swapArgs(bool direct, uint256 minOut)
        internal
        pure
        returns (int24[] memory ticks, bool[] memory directs, uint256[] memory mins)
    {
        ticks = new int24[](1);
        directs = new bool[](1);
        mins = new uint256[](1);
        ticks[0] = 100;
        directs[0] = direct;
        mins[0] = minOut;
    }
}
