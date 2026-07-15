// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LPAutoBalancerV2} from "@contracts/LPAutoBalancerV2.sol";

/// @notice TEST-ONLY subclass exposing named-field writes for position states the public API
///         cannot reach directly (or only reaches through a full rebalance flow against the
///         260-line position-manager mock). Replaces the old stdstore struct-depth pokes
///         (`.sig("position()").depth(N)`) and the packed-word bit-flipping via vm.store: those
///         write by SLOT, so any ManagedPositionV2 field reorder silently corrupts test state.
///         These setters write fields BY NAME, and `exposed_position()` gives the suite named-field
///         READS (the public `position()` auto-getter only returns a positional 21-tuple, which has
///         the same reorder fragility on the read side). With both, a field reorder is either
///         transparent or a compile error — never silent corruption. Production code is untouched;
///         this contract lives in test/ and is never deployed.
contract LPAutoBalancerV2Harness is LPAutoBalancerV2 {
    constructor(
        address admin,
        address manager,
        address rebalancer,
        address guardian,
        address positionManager,
        address aero
    ) LPAutoBalancerV2(admin, manager, rebalancer, guardian, positionManager, aero) {}

    /// @dev Named-field read of the whole position struct. The public `position()` getter returns
    ///      a positional 21-tuple; destructuring it by index would silently misread after a swap of
    ///      adjacent same-type fields. Tests read through this instead and access fields by name.
    function exposed_position() external view returns (ManagedPositionV2 memory) {
        return position;
    }

    /// @dev Inject an alt tokenId, bypassing _store()'s forced-zero, so alt staking/teardown paths
    ///      are testable without running a full rebalanceUsingAlt() first.
    function exposed_setAltTokenId(uint256 tokenId) external {
        position.altTokenId = tokenId;
    }

    /// @dev Stamp lastRebalance so cooldown gates are testable without simulating a prior
    ///      rebalance (_store() forces it to 0 at registration).
    function exposed_setLastRebalance(uint256 timestamp) external {
        position.lastRebalance = timestamp;
    }

    /// @dev Force the staked flags into combinations the public API never produces directly —
    ///      e.g. mainStaked=false, altStaked=true for the setGauge stranding guard (M-2).
    function exposed_setStakedFlags(bool mainStaked_, bool altStaked_) external {
        position.mainStaked = mainStaked_;
        position.altStaked = altStaked_;
    }
}
