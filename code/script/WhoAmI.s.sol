// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EnvKey} from "./EnvKey.sol";

/// @notice Prints the address and balance behind PRIVATE_KEY (from .env) without revealing the key.
///         forge script script/WhoAmI.s.sol --rpc-url sepolia
contract WhoAmI is EnvKey {
    function run() external view {
        address a = vm.addr(_envKey());
        console.log("chain id:", block.chainid);
        console.log("address: ", a);
        console.log("balance (wei):", a.balance);
    }
}
