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

    uint256 constant T1 = 25_000_000e18;
    uint256 constant T2 = 50_000_000e18;
    uint256 constant T3 = 100_000_000e18;

    function setUp() public virtual {
        custos = new MockCustos();
        weth   = new MockWETH();
        zeroEx = new MockZeroEx(custos);

        address[] memory custodians = new address[](1);
        custodians[0] = custodian;
        controller = new CustosMineController(
            owner,
            custodians,
            oracle,
            address(0), // custosMineRewards — set after rewards deployment
            address(custos),
            T1, T2, T3
        );

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

        // Wire controller → rewards
        vm.prank(custodian);
        controller.setCustosMineRewards(address(rewards));

        // Seed zeroEx with CUSTOS for swaps
        custos.mint(address(zeroEx), 1_000_000_000e18);
        // Wire weth into mock zeroEx (so it can pull allowances)
        zeroEx.setWeth(weth);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _openEpoch() internal {
        vm.prank(oracle);
        controller.openEpoch(0);
    }

    function _registerMiner(address miner, uint256 bal) internal {
        custos.mint(miner, bal);
        vm.prank(miner);
        controller.registerForEpoch();
    }

    function _postChallenge(string memory answer) internal returns (uint256 challengeId, bytes32 answerHash) {
        answerHash = keccak256(abi.encodePacked(answer));
        bytes32 questionHash = keccak256("q");
        vm.prank(oracle);
        challengeId = controller.postChallenge("ipfs://Qm", questionHash, answerHash);
    }

    function _commit(address miner, uint256 challengeId, string memory answer, bytes32 salt) internal {
        bytes32 commitHash = keccak256(abi.encodePacked(answer, salt));
        vm.prank(miner);
        controller.commit(challengeId, commitHash);
    }

    function _reveal(address miner, uint256 challengeId, string memory answer, bytes32 salt) internal {
        vm.prank(miner);
        controller.reveal(challengeId, answer, salt);
    }

    function _settleChallenge(uint256 challengeId, string memory answer) internal {
        CustosMineController.Challenge memory ch = controller.getChallenge(challengeId);
        vm.warp(ch.revealCloseAt + 1);
        vm.prank(oracle);
        controller.settleChallenge(challengeId, answer);
    }

    function _closeEpoch() internal {
        vm.prank(oracle);
        controller.closeEpoch();
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
        // Seed 500k CUSTOS into pendingRewards via custodian seed
        custos.mint(address(controller), 500_000e18);
        vm.prank(custodian);
        controller.seedRewards(500_000e18);

        _openEpoch();
        CustosMineController.Epoch memory e = controller.getEpoch(1);
        assertEq(e.rewardPool, 500_000e18);
        assertEq(controller.pendingRewards(), 0);
    }

    function test_openEpoch_revertsIfAlreadyOpen() public {
        _openEpoch();
        vm.prank(oracle);
        vm.expectRevert("epoch already open");
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
        vm.expectRevert("no active epoch");
        controller.closeEpoch();
    }

    function test_multipleEpochs_incrementId() public {
        _openEpoch();
        _closeEpoch();
        _openEpoch();
        assertEq(controller.currentEpochId(), 2);
    }
}

contract MineControllerRegistrationTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        _openEpoch();
    }

    function test_registerForEpoch_setsSnapshot() public {
        _registerMiner(miner1, T1);
        assertTrue(controller.isRegistered(miner1, 1));
        assertEq(controller.getSnapshot(miner1, 1), T1);
        assertEq(controller.getEpochTier(miner1, 1), 1);
    }

    function test_registerForEpoch_tier2() public {
        _registerMiner(miner1, T2);
        assertEq(controller.getEpochTier(miner1, 1), 2);
    }

    function test_registerForEpoch_tier3() public {
        _registerMiner(miner1, T3);
        assertEq(controller.getEpochTier(miner1, 1), 3);
    }

    function test_registerForEpoch_revertsBelow_Tier1() public {
        custos.mint(miner1, T1 - 1);
        vm.prank(miner1);
        vm.expectRevert("insufficient CUSTOS for tier 1");
        controller.registerForEpoch();
    }

    function test_registerForEpoch_revertsDoubleRegister() public {
        _registerMiner(miner1, T1);
        vm.prank(miner1);
        vm.expectRevert("already registered");
        controller.registerForEpoch();
    }

    function test_registerForEpoch_revertsAfterCutoff() public {
        CustosMineController.Epoch memory e = controller.getEpoch(1);
        vm.warp(e.endAt - 3599); // 1 second past cutoff
        custos.mint(miner1, T1);
        vm.prank(miner1);
        vm.expectRevert("registration closed");
        controller.registerForEpoch();
    }

    function test_snapshot_immutableAfterTransfer() public {
        // Register with T2 balance
        custos.mint(miner1, T2);
        vm.prank(miner1);
        controller.registerForEpoch();

        // Transfer tokens away — snapshot should NOT change
        vm.prank(miner1);
        custos.transfer(miner2, T2 - T1 + 1); // now below T2

        // Snapshot still T2
        assertEq(controller.getSnapshot(miner1, 1), T2);
        assertEq(controller.getEpochTier(miner1, 1), 2);
    }
}

