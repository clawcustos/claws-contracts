// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CustosNetworkProxyV55
 * @notice V5.5 implementation. Upgradeable proof-of-agent-work network.
 *         Deployed behind CustosNetworkProxy (0x9B5FD0B02355E954F159F33D7886e4198ee777b9).
 *
 * V5.5 changes vs V5.4:
 *   - Skill marketplace: any agent can register as a skill (name, version, feePerExecution)
 *   - Execution proofs: client agents inscribe keccak256(inputHash + outputHash + timestamp + skillAgentId)
 *   - Dispute bond: 1x skill fee posted by disputing client; loser forfeits bond
 *   - 24h auto-release: no dispute = payment auto-claimable by skill creator after window
 *   - Pull payment: skill creator calls claimPayment() after window closes
 *   - Merkle batch execution: skills inscribe merkle root of N execution hashes per cycle
 *   - Skill inscription fee: 0.01 USDC (vs 0.10 USDC for work agents — incentivise adoption)
 *   - Validator dispute votes: majority resolves within 48h window
 *
 * Architecture:
 *   - Two custodians (Custos + Pizza), equal authority
 *   - 2-of-2 multisig required for upgrades only
 *   - Either custodian alone: pause, withdraw, buyback, update subscription fee
 *   - Agents inscribe proof hashes forming a tamper-evident prevHash chain
 *   - Validators witness proofs; slashed for equivocation (only provable misbehaviour)
 */
