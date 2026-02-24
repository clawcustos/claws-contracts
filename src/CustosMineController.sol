// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title CustosMineController
 * @notice Staking-based mining controller for $CUSTOS token rewards
 * 
 * Flow:
 * 0xSplits R&D → CustosMineRewards (WETH)
 *   → swapAndSend() → $CUSTOS → receiveCustos() → pendingRewards
 *   → openEpoch() → epoch.rewardPool + tier snapshots taken
 *   → 140 rounds: postRound / commit / reveal / settleRound (10min loops)
 *   → closeEpoch() → epoch.settled, pending tiers applied
 *   → claimEpochReward() → $CUSTOS to participant
 *   → sweepExpiredClaims() → unclaimed → pendingRewards → next epoch
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice CustosMineController manages staking, epochs, rounds, and reward distribution
contract CustosMineController {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant COMMIT_WINDOW = 600;
    uint256 public constant REVEAL_WINDOW = 300;
    uint256 public constant EPOCH_DURATION = 86400;
    uint256 public constant CLAIM_WINDOW = 30 days;
    uint256 public constant MAX_REVEALERS_PER_ROUND = 500;

    // Reentrancy guard
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    // ============ State Variables ============
    address public owner;
    mapping(address => bool) public custodians;
    address public oracle;
    address public custosMineRewards;
    address public immutable CUSTOS_TOKEN;

    bool public paused;
    bool public epochOpen;
    uint256 public currentEpochId;
    uint256 public roundCount;
    uint256 public pendingRewards;

    // Tier thresholds
    uint256 public tier1Threshold;
    uint256 public tier2Threshold;
    uint256 public tier3Threshold;
    uint256 public pendingTier1;
    uint256 public pendingTier2;
    uint256 public pendingTier3;
    bool public tierChangePending;

    // Staking
    struct StakePosition {
        uint256 amount;
        bool withdrawalQueued;
        uint256 unstakeEpochId;
    }
    mapping(address => StakePosition) public stakes;
    address[] public stakedAgents;
    mapping(address => bool) public isStaked;

    // Snapshots: epochId => wallet => tier
    mapping(uint256 => mapping(address => uint256)) public tierSnapshot;

    // Epochs + Rounds + Submissions
    struct Epoch {
        uint256 epochId;
        uint256 startAt;
        uint256 endAt;
        uint256 rewardPool;
        uint256 totalCredits;
        bool settled;
        uint256 claimDeadline;
    }
    struct Round {
        uint256 roundId;
        uint256 epochId;
        uint256 commitOpenAt;
        uint256 commitCloseAt;
        uint256 revealCloseAt;
        bytes32 answerHash; // immutable after postRound
        string questionUri;
        bool settled;
        bool expired;
        bool batchSettling; // true while settleBatch is in progress
        string revealedAnswer;
        uint256 correctCount;
        uint256 revealCount;
    }
    struct Submission {
        bytes32 commitHash;
        string revealedAnswer;
        bool committed;
        bool revealed;
        bool credited;
        uint256 tierAtCommit;
    }

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => Submission)) public submissions;
    mapping(uint256 => address[]) internal _pendingReveals;

    // Credits + Claims
    mapping(uint256 => mapping(address => uint256)) public epochCredits;
    mapping(uint256 => mapping(address => bool)) public epochClaimed;
    mapping(uint256 => uint256) public epochClaimedAmount;

    // ============ Events ============
    event EpochOpened(uint256 indexed epochId, uint256 startAt, uint256 endAt, uint256 rewardPool);
    event EpochClosed(uint256 indexed epochId, uint256 totalCredits, uint256 rewardPool);
    event RoundPosted(uint256 indexed roundId, string questionUri, uint256 commitOpenAt, uint256 commitCloseAt, uint256 revealCloseAt);
    event CommitSubmitted(uint256 indexed roundId, address indexed wallet, uint256 tier);
    event RevealSubmitted(uint256 indexed roundId, address indexed wallet);
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
    modifier onlyOwner() {
        require(msg.sender == owner, "Ownable: caller is not owner");
        _;
    }

    modifier onlyCustodian() {
        require(custodians[msg.sender], "Not custodian");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "Not oracle");
        _;
    }

    modifier onlyAuthorised() {
        require(msg.sender == oracle || custodians[msg.sender], "Not authorised");
        _;
    }

    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ============ Constructor ============
    constructor(
        address _custosToken,
        address _custosMineRewards,
        address _oracle,
        uint256 _tier1,
        uint256 _tier2,
        uint256 _tier3
    ) {
        owner = msg.sender;
        CUSTOS_TOKEN = _custosToken;
        custosMineRewards = _custosMineRewards;
        oracle = _oracle;
        
        tier1Threshold = _tier1;
        tier2Threshold = _tier2;
        tier3Threshold = _tier3;
        
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ============ Staking Functions ============
    
    /**
     * @notice Stake $CUSTOS tokens to participate in mining
     * @param amount Amount of tokens to stake (must be >= tier1Threshold)
     */
    function stake(uint256 amount) external notPaused nonReentrant {
        require(amount >= tier1Threshold, "Amount below tier1");
        
        IERC20(CUSTOS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        
        StakePosition storage position = stakes[msg.sender];
        position.amount += amount;
        
        if (!isStaked[msg.sender]) {
            isStaked[msg.sender] = true;
            stakedAgents.push(msg.sender);
        }
        
        uint256 tier = _getTierFromBalance(position.amount);
        emit Staked(msg.sender, amount, tier);
    }

    /**
     * @notice Queue stake for withdrawal at end of current epoch
     */
    function unstake() external notPaused {
        require(isStaked[msg.sender], "Not staked");
        require(!stakes[msg.sender].withdrawalQueued, "Already queued");
        
        stakes[msg.sender].withdrawalQueued = true;
        stakes[msg.sender].unstakeEpochId = currentEpochId;
        
        emit Unstaked(msg.sender, currentEpochId);
    }

    /**
     * @notice Cancel pending withdrawal
     */
    function cancelUnstake() external notPaused {
        require(stakes[msg.sender].withdrawalQueued, "No withdrawal queued");
        
        stakes[msg.sender].withdrawalQueued = false;
        stakes[msg.sender].unstakeEpochId = 0;
        
        emit UnstakeCancelled(msg.sender);
    }

    /**
     * @notice Withdraw stake after unstake epoch has ended
     */
    function withdrawStake() external nonReentrant {
        StakePosition storage position = stakes[msg.sender];
        require(position.amount > 0, "No stake");
        require(position.withdrawalQueued, "No withdrawal queued");
        
        uint256 unstakeEpoch = position.unstakeEpochId;
        // Must wait until the epoch queued for has ended:
        // - If unstakeEpoch == 0 (queued before first epoch), wait until epoch 1 is closed
        // - If unstakeEpoch > 0, wait until that epoch's endAt has passed AND no epoch is open
        if (unstakeEpoch == 0) {
            require(!epochOpen && currentEpochId > 0, "Epoch not ended");
        } else {
            require(!epochOpen && epochs[unstakeEpoch].settled, "Epoch not ended");
        }
        
        uint256 amount = position.amount;
        
        // CEI: clear state before transfer
        position.amount = 0;
        position.withdrawalQueued = false;
        position.unstakeEpochId = 0;
        isStaked[msg.sender] = false;
        
        // Remove from stakedAgents using swap-and-pop
        _removeFromStakedAgents(msg.sender);
        
        IERC20(CUSTOS_TOKEN).safeTransfer(msg.sender, amount);
        
        emit StakeWithdrawn(msg.sender, amount);
    }

    function _removeFromStakedAgents(address wallet) internal {
        for (uint256 i = 0; i < stakedAgents.length; i++) {
            if (stakedAgents[i] == wallet) {
                stakedAgents[i] = stakedAgents[stakedAgents.length - 1];
                stakedAgents.pop();
                break;
            }
        }
    }

    // ============ Participation Functions ============

    /**
     * @notice Submit commit hash for a round
     * @param roundId Round to commit to
     * @param commitHash Hash of (answer + salt)
     */
    function commit(uint256 roundId, bytes32 commitHash) external notPaused {
        require(epochOpen, "No epoch open");
        require(tierSnapshot[currentEpochId][msg.sender] > 0, "Not staked for epoch");
        require(rounds[roundId].epochId == currentEpochId, "Round not in current epoch");
        require(rounds[roundId].commitOpenAt <= block.timestamp, "Commit not open");
        require(rounds[roundId].commitCloseAt > block.timestamp, "Commit closed");
        
        Submission storage sub = submissions[roundId][msg.sender];
        require(!sub.committed, "Already committed");
        
        sub.committed = true;
        sub.commitHash = commitHash;
        sub.tierAtCommit = tierSnapshot[currentEpochId][msg.sender];
        
        emit CommitSubmitted(roundId, msg.sender, sub.tierAtCommit);
    }

    /**
     * @notice Reveal answer for a round
     * @param roundId Round to reveal for
     * @param answer Answer string
     * @param salt Salt used in commit
     */
    function reveal(uint256 roundId, string calldata answer, bytes32 salt) external notPaused {
        require(epochOpen, "No epoch open");
        require(rounds[roundId].commitCloseAt <= block.timestamp, "Commit still open");
        require(rounds[roundId].revealCloseAt > block.timestamp, "Reveal closed");
        
        Submission storage sub = submissions[roundId][msg.sender];
        require(sub.committed, "Not committed");
        require(!sub.revealed, "Already revealed");
        
        // Verify commit hash
        require(keccak256(abi.encodePacked(answer, salt)) == sub.commitHash, "Hash mismatch");
        
        // Cap pending reveals
        require(_pendingReveals[roundId].length < MAX_REVEALERS_PER_ROUND, "Too many reveals");
        
        sub.revealed = true;
        sub.revealedAnswer = answer;
        
        _pendingReveals[roundId].push(msg.sender);
        
        emit RevealSubmitted(roundId, msg.sender);
    }

    /**
     * @notice Claim rewards for an epoch
     * @param epochId Epoch to claim for
     */
    function claimEpochReward(uint256 epochId) external nonReentrant {
        require(epochClaimed[epochId][msg.sender] == false, "Already claimed");
        
        Epoch storage epoch = epochs[epochId];
        require(epoch.settled, "Epoch not settled");
        require(block.timestamp <= epoch.claimDeadline, "Claim deadline passed");
        
        uint256 credits = epochCredits[epochId][msg.sender];
        require(credits > 0, "No credits");
        
        uint256 claimable = (epoch.rewardPool * credits) / epoch.totalCredits;
        
        // CEI: set state before transfer
        epochClaimed[epochId][msg.sender] = true;
        epochClaimedAmount[epochId] += claimable;
        
        IERC20(CUSTOS_TOKEN).safeTransfer(msg.sender, claimable);
        
        emit RewardClaimed(epochId, msg.sender, claimable);
    }

    // ============ Oracle Functions ============

    /**
     * @notice Post a new round (oracle only)
     * @param questionUri URI to question data
     * @param answerHash Hash of correct answer
     * @return roundId The ID of the newly created round
     */
    function postRound(string calldata questionUri, bytes32 answerHash) external onlyOracle returns (uint256 roundId) {
        roundId = ++roundCount;
        
        uint256 commitOpen = block.timestamp;
        uint256 commitClose = commitOpen + COMMIT_WINDOW;
        uint256 revealClose = commitClose + REVEAL_WINDOW;
        
        rounds[roundId] = Round({
            roundId: roundId,
            epochId: currentEpochId,
            commitOpenAt: commitOpen,
            commitCloseAt: commitClose,
            revealCloseAt: revealClose,
            answerHash: answerHash,
            questionUri: questionUri,
            settled: false,
            expired: false,
            batchSettling: false,
            revealedAnswer: "",
            correctCount: 0,
            revealCount: 0
        });
        
        emit RoundPosted(roundId, questionUri, commitOpen, commitClose, revealClose);
    }

    /**
     * @notice Settle a round with correct answer (oracle only)
     * @param roundId Round to settle
     * @param correctAnswer The correct answer
     */
    function settleRound(uint256 roundId, string calldata correctAnswer) external onlyOracle {
        require(!rounds[roundId].settled, "Already settled");
        require(!rounds[roundId].expired, "Already expired");
        require(!rounds[roundId].batchSettling, "Batch settle in progress");
        require(keccak256(abi.encodePacked(correctAnswer)) == rounds[roundId].answerHash, "Answer mismatch");
        
        Round storage round = rounds[roundId];
        address[] storage pending = _pendingReveals[roundId];
        
        uint256 correctCount = 0;
        uint256 totalReveals = pending.length;
        
        for (uint256 i = 0; i < pending.length; i++) {
            address wallet = pending[i];
            Submission storage sub = submissions[roundId][wallet];
            
            if (keccak256(abi.encodePacked(sub.revealedAnswer)) == keccak256(abi.encodePacked(correctAnswer))) {
                if (!sub.credited) {
                    sub.credited = true;
                    correctCount++;
                    
                    uint256 credits = _calculateCredits(round.epochId, wallet, sub.tierAtCommit);
                    epochCredits[round.epochId][wallet] += credits;
                    
                    emit RoundSolved(roundId, wallet, credits);
                }
            }
        }
        
        round.settled = true;
        round.revealedAnswer = correctAnswer;
        round.correctCount = correctCount;
        round.revealCount = totalReveals;
        
        delete _pendingReveals[roundId];
        
        emit RoundSettled(roundId, correctAnswer, correctCount, totalReveals);
    }

    /**
     * @notice Settle a round in batches (oracle only)
     * @param roundId Round to settle
     * @param start Start index in pending reveals array
     * @param end End index (exclusive)
     * @param correctAnswer The correct answer
     */
    function settleBatch(
        uint256 roundId, 
        uint256 start, 
        uint256 end, 
        string calldata correctAnswer
    ) external onlyOracle {
        require(!rounds[roundId].settled, "Already settled");
        require(!rounds[roundId].expired, "Already expired");
        // Verify correctAnswer matches the committed answerHash — prevents oracle from
        // using different answers across batches
        require(keccak256(abi.encodePacked(correctAnswer)) == rounds[roundId].answerHash, "Answer mismatch");
        // Mark batch settling in progress — blocks settleRound from running in parallel
        if (!rounds[roundId].batchSettling) {
            rounds[roundId].batchSettling = true;
        }
        
        Round storage round = rounds[roundId];
        address[] storage pending = _pendingReveals[roundId];
        
        require(start < end, "Empty batch");
        require(end <= pending.length, "End out of bounds");
        
        uint256 correctCount = 0;
        
        for (uint256 i = start; i < end; i++) {
            address wallet = pending[i];
            Submission storage sub = submissions[roundId][wallet];
            
            if (keccak256(abi.encodePacked(sub.revealedAnswer)) == keccak256(abi.encodePacked(correctAnswer))) {
                if (!sub.credited) {
                    sub.credited = true;
                    correctCount++;
                    
                    uint256 credits = _calculateCredits(round.epochId, wallet, sub.tierAtCommit);
                    epochCredits[round.epochId][wallet] += credits;
                    
                    emit RoundSolved(roundId, wallet, credits);
                }
            }
        }
        
        round.correctCount += correctCount;
        round.revealCount += (end - start);
        
        // If this is the last batch, settle the round
        if (end == pending.length) {
            round.settled = true;
            round.revealedAnswer = correctAnswer;
            delete _pendingReveals[roundId];
            
            emit RoundSettled(roundId, correctAnswer, round.correctCount, round.revealCount);
        }
    }

    /**
     * @notice Expire a round (permissionless)
     * @param roundId Round to expire
     */
    function expireRound(uint256 roundId) external {
        Round storage round = rounds[roundId];
        require(!round.settled, "Already settled");
        require(!round.expired, "Already expired");
        require(block.timestamp > round.revealCloseAt, "Reveal still open");
        
        round.expired = true;
        delete _pendingReveals[roundId];
        
        emit RoundExpired(roundId);
    }

    /**
     * @notice Open a new epoch (oracle only)
     * @param startAt Timestamp when epoch starts
     */
    function openEpoch(uint256 startAt) external onlyOracle {
        require(!epochOpen, "Epoch already open");
        
        // Drain pending rewards to epoch reward pool
        uint256 rewardPool = pendingRewards;
        pendingRewards = 0;
        
        uint256 epochId = ++currentEpochId;
        
        epochs[epochId] = Epoch({
            epochId: epochId,
            startAt: startAt,
            endAt: startAt + EPOCH_DURATION,
            rewardPool: rewardPool,
            totalCredits: 0,
            settled: false,
            claimDeadline: startAt + EPOCH_DURATION + CLAIM_WINDOW
        });
        
        // Take tier snapshots for all staked agents
        uint256 t1 = tier1Threshold;
        uint256 t2 = tier2Threshold;
        uint256 t3 = tier3Threshold;
        
        for (uint256 i = 0; i < stakedAgents.length; i++) {
            address wallet = stakedAgents[i];
            StakePosition storage stakePos = stakes[wallet];
            
            // Skip if withdrawal queued (exiting after this epoch)
            if (stakePos.withdrawalQueued) continue;
            
            uint256 tier = _computeTier(stakePos.amount, t1, t2, t3);
            tierSnapshot[epochId][wallet] = tier;
        }
        
        epochOpen = true;
        
        emit EpochOpened(epochId, startAt, startAt + EPOCH_DURATION, rewardPool);
    }

    /**
     * @notice Close current epoch (oracle only)
     */
    function closeEpoch() external onlyOracle {
        require(epochOpen, "No epoch open");
        
        Epoch storage epoch = epochs[currentEpochId];
        epoch.settled = true;
        epoch.totalCredits = _calculateTotalCredits(currentEpochId);
        
        // Apply pending tier changes
        if (tierChangePending) {
            tier1Threshold = pendingTier1;
            tier2Threshold = pendingTier2;
            tier3Threshold = pendingTier3;
            tierChangePending = false;
            
            emit TierThresholdsUpdated(tier1Threshold, tier2Threshold, tier3Threshold);
        }
        
        epochOpen = false;
        
        emit EpochClosed(currentEpochId, epoch.totalCredits, epoch.rewardPool);
    }

    // ============ Admin Functions ============

    /**
     * @notice Fund epoch with $CUSTOS (custodian only)
     * @param custosAmount Amount to fund
     */
    function fundEpoch(uint256 custosAmount) external onlyCustodian {
        require(custosAmount > 0, "Amount must be > 0");
        
        IERC20(CUSTOS_TOKEN).safeTransferFrom(msg.sender, address(this), custosAmount);
        pendingRewards += custosAmount;
        
        emit CustosReceived(custosAmount, pendingRewards);
    }

    /**
     * @notice Seed rewards from already transferred tokens (custodian only)
     * @param amount Amount to register as pending
     */
    function seedRewards(uint256 amount) external onlyCustodian {
        require(amount > 0, "Amount must be > 0");
        
        uint256 balance = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        // Account for all locked amounts: staked tokens + pending rewards + active epoch pool
        uint256 available = balance;
        for (uint256 i = 0; i < stakedAgents.length; i++) {
            available -= stakes[stakedAgents[i]].amount;
        }
        available -= pendingRewards;
        if (epochOpen) {
            available -= epochs[currentEpochId].rewardPool;
        }
        
        require(available >= amount, "Insufficient balance");
        
        pendingRewards += amount;
        
        emit CustosReceived(amount, pendingRewards);
    }

    /**
     * @notice Receive $CUSTOS from CustosMineRewards
     * @param amount Amount received
     */
    function receiveCustos(uint256 amount) external {
        require(custosMineRewards != address(0), "Rewards not set");
        require(msg.sender == custosMineRewards, "Only rewards contract");
        
        pendingRewards += amount;
        
        emit CustosReceived(amount, pendingRewards);
    }

    /**
     * @notice Sweep unclaimed rewards after claim deadline (oracle only)
     * @param epochId Epoch to sweep
     */
    function sweepExpiredClaims(uint256 epochId) external onlyOracle {
        require(epochs[epochId].settled, "Epoch not settled");
        require(block.timestamp > epochs[epochId].claimDeadline, "Claim deadline not passed");
        
        uint256 unclaimed = epochs[epochId].rewardPool - epochClaimedAmount[epochId];
        require(unclaimed > 0, "No unclaimed rewards");
        
        epochClaimedAmount[epochId] = epochs[epochId].rewardPool; // Mark fully claimed
        pendingRewards += unclaimed;
        
        emit ExpiredClaimsSwept(epochId, unclaimed);
    }

    /**
     * @notice Recover accidentally sent ERC20 tokens (custodian only)
     * @param token Token to recover
     * @param amount Amount to recover
     * @param to Recipient address
     */
    function recoverERC20(address token, uint256 amount, address to) external onlyCustodian {
        require(to != address(0), "zero recipient");
        // If recovering CUSTOS, protect staked amounts + reward pool
        uint256 protectedAmount = 0;
        if (token == CUSTOS_TOKEN) {
            protectedAmount = pendingRewards;
            if (epochOpen) {
                protectedAmount += epochs[currentEpochId].rewardPool;
            }
            for (uint256 i = 0; i < stakedAgents.length; i++) {
                protectedAmount += stakes[stakedAgents[i]].amount;
            }
        }
        
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance >= protectedAmount + amount, "Insufficient available");
        
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Recover accidentally sent ETH (custodian only)
     * @param to Recipient address
     */
    function recoverETH(address payable to) external onlyCustodian {
        require(to != address(0), "zero recipient");
        uint256 bal = address(this).balance;
        require(bal > 0, "No ETH");
        (bool success,) = to.call{value: bal}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Set oracle address (custodian only)
     * @param newOracle New oracle address
     */
    function setOracle(address newOracle) external onlyCustodian {
        address prev = oracle;
        oracle = newOracle;
        
        emit OracleUpdated(prev, newOracle);
    }

    /**
     * @notice Set CustosMineRewards address (owner only)
     * @param newRewards New rewards contract address
     */
    function setCustosMineRewards(address newRewards) external onlyOwner {
        address prev = custosMineRewards;
        custosMineRewards = newRewards;
        
        emit MineRewardsUpdated(prev, newRewards);
    }

    /**
     * @notice Set tier thresholds (custodian only)
     * @param t1 Tier 1 threshold
     * @param t2 Tier 2 threshold
     * @param t3 Tier 3 threshold
     */
    function setTierThresholds(uint256 t1, uint256 t2, uint256 t3) external onlyCustodian {
        require(t1 < t2 && t2 < t3, "Invalid tier order");
        
        pendingTier1 = t1;
        pendingTier2 = t2;
        pendingTier3 = t3;
        tierChangePending = true;
        
        emit PendingTierThresholdsSet(t1, t2, t3);
    }

    /**
     * @notice Set custodian status (owner only)
     * @param account Account to modify
     * @param enabled True to enable, false to disable
     */
    function setCustodian(address account, bool enabled) external onlyOwner {
        custodians[account] = enabled;
        
        emit CustodianSet(account, enabled);
    }

    /**
     * @notice Transfer ownership (owner only)
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        address prev = owner;
        owner = newOwner;
        
        emit OwnershipTransferred(prev, newOwner);
    }

    /**
     * @notice Pause the contract (custodian only)
     */
    function pause() external onlyCustodian {
        paused = true;
        
        emit Paused();
    }

    /**
     * @notice Unpause the contract (custodian only)
     */
    function unpause() external onlyCustodian {
        paused = false;
        
        emit Unpaused();
    }

    /**
     * @notice Set epoch duration (owner only)
     * @param duration New duration
     */


    // ============ View Functions ============

    /**
     * @notice Get current round
     * @return Round Current round or empty if no rounds
     */
    function getCurrentRound() external view returns (Round memory) {
        if (roundCount == 0) { return Round(0, 0, 0, 0, 0, bytes32(0), "", false, false, false, "", 0, 0); }
        return rounds[roundCount];
    }

    /**
     * @notice Get round by ID
     * @param roundId Round ID
     * @return Round data
     */
    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    /**
     * @notice Get epoch data
     * @param epochId Epoch ID
     * @return Epoch data
     */
    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return epochs[epochId];
    }

    /**
     * @notice Get stake position for a wallet
     * @param wallet Wallet address
     * @return StakePosition stake data
     */
    function getStake(address wallet) external view returns (StakePosition memory) {
        return stakes[wallet];
    }

    /**
     * @notice Get tier snapshot for a wallet in an epoch
     * @param wallet Wallet address
     * @param epochId Epoch ID
     * @return tier Tier snapshot (0 if not staked that epoch)
     */
    function getTierSnapshot(address wallet, uint256 epochId) external view returns (uint256 tier) {
        return tierSnapshot[epochId][wallet];
    }

    /**
     * @notice Get credits for a wallet in an epoch
     * @param wallet Wallet address
     * @param epochId Epoch ID
     * @return credits Credit amount
     */
    function getCredits(address wallet, uint256 epochId) external view returns (uint256 credits) {
        return epochCredits[epochId][wallet];
    }

    /**
     * @notice Calculate claimable amount for a wallet
     * @param wallet Wallet address
     * @param epochId Epoch ID
     * @return claimable Amount claimable
     */
    function getClaimable(address wallet, uint256 epochId) external view returns (uint256 claimable) {
        if (epochClaimed[epochId][wallet]) return 0;
        
        Epoch storage epoch = epochs[epochId];
        if (!epoch.settled) return 0;
        if (block.timestamp > epoch.claimDeadline) return 0;
        
        uint256 credits = epochCredits[epochId][wallet];
        if (credits == 0) return 0;
        
        return (epoch.rewardPool * credits) / epoch.totalCredits;
    }

    /**
     * @notice Check if commit window is open
     * @return bool True if commit is open
     */
    function isCommitOpen() external view returns (bool) {
        if (roundCount == 0 || !epochOpen) return false;
        Round storage round = rounds[roundCount];
        return round.commitOpenAt <= block.timestamp && round.commitCloseAt > block.timestamp;
    }

    /**
     * @notice Check if reveal window is open
     * @return bool True if reveal is open
     */
    function isRevealOpen() external view returns (bool) {
        if (roundCount == 0 || !epochOpen) return false;
        Round storage round = rounds[roundCount];
        return round.commitCloseAt <= block.timestamp && round.revealCloseAt > block.timestamp;
    }

    /**
     * @notice Get count of pending reveals for a round
     * @param roundId Round ID
     * @return count Number of pending reveals
     */
    function getPendingRevealCount(uint256 roundId) external view returns (uint256 count) {
        return _pendingReveals[roundId].length;
    }

    /**
     * @notice Get list of pending revealers for a round
     * @param roundId Round ID
     * @param offset Start index
     * @param limit Number of addresses to return
     * @return List of wallet addresses
     */
    function getPendingRevealers(uint256 roundId, uint256 offset, uint256 limit) 
        external 
        view 
        returns (address[] memory) 
    {
        address[] storage pending = _pendingReveals[roundId];
        if (offset >= pending.length) return new address[](0);
        
        uint256 available = pending.length - offset;
        uint256 toReturn = available < limit ? available : limit;
        
        address[] memory result = new address[](toReturn);
        for (uint256 i = 0; i < toReturn; i++) {
            result[i] = pending[offset + i];
        }
        return result;
    }

    /**
     * @notice Get number of staked agents
     * @return count Number of staked agents
     */
    function getStakedAgentCount() external view returns (uint256 count) {
        return stakedAgents.length;
    }

    // ============ Internal Functions ============

    /**
     * @notice Compute tier from stake amount
     * @param amount Stake amount
     * @return tier Tier (1, 2, or 3)
     */
    function _computeTier(uint256 amount, uint256 t1, uint256 t2, uint256 t3) 
        internal 
        pure 
        returns (uint256 tier) 
    {
        if (amount >= t3) return 3;
        if (amount >= t2) return 2;
        if (amount >= t1) return 1;
        return 0;
    }

    /**
     * @notice Get tier from balance using current thresholds
     * @param amount Stake amount
     * @return tier Current tier
     */
    function _getTierFromBalance(uint256 amount) internal view returns (uint256 tier) {
        return _computeTier(amount, tier1Threshold, tier2Threshold, tier3Threshold);
    }

    /**
     * @notice Calculate credits for a correct reveal
     * @param tier Tier at commit time (1/2/3)
     * @return credits Credits earned (equals tier value)
     */
    function _calculateCredits(uint256 /*epochId*/, address /*wallet*/, uint256 tier) 
        internal 
        pure 
        returns (uint256 credits) 
    {
        // Credits = tier value: tier1=1, tier2=2, tier3=3
        // Proportional reward share: (myCredits / totalCredits) * rewardPool
        return tier;
    }

    /**
     * @notice Calculate total credits for an epoch
     * @param epochId Epoch ID
     * @return total Total credits
     */
    function _calculateTotalCredits(uint256 epochId) internal view returns (uint256 total) {
        for (uint256 i = 0; i < stakedAgents.length; i++) {
            total += epochCredits[epochId][stakedAgents[i]];
        }
    }

    // ============ Fallback ============
    receive() external payable {
        require(msg.sender == custosMineRewards, "Only rewards contract can send ETH");
    }
}