contract MineControllerCommitRevealTest is MineTestBase {

    bytes32 constant SALT = keccak256("test-salt");
    string  constant ANSWER = "42069";

    function setUp() public override {
        super.setUp();
        _openEpoch();
        _registerMiner(miner1, T1);
        _registerMiner(miner2, T2);
        _registerMiner(miner3, T3);
    }

    function test_postChallenge_setsFields() public {
        (uint256 cid, bytes32 ah) = _postChallenge(ANSWER);
        assertEq(cid, 1);
        CustosMineController.Challenge memory ch = controller.getCurrentChallenge();
        assertEq(ch.challengeId, 1);
        assertEq(ch.answerHash, ah);
        assertEq(ch.epochId, 1);
        assertFalse(ch.settled);
        assertTrue(controller.isCommitOpen());
    }

    function test_commit_succeeds() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        _commit(miner1, cid, ANSWER, SALT);
        (bytes32 commitHash,,,,bool committed,,,uint256 credits) = _getSubmission(cid, miner1);
        assertTrue(committed);
        assertEq(commitHash, keccak256(abi.encodePacked(ANSWER, SALT)));
        assertEq(credits, 0); // not yet settled
    }

    function test_commit_revertsNotRegistered() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        vm.prank(makeAddr("unregistered"));
        vm.expectRevert("register for epoch first");
        controller.commit(cid, bytes32(uint256(1)));
    }

    function test_commit_revertsAfterWindow() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        CustosMineController.Challenge memory ch = controller.getChallenge(cid);
        vm.warp(ch.commitCloseAt + 1);
        vm.prank(miner1);
        vm.expectRevert("commit window closed");
        controller.commit(cid, bytes32(uint256(1)));
    }

    function test_commit_revertsDoubleCommit() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        _commit(miner1, cid, ANSWER, SALT);
        vm.prank(miner1);
        vm.expectRevert("already committed");
        controller.commit(cid, bytes32(uint256(2)));
    }

    function test_reveal_succeeds() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        _commit(miner1, cid, ANSWER, SALT);
        CustosMineController.Challenge memory ch = controller.getChallenge(cid);
        vm.warp(ch.commitCloseAt + 1);
        _reveal(miner1, cid, ANSWER, SALT);
        (,,,, bool committed, bool revealed,,) = _getSubmission(cid, miner1);
        assertTrue(committed);
        assertTrue(revealed);
    }

    function test_reveal_revertsWrongSalt() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        _commit(miner1, cid, ANSWER, SALT);
        CustosMineController.Challenge memory ch = controller.getChallenge(cid);
        vm.warp(ch.commitCloseAt + 1);
        vm.prank(miner1);
        vm.expectRevert("reveal mismatch");
        controller.reveal(cid, ANSWER, keccak256("wrong-salt"));
    }

    function test_reveal_revertsNotCommitted() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        CustosMineController.Challenge memory ch = controller.getChallenge(cid);
        vm.warp(ch.commitCloseAt + 1);
        vm.prank(miner1);
        vm.expectRevert("not committed");
        controller.reveal(cid, ANSWER, SALT);
    }

    function test_settle_awardsCreditsCorrectly() public {
        (uint256 cid,) = _postChallenge(ANSWER);

        // miner1 (tier 1) correct
        _commit(miner1, cid, ANSWER, SALT);
        // miner2 (tier 2) correct
        bytes32 salt2 = keccak256("salt2");
        _commit(miner2, cid, ANSWER, salt2);
        // miner3 (tier 3) WRONG
        bytes32 salt3 = keccak256("salt3");
        _commit(miner3, cid, "wrong", salt3);

        CustosMineController.Challenge memory ch = controller.getChallenge(cid);
        vm.warp(ch.commitCloseAt + 1);
        _reveal(miner1, cid, ANSWER, SALT);
        _reveal(miner2, cid, ANSWER, salt2);
        _reveal(miner3, cid, "wrong", salt3);

        _settleChallenge(cid, ANSWER);

        // credits: miner1 = 1 (tier 1), miner2 = 2 (tier 2), miner3 = 0 (wrong)
        assertEq(controller.getCredits(miner1, 1), 1);
        assertEq(controller.getCredits(miner2, 1), 2);
        assertEq(controller.getCredits(miner3, 1), 0);

        CustosMineController.Epoch memory e = controller.getEpoch(1);
        assertEq(e.totalCredits, 3);
    }

    function test_settle_revertsWrongAnswer() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        _settleChallenge_passTime(cid);
        vm.prank(oracle);
        vm.expectRevert("answer mismatch");
        controller.settleChallenge(cid, "completely wrong");
    }

    function test_settle_revertsBeforeRevealClose() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        vm.prank(oracle);
        vm.expectRevert("reveal window not closed");
        controller.settleChallenge(cid, ANSWER);
    }

    function test_settle_revertsDoubleSettle() public {
        (uint256 cid,) = _postChallenge(ANSWER);
        _settleChallenge(cid, ANSWER);
        vm.prank(oracle);
        vm.expectRevert("already settled");
        controller.settleChallenge(cid, ANSWER);
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    function _getSubmission(uint256 cid, address wallet) internal view returns (
        bytes32 commitHash, uint256 tier, string memory revealedAnswer, bytes32 revealedSalt,
        bool committed, bool revealed, bool correct, uint256 credits
    ) {
        (commitHash, tier, revealedAnswer, revealedSalt, committed, revealed, correct, credits) =
            controller.submissions(cid, wallet);
    }

    function _settleChallenge_passTime(uint256 cid) internal {
        CustosMineController.Challenge memory ch = controller.getChallenge(cid);
        vm.warp(ch.revealCloseAt + 1);
    }
}

