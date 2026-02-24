// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title CustosMineController v2
 * @notice Proof-of-intelligence mining via CustosNetwork inscriptions.
 *
 * Agents participate by inscribing on CustosNetworkProxy each loop:
 *   blockType:   "mine-commit"  (loop N)   contentHash = keccak256(answer|salt)
 *   blockType:   "mine-reveal"  (loop N+1) contentHash = keccak256(answer|salt|commitInscriptionId)
 *
 * Each 10-min loop an agent calls ONE of:
 *   registerCommit(roundId, inscriptionId)                              — round 1 only
 *   registerCommitReveal(roundIdN, insIdN, roundIdN1, answer, salt)    — rounds 2-139
 *   registerReveal(roundId, answer, salt)                              — round 140 only
 *
 * On-chain verification in registerCommitReveal / registerReveal:
 *   keccak256(abi.encodePacked(answer, salt)) == proxy.inscriptionContentHash(commitInscriptionId)
 *
 * Oracle role: postRound() + settleRound() only. No commit/reveal handling.
 *
 * Error codes (E01-E62):
 *   E10 No epoch    E11 Already open   E12 Not staked    E13 Below tier1
 *   E14 Bad window  E15 Already done   E16 Wrong agent   E17 Hash mismatch
 *   E18 Too many    E19 Not revealed   E20 Not settled   E21 Claimed
 *   E22 Expired     E23 No credits     E24 Not oracle    E25 Not custodian
 *   E26 Not owner   E27 Paused        E28 Reentrant     E29 Zero addr
 *   E30 Zero amt    E31 Bad tiers     E32 Snapshot pend  E33 Snap done
 *   E34 Bad batch   E35 Credits pend   E36 No stakers    E37 No stake
 *   E38 No queue    E39 Not ended     E40 Bad round     E41 No rewards
 *   E42 Slippage    E43 Deadline      E44 Only rewards   E45 Gap
 *   E46 No ETH      E47 ETH fail      E48 Insufficient   E49 No unclaimed
 *   E50 Snap not done E51 Not expired  E52 Batch settling E53 Empty batch
 *   E54 Cross epoch  E55 Snap cursor   E56 Bad epoch dur  E57 No commit
 *   E58 Wrong round  E59 Zero insId   E60 Not mine insId E61 Insid agent  E62 commit window
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal interface to CustosNetworkProxy for inscription verification
interface ICustosProxy {
    function inscriptionContentHash(uint256 inscriptionId) external view returns (bytes32);
    function inscriptionAgent(uint256 inscriptionId) external view returns (address);
    function agentIdByWallet(address wallet) external view returns (uint256);
}

