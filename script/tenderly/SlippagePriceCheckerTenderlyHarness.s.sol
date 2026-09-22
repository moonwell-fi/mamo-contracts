// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {ISlippagePriceChecker} from "@interfaces/ISlippagePriceChecker.sol";

/*//////////////////////////////////////////////////////////////////////////////
        SlippagePriceChecker — Tenderly Virtual TestNet harness (simulation-only)
////////////////////////////////////////////////////////////////////////////////

Exercises the LIVE deployed SlippagePriceChecker (CHAINLINK_SWAP_CHECKER_PROXY) on a Base-fork vnet,
against its REAL Chainlink configuration, to corroborate the swap-price gate the strategies rely on:

  • a fair minOut passes checkPrice()
  • an under-priced minOut (below the slippage floor) fails checkPrice()
  • a stale feed makes checkPrice() revert ("... exceeds heartbeat")

All entrypoints are pure simulation (checkPrice is `view`) — run WITHOUT --broadcast. The orchestrator
(run-price-checker.sh) advances the vnet clock past the feed heartbeat before checkStalePrice().

ENV CONTRACT: none required beyond the address book. Reads addresses/8453.json via FPS.
//////////////////////////////////////////////////////////////////////////////*/

contract SlippagePriceCheckerTenderlyHarness is Script {
    uint256 constant MAX_BPS = 10_000;
    uint256 constant SLIPPAGE_BPS = 100; // 1%
    uint256 constant AMOUNT_IN = 100e18; // reward tokens (WELL/MORPHO/AERO) are 18-dec

    // Exact require-string emitted by SlippagePriceChecker.getExpectedOutFromChainlink when a feed is
    // stale (block.timestamp > updatedAt + heartbeat). Pinned so checkStalePrice() asserts the REASON.
    string constant STALE_REVERT_REASON = "Price feed update time exceeds heartbeat";

    Addresses internal addresses;
    ISlippagePriceChecker internal checker;

    function _resolve() internal {
        if (address(addresses) != address(0)) return;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses("./addresses", chainIds);
        vm.makePersistent(address(addresses));
        checker = ISlippagePriceChecker(addresses.getAddress("CHAINLINK_SWAP_CHECKER_PROXY"));
    }

    /// @dev Discover a (fromToken → toToken) pair that is actually configured on the live checker,
    ///      instead of hardcoding one — survives config differences across deployments/time.
    function _findConfiguredPair() internal returns (address from, address to) {
        _resolve();
        string[3] memory fromNames = ["xWELL_PROXY", "MORPHO", "AERO"];
        string[3] memory toNames = ["USDC", "cbBTC", "WETH"];
        for (uint256 i = 0; i < fromNames.length; i++) {
            address f = _tryAddr(fromNames[i]);
            if (f == address(0)) continue;
            for (uint256 j = 0; j < toNames.length; j++) {
                address t = _tryAddr(toNames[j]);
                if (t == address(0)) continue;
                if (checker.isTokenPairConfigured(f, t)) return (f, t);
            }
        }
        revert("no configured token pair found on the live checker");
    }

    function _tryAddr(string memory name) internal view returns (address a) {
        try addresses.getAddress(name) returns (address r) {
            a = r;
        } catch {
            a = address(0);
        }
    }

    /// @notice Assert the gate ACCEPTS a fair order and REJECTS an under-priced one, against the
    ///         live oracle-implied expected output.
    function checkPriceGating() public {
        _resolve();
        (address from, address to) = _findConfiguredPair();
        uint256 expectedOut = checker.getExpectedOut(AMOUNT_IN, from, to);
        require(expectedOut > 0, "expectedOut must be > 0");

        // fair: minOut == expectedOut → strictly above the (1 - slippage) floor → accepted
        bool fairOk = checker.checkPrice(AMOUNT_IN, from, to, expectedOut, SLIPPAGE_BPS);
        require(fairOk, "fair minOut must pass checkPrice");

        // under-priced: minOut = expectedOut * (1 - 2*slippage) → below the floor → rejected
        uint256 badMinOut = (expectedOut * (MAX_BPS - 2 * SLIPPAGE_BPS)) / MAX_BPS;
        bool badOk = checker.checkPrice(AMOUNT_IN, from, to, badMinOut, SLIPPAGE_BPS);
        require(!badOk, "under-priced minOut must fail checkPrice");

        console.log("priceGating.from        :", from);
        console.log("priceGating.to          :", to);
        console.log("priceGating.expectedOut :", expectedOut);
        console.log("priceGating.fair_passed  :", fairOk);
        console.log("priceGating.badReject    :", !badOk);
        console.log("checkPriceGating [OK]");
    }

    /// @notice Assert getExpectedOut() reverts for the RIGHT reason once the feed is stale (orchestrator
    ///         advanced the clock past the configured heartbeat). The staleness guard lives in
    ///         SlippagePriceChecker.getExpectedOutFromChainlink as a require-string:
    ///           require(block.timestamp <= updatedAt + heartbeat, "Price feed update time exceeds heartbeat")
    ///         which bubbles up as Error(string). We assert the EXACT message (not merely "it reverted"),
    ///         so an unrelated revert cause fails this phase — mirroring checkStaleOracle/checkCalmGate
    ///         in LPV2TenderlyHarness, which pin the revert selector.
    function checkStalePrice() public {
        _resolve();
        (address from, address to) = _findConfiguredPair();
        try checker.getExpectedOut(AMOUNT_IN, from, to) returns (uint256) {
            revert("getExpectedOut must revert when the feed is stale");
        } catch Error(string memory reason) {
            require(
                keccak256(bytes(reason)) == keccak256(bytes(STALE_REVERT_REASON)),
                "stale revert reason must be 'Price feed update time exceeds heartbeat'"
            );
            console.log("stalePrice.reverted     :", true);
            console.log("stalePrice.reason       :", reason);
            console.log("checkStalePrice [OK]");
        } catch (bytes memory ret) {
            // A custom error / Panic — NOT the require-string staleness guard. Fail loudly.
            console.log("stalePrice.unexpectedSelector_len :", ret.length);
            revert("stale revert was not Error(string) 'exceeds heartbeat' - unexpected cause");
        }
    }
}