contract MineControllerClaimTest is MineTestBase {

    bytes32 constant SALT1 = keccak256("salt1");
    bytes32 constant SALT2 = keccak256("salt2");
    string  constant ANSWER = "12345";

    uint256 constant POOL = 1_000_000e18; // 1M CUSTOS reward pool

    function setUp() public override {
        super.setUp();

        // Seed reward pool
        custos.mint(address(controller), POOL);
        vm.prank(custodian);
        controller.seedRewards(POOL);

        _openEpoch();
        _registerMiner(miner1, T1); // 1x credits
        _registerMiner(miner2, T2); // 2x credits

        // Full round: both miners commit + reveal + settle
        (uint256 cid,) = _postAndFullSettle();
        // miner1 = 1 credit, miner2 = 2 credits, total = 3
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
        vm.expectRevert("already claimed");
        controller.claimEpochReward(1);
    }

    function test_claim_revertsNoCredits() public {
        // miner3 never participated
        vm.prank(miner3);
        vm.expectRevert("no credits");
        controller.claimEpochReward(1);
    }

    function test_claim_revertsAfterWindow() public {
        CustosMineController.Epoch memory e = controller.getEpoch(1);
        vm.warp(e.endAt + 30 days + 1);
        vm.prank(miner1);
        vm.expectRevert("claim window expired");
        controller.claimEpochReward(1);
    }

    function test_getClaimable_returnsZeroIfNotSettled() public {
        // New epoch, not settled yet
        _openEpoch();
        assertEq(controller.getClaimable(miner1, 2), 0);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _postAndFullSettle() internal returns (uint256 cid, bytes32 ah) {
        ah = keccak256(abi.encodePacked(ANSWER));
        vm.prank(oracle);
        cid = controller.postChallenge("ipfs://test", keccak256("q"), ah);

        vm.prank(miner1);
        controller.commit(cid, keccak256(abi.encodePacked(ANSWER, SALT1)));
        vm.prank(miner2);
        controller.commit(cid, keccak256(abi.encodePacked(ANSWER, SALT2)));

        CustosMineController.Challenge memory ch = controller.getChallenge(cid);
        vm.warp(ch.commitCloseAt + 1);
        vm.prank(miner1);
        controller.reveal(cid, ANSWER, SALT1);
        vm.prank(miner2);
        controller.reveal(cid, ANSWER, SALT2);

        vm.warp(ch.revealCloseAt + 1);
        vm.prank(oracle);
        controller.settleChallenge(cid, ANSWER);
    }
}

contract MineControllerSeedTest is MineTestBase {

    function test_seedRewards_addsToPending() public {
        uint256 amt = 500_000e18;
        custos.mint(address(controller), amt);
        vm.prank(custodian);
        controller.seedRewards(amt);
        assertEq(controller.pendingRewards(), amt);
    }

    function test_seedRewards_revertsInsufficientBalance() public {
        // Don't transfer CUSTOS first
        vm.prank(custodian);
        vm.expectRevert("insufficient balance - transfer first");
        controller.seedRewards(1e18);
    }

    function test_receiveCustos_onlyFromRewardsContract() public {
        custos.mint(address(this), 1e18);
        custos.approve(address(controller), 1e18);
        vm.expectRevert("not mine rewards contract");
        controller.receiveCustos(1e18);
    }

    function test_receiveCustos_addsToPending() public {
        // Simulate CustosMineRewards sending CUSTOS
        vm.prank(address(rewards));
        // rewards contract must have CUSTOS to transfer — we transfer it directly here
        custos.mint(address(controller), 100e18);
        // Note: receiveCustos() just increments pendingRewards — it doesn't do a transfer
        // The transfer happens in CustosMineRewards.swapAndSend() before calling receiveCustos()
        vm.prank(address(rewards));
        controller.receiveCustos(100e18);
        assertEq(controller.pendingRewards(), 100e18);
    }
}

contract MineControllerRecoveryTest is MineTestBase {

    function setUp() public override {
        super.setUp();
        _openEpoch();
    }

    function test_recoverERC20_nonCustos() public {
        MockWETH other = new MockWETH();
        other.mint(address(controller), 1 ether);
        vm.prank(custodian);
        controller.recoverERC20(address(other), 1 ether, custodian);
        assertEq(other.balanceOf(custodian), 1 ether);
    }

    function test_recoverERC20_custos_guardsActivePool() public {
        // Seed pool + open epoch — can't drain active pool
        uint256 pool = 1_000_000e18;
        custos.mint(address(controller), pool);
        vm.prank(custodian);
        controller.seedRewards(pool);

        // openEpoch() was already called in setUp, but no rewards were in pendingRewards
        // Close and reopen to capture the pool
        _closeEpoch();
        _openEpoch(); // now epoch 2 with pool = 1M

        CustosMineController.Epoch memory e = controller.getEpoch(2);
        assertEq(e.rewardPool, pool);

        // Try to recover all CUSTOS — should revert (would drain active pool)
        vm.prank(custodian);
        vm.expectRevert("would drain rewards");
        controller.recoverERC20(address(custos), pool, custodian);
    }

    function test_recoverERC20_revertsNonAuthorised() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("not authorised");
        controller.recoverERC20(address(custos), 1, custodian);
    }
}

