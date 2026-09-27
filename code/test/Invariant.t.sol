// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {MockERC20} from "./mocks/MockTokens.sol";

/// @dev Drives a vault through random interleavings of time, heartbeats, proofs of life, claims,
///      owner withdrawals, thief attempts and sweeps, and records safety violations in ghosts.
contract VaultHandler is Test {
    BequestVault internal immutable vault;
    address internal immutable owner;
    address internal immutable thief;
    uint32 internal immutable authWindow;

    BequestVault.Bequest[] internal bequests;
    bytes32[][] internal merkleProofs;
    BequestVault.Proof[] internal lifeProofs;
    uint256[] internal lifeTimes;
    uint256 internal immutable binding;

    uint256 public earlyClaims;          // claims that succeeded while not yet claimable
    uint256 public unauthorizedActions;  // owner actions that succeeded without a fresh proof of life
    uint256 public ethWithdrawn;

    constructor(BequestVault vault_, address owner_, address thief_, uint256 binding_, uint32 authWindow_) {
        vault = vault_;
        owner = owner_;
        thief = thief_;
        binding = binding_;
        authWindow = authWindow_;
    }

    function addBequest(BequestVault.Bequest memory b, bytes32[] memory proof) external {
        bequests.push(b);
        merkleProofs.push(proof);
    }

    function addLifeProof(BequestVault.Proof memory p, uint256 ts) external {
        lifeProofs.push(p);
        lifeTimes.push(ts);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 minutes, 120 days));
    }

    function heartbeat() external {
        vm.prank(owner);
        try vault.heartbeat() {} catch {}
    }

    function proveLife(uint256 k) external {
        k = bound(k, 0, lifeProofs.length - 1);
        try vault.proveLife(lifeProofs[k], binding, lifeTimes[k]) {} catch {}
    }

    function claim(uint256 k) external {
        k = bound(k, 0, bequests.length - 1);
        uint256 opensAfter = vault.claimableAt();
        try vault.claim(bequests[k], merkleProofs[k]) {
            if (block.timestamp <= opensAfter) earlyClaims++;
        } catch {}
    }

    function ownerWithdraw(uint256 amount) external {
        amount = bound(amount, 0, address(vault).balance);
        bool authorized = !vault.settled() && vault.lifeProven()
            && block.timestamp <= uint256(vault.lastLifeProof()) + authWindow;
        vm.prank(owner);
        try vault.withdraw(0, address(0), 0, amount, owner) {
            if (!authorized) unauthorizedActions++;
            ethWithdrawn += amount;
        } catch {}
    }

    function thiefActs(uint256 amount) external {
        vm.startPrank(thief);
        try vault.withdraw(0, address(0), 0, amount % 1 ether, thief) { unauthorizedActions++; } catch {}
        try vault.setAllocationRoot(bytes32(amount)) { unauthorizedActions++; } catch {}
        try vault.heartbeat() { unauthorizedActions++; } catch {}
        vm.stopPrank();
    }

    function sweep() external {
        try vault.sweep(0, address(0), 0) {} catch {}
    }
}

contract InvariantTest is BaseTest {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, owner, thief, binding, AUTH_WINDOW);
        uint256[7] memory plain = [ALICE_ETH, BOB_ETH, BOB_ETH_TRANCHE, ALICE_TOKEN, BOB_TOKEN, DAVE_NFT, BOB_MULTI];
        for (uint256 i; i < plain.length; i++) {
            (BequestVault.Bequest memory b, bytes32[] memory proof) = _bequest(plain[i]);
            handler.addBequest(b, proof);
        }
        string[3] memory keys = ["p10", "p200", "p400"];
        for (uint256 i; i < keys.length; i++) {
            (BequestVault.Proof memory p,, uint256 ts) = _lifeProof(keys[i]);
            handler.addLifeProof(p, ts);
        }
        targetContract(address(handler));
    }

    function invariant_NoClaimBeforeDeadlinePlusGrace() public view {
        assertEq(handler.earlyClaims(), 0);
    }

    function invariant_NoUnauthorizedOwnerActions() public view {
        assertEq(handler.unauthorizedActions(), 0);
    }

    /// Key-only heartbeats can never push the deadline past lastLifeProof + B.
    function invariant_DeadlineBoundedByLastProofOfLife() public view {
        assertLe(vault.deadline(), uint256(vault.lastLifeProof()) + B);
    }

    function invariant_EthConserved() public view {
        uint256 accounted = address(vault).balance + alice.balance + bob.balance + residuary.balance + owner.balance;
        assertEq(accounted, 10 ether);
        assertEq(owner.balance, handler.ethWithdrawn());
    }

    function invariant_TokensConserved() public view {
        uint256 accounted = token.balanceOf(address(vault)) + token.balanceOf(alice) + token.balanceOf(bob);
        assertEq(accounted, 1000 ether);
    }

    function invariant_PoolsNeverOverPaid() public view {
        assertLe(vault.paidBps(keccak256(abi.encode(uint8(0), address(0), uint256(0)))), 10_000);
        assertLe(vault.paidBps(keccak256(abi.encode(uint8(1), address(token), uint256(0)))), 10_000);
    }
}
