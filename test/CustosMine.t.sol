// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/CustosMineController.sol";
import "../src/CustosMineRewards.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Minimal mocks ─────────────────────────────────────────────────────────────

contract MockCustos is ERC20 {
    constructor() ERC20("CUSTOS", "CUSTOS") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockWETH is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev Fake 0x router: pulls WETH from caller (allowance already set), sends CUSTOS to caller
contract MockZeroEx {
    MockCustos public custos;
    MockWETH   public weth;
    uint256 public custosOut;

    constructor(MockCustos _custos) { custos = _custos; }

    function setWeth(MockWETH _weth) external { weth = _weth; }
    function setOutput(uint256 amount) external { custosOut = amount; }

    // Called by CustosMineRewards via low-level call(swapCalldata)
    // Simulate 0x: pull WETH allowance, send CUSTOS to caller
    fallback() external {
        if (address(weth) != address(0)) {
            uint256 allowed = weth.allowance(msg.sender, address(this));
            if (allowed > 0) {
                weth.transferFrom(msg.sender, address(this), allowed);
            }
        }
        custos.transfer(msg.sender, custosOut);
    }
}


// ─── Mock CustosProxy ──────────────────────────────────────────────────────────

contract MockCustosProxy {
    mapping(uint256 => bytes32) public inscriptionContentHash;
    mapping(uint256 => address) public inscriptionAgent;
    mapping(address => uint256) public agentIdByWallet;
    uint256 public nextId = 1;

    /// @dev Register a fake inscription — returns inscriptionId
    function mockInscribe(address agent, bytes32 contentHash) external returns (uint256 id) {
        id = nextId++;
        inscriptionContentHash[id] = contentHash;
        inscriptionAgent[id]       = agent;
        if (agentIdByWallet[agent] == 0) agentIdByWallet[agent] = id;
    }
}

// ─── Base test setup ───────────────────────────────────────────────────────────

contract MineTestBase is Test {
    CustosMineController controller;
    CustosMineRewards    rewards;
    MockCustos           custos;
    MockWETH             weth;
    MockZeroEx           zeroEx;

    address owner     = makeAddr("owner");
    address oracle    = makeAddr("oracle");
    address custodian = makeAddr("custodian");
    address miner1    = makeAddr("miner1");
    address miner2    = makeAddr("miner2");
    address miner3    = makeAddr("miner3");
    MockCustosProxy  proxy;

    uint256 constant T1 = 25_000_000e18;
    uint256 constant T2 = 50_000_000e18;
    uint256 constant T3 = 100_000_000e18;

    function setUp() public virtual {
        custos = new MockCustos();
        weth   = new MockWETH();
        zeroEx = new MockZeroEx(custos);

        // Deploy controller first
        proxy = new MockCustosProxy();
        controller = new CustosMineController(
            address(custos),
            address(proxy),
            address(0), // custosMineRewards - set after rewards deployment
            oracle,
            T1, T2, T3
        );

        // Deploy rewards
        address[] memory rewardsCustodians = new address[](1);
        rewardsCustodians[0] = custodian;
        rewards = new CustosMineRewards(
            owner,
            rewardsCustodians,
            oracle,
            address(controller),
            address(weth),
            address(custos),
            address(zeroEx)
        );

        // Wire controller → rewards (test contract is owner — msg.sender in constructor)
        controller.setCustosMineRewards(address(rewards));

        // Seed zeroEx with CUSTOS for swaps
        custos.mint(address(zeroEx), 1_000_000_000e18);
        // Wire weth into mock zeroEx (so it can pull allowances)
        zeroEx.setWeth(weth);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _openEpoch() internal {
        vm.prank(oracle);
        controller.openEpoch(block.timestamp);
        // Only snapshot if not already complete (0 stakers = instantly complete)
        if (!controller.snapshotComplete()) {
            vm.prank(oracle);
            controller.snapshotBatch(1000);
        }
    }

    function _stakeMiner(address miner, uint256 amount) internal {
        custos.mint(miner, amount);
        vm.prank(miner);
        custos.approve(address(controller), amount);
        vm.prank(miner);
        controller.stake(amount);
    }

    function _postRound(string memory answer) internal returns (uint256 roundId, bytes32 answerHash) {
        answerHash = keccak256(abi.encodePacked(answer));
        vm.prank(oracle);
        roundId = controller.postRound("ipfs://Qm", answerHash);
    }

    /// @dev Inscribe on mock proxy then registerCommit (round 1 pattern)
    function _commit(address miner, uint256 roundId, string memory answer, bytes32 salt) internal {
        bytes32 ch = keccak256(abi.encodePacked(answer, salt));
        vm.prank(miner);
        uint256 insId = proxy.mockInscribe(miner, ch);
        vm.prank(miner);
        controller.registerCommit(roundId, insId);
    }

    /// @dev Inscribe + registerCommitReveal (rounds 2-139 pattern)
    function _commitReveal(address miner, uint256 roundIdC, string memory answerC, bytes32 saltC,
                            uint256 roundIdR, string memory answerR, bytes32 saltR) internal {
        bytes32 ch = keccak256(abi.encodePacked(answerC, saltC));
        vm.prank(miner);
        uint256 insId = proxy.mockInscribe(miner, ch);
        vm.prank(miner);
        controller.registerCommitReveal(roundIdC, insId, roundIdR, answerR, saltR);
    }

    /// @dev registerReveal only (round 140 pattern)
    function _reveal(address miner, uint256 roundId, string memory answer, bytes32 salt) internal {
        vm.prank(miner);
        controller.registerReveal(roundId, answer, salt);
    }

    function _settleRound(uint256 roundId, string memory answer) internal {
        CustosMineController.Round memory rnd = controller.getCurrentRound();
        vm.warp(rnd.revealCloseAt + 1);
        vm.prank(oracle);
        controller.settleRound(roundId, answer);
    }

    function _closeEpoch() internal {
        vm.prank(oracle);
        controller.closeEpoch();
        // Accumulate credits for all agents in one batch, then finalize
        vm.prank(oracle);
        controller.accumulateCreditsBatch(1000);
        vm.prank(oracle);
        controller.finalizeClose();
    }
}

// ─── Test suites ──────────────────────────────────────────────────────────────

contract MineControllerEpochTest is MineTestBase {

    function test_openEpoch_setsFields() public {
        _openEpoch();
        CustosMineController.Epoch memory e = controller.getEpoch(1);
        assertEq(e.epochId, 1);
        assertEq(e.startAt, block.timestamp);
        assertEq(e.endAt, block.timestamp + 86400);
        assertEq(e.rewardPool, 0);
        assertFalse(e.settled);
        assertTrue(controller.epochOpen());
        assertEq(controller.currentEpochId(), 1);
    }

    function test_openEpoch_drainsPendingRewards() public {
        // Seed 500k CUSTOS into rewardBuffer via custodian seed
        custos.mint(address(controller), 500_000e18);
        controller.setCustodian(custodian, true);
        vm.prank(custodian);
        controller.allocateRewards(500_000e18);

        _openEpoch();
        CustosMineController.Epoch memory e = controller.getEpoch(1);
        assertEq(e.rewardPool, 500_000e18);
        assertEq(controller.rewardBuffer(), 0);
    }

    function test_openEpoch_revertsIfAlreadyOpen() public {
        _openEpoch();
        vm.prank(oracle);
        vm.expectRevert(bytes("E11"));
        controller.openEpoch(0);
    }

    function test_closeEpoch_setsSettled() public {
        _openEpoch();
        _closeEpoch();
        CustosMineController.Epoch memory e = controller.getEpoch(1);
        assertTrue(e.settled);
        assertFalse(controller.epochOpen());
    }

    function test_closeEpoch_revertsIfNoActiveEpoch() public {
        vm.prank(oracle);
        vm.expectRevert(bytes("E10"));
        controller.closeEpoch();
    }

    function test_multipleEpochs_incrementId() public {
        _openEpoch();
        _closeEpoch();
        _openEpoch();
        assertEq(controller.currentEpochId(), 2);
    }
}

contract MineControllerStakingTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);
    }

    function test_stake_addsToStake() public {
        custos.mint(miner1, T1);
        vm.prank(miner1);
        custos.approve(address(controller), T1);
        vm.prank(miner1);
        controller.stake(T1);
        
        CustosMineController.StakePosition memory pos = controller.getStake(miner1);
        assertEq(pos.amount, T1);
        assertFalse(pos.withdrawalQueued);
    }

    function test_stake_firstStake_addsToStakedAgents() public {
        custos.mint(miner1, T1);
        vm.prank(miner1);
        custos.approve(address(controller), T1);
        vm.prank(miner1);
        controller.stake(T1);
        
        assertEq(controller.getStakedAgentCount(), 1);
        assertTrue(controller.isStaked(miner1));
    }

    function test_stake_revertsBelowTier1() public {
        custos.mint(miner1, T1 - 1);
        vm.prank(miner1);
        vm.expectRevert(bytes("E13"));
        controller.stake(T1 - 1);
    }

    function test_unstake_queuesWithdrawal() public {
        _stakeMiner(miner1, T1);
        _openEpoch(); // open epoch 1 so unstakeEpochId = 1
        
        vm.prank(miner1);
        controller.unstake();
        
        CustosMineController.StakePosition memory pos = controller.getStake(miner1);
        assertTrue(pos.withdrawalQueued);
        assertEq(pos.unstakeEpochId, 1);
    }

    function test_cancelUnstake_clearsQueue() public {
        _stakeMiner(miner1, T1);
        
        vm.prank(miner1);
        controller.unstake();
        vm.prank(miner1);
        controller.cancelUnstake();
        
        CustosMineController.StakePosition memory pos = controller.getStake(miner1);
        assertFalse(pos.withdrawalQueued);
    }

    function test_withdrawStake_afterEpochEnds() public {
        _stakeMiner(miner1, T1);
        
        vm.prank(miner1);
        controller.unstake();
        
        _openEpoch();
        _closeEpoch(); // Epoch 1 ends
        
        // miner1 can now withdraw
        uint256 balBefore = custos.balanceOf(miner1);
        vm.prank(miner1);
        controller.withdrawStake();
        
        assertEq(custos.balanceOf(miner1) - balBefore, T1);
        assertFalse(controller.isStaked(miner1));
        assertEq(controller.getStakedAgentCount(), 0);
    }
}

contract MineControllerTierSnapshotTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);
    }

    function test_openEpoch_takesTierSnapshots() public {
        _stakeMiner(miner1, T1); // Tier 1
        _stakeMiner(miner2, T2); // Tier 2
        _stakeMiner(miner3, T3); // Tier 3
        
        _openEpoch();
        
        assertEq(controller.getTierSnapshot(miner1, 1), 1);
        assertEq(controller.getTierSnapshot(miner2, 1), 2);
        assertEq(controller.getTierSnapshot(miner3, 1), 3);
    }

    function test_openEpoch_skipsWithdrawalQueued() public {
        _stakeMiner(miner1, T1);
        _stakeMiner(miner2, T2);
        
        vm.prank(miner1);
        controller.unstake();
        
        _openEpoch();
        
        // miner1 should be skipped (exiting after this epoch)
        assertEq(controller.getTierSnapshot(miner1, 1), 0);
        assertEq(controller.getTierSnapshot(miner2, 1), 2);
    }

    function test_tierSnapshot_immutableAfterStakingChanges() public {
        _stakeMiner(miner1, T2); // Start with tier 2
        
        _openEpoch();
        assertEq(controller.getTierSnapshot(miner1, 1), 2);
        
        // Add more stake
        custos.mint(miner1, T1);
        vm.prank(miner1);
        custos.approve(address(controller), T1);
        vm.prank(miner1);
        controller.stake(T1);
        
        // Snapshot should NOT change
        assertEq(controller.getTierSnapshot(miner1, 1), 2);
    }
}

