// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DropAutomationV2} from "@contracts/DropAutomationV2.sol";
import {IMultiRewards} from "@interfaces/IMultiRewards.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StockAccountsConfig} from "@script/StockAccountsConfig.sol";
import {MockERC20Decimals} from "@test/mocks/MockERC20Decimals.sol";

/**
 * @title AddStockRewards
 * @notice F-MAMO batch starting the in-kind reward streams: WETH, USDC and each B20 stock become MultiRewards reward
 *         tokens with DropAutomationV2 as their distributor, and tokens DropAutomationV2 pays out as they are.
 * @dev Runs once most staking accounts have upgraded to MamoStakingStrategyV2: an account still on V1 receives
 *      tokens it cannot compound or reinvest (its owner can only recoverERC20 them). Until this runs, DropAutomationV2
 *      keeps swapping WETH to cbBTC and holds USDC and stocks.
 *      A token removed from MultiRewards must never be re-added: its stale per-user checkpoints make `earned`
 *      underflow and lock every earlier staker's withdrawals. {preBuildMock} can only check the token is not listed
 *      now, so this rule is operational.
 */
contract AddStockRewards is MultisigProposal {
    uint256 internal constant REWARDS_DURATION = 7 days;

    StockAccountsConfig public immutable deployConfig;

    constructor() {
        deployConfig = new StockAccountsConfig("./deploy/stock-accounts/8453_PROD.json");
        vm.makePersistent(address(deployConfig));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
    }

    function name() public pure override returns (string memory) {
        return "007_AddStockRewards";
    }

    function description() public pure override returns (string memory) {
        return "Add WETH, USDC and the B20 stocks as MultiRewards reward tokens distributed by DropAutomationV2";
    }

    function deploy() public override {}

    function preBuildMock() public override {
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        address drop = addresses.getAddress("DROP_AUTOMATION_V2");

        (address mamoDistributor,,,,,) = multiRewards.rewardData(addresses.getAddress("MAMO"));
        assertEq(mamoDistributor, drop, "f-mamo/006 should have run");

        address[] memory tokens = _rewardTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            (, uint256 duration,,,,) = multiRewards.rewardData(tokens[i]);
            assertEq(duration, 0, "Token is already a reward token");
        }

        _standInForNodeNativeTokens(_stocks());
    }

    /// @dev `addReward` reads `decimals()`, which revm cannot execute on a B20 stock (code 0xEF). The stand-in only
    ///      lets the call be recorded; the Safe sends the same calldata to the real token.
    function _standInForNodeNativeTokens(StockAccountsConfig.TokenListEntry[] memory stocks) internal {
        for (uint256 i = 0; i < stocks.length; i++) {
            bytes memory code = stocks[i].token.code;
            if (code.length != 1 || code[0] != 0xEF) continue;

            vm.etch(stocks[i].token, address(new MockERC20Decimals(stocks[i].symbol, stocks[i].decimals)).code);
            assertEq(IERC20Metadata(stocks[i].token).decimals(), stocks[i].decimals, "Stand-in decimals");
        }
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        DropAutomationV2 drop = DropAutomationV2(addresses.getAddress("DROP_AUTOMATION_V2"));

        address[] memory tokens = _rewardTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            multiRewards.addReward(tokens[i], address(drop), REWARDS_DURATION);
            drop.addRewardToken(tokens[i]);
        }
    }

    function simulate() public override {
        _simulateActions(addresses.getAddress("F-MAMO"));
    }

    function validate() public view override {
        IMultiRewards multiRewards = IMultiRewards(addresses.getAddress("MAMO_MULTI_REWARDS"));
        DropAutomationV2 drop = DropAutomationV2(addresses.getAddress("DROP_AUTOMATION_V2"));

        address[] memory tokens = _rewardTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            (address distributor, uint256 duration,,,,) = multiRewards.rewardData(tokens[i]);
            assertEq(distributor, address(drop), "Distributor should be DropAutomationV2");
            assertEq(duration, REWARDS_DURATION, "Rewards duration");
            assertTrue(drop.isRewardToken(tokens[i]), "Paid out as it is");
        }
    }

    /// @dev WETH, USDC, then the stocks
    function _rewardTokens() internal view returns (address[] memory tokens) {
        StockAccountsConfig.TokenListEntry[] memory stocks = _stocks();
        tokens = new address[](2 + stocks.length);
        tokens[0] = addresses.getAddress("WETH");
        tokens[1] = addresses.getAddress("USDC");
        for (uint256 i = 0; i < stocks.length; i++) {
            tokens[2 + i] = stocks[i].token;
        }
    }

    /// @dev The pool-priced entries of the stock list, i.e. the B20 stocks
    function _stocks() internal view returns (StockAccountsConfig.TokenListEntry[] memory stocks) {
        StockAccountsConfig.TokenListEntry[] memory entries = deployConfig.loadTokenList();
        stocks = new StockAccountsConfig.TokenListEntry[](entries.length);

        uint256 count;
        for (uint256 i = 0; i < entries.length; i++) {
            if (keccak256(bytes(entries[i].source)) == keccak256("PoolTwap")) stocks[count++] = entries[i];
        }

        assembly ("memory-safe") {
            mstore(stocks, count)
        }
    }

    function _initializeAddresses() internal {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
    }
}
