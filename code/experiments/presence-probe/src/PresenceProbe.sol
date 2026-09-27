// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// Prototype of three cheaper presence paths, with BequestVault's slot-0 layout, for gas measurement.
contract PresenceProbe {
    address public owner;
    uint40 public lastHeartbeat;
    uint40 public lastLifeProof;
    bool public settled;
    bool public lifeProven;
    mapping(uint256 => bool) public isBinding;
    bytes32 public pendingLifeProof;

    struct WebAuthnAssertion {
        bytes authenticatorData;
        bytes clientDataJSON;
        uint256 typeIndex;
        uint256 challengeIndex;
        bytes32 r;
        bytes32 s;
    }

    event Heartbeat();
    event PresenceProven(uint256 time);
    event LazyLifeProof(uint256 livenessTime, uint256 binding, uint256[8] proof);

    error NotOwner();
    error VaultSettled();
    error UnknownBinding();
    error StaleChallenge();
    error InvalidProof();

    constructor(address owner_, uint256 binding) {
        owner = owner_;
        lastHeartbeat = uint40(block.timestamp);
        lastLifeProof = uint40(block.timestamp);
        isBinding[binding] = true;
    }

    function heartbeat() external {
        if (msg.sender != owner) revert NotOwner();
        if (settled) revert VaultSettled();
        lastHeartbeat = uint40(block.timestamp);
        emit Heartbeat();
    }

    /// Binding of a passkey: a hash of its P-256 public key, stored like a ZK binding.
    function passkeyBinding(bytes32 qx, bytes32 qy) public pure returns (uint256) {
        return uint256(keccak256(abi.encode("bequest.passkey", qx, qy)));
    }

    /// Challenge the passkey must sign: bound to this vault, the current lastLifeProof (no replay)
    /// and a recent block hash (no pre-signing: unknown before that block, expires 256 blocks later).
    function presenceChallenge(uint256 blockNumber) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), lastLifeProof, blockNumber, blockhash(blockNumber)));
    }

    /// Proof of presence from a WebAuthn assertion with user verification (Face ID, fingerprint,
    /// Windows Hello). Callable by anyone: the assertion authenticates itself.
    function provePresence(WebAuthnAssertion calldata a, bytes32 qx, bytes32 qy, uint256 blockNumber) external {
        if (settled) revert VaultSettled();
        if (!isBinding[passkeyBinding(qx, qy)]) revert UnknownBinding();
        // lastLifeProof strictly increases, so an assertion (whose challenge commits to it) works once.
        if (block.timestamp <= lastLifeProof || blockhash(blockNumber) == 0) revert StaleChallenge();
        if (!_verifyWebAuthn(presenceChallenge(blockNumber), a, qx, qy)) revert InvalidProof();
        lastLifeProof = uint40(block.timestamp);
        lastHeartbeat = uint40(block.timestamp);
        lifeProven = true;
        emit PresenceProven(block.timestamp);
    }

    /// Optimistic proof of life: store a commitment, verify only if an heir disputes it.
    function proveLifeLazy(uint256[8] calldata proof, uint256 binding, uint256 livenessTime) external {
        if (msg.sender != owner) revert NotOwner();
        if (settled) revert VaultSettled();
        if (!isBinding[binding]) revert UnknownBinding();
        if (livenessTime <= lastLifeProof || livenessTime > block.timestamp + 15 minutes) revert InvalidProof();
        pendingLifeProof = keccak256(abi.encode(proof, binding, livenessTime));
        lastHeartbeat = uint40(block.timestamp);
        emit LazyLifeProof(livenessTime, binding, proof);
    }

    function _verifyWebAuthn(bytes32 challenge, WebAuthnAssertion calldata a, bytes32 qx, bytes32 qy)
        internal
        view
        returns (bool)
    {
        bytes calldata ad = a.authenticatorData;
        // flags byte: user present (0x01) and user verified (0x04)
        if (ad.length < 37 || uint8(ad[32]) & 0x05 != 0x05) return false;
        bytes calldata cd = a.clientDataJSON;
        if (!_at(cd, a.typeIndex, '"type":"webauthn.get"')) return false;
        if (!_at(cd, a.challengeIndex, bytes.concat('"challenge":"', bytes(Base64.encodeURL(abi.encodePacked(challenge))), '"'))) {
            return false;
        }
        bytes32 h = sha256(bytes.concat(ad, sha256(cd)));
        (bool ok, bytes memory out) = address(0x100).staticcall(abi.encode(h, a.r, a.s, qx, qy));
        return ok && out.length == 32 && abi.decode(out, (uint256)) == 1;
    }

    function _at(bytes calldata s, uint256 i, bytes memory sub) private pure returns (bool) {
        if (i + sub.length > s.length) return false;
        return keccak256(s[i:i + sub.length]) == keccak256(sub);
    }
}
