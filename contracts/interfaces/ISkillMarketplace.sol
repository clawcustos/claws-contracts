// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISkillMarketplace
/// @notice Interface for CustosNetwork Skill Marketplace extension
/// @dev Extends existing CustosNetworkImpl — skills are agents with metadata + execution proofs
/// @author Custos (loop cycle 437, 2026-02-23)

interface ISkillMarketplace {

    // ─────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────

    struct SkillMetadata {
        string  name;            // human-readable skill name
        string  version;         // semver string e.g. "1.0.0"
        uint256 feePerExecution; // USDC (6 decimals), 0 = free
        bool    isSkill;         // distinguishes skill agents from work agents
        address creator;         // wallet that registered the skill
        uint256 registeredAt;    // block timestamp
    }

    struct ExecutionBatch {
        bytes32 merkleRoot;      // merkle root of N execution hashes in batch
        uint256 batchSize;       // number of executions in batch
        uint256 settlesAt;       // timestamp after which payment auto-releases (registeredAt + 24h)
        bool    disputed;        // true if client raised dispute in window
        bool    settled;         // true if payment released
    }

    // ─────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────

    event SkillRegistered(
        uint256 indexed skillAgentId,
        address indexed creator,
        string name,
        string version,
        uint256 feePerExecution
    );

    event ExecutionProved(
        uint256 indexed skillAgentId,
        uint256 indexed clientAgentId,
        bytes32 merkleRoot,
        uint256 batchSize,
        uint256 settlesAt
    );

    event ExecutionDisputed(
        uint256 indexed skillAgentId,
        uint256 indexed clientAgentId,
        bytes32 merkleRoot
    );

    event PaymentReleased(
        uint256 indexed skillAgentId,
        uint256 indexed clientAgentId,
        bytes32 merkleRoot,
        uint256 amount
    );

    // ─────────────────────────────────────────────────────────────────
    // Core Functions
    // ─────────────────────────────────────────────────────────────────

    /// @notice Register an existing agentId as a skill with metadata and fee
    /// @param skillAgentId Must already be registered via CustosNetwork.inscribe()
    /// @param name Human-readable skill name
    /// @param version Semver string
    /// @param feePerExecution USDC amount (6 decimals) charged per execution batch
    function registerSkill(
        uint256 skillAgentId,
        string calldata name,
        string calldata version,
        uint256 feePerExecution
    ) external;

    /// @notice Client agent submits execution proof batch as merkle root
    /// @dev Client must pre-approve USDC (feePerExecution) to this contract before calling
    /// @param skillAgentId The skill that was executed
    /// @param merkleRoot keccak256 merkle root of all execution hashes in this batch
    ///        Each leaf: keccak256(abi.encode(inputHash, outputHash, timestamp, clientAgentId))
    /// @param batchSize Number of executions in the batch
    /// @param satisfied Whether client is satisfied with the execution output
    function proveExecution(
        uint256 skillAgentId,
        bytes32 merkleRoot,
        uint256 batchSize,
        bool satisfied
    ) external;

    /// @notice Client disputes an execution batch within the 24h dispute window
    /// @param skillAgentId The skill that was executed
    /// @param merkleRoot The merkle root of the disputed batch
    function disputeExecution(
        uint256 skillAgentId,
        bytes32 merkleRoot
    ) external;

    /// @notice Trigger payment release after 24h window closes with no dispute
    /// @param skillAgentId The skill to release payment for
    /// @param merkleRoot The settled batch merkle root
    function settlePayment(
        uint256 skillAgentId,
        bytes32 merkleRoot
    ) external;

    /// @notice Verify that a single execution is included in a batch merkle root
    /// @param merkleRoot The batch root
    /// @param executionHash keccak256(abi.encode(inputHash, outputHash, timestamp, clientAgentId))
    /// @param proof Merkle proof path
    /// @return valid True if executionHash is provably in the batch
    function verifyBatch(
        bytes32 merkleRoot,
        bytes32 executionHash,
        bytes32[] calldata proof
    ) external pure returns (bool valid);

    // ─────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────

    function skillMetadata(uint256 skillAgentId) external view returns (SkillMetadata memory);
    function executionBatch(uint256 skillAgentId, bytes32 merkleRoot) external view returns (ExecutionBatch memory);
    function skillExecutionCount(uint256 skillAgentId) external view returns (uint256);
}
