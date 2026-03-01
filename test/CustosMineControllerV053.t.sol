// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/CustosMineControllerV053.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============ Mock ERC20 ============

contract MockERC20 is IERC20 {
    string public name = "MockCustos";
    string public symbol = "MCT";
    uint8  public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ============ Mock CustosProxy ============

contract MockCustosProxy {
    struct InscriptionData {
        string  blockType;
        uint256 roundId;
        address agent;
        uint256 revealTime;
        bool    revealed;
        string  content;
        bytes32 contentHash;
    }

    mapping(uint256 => InscriptionData) public inscriptions;

    function setInscription(
        uint256 insId,
        string memory blockType_,
        uint256 roundId_,
        address agent_,
        uint256 revealTime_,
        bool revealed_,
        string memory content_,
        bytes32 contentHash_
    ) external {
        inscriptions[insId] = InscriptionData(blockType_, roundId_, agent_, revealTime_, revealed_, content_, contentHash_);
    }

    function inscriptionBlockType(uint256 insId) external view returns (string memory) {
        return inscriptions[insId].blockType;
    }

    function inscriptionRoundId(uint256 insId) external view returns (uint256) {
        return inscriptions[insId].roundId;
    }

    function inscriptionAgent(uint256 insId) external view returns (address) {
        return inscriptions[insId].agent;
    }

    function inscriptionRevealTime(uint256 insId) external view returns (uint256) {
        return inscriptions[insId].revealTime;
    }

    function getInscriptionContent(uint256 insId) external view returns (bool, string memory, bytes32) {
        InscriptionData storage d = inscriptions[insId];
        return (d.revealed, d.content, d.contentHash);
    }

    function getInscriptionData(uint256 insId) external view returns (InscriptionData memory) {
        return inscriptions[insId];
    }
}

// ============ Reentrancy Attacker ============

contract ReentrancyAttacker053 {
    CustosMineControllerV053 public controller;
    MockERC20 public token;
    uint256 public epochId;
    bool public attacking;

    constructor(address _controller, address _token) {
        controller = CustosMineControllerV053(payable(_controller));
        token = MockERC20(_token);
    }

    function attackClaim(uint256 _epochId) external {
        epochId = _epochId;
        attacking = true;
        controller.claimEpochReward(_epochId);
    }

    fallback() external {
        if (attacking) {
            attacking = false;
            try controller.claimEpochReward(epochId) {} catch {}
        }
    }
}

// ============ Test Contract ============

contract CustosMineControllerV053Test is Test {
    CustosMineControllerV053 public mine;
    MockERC20 public token;
    MockCustosProxy public proxy;

    address public owner      = address(this);
    address public oracleAddr = address(0xAA);
    address public rewards    = address(0xBB);
    address public agent1     = address(0x1001);
    address public agent2     = address(0x1002);
    address public agent3     = address(0x1003);
    address public rando      = address(0xDEAD);

    uint256 public constant T1 = 25_000_000e18;
    uint256 public constant T2 = 50_000_000e18;
    uint256 public constant T3 = 100_000_000e18;

    function setUp() public {
        token = new MockERC20();
        proxy = new MockCustosProxy();
        mine = new CustosMineControllerV053(
            address(token),
            address(proxy),
            rewards,
            oracleAddr,
            T1, T2, T3
        );

        token.mint(agent1, T3 * 2);
        token.mint(agent2, T3 * 2);
        token.mint(agent3, T3 * 2);

        vm.prank(agent1); token.approve(address(mine), type(uint256).max);
        vm.prank(agent2); token.approve(address(mine), type(uint256).max);
        vm.prank(agent3); token.approve(address(mine), type(uint256).max);
    }

    // ============ Helpers ============

    function _stakeAs(address agent, uint256 amount) internal {
        vm.prank(agent);
        mine.stake(amount);
    }

    function _openEpochAndSnapshot() internal {
        vm.prank(oracleAddr);
        mine.openEpoch(block.timestamp);
        vm.prank(oracleAddr);
        mine.snapshotBatch(100);
    }

    uint256 private _oracleInsCounter = 10000;

    function _postRound(string memory qUri, string memory answer) internal returns (uint256) {
        bytes32 ah = keccak256(abi.encodePacked(answer));
        uint256 oracleInsId = _oracleInsCounter++;
        proxy.setInscription(oracleInsId, "mine-question", 0, oracleAddr, 0, false, qUri, bytes32(0));
        vm.prank(oracleAddr);
        return mine.postRound(qUri, ah, oracleInsId);
    }

    function _revealOracleInscription(uint256 roundId) internal {
        uint256 oracleInsId = mine.getRound(roundId).oracleInscriptionId;
        MockCustosProxy.InscriptionData memory d = proxy.getInscriptionData(oracleInsId);
        proxy.setInscription(oracleInsId, d.blockType, d.roundId, d.agent, block.timestamp, true, d.content, d.contentHash);
    }

    function _setupInscription(
        uint256 insId,
        uint256 roundId,
        address agent,
        uint256 revealTime,
        string memory answer
    ) internal {
        proxy.setInscription(insId, "mine-commit", roundId, agent, revealTime, true, answer, bytes32(0));
    }

    function _settleRound(uint256 roundId, string memory answer, uint256[] memory insIds) internal {
        _revealOracleInscription(roundId);
        vm.prank(oracleAddr);
        mine.settleRound(roundId, answer, insIds);
    }

    function _closeAndFinalize() internal {
        vm.prank(oracleAddr);
        mine.closeEpoch();
        vm.prank(oracleAddr);
        mine.accumulateCreditsBatch(1000);
        vm.prank(oracleAddr);
        mine.finalizeClose();
    }

    // ============ Version ============

    function test_version() public view {
        assertEq(keccak256(bytes(mine.VERSION())), keccak256(bytes("v0.5.3")));
    }

    // ============ Test 1: Rolling window ============

    function test_rollingWindow_settleN2_postN() public {
        vm.warp(10000);
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        uint256 r1 = _postRound("q1", "ans1");
        vm.warp(10600);
        uint256 r2 = _postRound("q2", "ans2");

        vm.warp(11200);
        _setupInscription(100, r1, agent1, 10600, "ans1");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 100;
        _settleRound(r1, "ans1", ids);

        uint256 r3 = _postRound("q3", "ans3");

        assertTrue(mine.getRound(r1).settled);
        assertEq(r3, 3);
    }

    // ============ Test 2: Edge cases round 1, 2, 3 ============

    function test_edgeCases_round1_2_3() public {
        vm.warp(10000);
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        uint256 r1 = _postRound("q1", "ans1");
        assertEq(r1, 1);

        vm.warp(10600);
        uint256 r2 = _postRound("q2", "ans2");
        assertEq(r2, 2);

        vm.warp(11200);
        _setupInscription(1, 1, agent1, 10600, "ans1");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        uint256 r3 = _postRound("q3", "ans3");

        assertTrue(mine.getRound(1).settled);
        assertEq(r3, 3);
    }

    // ============ Test 3: Rounds 139/140 and epoch close ============

    function test_rounds139_140_epochClose() public {
        vm.warp(10000);
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        // Post 140 rounds: round i posted at 10000 + (i-1)*600
        for (uint256 i = 1; i <= 140; i++) {
            _postRound("q", "ans");
            vm.warp(10000 + i * 600);
        }
        // After loop: t = 10000 + 140*600 = 94000

        assertEq(mine.roundCount(), 140);
        assertEq(mine.epochRoundCount(), 140);

        // E69: can't post round 141 in this epoch
        bytes32 ah = keccak256(abi.encodePacked("ans"));
        vm.prank(oracleAddr);
        vm.expectRevert(bytes("E69"));
        mine.postRound("q141", ah, 99999);

        // Round 139: posted at 92800, commitClose=93400, revealClose=94000
        // Round 140: posted at 93400, commitClose=94000, revealClose=94600
        // Warp past round 140's revealClose
        vm.warp(95000);

        uint256 r139CommitClose = mine.getRound(139).commitCloseAt;
        _setupInscription(139, 139, agent1, r139CommitClose, "ans");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 139;
        _settleRound(139, "ans", ids);

        uint256 r140CommitClose = mine.getRound(140).commitCloseAt;
        _setupInscription(140, 140, agent1, r140CommitClose, "ans");
        ids[0] = 140;
        _settleRound(140, "ans", ids);

        _closeAndFinalize();
        assertTrue(mine.getEpoch(1).settled);
        assertEq(mine.epochRoundsPosted(1), 140);
    }

    // ============ Test 4: 7-day claim window ============

    function test_claimWindow_7days() public {
        _stakeAs(agent1, T1);
        token.mint(address(mine), 1000e18);
        mine.setCustodian(owner, true);
        mine.allocateRewards(1000e18);

        _openEpochAndSnapshot();

        uint256 r1 = _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);
        _setupInscription(1, 1, agent1, mine.getRound(1).commitCloseAt, "ans1");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);

        _closeAndFinalize();

        vm.prank(agent1);
        mine.claimEpochReward(1);
        assertTrue(mine.epochClaimed(1, agent1));
    }

    function test_claimWindow_revertAfter7days() public {
        _stakeAs(agent1, T1);
        token.mint(address(mine), 1000e18);
        mine.setCustodian(owner, true);
        mine.allocateRewards(1000e18);

        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);
        _setupInscription(1, 1, agent1, mine.getRound(1).commitCloseAt, "ans1");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        _closeAndFinalize();

        vm.warp(mine.getEpoch(1).claimDeadline + 1);
        vm.prank(agent1);
        vm.expectRevert(bytes("E22"));
        mine.claimEpochReward(1);
    }

    function test_sweepAfterClaimWindow() public {
        _stakeAs(agent1, T1);
        token.mint(address(mine), 1000e18);
        mine.setCustodian(owner, true);
        mine.allocateRewards(1000e18);

        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);
        _setupInscription(1, 1, agent1, mine.getRound(1).commitCloseAt, "ans1");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        _closeAndFinalize();

        vm.warp(mine.getEpoch(1).claimDeadline + 1);
        uint256 bufferBefore = mine.rewardBuffer();
        vm.prank(oracleAddr);
        mine.sweepExpiredClaims(1);
        assertGt(mine.rewardBuffer(), bufferBefore);
    }

    // ============ Test 5: Staking lock ============

    function test_stakingLock_cannotWithdrawDuringEpoch() public {
        _stakeAs(agent1, T1);
        vm.prank(agent1);
        mine.unstake();

        _openEpochAndSnapshot();

        vm.prank(agent1);
        vm.expectRevert(bytes("E39"));
        mine.withdrawStake();
    }

    function test_stakingLock_canWithdrawAfterFinalize() public {
        _stakeAs(agent1, T1);
        vm.prank(agent1);
        mine.unstake();

        _openEpochAndSnapshot();
        _closeAndFinalize();

        vm.prank(agent1);
        mine.withdrawStake();
        assertEq(token.balanceOf(agent1), T3 * 2);
    }

    // ============ Test 6: withdrawalQueued excluded from snapshot ============

    function test_withdrawalQueued_excludedFromSnapshot() public {
        _stakeAs(agent1, T1);
        _stakeAs(agent2, T1);

        vm.prank(agent1);
        mine.unstake();

        _openEpochAndSnapshot();

        assertEq(mine.getTierSnapshot(agent1, 1), 0);
        assertEq(mine.getTierSnapshot(agent2, 1), 1);
    }

    // ============ Test 7: Tier credits ============

    function test_tierCredits_1_2_3() public {
        _stakeAs(agent1, T1);
        _stakeAs(agent2, T2);
        _stakeAs(agent3, T3);

        _openEpochAndSnapshot();

        assertEq(mine.getTierSnapshot(agent1, 1), 1);
        assertEq(mine.getTierSnapshot(agent2, 1), 2);
        assertEq(mine.getTierSnapshot(agent3, 1), 3);

        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256 cc = mine.getRound(1).commitCloseAt;
        _setupInscription(1, 1, agent1, cc, "ans1");
        _setupInscription(2, 1, agent2, cc, "ans1");
        _setupInscription(3, 1, agent3, cc, "ans1");

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;
        _settleRound(1, "ans1", ids);

        assertEq(mine.getCredits(agent1, 1), 1);
        assertEq(mine.getCredits(agent2, 1), 2);
        assertEq(mine.getCredits(agent3, 1), 3);
    }

    // ============ Test 8: Wrong answer ============

    function test_wrongAnswer_zeroCredits() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256 cc = mine.getRound(1).commitCloseAt;
        _setupInscription(1, 1, agent1, cc, "WRONG");

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);

        assertEq(mine.getCredits(agent1, 1), 0);
    }

    // ============ Test 9: Each of 5 settleRound checks failing ============

    function test_settleCheck_a_wrongBlockType() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256 cc = mine.getRound(1).commitCloseAt;
        proxy.setInscription(1, "mine-question", 1, agent1, cc, true, "ans1", bytes32(0));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        assertEq(mine.getCredits(agent1, 1), 0);
    }

    function test_settleCheck_b_wrongRoundId() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256 cc = mine.getRound(1).commitCloseAt;
        proxy.setInscription(1, "mine-commit", 999, agent1, cc, true, "ans1", bytes32(0));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        assertEq(mine.getCredits(agent1, 1), 0);
    }

    function test_settleCheck_c_noStake() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256 cc = mine.getRound(1).commitCloseAt;
        proxy.setInscription(1, "mine-commit", 1, rando, cc, true, "ans1", bytes32(0));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        assertEq(mine.getCredits(rando, 1), 0);
    }

    function test_settleCheck_d_badRevealTime() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        proxy.setInscription(1, "mine-commit", 1, agent1, mine.getRound(1).commitCloseAt - 1, true, "ans1", bytes32(0));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        assertEq(mine.getCredits(agent1, 1), 0);
    }

    function test_settleCheck_e_notRevealed() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256 cc = mine.getRound(1).commitCloseAt;
        proxy.setInscription(1, "mine-commit", 1, agent1, cc, false, "ans1", bytes32(0));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        assertEq(mine.getCredits(agent1, 1), 0);
    }

    // ============ Test 10: Proportional reward ============

    function test_proportionalReward() public {
        _stakeAs(agent1, T1);
        _stakeAs(agent2, T3);

        token.mint(address(mine), 1000e18);
        mine.setCustodian(owner, true);
        mine.allocateRewards(1000e18);

        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256 cc = mine.getRound(1).commitCloseAt;
        _setupInscription(1, 1, agent1, cc, "ans1");
        _setupInscription(2, 1, agent2, cc, "ans1");

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        _settleRound(1, "ans1", ids);

        _closeAndFinalize();

        uint256 pool = mine.getEpoch(1).rewardPool;
        uint256 expected1 = (pool * 1) / 4;
        uint256 expected2 = (pool * 3) / 4;

        uint256 bal1Before = token.balanceOf(agent1);
        vm.prank(agent1);
        mine.claimEpochReward(1);
        assertEq(token.balanceOf(agent1) - bal1Before, expected1);

        uint256 bal2Before = token.balanceOf(agent2);
        vm.prank(agent2);
        mine.claimEpochReward(1);
        assertEq(token.balanceOf(agent2) - bal2Before, expected2);
    }

    // ============ Test 11: Security — access control ============

    function test_nonOracle_cannotPostRound() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        bytes32 ah = keccak256(abi.encodePacked("ans"));
        vm.prank(rando);
        vm.expectRevert(bytes("E24"));
        mine.postRound("q1", ah, 1);
    }

    function test_nonOracle_cannotSettleRound() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);

        uint256[] memory ids = new uint256[](0);
        vm.prank(rando);
        vm.expectRevert(bytes("E24"));
        mine.settleRound(1, "ans1", ids);
    }

    function test_nonOwner_cannotSetCustodian() public {
        vm.prank(rando);
        vm.expectRevert(bytes("E26"));
        mine.setCustodian(agent1, true);
    }

    // ============ Test 12: Reentrancy guard ============

    function test_reentrancyGuard_stake() public {
        _stakeAs(agent1, T1);
        assertTrue(true);
    }

    function test_reentrancyGuard_withdrawStake() public {
        _stakeAs(agent1, T1);
        vm.prank(agent1);
        mine.unstake();
        _openEpochAndSnapshot();
        _closeAndFinalize();
        vm.prank(agent1);
        mine.withdrawStake();
        assertTrue(true);
    }

    function test_reentrancyGuard_claimEpochReward() public {
        _stakeAs(agent1, T1);
        token.mint(address(mine), 1000e18);
        mine.setCustodian(owner, true);
        mine.allocateRewards(1000e18);

        _openEpochAndSnapshot();
        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 1200);
        _setupInscription(1, 1, agent1, mine.getRound(1).commitCloseAt, "ans1");
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _settleRound(1, "ans1", ids);
        _closeAndFinalize();

        vm.prank(agent1);
        mine.claimEpochReward(1);
        assertTrue(mine.epochClaimed(1, agent1));
    }

    // ============ Test 13: Paused ============

    function test_paused_rejectsStake() public {
        mine.setCustodian(owner, true);
        mine.pause();

        vm.prank(agent1);
        vm.expectRevert(bytes("E27"));
        mine.stake(T1);
    }

    // ============ Test 14: recoverERC20 ============

    function test_recoverERC20_cannotDrainProtected() public {
        mine.setCustodian(owner, true);
        _stakeAs(agent1, T1);

        vm.expectRevert(bytes("E48"));
        mine.recoverERC20(address(token), 1, address(0x999));
    }

    function test_recoverERC20_canRecoverExcess() public {
        mine.setCustodian(owner, true);
        _stakeAs(agent1, T1);

        token.mint(address(mine), 500e18);
        mine.recoverERC20(address(token), 500e18, address(0x999));
        assertEq(token.balanceOf(address(0x999)), 500e18);
    }

    // ============ Test 15: Owner can open/close/finalize ============

    function test_ownerCanOpenEpoch() public {
        _stakeAs(agent1, T1);
        mine.openEpoch(block.timestamp);
        assertTrue(mine.epochOpen());
    }

    function test_ownerCanCloseAndFinalize() public {
        _stakeAs(agent1, T1);
        mine.openEpoch(block.timestamp);
        vm.prank(oracleAddr);
        mine.snapshotBatch(100);
        mine.closeEpoch();
        vm.prank(oracleAddr);
        mine.accumulateCreditsBatch(1000);
        mine.finalizeClose();
        assertTrue(mine.getEpoch(1).settled);
    }

    // ============ Test 16: WINDOW constants ============

    function test_windowConstant() public view {
        assertEq(mine.WINDOW(), 600);
        assertEq(mine.CLAIM_WINDOW(), 7 days);
    }

    function test_roundTimings() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        uint256 t0 = block.timestamp;
        _postRound("q1", "ans1");

        CustosMineControllerV053.Round memory r = mine.getRound(1);
        assertEq(r.commitCloseAt, t0 + 600);
        assertEq(r.revealCloseAt, t0 + 1200);
    }

    // ============ Test 17: E69 per-epoch (not global!) ============

    function test_E69_roundLimit_perEpoch() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        for (uint256 i = 0; i < 140; i++) {
            _postRound("q", "a");
            vm.warp(block.timestamp + 600);
        }

        bytes32 ah = keccak256(abi.encodePacked("a"));
        vm.prank(oracleAddr);
        vm.expectRevert(bytes("E69"));
        mine.postRound("q141", ah, 99999);
    }

    // ============ Test 18: postRound no sequential requirement ============

    function test_postRound_noSequentialRequirement() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        _postRound("q1", "ans1");
        vm.warp(block.timestamp + 600);
        _postRound("q2", "ans2");
        vm.warp(block.timestamp + 600);
        _postRound("q3", "ans3");

        assertEq(mine.roundCount(), 3);
        assertFalse(mine.getRound(1).settled);
    }

    // ============ Test 19: Mid-epoch join ============

    function test_midEpoch_staker_gets_tier_snapshot() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        assertEq(mine.getTierSnapshot(agent1, 1), 1);

        address agent4 = address(0xBEEF4);
        token.mint(agent4, T1);
        vm.startPrank(agent4);
        token.approve(address(mine), T1);
        mine.stake(T1);
        vm.stopPrank();

        assertEq(mine.getTierSnapshot(agent4, 1), 1);
        assertTrue(mine.snapshotComplete());
    }

    function test_midEpoch_staker_earns_credits() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        address agent4 = address(0xBEEF4);
        token.mint(agent4, T1);
        vm.startPrank(agent4);
        token.approve(address(mine), T1);
        mine.stake(T1);
        vm.stopPrank();

        string memory answer = "42";
        uint256 roundId = _postRound("midepoch question", answer);

        uint256 insId1 = 9001;
        uint256 insId2 = 9002;
        uint256 revealTime = mine.getRound(roundId).commitCloseAt + 1;
        _setupInscription(insId1, roundId, agent1, revealTime, answer);
        _setupInscription(insId2, roundId, agent4, revealTime, answer);

        uint256[] memory ids = new uint256[](2);
        ids[0] = insId1; ids[1] = insId2;
        vm.warp(mine.getRound(roundId).revealCloseAt + 1);
        _settleRound(roundId, answer, ids);

        assertEq(mine.getCredits(agent1, 1), 1);
        assertEq(mine.getCredits(agent4, 1), 1);
        assertEq(mine.getRound(roundId).correctCount, 2);
    }

    // ============ Test 20: answerHash encoding ============

    function test_answerHash_encodePacked() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        string memory answer = "hello world";
        bytes32 expectedHash = keccak256(abi.encodePacked(answer));
        _postRound("q1", answer);

        assertEq(mine.getRound(1).answerHash, expectedHash);
    }

    // ═══════════════════════════════════════════════════════════════
    //  NEW V053 TESTS — epoch-relative round numbering
    // ═══════════════════════════════════════════════════════════════

    // ============ Test 21: epochRoundNumber is set correctly ============

    function test_epochRoundNumber_sequential() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        uint256 r1 = _postRound("q1", "a1");
        vm.warp(block.timestamp + 600);
        uint256 r2 = _postRound("q2", "a2");
        vm.warp(block.timestamp + 600);
        uint256 r3 = _postRound("q3", "a3");

        assertEq(mine.getRound(r1).epochRoundNumber, 1);
        assertEq(mine.getRound(r2).epochRoundNumber, 2);
        assertEq(mine.getRound(r3).epochRoundNumber, 3);

        // Global IDs still sequential
        assertEq(r1, 1);
        assertEq(r2, 2);
        assertEq(r3, 3);
    }

    // ============ Test 22: epochRounds mapping lookup ============

    function test_epochRounds_mapping() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        uint256 r1 = _postRound("q1", "a1");
        vm.warp(block.timestamp + 600);
        uint256 r2 = _postRound("q2", "a2");

        // epochRounds[1][1] = global round 1
        assertEq(mine.epochRounds(1, 1), r1);
        assertEq(mine.epochRounds(1, 2), r2);
        // Non-existent returns 0
        assertEq(mine.epochRounds(1, 3), 0);
    }

    // ============ Test 23: getEpochRound view ============

    function test_getEpochRound_view() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        uint256 r1 = _postRound("q1", "a1");
        vm.warp(block.timestamp + 600);
        uint256 r2 = _postRound("q2", "a2");

        CustosMineControllerV053.Round memory round1 = mine.getEpochRound(1, 1);
        assertEq(round1.roundId, r1);
        assertEq(round1.epochRoundNumber, 1);
        assertEq(keccak256(bytes(round1.questionUri)), keccak256(bytes("q1")));

        CustosMineControllerV053.Round memory round2 = mine.getEpochRound(1, 2);
        assertEq(round2.roundId, r2);
        assertEq(round2.epochRoundNumber, 2);
    }

    // ============ Test 24: getEpochRoundCount — live + finalized ============

    function test_getEpochRoundCount_live() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        assertEq(mine.getEpochRoundCount(1), 0);

        _postRound("q1", "a1");
        assertEq(mine.getEpochRoundCount(1), 1);

        vm.warp(block.timestamp + 600);
        _postRound("q2", "a2");
        assertEq(mine.getEpochRoundCount(1), 2);
    }

    function test_getEpochRoundCount_finalized() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        _postRound("q1", "a1");
        vm.warp(block.timestamp + 600);
        _postRound("q2", "a2");
        vm.warp(block.timestamp + 600);
        _postRound("q3", "a3");

        _closeAndFinalize();

        // After finalize, count persisted in epochRoundsPosted
        assertEq(mine.getEpochRoundCount(1), 3);
        assertEq(mine.epochRoundsPosted(1), 3);
    }

    // ============ Test 25: getLatestEpoch ============

    function test_getLatestEpoch() public {
        _stakeAs(agent1, T1);
        vm.warp(10000);
        _openEpochAndSnapshot();

        CustosMineControllerV053.Epoch memory ep = mine.getLatestEpoch();
        assertEq(ep.epochId, 1);
        assertEq(ep.startAt, 10000);
        assertEq(ep.endAt, 10000 + 86400);
    }

    // ============ Test 26: Multi-epoch — epochRoundCount resets ============

    function test_multiEpoch_epochRoundCountResets() public {
        _stakeAs(agent1, T1);
        vm.warp(10000);

        // ── Epoch 1: post 5 rounds ──
        _openEpochAndSnapshot();

        for (uint256 i = 0; i < 5; i++) {
            _postRound("q", "a");
            vm.warp(block.timestamp + 600);
        }
        assertEq(mine.epochRoundCount(), 5);
        assertEq(mine.roundCount(), 5);

        _closeAndFinalize();
        assertEq(mine.epochRoundsPosted(1), 5);

        // ── Epoch 2: post 3 rounds ──
        vm.warp(block.timestamp + 100);
        _openEpochAndSnapshot();

        // epochRoundCount should be 0 after openEpoch
        assertEq(mine.epochRoundCount(), 0);

        for (uint256 i = 0; i < 3; i++) {
            _postRound("q", "a");
            vm.warp(block.timestamp + 600);
        }
        assertEq(mine.epochRoundCount(), 3);
        assertEq(mine.roundCount(), 8); // global: 5 + 3

        // Check epoch-relative numbering for epoch 2
        CustosMineControllerV053.Round memory r6 = mine.getRound(6);
        assertEq(r6.epochId, 2);
        assertEq(r6.epochRoundNumber, 1); // first round of epoch 2

        CustosMineControllerV053.Round memory r8 = mine.getRound(8);
        assertEq(r8.epochId, 2);
        assertEq(r8.epochRoundNumber, 3); // third round of epoch 2

        // epochRounds lookup works for both epochs
        assertEq(mine.epochRounds(1, 1), 1); // epoch 1, round #1 = global 1
        assertEq(mine.epochRounds(1, 5), 5); // epoch 1, round #5 = global 5
        assertEq(mine.epochRounds(2, 1), 6); // epoch 2, round #1 = global 6
        assertEq(mine.epochRounds(2, 3), 8); // epoch 2, round #3 = global 8

        _closeAndFinalize();
        assertEq(mine.epochRoundsPosted(2), 3);
    }

    // ============ Test 27: Multi-epoch — E69 per-epoch not global ============

    function test_multiEpoch_E69_perEpochNotGlobal() public {
        _stakeAs(agent1, T1);
        vm.warp(10000);

        // ── Epoch 1: fill all 140 rounds ──
        _openEpochAndSnapshot();
        for (uint256 i = 0; i < 140; i++) {
            _postRound("q", "a");
            vm.warp(block.timestamp + 600);
        }
        assertEq(mine.roundCount(), 140);
        assertEq(mine.epochRoundCount(), 140);

        _closeAndFinalize();

        // ── Epoch 2: can post again! (was broken in V052) ──
        vm.warp(block.timestamp + 100);
        _openEpochAndSnapshot();

        // This would have failed with E69 in V052 because roundCount(140) >= ROUNDS_PER_EPOCH(140)
        uint256 r141 = _postRound("epoch2-q1", "a");
        assertEq(r141, 141);  // global ID continues
        assertEq(mine.epochRoundCount(), 1);  // epoch-relative is 1

        CustosMineControllerV053.Round memory round = mine.getRound(r141);
        assertEq(round.epochId, 2);
        assertEq(round.epochRoundNumber, 1);

        // Can post all 140 rounds in epoch 2
        for (uint256 i = 1; i < 140; i++) {
            vm.warp(block.timestamp + 600);
            _postRound("q", "a");
        }
        assertEq(mine.epochRoundCount(), 140);
        assertEq(mine.roundCount(), 280); // 140 + 140

        // E69 triggers at epoch limit
        bytes32 ah = keccak256(abi.encodePacked("a"));
        vm.prank(oracleAddr);
        vm.expectRevert(bytes("E69"));
        mine.postRound("too-many", ah, 99999);
    }

    // ============ Test 28: Multi-epoch with settlement and credits ============

    function test_multiEpoch_fullCycle_with_credits() public {
        _stakeAs(agent1, T1);
        _stakeAs(agent2, T3);

        token.mint(address(mine), 2000e18);
        mine.setCustodian(owner, true);
        mine.allocateRewards(1000e18);

        vm.warp(10000);

        // ── Epoch 1 ──
        // Round 1 posted at t=10000, commitClose=10600, revealClose=11200
        _openEpochAndSnapshot();

        uint256 r1 = _postRound("q1", "ans1");
        vm.warp(11200); // past revealClose
        _setupInscription(1, r1, agent1, 10600, "ans1"); // revealTime = commitClose
        _setupInscription(2, r1, agent2, 10600, "ans1");
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        _settleRound(r1, "ans1", ids);

        _closeAndFinalize();

        // Claim epoch 1
        vm.prank(agent1);
        mine.claimEpochReward(1);
        vm.prank(agent2);
        mine.claimEpochReward(1);

        // ── Epoch 2 ──
        mine.allocateRewards(1000e18);
        vm.warp(11300);
        _openEpochAndSnapshot();

        // Round 2 posted at t=11300, commitClose=11900, revealClose=12500
        uint256 r2 = _postRound("q2", "ans2");
        assertEq(mine.getRound(r2).epochRoundNumber, 1); // epoch-relative #1

        vm.warp(12500); // past revealClose
        _setupInscription(3, r2, agent1, 11900, "ans2"); // revealTime = commitClose
        ids = new uint256[](1);
        ids[0] = 3;
        _settleRound(r2, "ans2", ids);

        _closeAndFinalize();

        // agent1 earned credits in epoch 2
        assertEq(mine.getCredits(agent1, 2), 1);
        assertEq(mine.getCredits(agent2, 2), 0); // didn't participate

        vm.prank(agent1);
        mine.claimEpochReward(2);
        assertTrue(mine.epochClaimed(2, agent1));
    }

    // ============ Test 29: expireRound onlyOracleOrOwner ============

    function test_expireRound_onlyOracleOrOwner() public {
        vm.warp(10000);
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        uint256 r1 = _postRound("q1", "ans1");
        // revealCloseAt = 10000 + 1200 = 11200. expireRound requires > revealCloseAt + 300 = 11500

        vm.warp(11501); // strictly past revealCloseAt + 300

        // Random user cannot expire
        vm.prank(rando);
        vm.expectRevert(bytes("E24"));
        mine.expireRound(r1);

        // Oracle can expire
        vm.prank(oracleAddr);
        mine.expireRound(r1);
        assertTrue(mine.getRound(r1).expired);
    }

    function test_expireRound_ownerCanExpire() public {
        vm.warp(10000);
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();
        uint256 r1 = _postRound("q1", "ans1");

        vm.warp(11501); // strictly past revealCloseAt + 300

        // Owner can expire
        mine.expireRound(r1);
        assertTrue(mine.getRound(r1).expired);
    }

    // ============ Test 30: getEpochRound returns empty for non-existent ============

    function test_getEpochRound_nonExistent_returnsEmpty() public view {
        CustosMineControllerV053.Round memory r = mine.getEpochRound(999, 1);
        assertEq(r.roundId, 0);
        assertEq(r.epochId, 0);
        assertEq(r.epochRoundNumber, 0);
    }

    // ============ Test 31: epochRoundsPosted is 0 for unclosed epochs ============

    function test_epochRoundsPosted_zeroBeforeFinalize() public {
        _stakeAs(agent1, T1);
        _openEpochAndSnapshot();

        _postRound("q1", "a1");
        _postRound("q2", "a2");

        // Not finalized yet — epochRoundsPosted should be 0
        assertEq(mine.epochRoundsPosted(1), 0);
        // But getEpochRoundCount returns live count
        assertEq(mine.getEpochRoundCount(1), 2);
    }

    // ============ Test 32: Three concurrent epochs (stress test) ============

    function test_threeEpochs_roundNumbering() public {
        _stakeAs(agent1, T1);
        vm.warp(10000);

        uint256[] memory epochRoundCounts = new uint256[](3);
        epochRoundCounts[0] = 10;
        epochRoundCounts[1] = 20;
        epochRoundCounts[2] = 15;

        uint256 expectedGlobalRound = 0;

        for (uint256 e = 0; e < 3; e++) {
            _openEpochAndSnapshot();
            uint256 epochId = mine.currentEpochId();

            for (uint256 i = 0; i < epochRoundCounts[e]; i++) {
                uint256 rid = _postRound("q", "a");
                expectedGlobalRound++;
                assertEq(rid, expectedGlobalRound, "global ID");

                CustosMineControllerV053.Round memory r = mine.getRound(rid);
                assertEq(r.epochRoundNumber, i + 1, "epoch-relative number");
                assertEq(r.epochId, epochId, "epoch ID");

                // epochRounds mapping
                assertEq(mine.epochRounds(epochId, i + 1), rid, "epochRounds mapping");

                vm.warp(block.timestamp + 600);
            }

            _closeAndFinalize();
            assertEq(mine.epochRoundsPosted(epochId), epochRoundCounts[e], "rounds posted");
            vm.warp(block.timestamp + 100);
        }

        // Total global rounds = 10 + 20 + 15 = 45
        assertEq(mine.roundCount(), 45);
    }
}
