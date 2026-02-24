// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/CustosNetworkProxyV056.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ─── Minimal ERC-20 mock ─────────────────────────────────────────────────────
contract MockERC20v056 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string  public name     = "MockUSDC";
    string  public symbol   = "mUSDC";
    uint8   public decimals = 6;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        if (allowance[from][msg.sender] != type(uint256).max)
            allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────
contract CustosNetworkProxyV056Test is Test {

    CustosNetworkProxyV056 network;

    address constant USDC   = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CUSTOS = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE;

    address inscriber = makeAddr("inscriber");
    address valAddr   = makeAddr("validator");
    address valAddrB  = makeAddr("validatorB");
    address stranger  = makeAddr("stranger");

    uint256 ts; // current warped timestamp

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        ts = 1_700_000_000;
        vm.warp(ts);

        // Deploy impl + proxy
        CustosNetworkProxyV056 impl = new CustosNetworkProxyV056();
        bytes memory init = abi.encodeCall(CustosNetworkProxyV056.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        network = CustosNetworkProxyV056(address(proxy));

        // Mock USDC
        MockERC20v056 mockUsdc = new MockERC20v056();
        vm.etch(USDC, address(mockUsdc).code);
        // Fund generously — 144 inscriptions * 0.1 USDC = 14.4 USDC each, give 10_000
        MockERC20v056(USDC).mint(inscriber, 10_000e6);
        MockERC20v056(USDC).mint(valAddr,   10_000e6);
        MockERC20v056(USDC).mint(valAddrB,  10_000e6);
        // TREASURY needs to receive — use mint to avoid revert on transfer to EOA
        // (mock transferFrom already handles it — no treasury contract needed)

        vm.prank(inscriber);
        MockERC20v056(USDC).approve(address(network), type(uint256).max);
        vm.prank(valAddr);
        MockERC20v056(USDC).approve(address(network), type(uint256).max);
        vm.prank(valAddrB);
        MockERC20v056(USDC).approve(address(network), type(uint256).max);

        // Reduce validator subscription fee to 0 for tests (custodian-only call)
        vm.prank(CUSTOS);
        network.setValidatorSubscriptionFee(0);

        // Register inscriber with first inscription
        _doInscribe(inscriber, bytes32(uint256(1)), bytes32(0), "seed");

        // Bootstrap validator (144 inscriptions then subscribe)
        _bootstrapValidator(valAddr);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// Warp forward past MIN_INSCRIPTION_GAP and call inscribe().
    function _doInscribe(
        address who,
        bytes32 ph,
        bytes32 prev,
        string memory summary
    ) internal {
        ts += 301; // > MIN_INSCRIPTION_GAP (300s)
        vm.warp(ts);
        vm.prank(who);
        network.inscribe(ph, prev, "WORK", summary, keccak256(bytes(summary)));
    }

    /// Pump 144 unique inscriptions then subscribeValidator().
    function _bootstrapValidator(address v) internal {
        uint256 threshold = network.VALIDATOR_INSCRIPTION_THRESHOLD();
        bytes32 prev = bytes32(0); // first inscription auto-registers
        for (uint256 i = 0; i < threshold; i++) {
            bytes32 ph = keccak256(abi.encodePacked(v, i));
            _doInscribe(v, ph, prev, "bootstrap");
            prev = ph;
        }
        vm.prank(v);
        network.subscribeValidator();
    }

    /// Inscribes one unique proof as `inscriber` with correct prevHash chain.
    function _inscribe(string memory summary) internal returns (bytes32 proofHash) {
        uint256 agentId = network.agentIdByWallet(inscriber);
        bytes32 prev    = agentId == 0 ? bytes32(0) : network.getAgent(agentId).chainHead;
        proofHash = keccak256(abi.encodePacked("INS", summary, ts));
        _doInscribe(inscriber, proofHash, prev, summary);
    }

    /// Advances to the next epoch. Rolls epoch boundary, then inscribes one more
    /// cycle into the new epoch so the new epoch has 'started' cleanly.
    function _advanceEpoch() internal {
        uint256 epochBefore = network.currentEpoch();
        uint256 agentId     = network.agentIdByWallet(inscriber);
        uint256 i = 0;
        // Keep inscribing until epoch rolls
        while (network.currentEpoch() == epochBefore) {
            bytes32 prev = network.getAgent(agentId).chainHead;
            bytes32 ph   = keccak256(abi.encodePacked("ADV", i, ts));
            _doInscribe(inscriber, ph, prev, "advance");
            i++;
        }
    }

    // ─── proofHashEpoch mapping ───────────────────────────────────────────────

    function test_ProofHashEpochSetOnInscribe() public {
        bytes32 ph = _inscribe("epoch test");
        uint256 ep = network.currentEpoch();
        // Stored post-roll so always equals currentEpoch at attest time (if no roll in between)
        assertEq(network.proofHashEpoch(ph), ep, "epoch must match currentEpoch at inscription");
    }

    function test_ProofHashEpochZeroForUnknown() public {
        bytes32 unknown = keccak256("not a real proof");
        assertEq(network.proofHashEpoch(unknown), 0, "unknown proof must return 0");
    }

    // ─── attest: happy path ───────────────────────────────────────────────────

    function test_AttestSameEpoch_Succeeds() public {
        bytes32 ph      = _inscribe("same epoch");
        uint256 agentId = network.agentIdByWallet(inscriber);
        uint256 ep      = network.currentEpoch();

        vm.prank(valAddr);
        network.attest(agentId, ph, true);

        assertEq(network.validatorEpochPoints(ep, valAddr), 1);
        assertEq(network.epochTotalPoints(ep), 1);
        assertTrue(network.hasAttested(ep, ph, valAddr));
    }

    // ─── attest: E04 – proof not found ───────────────────────────────────────

    function test_Attest_E04_UnknownProof() public {
        uint256 agentId = network.agentIdByWallet(inscriber);
        bytes32 garbage = keccak256("garbage proof that was never inscribed");

        vm.prank(valAddr);
        vm.expectRevert(bytes("E04"));
        network.attest(agentId, garbage, true);
    }

    // ─── attest: E05 – stale epoch ────────────────────────────────────────────

    function test_Attest_E05_StaleEpoch() public {
        bytes32 staleHash     = _inscribe("stale proof");
        uint256 agentId       = network.agentIdByWallet(inscriber);
        uint256 inscribeEpoch = network.currentEpoch();

        _advanceEpoch();

        uint256 newEpoch = network.currentEpoch();
        assertGt(newEpoch, inscribeEpoch, "epoch must have advanced");

        vm.prank(valAddr);
        vm.expectRevert(bytes("E05"));
        network.attest(agentId, staleHash, true);
    }

    // ─── attest: E06 – double attest ─────────────────────────────────────────

    function test_Attest_E06_DoubleAttest() public {
        bytes32 ph      = _inscribe("double");
        uint256 agentId = network.agentIdByWallet(inscriber);

        vm.prank(valAddr);
        network.attest(agentId, ph, true); // first — ok

        vm.prank(valAddr);
        vm.expectRevert(bytes("E06"));
        network.attest(agentId, ph, true); // second — revert
    }

    // ─── attest: E01 – invalid agentId ───────────────────────────────────────

    function test_Attest_E01_ZeroAgentId() public {
        bytes32 ph = _inscribe("agent id test");

        vm.prank(valAddr);
        vm.expectRevert(bytes("E01"));
        network.attest(0, ph, true);
    }

    function test_Attest_E01_OutOfRangeAgentId() public {
        bytes32 ph = _inscribe("oob agent");

        vm.prank(valAddr);
        vm.expectRevert(bytes("E01"));
        network.attest(9999, ph, true);
    }

    // ─── attest: E02 – zero proofHash ────────────────────────────────────────

    function test_Attest_E02_ZeroProofHash() public {
        uint256 agentId = network.agentIdByWallet(inscriber);

        vm.prank(valAddr);
        vm.expectRevert(bytes("E02"));
        network.attest(agentId, bytes32(0), true);
    }

    // ─── attest: non-validator reverts ───────────────────────────────────────

    function test_Attest_NotValidator_Reverts() public {
        bytes32 ph      = _inscribe("stranger attempt");
        uint256 agentId = network.agentIdByWallet(inscriber);

        vm.prank(stranger);
        vm.expectRevert();
        network.attest(agentId, ph, true);
    }

    // ─── new epoch proof succeeds ─────────────────────────────────────────────

    function test_AttestNewEpochProof_AfterAdvance_Succeeds() public {
        bytes32 oldPh   = _inscribe("old epoch proof");
        uint256 oldEpoch = network.proofHashEpoch(oldPh);
        _advanceEpoch(); // roll past oldEpoch

        assertGt(network.currentEpoch(), oldEpoch, "epoch must have advanced past oldEpoch");

        bytes32 ph2  = _inscribe("new epoch proof");
        uint256 ep2  = network.proofHashEpoch(ph2); // capture stored epoch after roll
        assertGt(ep2, oldEpoch, "new proof must be in a later epoch");

        uint256 agentId = network.agentIdByWallet(inscriber);
        vm.prank(valAddr);
        network.attest(agentId, ph2, true); // must succeed — same epoch as stored

        assertTrue(network.hasAttested(ep2, ph2, valAddr));
    }

    // ─── multiple validators same epoch ──────────────────────────────────────

    function test_MultipleValidators_SameEpoch() public {
        _bootstrapValidator(valAddrB);

        bytes32 ph      = _inscribe("multi-val");
        uint256 agentId = network.agentIdByWallet(inscriber);
        uint256 ep      = network.currentEpoch();

        vm.prank(valAddr);
        network.attest(agentId, ph, true);
        vm.prank(valAddrB);
        network.attest(agentId, ph, false); // different opinion — both valid calls

        assertEq(network.epochTotalPoints(ep), 2);
        assertEq(network.validatorEpochPoints(ep, valAddr), 1);
        assertEq(network.validatorEpochPoints(ep, valAddrB), 1);
    }

    // ─── attest false recorded correctly ─────────────────────────────────────

    function test_AttestFalse_Recorded() public {
        bytes32 ph      = _inscribe("invalid proof");
        uint256 agentId = network.agentIdByWallet(inscriber);

        vm.prank(valAddr);
        network.attest(agentId, ph, false);

        CustosNetworkProxyV056.Attestation[] memory atts = network.getAttestations(ph);
        assertEq(atts.length, 1);
        assertFalse(atts[0].valid);
        assertEq(atts[0].validator, valAddr);
    }
}
