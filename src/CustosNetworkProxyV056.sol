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
 * @title CustosNetworkProxyV056
 * @notice v0.5.6 implementation. Upgradeable proof-of-agent-work network.
 *         Deployed behind CustosNetworkProxy (0x9B5FD0B02355E954F159F33D7886e4198ee777b9).
 *         NOTE: Pre-audit. Semver convention adopted from v0.5.6 onwards.
 *
 * v0.5.6 changes vs V5.5:
 *   - Epoch-scoped attestation enforcement: proofHash can only be attested in the epoch it was inscribed
 *   - New storage slot 37: mapping(bytes32 => uint256) proofHashEpoch — set at inscription time
 *   - attest() now requires proofHashEpoch[proofHash] == currentEpoch (rejects stale proofs)
 *   - attest-external-agents.sh simplified: just attest chainHead, contract rejects stale ones
 *   - Versioning: CHANGELOG convention switches to v0.x.x (pre-audit, unaudited code)
 *
 * Architecture:
 *   - Two custodians (Custos + Pizza), equal authority
 *   - 2-of-2 multisig required for upgrades only
 *   - Either custodian alone: pause, withdraw, buyback, update subscription fee
 *   - Agents inscribe proof hashes forming a tamper-evident prevHash chain
 *   - Validators witness proofs; slashed for equivocation (only provable misbehaviour)
 */