contract MineControllerConfigTest is MineTestBase {

    function test_setTierThresholds() public {
        vm.prank(custodian);
        controller.setTierThresholds(10e18, 20e18, 30e18);
        assertEq(controller.tier1Threshold(), 10e18);
        assertEq(controller.tier2Threshold(), 20e18);
        assertEq(controller.tier3Threshold(), 30e18);
    }

    function test_setTierThresholds_revertsInvalidOrder() public {
        vm.prank(custodian);
        vm.expectRevert("invalid thresholds");
        controller.setTierThresholds(30e18, 20e18, 10e18);
    }

    function test_setOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(custodian);
        controller.setOracle(newOracle);
        assertEq(controller.oracle(), newOracle);
    }

    function test_setOracle_revertsNonCustodian() public {
        vm.prank(oracle);
        vm.expectRevert("not custodian");
        controller.setOracle(makeAddr("x"));
    }

    function test_setPaused_blocksOperations() public {
        // openEpoch first (no notPaused), then pause, then registerForEpoch reverts
        vm.prank(oracle);
        controller.openEpoch(0);

        vm.prank(custodian);
        controller.setPaused(true);

        custos.mint(makeAddr("p"), T1);
        vm.prank(makeAddr("p"));
        vm.expectRevert("paused");
        controller.registerForEpoch();
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

        // Controller received CUSTOS into pendingRewards
        assertEq(controller.pendingRewards(), custosOut);
        // WETH drained from rewards (transferred to mock zeroEx)
        assertEq(weth.balanceOf(address(rewards)), 0);
        assertEq(weth.balanceOf(address(zeroEx)), wethAmt);
    }

    function test_swapAndSend_revertsNoWETH() public {
        vm.prank(oracle);
        vm.expectRevert("no WETH to swap");
        rewards.swapAndSend(bytes(""), 0);
    }

    function test_swapAndSend_revertsSlippage() public {
        weth.mint(address(rewards), 1 ether);
        zeroEx.setOutput(1000e18);

        vm.prank(oracle);
        vm.expectRevert("slippage exceeded");
        rewards.swapAndSend(bytes(""), 1001e18); // wants more than mock gives
    }

    function test_recoverFunds_custodianOnly() public {
        weth.mint(address(rewards), 1 ether);
        vm.prank(custodian);
        rewards.recoverFunds(address(weth), 1 ether, custodian);
        assertEq(weth.balanceOf(custodian), 1 ether);
    }

    function test_recoverFunds_revertsNonCustodian() public {
        vm.prank(oracle);
        vm.expectRevert("not custodian");
        rewards.recoverFunds(address(weth), 1, custodian);
    }

    function test_setController() public {
        address newCtrl = makeAddr("newCtrl");
        vm.prank(custodian);
        rewards.setController(newCtrl);
        assertEq(rewards.controller(), newCtrl);
    }
}
