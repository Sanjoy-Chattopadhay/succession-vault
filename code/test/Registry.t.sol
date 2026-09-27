// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivenessRegistry} from "../src/LivenessRegistry.sol";
import {ILivenessRegistry, Groth16Proof} from "../src/interfaces/ILivenessRegistry.sol";
import {BequestVault} from "../src/BequestVault.sol";
import {BequestFactory} from "../src/BequestFactory.sol";
import {IGroth16Verifier} from "../src/interfaces/IGroth16Verifier.sol";
import {LivenessVerifier} from "../src/verifiers/LivenessVerifier.sol";
import {AgeVerifier} from "../src/verifiers/AgeVerifier.sol";

/// @dev Fixtures come from `node js/gen-batch-fixtures.mjs`, which needs scripts/batch-setup.sh
///      to have built the aggregation circuits first.
abstract contract RegistryBase is Test {
    uint256 internal constant T0 = 1_900_000_000;
    uint256 internal constant DAY = 86_400;
    uint32 internal constant I = 30 days;
    // lifeProof + grace must fit inside the registry span: LOOKBACK epochs of at least MIN_EPOCH
    // each, i.e. 64 days here (the fixtures' epochs last exactly one day).
    uint32 internal constant B = 30 days;
    uint32 internal constant G = 30 days;
    uint32 internal constant W = 3650 days;
    uint32 internal constant MIN_PERIOD = 1 hours;
    uint32 internal constant AUTH_WINDOW = 1 days;
    uint32 internal constant LOOKBACK = 64;
    uint64 internal constant MIN_EPOCH = 1 days;

    string internal json;
    string internal cohort; // e.g. ".cohorts.agg_N8_m40_w1"

    LivenessRegistry internal registry;
    BequestFactory internal factory;
    BequestVault internal impl;
    uint256 internal n;
    uint256 internal words;

    function _setUpCohort(string memory name) internal {
        json = vm.readFile("test/fixtures/registry.json");
        cohort = string.concat(".cohorts.", name);
        n = vm.parseJsonUint(json, string.concat(cohort, ".n"));
        words = vm.parseJsonUint(json, string.concat(cohort, ".words"));

        vm.warp(T0);
        address epochVerifier = deployCode(string.concat("src/verifiers/", name2verifier(name), ".sol:", name2verifier(name)));
        address enrollVerifier = deployCode("src/verifiers/EnrollVerifier.sol:EnrollVerifier");
        registry = new LivenessRegistry(
            enrollVerifier,
            epochVerifier,
            words,
            n,
            64,
            vm.parseJsonUint(json, ".emptyRoot"),
            address(this), // the aggregator: every epoch in these tests is submitted by the test
            MIN_EPOCH
        );
        impl = new BequestVault(
            IGroth16Verifier(address(new LivenessVerifier())),
            IGroth16Verifier(address(new AgeVerifier())),
            MIN_PERIOD,
            AUTH_WINDOW,
            ILivenessRegistry(address(registry)),
            LOOKBACK
        );
        factory = new BequestFactory(address(impl));
    }

    /// agg_N8_m40_w1 -> AggVerifier_N8_m40_w1
    function name2verifier(string memory name) internal pure returns (string memory) {
        bytes memory b = bytes(name);
        bytes memory tail = new bytes(b.length - 3); // strip "agg"
        for (uint256 i = 3; i < b.length; ++i) tail[i - 3] = b[i];
        return string.concat("AggVerifier", string(tail));
    }

    // ------------------------------------------------------------- fixture readers

    function _u2(string memory j, string memory p) internal pure returns (uint256[2] memory r) {
        uint256[] memory a = vm.parseJsonUintArray(j, p);
        r[0] = a[0];
        r[1] = a[1];
    }

    function _proof(string memory key) internal view returns (Groth16Proof memory p) {
        p.a = _u2(json, string.concat(key, ".a"));
        p.b[0] = _u2(json, string.concat(key, ".b[0]"));
        p.b[1] = _u2(json, string.concat(key, ".b[1]"));
        p.c = _u2(json, string.concat(key, ".c"));
    }

    function _enrollment(uint256 i)
        internal
        view
        returns (Groth16Proof memory p, uint256 newRoot, uint256 binding)
    {
        string memory k = string.concat(cohort, ".enrollments[", vm.toString(i), "]");
        p = _proof(k);
        newRoot = vm.parseJsonUint(json, string.concat(k, ".newRoot"));
        binding = vm.parseJsonUint(json, string.concat(k, ".binding"));
    }

    function _epoch(string memory which)
        internal
        view
        returns (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w)
    {
        string memory k = string.concat(cohort, ".", which);
        p = _proof(k);
        start = uint64(vm.parseJsonUint(json, string.concat(k, ".start")));
        end = uint64(vm.parseJsonUint(json, string.concat(k, ".end")));
        w = vm.parseJsonUintArray(json, string.concat(k, ".words"));
    }

    function _binding(uint256 i) internal view returns (uint256) {
        return vm.parseJsonUint(json, string.concat(cohort, ".bindings[", vm.toString(i), "]"));
    }

    /// @dev Vault i owns slot i, so the enrollment proofs (which fix the slot) line up.
    function _vaults() internal returns (BequestVault[] memory vs, address[] memory owners) {
        vs = new BequestVault[](n);
        owners = new address[](n);
        for (uint256 i; i < n; ++i) {
            owners[i] = makeAddr(string.concat("owner", vm.toString(i)));
            vm.prank(owners[i]);
            vs[i] = BequestVault(payable(factory.createVault(
                BequestVault.Config({
                    heartbeatInterval: I,
                    lifeProofInterval: B,
                    gracePeriod: G,
                    claimWindow: W,
                    allocationRoot: bytes32(uint256(1)),
                    residuary: makeAddr("residuary"),
                    livenessBinding: _binding(i)
                }),
                bytes32(0)
            )));
        }
    }

    function _enrollAll(BequestVault[] memory vs, address[] memory owners) internal {
        for (uint256 i; i < n; ++i) {
            (Groth16Proof memory p, uint256 newRoot, uint256 binding) = _enrollment(i);
            vm.prank(owners[i]);
            vs[i].enrollInRegistry(p, newRoot, binding);
        }
    }

    function _submit(string memory which) internal returns (uint256 epochId) {
        (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w) = _epoch(which);
        vm.warp(uint256(end) + 60);
        epochId = registry.submitEpoch(p, start, end, w);
    }
}

