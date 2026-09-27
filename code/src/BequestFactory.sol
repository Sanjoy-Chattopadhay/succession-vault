// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BequestVault} from "./BequestVault.sol";

/// @title BequestFactory
/// @notice Deploys one EIP-1167 minimal-proxy vault per (owner, salt). The address is known in
///         advance, so an owner can publish it as their deposit address before creating the vault.
contract BequestFactory {
    address public immutable implementation;

    event VaultCreated(address indexed owner, address indexed vault, bytes32 salt);

    error ZeroImplementation();

    constructor(address implementation_) {
        if (implementation_ == address(0)) revert ZeroImplementation();
        implementation = implementation_;
    }

    function createVault(BequestVault.Config calldata cfg, bytes32 salt) external returns (address vault) {
        vault = Clones.cloneDeterministic(implementation, _salt(msg.sender, salt));
        emit VaultCreated(msg.sender, vault, salt);
        BequestVault(payable(vault)).initialize(msg.sender, cfg);
    }

    function vaultAddress(address owner, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(owner, salt));
    }

    /// @dev Mixing in the owner means nobody else can occupy an owner's vault address.
    function _salt(address owner, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }
}
