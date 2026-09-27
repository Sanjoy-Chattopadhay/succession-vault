// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {PresenceProbe} from "../src/PresenceProbe.sol";

contract PresenceTest is Test {
    uint256 constant PK = 0xB10B1E7;
    uint256 constant N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    address owner = makeAddr("owner");
    PresenceProbe v;
    bytes32 qx;
    bytes32 qy;

    function setUp() public {
        (uint256 x, uint256 y) = vm.publicKeyP256(PK);
        (qx, qy) = (bytes32(x), bytes32(y));
        vm.warp(1_800_000_000);
        vm.roll(1000);
        // a passkey binding and a ZK binding (value 42) are both registered
        v = new PresenceProbe(owner, uint256(keccak256(abi.encode("bequest.passkey", qx, qy))));
    }

    function _assertion(uint256 blockNumber, bytes1 flags) internal view returns (PresenceProbe.WebAuthnAssertion memory a) {
        bytes32 c = v.presenceChallenge(blockNumber);
        a.authenticatorData = abi.encodePacked(sha256("bequest.example"), flags, bytes4(0));
        a.clientDataJSON = bytes(string.concat(
            '{"type":"webauthn.get","challenge":"', Base64.encodeURL(abi.encodePacked(c)),
            '","origin":"https://bequest.example","crossOrigin":false}'));
        a.typeIndex = 1;
        a.challengeIndex = 23;
        bytes32 h = sha256(bytes.concat(a.authenticatorData, sha256(a.clientDataJSON)));
        (bytes32 r, bytes32 s) = vm.signP256(PK, h);
        if (uint256(s) > N / 2) s = bytes32(N - uint256(s));
        (a.r, a.s) = (r, s);
    }

    function _gas(string memory name) internal returns (uint256 used) {
        used = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint(name, used);
    }

    function test_Gas() public {
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);
        vm.prank(owner);
        v.heartbeat();
        _gas("heartbeat (key only)");

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);
        uint256 bn = block.number - 2;
        vm.setBlockhash(bn, keccak256("recent block"));
        PresenceProbe.WebAuthnAssertion memory a = _assertion(bn, 0x05);
        vm.roll(block.number + 1);
        v.provePresence(a, qx, qy, bn);
        _gas("provePresence (WebAuthn + P256VERIFY)");
        assertEq(v.lastLifeProof(), block.timestamp);
        assertTrue(v.lifeProven());

        uint256[8] memory proof;
        for (uint256 i; i < 8; i++) proof[i] = uint256(keccak256(abi.encode(i))) >> 2;
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        v.proveLifeLazy(proof, uint256(keccak256(abi.encode("bequest.passkey", qx, qy))), block.timestamp - 60);
        _gas("proveLifeLazy (first)");
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        v.proveLifeLazy(proof, uint256(keccak256(abi.encode("bequest.passkey", qx, qy))), block.timestamp - 60);
        _gas("proveLifeLazy (later)");
    }

    function test_RejectsReplayStaleAndNoUV() public {
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 10);
        uint256 bn = block.number - 1;
        vm.setBlockhash(bn, keccak256("b"));
        PresenceProbe.WebAuthnAssertion memory a = _assertion(bn, 0x05);
        v.provePresence(a, qx, qy, bn);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(PresenceProbe.InvalidProof.selector); // lastLifeProof changed: replay fails
        v.provePresence(a, qx, qy, bn);

        PresenceProbe.WebAuthnAssertion memory b = _assertion(bn, 0x05);
        vm.roll(bn + 257);
        vm.expectRevert(PresenceProbe.StaleChallenge.selector); // block hash no longer available
        v.provePresence(b, qx, qy, bn);

        bn = block.number - 1;
        vm.setBlockhash(bn, keccak256("c"));
        PresenceProbe.WebAuthnAssertion memory c = _assertion(bn, 0x01); // user present, not verified
        vm.expectRevert(PresenceProbe.InvalidProof.selector);
        v.provePresence(c, qx, qy, bn);

        PresenceProbe.WebAuthnAssertion memory d = _assertion(bn, 0x05);
        (uint256 ox, uint256 oy) = vm.publicKeyP256(PK + 1); // an unregistered key
        vm.expectRevert(PresenceProbe.UnknownBinding.selector);
        v.provePresence(d, bytes32(ox), bytes32(oy), bn);
    }
}
