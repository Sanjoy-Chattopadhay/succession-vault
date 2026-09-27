// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {BequestVault} from "../src/BequestVault.sol";

/// @notice Gas benchmark. Run with `forge test --match-contract GasBenchmark --isolate -vv`:
///         with --isolate every top-level call is its own transaction, so the reported figures
///         are transaction gas (21000 base + calldata + execution, cold/warm as on-chain).
///         With WRITE_REPORTS=true, results are written to reports/gas-*.json (only meaningful
///         together with --isolate; a plain `forge test` must not overwrite them).
contract GasBenchmark is BaseTest {
    string internal ops = "ops";
    string internal scaling = "scaling";

    function _record(string memory name) internal returns (uint256 used) {
        Vm.Gas memory g = vm.lastCallGas();
        used = g.gasTotalUsed;
        vm.serializeUint(ops, name, used);
        emit log_named_uint(name, used);
    }

    function test_GasPerOperation() public {
        // --- creation and deposits
        vm.prank(makeAddr("fresh"));
        factory.createVault(_config(root, binding), bytes32(0));
        _record("createVault");

        vm.deal(owner, 5 ether);
        vm.prank(owner);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        _record("depositETH");

        token.mint(owner, 10 ether);
        vm.prank(owner);
        token.transfer(address(vault), 1 ether);
        _record("depositERC20_transfer");

        // --- liveness
        vm.warp(T0 + 5 days);
        vm.prank(owner);
        vault.heartbeat();
        _record("heartbeat");

        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("p10");
        vm.warp(ts + 1 hours);
        vault.proveLife(p, bnd, ts);
        _record("proveLife");

        // --- owner actions after a proof of life
        vm.prank(owner);
        vault.withdraw(0, address(0), 0, 0.5 ether, owner);
        _record("withdrawETH");

        vm.prank(owner);
        vault.setAllocationRoot(root);
        _record("setAllocationRoot");

        // --- succession
        _warpToClaimable(vault);
        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(ALICE_ETH);
        vault.claim(b, proof);
        _record("claimETH_first");

        (b, proof) = _bequest(BOB_ETH);
        vault.claim(b, proof);
        _record("claimETH");

        (b, proof) = _bequest(ALICE_TOKEN);
        vault.claim(b, proof);
        _record("claimERC20_firstOfPool");

        (b, proof) = _bequest(BOB_TOKEN);
        vault.claim(b, proof);
        _record("claimERC20");

        (b, proof) = _bequest(DAVE_NFT);
        vault.claim(b, proof);
        _record("claimERC721");

        (b, proof) = _bequest(BOB_MULTI);
        vault.claim(b, proof);
        _record("claimERC1155");

        (b, proof) = _bequest(CAROL_TOKEN_AGE);
        (BequestVault.Proof memory ap, uint256 cutoff) = _agePrf("carol");
        vm.warp(vm.parseJsonUint(ageJson, ".carolEligibleAt"));
        vault.claimWithAgeProof(b, proof, ap, cutoff);
        _record("claimWithAgeProof");

        vm.warp(vault.claimableAt() + W + 1);
        vault.sweep(1, address(token), 0);
        _record("sweepERC20");
        vault.sweep(0, address(0), 0);
        _record("sweepETH");

        string memory json = vm.serializeString(ops, "unit", "transaction gas (forge --isolate)");
        if (vm.envOr("WRITE_REPORTS", false)) vm.writeJson(json, "reports/gas-ops.json");
    }

    /// j-of-m issuer threshold: registering an issuer with a threshold, and a 2-issuer proof of life.
    function test_GasThreshold() public {
        string memory thr = vm.readFile("test/fixtures/threshold.json");
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("p10");
        vm.warp(ts + 1 hours);
        vault.proveLife(p, bnd, ts);

        vm.prank(owner);
        vault.setBindingThreshold(vm.parseJsonUint(thr, ".bindingB"), 2);
        _record("setBindingThreshold_new");
        vm.prank(owner);
        vault.setBindingThreshold(binding, 2);
        _record("setBindingThreshold_update");

        BequestVault.Proof[] memory ps = new BequestVault.Proof[](2);
        uint256[] memory bs = new uint256[](2);
        uint256[] memory tss = new uint256[](2);
        ps[0] = _proof(thr, ".a200");
        bs[0] = vm.parseJsonUint(thr, ".a200.binding");
        tss[0] = vm.parseJsonUint(thr, ".a200.ts");
        ps[1] = _proof(thr, ".b200");
        bs[1] = vm.parseJsonUint(thr, ".b200.binding");
        tss[1] = vm.parseJsonUint(thr, ".b200.ts");
        vm.warp(tss[0] + 1 hours);
        vault.proveLifeMulti(ps, bs, tss);
        string memory json = vm.serializeUint(ops, "proveLifeMulti_2", _record("proveLifeMulti_2"));
        if (vm.envOr("WRITE_REPORTS", false)) vm.writeJson(json, "reports/gas-threshold.json");
    }

    /// Execution gas of the Groth16 verifier contracts alone (pairing check + public-input MSM).
    /// verifyProof is a view function, so this is a static call: no base fee or calldata cost.
    function test_GasVerifiersOnly() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("p10");
        bool ok = impl.LIVENESS_VERIFIER().verifyProof(p.a, p.b, p.c, [bnd, ts]);
        assertTrue(ok);
        _record("verifyLivenessProof");
        (BequestVault.Proof memory ap, uint256 cutoff) = _agePrf("carol");
        ok = impl.AGE_VERIFIER().verifyProof(ap.a, ap.b, ap.c, [vm.parseJsonUint(ageJson, ".carol.commitment"), cutoff]);
        assertTrue(ok);
        string memory json = vm.serializeUint(ops, "verifyAgeProof", _record("verifyAgeProof"));
        if (vm.envOr("WRITE_REPORTS", false)) vm.writeJson(json, "reports/gas-verifiers.json");
    }

    /// Creation cost is independent of the number of heirs; claim cost grows with log2(n).
    function test_GasScalingWithHeirs() public {
        string memory treesJson = vm.readFile("test/fixtures/trees.json");
        uint256[10] memory sizes = [uint256(1), 2, 4, 8, 16, 32, 64, 128, 256, 1024];
        string memory out;
        for (uint256 i; i < sizes.length; i++) {
            string memory k = string.concat(".n", vm.toString(sizes[i]));
            bytes32 r = vm.parseJsonBytes32(treesJson, string.concat(k, ".root"));
            (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequestFrom(treesJson, string.concat(k, ".leaf"));

            address o = address(uint160(0xB0000 + i));
            vm.warp(T0);
            vm.prank(o);
            BequestVault v = BequestVault(payable(factory.createVault(_config(r, binding), bytes32(0))));
            uint256 createGas = vm.lastCallGas().gasTotalUsed;
            token.mint(address(v), 1000 ether);

            vm.warp(v.claimableAt() + 1);
            v.claim(b, proof);
            uint256 claimGas = vm.lastCallGas().gasTotalUsed;

            string memory row = string.concat("n", vm.toString(sizes[i]));
            vm.serializeUint(row, "heirs", sizes[i]);
            vm.serializeUint(row, "proofLength", proof.length);
            vm.serializeUint(row, "createVault", createGas);
            string memory rowJson = vm.serializeUint(row, "claimERC20_firstOfPool", claimGas);
            out = vm.serializeString(scaling, row, rowJson);
            emit log_named_uint(string.concat("n=", vm.toString(sizes[i]), " create"), createGas);
            emit log_named_uint(string.concat("n=", vm.toString(sizes[i]), " claim"), claimGas);
        }
        if (vm.envOr("WRITE_REPORTS", false)) vm.writeJson(out, "reports/gas-scaling.json");
    }
}