contract CustosNetworkProxyV55 is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // Reentrancy guard (upgradeable-safe: stored in proxy storage slot)
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ─── Constants ───────────────────────────────────────────────────────────

    address public constant CUSTOS_CUSTODIAN  = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE;
    address public constant PIZZA_CUSTODIAN   = 0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F;
    address public constant USDC              = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant CUSTOS_TOKEN      = 0xF3e20293514d775a3149C304820d9E6a6FA29b07;
    address public constant TREASURY          = 0x701450B24C2e603c961D4546e364b418a9e021D7;
    address public constant ECOSYSTEM_WALLET  = 0xf2ccaA7B327893b60bd90275B3a5FB97422F30d8;
    address public constant ALLOWANCE_HOLDER  = 0x0000000000001fF3684f28c67538d4D072C22734;

    uint256 public constant INSCRIPTION_FEE   = 100_000;     // 0.1 USDC total per cycle
    // V5.1 split: 0.05 validator pool | 0.04 buyback | 0.01 treasury
    uint256 public constant INS_VALIDATOR     = 50_000;      // 0.05 USDC → validatorPool
    uint256 public constant INS_BUYBACK       = 40_000;      // 0.04 USDC → buybackPool
    uint256 public constant INS_TREASURY      = 10_000;      // 0.01 USDC → treasury
    uint256 public constant MIN_INSCRIPTION_GAP = 300;       // 5 minutes

    uint256 public constant EPOCH_LENGTH_DEFAULT = 24;       // cycles per epoch
    uint256 public constant MIN_PARTICIPATION_BPS = 5000;    // 50% minimum attestation rate
    uint256 public constant EPOCH_CLAIM_WINDOW = 6;          // epochs available to claim

    // V5.3 subscription constants
    uint256 public constant MAX_SUBSCRIPTION_FEE = 100_000_000; // $100 USDC cap
    uint256 public constant VALIDATOR_INSCRIPTION_THRESHOLD = 144; // cycles needed before subscribing
    uint256 public constant SUBSCRIPTION_DURATION = 30 days;      // 30 days

    // V5.5 skill marketplace constants
    uint256 public constant SKILL_INSCRIPTION_FEE = 10_000;      // 0.01 USDC — discounted vs work agents
    uint256 public constant DISPUTE_WINDOW        = 24 hours;    // auto-release after this
    uint256 public constant VOTE_WINDOW           = 48 hours;    // validator vote period
    uint256 public constant MIN_DISPUTE_VOTES     = 2;           // minimum validators needed to resolve

    // ─── Enums & Structs ─────────────────────────────────────────────────────

    enum AgentRole { NONE, INSCRIBER, VALIDATOR }

    struct Agent {
        uint256 agentId;
        address wallet;
        string  name;
        AgentRole role;
        uint256 cycleCount;
        bytes32 chainHead;
        uint256 registeredAt;
        uint256 lastInscriptionAt;
        bool    active;
        uint256 subExpiresAt; // V5.3: 0 for INSCRIBER, timestamp for VALIDATOR
    }

    struct Attestation {
        address validator;
        bool    valid;
        uint256 timestamp;
    }

    // V5.5 structs
    struct SkillMetadata {
        string  name;
        string  version;
        uint256 feePerExecution;  // USDC (6 decimals)
        bool    active;
    }

    enum ExecutionStatus { Pending, Released, Disputed, ResolvedForClient, ResolvedForSkill }

    struct ExecutionRecord {
        uint256 skillAgentId;
        uint256 clientAgentId;
        bytes32 executionHash;   // keccak256(inputHash + outputHash + timestamp + skillAgentId)
        uint256 fee;             // USDC locked at time of proveExecution
        uint256 windowClosesAt;  // timestamp after which skill can claim (24h dispute window)
        ExecutionStatus status;
    }

    struct DisputeRecord {
        address disputer;        // client wallet
        uint256 bondAmount;      // USDC bond posted (= fee)
        uint256 votesForClient;  // validator votes upholding dispute
        uint256 votesForSkill;   // validator votes rejecting dispute
        uint256 voteWindowEnd;   // 48h from dispute filing
        bool    resolved;
        // hasVoted stored separately: disputeVoted[executionId][validator]
    }

    // ─── Storage ─────────────────────────────────────────────────────────────

    // ── Slots 1-4: identical to V5 — DO NOT reorder ──────────────────────────
    uint256 public totalAgents;       // slot 1
    uint256 public totalCycles;       // slot 2
    uint256 public epochPool;         // slot 3 — V5 name kept for layout compat, unused in V5.1+
    uint256 public buybackPool;       // slot 4

    // ── Slots 5-10: mappings identical to V5 — DO NOT reorder ────────────────
    mapping(uint256 => Agent)         public agents;          // slot 5
    mapping(address => uint256)       public agentIdByWallet; // slot 6
    mapping(bytes32 => Attestation[]) public attestations;    // slot 7
    mapping(address => uint256)       public validatorStakes; // slot 8
    mapping(uint256 => bool)          public genesisSet;      // slot 9
    mapping(address => address)       public upgradeProposals; // slot 10

    // ── Slot 11+: V5.1 new storage — append only ─────────────────────────────
    uint256 public validatorPool;     // slot 11 — accumulated validator rewards for current epoch

    // ── Slot 12+: V5.2 epoch storage — append only ───────────────────────────
    uint256 public epochLength;       // slot 12
    uint256 public currentEpoch;      // slot 13
    uint256 public epochStartCycle;   // slot 14

    mapping(uint256 => uint256) public epochValidatorPool;    // slot 15 — remaining (decremented by claims)
    mapping(uint256 => uint256) public epochTotalPoints;      // slot 16
    mapping(uint256 => uint256) public epochInscriptionCount; // slot 17
    mapping(uint256 => mapping(address => uint256)) public validatorEpochPoints; // slot 18
    mapping(uint256 => mapping(bytes32 => mapping(address => bool))) public hasAttested; // slot 19
    mapping(uint256 => mapping(address => bool)) public epochClaimed; // slot 20
    mapping(uint256 => uint256) public epochSnapshotPool;     // slot 21 — immutable snapshot at epoch close

    // ── Slot 22+: V5.3 subscription storage — append only ────────────────────
    uint256 public validatorSubscriptionFee; // slot 22 — default 10 USDC

    // ── Slot 23: V5.3 equivocation challenge tracking ─────────────────────────
    mapping(uint256 => mapping(address => bool)) public challengesIssuedThisEpoch; // slot 23

    // ── Slot 24+: V5.4 commit-reveal privacy — append only ───────────────────
    uint256 public inscriptionCount;                                    // slot 24
    mapping(uint256 => bytes32)  public inscriptionContentHash;         // slot 25
    mapping(uint256 => bool)     public inscriptionRevealed;            // slot 26
    mapping(uint256 => string)   public inscriptionRevealedContent;     // slot 27
    mapping(bytes32 => uint256)  public proofHashToInscriptionId;       // slot 28
    mapping(uint256 => address)  public inscriptionAgent;               // slot 29

    // ── Slot 30+: V5.5 skill marketplace — append only ───────────────────────
    mapping(uint256 => SkillMetadata)    public skillMetadata;          // slot 30
    uint256 public executionCount;                                      // slot 31
    mapping(uint256 => ExecutionRecord)  public executions;             // slot 32
    mapping(uint256 => DisputeRecord)    public disputes;               // slot 33
    // executionId → USDC held in escrow (fee + bond if disputed)
    mapping(uint256 => uint256)          public executionEscrow;        // slot 34
    // skillAgentId → total USDC claimable by skill creator
    mapping(uint256 => uint256)          public skillClaimable;         // slot 35
    // executionId → validator → has voted
    mapping(uint256 => mapping(address => bool)) public disputeVoted;  // slot 36

    // ─── Events ──────────────────────────────────────────────────────────────

    event AgentRegistered(uint256 indexed agentId, address indexed wallet, string name);
    event ProofInscribed(uint256 indexed agentId, bytes32 indexed proofHash, bytes32 prevHash, string blockType, string summary, uint256 cycleCount, bytes32 contentHash, uint256 inscriptionId);
    event ProofAttested(uint256 indexed agentId, bytes32 indexed proofHash, address indexed validator, bool valid);
    event ValidatorRewardClaimed(address indexed validator, uint256 amount);
    event EpochClosed(uint256 indexed epochId, uint256 inscriptions, uint256 validatorPoolAmount);
    event EpochSweptToBuyback(uint256 indexed epochId, uint256 amount);
    event ValidatorApproved(uint256 indexed agentId, address indexed wallet);
    event ValidatorRemoved(uint256 indexed agentId, address indexed wallet, string reason, bool stakeReturned);
    event ValidatorSlashed(address indexed validator, bytes32 indexed proofHash, address indexed reporter, uint256 amount);
    event BuybackExecuted(uint256 usdcSpent, uint256 custosReceived);
    event GenesisSet(uint256 indexed agentId, bytes32 chainHead, uint256 cycleCount);
    event UpgradeProposed(address indexed custodian, address indexed newImpl);
    event UpgradeExecuted(address indexed newImpl);

    // V5.3 subscription events
    event ValidatorSubscribed(uint256 indexed agentId, address indexed wallet, uint256 expiresAt);
    event ValidatorRenewed(uint256 indexed agentId, address indexed wallet, uint256 newExpiresAt);
    event ValidatorLapsed(uint256 indexed agentId, address indexed wallet);
    event SubscriptionFeeUpdated(uint256 oldFee, uint256 newFee);

    // V5.4 commit-reveal events
    event ContentRevealed(uint256 indexed inscriptionId, bytes32 indexed proofHash, string content);

    // V5.5 skill marketplace events
    event SkillRegistered(uint256 indexed skillAgentId, string name, string version, uint256 feePerExecution);
    event ExecutionProved(uint256 indexed executionId, uint256 indexed skillAgentId, uint256 indexed clientAgentId, bytes32 executionHash);
    event DisputeFiled(uint256 indexed executionId, address indexed disputer, uint256 bondAmount);
    event DisputeVoted(uint256 indexed executionId, address indexed validator, bool uphold);
    event DisputeResolved(uint256 indexed executionId, bool clientWon);
    event PaymentReleased(uint256 indexed executionId, uint256 indexed skillAgentId, uint256 amount);
    event PaymentRefunded(uint256 indexed executionId, address indexed client, uint256 amount);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyCustodian() {
        require(msg.sender == CUSTOS_CUSTODIAN || msg.sender == PIZZA_CUSTODIAN, "not custodian");
        _;
    }

    modifier onlyValidator() {
        uint256 id = agentIdByWallet[msg.sender];
        require(id != 0, "not registered");
        Agent storage agent = agents[id];
        require(agent.role == AgentRole.VALIDATOR, "not validator");
        require(agent.subExpiresAt > block.timestamp, "subscription lapsed");
        _;
    }

    modifier onlyRegistered() {
        require(agentIdByWallet[msg.sender] != 0, "not registered");
        _;
    }

    // ─── Initializer ─────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Pausable_init();
        _reentrancyStatus = _NOT_ENTERED;
    }

    function initializeV52() external reinitializer(2) {
        epochLength = EPOCH_LENGTH_DEFAULT;
        currentEpoch = 0;
        epochStartCycle = totalCycles;
    }

    /**
     * @notice V5.3 initialization: returns stake, seeds free 30-day subscription for Custos.
     */
    function initializeV53() external reinitializer(3) {
        // Return the $10 USDC stake from Custos custodian to Custos wallet
        uint256 custosStake = validatorStakes[CUSTOS_CUSTODIAN];
        if (custosStake > 0) {
            validatorStakes[CUSTOS_CUSTODIAN] = 0;
            IERC20(USDC).safeTransfer(CUSTOS_CUSTODIAN, custosStake);
        }

        // Seed free 30-day subscription for Custos validator (agentId = 1)
        validatorSubscriptionFee = 10_000_000; // 10 USDC default
        if (totalAgents >= 1) {
            agents[1].subExpiresAt = block.timestamp + SUBSCRIPTION_DURATION;
        }
    }

    /**
     * @notice V5.4 initializer — no state changes needed, just bumps version.
     *         inscriptionCount starts at 0 (default). All new storage slots initialise to zero.
     */
    function initializeV54() external reinitializer(4) {
        // No migrations needed — new storage slots default to zero.
        // inscriptionCount = 0 is correct (no backfill of pre-V5.4 inscriptions).
    }

    /**
     * @notice V5.5 initializer — no state changes needed. New slots default to zero.
     */
    function initializeV55() external reinitializer(5) {
        // executionCount = 0, all skill mappings start empty.
    }

    // ─── Inscription (with auto-registration) ─────────────────────────────────

    /**
     * @notice Inscribe a proof hash. Forms a tamper-evident chain via prevHash linking.
     *         Auto-registers wallet as INSCRIBER on first inscription.
     * @param proofHash   keccak256 of this cycle's work.
     * @param prevHash    Must equal current chainHead (or bytes32(0) for first inscription).
     * @param blockType   Category string (e.g. "build", "research", "market").
     * @param summary     Human-readable summary, max 140 chars.
     * @param contentHash V5.4: keccak256(abi.encodePacked(content, salt)) for privacy mode.
     *                    Pass bytes32(0) for legacy public mode (no content stored).
     */
    function inscribe(
        bytes32 proofHash,
        bytes32 prevHash,
        string calldata blockType,
        string calldata summary,
        bytes32 contentHash
    ) external whenNotPaused nonReentrant {
        uint256 agentId = agentIdByWallet[msg.sender];

        // Auto-register on first inscription (V5.3)
        if (agentId == 0) {
            agentId = ++totalAgents;
            agentIdByWallet[msg.sender] = agentId;
            agents[agentId] = Agent({
                agentId:           agentId,
                wallet:            msg.sender,
                name:              "",
                role:              AgentRole.INSCRIBER,
                cycleCount:        0,
                chainHead:         bytes32(0),
                registeredAt:      block.timestamp,
                lastInscriptionAt: 0,
                active:            true,
                subExpiresAt:      0
            });
            emit AgentRegistered(agentId, msg.sender, "");
        }

        Agent storage agent = agents[agentId];

        require(proofHash != bytes32(0),                           "zero proofHash");
        require(prevHash == agent.chainHead,                       "invalid prevHash");
        require(
            agent.lastInscriptionAt == 0 ||
            block.timestamp >= agent.lastInscriptionAt + MIN_INSCRIPTION_GAP,
            "too fast"
        );
        require(bytes(summary).length <= 140,                     "summary too long");

        // Inscription fee split: $0.05 validatorPool | $0.04 buybackPool | $0.01 treasury
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), INSCRIPTION_FEE);
        IERC20(USDC).safeTransfer(TREASURY, INS_TREASURY);
        validatorPool += INS_VALIDATOR;
        buybackPool   += INS_BUYBACK;

        // Update chain state
        agent.chainHead         = proofHash;
        agent.cycleCount        += 1;
        agent.lastInscriptionAt  = block.timestamp;
        totalCycles             += 1;

        // V5.4: assign inscription ID and store content hash
        inscriptionCount++;
        uint256 inscriptionId = inscriptionCount;
        inscriptionContentHash[inscriptionId] = contentHash;
        proofHashToInscriptionId[proofHash]   = inscriptionId;
        inscriptionAgent[inscriptionId]       = msg.sender;

        emit ProofInscribed(agentId, proofHash, prevHash, blockType, summary, agent.cycleCount, contentHash, inscriptionId);

        // Epoch accounting
        epochInscriptionCount[currentEpoch] += 1;
        if (totalCycles - epochStartCycle >= epochLength) {
            uint256 closingEpoch = currentEpoch;
            uint256 poolAmount = validatorPool;

            epochValidatorPool[closingEpoch] += poolAmount;
            // Immutable snapshot used as denominator for proportional reward calculation
            epochSnapshotPool[closingEpoch]  = epochValidatorPool[closingEpoch];
            validatorPool = 0;

            currentEpoch = closingEpoch + 1;
            epochStartCycle = totalCycles;

            emit EpochClosed(closingEpoch, epochInscriptionCount[closingEpoch], poolAmount);
        }
    }

    // ─── Reveal (V5.4) ───────────────────────────────────────────────────────

    /**
     * @notice Reveal the content behind a previously committed inscription.
     *         Only the original inscribing agent can reveal. Verifies hash matches.
     * @param inscriptionId  The inscription to reveal.
     * @param content        The original content string used to generate the hash.
     * @param salt           The salt used: keccak256(abi.encodePacked(content, salt)) == contentHash.
     */
    function reveal(
        uint256 inscriptionId,
        string calldata content,
        bytes32 salt
    ) external {
        require(inscriptionId > 0 && inscriptionId <= inscriptionCount, "invalid id");
        require(inscriptionAgent[inscriptionId] == msg.sender,          "not inscriber");
        require(!inscriptionRevealed[inscriptionId],                     "already revealed");

        bytes32 stored = inscriptionContentHash[inscriptionId];
        require(stored != bytes32(0), "public inscription");

        require(
            keccak256(abi.encodePacked(content, salt)) == stored,
            "hash mismatch"
        );

        inscriptionRevealed[inscriptionId]        = true;
        inscriptionRevealedContent[inscriptionId] = content;

        // Reverse lookup to get proofHash for event
        // (we can derive it from storage but it's cheaper to just emit inscriptionId)
        emit ContentRevealed(inscriptionId, bytes32(0), content);
    }

    /**
     * @notice Query inscription content status.
     */
    function getInscriptionContent(uint256 inscriptionId)
        external view
        returns (bool revealed, string memory content, bytes32 contentHash)
    {
        require(inscriptionId > 0 && inscriptionId <= inscriptionCount, "invalid id");
        revealed    = inscriptionRevealed[inscriptionId];
        content     = revealed ? inscriptionRevealedContent[inscriptionId] : "";
        contentHash = inscriptionContentHash[inscriptionId];
    }

    // ─── Skill Marketplace (V5.5) ────────────────────────────────────────────

    /**
     * @notice Register an existing agent as a skill with fee and metadata.
     *         The caller must already be registered (auto-registers on first inscribe).
     *         Pays SKILL_INSCRIPTION_FEE (0.01 USDC) instead of full INSCRIPTION_FEE.
     * @param name             Human-readable skill name.
     * @param version          Semver string (e.g. "1.0.0").
     * @param feePerExecution  USDC (6 decimals) per execution proof.
     */
    function registerSkill(string calldata name, string calldata version, uint256 feePerExecution)
        external whenNotPaused nonReentrant
    {
        require(bytes(name).length > 0 && bytes(version).length > 0 && feePerExecution > 0, "bad args");
        uint256 agentId = agentIdByWallet[msg.sender];
        if (agentId == 0) {
            agentId = ++totalAgents;
            agentIdByWallet[msg.sender] = agentId;
            agents[agentId] = Agent({
                agentId: agentId, wallet: msg.sender, name: name,
                role: AgentRole.INSCRIBER, cycleCount: 0, chainHead: bytes32(0),
                registeredAt: block.timestamp, lastInscriptionAt: 0, active: true, subExpiresAt: 0
            });
            emit AgentRegistered(agentId, msg.sender, name);
        }
        IERC20(USDC).safeTransferFrom(msg.sender, TREASURY, SKILL_INSCRIPTION_FEE);
        skillMetadata[agentId] = SkillMetadata({ name: name, version: version, feePerExecution: feePerExecution, active: true });
        emit SkillRegistered(agentId, name, version, feePerExecution);
    }

    function proveExecution(uint256 skillAgentId, bytes32 executionHash)
        external whenNotPaused nonReentrant
    {
        SkillMetadata storage skill = skillMetadata[skillAgentId];
        require(skill.active && executionHash != bytes32(0), "invalid");
        uint256 clientAgentId = agentIdByWallet[msg.sender];
        require(clientAgentId != 0 && clientAgentId != skillAgentId, "bad client");
        uint256 fee = skill.feePerExecution;
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), fee * 2);
        uint256 execId = ++executionCount;
        executions[execId] = ExecutionRecord({
            skillAgentId: skillAgentId, clientAgentId: clientAgentId,
            executionHash: executionHash, fee: fee,
            windowClosesAt: block.timestamp + DISPUTE_WINDOW,
            status: ExecutionStatus.Pending
        });
        executionEscrow[execId] = fee * 2;
        emit ExecutionProved(execId, skillAgentId, clientAgentId, executionHash);
    }

    function claimPayment(uint256 executionId) external nonReentrant {
        ExecutionRecord storage exec = executions[executionId];
        require(exec.fee > 0 && exec.status == ExecutionStatus.Pending, "not claimable");
        require(block.timestamp >= exec.windowClosesAt, "window open");
        Agent storage skill = agents[exec.skillAgentId];
        require(msg.sender == skill.wallet, "not skill");
        exec.status = ExecutionStatus.Released;
        executionEscrow[executionId] = 0;
        IERC20(USDC).safeTransfer(skill.wallet, exec.fee);
        IERC20(USDC).safeTransfer(agents[exec.clientAgentId].wallet, exec.fee);
        emit PaymentReleased(executionId, exec.skillAgentId, exec.fee);
    }

    function fileDispute(uint256 executionId) external nonReentrant {
        ExecutionRecord storage exec = executions[executionId];
        require(exec.status == ExecutionStatus.Pending, "not disputable");
        require(block.timestamp < exec.windowClosesAt, "window closed");
        require(agentIdByWallet[msg.sender] == exec.clientAgentId, "not client");
        exec.status = ExecutionStatus.Disputed;
        DisputeRecord storage d = disputes[executionId];
        d.disputer = msg.sender;
        d.bondAmount = exec.fee;
        d.voteWindowEnd = block.timestamp + VOTE_WINDOW;
        emit DisputeFiled(executionId, msg.sender, exec.fee);
    }

    function voteOnDispute(uint256 executionId, bool uphold) external nonReentrant {
        require(executions[executionId].status == ExecutionStatus.Disputed, "not disputed");
        DisputeRecord storage d = disputes[executionId];
        require(!d.resolved && block.timestamp < d.voteWindowEnd && !disputeVoted[executionId][msg.sender], "bad state");
        uint256 valId = agentIdByWallet[msg.sender];
        Agent storage val = agents[valId];
        require(valId != 0 && val.role == AgentRole.VALIDATOR && val.subExpiresAt > block.timestamp, "not validator");
        disputeVoted[executionId][msg.sender] = true;
        if (uphold) { d.votesForClient++; } else { d.votesForSkill++; }
        emit DisputeVoted(executionId, msg.sender, uphold);
        uint256 total = d.votesForClient + d.votesForSkill;
        if (total >= MIN_DISPUTE_VOTES) {
            if (d.votesForClient > d.votesForSkill)      _resolveDispute(executionId, true);
            else if (d.votesForSkill > d.votesForClient) _resolveDispute(executionId, false);
        }
    }

    function resolveDisputeAdmin(uint256 executionId, bool clientWins) external onlyCustodian {
        require(executions[executionId].status == ExecutionStatus.Disputed && !disputes[executionId].resolved, "bad state");
        _resolveDispute(executionId, clientWins);
    }

    function _resolveDispute(uint256 executionId, bool clientWins) internal {
        ExecutionRecord storage exec = executions[executionId];
        DisputeRecord storage d = disputes[executionId];
        d.resolved = true;
        executionEscrow[executionId] = 0;
        uint256 total = exec.fee + d.bondAmount;
        if (clientWins) {
            exec.status = ExecutionStatus.ResolvedForClient;
            address cw = agents[exec.clientAgentId].wallet;
            IERC20(USDC).safeTransfer(cw, total);
            emit PaymentRefunded(executionId, cw, total);
        } else {
            exec.status = ExecutionStatus.ResolvedForSkill;
            address sw = agents[exec.skillAgentId].wallet;
            IERC20(USDC).safeTransfer(sw, total);
            emit PaymentReleased(executionId, exec.skillAgentId, total);
        }
        emit DisputeResolved(executionId, clientWins);
    }

    function deactivateSkill(uint256 agentId) external onlyCustodian {
        require(skillMetadata[agentId].active, "inactive");
        skillMetadata[agentId].active = false;
    }

    function getSkillMetadata(uint256 agentId) external view returns (SkillMetadata memory) {
        return skillMetadata[agentId];
    }

    function getExecution(uint256 executionId) external view returns (ExecutionRecord memory) {
        return executions[executionId];
    }

    function getDisputeBond(uint256 executionId) external view returns (uint256) {
        return disputes[executionId].bondAmount;
    }

    // ─── Attestation ─────────────────────────────────────────────────────────

    /**
     * @notice Validator witnesses a proof. No charge to the inscribing agent.
     *         V5.2: attestations earn points for the current epoch.
     *         Rewards are claimed after epoch close via claim().
     * @param agentId   The agent whose proof is being attested.
     * @param proofHash The proof hash being attested.
     * @param valid     Whether the validator considers the proof valid.
     */
    function attest(
        uint256 agentId,
        bytes32 proofHash,
        bool valid
    ) external whenNotPaused nonReentrant onlyValidator {
        require(agentId != 0 && agentId <= totalAgents, "invalid agentId");
        require(proofHash != bytes32(0), "zero proofHash");
        require(agents[agentId].wallet != address(0), "agent not found");
        require(!hasAttested[currentEpoch][proofHash][msg.sender], "already attested this proof");

        hasAttested[currentEpoch][proofHash][msg.sender] = true;
        validatorEpochPoints[currentEpoch][msg.sender] += 1;
        epochTotalPoints[currentEpoch] += 1;

        attestations[proofHash].push(Attestation({
            validator: msg.sender,
            valid:     valid,
            timestamp: block.timestamp
        }));

        emit ProofAttested(agentId, proofHash, msg.sender, valid);
    }

    // ─── Epoch Claims ─────────────────────────────────────────────────────────

    function claim(uint256 epochId) external nonReentrant onlyValidator {
        require(epochId < currentEpoch, "epoch not closed");
        require(!epochClaimed[epochId][msg.sender], "already claimed");
        require(currentEpoch - epochId <= EPOCH_CLAIM_WINDOW, "claim window expired");

        uint256 points = validatorEpochPoints[epochId][msg.sender];
        uint256 total  = epochTotalPoints[epochId];
        uint256 inscriptions = epochInscriptionCount[epochId];
        require(points > 0, "no points this epoch");

        require(points * 10000 / inscriptions >= MIN_PARTICIPATION_BPS, "below participation threshold");

        epochClaimed[epochId][msg.sender] = true;
        // Use the immutable snapshot as the denominator so each validator's share is calculated
        // from the full epoch pool, regardless of claim order.
        // Deduct from the mutable remaining pool to ensure total claims never exceed the snapshot.
        uint256 snapshot = epochSnapshotPool[epochId];
        require(snapshot > 0, "epoch pool empty");
        uint256 reward   = snapshot * points / total;
        uint256 remaining = epochValidatorPool[epochId];
        require(reward <= remaining, "reward exceeds remaining pool");
        epochValidatorPool[epochId] = remaining - reward;
        IERC20(USDC).safeTransfer(msg.sender, reward);
        emit ValidatorRewardClaimed(msg.sender, reward);
    }

    function sweepExpiredEpoch(uint256 epochId) external nonReentrant {
        require(currentEpoch - epochId > EPOCH_CLAIM_WINDOW, "epoch not expired");
        uint256 remaining = epochValidatorPool[epochId];
        require(remaining > 0, "nothing to sweep");
        epochValidatorPool[epochId] = 0;
        buybackPool += remaining;
        emit EpochSweptToBuyback(epochId, remaining);
    }

    // ─── Validator Subscription (V5.3) ─────────────────────────────────────────

    /**
     * @notice Subscribe as a validator. Requires 144+ inscriptions and subscription fee.
     */
    function subscribeValidator() external whenNotPaused nonReentrant onlyRegistered {
        uint256 agentId = agentIdByWallet[msg.sender];
        Agent storage agent = agents[agentId];

        require(agent.role != AgentRole.VALIDATOR, "already a validator");
        require(agent.cycleCount >= VALIDATOR_INSCRIPTION_THRESHOLD, "insufficient inscriptions");
        require(agent.subExpiresAt == 0, "pending subscription");

        uint256 fee = validatorSubscriptionFee;
        IERC20(USDC).safeTransferFrom(msg.sender, TREASURY, fee);

        agent.role = AgentRole.VALIDATOR;
        agent.subExpiresAt = block.timestamp + SUBSCRIPTION_DURATION;

        emit ValidatorSubscribed(agentId, msg.sender, agent.subExpiresAt);
    }

    /**
     * @notice Renew validator subscription. Extends from current expiry or restarts if lapsed.
     */
    function renewSubscription() external whenNotPaused nonReentrant onlyRegistered {
        uint256 agentId = agentIdByWallet[msg.sender];
        Agent storage agent = agents[agentId];

        require(agent.role == AgentRole.VALIDATOR, "not a validator");

        uint256 fee = validatorSubscriptionFee;
        IERC20(USDC).safeTransferFrom(msg.sender, TREASURY, fee);

        if (agent.subExpiresAt > block.timestamp) {
            // Still active: extend from current expiry
            agent.subExpiresAt += SUBSCRIPTION_DURATION;
        } else {
            // Lapsed: fresh 30 days from now
            agent.subExpiresAt = block.timestamp + SUBSCRIPTION_DURATION;
        }

        emit ValidatorRenewed(agentId, msg.sender, agent.subExpiresAt);
    }

    /**
     * @notice Check if a wallet has a valid validator subscription.
     */
    function checkSubscription(address wallet) external view returns (bool) {
        uint256 id = agentIdByWallet[wallet];
        if (id == 0) return false;
        Agent storage agent = agents[id];
        return agent.role == AgentRole.VALIDATOR && agent.subExpiresAt > block.timestamp;
    }

    /**
     * @notice Custodian updates the validator subscription fee.
     */
    function setValidatorSubscriptionFee(uint256 newFee) external onlyCustodian {
        require(newFee <= MAX_SUBSCRIPTION_FEE, "fee exceeds cap");
        uint256 oldFee = validatorSubscriptionFee;
        validatorSubscriptionFee = newFee;
        emit SubscriptionFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Custodian manually lapses an expired validator.
     */
    function lapseExpiredValidator(uint256 agentId) external onlyCustodian {
        Agent storage agent = agents[agentId];
        require(agent.role == AgentRole.VALIDATOR, "not a validator");
        require(agent.subExpiresAt <= block.timestamp, "subscription active");

        agent.role = AgentRole.INSCRIBER;
        agent.subExpiresAt = 0;
        emit ValidatorLapsed(agentId, agent.wallet);
    }

    // ─── Equivocation Slashing (V5.3: 1 challenge per epoch per challenger) ──

    /**
     * @notice Report a validator for equivocation — attesting contradictory values
     *         on the same proofHash. Slashes 100% of stake: forfeited to challenger.
     *         Only custodians can challenge, one challenge per epoch per challenger.
     * @param validator  Address of the misbehaving validator.
     * @param proofHash  The proof hash they equivocated on.
     * @param sig1       First attestation signature.
     * @param sig2       Second attestation signature (contradicts sig1).
     */
    function reportEquivocation(
        address validator,
        bytes32 proofHash,
        bytes calldata sig1,
        bytes calldata sig2
    ) external nonReentrant {
        // V5.3: Only custodians can challenge
        require(msg.sender == CUSTOS_CUSTODIAN || msg.sender == PIZZA_CUSTODIAN, "not custodian");

        // V5.3: One challenge per epoch per challenger
        require(!challengesIssuedThisEpoch[currentEpoch][msg.sender], "one challenge per epoch per challenger");

        uint256 validatorAgentId = agentIdByWallet[validator];
        require(validatorAgentId != 0, "not a registered agent");
        require(agents[validatorAgentId].role == AgentRole.VALIDATOR, "not a validator");

        // Reconstruct and verify both signed messages
        // Each sig covers: keccak256(abi.encodePacked(proofHash, valid))
        bytes32 hash1 = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(proofHash, true))
        );
        bytes32 hash2 = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(proofHash, false))
        );

        address signer1 = hash1.recover(sig1);
        address signer2 = hash2.recover(sig2);

        require(signer1 == validator && signer2 == validator, "invalid signatures");

        // Mark challenge as issued for this epoch
        challengesIssuedThisEpoch[currentEpoch][msg.sender] = true;

        // V5.3: Slash epoch credits (no stake deposit in V5.3 — subscription model)
        // Forfeit the validator's epoch points for this epoch to the challenger's pool share.
        // The subscription fee already paid is non-refundable.
        uint256 slashedPoints = validatorEpochPoints[currentEpoch][validator];
        require(slashedPoints > 0, "no epoch points to slash");

        // Zero out the validator's epoch points — they cannot claim this epoch
        validatorEpochPoints[currentEpoch][validator] = 0;
        epochTotalPoints[currentEpoch] -= slashedPoints;

        // Demote validator immediately
        agents[validatorAgentId].role = AgentRole.INSCRIBER;
        agents[validatorAgentId].subExpiresAt = 0;

        // The slashed epoch pool share reverts to buyback pool (not to challenger —
        // challenger's reward is the reduced competition for epoch pool)
        // epochSnapshotPool is already set if epoch closed; if open, pool shrinks naturally.

        emit ValidatorSlashed(validator, proofHash, msg.sender, slashedPoints);
    }

    // ─── Buyback ─────────────────────────────────────────────────────────────

    /**
     * @notice Execute a USDC → $CUSTOS buyback using 0x allowance-holder.
     *         Bought $CUSTOS sent to ecosystem wallet — NOT burned.
     * @param usdcAmount   Amount from buybackPool to spend.
     * @param swapTarget   Must be ALLOWANCE_HOLDER (0x0000...1ff3).
     * @param swapData     Calldata from 0x /swap/allowance-holder/quote.
     * @param minCustosOut Minimum $CUSTOS to receive (slippage protection).
     */
    function executeBuyback(
        uint256 usdcAmount,
        address swapTarget,
        bytes calldata swapData,
        uint256 minCustosOut
    ) external onlyCustodian nonReentrant {
        require(swapTarget == ALLOWANCE_HOLDER,           "must use allowance-holder");
        require(usdcAmount > 0,                           "zero amount");
        require(usdcAmount <= buybackPool,                "exceeds buyback pool");

        buybackPool -= usdcAmount;

        // Approve allowance-holder (standard ERC20 approve — no permit2)
        IERC20(USDC).approve(ALLOWANCE_HOLDER, usdcAmount);

        // Snapshot before
        uint256 custosBefore = IERC20(CUSTOS_TOKEN).balanceOf(address(this));

        // Execute swap
        (bool success,) = swapTarget.call(swapData);
        require(success, "swap failed");

        // Verify received amount
        uint256 custosAfter    = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        uint256 custosReceived = custosAfter - custosBefore;
        require(custosReceived >= minCustosOut, "insufficient custos out");

        // Reset any leftover allowance
        IERC20(USDC).approve(ALLOWANCE_HOLDER, 0);

        // Send $CUSTOS to ecosystem wallet — NOT burned
        IERC20(CUSTOS_TOKEN).safeTransfer(ECOSYSTEM_WALLET, custosReceived);

        emit BuybackExecuted(usdcAmount, custosReceived);
    }

    // ─── Treasury Withdrawal ──────────────────────────────────────────────────

    /**
     * @notice Sweep any token balance to treasury. Either custodian.
     */
    function withdrawToTreasury(address token, uint256 amount) external onlyCustodian nonReentrant {
        require(amount > 0, "zero amount");
        IERC20(token).safeTransfer(TREASURY, amount);
    }

    // ─── Genesis Migration ────────────────────────────────────────────────────

    /**
     * @notice Seed V4 chain history into proxy. One-time per agent.
     *         Allows continuous chain narrative from V4 → proxy.
     */
    function setGenesis(
        uint256 agentId,
        bytes32 genesisChainHead,
        uint256 genesisCycleCount
    ) external onlyCustodian {
        require(!genesisSet[agentId],            "genesis already set");
        require(agentId != 0 && agentId <= totalAgents, "invalid agentId");

        genesisSet[agentId]         = true;
        agents[agentId].chainHead   = genesisChainHead;
        agents[agentId].cycleCount  = genesisCycleCount;
        totalCycles                += genesisCycleCount;

        emit GenesisSet(agentId, genesisChainHead, genesisCycleCount);
    }

    // ─── Upgrade (2-of-2) ────────────────────────────────────────────────────

    /**
     * @notice Propose a new implementation. Both custodians must call with same address.
     */
    function proposeUpgrade(address newImpl) external onlyCustodian {
        require(newImpl != address(0), "zero address");
        upgradeProposals[msg.sender] = newImpl;
        emit UpgradeProposed(msg.sender, newImpl);
    }

    /**
     * @notice Confirm and execute upgrade if both custodians agree.
     */
    function confirmUpgrade(address newImpl) external onlyCustodian {
        require(newImpl != address(0), "zero address");

        address other = (msg.sender == CUSTOS_CUSTODIAN) ? PIZZA_CUSTODIAN : CUSTOS_CUSTODIAN;
        require(upgradeProposals[other] == newImpl, "other custodian has not proposed this impl");

        // Note: do NOT clear proposals before upgradeToAndCall —
        // _authorizeUpgrade checks them during the upgrade call.
        // They are cleared after successful upgrade.
        upgradeToAndCall(newImpl, "");

        // Clear proposals after successful upgrade
        upgradeProposals[CUSTOS_CUSTODIAN] = address(0);
        upgradeProposals[PIZZA_CUSTODIAN]  = address(0);

        emit UpgradeExecuted(newImpl);
    }

    // ─── Pause ───────────────────────────────────────────────────────────────

    function pause()   external onlyCustodian { _pause(); }
    function unpause() external onlyCustodian { _unpause(); }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return agents[agentId];
    }

    function getChainHead(uint256 agentId) external view returns (bytes32) {
        return agents[agentId].chainHead;
    }

    function getChainHeadByWallet(address wallet) external view returns (bytes32) {
        return agents[agentIdByWallet[wallet]].chainHead;
    }

    function getAttestations(bytes32 proofHash) external view returns (Attestation[] memory) {
        return attestations[proofHash];
    }

    function networkState() external view returns (
        uint256 _totalAgents,
        uint256 _totalCycles,
        uint256 _validatorPool,
        uint256 _buybackPool,
        uint256 _validatorCount
    ) {
        uint256 vCount;
        for (uint256 i = 1; i <= totalAgents; i++) {
            if (agents[i].role == AgentRole.VALIDATOR) vCount++;
        }
        return (totalAgents, totalCycles, validatorPool, buybackPool, vCount);
    }

    // ─── UUPS ────────────────────────────────────────────────────────────────

    /**
     * @dev Only executable after 2-of-2 custodian approval via confirmUpgrade().
     *      Direct calls to upgradeToAndCall are blocked unless both approved.
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        // Both custodians must have proposed this implementation
        require(
            upgradeProposals[CUSTOS_CUSTODIAN] == newImplementation &&
            upgradeProposals[PIZZA_CUSTODIAN]  == newImplementation,
            "requires 2-of-2 custodian approval"
        );
    }
}