contract MineControllerCommitRevealTest is MineTestBase {

    bytes32 constant SALT = keccak256("test-salt");
    string  constant ANSWER = "42069";

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);
        // Stake BEFORE opening epoch — snapshot taken at openEpoch
        _stakeMiner(miner1, T1);
        _stakeMiner(miner2, T2);
        _stakeMiner(miner3, T3);
        _openEpoch();
    }

    function test_postRound_setsFields() public {
        (uint256 rid, bytes32 ah) = _postRound(ANSWER);
        assertEq(rid, 1);
        CustosMineController.Round memory rnd = controller.getCurrentRound();
        assertEq(rnd.roundId, 1);
        assertEq(rnd.answerHash, ah);
        assertEq(rnd.epochId, 1);
        assertFalse(rnd.settled);
        { CustosMineController.Round memory r2 = controller.getCurrentRound(); assertTrue(block.timestamp >= r2.commitOpenAt && block.timestamp < r2.commitCloseAt); }
    }

    function test_commit_succeeds() public {
        (uint256 rid,) = _postRound(ANSWER);
        _commit(miner1, rid, ANSWER, SALT);

        CustosMineController.Submission memory sub = controller.getSubmission(rid, miner1);
        assertTrue(sub.committed);
        // contentHash on proxy should match keccak256(answer|salt)
        bytes32 expected = keccak256(abi.encodePacked(ANSWER, SALT));
        assertEq(proxy.inscriptionContentHash(sub.commitInscriptionId), expected);
    }

    function test_commit_revertsNotStaked() public {
        (uint256 rid,) = _postRound(ANSWER);
        address unregistered = makeAddr("unregistered");
        bytes32 ch = keccak256(abi.encodePacked("answer", bytes32("salt")));
        uint256 insId = proxy.mockInscribe(unregistered, ch);
        vm.prank(unregistered);
        vm.expectRevert(bytes("E12"));
        controller.registerCommit(rid, insId);
    }

    function test_commit_revertsAfterWindow() public {
        (uint256 rid,) = _postRound(ANSWER);
        CustosMineController.Round memory rnd = controller.getCurrentRound();
        // inscribe before warp so inscription exists, then warp past commit window
        bytes32 ch = keccak256(abi.encodePacked(ANSWER, SALT));
        uint256 insId = proxy.mockInscribe(miner1, ch);
        vm.warp(rnd.commitCloseAt + 1);
        vm.prank(miner1);
        vm.expectRevert(bytes("E62"));
        controller.registerCommit(rid, insId);
    }

    function test_reveal_succeeds() public {
        (uint256 rid,) = _postRound(ANSWER);
        _commit(miner1, rid, ANSWER, SALT);
        CustosMineController.Round memory rnd = controller.getCurrentRound();
        vm.warp(rnd.commitCloseAt + 1);
        _reveal(miner1, rid, ANSWER, SALT);

        CustosMineController.Submission memory sub = controller.getSubmission(rid, miner1);
        assertTrue(sub.committed);
        assertTrue(sub.revealed);
    }

    function test_reveal_revertsWrongSalt() public {
        (uint256 rid,) = _postRound(ANSWER);
        _commit(miner1, rid, ANSWER, SALT);
        CustosMineController.Round memory rnd = controller.getCurrentRound();
        vm.warp(rnd.commitCloseAt + 1);
        vm.prank(miner1);
        vm.expectRevert(bytes("E17"));
        controller.registerReveal(rid, ANSWER, keccak256("wrong-salt"));
    }

    function test_settle_awardsCreditsCorrectly() public {
        (uint256 rid,) = _postRound(ANSWER);

        // miner1 (tier 1) correct
        _commit(miner1, rid, ANSWER, SALT);
        // miner2 (tier 2) correct
        bytes32 salt2 = keccak256("salt2");
        _commit(miner2, rid, ANSWER, salt2);
        // miner3 (tier 3) WRONG
        bytes32 salt3 = keccak256("salt3");
        _commit(miner3, rid, "wrong", salt3);

        CustosMineController.Round memory rnd = controller.getCurrentRound();
        vm.warp(rnd.commitCloseAt + 1);
        _reveal(miner1, rid, ANSWER, SALT);
        _reveal(miner2, rid, ANSWER, salt2);
        _reveal(miner3, rid, "wrong", salt3);

        _settleRound(rid, ANSWER);

        // miner1 = 1 credit (tier1), miner2 = 2 credits (tier2), miner3 = 0 (wrong answer)
        assertEq(controller.getCredits(miner1, 1), 1);
        assertEq(controller.getCredits(miner2, 1), 2);
        assertEq(controller.getCredits(miner3, 1), 0);
    }

    function test_settle_revertsDoubleSettle() public {
        (uint256 rid,) = _postRound(ANSWER);
        _settleRound(rid, ANSWER);
        vm.prank(oracle);
        vm.expectRevert(bytes("E40"));
        controller.settleRound(rid, ANSWER);
    }

    function test_expireRound_succeeds() public {
        (uint256 rid,) = _postRound(ANSWER);
        CustosMineController.Round memory rnd = controller.getCurrentRound();
        // expireRound requires block.timestamp > revealCloseAt + 300
        vm.warp(rnd.revealCloseAt + 301);
        
        controller.expireRound(rid);
        
        CustosMineController.Round memory r = controller.getRound(rid);
        assertTrue(r.expired);
    }
}

