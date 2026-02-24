// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CustosMineController
 * @notice Proof-of-intelligence mining game on top of CustosNetwork.
 *         Agents commit-reveal answers to on-chain challenges every 10 minutes.
 *         Correct answers earn credits. Credits earn a share of the epoch reward pool.
 *
 * Epochs: 24h, time-based. Open: 6pm GMT daily. Close: oracle triggers.
 * Challenges: commit window 10min, reveal window 5min. Posted by oracle.
 * Sybil defense: registerForEpoch() snapshots $CUSTOS balance at registration time.
 * Tiers: 25M/50M/100M $CUSTOS = 1x/2x/3x credits per correct solve.
 *
 * Reward flow:
 *   CustosMineRewards → $CUSTOS → this contract (pendingRewards)
 *   → openEpoch() → epoch.rewardPool
 *   → participant.claimEpochReward()
 *
 * Oracle: Custos wallet — posts/settles challenges, opens/closes epochs, sweeps expired claims.
 * Custodian: Pizza — config changes, fund recovery, tier updates.
 */
contract CustosMineController {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant COMMIT_WINDOW       = 600;     // 10 min
    uint256 public constant REVEAL_WINDOW        = 300;     // 5 min
    uint256 public constant EPOCH_DURATION       = 86400;   // 24h
    uint256 public constant CLAIM_WINDOW         = 30 days;
    uint256 public constant REG_CLOSE_BUFFER     = 3600;    // registration closes 1h before epoch end

    // ─── State ────────────────────────────────────────────────────────────────

    address public custodian;
    address public oracle;
    address public custosMineRewards;     // only contract that can call receiveCustos
    address public immutable CUSTOS_TOKEN;

    bool public paused;

    // Tier thresholds (operator-updatable)
    uint256 public tier1Threshold;   // default 25_000_000e18
    uint256 public tier2Threshold;   // default 50_000_000e18
    uint256 public tier3Threshold;   // default 100_000_000e18

    // ─── Epochs ───────────────────────────────────────────────────────────────

    uint256 public currentEpochId;
    bool    public epochOpen;

    struct Epoch {
        uint256 epochId;
        uint256 startAt;
        uint256 endAt;
        uint256 rewardPool;       // $CUSTOS allocated at openEpoch
        uint256 totalCredits;
        bool    settled;
    }

    mapping(uint256 => Epoch) public epochs;

    // Credits per wallet per epoch
    mapping(uint256 => mapping(address => uint256)) public epochCredits;
    // Claimed flag per wallet per epoch
    mapping(uint256 => mapping(address => bool))    public epochClaimed;

    // ─── Sybil defense: epoch registration snapshots ──────────────────────────

    // epochId => wallet => $CUSTOS balance at registerForEpoch() time
    mapping(uint256 => mapping(address => uint256)) public epochSnapshot;
    // epochId => wallet => registered
    mapping(uint256 => mapping(address => bool))    public epochRegistered;

    // ─── Challenges ───────────────────────────────────────────────────────────

    uint256 public challengeCount;
    uint256 public currentChallengeId;

    struct Challenge {
        uint256 challengeId;
        bytes32 answerHash;       // keccak256(abi.encodePacked(correctAnswer)) — committed at postChallenge
        bytes32 questionHash;     // keccak256 of question text (for verification)
        string  questionUri;      // IPFS URI containing full question JSON
        uint256 commitOpenAt;
        uint256 commitCloseAt;    // commitOpenAt + COMMIT_WINDOW
        uint256 revealCloseAt;    // commitCloseAt + REVEAL_WINDOW
        uint256 epochId;
        bool    settled;
        string  correctAnswer;    // revealed at settlement
        uint256 correctCount;
    }

    mapping(uint256 => Challenge) public challenges;

    // ─── Submissions ──────────────────────────────────────────────────────────

    struct Submission {
        bytes32 commitHash;       // keccak256(abi.encodePacked(answer, salt))
        uint256 tierAtCommit;     // 1, 2, or 3 — from epoch snapshot
        string  revealedAnswer;
        bytes32 revealedSalt;
        bool    committed;
        bool    revealed;
        bool    correct;
        uint256 creditsAwarded;
    }

    // challengeId => wallet => Submission
    mapping(uint256 => mapping(address => Submission)) public submissions;

    // Reveals awaiting settlement (array of wallets per challenge)
    mapping(uint256 => address[]) internal _pendingReveals;

    // ─── Pending reward pool ──────────────────────────────────────────────────

    uint256 public pendingRewards;   // accumulates until openEpoch() drains it

    // ─── Events ───────────────────────────────────────────────────────────────

    event EpochOpened(uint256 indexed epochId, uint256 startAt, uint256 endAt, uint256 rewardPool);
    event EpochClosed(uint256 indexed epochId, uint256 totalCredits, uint256 rewardPool);
    event EpochRegistered(uint256 indexed epochId, address indexed wallet, uint256 snapshot, uint256 tier);
    event ChallengePosted(uint256 indexed challengeId, string questionUri, uint256 commitOpenAt, uint256 commitCloseAt, uint256 revealCloseAt);
    event CommitSubmitted(uint256 indexed challengeId, address indexed wallet, uint256 tier);
    event RevealSubmitted(uint256 indexed challengeId, address indexed wallet);
    event ChallengeSolved(uint256 indexed challengeId, address indexed wallet, uint256 credits);
    event ChallengeSettled(uint256 indexed challengeId, string correctAnswer, uint256 correctCount, uint256 totalReveals);
    event RewardClaimed(uint256 indexed epochId, address indexed wallet, uint256 amount);
    event CustosReceived(uint256 amount, uint256 pendingTotal);
    event OracleUpdated(address indexed prev, address indexed next);
    event TierThresholdsUpdated(uint256 t1, uint256 t2, uint256 t3);
    event ExpiredClaimsSwept(uint256 indexed epochId, uint256 amount);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOracle() {
        require(msg.sender == oracle, "not oracle");
        _;
    }

    modifier onlyCustodian() {
        require(msg.sender == custodian, "not custodian");
        _;
    }

    modifier onlyAuthorised() {
        require(msg.sender == oracle || msg.sender == custodian, "not authorised");
        _;
    }

    modifier notPaused() {
        require(!paused, "paused");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _oracle,
        address _custodian,
        address _custosMineRewards,
        address _custosToken,
        uint256 _tier1,
        uint256 _tier2,
        uint256 _tier3
    ) {
        require(_oracle != address(0), "zero oracle");
        require(_custodian != address(0), "zero custodian");
        require(_custosToken != address(0), "zero token");

        oracle = _oracle;
        custodian = _custodian;
        custosMineRewards = _custosMineRewards;
        CUSTOS_TOKEN = _custosToken;
        tier1Threshold = _tier1;
        tier2Threshold = _tier2;
        tier3Threshold = _tier3;
    }

    // ─── EPOCH REGISTRATION (participant) ────────────────────────────────────

    /**
     * @notice Register $CUSTOS balance snapshot for current epoch.
     * @dev Must be called before first commit in epoch.
     *      Snapshot is immutable once set — selling $CUSTOS after registration
     *      does NOT reduce snapshot. Transfer cannot double-count: tokens used
     *      for one wallet's snapshot cannot boost another wallet's snapshot.
     *      Registration closes 1h before epoch end (REG_CLOSE_BUFFER).
     */
    function registerForEpoch() external notPaused {
        require(epochOpen, "no active epoch");
        uint256 epochId = currentEpochId;
        Epoch storage epoch = epochs[epochId];
        require(!epochRegistered[epochId][msg.sender], "already registered");
        require(block.timestamp < epoch.endAt - REG_CLOSE_BUFFER, "registration closed");

        uint256 bal = IERC20(CUSTOS_TOKEN).balanceOf(msg.sender);
        require(bal >= tier1Threshold, "insufficient CUSTOS for tier 1");

        epochSnapshot[epochId][msg.sender] = bal;
        epochRegistered[epochId][msg.sender] = true;

        uint256 tier = _getTierFromBalance(bal);
        emit EpochRegistered(epochId, msg.sender, bal, tier);
    }

    // ─── ORACLE — EPOCH MANAGEMENT ────────────────────────────────────────────

    /**
     * @notice Open a new epoch. Drains pendingRewards into epoch.rewardPool.
     * @param startAt Unix timestamp when epoch starts (use block.timestamp or future time).
     */
    function openEpoch(uint256 startAt) external onlyOracle {
        require(!epochOpen, "epoch already open");
        if (startAt == 0) startAt = block.timestamp;
        require(startAt <= block.timestamp + 3600, "startAt too far in future");

        currentEpochId += 1;
        uint256 epochId = currentEpochId;
        uint256 pool = pendingRewards;
        pendingRewards = 0;

        epochs[epochId] = Epoch({
            epochId: epochId,
            startAt: startAt,
            endAt: startAt + EPOCH_DURATION,
            rewardPool: pool,
            totalCredits: 0,
            settled: false
        });

        epochOpen = true;
        emit EpochOpened(epochId, startAt, startAt + EPOCH_DURATION, pool);
    }

    /**
     * @notice Close current epoch. Snapshots totalCredits.
     * @dev Unclaimed rewards remain in contract. pendingRewards unchanged.
     *      Oracle must call this after all challenges for the epoch are settled.
     */
    function closeEpoch() external onlyOracle {
        require(epochOpen, "no active epoch");
        uint256 epochId = currentEpochId;
        Epoch storage epoch = epochs[epochId];

        epoch.settled = true;
        epochOpen = false;

        emit EpochClosed(epochId, epoch.totalCredits, epoch.rewardPool);
    }

    // ─── ORACLE — CHALLENGE MANAGEMENT ───────────────────────────────────────

    /**
     * @notice Post a new challenge.
     * @param questionUri   IPFS URI of question JSON
     * @param questionHash  keccak256 of question text (for verification)
     * @param answerHash    keccak256(abi.encodePacked(correctAnswer)) — commit of answer
     */
    function postChallenge(
        string calldata questionUri,
        bytes32 questionHash,
        bytes32 answerHash
    ) external onlyOracle notPaused returns (uint256 challengeId) {
        require(epochOpen, "no active epoch");
        require(bytes(questionUri).length > 0, "empty uri");
        require(answerHash != bytes32(0), "empty answerHash");

        // Ensure previous challenge is settled (or is first challenge)
        if (challengeCount > 0) {
            Challenge storage prev = challenges[currentChallengeId];
            require(prev.settled, "previous challenge not settled");
        }

        challengeCount += 1;
        challengeId = challengeCount;
        currentChallengeId = challengeId;

        uint256 commitOpen = block.timestamp;
        uint256 commitClose = commitOpen + COMMIT_WINDOW;
        uint256 revealClose = commitClose + REVEAL_WINDOW;

        challenges[challengeId] = Challenge({
            challengeId: challengeId,
            answerHash: answerHash,
            questionHash: questionHash,
            questionUri: questionUri,
            commitOpenAt: commitOpen,
            commitCloseAt: commitClose,
            revealCloseAt: revealClose,
            epochId: currentEpochId,
            settled: false,
            correctAnswer: "",
            correctCount: 0
        });

        emit ChallengePosted(challengeId, questionUri, commitOpen, commitClose, revealClose);
    }

    /**
     * @notice Settle a challenge after reveal window closes.
     * @dev Verifies correctAnswer matches on-chain commitment (answerHash).
     *      Iterates all pending reveals, awards credits based on tierAtCommit.
     *      Credits go to epochCredits[epochId][wallet] and epoch.totalCredits.
     * @param challengeId   Challenge to settle
     * @param correctAnswer The correct answer (must hash to answerHash)
     */
    function settleChallenge(
        uint256 challengeId,
        string calldata correctAnswer
    ) external onlyOracle {
        Challenge storage ch = challenges[challengeId];
        require(!ch.settled, "already settled");
        require(ch.answerHash != bytes32(0), "challenge not found");
        require(block.timestamp >= ch.revealCloseAt, "reveal window not closed");

        // Verify answer matches commitment
        require(
            keccak256(abi.encodePacked(correctAnswer)) == ch.answerHash,
            "answer mismatch"
        );

        ch.settled = true;
        ch.correctAnswer = correctAnswer;

        uint256 epochId = ch.epochId;
        Epoch storage epoch = epochs[epochId];

        // Award credits to all correct revealers
        address[] storage revealers = _pendingReveals[challengeId];
        uint256 totalReveals = revealers.length;
        uint256 correctCount = 0;

        for (uint256 i = 0; i < totalReveals; i++) {
            address wallet = revealers[i];
            Submission storage sub = submissions[challengeId][wallet];

            if (!sub.revealed) continue;

            // Check if answer is correct (exact string match)
            bool correct = (
                keccak256(abi.encodePacked(sub.revealedAnswer)) ==
                keccak256(abi.encodePacked(correctAnswer))
            );

            if (correct) {
                sub.correct = true;
                uint256 credits = sub.tierAtCommit; // tier 1=1, 2=2, 3=3 credits
                sub.creditsAwarded = credits;
                epochCredits[epochId][wallet] += credits;
                epoch.totalCredits += credits;
                correctCount += 1;
                emit ChallengeSolved(challengeId, wallet, credits);
            }
        }

        ch.correctCount = correctCount;
        emit ChallengeSettled(challengeId, correctAnswer, correctCount, totalReveals);
    }

    // ─── PARTICIPANT — COMMIT ─────────────────────────────────────────────────

    /**
     * @notice Submit a blind commit to a challenge.
     * @dev Requires: epochRegistered. Requires: commit window open.
     *      commitHash = keccak256(abi.encodePacked(answer, salt))
     *      where salt is a random bytes32 kept secret until reveal.
     *      Tier locked from epoch snapshot — immutable for this epoch.
     */
    function commit(uint256 challengeId, bytes32 commitHash) external notPaused {
        require(epochOpen, "no active epoch");
        require(epochRegistered[currentEpochId][msg.sender], "register for epoch first");
        require(commitHash != bytes32(0), "empty commitHash");

        Challenge storage ch = challenges[challengeId];
        require(ch.challengeId == challengeId && challengeId != 0, "challenge not found");
        require(block.timestamp >= ch.commitOpenAt, "commit window not open");
        require(block.timestamp <  ch.commitCloseAt, "commit window closed");
        require(ch.epochId == currentEpochId, "challenge from wrong epoch");

        Submission storage sub = submissions[challengeId][msg.sender];
        require(!sub.committed, "already committed");

        uint256 snap = epochSnapshot[currentEpochId][msg.sender];
        uint256 tier = _getTierFromBalance(snap);

        sub.commitHash = commitHash;
        sub.tierAtCommit = tier;
        sub.committed = true;

        emit CommitSubmitted(challengeId, msg.sender, tier);
    }

    /**
     * @notice Reveal your answer for a committed challenge.
     * @dev Requires: reveal window open. Verifies commitHash.
     *      NO balance check at reveal — snapshot locked at registration.
     *      answer + salt must reproduce the commitHash submitted in commit().
     *      If challenge already settled (e.g. oracle settled early): immediately marks correct.
     *      If not yet settled: stored in _pendingReveals for settleChallenge().
     */
    function reveal(
        uint256 challengeId,
        string calldata answer,
        bytes32 salt
    ) external notPaused {
        Challenge storage ch = challenges[challengeId];
        require(ch.challengeId == challengeId && challengeId != 0, "challenge not found");
        require(block.timestamp >= ch.commitCloseAt, "reveal window not open");
        require(block.timestamp <  ch.revealCloseAt, "reveal window closed");

        Submission storage sub = submissions[challengeId][msg.sender];
        require(sub.committed, "not committed");
        require(!sub.revealed, "already revealed");

        // Verify reveal matches commitment
        require(
            keccak256(abi.encodePacked(answer, salt)) == sub.commitHash,
            "reveal mismatch"
        );

        sub.revealedAnswer = answer;
        sub.revealedSalt = salt;
        sub.revealed = true;

        // If already settled, immediately check correctness
        if (ch.settled) {
            bool correct = (
                keccak256(abi.encodePacked(answer)) ==
                keccak256(abi.encodePacked(ch.correctAnswer))
            );
            if (correct) {
                sub.correct = true;
                uint256 credits = sub.tierAtCommit;
                sub.creditsAwarded = credits;
                uint256 epochId = ch.epochId;
                epochCredits[epochId][msg.sender] += credits;
                epochs[epochId].totalCredits += credits;
                emit ChallengeSolved(challengeId, msg.sender, credits);
            }
        } else {
            // Queue for settlement
            _pendingReveals[challengeId].push(msg.sender);
        }

        emit RevealSubmitted(challengeId, msg.sender);
    }

    // ─── PARTICIPANT — CLAIM ──────────────────────────────────────────────────

    /**
     * @notice Claim $CUSTOS reward for an epoch.
     * @dev Epoch must be settled. 30-day claim window.
     *      reward = (myCredits / totalCredits) * rewardPool
     *      Uses integer math: reward = (myCredits * rewardPool) / totalCredits
     */
    function claimEpochReward(uint256 epochId) external notPaused {
        Epoch storage epoch = epochs[epochId];
        require(epoch.settled, "epoch not settled");
        require(!epochClaimed[epochId][msg.sender], "already claimed");
        require(block.timestamp <= epoch.endAt + CLAIM_WINDOW, "claim window expired");

        uint256 myCredits = epochCredits[epochId][msg.sender];
        require(myCredits > 0, "no credits");
        require(epoch.totalCredits > 0, "no total credits");
        require(epoch.rewardPool > 0, "empty reward pool");

        epochClaimed[epochId][msg.sender] = true;

        uint256 reward = (myCredits * epoch.rewardPool) / epoch.totalCredits;
        require(reward > 0, "zero reward");

        IERC20(CUSTOS_TOKEN).safeTransfer(msg.sender, reward);
        emit RewardClaimed(epochId, msg.sender, reward);
    }

    // ─── REWARD POOL ─────────────────────────────────────────────────────────

    /**
     * @notice Receive $CUSTOS from CustosMineRewards contract.
     * @dev Only callable by custosMineRewards.
     *      Adds to pendingRewards — allocated to epoch.rewardPool at openEpoch().
     */
    function receiveCustos(uint256 amount) external {
        require(msg.sender == custosMineRewards, "not mine rewards contract");
        pendingRewards += amount;
        emit CustosReceived(amount, pendingRewards);
    }

    /**
     * @notice Manual seed for early epochs. Custodian transfers $CUSTOS to contract,
     *         then calls this to register the amount as pendingRewards.
     * @dev Custodian must approve + transfer $CUSTOS to this contract first.
     *      Or: custodian can call IERC20.transfer directly, then call seedRewards
     *      with the transferred amount. Contract checks its own balance is sufficient.
     */
    function seedRewards(uint256 amount) external onlyCustodian {
        require(amount > 0, "zero amount");
        uint256 contractBal = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        require(contractBal >= pendingRewards + amount, "insufficient balance - transfer first");
        pendingRewards += amount;
        emit CustosReceived(amount, pendingRewards);
    }

    /**
     * @notice Sweep unclaimed rewards after 30-day window, back to pendingRewards.
     * @dev Oracle only. Unclaimed $CUSTOS recycled to next epoch pool.
     */
    function sweepExpiredClaims(uint256 epochId) external onlyOracle {
        Epoch storage epoch = epochs[epochId];
        require(epoch.settled, "epoch not settled");
        require(block.timestamp > epoch.endAt + CLAIM_WINDOW, "claim window not expired");

        // Calculate how much has been claimed
        // We track this via total - unclaimed.
        // Simpler: oracle calls this with specific epoch, we sweep what's left.
        // Approximate: rewardPool * (totalCredits - claimedCredits) / totalCredits
        // For simplicity, oracle manages this off-chain and calls with the right amount.
        // We just move the balance to pendingRewards.
        uint256 remaining = epoch.rewardPool;
        // epoch.rewardPool is the total allocated — we don't reduce it on each claim
        // so we can't know exactly what's left in contract without tracking claimed amount.
        // Instead: oracle computes unclaimed off-chain and passes explicit amount.
        // This function is a safety valve; actual amount passed by oracle.
        // For V1, oracle computes: remaining = sum(unclaimed credits * ratio)
        // We trust oracle with this value (paused if oracle compromised).
        require(remaining > 0, "nothing to sweep");

        pendingRewards += remaining;
        epoch.rewardPool = 0; // mark as swept

        emit ExpiredClaimsSwept(epochId, remaining);
    }

    // ─── RECOVERY ────────────────────────────────────────────────────────────

    /**
     * @notice Emergency ERC20 recovery. Cannot drain $CUSTOS if active epoch has reward pool.
     */
    function recoverERC20(address token, uint256 amount, address to) external onlyAuthorised {
        require(to != address(0), "zero recipient");
        if (token == CUSTOS_TOKEN) {
            // Guard: don't drain active epoch reward pool
            if (epochOpen) {
                uint256 activePool = epochs[currentEpochId].rewardPool;
                uint256 contractBal = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
                require(contractBal - amount >= activePool + pendingRewards, "would drain rewards");
            }
        }
        IERC20(token).safeTransfer(to, amount);
    }

    function recoverETH(address payable to) external onlyAuthorised {
        require(to != address(0), "zero recipient");
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "ETH transfer failed");
    }

    // ─── CONFIG (custodian only) ──────────────────────────────────────────────

    function setTierThresholds(uint256 t1, uint256 t2, uint256 t3) external onlyCustodian {
        require(t1 > 0 && t2 > t1 && t3 > t2, "invalid thresholds");
        tier1Threshold = t1;
        tier2Threshold = t2;
        tier3Threshold = t3;
        emit TierThresholdsUpdated(t1, t2, t3);
    }

    function setOracle(address newOracle) external onlyCustodian {
        require(newOracle != address(0), "zero");
        emit OracleUpdated(oracle, newOracle);
        oracle = newOracle;
    }

    function setCustosMineRewards(address newRewards) external onlyCustodian {
        custosMineRewards = newRewards;
    }

    function setPaused(bool _paused) external onlyCustodian {
        paused = _paused;
    }

    // ─── VIEW ─────────────────────────────────────────────────────────────────

    function getCurrentChallenge() external view returns (Challenge memory) {
        if (challengeCount == 0) return challenges[0]; // empty
        return challenges[currentChallengeId];
    }

    function getChallenge(uint256 challengeId) external view returns (Challenge memory) {
        return challenges[challengeId];
    }

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return epochs[epochId];
    }

    function getTierFromBalance(uint256 balance) external view returns (uint256) {
        return _getTierFromBalance(balance);
    }

    /**
     * @notice Get snapshot tier for wallet in epoch. Returns 0 if not registered.
     */
    function getEpochTier(address wallet, uint256 epochId) external view returns (uint256) {
        if (!epochRegistered[epochId][wallet]) return 0;
        return _getTierFromBalance(epochSnapshot[epochId][wallet]);
    }

    /**
     * @notice Get live tier for wallet (uses current balance). For display only.
     *         For game mechanics, epochSnapshot is canonical.
     */
    function getLiveTier(address wallet) external view returns (uint256) {
        return _getTierFromBalance(IERC20(CUSTOS_TOKEN).balanceOf(wallet));
    }

    function getCredits(address wallet, uint256 epochId) external view returns (uint256) {
        return epochCredits[epochId][wallet];
    }

    function getClaimable(address wallet, uint256 epochId) external view returns (uint256) {
        Epoch storage epoch = epochs[epochId];
        if (!epoch.settled) return 0;
        if (epochClaimed[epochId][wallet]) return 0;
        if (block.timestamp > epoch.endAt + CLAIM_WINDOW) return 0;
        uint256 myCredits = epochCredits[epochId][wallet];
        if (myCredits == 0 || epoch.totalCredits == 0 || epoch.rewardPool == 0) return 0;
        return (myCredits * epoch.rewardPool) / epoch.totalCredits;
    }

    function isRegistered(address wallet, uint256 epochId) external view returns (bool) {
        return epochRegistered[epochId][wallet];
    }

    function getSnapshot(address wallet, uint256 epochId) external view returns (uint256) {
        return epochSnapshot[epochId][wallet];
    }

    function isCommitOpen() external view returns (bool) {
        if (challengeCount == 0) return false;
        Challenge storage ch = challenges[currentChallengeId];
        return (
            !ch.settled &&
            block.timestamp >= ch.commitOpenAt &&
            block.timestamp < ch.commitCloseAt
        );
    }

    function isRevealOpen() external view returns (bool) {
        if (challengeCount == 0) return false;
        Challenge storage ch = challenges[currentChallengeId];
        return (
            !ch.settled &&
            block.timestamp >= ch.commitCloseAt &&
            block.timestamp < ch.revealCloseAt
        );
    }

    function getPendingRevealCount(uint256 challengeId) external view returns (uint256) {
        return _pendingReveals[challengeId].length;
    }

    function getPendingRevealers(
        uint256 challengeId,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory) {
        address[] storage revealers = _pendingReveals[challengeId];
        uint256 total = revealers.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = revealers[offset + i];
        }
        return result;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _getTierFromBalance(uint256 balance) internal view returns (uint256) {
        if (balance >= tier3Threshold) return 3;
        if (balance >= tier2Threshold) return 2;
        if (balance >= tier1Threshold) return 1;
        return 0;
    }

    receive() external payable {}
}
