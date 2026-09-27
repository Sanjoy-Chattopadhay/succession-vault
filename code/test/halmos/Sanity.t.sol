// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultSymbolic} from "./VaultSymbolic.t.sol";

/// @notice Negative controls: properties that are FALSE, which Halmos must refute with a
///         counterexample. They show the symbolic setup really explores arbitrary states and calls.
contract SanityNegative is VaultSymbolic {
    /// False: proveLife does move t_l.
    function check_NEG_livenessNeverChanges() public {
        _arbitraryState();
        uint256 before = vault.lastLifeProof();
        (,, bool ok) = _anyCall();
        vm.assume(ok);
        assertEq(vault.lastLifeProof(), before);
    }

    /// False: the owner can change the will (with a fresh proof of life).
    function check_NEG_rootNeverChanges() public {
        _arbitraryState();
        bytes32 before = vault.allocationRoot();
        (,, bool ok) = _anyCall();
        vm.assume(ok);
        assertEq(vault.allocationRoot(), before);
    }
}