contract MineControllerClaimTest is MineTestBase {

    bytes32 constant SALT1 = keccak256("salt1");
    bytes32 constant SALT2 = keccak256("salt2");
    string  constant ANSWER = "12345";

    uint256 constant POOL = 1_000_000e18; // 1M CUSTOS reward pool

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);

        // Seed reward pool
        custos.mint(address(controller), POOL);
        vm.prank(custodian);
        controller.allocateRewards(POOL);

        _stakeMiner(miner1, T1); // tier1 = 1 credit
        _stakeMiner(miner2, T2); // tier2 = 2 credits
        _openEpoch();

        // Full round: both miners commit + reveal + settle
        (uint256 rid,) = _postAndFullSettle();
        // miner1 = 1 credit (tier1), miner2 = 2 credits (tier2), total = 3
        assertEq(controller.getCredits(miner1, 1), 1);
        assertEq(controller.getCredits(miner2, 1), 2);

        _closeEpoch();
    }

    function test_claim_miner1_getsCorrectShare() public {
        // miner1: 1/3 of POOL
        uint256 expected = (1 * POOL) / 3;
        uint256 claimable = controller.getClaimable(miner1, 1);
        assertEq(claimable, expected);

        uint256 balBefore = custos.balanceOf(miner1);
        vm.prank(miner1);
        controller.claimEpochReward(1);
        assertEq(custos.balanceOf(miner1) - balBefore, expected);
    }

    function test_claim_miner2_getsCorrectShare() public {
        // miner2: 2/3 of POOL
        uint256 expected = (2 * POOL) / 3;
        uint256 balBefore = custos.balanceOf(miner2);
        vm.prank(miner2);
        controller.claimEpochReward(1);
        assertEq(custos.balanceOf(miner2) - balBefore, expected);
    }

    function test_claim_revertsDoubleClaim() public {
        vm.prank(miner1);
        controller.claimEpochReward(1);
        vm.prank(miner1);
        vm.expectRevert(bytes("E21"));
        controller.claimEpochReward(1);
    }

    function test_claim_revertsNoCredits() public {
        // miner3 never participated
        vm.prank(miner3);
        vm.expectRevert(bytes("E23"));
        controller.claimEpochReward(1);
    }

    function test_claim_revertsAfterWindow() public {
        CustosMineController.Epoch memory e = controller.getEpoch(1);
        vm.warp(e.endAt + 30 days + 1);
        vm.prank(miner1);
        vm.expectRevert(bytes("E22"));
        controller.claimEpochReward(1);
    }

    function test_getClaimable_returnsZeroIfNotSettled() public {
        _openEpoch();
        assertEq(controller.getClaimable(miner1, 2), 0);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _postAndFullSettle() internal returns (uint256 rid, bytes32 ah) {
        ah = keccak256(abi.encodePacked(ANSWER));
        vm.prank(oracle);
        rid = controller.postRound("ipfs://test", ah);

        _commit(miner1, rid, ANSWER, SALT1);
        _commit(miner2, rid, ANSWER, SALT2);

        CustosMineController.Round memory rnd = controller.getCurrentRound();
        vm.warp(rnd.commitCloseAt + 1);
        _reveal(miner1, rid, ANSWER, SALT1);
        _reveal(miner2, rid, ANSWER, SALT2);

        vm.warp(rnd.revealCloseAt + 1);
        vm.prank(oracle);
        controller.settleRound(rid, ANSWER);
    }
}

