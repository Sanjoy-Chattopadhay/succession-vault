// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {BequestFactory} from "../src/BequestFactory.sol";
import {IGroth16Verifier} from "../src/interfaces/IGroth16Verifier.sol";
import {ILivenessRegistry} from "../src/interfaces/ILivenessRegistry.sol";
import {LivenessVerifier} from "../src/verifiers/LivenessVerifier.sol";
import {AgeVerifier} from "../src/verifiers/AgeVerifier.sol";
import {MockERC20, MockERC721, MockERC1155} from "./mocks/MockTokens.sol";

/// @dev Shared deployment and fixture loading. Fixtures come from `node js/gen-fixtures.mjs`.
abstract contract BaseTest is Test {
    uint256 internal constant T0 = 1_900_000_000; // must match js/gen-fixtures.mjs
    uint32 internal constant I = 30 days; // heartbeat interval
    uint32 internal constant B = 365 days; // proof-of-life interval
    uint32 internal constant G = 90 days; // grace period
    uint32 internal constant W = 3650 days; // claim window
    uint32 internal constant MIN_PERIOD = 1 hours;
    uint32 internal constant AUTH_WINDOW = 1 days;

    // Bequest indices in test/fixtures/will.json
    uint256 internal constant ALICE_ETH = 0;
    uint256 internal constant BOB_ETH = 1;
    uint256 internal constant BOB_ETH_TRANCHE = 2;
    uint256 internal constant ALICE_TOKEN = 3;
    uint256 internal constant BOB_TOKEN = 4;
    uint256 internal constant CAROL_TOKEN_AGE = 5;
    uint256 internal constant ERIN_TOKEN_AGE = 6;
    uint256 internal constant DAVE_NFT = 7;
    uint256 internal constant BOB_MULTI = 8;

    string internal livenessJson;
    string internal willJson;
    string internal ageJson;

    BequestVault internal impl;
    BequestFactory internal factory;
    BequestVault internal vault;
    MockERC20 internal token;
    MockERC721 internal nft;
    MockERC1155 internal multi;

    address internal owner = makeAddr("owner");
    address internal thief = makeAddr("thief");
    address internal relayer = makeAddr("relayer");
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;
    address internal erin;
    address internal residuary;

    uint256 internal binding;
    uint256 internal otherBinding;
    bytes32 internal root;

    function setUp() public virtual {
        livenessJson = vm.readFile("test/fixtures/liveness.json");
        willJson = vm.readFile("test/fixtures/will.json");
        ageJson = vm.readFile("test/fixtures/age.json");
        binding = vm.parseJsonUint(livenessJson, ".binding");
        otherBinding = vm.parseJsonUint(livenessJson, ".otherBinding");
        root = vm.parseJsonBytes32(willJson, ".root");
        alice = vm.parseJsonAddress(willJson, ".addresses.alice");
        bob = vm.parseJsonAddress(willJson, ".addresses.bob");
        carol = vm.parseJsonAddress(willJson, ".addresses.carol");
        dave = vm.parseJsonAddress(willJson, ".addresses.dave");
        erin = vm.parseJsonAddress(willJson, ".addresses.erin");
        residuary = vm.parseJsonAddress(willJson, ".addresses.residuary");

        vm.warp(T0);
        impl = new BequestVault(
            IGroth16Verifier(address(new LivenessVerifier())),
            IGroth16Verifier(address(new AgeVerifier())),
            MIN_PERIOD,
            AUTH_WINDOW,
            ILivenessRegistry(address(0)), // the aggregation path has its own suite
            0
        );
        factory = new BequestFactory(address(impl));

        // Tokens live at the fixed addresses baked into the will's Merkle leaves.
        deployCodeTo("MockTokens.sol:MockERC20", vm.parseJsonAddress(willJson, ".addresses.token20"));
        deployCodeTo("MockTokens.sol:MockERC721", vm.parseJsonAddress(willJson, ".addresses.nft721"));
        deployCodeTo("MockTokens.sol:MockERC1155", vm.parseJsonAddress(willJson, ".addresses.multi1155"));
        token = MockERC20(vm.parseJsonAddress(willJson, ".addresses.token20"));
        nft = MockERC721(vm.parseJsonAddress(willJson, ".addresses.nft721"));
        multi = MockERC1155(vm.parseJsonAddress(willJson, ".addresses.multi1155"));

        vault = _createVault(owner, root, binding);
        vm.deal(address(vault), 10 ether);
        token.mint(address(vault), 1000 ether);
        nft.mint(address(vault), 1);
        multi.mint(address(vault), 7, 100);
    }

    function _config(bytes32 root_, uint256 binding_) internal view returns (BequestVault.Config memory) {
        return BequestVault.Config({
            heartbeatInterval: I,
            lifeProofInterval: B,
            gracePeriod: G,
            claimWindow: W,
            allocationRoot: root_,
            residuary: residuary,
            livenessBinding: binding_
        });
    }

    function _createVault(address who, bytes32 root_, uint256 binding_) internal returns (BequestVault v) {
        vm.prank(who);
        v = BequestVault(payable(factory.createVault(_config(root_, binding_), bytes32(0))));
    }

    // ------------------------------------------------------------- fixture readers

    function _u2(string memory json, string memory path) internal pure returns (uint256[2] memory r) {
        uint256[] memory a = vm.parseJsonUintArray(json, path);
        r[0] = a[0];
        r[1] = a[1];
    }

    function _proof(string memory json, string memory key) internal pure returns (BequestVault.Proof memory p) {
        p.a = _u2(json, string.concat(key, ".a"));
        p.b[0] = _u2(json, string.concat(key, ".b[0]"));
        p.b[1] = _u2(json, string.concat(key, ".b[1]"));
        p.c = _u2(json, string.concat(key, ".c"));
    }

    /// @return p proof, bnd binding, ts liveness timestamp of fixture `key` (p10, p200, p400, other10)
    function _lifeProof(string memory key) internal view returns (BequestVault.Proof memory p, uint256 bnd, uint256 ts) {
        string memory k = string.concat(".", key);
        p = _proof(livenessJson, k);
        bnd = vm.parseJsonUint(livenessJson, string.concat(k, ".binding"));
        ts = vm.parseJsonUint(livenessJson, string.concat(k, ".ts"));
    }

    function _proveLife(string memory key) internal {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof(key);
        vault.proveLife(p, bnd, ts);
    }

    function _bequest(uint256 i) internal view returns (BequestVault.Bequest memory b, bytes32[] memory proof) {
        (b, proof) = _bequestFrom(willJson, string.concat(".leaves[", vm.toString(i), "]"));
    }

    function _bequestFrom(string memory json, string memory k)
        internal
        pure
        returns (BequestVault.Bequest memory b, bytes32[] memory proof)
    {
        b.index = vm.parseJsonUint(json, string.concat(k, ".index"));
        b.heir = vm.parseJsonAddress(json, string.concat(k, ".heir"));
        b.kind = uint8(vm.parseJsonUint(json, string.concat(k, ".kind")));
        b.token = vm.parseJsonAddress(json, string.concat(k, ".token"));
        b.id = vm.parseJsonUint(json, string.concat(k, ".id"));
        b.shareBps = uint16(vm.parseJsonUint(json, string.concat(k, ".shareBps")));
        b.notBefore = uint40(vm.parseJsonUint(json, string.concat(k, ".notBefore")));
        b.minAge = uint8(vm.parseJsonUint(json, string.concat(k, ".minAge")));
        b.ageCommitment = vm.parseJsonUint(json, string.concat(k, ".ageCommitment"));
        proof = vm.parseJsonBytes32Array(json, string.concat(k, ".proof"));
    }

    function _claim(uint256 i) internal {
        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(i);
        vault.claim(b, proof);
    }

    function _agePrf(string memory key) internal view returns (BequestVault.Proof memory p, uint256 cutoff) {
        string memory k = string.concat(".", key);
        p = _proof(ageJson, k);
        cutoff = vm.parseJsonUint(ageJson, string.concat(k, ".cutoff"));
    }

    function _warpToClaimable(BequestVault v) internal {
        vm.warp(v.claimableAt() + 1);
    }
}
