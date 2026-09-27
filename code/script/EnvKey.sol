// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

/// @notice Reads the signing key from PRIVATE_KEY (loaded by Foundry from .env), accepting it with or
///         without the 0x prefix. Returns 0 when it is not set. The key is never logged.
abstract contract EnvKey is Script {
    function _envKey() internal view returns (uint256) {
        string memory s = vm.envOr("PRIVATE_KEY", string(""));
        if (bytes(s).length == 0) return 0;
        if (bytes(s).length == 64) s = string.concat("0x", s);
        return vm.parseUint(s);
    }
}