contract CustosNetworkProxyV056 is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // Reentrancy guard (upgradeable-safe: stored in proxy storage slot)
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "E62");
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


    // ─── Storage ─────────────────────────────────────────────────────────────

    // ── Slots 1-4: identical to V5 — DO NOT reorder ──────────────────────────
    uint256 public totalAgents;       // slot 1
    uint256 public totalCycles;       // slot 2
    uint256 public epochPool;         // slot 3 — legacy V5 variable, preserved for storage layout. Not written post-V5.1. Read as 0.
    uint256 public buybackPool;       // slot 4

    // ── Slots 5-10: mappings identical to V5 — DO NOT reorder ────────────────
    mapping(uint256 => Agent)         public agents;          // slot 5
    mapping(address => uint256)       public agentIdByWallet; // slot 6
    mapping(bytes32 => Attestation[]) public attestations;    // slot 7
    mapping(address => uint256)       public validatorStakes; // slot 8 — legacy stake deposits from V5 (pre-subscription model). Returned in initializeV53. Zero for all agents post-V5.3.
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
    uint256 public validatorCount;           // slot 22b — tracks active validators. Incremented on subscribeValidator, decremented on lapse/slash. NOTE: initialises to 0 on V0.5.6 upgrade; accurate from upgrade onwards.

    // ── Slot 23: V5.3 equivocation challenge tracking ─────────────────────────
    mapping(uint256 => mapping(address => bool)) public challengesIssuedThisEpoch; // slot 23

    // ── Slot 24+: V5.4 commit-reveal privacy — append only ───────────────────
    uint256 public inscriptionCount;                                    // slot 24
    mapping(uint256 => bytes32)  public inscriptionContentHash;         // slot 25
    mapping(uint256 => bool)     public inscriptionRevealed;            // slot 26
    mapping(uint256 => string)   public inscriptionRevealedContent;     // slot 27
    mapping(bytes32 => uint256)  public proofHashToInscriptionId;       // slot 28
    mapping(uint256 => address)  public inscriptionAgent;               // slot 29

    // ── Slot 30: V0.5.6 epoch-scoped attestation ────────────────────────────────
    /// @notice Records which epoch a proofHash was inscribed in.
    ///         Set AFTER any epoch roll in inscribe() so it always equals currentEpoch
    ///         at the time of inscription. proofHashEpoch[hash] == 0 means never inscribed.
    mapping(bytes32 => uint256) public proofHashEpoch;               // slot 30

    // ── Slot 31: V0.5.6 reverse lookup — inscriptionId → proofHash ───────────
    /// @notice Enables ContentRevealed event to emit the actual proofHash.
    ///         Set at inscription time alongside proofHashToInscriptionId.
    mapping(uint256 => bytes32) public inscriptionProofHash;         // slot 31

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



    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyCustodian() {
        require(msg.sender == CUSTOS_CUSTODIAN || msg.sender == PIZZA_CUSTODIAN, "E22");
        _;
    }

    modifier onlyValidator() {
        uint256 id = agentIdByWallet[msg.sender];
        require(id != 0, "E20");
        Agent storage agent = agents[id];
        require(agent.role == AgentRole.VALIDATOR, "E21");
        require(agent.subExpiresAt > block.timestamp, "E36");
        _;
    }

    modifier onlyRegistered() {
        require(agentIdByWallet[msg.sender] != 0, "E20");
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
    function initializeV056() external reinitializer(6) {
        // No migrations needed — proofHashEpoch starts at zero for all existing proofs.
        // validatorCount will be stale (0) after upgrade; lapseExpiredValidator guards this.
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

        require(proofHash != bytes32(0),                           "E12");
        require(prevHash == agent.chainHead,                       "E14");
        require(
            agent.lastInscriptionAt == 0 ||
            block.timestamp >= agent.lastInscriptionAt + MIN_INSCRIPTION_GAP,
            "E44"
        );
        require(bytes(summary).length <= 140,                     "E43");

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
        inscriptionProofHash[inscriptionId]   = proofHash;
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

        // V0.5.6: record after epoch roll so proofHashEpoch[ph] == currentEpoch when attest is called
        // (if this inscription triggered a roll, the proof belongs to the NEW epoch)
        proofHashEpoch[proofHash] = currentEpoch;
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
        require(inscriptionId > 0 && inscriptionId <= inscriptionCount, "E15");
        require(inscriptionAgent[inscriptionId] == msg.sender,          "E23");
        require(!inscriptionRevealed[inscriptionId],                     "E31");

        bytes32 stored = inscriptionContentHash[inscriptionId];
        require(stored != bytes32(0), "E56");

        require(
            keccak256(abi.encodePacked(content, salt)) == stored,
            "E51"
        );

        inscriptionRevealed[inscriptionId]        = true;
        inscriptionRevealedContent[inscriptionId] = content;

        emit ContentRevealed(inscriptionId, inscriptionProofHash[inscriptionId], content);
    }

    /**
     * @notice Query inscription content status.
     */
    function getInscriptionContent(uint256 inscriptionId)
        external view
        returns (bool revealed, string memory content, bytes32 contentHash)
    {
        require(inscriptionId > 0 && inscriptionId <= inscriptionCount, "E15");
        revealed    = inscriptionRevealed[inscriptionId];
        content     = revealed ? inscriptionRevealedContent[inscriptionId] : "";
        contentHash = inscriptionContentHash[inscriptionId];
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
        // Error key (off-chain reference):
        // E01 = invalid agentId
        // E02 = zero proofHash
        // E04 = proof not found (never inscribed)
        // E05 = proof not from current epoch (stale)
        // E06 = already attested this proof this epoch
        require(agentId != 0 && agentId <= totalAgents, "E01");
        require(proofHash != bytes32(0), "E02");
        require(proofHashToInscriptionId[proofHash] != 0, "E04");
        require(proofHashEpoch[proofHash] == currentEpoch, "E05");
        require(!hasAttested[currentEpoch][proofHash][msg.sender], "E06");

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
        require(epochId < currentEpoch, "E37");
        require(!epochClaimed[epochId][msg.sender], "E30");
        require(currentEpoch - epochId <= EPOCH_CLAIM_WINDOW, "E42");

        uint256 points = validatorEpochPoints[epochId][msg.sender];
        uint256 total  = epochTotalPoints[epochId];
        uint256 inscriptions = epochInscriptionCount[epochId];
        require(points > 0, "E53");

        require(points * 10000 / inscriptions >= MIN_PARTICIPATION_BPS, "E46");

        epochClaimed[epochId][msg.sender] = true;
        // Use the immutable snapshot as the denominator so each validator's share is calculated
        // from the full epoch pool, regardless of claim order.
        // Deduct from the mutable remaining pool to ensure total claims never exceed the snapshot.
        uint256 snapshot = epochSnapshotPool[epochId];
        require(snapshot > 0, "E39");
        uint256 reward   = snapshot * points / total;
        uint256 remaining = epochValidatorPool[epochId];
        require(reward <= remaining, "E55");
        epochValidatorPool[epochId] = remaining - reward;
        IERC20(USDC).safeTransfer(msg.sender, reward);
        emit ValidatorRewardClaimed(msg.sender, reward);
    }

    function sweepExpiredEpoch(uint256 epochId) external nonReentrant {
        require(currentEpoch - epochId > EPOCH_CLAIM_WINDOW, "E38");
        uint256 remaining = epochValidatorPool[epochId];
        require(remaining > 0, "E50");
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

        require(agent.role != AgentRole.VALIDATOR, "E32");
        require(agent.cycleCount >= VALIDATOR_INSCRIPTION_THRESHOLD, "E47");
        require(agent.subExpiresAt == 0, "E34");

        uint256 fee = validatorSubscriptionFee;
        IERC20(USDC).safeTransferFrom(msg.sender, TREASURY, fee);

        agent.role = AgentRole.VALIDATOR;
        agent.subExpiresAt = block.timestamp + SUBSCRIPTION_DURATION;
        validatorCount += 1;

        emit ValidatorSubscribed(agentId, msg.sender, agent.subExpiresAt);
    }

    /**
     * @notice Renew validator subscription. Extends from current expiry or restarts if lapsed.
     */
    function renewSubscription() external whenNotPaused nonReentrant onlyRegistered {
        uint256 agentId = agentIdByWallet[msg.sender];
        Agent storage agent = agents[agentId];

        require(agent.role == AgentRole.VALIDATOR, "E24");

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
        require(newFee <= MAX_SUBSCRIPTION_FEE, "E45");
        uint256 oldFee = validatorSubscriptionFee;
        validatorSubscriptionFee = newFee;
        emit SubscriptionFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Custodian manually lapses an expired validator.
     */
    function lapseExpiredValidator(uint256 agentId) external onlyCustodian {
        Agent storage agent = agents[agentId];
        require(agent.role == AgentRole.VALIDATOR, "E24");
        require(agent.subExpiresAt <= block.timestamp, "E35");

        agent.role = AgentRole.INSCRIBER;
        agent.subExpiresAt = 0;
        if (validatorCount > 0) validatorCount -= 1;
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
        require(msg.sender == CUSTOS_CUSTODIAN || msg.sender == PIZZA_CUSTODIAN, "E22");

        // V5.3: One challenge per epoch per challenger
        require(!challengesIssuedThisEpoch[currentEpoch][msg.sender], "E60");

        uint256 validatorAgentId = agentIdByWallet[validator];
        require(validatorAgentId != 0, "E25");
        require(agents[validatorAgentId].role == AgentRole.VALIDATOR, "E24");

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

        require(signer1 == validator && signer2 == validator, "E16");

        // Mark challenge as issued for this epoch
        challengesIssuedThisEpoch[currentEpoch][msg.sender] = true;

        // V5.3: Slash epoch credits (no stake deposit in V5.3 — subscription model)
        // Forfeit the validator's epoch points for this epoch to the challenger's pool share.
        // The subscription fee already paid is non-refundable.
        uint256 slashedPoints = validatorEpochPoints[currentEpoch][validator];
        require(slashedPoints > 0, "E54");

        // Zero out the validator's epoch points — they cannot claim this epoch
        validatorEpochPoints[currentEpoch][validator] = 0;
        epochTotalPoints[currentEpoch] -= slashedPoints;

        // Demote validator immediately
        agents[validatorAgentId].role = AgentRole.INSCRIBER;
        agents[validatorAgentId].subExpiresAt = 0;
        if (validatorCount > 0) validatorCount -= 1;

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
        require(swapTarget == ALLOWANCE_HOLDER,           "E61");
        require(usdcAmount > 0,                           "E11");
        require(usdcAmount <= buybackPool,                "E49");

        buybackPool -= usdcAmount;

        // Approve allowance-holder (standard ERC20 approve — no permit2)
        IERC20(USDC).approve(ALLOWANCE_HOLDER, usdcAmount);

        // Snapshot before
        uint256 custosBefore = IERC20(CUSTOS_TOKEN).balanceOf(address(this));

        // Execute swap — clear approval regardless of outcome (no dangling allowance)
        (bool success,) = swapTarget.call(swapData);
        IERC20(USDC).approve(ALLOWANCE_HOLDER, 0);
        require(success, "E52");

        // Verify received amount
        uint256 custosAfter    = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        uint256 custosReceived = custosAfter - custosBefore;
        require(custosReceived >= minCustosOut, "E48");

        // Send $CUSTOS to ecosystem wallet — NOT burned
        IERC20(CUSTOS_TOKEN).safeTransfer(ECOSYSTEM_WALLET, custosReceived);

        emit BuybackExecuted(usdcAmount, custosReceived);
    }

    // ─── Treasury Withdrawal ──────────────────────────────────────────────────

    /**
     * @notice Sweep any token balance to treasury. Either custodian.
     */
    function withdrawToTreasury(address token, uint256 amount) external onlyCustodian nonReentrant {
        require(amount > 0, "E11");
        // If recovering USDC, protect validator pool + buyback pool from being swept
        if (token == USDC) {
            uint256 locked = validatorPool + buybackPool;
            uint256 bal = IERC20(USDC).balanceOf(address(this));
            require(bal >= locked + amount, "E49");
        }
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
        require(!genesisSet[agentId],            "E33");
        require(agentId != 0 && agentId <= totalAgents, "E13");

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
        require(newImpl != address(0), "E10");
        upgradeProposals[msg.sender] = newImpl;
        emit UpgradeProposed(msg.sender, newImpl);
    }

    /**
     * @notice Confirm and execute upgrade if both custodians agree.
     */
    function confirmUpgrade(address newImpl) external onlyCustodian {
        require(newImpl != address(0), "E10");

        address other = (msg.sender == CUSTOS_CUSTODIAN) ? PIZZA_CUSTODIAN : CUSTOS_CUSTODIAN;
        require(upgradeProposals[other] == newImpl, "E59");

        // _authorizeUpgrade checks upgradeProposals during the call — must remain set.
        // Cleared below after successful upgrade.
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
        return (totalAgents, totalCycles, validatorPool, buybackPool, validatorCount);
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
            "E59"
        );
    }
}