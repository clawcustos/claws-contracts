// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title CustosMineController v3
 * @notice Proof-of-Agent-Work (PoAW) mining via CustosNetworkProxy v0.5.7 inscriptions.
 *
 * v3 design: oracle-verified settlement, no agent-side commit/reveal registration.
 *
 * Flow per 10-min round:
 *   1. Agent calls proxy.inscribe(blockType="mine-commit", contentHash=keccak256(answer|salt), roundId=N)
 *   2. Agent calls proxy.reveal(inscriptionId, answer, salt)  — within reveal window
 *   3. Oracle calls settleRound(roundId, correctAnswer, inscriptionIds[])
 *      — 5 on-chain checks per inscriptionId:
 *        (a) inscriptionBlockType == "mine-commit"
 *        (b) inscriptionRoundId   == roundId
 *        (c) tierSnapshot[wallet] > 0  (staked in this epoch)
 *        (d) inscriptionRevealTime within round's reveal window
 *        (e) revealed content == correctAnswer
 *
 * Key design decisions:
 *   - wallet is the join key. No agentId on MineController.
 *   - staking does NOT require prior inscription. proxy auto-registers on first inscribe().
 *   - roundId is globally unique, never resets across epochs.
 *   - oracle passes inscriptionIds[], MineController verifies everything on-chain.
 *   - No Submission struct, no _pendingReveals, no agent-side registerCommit/reveal calls.
 *
 * Error codes:
 *   E10 No epoch    E11 Already open   E12 Not staked    E13 Below tier1
 *   E14 Bad window  E15 Already done   E20 Not settled   E21 Claimed
 *   E22 Expired     E23 No credits     E24 Not oracle    E25 Not custodian
 *   E26 Not owner   E27 Paused        E28 Reentrant     E29 Zero addr
 *   E30 Zero amt    E31 Bad tiers     E33 Snap done     E34 Bad batch
 *   E35 Credits pend E36 No stakers   E37 No stake      E38 No queue
 *   E39 Not ended   E40 Bad round     E41 No rewards    E42 Slippage
 *   E43 Deadline    E44 Only rewards  E45 Gap           E46 No ETH
 *   E47 ETH fail    E48 Insufficient  E49 No unclaimed  E50 Snap not done
 *   E51 Not expired E63 Swap failed   E64 Closing
 *   E65 Wrong type  E66 Wrong round   E67 Reveal window E68 Wrong answer
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Interface to CustosNetworkProxy v0.5.7
interface ICustosProxy {
    function inscriptionBlockType(uint256 inscriptionId)    external view returns (string memory);
    function inscriptionRevealTime(uint256 inscriptionId)   external view returns (uint256);
    function inscriptionRoundId(uint256 inscriptionId)      external view returns (uint256);
    function inscriptionAgent(uint256 inscriptionId)        external view returns (address);
    function getInscriptionContent(uint256 inscriptionId)
        external view returns (bool revealed, string memory content, bytes32 contentHash);
}