contract MineControllerSeedTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);
    }

    function test_allocateRewards_addsToPending() public {
        uint256 amt = 500_000e18;
        custos.mint(address(controller), amt);
        vm.prank(custodian);
        controller.allocateRewards(amt);
        assertEq(controller.rewardBuffer(), amt);
    }

    function test_allocateRewards_revertsInsufficientBalance() public {
        vm.prank(custodian);
        vm.expectRevert(bytes("E48"));
        controller.allocateRewards(1e18);
    }

    function test_receiveCustos_onlyFromRewardsContract() public {
        vm.expectRevert(bytes("E44"));
        controller.receiveCustos(1e18);
    }

    function test_receiveCustos_addsToPending() public {
        vm.prank(address(rewards));
        controller.receiveCustos(100e18);
        assertEq(controller.rewardBuffer(), 100e18);
    }
}

contract MineControllerRecoveryTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);
        _openEpoch();
    }

    function test_recoverERC20_nonCustos() public {
        MockWETH other = new MockWETH();
        other.mint(address(controller), 1 ether);
        vm.prank(custodian);
        controller.recoverERC20(address(other), 1 ether, custodian);
        assertEq(other.balanceOf(custodian), 1 ether);
    }

    function test_recoverERC20_revertsNonCustodian() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(bytes("E25"));
        controller.recoverERC20(address(custos), 1, custodian);
    }
}

