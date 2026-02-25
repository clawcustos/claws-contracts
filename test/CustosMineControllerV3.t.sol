// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {CustosMineControllerV3} from "../src/CustosMineControllerV3.sol";

// ── Minimal ERC20 mock ────────────────────────────────────────────────────────
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        require(allowance[from][msg.sender] >= amt, "alw");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; return true;
    }
}

// ── Minimal proxy mock (ICustosProxy) ─────────────────────────────────────────
contract MockProxy {
    struct Ins {
        string  blockType;
        uint256 revealTime;
        uint256 roundId;
        address agent;
        bool    revealed;
        string  content;
        bytes32 contentHash;
    }
    mapping(uint256 => Ins) private _ins;

    function set(
        uint256 id,
        string memory blockType,
        uint256 revealTime,
        uint256 roundId,
        address agent,
        bool revealed,
        string memory content,
        bytes32 contentHash
    ) external {
        _ins[id] = Ins(blockType, revealTime, roundId, agent, revealed, content, contentHash);
    }

    function inscriptionBlockType(uint256 id) external view returns (string memory) { return _ins[id].blockType; }
    function inscriptionRevealTime(uint256 id) external view returns (uint256)       { return _ins[id].revealTime; }
    function inscriptionRoundId(uint256 id)    external view returns (uint256)       { return _ins[id].roundId; }
    function inscriptionAgent(uint256 id)      external view returns (address)       { return _ins[id].agent; }
    function getInscriptionContent(uint256 id) external view returns (bool, string memory, bytes32) {
        Ins memory i = _ins[id];
        return (i.revealed, i.content, i.contentHash);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────
contract CustosMineControllerV3Test is Test {
    CustosMineControllerV3 mine;
    MockERC20 custos;
    MockProxy proxy;

    address owner   = address(0x1);
    address oracle  = address(0x2);
    address pizza   = address(0x3);
    address rewards = address(0xFEE);
    address agent1  = address(0xA1);
    address agent2  = address(0xA2);

    uint256 constant T1 = 25_000_000e18;
    uint256 constant T2 = 50_000_000e18;
    uint256 constant T3 = 100_000_000e18;

    function setUp() public {
        custos = new MockERC20();
        proxy  = new MockProxy();

        vm.prank(owner);
        mine = new CustosMineControllerV3(
            address(custos),
            address(proxy),
            rewards,
            oracle,
            T1, T2, T3
        );

        vm.startPrank(owner);
        mine.setCustodian(pizza, true);
        mine.setCustodian(owner, true);
        vm.stopPrank();

        custos.mint(agent1, T1 * 4);
        custos.mint(agent2, T2 * 4);
        // seed mine with reward buffer
        custos.mint(address(mine), 10_000_000e18);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_OwnerSet() public view { assertEq(mine.owner(), owner); }
    function test_OracleSet() public view { assertEq(mine.oracle(), oracle); }
    function test_CustodianSet() public view { assertTrue(mine.custodians(pizza)); }

    function test_NonOwnerCannotSetCustodian() public {
        vm.prank(pizza);
        vm.expectRevert(bytes("E26"));
        mine.setCustodian(address(0x99), true);
    }

    function test_TransferOwnership() public {
        vm.prank(owner); mine.transferOwnership(pizza);
        assertEq(mine.owner(), pizza);
    }

    function test_SetOracleCustodianOnly() public {
        vm.prank(pizza); mine.setOracle(address(0x55));
        assertEq(mine.oracle(), address(0x55));
    }

    function test_NonCustodianCannotSetOracle() public {
        vm.prank(agent1);
        vm.expectRevert(bytes("E25"));
        mine.setOracle(address(0x55));
    }

    // ── Staking ───────────────────────────────────────────────────────────────

    function test_StakeTier1() public {
        _stake(agent1, T1);
        CustosMineControllerV3.StakePosition memory s = mine.getStake(agent1);
        assertEq(s.amount, T1);
        assertFalse(s.withdrawalQueued);
    }

    function test_StakeBelowTier1Reverts() public {
        vm.startPrank(agent1);
        custos.approve(address(mine), T1 - 1);
        vm.expectRevert(bytes("E13"));
        mine.stake(T1 - 1);
        vm.stopPrank();
    }

    function test_StakedAgentCountIncreases() public {
        _stake(agent1, T1);
        assertEq(mine.getStakedAgentCount(), 1);
    }

    function test_Unstake() public {
        _stake(agent1, T1);
        vm.prank(agent1); mine.unstake();
        assertTrue(mine.getStake(agent1).withdrawalQueued);
    }

    function test_CancelUnstake() public {
        _stake(agent1, T1);
        vm.prank(agent1); mine.unstake();
        vm.prank(agent1); mine.cancelUnstake();
        assertFalse(mine.getStake(agent1).withdrawalQueued);
    }

    function test_WithdrawStakeAfterEpoch() public {
        _stake(agent1, T1);
        vm.prank(agent1); mine.unstake();
        _runMinimalEpoch(false); // no settle needed
        vm.prank(oracle); mine.pruneExitedStakers(100);

        uint256 before = custos.balanceOf(agent1);
        vm.prank(agent1); mine.withdrawStake();
        assertEq(custos.balanceOf(agent1), before + T1);
    }

    // ── Epoch lifecycle ───────────────────────────────────────────────────────

    function test_OpenEpoch() public {
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        CustosMineControllerV3.Epoch memory e = mine.getEpoch(mine.currentEpochId());
        assertTrue(e.epochId > 0);
    }

    function test_NonOracleCannotOpenEpoch() public {
        vm.prank(agent1);
        vm.expectRevert(bytes("E24"));
        mine.openEpoch(block.timestamp);
    }

    function test_CannotOpenEpochTwice() public {
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle);
        vm.expectRevert(bytes("E11"));
        mine.openEpoch(block.timestamp);
    }

    function test_SnapshotBatch() public {
        _stake(agent1, T1);
        _stake(agent2, T2);
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.snapshotBatch(100);

        uint256 eid = mine.currentEpochId();
        assertEq(mine.getTierSnapshot(agent1, eid), 1);
        assertEq(mine.getTierSnapshot(agent2, eid), 2);
    }

    function test_CloseEpoch() public {
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.warp(block.timestamp + 86401);
        vm.prank(oracle); mine.closeEpoch();
        vm.prank(oracle); mine.accumulateCreditsBatch(100);
        vm.prank(oracle); mine.finalizeClose();
        // epoch settled
        CustosMineControllerV3.Epoch memory e = mine.getEpoch(mine.currentEpochId());
        assertTrue(e.settled);
    }

    // ── Round lifecycle ───────────────────────────────────────────────────────

    function test_PostRound() public {
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.postRound("https://q/1", _ansHash("ans", "salt"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();
        assertEq(r.roundId, 1);
        assertFalse(r.settled);
    }

    function test_NonOracleCannotPostRound() public {
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(agent1);
        vm.expectRevert(bytes("E24"));
        mine.postRound("q", bytes32(0));
    }

    function test_SettleRoundCorrectAnswer() public {
        _stake(agent1, T1);
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.snapshotBatch(100);

        vm.prank(oracle); mine.postRound("q", _ansHash("ans42", "s"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();

        // revealTime must be within [commitCloseAt, revealCloseAt]
        proxy.set(1, "mine-commit", r.commitCloseAt + 1, r.roundId, agent1, true, "ans42", keccak256(abi.encodePacked("ans42")));
        // settle requires block.timestamp >= revealCloseAt
        vm.warp(r.revealCloseAt);

        uint256[] memory ids = new uint256[](1); ids[0] = 1;
        vm.prank(oracle); mine.settleRound(r.roundId, "ans42", ids);

        assertTrue(mine.getRound(r.roundId).settled);
        assertEq(mine.getRound(r.roundId).correctCount, 1);
        assertEq(mine.getCredits(agent1, mine.currentEpochId()), 1);
    }

    function test_SettleRoundWrongAnswerNoCredit() public {
        _stake(agent1, T1);
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.snapshotBatch(100);
        vm.prank(oracle); mine.postRound("q", _ansHash("correct", "s"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();

        proxy.set(1, "mine-commit", r.commitCloseAt + 1, r.roundId, agent1, true, "wrong", keccak256(abi.encodePacked("wrong")));
        vm.warp(r.revealCloseAt);
        uint256[] memory ids = new uint256[](1); ids[0] = 1;
        vm.prank(oracle); mine.settleRound(r.roundId, "correct", ids);

        assertEq(mine.getCredits(agent1, mine.currentEpochId()), 0);
    }

    function test_SettleRoundWrongBlockTypeNoCredit() public {
        _stake(agent1, T1);
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.snapshotBatch(100);
        vm.prank(oracle); mine.postRound("q", _ansHash("a", "s"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();

        proxy.set(1, "build", r.commitCloseAt + 1, r.roundId, agent1, true, "a", keccak256(abi.encodePacked("a")));
        vm.warp(r.revealCloseAt);
        uint256[] memory ids = new uint256[](1); ids[0] = 1;
        vm.prank(oracle); mine.settleRound(r.roundId, "a", ids);

        assertEq(mine.getCredits(agent1, mine.currentEpochId()), 0);
    }

    function test_SettleRoundUnstakedAgentNoCredit() public {
        // agent1 not staked — stakedAgents is empty, openEpoch auto-sets snapshotComplete
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        // No snapshotBatch needed (snapshotComplete=true when no stakers)
        vm.prank(oracle); mine.postRound("q", _ansHash("a", "s"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();

        proxy.set(1, "mine-commit", r.commitCloseAt + 1, r.roundId, agent1, true, "a", keccak256(abi.encodePacked("a")));
        vm.warp(r.revealCloseAt);
        uint256[] memory ids = new uint256[](1); ids[0] = 1;
        vm.prank(oracle); mine.settleRound(r.roundId, "a", ids);

        assertEq(mine.getCredits(agent1, mine.currentEpochId()), 0);
    }

    function test_ExpireRound() public {
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.postRound("q", _ansHash("a", "s"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();
        // expireRound requires block.timestamp > revealCloseAt + 300
        vm.warp(r.revealCloseAt + 301);
        mine.expireRound(r.roundId);
        assertTrue(mine.getRound(r.roundId).expired);
    }

    // ── Rewards & claims ──────────────────────────────────────────────────────

    function test_ClaimReward() public {
        _stake(agent1, T1);
        // allocate rewards BEFORE openEpoch — rewardPool is snapshotted at open
        vm.prank(pizza); mine.allocateRewards(1_000_000e18);
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.snapshotBatch(100);

        vm.prank(oracle); mine.postRound("q", _ansHash("X", "s"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();
        proxy.set(1, "mine-commit", r.commitCloseAt + 1, r.roundId, agent1, true, "X", keccak256(abi.encodePacked("X")));
        vm.warp(r.revealCloseAt);
        uint256[] memory ids = new uint256[](1); ids[0] = 1;
        vm.prank(oracle); mine.settleRound(r.roundId, "X", ids);

        vm.warp(block.timestamp + 86401);
        vm.prank(oracle); mine.closeEpoch();
        vm.prank(oracle); mine.accumulateCreditsBatch(100);
        vm.prank(oracle); mine.finalizeClose();

        uint256 eid = mine.currentEpochId();
        uint256 claimable = mine.getClaimable(agent1, eid);
        assertGt(claimable, 0);

        uint256 before = custos.balanceOf(agent1);
        vm.prank(agent1); mine.claimEpochReward(eid);
        assertEq(custos.balanceOf(agent1), before + claimable);
    }

    function test_CannotClaimTwice() public {
        _fullEpochWithCredit();
        uint256 eid = mine.currentEpochId();
        vm.prank(agent1); mine.claimEpochReward(eid);
        vm.prank(agent1);
        vm.expectRevert(bytes("E21"));
        mine.claimEpochReward(eid);
    }

    function test_DepositRewards() public {
        custos.mint(pizza, 500_000e18);
        vm.prank(pizza); custos.approve(address(mine), 500_000e18);
        vm.prank(pizza); mine.depositRewards(500_000e18);
        assertEq(mine.rewardBuffer(), 500_000e18);
    }

    function test_AllocateRewards() public {
        // Mine already has 10M seeded. allocateRewards moves rewardBuffer to epoch pool on openEpoch.
        uint256 bufBefore = mine.rewardBuffer();
        vm.prank(pizza); mine.allocateRewards(1_000_000e18);
        assertEq(mine.rewardBuffer(), bufBefore + 1_000_000e18);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    function test_PauseBlocksStake() public {
        vm.prank(pizza); mine.pause();
        vm.startPrank(agent1);
        custos.approve(address(mine), T1);
        vm.expectRevert(bytes("E27"));
        mine.stake(T1);
        vm.stopPrank();
    }

    function test_UnpauseAllowsStake() public {
        vm.prank(pizza); mine.pause();
        vm.prank(pizza); mine.unpause();
        _stake(agent1, T1);
        assertEq(mine.getStake(agent1).amount, T1);
    }

    // ── Recovery ──────────────────────────────────────────────────────────────

    function test_RecoverNonCustosToken() public {
        MockERC20 other = new MockERC20();
        other.mint(address(mine), 1000e18);
        uint256 before = other.balanceOf(pizza);
        vm.prank(pizza); mine.recoverERC20(address(other), 1000e18, pizza);
        assertEq(other.balanceOf(pizza), before + 1000e18);
    }

    function test_RecoverCustosProtectsStakedAmount() public {
        // Stake agent1 so their CUSTOS is protected
        _stake(agent1, T1);
        // Try to recover entire balance — should revert E48 (insufficient unprotected)
        uint256 bal = custos.balanceOf(address(mine));
        vm.prank(pizza);
        vm.expectRevert(bytes("E48"));
        mine.recoverERC20(address(custos), bal, pizza);
    }

    // ── Tier thresholds ───────────────────────────────────────────────────────

    function test_SetTierThresholds() public {
        vm.prank(pizza); mine.setTierThresholds(10e18, 20e18, 30e18);
        // Must wait for next epoch — pendingTier thresholds apply after epoch boundary
        // For now verify thresholds are queued (pendingTierThresholds set)
        // Just verify the call succeeds and existing tier still enforced on current threshold
        custos.mint(address(0xBB), T1 * 2);
        vm.startPrank(address(0xBB));
        custos.approve(address(mine), T1);
        mine.stake(T1); // still works at old tier1
        vm.stopPrank();
        assertEq(mine.getStake(address(0xBB)).amount, T1);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev answerHash stored by oracle = keccak256(abi.encodePacked(correctAnswer))
    function _ansHash(string memory answer, string memory /*salt*/) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer));
    }

    function _stake(address who, uint256 amt) internal {
        vm.startPrank(who);
        custos.approve(address(mine), amt);
        mine.stake(amt);
        vm.stopPrank();
    }

    function _runMinimalEpoch(bool withSettle) internal {
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        if (withSettle) {
            vm.prank(oracle); mine.snapshotBatch(100);
        }
        vm.warp(block.timestamp + 86401);
        vm.prank(oracle); mine.closeEpoch();
        vm.prank(oracle); mine.accumulateCreditsBatch(100);
        vm.prank(oracle); mine.finalizeClose();
    }

    function _fullEpochWithCredit() internal {
        _stake(agent1, T1);
        vm.prank(pizza); mine.allocateRewards(1_000_000e18);
        vm.prank(oracle); mine.openEpoch(block.timestamp);
        vm.prank(oracle); mine.snapshotBatch(100);

        vm.prank(oracle); mine.postRound("q", _ansHash("Z", "s"));
        CustosMineControllerV3.Round memory r = mine.getCurrentRound();
        proxy.set(1, "mine-commit", r.commitCloseAt + 1, r.roundId, agent1, true, "Z", keccak256(abi.encodePacked("Z")));
        vm.warp(r.revealCloseAt);
        uint256[] memory ids = new uint256[](1); ids[0] = 1;
        vm.prank(oracle); mine.settleRound(r.roundId, "Z", ids);

        vm.warp(block.timestamp + 86401);
        vm.prank(oracle); mine.closeEpoch();
        vm.prank(oracle); mine.accumulateCreditsBatch(100);
        vm.prank(oracle); mine.finalizeClose();
    }
}