contract RegistryTest is RegistryBase {
    BequestVault[] internal vaults;
    address[] internal owners;

    function setUp() public {
        _setUpCohort("agg_N8_m40_w1");
        (BequestVault[] memory vs, address[] memory os) = _vaults();
        for (uint256 i; i < n; ++i) {
            vaults.push(vs[i]);
            owners.push(os[i]);
        }
    }

    // ---------------------------------------------------------------- enrollment

    function test_EnrollAssignsSequentialSlots() public {
        _enrollAll(vaults, owners);
        assertEq(registry.nextSlot(), n);
        for (uint256 i; i < n; ++i) {
            (bool enrolled, uint256 slot) = registry.slotOf(address(vaults[i]));
            assertTrue(enrolled);
            assertEq(slot, i);
            assertEq(registry.bindingAt(i), _binding(i));
        }
        assertEq(registry.enrollRoot(), vm.parseJsonUint(json, string.concat(cohort, ".enrollRoot")));
    }

    function test_EnrollRejectsForgedRoot() public {
        (Groth16Proof memory p, uint256 newRoot, uint256 binding) = _enrollment(0);
        vm.prank(owners[0]);
        vm.expectRevert(LivenessRegistry.InvalidProof.selector);
        vaults[0].enrollInRegistry(p, newRoot + 1, binding);
    }

    function test_EnrollRejectsUnregisteredBinding() public {
        (Groth16Proof memory p, uint256 newRoot,) = _enrollment(0);
        vm.prank(owners[0]);
        vm.expectRevert(BequestVault.UnknownBinding.selector);
        vaults[0].enrollInRegistry(p, newRoot, 12345);
    }

    function test_EnrollOnlyOncePerPrincipal() public {
        _enrollAll(vaults, owners);
        (Groth16Proof memory p, uint256 newRoot, uint256 binding) = _enrollment(0);
        vm.prank(owners[0]);
        vm.expectRevert(LivenessRegistry.SlotTaken.selector);
        vaults[0].enrollInRegistry(p, newRoot, binding);
    }

    function test_EnrollNotByNonOwner() public {
        (Groth16Proof memory p, uint256 newRoot, uint256 binding) = _enrollment(0);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(BequestVault.NotOwner.selector);
        vaults[0].enrollInRegistry(p, newRoot, binding);
    }

    // ---------------------------------------------------------------- epochs

    function test_SubmitEpochRecordsEveryone() public {
        _enrollAll(vaults, owners);
        uint256 id = _submit("epoch");
        assertEq(id, 0);
        assertEq(registry.epochCount(), 1);
        for (uint256 i; i < n; ++i) assertTrue(registry.isPresent(0, i));
    }

    function test_EpochRejectsForgedBitmap() public {
        _enrollAll(vaults, owners);
        (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w) = _epoch("epoch");
        w[0] = w[0] | (1 << 200); // claim a principal the proof never covered
        vm.warp(uint256(end) + 60);
        vm.expectRevert(LivenessRegistry.InvalidProof.selector);
        registry.submitEpoch(p, start, end, w);
    }

    function test_EpochRejectsOverlappingEpochs() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w) = _epoch("epoch");
        vm.warp(uint256(end) + 120);
        vm.expectRevert(LivenessRegistry.BadEpoch.selector);
        registry.submitEpoch(p, start, end, w); // same window: a credential would count twice
    }

    function test_EpochRejectsFutureEnd() public {
        _enrollAll(vaults, owners);
        (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w) = _epoch("epoch");
        vm.warp(uint256(end) - 1 hours);
        vm.expectRevert(LivenessRegistry.BadEpoch.selector);
        registry.submitEpoch(p, start, end, w);
    }

    function test_EpochRejectsWrongWordCount() public {
        _enrollAll(vaults, owners);
        (Groth16Proof memory p, uint64 start, uint64 end,) = _epoch("epoch");
        vm.warp(uint256(end) + 60);
        vm.expectRevert(LivenessRegistry.BadWordCount.selector);
        registry.submitEpoch(p, start, end, new uint256[](words + 1));
    }

    // ---------------------------------------------------------------- presence

    function test_PresenceReportsEpochStart() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        (, uint64 start,,) = _epoch("epoch");
        (uint256 binding, uint64 since) = registry.presenceOf(address(vaults[0]), LOOKBACK);
        assertEq(binding, _binding(0));
        assertEq(since, start);
    }

    function test_SilentPrincipalKeepsOnlyTheOlderEpoch() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        _submit("partialEpoch");
        (, uint64 first,,) = _epoch("epoch");
        (, uint64 second,,) = _epoch("partialEpoch");
        uint256 silent = vm.parseJsonUint(json, string.concat(cohort, ".partialEpoch.silentSlot"));

        (, uint64 present) = registry.presenceOf(address(vaults[0]), LOOKBACK);
        assertEq(present, second, "attending principal advances to the newer epoch");
        (, uint64 stale) = registry.presenceOf(address(vaults[silent]), LOOKBACK);
        assertEq(stale, first, "silent principal stays at the epoch it last attended");
        assertFalse(registry.isPresent(1, silent));
    }

    function test_PresenceOfStranger() public {
        (uint256 binding, uint64 since) = registry.presenceOf(makeAddr("nobody"), LOOKBACK);
        assertEq(binding, 0);
        assertEq(since, 0);
    }

    // ---------------------------------------------------------------- vault integration

    /// The point of the whole construction: the cohort stays alive without any of its members
    /// sending a transaction.
    function test_EpochExtendsEveryVaultDeadlineWithNoVaultTransaction() public {
        _enrollAll(vaults, owners);
        uint256 before_ = vaults[0].deadline();
        _submit("epoch");
        (, uint64 start,,) = _epoch("epoch");

        // An epoch refreshes both clocks, so the deadline is the tighter of the two intervals.
        for (uint256 i; i < n; ++i) {
            assertEq(vaults[i].deadline(), uint256(start) + I, "deadline follows the epoch");
            (bool proven, uint40 at) = vaults[i].presence();
            assertTrue(proven);
            assertEq(at, start);
        }
        assertGt(vaults[0].deadline(), before_);
    }

    function test_EpochAuthorizesOwnerActions() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        (, uint64 start,,) = _epoch("epoch");
        vm.deal(address(vaults[0]), 1 ether);

        vm.warp(uint256(start) + 1 hours);
        vm.prank(owners[0]);
        vaults[0].withdraw(0, address(0), 0, 0.5 ether, owners[0]);
        assertEq(owners[0].balance, 0.5 ether);
    }

    function test_OwnerActionsExpireAfterAuthWindow() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        (, uint64 start,,) = _epoch("epoch");
        vm.deal(address(vaults[0]), 1 ether);

        vm.warp(uint256(start) + AUTH_WINDOW + 1);
        vm.prank(owners[0]);
        vm.expectRevert(BequestVault.ProofOfLifeRequired.selector);
        vaults[0].withdraw(0, address(0), 0, 0.5 ether, owners[0]);
    }

    /// A registry cannot lend one principal's attestation to another: the vault only accepts the
    /// binding it registered itself.
    function test_VaultIgnoresPresenceForAForeignBinding() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        (, uint64 start,,) = _epoch("epoch");
        vm.warp(uint256(start) + 1 hours); // inside the authorization window
        vm.prank(owners[0]);
        vaults[0].setBinding(_binding(0), false); // vault no longer recognises its own slot
        assertEq(vaults[0].registryLifeProof(), 0);
        (bool proven,) = vaults[0].presence();
        assertFalse(proven);
    }

    /// Censorship is an availability cost, not a safety failure: the omitted principal keeps the
    /// single-principal path and the grace period outlasts the epoch.
    function test_CensoredPrincipalStillHasTheDirectPath() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        _submit("partialEpoch");
        uint256 silent = vm.parseJsonUint(json, string.concat(cohort, ".partialEpoch.silentSlot"));
        (, uint64 first,,) = _epoch("epoch");

        // The vault is still alive: one epoch of silence costs nothing, because the heartbeat
        // interval is far longer than an epoch. Censorship buys the aggregator delay, not control.
        assertEq(vaults[silent].deadline(), uint256(first) + I);
        assertGt(vaults[silent].deadline(), block.timestamp);
    }

    function test_SyncFromRegistryCachesPresence() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        (, uint64 start,,) = _epoch("epoch");
        vaults[0].syncFromRegistry();
        assertEq(vaults[0].lastLifeProof(), start);
        assertTrue(vaults[0].lifeProven());
        vm.expectRevert(BequestVault.StaleOrFutureProof.selector);
        vaults[0].syncFromRegistry();
    }

    // ---------------------------------------------------------------- who may write epochs, and how fast

    function test_OnlyTheAggregatorSubmitsEpochs() public {
        _enrollAll(vaults, owners);
        (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w) = _epoch("epoch");
        vm.warp(uint256(end) + 60);
        vm.prank(makeAddr("stranger")); // e.g. an heir who would like the vault to look abandoned
        vm.expectRevert(LivenessRegistry.NotAggregator.selector);
        registry.submitEpoch(p, start, end, w);
    }

    function test_EpochShorterThanTheMinimumIsRejected() public {
        _enrollAll(vaults, owners);
        (Groth16Proof memory p, uint64 start, uint64 end, uint256[] memory w) = _epoch("epoch");
        vm.warp(uint256(end) + 60);
        vm.expectRevert(LivenessRegistry.BadEpoch.selector);
        registry.submitEpoch(p, start + 1, end, w); // one second short of MIN_EPOCH
    }

    /// The attack the two rules above close. An empty bitmap needs no credential (every per-slot
    /// check in circuits/lib/batch.circom is gated by its presence bit), so the verifier is mocked
    /// here only to avoid generating those proofs. Even the aggregator, submitting the shortest
    /// epochs the registry accepts back to back, pushes the presence out of the lookback only
    /// after it has stopped mattering: by then the vault is claimable on that presence anyway.
    function test_EmptyEpochsCannotHideAPresenceThatStillMatters() public {
        _enrollAll(vaults, owners);
        _submit("epoch");
        (, uint64 sigma,,) = _epoch("epoch");
        uint256 horizon = uint256(sigma) + B + G; // until then the presence keeps vault 0 alive

        vm.mockCall(registry.EPOCH_VERIFIER(), bytes(""), abi.encode(true));
        uint256[] memory none = new uint256[](words);
        Groth16Proof memory p;
        uint64 last = registry.epochAt(registry.epochCount() - 1).end;
        bool hidden;
        for (uint256 k; k < LOOKBACK + 2; ++k) {
            uint64 s = last + 1;
            uint64 e = s + MIN_EPOCH;
            vm.warp(uint256(e) - registry.MAX_CLOCK_SKEW()); // as early as the registry allows
            registry.submitEpoch(p, s, e, none);
            last = e;
            bool visible = vaults[0].registryLifeProof() == sigma;
            if (block.timestamp <= horizon) {
                assertTrue(visible, "presence hidden while it still keeps the vault alive");
                assertTrue(vaults[0].status() != BequestVault.Status.Claimable, "claimable too early");
            }
            if (!visible) hidden = true;
        }
        assertTrue(hidden, "the flood does push the presence out of the lookback eventually");
        assertGt(block.timestamp, horizon);
        assertEq(uint256(vaults[0].status()), uint256(BequestVault.Status.Claimable));
    }

    /// The timer rule behind the test above: lifeProof + grace + clock skew must stay below
    /// LOOKBACK * MIN_EPOCH (64 days here), at creation and on every later change.
    function test_VaultRejectsTimersBeyondTheRegistrySpan() public {
        BequestVault.Config memory cfg = BequestVault.Config({
            heartbeatInterval: I,
            lifeProofInterval: 60 days,
            gracePeriod: 4 days, // 64 days plus skew: one epoch too many
            claimWindow: W,
            allocationRoot: bytes32(uint256(1)),
            residuary: makeAddr("residuary"),
            livenessBinding: _binding(0)
        });
        vm.prank(owners[0]);
        vm.expectRevert(BequestVault.InvalidConfig.selector);
        factory.createVault(cfg, bytes32(uint256(7)));

        _enrollAll(vaults, owners);
        _submit("epoch");
        (, uint64 start,,) = _epoch("epoch");
        vm.warp(uint256(start) + 1 hours); // inside the authorization window, so only the rule bites
        vm.prank(owners[0]);
        vm.expectRevert(BequestVault.InvalidConfig.selector);
        vaults[0].setTimers(I, 60 days, 4 days, W);
        vm.prank(owners[0]);
        vaults[0].setTimers(I, 60 days, 3 days, W); // 63 days plus skew fits
    }

    function test_VaultWithoutRegistryIsUnaffected() public {
        BequestVault plain = new BequestVault(
            IGroth16Verifier(address(new LivenessVerifier())),
            IGroth16Verifier(address(new AgeVerifier())),
            MIN_PERIOD,
            AUTH_WINDOW,
            ILivenessRegistry(address(0)),
            0
        );
        assertEq(plain.registryLifeProof(), 0);
    }
}