contract MineControllerConfigTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);
    }

    function test_setTierThresholds() public {
        vm.prank(custodian);
        controller.setTierThresholds(10e18, 20e18, 30e18);
        // Pending should be set, actual thresholds unchanged until closeEpoch
        assertEq(controller.tier1Threshold(), T1);
    }

    function test_setOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(custodian);
        controller.setOracle(newOracle);
        assertEq(controller.oracle(), newOracle);
    }

    function test_setPaused_blocksOperations() public {
        _openEpoch();

        vm.prank(custodian);
        controller.pause();

        custos.mint(makeAddr("p"), T1);
        vm.prank(makeAddr("p"));
        vm.expectRevert(bytes("E27"));
        controller.stake(T1);
    }
}

contract CustosMineRewardsTest is MineTestBase {

    function test_swapAndSend_forwardsToController() public {
        uint256 wethAmt = 1 ether;
        uint256 custosOut = 5_000_000e18;

        // Fund rewards contract with WETH
        weth.mint(address(rewards), wethAmt);
        // Set mock swap output
        zeroEx.setOutput(custosOut);

        // Execute swap
        vm.prank(oracle);
        rewards.swapAndSend(bytes(""), custosOut); // empty calldata hits fallback

        // Controller received CUSTOS into rewardBuffer
        assertEq(controller.rewardBuffer(), custosOut);
        // WETH drained from rewards (transferred to mock zeroEx)
        assertEq(weth.balanceOf(address(rewards)), 0);
        assertEq(weth.balanceOf(address(zeroEx)), wethAmt);
    }

    function test_swapAndSend_revertsNoWETH() public {
        vm.prank(oracle);
        vm.expectRevert(bytes("E46"));
        rewards.swapAndSend(bytes(""), 0);
    }

    function test_recoverFunds_custodianOnly() public {
        weth.mint(address(rewards), 1 ether);
        vm.prank(custodian);
        rewards.recoverFunds(address(weth), 1 ether, custodian);
        assertEq(weth.balanceOf(custodian), 1 ether);
    }

    function test_recoverFunds_revertsNonCustodian() public {
        vm.prank(oracle);
        vm.expectRevert(bytes("E25"));
        rewards.recoverFunds(address(weth), 1, custodian);
    }
}

// ─── Security fix tests ────────────────────────────────────────────────────────

