// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {MockERC20, MockERC721} from "./mocks/MockTokens.sol";
import {UnifiedWillManager} from "./legacy/src/WillManager.sol";
import {Groth16Verifier as LegacyAgeVerifier} from "./legacy/src/ZKProofs/AgeVerifier.sol";
import {Groth16Verifier as LegacyLivenessVerifier} from "./legacy/src/ZKProofs/Verifier.sol";

/// @notice Same succession workload on Bequest and on the legacy explicit-state-machine design.
///         Run: WRITE_REPORTS=true forge test --match-contract Comparison --isolate -vv
///         (writes reports/comparison.json)
///
/// Workload for n heirs: an ETH pool (1 ETH) and an ERC-20 pool (1000 tokens) split equally, one
/// NFT for heir 0, and every heir age-restricted (the legacy design requires an age proof from
/// every heir). Both designs use real Groth16 verifiers and real proofs.
contract Comparison is BaseTest {
    struct Tally {
        uint256 setup;      // owner transactions: create, register heirs/assets, deposits, approvals
        uint256 keeper;     // transactions only needed to move the state machine forward
        uint256 succession; // heirs' claims / proofs / execution batches
        uint256 txs;
    }

    string internal constant OUT = "comparison";

    function _add(Tally memory t, uint256 phase) internal view {
        uint256 g = vm.lastCallGas().gasTotalUsed;
        if (phase == 0) t.setup += g;
        else if (phase == 1) t.keeper += g;
        else t.succession += g;
        t.txs++;
    }

    function _heir(uint256 n, uint256 i) internal pure returns (address) {
        return address(uint160(0x4000000000000000000000000000000000000000) + uint160(n << 16) + uint160(i));
    }

    function _share(uint256 n, uint256 i) internal pure returns (uint16) {
        uint256 s = 10_000 / n;
        return uint16(i == 0 ? 10_000 - s * (n - 1) : s);
    }

    // ------------------------------------------------------------------ Merkle helper (OZ-compatible)

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _leaf(BequestVault.Bequest memory b) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(b))));
    }

    function _tree(bytes32[] memory leaves, uint256 k) internal pure returns (bytes32 root, bytes32[] memory proof) {
        bytes32[] memory layer = leaves;
        bytes32[] memory tmp = new bytes32[](64);
        uint256 len;
        uint256 idx = k;
        while (layer.length > 1) {
            uint256 m = (layer.length + 1) / 2;
            bytes32[] memory next = new bytes32[](m);
            for (uint256 i; i < layer.length / 2; i++) next[i] = _pair(layer[2 * i], layer[2 * i + 1]);
            if (layer.length % 2 == 1) next[m - 1] = layer[layer.length - 1];
            if ((idx ^ 1) < layer.length) tmp[len++] = layer[idx ^ 1];
            idx /= 2;
            layer = next;
        }
        root = layer[0];
        proof = new bytes32[](len);
        for (uint256 i; i < len; i++) proof[i] = tmp[i];
    }

    // ------------------------------------------------------------------ Bequest

    struct Ctx {
        uint256 n;
        MockERC20 tok;
        MockERC721 nft;
        BequestVault v;
        BequestVault.Bequest[] bs;
        bytes32[] leaves;
        BequestVault.Proof ap;
        uint256 cutoff;
        bool ageGated;
    }

    function _runBequest(uint256 n, bool ageGated) internal returns (Tally memory t) {
        Ctx memory c;
        c.n = n;
        c.ageGated = ageGated;
        c.tok = new MockERC20();
        c.nft = new MockERC721();
        (c.ap, c.cutoff) = _agePrf("carol");
        _buildWill(c);
        _createAndFund(c, t);
        // No keeper transactions: the vault becomes claimable with time alone.
        vm.warp(vm.parseJsonUint(ageJson, ".carolEligibleAt"));
        assertGt(block.timestamp, c.v.claimableAt());
        for (uint256 i; i < n; i++) {
            _claimAllOf(c, i);
            _add(t, 2);
        }
        assertEq(address(c.v).balance, 0);
        assertEq(c.tok.balanceOf(address(c.v)), 0);
        assertEq(c.nft.ownerOf(1), _heir(n, 0));
    }

    /// Per heir an ETH and an ERC-20 bequest; heir 0 also the NFT. Either all age-gated (18) with the
    /// fixture commitment whose age proof is in test/fixtures/age.json, or none (blinded leaves).
    function _buildWill(Ctx memory c) internal view {
        uint256 commitment = vm.parseJsonUint(willJson, ".leaves[5].ageCommitment");
        uint8 minAge = c.ageGated ? 18 : 0;
        uint256 n = c.n;
        c.bs = new BequestVault.Bequest[](2 * n + 1);
        c.leaves = new bytes32[](2 * n + 1);
        for (uint256 i; i < n; i++) {
            c.bs[2 * i] = BequestVault.Bequest(2 * i, _heir(n, i), 0, address(0), 0, _share(n, i), 0, minAge, commitment);
            c.bs[2 * i + 1] = BequestVault.Bequest(2 * i + 1, _heir(n, i), 1, address(c.tok), 0, _share(n, i), 0, minAge, commitment);
        }
        c.bs[2 * n] = BequestVault.Bequest(2 * n, _heir(n, 0), 2, address(c.nft), 1, 0, 0, minAge, commitment);
        for (uint256 j; j < c.bs.length; j++) {
            if (!c.ageGated) c.bs[j].ageCommitment = uint256(keccak256(abi.encode("blind", n, j))) >> 6;
            c.leaves[j] = _leaf(c.bs[j]);
        }
    }

    function _createAndFund(Ctx memory c, Tally memory t) internal {
        (bytes32 root,) = _tree(c.leaves, 0);
        address o = address(uint160(0xA0000 + c.n + (c.ageGated ? 0 : 0x1000)));
        vm.deal(o, 2 ether);
        c.tok.mint(o, 1000 ether);
        c.nft.mint(o, 1);
        vm.warp(T0);
        vm.prank(o);
        c.v = BequestVault(payable(factory.createVault(_config(root, binding), bytes32(0))));
        _add(t, 0);
        vm.prank(o);
        (bool ok,) = address(c.v).call{value: 1 ether}("");
        assertTrue(ok);
        _add(t, 0);
        vm.prank(o);
        c.tok.transfer(address(c.v), 1000 ether);
        _add(t, 0);
        vm.prank(o);
        c.nft.transferFrom(o, address(c.v), 1);
        _add(t, 0);
    }

    /// Heir i claims all of their bequests in one transaction with one age proof.
    function _claimAllOf(Ctx memory c, uint256 i) internal {
        uint256 m = i == 0 ? 3 : 2;
        BequestVault.Bequest[] memory mine = new BequestVault.Bequest[](m);
        bytes32[][] memory proofs = new bytes32[][](m);
        for (uint256 j; j < m; j++) {
            uint256 idx = j < 2 ? 2 * i + j : 2 * c.n;
            mine[j] = c.bs[idx];
            (, proofs[j]) = _tree(c.leaves, idx);
        }
        vm.prank(_heir(c.n, i));
        if (c.ageGated) c.v.claimManyWithAgeProof(mine, proofs, c.ap, c.cutoff);
        else c.v.claimMany(mine, proofs);
    }

    // ------------------------------------------------------------------ legacy

    struct LCtx {
        uint256 n;
        MockERC20 tok;
        MockERC721 nft;
        UnifiedWillManager legacy;
        address o;
        uint256 commitment;
        BequestVault.Proof p;
        uint256[4] pub;
    }

    function _runLegacy(uint256 n) internal returns (Tally memory t) {
        LCtx memory c;
        c.n = n;
        c.tok = new MockERC20();
        c.nft = new MockERC721();
        c.legacy = new UnifiedWillManager(address(new LegacyAgeVerifier()), address(new LegacyLivenessVerifier()));
        string memory pj = vm.readFile("test/legacy/zk/proof.json");
        c.commitment = vm.parseJsonUint(pj, ".commitment");
        c.p = _proof(pj, "");
        uint256[] memory pubArr = vm.parseJsonUintArray(pj, ".pub");
        c.pub = [pubArr[0], pubArr[1], pubArr[2], pubArr[3]];
        c.o = address(uint160(0xB0000 + n));
        vm.deal(c.o, 2 ether);
        c.tok.mint(c.o, 1000 ether);
        c.nft.mint(c.o, 1);
        vm.warp(T0);
        _legacySetup(c, t);
        _legacyKeeper(c, t);
        _legacySuccession(c, t);
        assertEq(address(c.legacy).balance, 0);
        assertEq(c.tok.balanceOf(address(c.legacy)), 0);
        assertEq(c.nft.ownerOf(1), _heir(n, 0));
    }

    function _legacySetup(LCtx memory c, Tally memory t) internal {
        vm.startPrank(c.o);
        c.legacy.createWill(0, residuary);
        _add(t, 0);
        for (uint256 i; i < c.n; i++) {
            c.legacy.addHeir(0, _heir(c.n, i), _share(c.n, i), c.commitment, 18, 0);
            _add(t, 0);
        }
        c.legacy.addETHAsset{value: 1 ether}(0);
        _add(t, 0);
        c.tok.approve(address(c.legacy), 1000 ether);
        _add(t, 0);
        c.legacy.addERC20Asset(0, address(c.tok), 1000 ether);
        _add(t, 0);
        c.nft.approve(address(c.legacy), 1);
        _add(t, 0);
        c.legacy.addERC721Asset(0, address(c.nft), 1, _heir(c.n, 0));
        _add(t, 0);
        c.legacy.activateWill(0);
        _add(t, 0);
        vm.stopPrank();
    }

    /// Transactions that only move the legacy state machine: inactivity -> grace -> heir proofs.
    function _legacyKeeper(LCtx memory c, Tally memory t) internal {
        vm.warp(T0 + 30 days + 1);
        c.legacy.detectInactivity(c.o, 0);
        _add(t, 1);
        vm.warp(block.timestamp + 30 days);
        c.legacy.startGracePeriod(c.o, 0);
        _add(t, 1);
        vm.warp(block.timestamp + 90 days);
        vm.prank(_heir(c.n, 0));
        c.legacy.finalizeGracePeriod(c.o, 0);
        _add(t, 1);
    }

    function _legacySuccession(LCtx memory c, Tally memory t) internal {
        for (uint256 i; i < c.n; i++) {
            vm.prank(_heir(c.n, i));
            c.legacy.verifyHeirAge(c.o, 0, i, c.p.a, c.p.b, c.p.c, c.pub);
            _add(t, 2);
        }
        for (uint256 done; done < c.n; done += 10) {
            c.legacy.executeInheritanceBatch(c.o, 0, 10);
            _add(t, 2);
        }
    }

    function _json(string memory key, Tally memory t) internal returns (string memory) {
        vm.serializeUint(key, "setup", t.setup);
        vm.serializeUint(key, "keeper", t.keeper);
        vm.serializeUint(key, "succession", t.succession);
        vm.serializeUint(key, "transactions", t.txs);
        return vm.serializeUint(key, "total", t.setup + t.keeper + t.succession);
    }

    function test_CompareLifecycleGas() public {
        uint256[5] memory sizes = [uint256(1), 2, 4, 8, 16];
        string memory out;
        for (uint256 k; k < sizes.length; k++) {
            uint256 n = sizes[k];
            Tally memory b = _runBequest(n, true);
            Tally memory b0 = _runBequest(n, false);
            Tally memory l = _runLegacy(n);
            string memory row = string.concat("n", vm.toString(n));
            vm.serializeUint(row, "heirs", n);
            vm.serializeString(row, "bequest", _json(string.concat(row, "b"), b));
            vm.serializeString(row, "bequestNoAgeGate", _json(string.concat(row, "b0"), b0));
            string memory rowJson = vm.serializeString(row, "legacy", _json(string.concat(row, "l"), l));
            out = vm.serializeString(OUT, row, rowJson);
            emit log_named_uint(string.concat("n=", vm.toString(n), " bequest total"), b.setup + b.keeper + b.succession);
            emit log_named_uint(string.concat("n=", vm.toString(n), " bequest (no age gates) total"), b0.setup + b0.keeper + b0.succession);
            emit log_named_uint(string.concat("n=", vm.toString(n), " legacy  total"), l.setup + l.keeper + l.succession);
        }
        if (vm.envOr("WRITE_REPORTS", false)) vm.writeJson(out, "reports/comparison.json");
    }
}