contract CustosMineController {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant COMMIT_WINDOW         = 600;
    uint256 public constant REVEAL_WINDOW         = 600;
    uint256 public constant EPOCH_DURATION        = 86400;
    uint256 public constant CLAIM_WINDOW          = 30 days;
    uint256 public constant MAX_REVEALERS_PER_ROUND = 500;
    uint256 public constant ROUNDS_PER_EPOCH      = 140;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;
    uint256 private _reentrancyStatus;

    // ============ State ============
    address public owner;
    mapping(address => bool) public custodians;
    address public oracle;
    address public custosMineRewards;
    address public immutable CUSTOS_TOKEN;
    address public immutable CUSTOS_PROXY;

    bool    public paused;
    bool    public epochOpen;
    uint256 public currentEpochId;
    uint256 public roundCount;
    /// @dev $CUSTOS staged here between receipt and next epoch open. Moves to epoch.rewardPool at openEpoch().
    uint256 public rewardBuffer;

    uint256 public tier1Threshold;
    uint256 public tier2Threshold;
    uint256 public tier3Threshold;
    uint256 public pendingTier1;
    uint256 public pendingTier2;
    uint256 public pendingTier3;
    bool    public tierChangePending;

    struct StakePosition {
        uint256 amount;
        bool    withdrawalQueued;
        uint256 unstakeEpochId;
        uint256 stakedIndex;
    }
    mapping(address => StakePosition) public stakes;
    address[] public stakedAgents;
    mapping(address => bool) public isStaked;

    mapping(uint256 => mapping(address => uint256)) public tierSnapshot;

    struct Epoch {
        uint256 epochId;
        uint256 startAt;
        uint256 endAt;
        uint256 rewardPool;
        uint256 totalCredits;
        bool    settled;
        uint256 claimDeadline;
    }

    struct Round {
        uint256 roundId;
        uint256 epochId;
        uint256 commitOpenAt;
        uint256 commitCloseAt;
        uint256 revealCloseAt;
        bytes32 answerHash;
        string  questionUri;
        bool    settled;
        bool    expired;
        bool    batchSettling;
        string  revealedAnswer;
        uint256 correctCount;
        uint256 revealCount;
    }

    /// @dev Per-agent per-round: stores commitInscriptionId and revealed answer
    struct Submission {
        uint256 commitInscriptionId; // inscriptionId from agent's mine-commit inscription
        string  revealedAnswer;
        bool    committed;
        bool    revealed;
        bool    credited;
    }

    mapping(uint256 => Epoch)                              public epochs;
    mapping(uint256 => Round)                              public rounds;
    mapping(uint256 => mapping(address => Submission))    public submissions;
    mapping(uint256 => address[])                         internal _pendingReveals;

    mapping(uint256 => mapping(address => uint256)) public epochCredits;
    mapping(uint256 => mapping(address => bool))    public epochClaimed;
    mapping(uint256 => uint256)                     public epochClaimedAmount;

    uint256 public snapshotCursor;
    bool    public snapshotComplete;
    uint256 public creditCursor;

    // ============ Events ============
    event EpochOpened(uint256 indexed epochId, uint256 startAt, uint256 endAt, uint256 rewardPool);
    event EpochClosed(uint256 indexed epochId, uint256 totalCredits, uint256 rewardPool);
    event RoundPosted(uint256 indexed roundId, string questionUri, uint256 commitOpenAt, uint256 commitCloseAt, uint256 revealCloseAt);
    event CommitRegistered(uint256 indexed roundId, address indexed wallet, uint256 inscriptionId);
    event RevealRegistered(uint256 indexed roundId, address indexed wallet);
    event RoundSolved(uint256 indexed roundId, address indexed wallet, uint256 credits);
    event RoundSettled(uint256 indexed roundId, string correctAnswer, uint256 correctCount, uint256 totalReveals);
    event RoundExpired(uint256 indexed roundId);
    event RewardClaimed(uint256 indexed epochId, address indexed wallet, uint256 amount);
    event Staked(address indexed wallet, uint256 amount, uint256 tier);
    event Unstaked(address indexed wallet, uint256 indexed epochId);
    event UnstakeCancelled(address indexed wallet);
    event StakeWithdrawn(address indexed wallet, uint256 amount);
    event CustosReceived(uint256 amount, uint256 pendingTotal);
    event TierThresholdsUpdated(uint256 t1, uint256 t2, uint256 t3);
    event PendingTierThresholdsSet(uint256 t1, uint256 t2, uint256 t3);
    event ExpiredClaimsSwept(uint256 indexed epochId, uint256 amount);
    event OracleUpdated(address indexed prev, address indexed next);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event CustodianSet(address indexed account, bool enabled);
    event MineRewardsUpdated(address indexed prev, address indexed next);
    event Paused();
    event Unpaused();

    // ============ Modifiers ============
    modifier onlyOwner()      { require(msg.sender == owner,           "E26"); _; }
    modifier onlyCustodian()  { require(custodians[msg.sender],        "E25"); _; }
    modifier onlyOracle()     { require(msg.sender == oracle,          "E24"); _; }
    modifier notPaused()      { require(!paused,                       "E27"); _; }
    modifier nonReentrant()   {
        require(_reentrancyStatus != _ENTERED, "E28");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ============ Constructor ============
    constructor(
        address _custosToken,
        address _custosProxy,
        address _custosMineRewards,
        address _oracle,
        uint256 _tier1,
        uint256 _tier2,
        uint256 _tier3
    ) {
        require(_custosToken  != address(0), "E29");
        require(_custosProxy  != address(0), "E29");
        require(_oracle       != address(0), "E29");
        require(_tier1 > 0 && _tier1 < _tier2 && _tier2 < _tier3, "E31");

        owner             = msg.sender;
        CUSTOS_TOKEN      = _custosToken;
        CUSTOS_PROXY      = _custosProxy;
        custosMineRewards = _custosMineRewards;
        oracle            = _oracle;
        tier1Threshold    = _tier1;
        tier2Threshold    = _tier2;
        tier3Threshold    = _tier3;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ============ Staking ============

    function stake(uint256 amount) external notPaused nonReentrant {
        require(amount >= tier1Threshold, "E13");
        IERC20(CUSTOS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        StakePosition storage pos = stakes[msg.sender];
        pos.amount += amount;
        if (!isStaked[msg.sender]) {
            isStaked[msg.sender]  = true;
            pos.stakedIndex       = stakedAgents.length;
            stakedAgents.push(msg.sender);
        }
        emit Staked(msg.sender, amount, _getTier(pos.amount));
    }

    function unstake() external notPaused {
        require(isStaked[msg.sender],              "E37");
        require(!stakes[msg.sender].withdrawalQueued, "E15");
        stakes[msg.sender].withdrawalQueued = true;
        stakes[msg.sender].unstakeEpochId   = currentEpochId;
        emit Unstaked(msg.sender, currentEpochId);
    }

    function cancelUnstake() external notPaused {
        require(stakes[msg.sender].withdrawalQueued, "E38");
        stakes[msg.sender].withdrawalQueued = false;
        stakes[msg.sender].unstakeEpochId   = 0;
        emit UnstakeCancelled(msg.sender);
    }

    function withdrawStake() external nonReentrant {
        StakePosition storage pos = stakes[msg.sender];
        require(pos.amount > 0,             "E37");
        require(pos.withdrawalQueued,       "E38");
        uint256 ue = pos.unstakeEpochId;
        if (ue == 0) {
            require(!epochOpen && currentEpochId > 0, "E39");
        } else {
            require(!epochOpen && epochs[ue].settled, "E39");
        }
        uint256 amount = pos.amount;
        pos.amount           = 0;
        pos.withdrawalQueued = false;
        pos.unstakeEpochId   = 0;
        isStaked[msg.sender] = false;
        if (pos.stakedIndex != type(uint256).max) {
            _removeFromStakedAgents(msg.sender);
        } else {
            pos.stakedIndex = 0;
        }
        IERC20(CUSTOS_TOKEN).safeTransfer(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount);
    }

    function _removeFromStakedAgents(address wallet) internal {
        uint256 idx  = stakes[wallet].stakedIndex;
        uint256 last = stakedAgents.length - 1;
        if (idx != last) {
            address moved        = stakedAgents[last];
            stakedAgents[idx]    = moved;
            stakes[moved].stakedIndex = idx;
        }
        stakedAgents.pop();
        stakes[wallet].stakedIndex = 0;
    }

    // ============ Participation — CustosNetwork inscription-based ============

    /**
     * @notice Round 1 only — register a commit inscription, nothing to reveal yet.
     * @param roundId         Must be round 1 of the epoch (roundCount == 1)
     * @param inscriptionId   The inscriptionId from agent's "mine-commit" inscription this loop
     *
     * Agent must have already called proxy.inscribe() this loop with:
     *   blockType:   "mine-commit"
     *   contentHash: keccak256(abi.encodePacked(answer_for_roundId, salt))
     */
    function registerCommit(
        uint256 roundId,
        uint256 inscriptionId
    ) external notPaused {
        _validateCommit(roundId, inscriptionId);
        Submission storage sub = submissions[roundId][msg.sender];
        sub.commitInscriptionId = inscriptionId;
        sub.committed           = true;
        emit CommitRegistered(roundId, msg.sender, inscriptionId);
    }

    /**
     * @notice Rounds 2-139 — commit to roundIdCommit AND reveal roundIdReveal in one tx.
     * @param roundIdCommit   Current round N (commit window open)
     * @param inscriptionId   inscriptionId from agent's "mine-commit" inscription this loop
     * @param roundIdReveal   Previous round N-1 (reveal window open)
     * @param answer          Plaintext answer for roundIdReveal
     * @param salt            Salt used when committing to roundIdReveal
     *
     * Verification: keccak256(answer|salt) must match the contentHash stored on-chain
     * for the commit inscription registered in roundIdReveal.
     */
    function registerCommitReveal(
        uint256 roundIdCommit,
        uint256 inscriptionId,
        uint256 roundIdReveal,
        string calldata answer,
        bytes32 salt
    ) external notPaused {
        require(roundIdReveal + 1 == roundIdCommit, "E45");
        _validateCommit(roundIdCommit, inscriptionId);
        _validateReveal(roundIdReveal, answer, salt);

        // Store commit
        Submission storage subC = submissions[roundIdCommit][msg.sender];
        subC.commitInscriptionId = inscriptionId;
        subC.committed           = true;

        // Store reveal
        Submission storage subR = submissions[roundIdReveal][msg.sender];
        subR.revealedAnswer = answer;
        subR.revealed       = true;
        _pendingReveals[roundIdReveal].push(msg.sender);

        emit CommitRegistered(roundIdCommit, msg.sender, inscriptionId);
        emit RevealRegistered(roundIdReveal, msg.sender);
    }

    /**
     * @notice Round 140 only — reveal previous round, no new commit needed.
     * @param roundId   Round N-1 to reveal (must be in reveal window)
     * @param answer    Plaintext answer
     * @param salt      Salt used at commit time
     */
    function registerReveal(
        uint256 roundId,
        string calldata answer,
        bytes32 salt
    ) external notPaused {
        _validateReveal(roundId, answer, salt);
        Submission storage sub = submissions[roundId][msg.sender];
        sub.revealedAnswer = answer;
        sub.revealed       = true;
        _pendingReveals[roundId].push(msg.sender);
        emit RevealRegistered(roundId, msg.sender);
    }

    // ── internal validation helpers ────────────────────────────────────

    function _validateCommit(uint256 roundId, uint256 inscriptionId) internal view {
        require(epochOpen,                                    "E10");
        require(snapshotComplete,                             "E50");
        require(inscriptionId != 0,                          "E59");
        Round storage r = rounds[roundId];
        require(r.roundId == roundId && r.epochId == currentEpochId, "E58");
        require(
            block.timestamp >= r.commitOpenAt &&
            block.timestamp <  r.commitCloseAt,              "E62");
        require(!r.settled && !r.expired,                    "E40");
        require(tierSnapshot[currentEpochId][msg.sender] > 0,"E12");
        require(!submissions[roundId][msg.sender].committed, "E15");

        // Verify inscription belongs to this agent on CustosProxy
        require(
            ICustosProxy(CUSTOS_PROXY).inscriptionAgent(inscriptionId) == msg.sender,
            "E61"
        );
        // contentHash must be non-zero (inscription exists)
        require(
            ICustosProxy(CUSTOS_PROXY).inscriptionContentHash(inscriptionId) != bytes32(0),
            "E60"
        );
    }

    function _validateReveal(
        uint256 roundId,
        string calldata answer,
        bytes32 salt
    ) internal view {
        Round storage r = rounds[roundId];
        require(r.roundId == roundId && r.epochId == currentEpochId, "E58");
        require(
            block.timestamp >= r.commitCloseAt &&
            block.timestamp <  r.revealCloseAt,              "E14");
        require(!r.settled && !r.expired,                    "E40");
        require(tierSnapshot[currentEpochId][msg.sender] > 0,"E12");

        Submission storage sub = submissions[roundId][msg.sender];
        require(sub.committed,  "E57");
        require(!sub.revealed,  "E15");
        require(
            _pendingReveals[roundId].length < MAX_REVEALERS_PER_ROUND,
            "E18"
        );

        // ── On-chain verification ────────────────────────────────────
        // Agent's commit inscription contentHash = keccak256(answer|salt)
        bytes32 expected = ICustosProxy(CUSTOS_PROXY)
            .inscriptionContentHash(sub.commitInscriptionId);
        require(expected != bytes32(0), "E60");
        require(
            keccak256(abi.encodePacked(answer, salt)) == expected,
            "E17"
        );
    }

    // ============ Claim ============

    function claimEpochReward(uint256 epochId) external nonReentrant {
        Epoch storage ep = epochs[epochId];
        require(ep.settled,                         "E20");
        require(!epochClaimed[epochId][msg.sender], "E21");
        require(block.timestamp <= ep.claimDeadline,"E22");
        uint256 credits = epochCredits[epochId][msg.sender];
        require(credits > 0,                        "E23");
        epochClaimed[epochId][msg.sender]  = true;
        uint256 reward = (ep.rewardPool * credits) / ep.totalCredits;
        epochClaimedAmount[epochId]       += reward;
        IERC20(CUSTOS_TOKEN).safeTransfer(msg.sender, reward);
        emit RewardClaimed(epochId, msg.sender, reward);
    }

    // ============ Oracle ============

    function postRound(string calldata questionUri, bytes32 answerHash)
        external onlyOracle returns (uint256 roundId)
    {
        require(epochOpen,        "E10");
        require(snapshotComplete, "E50");
        require(roundCount < ROUNDS_PER_EPOCH, "E40");

        roundId = ++roundCount;
        uint256 now_ = block.timestamp;
        rounds[roundId] = Round({
            roundId:       roundId,
            epochId:       currentEpochId,
            commitOpenAt:  now_,
            commitCloseAt: now_ + COMMIT_WINDOW,
            revealCloseAt: now_ + COMMIT_WINDOW + REVEAL_WINDOW,
            answerHash:    answerHash,
            questionUri:   questionUri,
            settled:       false,
            expired:       false,
            batchSettling: false,
            revealedAnswer: "",
            correctCount:  0,
            revealCount:   0
        });
        emit RoundPosted(roundId, questionUri, now_, now_ + COMMIT_WINDOW, now_ + COMMIT_WINDOW + REVEAL_WINDOW);
    }

    function settleRound(uint256 roundId, string calldata correctAnswer)
        external onlyOracle
    {
        Round storage r = rounds[roundId];
        require(!r.settled && !r.expired,  "E40");
        require(!r.batchSettling,          "E52");
        require(block.timestamp >= r.revealCloseAt, "E14");
        require(r.answerHash == keccak256(abi.encodePacked(correctAnswer)), "E17");

        address[] storage pending = _pendingReveals[roundId];
        uint256 len = pending.length;
        require(len <= MAX_REVEALERS_PER_ROUND, "E53");

        uint256 epochId = r.epochId;
        for (uint256 i = 0; i < len; i++) {
            address wallet = pending[i];
            Submission storage sub = submissions[roundId][wallet];
            if (!sub.revealed || sub.credited) continue;
            if (keccak256(abi.encodePacked(sub.revealedAnswer)) ==
                keccak256(abi.encodePacked(correctAnswer)))
            {
                sub.credited = true;
                uint256 tier = tierSnapshot[epochId][wallet];
                uint256 credits = tier; // tier1=1, tier2=2, tier3=3
                epochCredits[epochId][wallet] += credits;
                r.correctCount++;
                emit RoundSolved(roundId, wallet, credits);
            }
        }

        r.revealedAnswer = correctAnswer;
        r.revealCount    = len;
        r.settled        = true;
        delete _pendingReveals[roundId];
        emit RoundSettled(roundId, correctAnswer, r.correctCount, len);
    }

    function settleBatch(
        uint256 roundId,
        uint256 start,
        uint256 end,
        string calldata correctAnswer
    ) external onlyOracle {
        Round storage r = rounds[roundId];
        require(!r.settled && !r.expired, "E40");
        require(block.timestamp >= r.revealCloseAt, "E14");
        require(r.answerHash == keccak256(abi.encodePacked(correctAnswer)), "E17");
        require(start < end, "E34");

        address[] storage pending = _pendingReveals[roundId];
        require(end <= pending.length, "E34");

        if (!r.batchSettling) r.batchSettling = true;

        uint256 epochId = r.epochId;
        for (uint256 i = start; i < end; i++) {
            address wallet = pending[i];
            Submission storage sub = submissions[roundId][wallet];
            if (!sub.revealed || sub.credited) continue;
            if (keccak256(abi.encodePacked(sub.revealedAnswer)) ==
                keccak256(abi.encodePacked(correctAnswer)))
            {
                sub.credited = true;
                uint256 credits = tierSnapshot[epochId][wallet];
                epochCredits[epochId][wallet] += credits;
                r.correctCount++;
                emit RoundSolved(roundId, wallet, credits);
            }
        }

        if (end == pending.length) {
            r.revealedAnswer = correctAnswer;
            r.revealCount    = pending.length;
            r.settled        = true;
            r.batchSettling  = false;
            delete _pendingReveals[roundId];
            emit RoundSettled(roundId, correctAnswer, r.correctCount, r.revealCount);
        }
    }

    function expireRound(uint256 roundId) external {
        Round storage r = rounds[roundId];
        require(!r.settled && !r.expired,          "E40");
        require(block.timestamp > r.revealCloseAt + 300, "E51");
        r.expired = true;
        delete _pendingReveals[roundId];
        emit RoundExpired(roundId);
    }



    // ============ Epoch Lifecycle ============

    function openEpoch(uint256 startAt) external onlyOracle {
        require(!epochOpen, "E11");
        // Move staged rewards into this epoch's pool
        uint256 rewardPool = rewardBuffer;
        rewardBuffer = 0;
        uint256 epochId = ++currentEpochId;
        epochs[epochId] = Epoch({
            epochId:      epochId,
            startAt:      startAt,
            endAt:        startAt + EPOCH_DURATION,
            rewardPool:   rewardPool,
            totalCredits: 0,
            settled:      false,
            claimDeadline: startAt + EPOCH_DURATION + CLAIM_WINDOW
        });
        epochOpen        = true;
        snapshotCursor   = 0;
        snapshotComplete = stakedAgents.length == 0;
        roundCount       = 0;
        emit EpochOpened(epochId, startAt, startAt + EPOCH_DURATION, rewardPool);
    }

    function snapshotBatch(uint256 batchSize) external onlyOracle {
        require(epochOpen,          "E10");
        require(!snapshotComplete,  "E33");
        require(batchSize > 0,      "E34");
        uint256 epochId = currentEpochId;
        uint256 t1 = tier1Threshold;
        uint256 t2 = tier2Threshold;
        uint256 t3 = tier3Threshold;
        uint256 cursor = snapshotCursor;
        uint256 total  = stakedAgents.length;
        uint256 end    = cursor + batchSize;
        if (end > total) end = total;
        for (uint256 i = cursor; i < end; i++) {
            address wallet = stakedAgents[i];
            if (stakes[wallet].withdrawalQueued) continue;
            tierSnapshot[epochId][wallet] = _computeTier(stakes[wallet].amount, t1, t2, t3);
        }
        snapshotCursor = end;
        if (end == total) snapshotComplete = true;
    }

    function closeEpoch() external onlyOracle {
        require(epochOpen, "E10");
        creditCursor = 0;
    }

    function accumulateCreditsBatch(uint256 batchSize) external onlyOracle {
        require(epochOpen,     "E10");
        require(batchSize > 0, "E34");
        uint256 epochId = currentEpochId;
        uint256 cursor  = creditCursor;
        uint256 total   = stakedAgents.length;
        uint256 end     = cursor + batchSize;
        if (end > total) end = total;
        Epoch storage ep = epochs[epochId];
        for (uint256 i = cursor; i < end; i++) {
            ep.totalCredits += epochCredits[epochId][stakedAgents[i]];
        }
        creditCursor = end;
    }

    function finalizeClose() external onlyOracle {
        require(epochOpen,                         "E10");
        require(creditCursor >= stakedAgents.length, "E35");
        Epoch storage ep = epochs[currentEpochId];
        ep.settled = true;
        if (tierChangePending) {
            tier1Threshold  = pendingTier1;
            tier2Threshold  = pendingTier2;
            tier3Threshold  = pendingTier3;
            tierChangePending = false;
            emit TierThresholdsUpdated(tier1Threshold, tier2Threshold, tier3Threshold);
        }
        uint256 i = 0;
        while (i < stakedAgents.length) {
            address wallet = stakedAgents[i];
            if (stakes[wallet].withdrawalQueued) {
                _removeFromStakedAgents(wallet);
                stakes[wallet].stakedIndex = type(uint256).max;
            } else {
                i++;
            }
        }
        epochOpen        = false;
        snapshotComplete = false;
        creditCursor     = 0;
        snapshotCursor   = 0;
        emit EpochClosed(currentEpochId, ep.totalCredits, ep.rewardPool);
    }

    /// @notice After the 30-day claim window, unclaimed $CUSTOS rolls into the next epoch's reward pool.
    /// @dev Tokens stay in this contract — they move from expired epoch accounting into rewardBuffer.
    function sweepExpiredClaims(uint256 epochId) external onlyOracle {
        require(epochs[epochId].settled,                   "E20");
        require(block.timestamp > epochs[epochId].claimDeadline, "E43");
        uint256 unclaimed = epochs[epochId].rewardPool - epochClaimedAmount[epochId];
        require(unclaimed > 0, "E49");
        epochClaimedAmount[epochId] = epochs[epochId].rewardPool;
        rewardBuffer += unclaimed;
        emit ExpiredClaimsSwept(epochId, unclaimed);
    }

    // ============ Admin ============

    function receiveCustos(uint256 amount) external {
        require(custosMineRewards != address(0), "E29");
        require(msg.sender == custosMineRewards, "E44");
        rewardBuffer += amount;
        emit CustosReceived(amount, rewardBuffer);
    }

    /// @notice Pull $CUSTOS from caller into the reward buffer for the next epoch.
    function depositRewards(uint256 amount) external onlyCustodian {
        require(amount > 0, "E30");
        IERC20(CUSTOS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        rewardBuffer += amount;
        emit CustosReceived(amount, rewardBuffer);
    }

    /// @notice Mark already-held $CUSTOS (e.g. received via receiveCustos) as staged for the next epoch.
    /// @dev Only allocates from free balance — cannot touch staked tokens or the current epoch's pool.
    function allocateRewards(uint256 amount) external onlyCustodian {
        require(amount > 0, "E30");
        uint256 bal = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        uint256 locked = rewardBuffer;
        if (epochOpen) locked += epochs[currentEpochId].rewardPool;
        for (uint256 i = 0; i < stakedAgents.length; i++) locked += stakes[stakedAgents[i]].amount;
        require(bal >= locked + amount, "E48");
        rewardBuffer += amount;
        emit CustosReceived(amount, rewardBuffer);
    }

    function recoverERC20(address token, uint256 amount, address to) external onlyCustodian {
        require(to != address(0), "E29");
        uint256 protected = 0;
        if (token == CUSTOS_TOKEN) {
            protected = rewardBuffer;
            if (epochOpen) protected += epochs[currentEpochId].rewardPool;
            for (uint256 i = 0; i < stakedAgents.length; i++) protected += stakes[stakedAgents[i]].amount;
        }
        require(IERC20(token).balanceOf(address(this)) >= protected + amount, "E48");
        IERC20(token).safeTransfer(to, amount);
    }

    function recoverETH(address payable to) external onlyCustodian {
        require(to != address(0), "E29");
        uint256 bal = address(this).balance;
        require(bal > 0, "E46");
        (bool ok,) = to.call{value: bal}("");
        require(ok, "E47");
    }

    function setOracle(address newOracle) external onlyCustodian {
        require(newOracle != address(0), "E29");
        address prev = oracle;
        oracle = newOracle;
        emit OracleUpdated(prev, newOracle);
    }

    function setCustosMineRewards(address newRewards) external onlyOwner {
        require(newRewards != address(0), "E29");
        address prev = custosMineRewards;
        custosMineRewards = newRewards;
        emit MineRewardsUpdated(prev, newRewards);
    }

    function setTierThresholds(uint256 t1, uint256 t2, uint256 t3) external onlyCustodian {
        require(t1 < t2 && t2 < t3, "E31");
        pendingTier1 = t1; pendingTier2 = t2; pendingTier3 = t3;
        tierChangePending = true;
        emit PendingTierThresholdsSet(t1, t2, t3);
    }

    function setCustodian(address account, bool enabled) external onlyOwner {
        require(account != address(0), "E29");
        custodians[account] = enabled;
        emit CustodianSet(account, enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "E29");
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    function pause()   external onlyCustodian { paused = true;  emit Paused(); }
    function unpause() external onlyCustodian { paused = false; emit Unpaused(); }

    // ============ View ============

    function getCurrentRound() external view returns (Round memory) {
        if (roundCount == 0) return Round(0,0,0,0,0,bytes32(0),"",false,false,false,"",0,0);
        return rounds[roundCount];
    }
    function getRound(uint256 roundId)   external view returns (Round memory)  { return rounds[roundId]; }
    function getEpoch(uint256 epochId)   external view returns (Epoch memory)  { return epochs[epochId]; }
    function getStake(address wallet)    external view returns (StakePosition memory) { return stakes[wallet]; }
    function getTierSnapshot(address w, uint256 e) external view returns (uint256) { return tierSnapshot[e][w]; }
    function getCredits(address w, uint256 e)      external view returns (uint256) { return epochCredits[e][w]; }
    function getStakedAgentCount()       external view returns (uint256) { return stakedAgents.length; }
    function getPendingRevealCount(uint256 roundId) external view returns (uint256) { return _pendingReveals[roundId].length; }

    function getClaimable(address wallet, uint256 epochId) external view returns (uint256) {
        if (epochClaimed[epochId][wallet]) return 0;
        Epoch storage ep = epochs[epochId];
        if (!ep.settled || block.timestamp > ep.claimDeadline) return 0;
        uint256 credits = epochCredits[epochId][wallet];
        if (credits == 0 || ep.totalCredits == 0) return 0;
        return (ep.rewardPool * credits) / ep.totalCredits;
    }

    function getSubmission(uint256 roundId, address wallet) external view returns (Submission memory) {
        return submissions[roundId][wallet];
    }

    // ============ Internal ============

    function _computeTier(uint256 amount, uint256 t1, uint256 t2, uint256 t3)
        internal pure returns (uint256)
    {
        if (amount >= t3) return 3;
        if (amount >= t2) return 2;
        if (amount >= t1) return 1;
        return 0;
    }

    function _getTier(uint256 amount) internal view returns (uint256) {
        return _computeTier(amount, tier1Threshold, tier2Threshold, tier3Threshold);
    }

    receive() external payable {
        require(msg.sender == custosMineRewards, "E44");
    }
}