contract MineControllerSecurityTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        controller.setCustodian(custodian, true);
    }

    // FIX1: withdrawStake should NOT be allowed during an open epoch
    function test_withdrawStake_revertsIfEpochOpen() public {
        _stakeMiner(miner1, T1);
        _openEpoch(); // epoch 1 now open

        // Unstake during open epoch — unstakeEpochId = 1
        vm.prank(miner1);
        controller.unstake();

        // Try to withdraw immediately — epoch still open
        vm.prank(miner1);
        vm.expectRevert(bytes("E39"));
        controller.withdrawStake();
    }

    // FIX1: withdrawStake allowed after epoch ends
    function test_withdrawStake_succeedsAfterEpochEnds() public {
        _stakeMiner(miner1, T1);

        vm.prank(miner1);
        controller.unstake();

        _openEpoch();
        _closeEpoch();
        // Epoch is closed, warp past endAt
        vm.warp(block.timestamp + 86401);

        vm.prank(miner1);
        controller.withdrawStake(); // should succeed
        assertFalse(controller.isStaked(miner1));
    }

    // FIX2: seedRewards double-seed should revert
    function test_allocateRewards_preventsDoubleSeed() public {
        uint256 amt = 500_000e18;
        custos.mint(address(controller), amt);
        vm.prank(custodian);
        controller.allocateRewards(amt);
        // rewardBuffer = amt, balance = amt. No free balance left.
        vm.prank(custodian);
        vm.expectRevert(bytes("E48"));
        controller.allocateRewards(1); // nothing left to seed
    }

    // FIX3: receiveCustos reverts if custosMineRewards is address(0)
    function test_receiveCustos_revertsIfRewardsNotSet() public {
        // Deploy a fresh controller with address(0) as rewardsAddress
        CustosMineController fresh = new CustosMineController(
            address(custos),
            address(proxy),
            address(0), // rewards not set
            oracle,
            T1, T2, T3
        );
        vm.expectRevert(bytes("E29"));
        fresh.receiveCustos(100e18);
    }

    // FIX4: commit should revert for a round from a previous epoch
    function test_commit_revertsStaleEpochRound() public {
        _stakeMiner(miner1, T1);
        _openEpoch(); // epoch 1

        // Post round in epoch 1
        vm.prank(oracle);
        uint256 rid = controller.postRound("ipfs://stale", keccak256("answer"));

        // Close epoch 1, open epoch 2
        _closeEpoch();
        _openEpoch(); // epoch 2 — miner1 was not queued for withdrawal so re-snapshotted

        // Try to commit to epoch-1 round during epoch 2
        bytes32 ch = keccak256(abi.encodePacked("answer", bytes32("salt")));
        vm.prank(miner1);
        uint256 insId = proxy.mockInscribe(miner1, ch);
        vm.expectRevert(bytes("E58"));
        controller.registerCommit(rid, insId);
    }

    // FIX5: settleRound should revert with wrong answer (not matching answerHash)
    function test_settleRound_revertsWrongAnswer() public {
        _stakeMiner(miner1, T1);
        _openEpoch();
        bytes32 ah = keccak256(abi.encodePacked("correct"));
        vm.prank(oracle);
        uint256 rid = controller.postRound("ipfs://q", ah);

        CustosMineController.Round memory rnd = controller.getRound(rid);
        vm.warp(rnd.revealCloseAt + 1);

        vm.prank(oracle);
        vm.expectRevert(bytes("E17"));
        controller.settleRound(rid, "wrong_answer");
    }

    // FIX5: settleBatch should revert with wrong answer
    function test_settleBatch_revertsWrongAnswer() public {
        _stakeMiner(miner1, T1);
        _openEpoch();
        bytes32 ah = keccak256(abi.encodePacked("correct"));
        vm.prank(oracle);
        uint256 rid = controller.postRound("ipfs://q", ah);

        CustosMineController.Round memory rnd = controller.getRound(rid);
        vm.warp(rnd.revealCloseAt + 1);

        vm.prank(oracle);
        vm.expectRevert(bytes("E17"));
        controller.settleBatch(rid, 0, 0, "wrong_answer");
    }

    // FIX9: settleRound should revert if batchSettling in progress
    function test_settleRound_revertsIfBatchSettling() public {
        _stakeMiner(miner1, T1);
        _stakeMiner(miner2, T2);
        _openEpoch();
        bytes32 ah = keccak256(abi.encodePacked("correct"));
        vm.prank(oracle);
        uint256 rid = controller.postRound("ipfs://q", ah);

        // Both miners commit
        bytes32 salt = keccak256("s");
        _commit(miner1, rid, "correct", salt);
        _commit(miner2, rid, "correct", salt);

        CustosMineController.Round memory rnd = controller.getRound(rid);
        vm.warp(rnd.commitCloseAt + 1);
        _reveal(miner1, rid, "correct", salt);
        _reveal(miner2, rid, "correct", salt);
        vm.warp(rnd.revealCloseAt + 1);

        // First call to settleBatch: settle only first revealer — sets batchSettling = true, not yet settled
        vm.prank(oracle);
        controller.settleBatch(rid, 0, 1, "correct"); // partial batch, batchSettling=true

        // Now settleRound should revert because batchSettling is in progress
        vm.prank(oracle);
        vm.expectRevert(bytes("E52"));
        controller.settleRound(rid, "correct");
    }

    // FIX6: recoverERC20 on CUSTOS should not drain staked tokens
    function test_recoverERC20_cannotDrainStakes() public {
        _stakeMiner(miner1, T1); // T1 staked into controller

        // No extra CUSTOS in contract — all is staked
        vm.prank(custodian);
        vm.expectRevert(bytes("E48"));
        controller.recoverERC20(address(custos), 1, custodian);
    }

    // FIX6: recoverERC20 on CUSTOS allows recovering truly free tokens
    function test_recoverERC20_allowsFreeTokens() public {
        _stakeMiner(miner1, T1);
        // Send 100 extra CUSTOS directly (not via stake/seed)
        custos.mint(address(controller), 100e18);

        vm.prank(custodian);
        controller.recoverERC20(address(custos), 100e18, custodian);
        assertEq(custos.balanceOf(custodian), 100e18);
    }
}
