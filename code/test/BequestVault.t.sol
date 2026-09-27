// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./Base.t.sol";
import {BequestVault} from "../src/BequestVault.sol";

contract BequestVaultTest is BaseTest {
    // =================================================================== lifecycle

    function test_InitialState() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.allocationRoot(), root);
        assertTrue(vault.isBinding(binding));
        assertEq(vault.residuary(), residuary);
        assertEq(vault.lastHeartbeat(), T0);
        assertEq(vault.lastLifeProof(), T0);
        assertFalse(vault.lifeProven());
        assertEq(vault.deadline(), T0 + I);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Alive));
        assertEq(factory.vaultAddress(owner, bytes32(0)), address(vault));
    }

    function test_CannotReinitialize() public {
        vm.expectRevert(BequestVault.AlreadyInitialized.selector);
        vault.initialize(thief, _config(root, binding));
        vm.expectRevert(BequestVault.AlreadyInitialized.selector);
        impl.initialize(thief, _config(root, binding));
    }

    /// Phases change with time alone: no keeper transaction is needed.
    function test_StatusIsPureFunctionOfTime() public {
        vm.warp(T0 + I);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Alive));
        vm.warp(T0 + I + 1);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Grace));
        vm.warp(T0 + I + G);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Grace));
        vm.warp(T0 + I + G + 1);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Claimable));
    }

    // =================================================================== key-only heartbeats

    function test_Heartbeat_OnlyOwner() public {
        vm.prank(thief);
        vm.expectRevert(BequestVault.NotOwner.selector);
        vault.heartbeat();
    }

    function test_Heartbeat_ExtendsDeadline() public {
        vm.warp(T0 + 20 days);
        vm.prank(owner);
        vault.heartbeat();
        assertEq(vault.deadline(), T0 + 20 days + I);
    }

    function test_Heartbeat_RevivesDuringGrace() public {
        vm.warp(T0 + I + 10 days);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Grace));
        vm.prank(owner);
        vault.heartbeat();
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Alive));
    }

    /// Key-only heartbeats never move the deadline past lastLifeProof + B.
    function test_Heartbeat_CappedByLifeProofInterval() public {
        for (uint256 t = T0 + 29 days; t <= T0 + B; t += 29 days) {
            vm.warp(t);
            vm.prank(owner);
            vault.heartbeat();
            assertLe(vault.deadline(), T0 + B);
        }
        vm.warp(T0 + B + 1);
        vm.prank(owner);
        vault.heartbeat(); // accepted, but useless without a proof of life
        assertEq(vault.deadline(), T0 + B);
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Grace));
    }

    // =================================================================== proofs of life

    function test_ProveLife_AnyoneCanSubmit() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("p10");
        vm.warp(ts + 1 hours);
        vm.prank(relayer);
        vm.expectEmit(address(vault));
        emit BequestVault.LifeProven(ts);
        vault.proveLife(p, bnd, ts);
        assertEq(vault.lastLifeProof(), ts);
        assertEq(vault.lastHeartbeat(), ts);
        assertTrue(vault.lifeProven());
        assertEq(vault.deadline(), ts + I);
    }

    function test_ProveLife_RejectsReplay() public {
        vm.warp(T0 + 11 days);
        _proveLife("p10");
        vm.expectRevert(BequestVault.StaleOrFutureProof.selector);
        _proveLife("p10");
    }

    function test_ProveLife_RejectsOlderThanLast() public {
        vm.warp(T0 + 201 days);
        _proveLife("p200");
        vm.expectRevert(BequestVault.StaleOrFutureProof.selector);
        _proveLife("p10");
    }

    function test_ProveLife_RejectsFutureTimestamp() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("p10");
        vm.warp(ts - 16 minutes);
        vm.expectRevert(BequestVault.StaleOrFutureProof.selector);
        vault.proveLife(p, bnd, ts);
        vm.warp(ts - 14 minutes); // within MAX_CLOCK_SKEW
        vault.proveLife(p, bnd, ts);
    }

    function test_ProveLife_RejectsCredentialOlderThanVault() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("p10");
        vm.warp(ts + 1 days);
        BequestVault later = _createVault(makeAddr("later"), root, binding);
        vm.expectRevert(BequestVault.StaleOrFutureProof.selector);
        later.proveLife(p, bnd, ts);
    }

    function test_ProveLife_RejectsUnregisteredIssuer() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("other10");
        vm.warp(ts + 1 hours);
        vm.expectRevert(BequestVault.UnknownBinding.selector);
        vault.proveLife(p, bnd, ts);
    }

    function test_ProveLife_SecondIssuerAfterRegistration() public {
        vm.warp(T0 + 10 days + 1 hours);
        _proveLife("p10");
        vm.prank(owner);
        vault.setBinding(otherBinding, true);
        // The second issuer's credential is not newer than the last proof: still rejected.
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("other10");
        vm.expectRevert(BequestVault.StaleOrFutureProof.selector);
        vault.proveLife(p, bnd, ts);
    }

    function test_ProveLife_RejectsTamperedSignals() public {
        (BequestVault.Proof memory p, uint256 bnd, uint256 ts) = _lifeProof("p200");
        vm.warp(ts + 1 hours);
        vm.expectRevert(BequestVault.InvalidProof.selector);
        vault.proveLife(p, bnd, ts - 1 days); // different timestamp
        p.a[0] = p.a[0] ^ 1; // malformed point
        vm.expectRevert();
        vault.proveLife(p, bnd, ts);
    }

    /// A proof made for issuer A does not verify when presented under issuer B's (registered) binding.
    function test_ProveLife_RejectsProofBoundToAnotherIssuer() public {
        vm.warp(T0 + 10 days + 1 hours);
        _proveLife("p10");
        vm.prank(owner);
        vault.setBinding(otherBinding, true);
        (BequestVault.Proof memory p,, uint256 ts) = _lifeProof("p200");
        vm.warp(ts + 1 hours);
        vm.expectRevert(BequestVault.InvalidProof.selector);
        vault.proveLife(p, otherBinding, ts);
    }

    // =================================================================== threat: stolen / posthumous key

    /// The owner's last genuine proof of life is p10; afterwards only a key holder acts.
    /// However often the thief heartbeats, succession opens by lastLifeProof + B + G.
    function test_KeyThief_CanOnlyDelaySuccessionBoundedly() public {
        (,, uint256 lastGenuine) = _lifeProof("p10");
        vm.warp(lastGenuine + 1 hours);
        _proveLife("p10");

        // The thief (holding the owner's key) heartbeats every 29 days for as long as it helps.
        for (uint256 t = lastGenuine + 29 days; t <= lastGenuine + B + G; t += 29 days) {
            vm.warp(t);
            vm.prank(owner);
            vault.heartbeat();
            assertLe(vault.claimableAt(), lastGenuine + B + G);
        }
        uint256 opensAt = vault.claimableAt();
        assertEq(opensAt, lastGenuine + B + G);

        // The thief cannot move assets or rewrite the will without a fresh proof of life.
        vm.startPrank(owner);
        vm.expectRevert(BequestVault.ProofOfLifeRequired.selector);
        vault.withdraw(0, address(0), 0, 1 ether, thief);
        vm.expectRevert(BequestVault.ProofOfLifeRequired.selector);
        vault.setAllocationRoot(keccak256("thief's will"));
        vm.stopPrank();

        vm.warp(opensAt + 1);
        _claim(ALICE_ETH);
        assertEq(alice.balance, 6 ether);
    }

    // =================================================================== owner actions

    function test_Withdraw_NeedsFreshProofOfLife() public {
        vm.prank(owner);
        vm.expectRevert(BequestVault.ProofOfLifeRequired.selector); // creation is not enough
        vault.withdraw(0, address(0), 0, 1 ether, owner);

        (,, uint256 ts) = _lifeProof("p10");
        vm.warp(ts + 1 hours);
        _proveLife("p10");
        vm.prank(owner);
        vault.withdraw(0, address(0), 0, 1 ether, owner);
        assertEq(owner.balance, 1 ether);

        vm.warp(ts + AUTH_WINDOW + 1);
        vm.prank(owner);
        vm.expectRevert(BequestVault.ProofOfLifeRequired.selector);
        vault.withdraw(0, address(0), 0, 1 ether, owner);
    }

    function test_Withdraw_AllAssetKinds() public {
        vm.warp(T0 + 10 days + 1 hours);
        _proveLife("p10");
        vm.startPrank(owner);
        vault.withdraw(1, address(token), 0, 5 ether, owner);
        vault.withdraw(2, address(nft), 1, 1, owner);
        vault.withdraw(3, address(multi), 7, 40, owner);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), 5 ether);
        assertEq(nft.ownerOf(1), owner);
        assertEq(multi.balanceOf(owner, 7), 40);
    }

    function test_OwnerActions_RejectNonOwnerEvenWithFreshProof() public {
        vm.warp(T0 + 10 days + 1 hours);
        _proveLife("p10");
        vm.startPrank(thief);
        vm.expectRevert(BequestVault.NotOwner.selector);
        vault.withdraw(0, address(0), 0, 1 ether, thief);
        vm.expectRevert(BequestVault.NotOwner.selector);
        vault.setAllocationRoot(bytes32(uint256(1)));
        vm.expectRevert(BequestVault.NotOwner.selector);
        vault.setResiduary(thief);
        vm.stopPrank();
    }

    function test_SetTimers_Validation() public {
        vm.warp(T0 + 10 days + 1 hours);
        _proveLife("p10");
        vm.startPrank(owner);
        vm.expectRevert(BequestVault.InvalidConfig.selector);
        vault.setTimers(MIN_PERIOD - 60, B, G, W); // below the minimum
        vm.expectRevert(BequestVault.InvalidConfig.selector);
        vault.setTimers(I + 1, B, G, W); // not a whole minute
        vault.setTimers(60 days, 2 * B, G, W);
        vm.stopPrank();
        assertEq(vault.heartbeatInterval(), 60 days);
        assertEq(vault.lifeProofInterval(), 2 * B);
    }

    function test_CreateVault_RejectsBadConfig() public {
        BequestVault.Config memory cfg = _config(root, binding);
        cfg.residuary = address(0);
        vm.expectRevert(BequestVault.InvalidConfig.selector);
        factory.createVault(cfg, bytes32(uint256(1)));
        cfg = _config(root, binding);
        cfg.gracePeriod = 0;
        vm.expectRevert(BequestVault.InvalidConfig.selector);
        factory.createVault(cfg, bytes32(uint256(1)));
    }

    // =================================================================== revival and settlement

    /// Even after the vault becomes claimable, a proof of life revives it until the first claim.
    function test_ProofOfLifeRevivesClaimableVaultBeforeFirstClaim() public {
        (,, uint256 ts) = _lifeProof("p200");
        vm.warp(ts + 1 hours);
        assertGt(block.timestamp, vault.claimableAt()); // claimable since T0 + I + G
        _proveLife("p200");
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Alive));
        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(ALICE_ETH);
        vm.expectRevert(BequestVault.NotClaimable.selector);
        vault.claim(b, proof);
    }

    function test_FirstClaimSettlesIrrevocably() public {
        _warpToClaimable(vault);
        _claim(ALICE_ETH);
        assertTrue(vault.settled());
        assertEq(uint8(vault.status()), uint8(BequestVault.Status.Settled));

        (,, uint256 ts) = _lifeProof("p200");
        vm.warp(ts + 1 hours);
        vm.expectRevert(BequestVault.VaultSettled.selector);
        _proveLife("p200");
        vm.prank(owner);
        vm.expectRevert(BequestVault.VaultSettled.selector);
        vault.heartbeat();
    }

    // =================================================================== claims

    function test_Claim_RevertsWhileAliveOrGrace() public {
        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(ALICE_ETH);
        vm.expectRevert(BequestVault.NotClaimable.selector);
        vault.claim(b, proof);
        vm.warp(vault.claimableAt());
        vm.expectRevert(BequestVault.NotClaimable.selector);
        vault.claim(b, proof);
    }

    function test_Claim_EthProRataAndTranche() public {
        _warpToClaimable(vault);
        vm.prank(relayer); // anyone may submit; funds go to the heir in the leaf
        _claim(ALICE_ETH);
        _claim(BOB_ETH);
        assertEq(alice.balance, 6 ether);
        assertEq(bob.balance, 2 ether);

        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(BOB_ETH_TRANCHE);
        vm.expectRevert(BequestVault.TimeLocked.selector);
        vault.claim(b, proof);
        vm.warp(b.notBefore);
        vault.claim(b, proof);
        assertEq(bob.balance, 4 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_Claim_TokensWithAgeGates() public {
        _warpToClaimable(vault);
        _claim(ALICE_TOKEN);
        _claim(BOB_TOKEN);
        assertEq(token.balanceOf(alice), 400 ether);
        assertEq(token.balanceOf(bob), 300 ether);

        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(CAROL_TOKEN_AGE);
        vm.expectRevert(BequestVault.AgeProofRequired.selector);
        vault.claim(b, proof);

        (BequestVault.Proof memory ap, uint256 cutoff) = _agePrf("carol");
        uint256 eligibleAt = vm.parseJsonUint(ageJson, ".carolEligibleAt");
        vm.warp(eligibleAt - 1 days);
        vm.expectRevert(BequestVault.AgeNotReached.selector);
        vault.claimWithAgeProof(b, proof, ap, cutoff);

        vm.warp(eligibleAt);
        vault.claimWithAgeProof(b, proof, ap, cutoff);
        assertEq(token.balanceOf(carol), 200 ether);
    }

    /// A valid proof for a later cutoff does not let a heir claim early.
    function test_Claim_AgeProofWithTooLateCutoffRejected() public {
        _warpToClaimable(vault);
        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(CAROL_TOKEN_AGE);
        (BequestVault.Proof memory ap, uint256 cutoff) = _agePrf("carolLoose");
        vm.warp(vm.parseJsonUint(ageJson, ".carolEligibleAt") + 1 days);
        vm.expectRevert(BequestVault.AgeNotReached.selector);
        vault.claimWithAgeProof(b, proof, ap, cutoff);
    }

    /// Carol's proof cannot unlock Erin's bequest: the vault feeds Erin's commitment to the verifier.
    function test_Claim_AgeProofBoundToLeafCommitment() public {
        _warpToClaimable(vault);
        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(ERIN_TOKEN_AGE);
        (BequestVault.Proof memory ap, uint256 cutoff) = _agePrf("carol");
        vm.warp(vm.parseJsonUint(ageJson, ".carolEligibleAt") + 1 days);
        vm.expectRevert(BequestVault.InvalidProof.selector);
        vault.claimWithAgeProof(b, proof, ap, cutoff);
    }

    function test_Claim_Erc721AndErc1155() public {
        _warpToClaimable(vault);
        _claim(DAVE_NFT);
        _claim(BOB_MULTI);
        assertEq(nft.ownerOf(1), dave);
        assertEq(multi.balanceOf(bob, 7), 100);
    }

    function test_Claim_DoubleClaimReverts() public {
        _warpToClaimable(vault);
        _claim(ALICE_ETH);
        assertTrue(vault.isClaimed(ALICE_ETH));
        vm.expectRevert(BequestVault.AlreadyClaimed.selector);
        _claim(ALICE_ETH);
    }

    function test_Claim_ForgedLeafReverts() public {
        _warpToClaimable(vault);
        (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(BOB_ETH);
        b.shareBps = 10_000;
        vm.expectRevert(BequestVault.InvalidBequest.selector);
        vault.claim(b, proof);
        (b, proof) = _bequest(BOB_ETH);
        b.heir = thief;
        vm.expectRevert(BequestVault.InvalidBequest.selector);
        vault.claim(b, proof);
    }

    /// The vault enforces the 100% bound even if a (buggy or malicious) tree over-allocates.
    function test_Claim_OverAllocationRejected() public {
        BequestVault.Bequest memory b = BequestVault.Bequest({
            index: 0, heir: alice, kind: 0, token: address(0), id: 0,
            shareBps: 10_001, notBefore: 0, minAge: 0, ageCommitment: 0
        });
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(b))));
        BequestVault v = _createVault(makeAddr("sloppy"), leaf, binding);
        vm.deal(address(v), 1 ether);
        _warpToClaimable(v);
        vm.expectRevert(BequestVault.InvalidShare.selector);
        v.claim(b, new bytes32[](0));
    }

    function test_FullSuccessionAndSweep() public {
        _warpToClaimable(vault);
        for (uint256 i; i <= BOB_MULTI; i++) {
            if (i == BOB_ETH_TRANCHE || i == CAROL_TOKEN_AGE || i == ERIN_TOKEN_AGE) continue;
            _claim(i);
        }
        vm.expectRevert(BequestVault.ClaimWindowOpen.selector);
        vault.sweep(1, address(token), 0);

        // Nobody claims the tranche or the age-gated shares; after the window they go to the residuary.
        vm.warp(vault.claimableAt() + W + 1);
        vault.sweep(0, address(0), 0);
        vault.sweep(1, address(token), 0);
        assertEq(residuary.balance, 2 ether);
        assertEq(token.balanceOf(residuary), 300 ether);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    // =================================================================== batched claims

    function _many(uint256 a, uint256 b)
        internal
        view
        returns (BequestVault.Bequest[] memory bs, bytes32[][] memory proofs)
    {
        bs = new BequestVault.Bequest[](2);
        proofs = new bytes32[][](2);
        (bs[0], proofs[0]) = _bequest(a);
        (bs[1], proofs[1]) = _bequest(b);
    }

    function test_ClaimMany_OneTransactionPerHeir() public {
        _warpToClaimable(vault);
        (BequestVault.Bequest[] memory bs, bytes32[][] memory proofs) = _many(ALICE_ETH, ALICE_TOKEN);
        vault.claimMany(bs, proofs);
        assertEq(alice.balance, 6 ether);
        assertEq(token.balanceOf(alice), 400 ether);
        assertTrue(vault.isClaimed(ALICE_ETH) && vault.isClaimed(ALICE_TOKEN));
    }

    function test_ClaimMany_RejectsAgeGatedLeafAndLengthMismatch() public {
        _warpToClaimable(vault);
        (BequestVault.Bequest[] memory bs, bytes32[][] memory proofs) = _many(ALICE_ETH, CAROL_TOKEN_AGE);
        vm.expectRevert(BequestVault.AgeProofRequired.selector);
        vault.claimMany(bs, proofs);
        bytes32[][] memory short = new bytes32[][](1);
        vm.expectRevert(BequestVault.InvalidBequest.selector);
        vault.claimMany(bs, short);
        assertFalse(vault.isClaimed(ALICE_ETH)); // the whole batch reverted
    }

    function test_ClaimManyWithAgeProof_RejectsMixedCommitments() public {
        _warpToClaimable(vault);
        (BequestVault.Bequest[] memory bs, bytes32[][] memory proofs) = _many(CAROL_TOKEN_AGE, ERIN_TOKEN_AGE);
        (BequestVault.Proof memory ap, uint256 cutoff) = _agePrf("carol");
        vm.warp(vm.parseJsonUint(ageJson, ".carolEligibleAt"));
        vm.expectRevert(BequestVault.InvalidBequest.selector);
        vault.claimManyWithAgeProof(bs, proofs, ap, cutoff);
    }

    function test_ClaimManyWithAgeProof_ChecksAgeBeforePaying() public {
        _warpToClaimable(vault);
        BequestVault.Bequest[] memory bs = new BequestVault.Bequest[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        (bs[0], proofs[0]) = _bequest(CAROL_TOKEN_AGE);
        (BequestVault.Proof memory ap, uint256 cutoff) = _agePrf("carol");
        uint256 eligibleAt = vm.parseJsonUint(ageJson, ".carolEligibleAt");
        vm.warp(eligibleAt - 1 days);
        vm.expectRevert(BequestVault.AgeNotReached.selector);
        vault.claimManyWithAgeProof(bs, proofs, ap, cutoff);
        vm.warp(eligibleAt);
        vault.claimManyWithAgeProof(bs, proofs, ap, cutoff);
        assertEq(token.balanceOf(carol), 200 ether);
    }

    // =================================================================== calendar

    function test_AgeCutoff_KnownDates() public view {
        assertEq(vault.ageCutoff(2_001_196_800, 18), 20_150_601); // 2033-06-01 00:00 UTC
        assertEq(vault.ageCutoff(2_001_196_799, 18), 20_150_531); // one second earlier
        assertEq(vault.ageCutoff(1_709_164_800, 18), 20_060_229); // 2024-02-29 (leap day)
        assertEq(vault.ageCutoff(946_684_799, 0), 19_991_231); // 1999-12-31 23:59:59
        assertEq(vault.ageCutoff(946_684_800, 21), 19_790_101); // 2000-01-01
        assertEq(vault.ageCutoff(4_102_444_800, 18), 20_820_101); // 2100-01-01
    }

    function testFuzz_AgeCutoff_ValidCalendarDate(uint40 ts) public view {
        uint256 c = vault.ageCutoff(ts, 0);
        uint256 m = (c / 100) % 100;
        uint256 d = c % 100;
        assertGe(m, 1);
        assertLe(m, 12);
        assertGe(d, 1);
        assertLe(d, 31);
        // Monotone in time.
        if (ts > 1 days) assertLe(vault.ageCutoff(ts - 1 days, 0), c);
    }

    // =================================================================== real credential

    /// Uses a proof generated from a real Billions LivenessCredential when it is available locally
    /// (fixtures/private is git-ignored; see README).
    function test_RealBillionsCredential() public {
        string memory path = "fixtures/private/proofs/liveness-2025-12-14.proof.json";
        if (!vm.exists(path)) return;
        string memory json = vm.readFile(path);
        BequestVault.Proof memory p = _proof(json, ".calldata");
        uint256 bnd = vm.parseJsonUint(json, ".binding");
        uint256 ts = vm.parseJsonUint(json, ".livenessTimestamp");

        vm.warp(ts - 7 days);
        BequestVault v = _createVault(makeAddr("real-owner"), root, bnd);
        vm.warp(ts + 1 hours);
        v.proveLife(p, bnd, ts);
        assertEq(v.lastLifeProof(), ts);
        assertTrue(v.lifeProven());
    }
}