contract CustosMineControllerV3 {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant COMMIT_WINDOW           = 600;   // 10 min
    uint256 public constant REVEAL_WINDOW           = 600;   // 10 min
    uint256 public constant EPOCH_DURATION          = 86400; // 24 h
    uint256 public constant CLAIM_WINDOW            = 30 days;
    uint256 public constant ROUNDS_PER_EPOCH        = 140;
    uint256 public constant MAX_SETTLERS_PER_ROUND  = 500;

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
    bool    public epochClosing;
    uint256 public currentEpochId;
    uint256 public roundCount;
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
        string  revealedAnswer;
        uint256 correctCount;
    }

    mapping(uint256 => Epoch)  public epochs;
    mapping(uint256 => Round)  public rounds;

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
    event RoundSettled(uint256 indexed roundId, string correctAnswer, uint256 correctCount);
    event RoundExpired(uint256 indexed roundId);
    event RoundSolved(uint256 indexed roundId, address indexed wallet, uint256 credits);
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

    modifier onlyOwner()     { require(msg.sender == owner,        "E26"); _; }
    modifier onlyCustodian() { require(custodians[msg.sender],     "E25"); _; }
    modifier onlyOracle()    { require(msg.sender == oracle,       "E24"); _; }
    modifier notPaused()     { require(!paused,                    "E27"); _; }
    modifier nonReentrant()  {
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
        require(_custosToken != address(0), "E29");
        require(_custosProxy != address(0), "E29");
        require(_oracle      != address(0), "E29");
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
            isStaked[msg.sender] = true;
            pos.stakedIndex      = stakedAgents.length;
            stakedAgents.push(msg.sender);
        }
        emit Staked(msg.sender, amount, _getTier(pos.amount));
    }

    function unstake() external notPaused {
        require(isStaked[msg.sender],                "E37");
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
        require(pos.amount > 0,       "E37");
        require(pos.withdrawalQueued, "E38");
        uint256 ue = pos.unstakeEpochId;
        if (ue == 0) {
            require(!epochOpen && currentEpochId > 0, "E39");
        } else {
            require(!epochOpen && epochs[ue].settled, "E39");
        }
        uint256 amount       = pos.amount;
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
            address moved             = stakedAgents[last];
            stakedAgents[idx]         = moved;
            stakes[moved].stakedIndex = idx;
        }
        stakedAgents.pop();
        stakes[wallet].stakedIndex = 0;
    }

    // ============ Oracle — Round Lifecycle ============

    /**
     * @notice Post a new round. answerHash = keccak256(abi.encodePacked(correctAnswer)).
     *         Oracle reveals correctAnswer at settleRound() — commit-reveal for oracle too.
     */
    function postRound(string calldata questionUri, bytes32 answerHash)
        external onlyOracle returns (uint256 roundId)
    {
        require(epochOpen,         "E10");
        require(!epochClosing,     "E64");
        require(snapshotComplete,  "E50");
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
            revealedAnswer: "",
            correctCount:  0
        });
        emit RoundPosted(roundId, questionUri, now_, now_ + COMMIT_WINDOW, now_ + COMMIT_WINDOW + REVEAL_WINDOW);
    }

    /**
     * @notice Settle a round. Oracle provides correctAnswer and the list of inscriptionIds to check.
     *         For each inscriptionId, 5 on-chain checks are performed:
     *           (a) inscriptionBlockType == "mine-commit"
     *           (b) inscriptionRoundId   == roundId
     *           (c) tierSnapshot[wallet] > 0  (staked at epoch snapshot)
     *           (d) inscriptionRevealTime within [commitCloseAt, revealCloseAt]
     *           (e) revealed content == correctAnswer
     *         Passing all 5 earns tier credits for that wallet.
     * @param roundId        The round to settle.
     * @param correctAnswer  Plaintext answer (verified against answerHash).
     * @param inscriptionIds List of proxy inscriptionIds to evaluate. Oracle-provided, verified on-chain.
     */
    function settleRound(
        uint256 roundId,
        string calldata correctAnswer,
        uint256[] calldata inscriptionIds
    ) external onlyOracle {
        Round storage r = rounds[roundId];
        require(r.roundId == roundId,                              "E40");
        require(r.epochId == currentEpochId,                      "E40");
        require(!r.settled && !r.expired,                         "E40");
        require(block.timestamp >= r.revealCloseAt,               "E14");
        require(
            r.answerHash == keccak256(abi.encodePacked(correctAnswer)),
            "E68"
        );
        require(inscriptionIds.length <= MAX_SETTLERS_PER_ROUND,  "E34");

        ICustosProxy proxy       = ICustosProxy(CUSTOS_PROXY);
        uint256      epochId     = r.epochId;
        uint256      correctCount = 0;
        uint256      commitClose  = r.commitCloseAt;
        uint256      revealClose  = r.revealCloseAt;

        for (uint256 i = 0; i < inscriptionIds.length; i++) {
            uint256 insId = inscriptionIds[i];

            // (a) blockType must be "mine-commit"
            if (keccak256(bytes(proxy.inscriptionBlockType(insId))) !=
                keccak256(bytes("mine-commit"))) continue;

            // (b) roundId must match
            if (proxy.inscriptionRoundId(insId) != roundId) continue;

            // (c) wallet must be in tier snapshot for this epoch
            address wallet = proxy.inscriptionAgent(insId);
            uint256 tier   = tierSnapshot[epochId][wallet];
            if (tier == 0) continue;

            // (d) reveal must have happened within the reveal window
            uint256 revealTime = proxy.inscriptionRevealTime(insId);
            if (revealTime < commitClose || revealTime >= revealClose) continue;

            // (e) revealed content must match correctAnswer
            (bool revealed, string memory content,) = proxy.getInscriptionContent(insId);
            if (!revealed) continue;
            if (keccak256(bytes(content)) != keccak256(bytes(correctAnswer))) continue;

            // All 5 checks passed — award tier credits
            epochCredits[epochId][wallet] += tier;
            correctCount++;
            emit RoundSolved(roundId, wallet, tier);
        }

        r.revealedAnswer = correctAnswer;
        r.correctCount   = correctCount;
        r.settled        = true;

        emit RoundSettled(roundId, correctAnswer, correctCount);
    }

    function expireRound(uint256 roundId) external {
        Round storage r = rounds[roundId];
        require(!r.settled && !r.expired,             "E40");
        require(block.timestamp > r.revealCloseAt + 300, "E51");
        r.expired = true;
        emit RoundExpired(roundId);
    }

    // ============ Epoch Lifecycle ============

    function openEpoch(uint256 startAt) external onlyOracle {
        require(!epochOpen, "E11");
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
        require(epochOpen,         "E10");
        require(!snapshotComplete, "E33");
        require(batchSize > 0,     "E34");
        uint256 epochId = currentEpochId;
        uint256 t1      = tier1Threshold;
        uint256 t2      = tier2Threshold;
        uint256 t3      = tier3Threshold;
        uint256 cursor  = snapshotCursor;
        uint256 total   = stakedAgents.length;
        uint256 end     = cursor + batchSize > total ? total : cursor + batchSize;
        for (uint256 i = cursor; i < end; i++) {
            address wallet = stakedAgents[i];
            if (stakes[wallet].withdrawalQueued) continue;
            tierSnapshot[epochId][wallet] = _computeTier(stakes[wallet].amount, t1, t2, t3);
        }
        snapshotCursor = end;
        if (end == total) snapshotComplete = true;
    }

    function closeEpoch() external onlyOracle {
        require(epochOpen,     "E10");
        require(!epochClosing, "E11");
        epochClosing = true;
        creditCursor = 0;
    }

    function accumulateCreditsBatch(uint256 batchSize) external onlyOracle {
        require(epochOpen,     "E10");
        require(batchSize > 0, "E34");
        uint256 epochId = currentEpochId;
        uint256 cursor  = creditCursor;
        uint256 total   = stakedAgents.length;
        uint256 end     = cursor + batchSize > total ? total : cursor + batchSize;
        Epoch storage ep = epochs[epochId];
        for (uint256 i = cursor; i < end; i++) {
            ep.totalCredits += epochCredits[epochId][stakedAgents[i]];
        }
        creditCursor = end;
    }

    function finalizeClose() external onlyOracle {
        require(epochClosing,                        "E10");
        require(creditCursor >= stakedAgents.length, "E35");
        Epoch storage ep = epochs[currentEpochId];
        ep.settled = true;
        if (tierChangePending) {
            tier1Threshold    = pendingTier1;
            tier2Threshold    = pendingTier2;
            tier3Threshold    = pendingTier3;
            tierChangePending = false;
            emit TierThresholdsUpdated(tier1Threshold, tier2Threshold, tier3Threshold);
        }
        epochOpen        = false;
        epochClosing     = false;
        snapshotComplete = false;
        creditCursor     = 0;
        snapshotCursor   = 0;
        emit EpochClosed(currentEpochId, ep.totalCredits, ep.rewardPool);
    }

    function pruneExitedStakers(uint256 batchSize) external onlyOracle {
        require(!epochOpen, "E11");
        require(batchSize > 0, "E34");
        uint256 i = 0;
        uint256 removed = 0;
        while (i < stakedAgents.length && removed < batchSize) {
            address wallet = stakedAgents[i];
            if (stakes[wallet].withdrawalQueued) {
                _removeFromStakedAgents(wallet);
                stakes[wallet].stakedIndex = type(uint256).max;
                removed++;
            } else {
                i++;
            }
        }
    }

    // ============ Claim ============

    function claimEpochReward(uint256 epochId) external nonReentrant {
        Epoch storage ep = epochs[epochId];
        require(ep.settled,                         "E20");
        require(!epochClaimed[epochId][msg.sender], "E21");
        require(block.timestamp <= ep.claimDeadline, "E22");
        uint256 credits = epochCredits[epochId][msg.sender];
        require(credits > 0,                        "E23");
        epochClaimed[epochId][msg.sender] = true;
        uint256 reward = (ep.rewardPool * credits) / ep.totalCredits;
        epochClaimedAmount[epochId] += reward;
        IERC20(CUSTOS_TOKEN).safeTransfer(msg.sender, reward);
        emit RewardClaimed(epochId, msg.sender, reward);
    }

    function sweepExpiredClaims(uint256 epochId) external onlyOracle {
        require(epochs[epochId].settled,                       "E20");
        require(block.timestamp > epochs[epochId].claimDeadline, "E43");
        uint256 unclaimed = epochs[epochId].rewardPool - epochClaimedAmount[epochId];
        require(unclaimed > 0, "E49");
        epochClaimedAmount[epochId] = epochs[epochId].rewardPool;
        rewardBuffer += unclaimed;
        emit ExpiredClaimsSwept(epochId, unclaimed);
    }

    // ============ Reward Ingestion ============

    function receiveCustos(uint256 amount) external nonReentrant {
        require(custosMineRewards != address(0), "E29");
        require(msg.sender == custosMineRewards, "E44");
        rewardBuffer += amount;
        emit CustosReceived(amount, rewardBuffer);
    }

    function depositRewards(uint256 amount) external onlyCustodian {
        require(amount > 0, "E30");
        IERC20(CUSTOS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        rewardBuffer += amount;
        emit CustosReceived(amount, rewardBuffer);
    }

    function allocateRewards(uint256 amount) external onlyCustodian {
        require(amount > 0, "E30");
        uint256 bal    = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        uint256 locked = rewardBuffer;
        if (epochOpen) locked += epochs[currentEpochId].rewardPool;
        for (uint256 i = 0; i < stakedAgents.length; i++) locked += stakes[stakedAgents[i]].amount;
        require(bal >= locked + amount, "E48");
        rewardBuffer += amount;
        emit CustosReceived(amount, rewardBuffer);
    }

    // ============ Admin ============

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
        if (roundCount == 0) return Round({ roundId: 0, epochId: 0, commitOpenAt: 0, commitCloseAt: 0, revealCloseAt: 0, answerHash: bytes32(0), questionUri: "", settled: false, expired: false, revealedAnswer: "", correctCount: 0 });
        return rounds[roundCount];
    }
    function getRound(uint256 roundId)  external view returns (Round memory)         { return rounds[roundId]; }
    function getEpoch(uint256 epochId)  external view returns (Epoch memory)         { return epochs[epochId]; }
    function getStake(address wallet)   external view returns (StakePosition memory) { return stakes[wallet]; }
    function getTierSnapshot(address w, uint256 e) external view returns (uint256)   { return tierSnapshot[e][w]; }
    function getCredits(address w, uint256 e)      external view returns (uint256)   { return epochCredits[e][w]; }
    function getStakedAgentCount()      external view returns (uint256)              { return stakedAgents.length; }

    function getClaimable(address wallet, uint256 epochId) external view returns (uint256) {
        if (epochClaimed[epochId][wallet]) return 0;
        Epoch storage ep = epochs[epochId];
        if (!ep.settled || block.timestamp > ep.claimDeadline) return 0;
        uint256 credits = epochCredits[epochId][wallet];
        if (credits == 0 || ep.totalCredits == 0) return 0;
        return (ep.rewardPool * credits) / ep.totalCredits;
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
