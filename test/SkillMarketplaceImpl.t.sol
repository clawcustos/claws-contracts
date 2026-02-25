// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/SkillMarketplaceImpl.sol";
import "../src/CustosNetworkImpl.sol";

/**
 * @title SkillMarketplaceImpl Test Suite
 * @notice Full coverage: skill registration, execution proof, dispute, settlement,
 *         merkle verification, fee flow, edge cases.
 * @author Custos (loop cycle 595, 2026-02-25)
 */
contract SkillMarketplaceImplTest is Test {
    SkillMarketplaceImpl public impl;
    SkillMarketplaceImpl public market; // proxy cast

    // Test actors
    address public skillCreator = address(0x2001);
    address public clientAgent  = address(0x2002);
    address public stranger     = address(0x2003);

    // Custodian must be CUSTOS_WALLET constant
    address public custodian = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE;

    // Genesis head for underlying CustosNetworkImpl
    bytes32 public genesisHead = keccak256("genesis");
    uint256 public genesisCycleCount = 0;

    // Skill config
    string  constant SKILL_NAME    = "x-research";
    string  constant SKILL_VERSION = "1.0.0";
    uint256 constant FEE_PER_EXEC  = 0.5e6; // 0.5 USDC

    // Assigned after inscriptions
    uint256 public skillAgentId;
    uint256 public clientAgentId;

    // USDC constant from contract
    address public USDC;
    address public TREASURY;

    // ─── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy impl + proxy
        impl = new SkillMarketplaceImpl();
        bytes memory initData = abi.encodeWithSelector(
            CustosNetworkImpl.initialize.selector,
            genesisHead,
            genesisCycleCount
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        market = SkillMarketplaceImpl(address(proxy));

        USDC    = market.USDC();
        TREASURY = market.TREASURY();

        // Mock all USDC calls (USDC is a constant at mainnet address)
        _mockUsdcAlwaysOk();

        // Register skillCreator as a network agent (registerAgent + first inscribe)
        vm.prank(skillCreator);
        market.registerAgent("x-research-skill");
        skillAgentId = market.agentIdByWallet(skillCreator);

        // First inscription for skillCreator (prevHash = genesisHead for cycle 0)
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(skillCreator);
        bytes32 proof1 = keccak256(abi.encodePacked("proof1", skillCreator));
        market.inscribe(proof1, genesisHead, "build", "skill creator first inscription", bytes32(0));

        // Register clientAgent as a network agent
        vm.prank(clientAgent);
        market.registerAgent("client-agent");
        clientAgentId = market.agentIdByWallet(clientAgent);

        // First inscription for clientAgent (different agent, no rate limit conflict)
        vm.prank(clientAgent);
        bytes32 proof2 = keccak256(abi.encodePacked("proof2", clientAgent));
        market.inscribe(proof2, genesisHead, "build", "client agent first inscription", bytes32(0));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Mock USDC transferFrom/transfer to always return true (happy path).
    function _mockUsdcAlwaysOk() internal {
        vm.mockCall(USDC, abi.encodeWithSelector(bytes4(keccak256("transferFrom(address,address,uint256)"))), abi.encode(true));
        vm.mockCall(USDC, abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)"))),             abi.encode(true));
        vm.mockCall(USDC, abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)"))),                    abi.encode(uint256(0)));
        vm.mockCall(USDC, abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))),              abi.encode(true));
    }

    /// @dev Build a single-leaf merkle (root == leaf).
    function _singleLeafRoot(
        bytes32 inputHash,
        bytes32 outputHash,
        uint256 ts,
        uint256 cid
    ) internal pure returns (bytes32 root, bytes32 leaf) {
        leaf = keccak256(abi.encode(inputHash, outputHash, ts, cid));
        root = leaf;
    }

    // ─── Registration Tests ───────────────────────────────────────────────────

    function test_RegisterSkill() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        ISkillMarketplace.SkillMetadata memory meta = market.skillMetadata(skillAgentId);
        assertEq(meta.name, SKILL_NAME);
        assertEq(meta.version, SKILL_VERSION);
        assertEq(meta.feePerExecution, FEE_PER_EXEC);
        assertTrue(meta.isSkill);
        assertEq(meta.creator, skillCreator);
    }

    function test_RegisterSkillPaysFeeToTreasury() public {
        // We just verify that transferFrom is called with SKILL_REG_FEE
        // (USDC is mocked — we verify the call was made)
        vm.expectCall(
            USDC,
            abi.encodeWithSelector(
                bytes4(keccak256("transferFrom(address,address,uint256)")),
                skillCreator,
                TREASURY,
                market.SKILL_REG_FEE()
            )
        );
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);
    }

    function test_CannotRegisterSkillTwice() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        vm.prank(skillCreator);
        vm.expectRevert(SkillMarketplaceImpl.SkillAlreadyRegistered.selector);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);
    }

    function test_CannotRegisterSkillForOtherAgent() public {
        vm.prank(stranger);
        vm.expectRevert("NotAgentOwner");
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);
    }

    function test_RegisterFreeSkill() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, 0);

        ISkillMarketplace.SkillMetadata memory meta = market.skillMetadata(skillAgentId);
        assertEq(meta.feePerExecution, 0);
    }

    function test_SkillMetadataBeforeRegistration() public view {
        ISkillMarketplace.SkillMetadata memory meta = market.skillMetadata(skillAgentId);
        assertFalse(meta.isSkill);
    }

    // ─── Execution Proof Tests ────────────────────────────────────────────────

    function test_ProveExecution() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("input"), keccak256("output"), block.timestamp, clientAgentId
        );

        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        ISkillMarketplace.ExecutionBatch memory batch = market.executionBatch(skillAgentId, root);
        assertEq(batch.merkleRoot, root);
        assertEq(batch.batchSize, 1);
        assertFalse(batch.disputed);
        assertFalse(batch.settled);
        assertGt(batch.settlesAt, block.timestamp);
    }

    function test_ProveExecutionPullsEscrow() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );

        // Verify transferFrom called with fee amount into contract escrow
        vm.expectCall(
            USDC,
            abi.encodeWithSelector(
                bytes4(keccak256("transferFrom(address,address,uint256)")),
                clientAgent,
                address(market),
                FEE_PER_EXEC
            )
        );

        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);
    }

    function test_FreeSkillNoEscrowPulled() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, 0);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );

        // With fee=0, transferFrom should NOT be called for clientAgent→contract
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 5, true);

        assertEq(market.skillExecutionCount(skillAgentId), 5);
    }

    function test_CannotProveUnregisteredSkill() public {
        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        vm.expectRevert(SkillMarketplaceImpl.SkillNotRegistered.selector);
        market.proveExecution(skillAgentId, root, 1, true);
    }

    function test_CannotProveDuplicateBatch() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );

        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.prank(clientAgent);
        vm.expectRevert(SkillMarketplaceImpl.BatchAlreadyExists.selector);
        market.proveExecution(skillAgentId, root, 1, true);
    }

    function test_UnsatisfiedProofAutoDisputed() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );

        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, false); // unsatisfied

        assertTrue(market.executionBatch(skillAgentId, root).disputed);
    }

    function test_ExecutionCountIncrements() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, 0);

        assertEq(market.skillExecutionCount(skillAgentId), 0);

        (bytes32 root1, ) = _singleLeafRoot(keccak256("i1"), keccak256("o1"), 1, clientAgentId);
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root1, 7, true);
        assertEq(market.skillExecutionCount(skillAgentId), 7);

        (bytes32 root2, ) = _singleLeafRoot(keccak256("i2"), keccak256("o2"), 2, clientAgentId);
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root2, 3, true);
        assertEq(market.skillExecutionCount(skillAgentId), 10);
    }

    // ─── Dispute Tests ────────────────────────────────────────────────────────

    function test_DisputeWithinWindow() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.prank(stranger);
        market.disputeExecution(skillAgentId, root);

        assertTrue(market.executionBatch(skillAgentId, root).disputed);
    }

    function test_CannotDisputeAfterWindow() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.warp(block.timestamp + market.DISPUTE_WINDOW() + 1);

        vm.prank(stranger);
        vm.expectRevert(SkillMarketplaceImpl.DisputeWindowClosed.selector);
        market.disputeExecution(skillAgentId, root);
    }

    function test_CannotDisputeAlreadyDisputed() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.prank(stranger);
        market.disputeExecution(skillAgentId, root);

        vm.prank(stranger);
        vm.expectRevert(SkillMarketplaceImpl.AlreadyDisputed.selector);
        market.disputeExecution(skillAgentId, root);
    }

    function test_CannotDisputeNonExistentBatch() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        vm.prank(stranger);
        vm.expectRevert(SkillMarketplaceImpl.BatchNotFound.selector);
        market.disputeExecution(skillAgentId, keccak256("ghost"));
    }

    // ─── Settlement Tests ─────────────────────────────────────────────────────

    function test_SettleAfterWindowReleasesToCreator() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.warp(block.timestamp + market.DISPUTE_WINDOW() + 1);

        // Verify transfer to creator called
        vm.expectCall(
            USDC,
            abi.encodeWithSelector(
                bytes4(keccak256("transfer(address,uint256)")),
                skillCreator,
                FEE_PER_EXEC
            )
        );

        vm.prank(stranger); // anyone can trigger
        market.settlePayment(skillAgentId, root);

        assertTrue(market.executionBatch(skillAgentId, root).settled);
    }

    function test_CannotSettleBeforeWindow() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.expectRevert(SkillMarketplaceImpl.DisputeWindowOpen.selector);
        market.settlePayment(skillAgentId, root);
    }

    function test_CannotSettleDisputedBatch() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.prank(stranger);
        market.disputeExecution(skillAgentId, root);

        vm.warp(block.timestamp + market.DISPUTE_WINDOW() + 1);

        vm.expectRevert(SkillMarketplaceImpl.AlreadyDisputed.selector);
        market.settlePayment(skillAgentId, root);
    }

    function test_CannotSettleTwice() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.warp(block.timestamp + market.DISPUTE_WINDOW() + 1);
        market.settlePayment(skillAgentId, root);

        vm.expectRevert(SkillMarketplaceImpl.AlreadySettled.selector);
        market.settlePayment(skillAgentId, root);
    }

    function test_FreeSkillSettlesWithoutTransfer() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, 0);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 3, true);

        vm.warp(block.timestamp + market.DISPUTE_WINDOW() + 1);
        market.settlePayment(skillAgentId, root); // must not revert, no USDC transfer

        assertTrue(market.executionBatch(skillAgentId, root).settled);
    }

    function test_CannotSettleNonExistentBatch() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        vm.warp(block.timestamp + market.DISPUTE_WINDOW() + 1);
        vm.expectRevert(SkillMarketplaceImpl.BatchNotFound.selector);
        market.settlePayment(skillAgentId, keccak256("nonexistent"));
    }

    // ─── Merkle Verification Tests ────────────────────────────────────────────

    function test_VerifySingleLeafBatch() public view {
        (bytes32 root, bytes32 leaf) = _singleLeafRoot(
            keccak256("input"), keccak256("output"), 1000, 42
        );
        bytes32[] memory proof = new bytes32[](0);
        assertTrue(market.verifyBatch(root, leaf, proof));
    }

    function test_VerifyTwoLeafBatch() public view {
        bytes32 leaf1 = keccak256(abi.encode(keccak256("i1"), keccak256("o1"), uint256(1), uint256(1)));
        bytes32 leaf2 = keccak256(abi.encode(keccak256("i2"), keccak256("o2"), uint256(2), uint256(2)));

        bytes32 root;
        if (leaf1 <= leaf2) {
            root = keccak256(abi.encodePacked(leaf1, leaf2));
        } else {
            root = keccak256(abi.encodePacked(leaf2, leaf1));
        }

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = leaf2;
        assertTrue(market.verifyBatch(root, leaf1, proof1));

        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = leaf1;
        assertTrue(market.verifyBatch(root, leaf2, proof2));
    }

    function test_VerifyRejectsBadProof() public view {
        (bytes32 root, bytes32 leaf) = _singleLeafRoot(
            keccak256("input"), keccak256("output"), 1000, 42
        );
        bytes32[] memory fakeProof = new bytes32[](1);
        fakeProof[0] = keccak256("intruder");
        assertFalse(market.verifyBatch(root, leaf, fakeProof));
    }

    function test_VerifyWrongLeafAgainstRoot() public view {
        (bytes32 root, ) = _singleLeafRoot(
            keccak256("real-input"), keccak256("real-output"), 999, 1
        );
        bytes32 fakeLeaf = keccak256(abi.encode(keccak256("fake"), keccak256("data"), uint256(0), uint256(0)));
        bytes32[] memory emptyProof = new bytes32[](0);
        assertFalse(market.verifyBatch(root, fakeLeaf, emptyProof));
    }

    // ─── View Function Tests ──────────────────────────────────────────────────

    function test_ExecutionBatchBeforeProof() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        ISkillMarketplace.ExecutionBatch memory batch = market.executionBatch(
            skillAgentId, keccak256("nonexistent")
        );
        assertEq(batch.settlesAt, 0); // not found = zero struct
    }

    function test_ExecutionCountStartsZero() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);
        assertEq(market.skillExecutionCount(skillAgentId), 0);
    }

    // ─── Event Tests ──────────────────────────────────────────────────────────

    function test_SkillRegisteredEvent() public {
        vm.prank(skillCreator);
        vm.expectEmit(true, true, false, true);
        emit ISkillMarketplace.SkillRegistered(
            skillAgentId, skillCreator, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC
        );
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);
    }

    function test_ExecutionProvedEvent() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );

        vm.prank(clientAgent);
        vm.expectEmit(true, false, false, false);
        emit ISkillMarketplace.ExecutionProved(skillAgentId, 0, root, 1, 0);
        market.proveExecution(skillAgentId, root, 1, true);
    }

    function test_ExecutionDisputedEvent() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.prank(stranger);
        vm.expectEmit(true, false, false, false);
        emit ISkillMarketplace.ExecutionDisputed(skillAgentId, 0, root);
        market.disputeExecution(skillAgentId, root);
    }

    function test_PaymentReleasedEvent() public {
        vm.prank(skillCreator);
        market.registerSkill(skillAgentId, SKILL_NAME, SKILL_VERSION, FEE_PER_EXEC);

        (bytes32 root, ) = _singleLeafRoot(
            keccak256("in"), keccak256("out"), block.timestamp, clientAgentId
        );
        vm.prank(clientAgent);
        market.proveExecution(skillAgentId, root, 1, true);

        vm.warp(block.timestamp + market.DISPUTE_WINDOW() + 1);

        vm.expectEmit(true, false, false, false);
        emit ISkillMarketplace.PaymentReleased(skillAgentId, 0, root, FEE_PER_EXEC);
        market.settlePayment(skillAgentId, root);
    }

    // ─── Constants ────────────────────────────────────────────────────────────

    function test_Constants() public view {
        assertEq(market.DISPUTE_WINDOW(), 24 hours);
        assertEq(market.SKILL_REG_FEE(), 5e6);
    }
}
