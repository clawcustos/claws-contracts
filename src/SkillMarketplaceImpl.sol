// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CustosNetworkImpl.sol";
import "../contracts/interfaces/ISkillMarketplace.sol";

/**
 * @title SkillMarketplaceImpl
 * @notice CustosNetwork Skill Marketplace — V5.6 extension
 *         Skills are agents with metadata + execution proof + payment settlement.
 *         Payment settles on proof-of-execution, not promise.
 *
 * @dev Extends CustosNetworkImpl via UUPS upgrade. Skills must first register
 *      as agents via inscribe(), then call registerSkill() to attach metadata.
 *      Execution proofs use merkle batching (flat gas regardless of batch size).
 *      24-hour dispute window before USDC auto-releases to skill creator.
 *
 * @author Custos (loop cycle 438, 2026-02-23)
 *
 * Spec: memory/skill-marketplace-spec-2026-02-23.md (v2)
 * Interface: contracts/interfaces/ISkillMarketplace.sol
 *
 * PENDING PIZZA APPROVAL — do not deploy until approved.
 */
contract SkillMarketplaceImpl is CustosNetworkImpl, ISkillMarketplace {

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant DISPUTE_WINDOW    = 24 hours;
    uint256 public constant SKILL_REG_FEE     = 5e6;   // 5 USDC — anti-sybil for skills

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @notice Skill metadata by agentId
    mapping(uint256 => SkillMetadata) private _skillMetadata;

    /// @notice Execution batches: skillAgentId → merkleRoot → ExecutionBatch
    mapping(uint256 => mapping(bytes32 => ExecutionBatch)) private _batches;

    /// @notice USDC held in escrow per batch: skillAgentId → merkleRoot → amount
    mapping(uint256 => mapping(bytes32 => uint256)) private _escrow;

    /// @notice Total attested execution count per skill
    mapping(uint256 => uint256) private _executionCount;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotAgentOwner();
    error SkillAlreadyRegistered();
    error SkillNotRegistered();
    error BatchAlreadyExists();
    error BatchNotFound();
    error DisputeWindowOpen();
    error DisputeWindowClosed();
    error AlreadyDisputed();
    error AlreadySettled();
    error InsufficientAllowance();
    error TransferFailed();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyAgentOwner(uint256 agentId) {
        // Agent must be registered and caller must be the registered wallet
        require(agentWallet[agentId] == msg.sender, "NotAgentOwner");
        _;
    }

    modifier skillExists(uint256 skillAgentId) {
        if (!_skillMetadata[skillAgentId].isSkill) revert SkillNotRegistered();
        _;
    }

    // ─── Registration ────────────────────────────────────────────────────────

    /// @inheritdoc ISkillMarketplace
    function registerSkill(
        uint256 skillAgentId,
        string calldata name,
        string calldata version,
        uint256 feePerExecution
    ) external override onlyAgentOwner(skillAgentId) {
        if (_skillMetadata[skillAgentId].isSkill) revert SkillAlreadyRegistered();

        // Collect skill registration fee
        bool ok = IERC20(USDC).transferFrom(msg.sender, treasury, SKILL_REG_FEE);
        if (!ok) revert TransferFailed();

        _skillMetadata[skillAgentId] = SkillMetadata({
            name:            name,
            version:         version,
            feePerExecution: feePerExecution,
            isSkill:         true,
            creator:         msg.sender,
            registeredAt:    block.timestamp
        });

        emit SkillRegistered(skillAgentId, msg.sender, name, version, feePerExecution);
    }

    // ─── Execution Proof ─────────────────────────────────────────────────────

    /// @inheritdoc ISkillMarketplace
    /// @dev Client must pre-approve USDC (feePerExecution) before calling.
    ///      merkleRoot = keccak256 merkle root of all execution leaf hashes in batch.
    ///      Each leaf: keccak256(abi.encode(inputHash, outputHash, timestamp, clientAgentId))
    function proveExecution(
        uint256 skillAgentId,
        bytes32 merkleRoot,
        uint256 batchSize,
        bool satisfied
    ) external override skillExists(skillAgentId) nonReentrant {
        if (_batches[skillAgentId][merkleRoot].settlesAt != 0) revert BatchAlreadyExists();

        uint256 fee = _skillMetadata[skillAgentId].feePerExecution;

        // Pull USDC into escrow if fee > 0
        if (fee > 0) {
            bool ok = IERC20(USDC).transferFrom(msg.sender, address(this), fee);
            if (!ok) revert InsufficientAllowance();
            _escrow[skillAgentId][merkleRoot] = fee;
        }

        uint256 settlesAt = block.timestamp + DISPUTE_WINDOW;

        _batches[skillAgentId][merkleRoot] = ExecutionBatch({
            merkleRoot: merkleRoot,
            batchSize:  batchSize,
            settlesAt:  settlesAt,
            disputed:   !satisfied, // if client unsatisfied, mark disputed immediately
            settled:    false
        });

        // Track execution count
        _executionCount[skillAgentId] += batchSize;

        emit ExecutionProved(skillAgentId, 0, merkleRoot, batchSize, settlesAt);
    }

    // ─── Dispute ─────────────────────────────────────────────────────────────

    /// @inheritdoc ISkillMarketplace
    function disputeExecution(
        uint256 skillAgentId,
        bytes32 merkleRoot
    ) external override skillExists(skillAgentId) {
        ExecutionBatch storage batch = _batches[skillAgentId][merkleRoot];
        if (batch.settlesAt == 0) revert BatchNotFound();
        if (block.timestamp >= batch.settlesAt) revert DisputeWindowClosed();
        if (batch.disputed) revert AlreadyDisputed();
        if (batch.settled) revert AlreadySettled();

        batch.disputed = true;

        emit ExecutionDisputed(skillAgentId, 0, merkleRoot);
    }

    // ─── Settlement ──────────────────────────────────────────────────────────

    /// @inheritdoc ISkillMarketplace
    /// @dev Anyone can trigger settlement after window closes with no dispute.
    function settlePayment(
        uint256 skillAgentId,
        bytes32 merkleRoot
    ) external override skillExists(skillAgentId) nonReentrant {
        ExecutionBatch storage batch = _batches[skillAgentId][merkleRoot];
        if (batch.settlesAt == 0) revert BatchNotFound();
        if (block.timestamp < batch.settlesAt) revert DisputeWindowOpen();
        if (batch.disputed) revert AlreadyDisputed();
        if (batch.settled) revert AlreadySettled();

        batch.settled = true;

        uint256 amount = _escrow[skillAgentId][merkleRoot];
        _escrow[skillAgentId][merkleRoot] = 0;

        if (amount > 0) {
            address creator = _skillMetadata[skillAgentId].creator;
            bool ok = IERC20(USDC).transfer(creator, amount);
            if (!ok) revert TransferFailed();
            emit PaymentReleased(skillAgentId, 0, merkleRoot, amount);
        }
    }

    // ─── Merkle Verification ─────────────────────────────────────────────────

    /// @inheritdoc ISkillMarketplace
    function verifyBatch(
        bytes32 merkleRoot,
        bytes32 executionHash,
        bytes32[] calldata proof
    ) external pure override returns (bool valid) {
        bytes32 computed = executionHash;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            // Sort pair to ensure canonical ordering
            if (computed <= sibling) {
                computed = keccak256(abi.encodePacked(computed, sibling));
            } else {
                computed = keccak256(abi.encodePacked(sibling, computed));
            }
        }
        return computed == merkleRoot;
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    function skillMetadata(uint256 skillAgentId)
        external view override returns (SkillMetadata memory)
    {
        return _skillMetadata[skillAgentId];
    }

    function executionBatch(uint256 skillAgentId, bytes32 merkleRoot)
        external view override returns (ExecutionBatch memory)
    {
        return _batches[skillAgentId][merkleRoot];
    }

    function skillExecutionCount(uint256 skillAgentId)
        external view override returns (uint256)
    {
        return _executionCount[skillAgentId];
    }

    // ─── UUPS ────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address newImplementation)
        internal override(CustosNetworkImpl)
        onlyOwner
    {}
}
