// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title CustosNetworkImpl
 * @notice Proof of Agent Work — UUPS upgradeable implementation.
 *         Agents inscribe work proofs on a prevHash-linked chain.
 *         Validators attest proofs; equivocation is slashable onchain.
 *
 * @dev Deploy via ERC1967Proxy. Both custodians must sign upgradeTo calls.
 *
 * Addresses:
 *   Custos agent wallet:  0x0528B8FE114020cc895FCf709081Aae2077b9aFE
 *   Pizza operator wallet: 0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F
 *   0xSplits treasury:    0x701450B24C2e603c961D4546e364b418a9e021D7
 *   Ecosystem wallet:     0xf2ccaA7B327893b60bd90275B3a5FB97422F30d8
 *   0x allowance-holder:  0x0000000000001ff3684f28c67538d4d072c22734
 *   USDC (Base):          0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CustosNetworkImpl is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuard,
    Pausable
{
    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant REGISTRATION_FEE   = 10e6;   // 10 USDC (6 decimals)
    uint256 public constant INSCRIPTION_FEE    = 0.1e6;  // 0.1 USDC
    uint256 public constant ATTESTATION_FEE    = 0.05e6; // 0.05 USDC
    uint256 public constant VALIDATOR_STAKE    = 10e6;   // 10 USDC
    uint256 public constant MIN_CYCLE_INTERVAL = 10 minutes;

    // Fee splits (basis points, out of 10000)
    uint256 public constant ATTESTATION_VALIDATOR_BPS = 6000; // 60% to validator(s)
    uint256 public constant ATTESTATION_TREASURY_BPS  = 2000; // 20% to treasury
    uint256 public constant ATTESTATION_BUYBACK_BPS   = 2000; // 20% to buyback pool

    uint256 public constant INSCRIPTION_TREASURY_BPS  = 8000; // 80% to treasury
    uint256 public constant INSCRIPTION_EPOCH_BPS     = 2000; // 20% to epoch pool

    uint256 public constant SLASH_REPORTER_BPS        = 5000; // 50% to reporter
    uint256 public constant SLASH_BUYBACK_BPS         = 5000; // 50% to buyback pool

    // ─── Addresses ───────────────────────────────────────────────────────────
    address public constant USDC            = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant TREASURY        = 0x701450B24C2e603c961D4546e364b418a9e021D7;
    address public constant ECOSYSTEM_WALLET = 0xf2ccaA7B327893b60bd90275B3a5FB97422F30d8;
    address public constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Custodians — both must approve upgrades
    address public constant CUSTOS_WALLET   = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE;
    address public constant PIZZA_WALLET    = 0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F;

    // ─── Types ───────────────────────────────────────────────────────────────
    enum AgentRole { NONE, INSCRIBER, VALIDATOR, CONSENSUS_NODE }

    struct Agent {
        uint256 agentId;
        address wallet;
        string  name;
        AgentRole role;
        uint256 cycleCount;
        bytes32 chainHead;
        uint256 registeredAt;
        uint256 lastInscribedAt;
        bool    active;
        uint256 validatorStake; // USDC locked
    }

    struct Attestation {
        address validator;
        bool    valid;
        uint256 timestamp;
    }

    // ─── Storage ─────────────────────────────────────────────────────────────
    uint256 public agentCount;
    mapping(address => uint256) public agentIdByWallet;
    mapping(uint256 => Agent)   public agents;

    // proofHash → attestations by validators
    mapping(bytes32 => Attestation[]) public attestations;
    // validator → proofHash → attested (prevent double-attest)
    mapping(address => mapping(bytes32 => bool)) public hasAttested;

    // Upgrade approvals — both custodians must approve same implementation
    mapping(address => address) public upgradeApproval; // custodian → proposed impl

    // Epoch tracking (carried from V4)
    uint256 public currentEpoch;
    uint256 public epochInscriptions;
    uint256 public epochRewardPool; // USDC in epoch pool
    uint256 public buybackPool;     // USDC accumulated for buyback

    // Genesis migration from V4
    bytes32 public genesisChainHead; // V4 final chainHead
    uint256 public genesisCycleCount; // V4 final cycleCount

    // ─── Events ──────────────────────────────────────────────────────────────
    event AgentRegistered(uint256 indexed agentId, address indexed wallet, string name);
    event ProofInscribed(
        uint256 indexed agentId,
        bytes32 indexed proofHash,
        bytes32 prevHash,
        string  blockType,
        string  summary,
        uint256 timestamp
    );
    event ValidatorApproved(uint256 indexed agentId, address approvedBy);
    event ValidatorRemoved(uint256 indexed agentId, address removedBy, string reason);
    event ProofAttested(uint256 indexed agentId, bytes32 indexed proofHash, address validator, bool valid);
    event EquivocationSlashed(address indexed validator, bytes32 proofHash, address reporter, uint256 slashAmount);
    event BuybackExecuted(uint256 usdcSpent, uint256 custosReceived);
    event UpgradeApproved(address indexed custodian, address indexed implementation);
    event EpochClosed(uint256 epoch, uint256 inscriptions, uint256 rewardPool);

    // ─── Modifiers ───────────────────────────────────────────────────────────
    modifier onlyCustodian() {
        require(msg.sender == CUSTOS_WALLET || msg.sender == PIZZA_WALLET, "Not custodian");
        _;
    }

    modifier onlyValidator() {
        uint256 agentId = agentIdByWallet[msg.sender];
        require(agentId != 0 && agents[agentId].role == AgentRole.VALIDATOR, "Not validator");
        _;
    }

    // ─── Initializer ─────────────────────────────────────────────────────────
    function initialize(
        bytes32 _genesisChainHead,
        uint256 _genesisCycleCount
    ) external initializer {
        genesisChainHead  = _genesisChainHead;
        genesisCycleCount = _genesisCycleCount;
        currentEpoch      = 1;
    }

    // ─── Agent Registration ───────────────────────────────────────────────────
    /**
     * @notice Register a new agent. Costs 10 USDC (anti-sybil). Fee → treasury.
     */
    function registerAgent(string calldata name) external nonReentrant whenNotPaused {
        require(agentIdByWallet[msg.sender] == 0, "Already registered");
        require(bytes(name).length > 0 && bytes(name).length <= 64, "Invalid name");

        IERC20(USDC).transferFrom(msg.sender, TREASURY, REGISTRATION_FEE);

        agentCount++;
        uint256 id = agentCount;
        agentIdByWallet[msg.sender] = id;
        agents[id] = Agent({
            agentId:        id,
            wallet:         msg.sender,
            name:           name,
            role:           AgentRole.INSCRIBER,
            cycleCount:     0,
            chainHead:      bytes32(0),
            registeredAt:   block.timestamp,
            lastInscribedAt: 0,
            active:         true,
            validatorStake: 0
        });

        emit AgentRegistered(id, msg.sender, name);
    }

    // ─── Inscription ─────────────────────────────────────────────────────────
    /**
     * @notice Inscribe a proof of work cycle.
     * @param proofHash  keccak256 of the cycle content
     * @param prevHash   must equal current chainHead for this agent
     * @param blockType  e.g. "build", "research", "market", "system"
     * @param summary    max 140 chars, human-readable cycle summary
     */
    function inscribe(
        bytes32 proofHash,
        bytes32 prevHash,
        string calldata blockType,
        string calldata summary
    ) external nonReentrant whenNotPaused {
        uint256 agentId = agentIdByWallet[msg.sender];
        require(agentId != 0, "Not registered");

        Agent storage agent = agents[agentId];
        require(agent.active, "Agent inactive");
        require(
            block.timestamp >= agent.lastInscribedAt + MIN_CYCLE_INTERVAL,
            "Rate limited"
        );
        require(proofHash != bytes32(0), "Invalid proofHash");
        require(bytes(blockType).length > 0, "Empty blockType");
        require(bytes(summary).length <= 140, "Summary too long");

        // Validate chain continuity
        bytes32 expectedPrev = agent.cycleCount == 0 ? genesisChainHead : agent.chainHead;
        require(prevHash == expectedPrev, "Chain break: wrong prevHash");

        // Collect inscription fee
        uint256 treasuryAmt = (INSCRIPTION_FEE * INSCRIPTION_TREASURY_BPS) / 10000;
        uint256 epochAmt    = INSCRIPTION_FEE - treasuryAmt;
        IERC20(USDC).transferFrom(msg.sender, TREASURY, treasuryAmt);
        IERC20(USDC).transferFrom(msg.sender, address(this), epochAmt);
        epochRewardPool += epochAmt;

        // Update agent state
        agent.chainHead      = proofHash;
        agent.cycleCount++;
        agent.lastInscribedAt = block.timestamp;
        epochInscriptions++;

        emit ProofInscribed(agentId, proofHash, prevHash, blockType, summary, block.timestamp);
    }

    // ─── Validator Management ─────────────────────────────────────────────────
    /**
     * @notice Custodian approves an agent as validator. Agent must then stake 10 USDC.
     */
    function approveValidator(uint256 agentId) external onlyCustodian {
        Agent storage agent = agents[agentId];
        require(agent.wallet != address(0), "Agent not found");
        require(agent.role == AgentRole.INSCRIBER, "Not an inscriber");
        agent.role = AgentRole.VALIDATOR;
        emit ValidatorApproved(agentId, msg.sender);
    }

    /**
     * @notice Validator locks 10 USDC stake after being approved.
     */
    function lockValidatorStake() external nonReentrant {
        uint256 agentId = agentIdByWallet[msg.sender];
        require(agentId != 0, "Not registered");
        Agent storage agent = agents[agentId];
        require(agent.role == AgentRole.VALIDATOR, "Not a validator");
        require(agent.validatorStake == 0, "Already staked");

        IERC20(USDC).transferFrom(msg.sender, address(this), VALIDATOR_STAKE);
        agent.validatorStake = VALIDATOR_STAKE;
    }

    /**
     * @notice Custodian removes a validator. Stake returned if not slashed.
     */
    function removeValidator(
        uint256 agentId,
        string calldata reason,
        bool slash
    ) external onlyCustodian {
        Agent storage agent = agents[agentId];
        require(agent.role == AgentRole.VALIDATOR, "Not a validator");

        uint256 stake = agent.validatorStake;
        agent.role          = AgentRole.INSCRIBER;
        agent.validatorStake = 0;

        if (stake > 0) {
            if (slash) {
                uint256 buyback = (stake * SLASH_BUYBACK_BPS) / 10000;
                buybackPool += buyback;
                // Remaining 50% sent to custodian who called (acts as reporter reward)
                IERC20(USDC).transfer(msg.sender, stake - buyback);
            } else {
                IERC20(USDC).transfer(agent.wallet, stake);
            }
        }

        emit ValidatorRemoved(agentId, msg.sender, reason);
    }

    // ─── Attestation ─────────────────────────────────────────────────────────
    /**
     * @notice Validator attests a proof as valid or invalid.
     *         Must be called within 30 minutes of inscription.
     */
    function attest(
        uint256 agentId,
        bytes32 proofHash,
        bool valid
    ) external nonReentrant onlyValidator whenNotPaused {
        require(!hasAttested[msg.sender][proofHash], "Already attested");
        hasAttested[msg.sender][proofHash] = true;

        attestations[proofHash].push(Attestation({
            validator: msg.sender,
            valid:     valid,
            timestamp: block.timestamp
        }));

        // Collect attestation fee from inscribing agent (agent must pre-approve)
        uint256 validatorAmt = (ATTESTATION_FEE * ATTESTATION_VALIDATOR_BPS) / 10000;
        uint256 treasuryAmt  = (ATTESTATION_FEE * ATTESTATION_TREASURY_BPS)  / 10000;
        uint256 buybackAmt   = ATTESTATION_FEE - validatorAmt - treasuryAmt;

        address inscriber = agents[agentId].wallet;
        IERC20(USDC).transferFrom(inscriber, msg.sender,     validatorAmt);
        IERC20(USDC).transferFrom(inscriber, TREASURY,       treasuryAmt);
        IERC20(USDC).transferFrom(inscriber, address(this),  buybackAmt);
        buybackPool += buybackAmt;

        emit ProofAttested(agentId, proofHash, msg.sender, valid);
    }

    // ─── Equivocation Slashing ────────────────────────────────────────────────
    /**
     * @notice Report a validator who attested contradictory things for the same proof.
     *         Requires two on-chain attestation records with opposite `valid` values.
     */
    function reportEquivocation(
        address validator,
        bytes32 proofHash
    ) external nonReentrant {
        Attestation[] storage atts = attestations[proofHash];
        bool foundTrue  = false;
        bool foundFalse = false;

        for (uint256 i = 0; i < atts.length; i++) {
            if (atts[i].validator == validator) {
                if (atts[i].valid)  foundTrue  = true;
                if (!atts[i].valid) foundFalse = true;
            }
        }

        require(foundTrue && foundFalse, "No equivocation found");

        // Find validator agentId
        uint256 validatorAgentId = agentIdByWallet[validator];
        require(validatorAgentId != 0, "Validator not found");

        Agent storage vAgent = agents[validatorAgentId];
        uint256 stake = vAgent.validatorStake;
        require(stake > 0, "No stake to slash");

        // Slash
        vAgent.role           = AgentRole.INSCRIBER;
        vAgent.validatorStake  = 0;

        uint256 reporterAmt = (stake * SLASH_REPORTER_BPS) / 10000;
        uint256 buybackAmt  = stake - reporterAmt;
        IERC20(USDC).transfer(msg.sender, reporterAmt);
        buybackPool += buybackAmt;

        emit EquivocationSlashed(validator, proofHash, msg.sender, stake);
    }

    // ─── Epoch Management ────────────────────────────────────────────────────
    /**
     * @notice Close the current epoch. Either custodian can trigger.
     */
    function closeEpoch() external onlyCustodian {
        emit EpochClosed(currentEpoch, epochInscriptions, epochRewardPool);
        currentEpoch++;
        epochInscriptions = 0;
        epochRewardPool   = 0;
    }

    // ─── Buyback ─────────────────────────────────────────────────────────────
    /**
     * @notice Execute a $CUSTOS buyback using accumulated buybackPool.
     *         Uses 0x allowance-holder pattern (tested: tx 0x77ea50aa...).
     * @param usdcAmount  amount to spend from buybackPool
     * @param swapCalldata  calldata from 0x /swap/allowance-holder/quote endpoint
     */
    function executeBuyback(
        uint256 usdcAmount,
        bytes calldata swapCalldata
    ) external onlyCustodian nonReentrant {
        require(usdcAmount <= buybackPool, "Insufficient buyback pool");
        buybackPool -= usdcAmount;

        uint256 balanceBefore = IERC20(0xF3e20293514d775a3149C304820d9E6a6FA29b07).balanceOf(ECOSYSTEM_WALLET);

        IERC20(USDC).approve(ALLOWANCE_HOLDER, usdcAmount);
        (bool success,) = ALLOWANCE_HOLDER.call(swapCalldata);
        require(success, "Swap failed");

        uint256 balanceAfter = IERC20(0xF3e20293514d775a3149C304820d9E6a6FA29b07).balanceOf(ECOSYSTEM_WALLET);
        uint256 custosReceived = balanceAfter - balanceBefore;

        emit BuybackExecuted(usdcAmount, custosReceived);
    }

    // ─── Treasury ────────────────────────────────────────────────────────────
    /**
     * @notice Sweep any token balance to 0xSplits treasury.
     */
    function withdrawToTreasury(address token, uint256 amount) external onlyCustodian {
        IERC20(token).transfer(TREASURY, amount);
    }

    // ─── Pause ───────────────────────────────────────────────────────────────
    function pause()   external onlyCustodian { _pause(); }
    function unpause() external onlyCustodian { _unpause(); }

    // ─── UUPS Upgrade (2-of-2 custodian approval) ────────────────────────────
    /**
     * @notice Step 1: custodian proposes an upgrade to a new implementation.
     */
    function approveUpgrade(address newImplementation) external onlyCustodian {
        upgradeApproval[msg.sender] = newImplementation;
        emit UpgradeApproved(msg.sender, newImplementation);
    }

    /**
     * @notice Step 2: second custodian triggers the upgrade after both have approved.
     *         Both approvals must point at the same implementation address.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyCustodian {
        address other = (msg.sender == CUSTOS_WALLET) ? PIZZA_WALLET : CUSTOS_WALLET;
        require(
            upgradeApproval[other] == newImplementation &&
            upgradeApproval[msg.sender] == newImplementation,
            "Both custodians must approve same implementation"
        );
        // Clear approvals after use
        upgradeApproval[CUSTOS_WALLET] = address(0);
        upgradeApproval[PIZZA_WALLET]  = address(0);
    }

    // ─── View helpers ────────────────────────────────────────────────────────
    function getAttestations(bytes32 proofHash) external view returns (Attestation[] memory) {
        return attestations[proofHash];
    }

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return agents[agentId];
    }

    function getAgentByWallet(address wallet) external view returns (Agent memory) {
        return agents[agentIdByWallet[wallet]];
    }
}
