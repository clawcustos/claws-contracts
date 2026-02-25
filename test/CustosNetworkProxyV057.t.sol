// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/CustosNetworkProxyV057.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ─── Minimal ERC-20 mock ─────────────────────────────────────────────────────
contract MockERC20v057 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        if (allowance[from][msg.sender] != type(uint256).max)
            allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────
contract CustosNetworkProxyV057Test is Test {

    CustosNetworkProxyV057 network;

    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CUSTOS  = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE; // CUSTOS_CUSTODIAN

    address inscriber = makeAddr("inscriber");
    address stranger  = makeAddr("stranger");

    uint256 ts;

    uint256 counter; // monotonic nonce for unique proofHashes

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        ts = 1_700_000_000;
        vm.warp(ts);

        CustosNetworkProxyV057 impl = new CustosNetworkProxyV057();
        bytes memory init = abi.encodeCall(CustosNetworkProxyV057.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        network = CustosNetworkProxyV057(address(proxy));

        // Bump reinitializers so we land at version 7
        network.initializeV52();
        network.initializeV53();
        network.initializeV54();
        network.initializeV056();
        network.initializeV057();

        // Mock USDC
        MockERC20v057 mockUsdc = new MockERC20v057();
        vm.etch(USDC, address(mockUsdc).code);
        MockERC20v057(USDC).mint(inscriber, 100_000e6);
        vm.prank(inscriber);
        MockERC20v057(USDC).approve(address(network), type(uint256).max);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// Inscribe one cycle for `who`. Returns (inscriptionId, proofHash).
    function _inscribe(
        address who,
        string memory blockType,
        bytes32 contentHash,
        uint256 roundId
    ) internal returns (uint256 inscriptionId, bytes32 proofHash) {
        bytes32 prevHash = network.getChainHeadByWallet(who);
        proofHash = keccak256(abi.encodePacked(who, ++counter));
        vm.prank(who);
        network.inscribe(proofHash, prevHash, blockType, "summary", contentHash, roundId);
        inscriptionId = network.proofHashToInscriptionId(proofHash);
    }

    // ─── V0.5.7: inscriptionBlockType stored at inscription time ──────────────

    function test_BlockTypeStoredOnInscribe() public {
        (uint256 id,) = _inscribe(inscriber, "mine-commit", bytes32(0), 0);
        assertEq(network.inscriptionBlockType(id), "mine-commit");
    }

    function test_BlockTypeNonMine() public {
        (uint256 id,) = _inscribe(inscriber, "build", bytes32(0), 0);
        assertEq(network.inscriptionBlockType(id), "build");
    }

    function test_BlockTypeEmptyString() public {
        (uint256 id,) = _inscribe(inscriber, "", bytes32(0), 0);
        assertEq(network.inscriptionBlockType(id), "");
    }

    // ─── V0.5.7: inscriptionRoundId stored when roundId != 0 ─────────────────

    function test_RoundIdStoredWhenNonZero() public {
        (uint256 id,) = _inscribe(inscriber, "mine-commit", bytes32(0), 42);
        assertEq(network.inscriptionRoundId(id), 42);
    }

    function test_RoundIdZeroForNonMine() public {
        (uint256 id,) = _inscribe(inscriber, "build", bytes32(0), 0);
        assertEq(network.inscriptionRoundId(id), 0);
    }

    function test_RoundIdNotStoredWhenZero() public {
        // Passing roundId=0 must NOT store anything (guard in contract)
        (uint256 id,) = _inscribe(inscriber, "mine-commit", bytes32(0), 0);
        assertEq(network.inscriptionRoundId(id), 0);
    }

    // ─── V0.5.7: inscriptionRevealTime set on reveal() ───────────────────────

    function test_RevealTimeSetsOnReveal() public {
        bytes32 salt        = keccak256("salt");
        string  memory ans  = "42";
        bytes32 contentHash = keccak256(abi.encodePacked(ans, salt));

        (uint256 id,) = _inscribe(inscriber, "mine-commit", contentHash, 1);
        assertEq(network.inscriptionRevealTime(id), 0); // zero before reveal

        uint256 revealAt = ts + 300;
        vm.warp(revealAt);
        vm.prank(inscriber);
        network.reveal(id, ans, salt);

        assertEq(network.inscriptionRevealTime(id), revealAt);
    }

    function test_RevealTimeZeroBeforeReveal() public {
        (uint256 id,) = _inscribe(inscriber, "mine-commit", bytes32(keccak256("x")), 1);
        assertEq(network.inscriptionRevealTime(id), 0);
    }

    // ─── Reveal still requires hash match ────────────────────────────────────

    function test_RevealRevertsWrongContent() public {
        bytes32 salt        = keccak256("salt");
        bytes32 contentHash = keccak256(abi.encodePacked("correct", salt));
        (uint256 id,) = _inscribe(inscriber, "mine-commit", contentHash, 1);

        vm.prank(inscriber);
        vm.expectRevert(bytes("E51"));
        network.reveal(id, "wrong", salt);
    }

    function test_RevealRevertsDoubleReveal() public {
        bytes32 salt        = keccak256("salt");
        string  memory ans  = "42";
        bytes32 contentHash = keccak256(abi.encodePacked(ans, salt));
        (uint256 id,) = _inscribe(inscriber, "mine-commit", contentHash, 1);

        vm.prank(inscriber);
        network.reveal(id, ans, salt);

        vm.prank(inscriber);
        vm.expectRevert(bytes("E31"));
        network.reveal(id, ans, salt);
    }

    function test_RevealRevertsWrongCaller() public {
        bytes32 salt        = keccak256("salt");
        string  memory ans  = "42";
        bytes32 contentHash = keccak256(abi.encodePacked(ans, salt));
        (uint256 id,) = _inscribe(inscriber, "mine-commit", contentHash, 1);

        vm.prank(stranger);
        vm.expectRevert(bytes("E23"));
        network.reveal(id, ans, salt);
    }

    // ─── Reveal requires contentHash != 0 (public mode inscriptions) ─────────

    function test_RevealRevertsPublicModeInscription() public {
        // contentHash == 0 means public mode — reveal should revert E56
        (uint256 id,) = _inscribe(inscriber, "mine-commit", bytes32(0), 1);
        vm.prank(inscriber);
        vm.expectRevert(bytes("E56"));
        network.reveal(id, "anything", keccak256("salt"));
    }

    // ─── getInscriptionContent after reveal ───────────────────────────────────

    function test_GetInscriptionContentAfterReveal() public {
        bytes32 salt        = keccak256("mysalt");
        string  memory ans  = "blockheight:100";
        bytes32 contentHash = keccak256(abi.encodePacked(ans, salt));
        (uint256 id,) = _inscribe(inscriber, "mine-commit", contentHash, 7);

        vm.prank(inscriber);
        network.reveal(id, ans, salt);

        (bool revealed, string memory content, bytes32 storedHash) = network.getInscriptionContent(id);
        assertTrue(revealed);
        assertEq(content, ans);
        assertEq(storedHash, contentHash);
    }

    function test_GetInscriptionContentBeforeReveal() public {
        bytes32 contentHash = keccak256(abi.encodePacked("ans", keccak256("s")));
        (uint256 id,) = _inscribe(inscriber, "mine-commit", contentHash, 1);
        (bool revealed, string memory content,) = network.getInscriptionContent(id);
        assertFalse(revealed);
        assertEq(bytes(content).length, 0);
    }

    // ─── Multiple inscriptions: each gets correct blockType / roundId ─────────

    function test_MultipleInscriptionsIndependentFields() public {
        // need to warp between inscriptions to clear MIN_INSCRIPTION_GAP
        (uint256 id1,) = _inscribe(inscriber, "mine-commit", bytes32(0), 10);
        vm.warp(ts + 400);
        (uint256 id2,) = _inscribe(inscriber, "build", bytes32(0), 0);
        vm.warp(ts + 800);
        (uint256 id3,) = _inscribe(inscriber, "research", bytes32(0), 11);

        assertEq(network.inscriptionBlockType(id1), "mine-commit");
        assertEq(network.inscriptionRoundId(id1), 10);

        assertEq(network.inscriptionBlockType(id2), "build");
        assertEq(network.inscriptionRoundId(id2), 0);

        assertEq(network.inscriptionBlockType(id3), "research");
        assertEq(network.inscriptionRoundId(id3), 11);
    }

    // ─── inscriptionAgent set correctly ──────────────────────────────────────

    function test_InscriptionAgentSetCorrectly() public {
        (uint256 id,) = _inscribe(inscriber, "mine-commit", bytes32(0), 1);
        assertEq(network.inscriptionAgent(id), inscriber);
    }

    // ─── Full mine-commit flow: inscribe → reveal, all V057 fields correct ────

    function test_FullMineCommitFlow() public {
        uint256 roundId     = 5;
        bytes32 salt        = keccak256("testsalt");
        string  memory ans  = "0xdeadbeef";
        bytes32 contentHash = keccak256(abi.encodePacked(ans, salt));

        (uint256 id, bytes32 ph) = _inscribe(inscriber, "mine-commit", contentHash, roundId);

        // Pre-reveal checks
        assertEq(network.inscriptionBlockType(id),  "mine-commit");
        assertEq(network.inscriptionRoundId(id),    roundId);
        assertEq(network.inscriptionRevealTime(id), 0);
        assertEq(network.inscriptionAgent(id),      inscriber);
        assertEq(network.inscriptionProofHash(id),  ph);

        // Reveal
        uint256 revealAt = ts + 650;
        vm.warp(revealAt);
        vm.prank(inscriber);
        network.reveal(id, ans, salt);

        // Post-reveal checks
        assertEq(network.inscriptionRevealTime(id), revealAt);
        (bool revealed, string memory content,) = network.getInscriptionContent(id);
        assertTrue(revealed);
        assertEq(content, ans);
    }

    // ─── depositBuyback ───────────────────────────────────────────────────────

    function test_DepositBuybackIncreasesBuybackPool() public {
        uint256 before = network.buybackPool();
        uint256 deposit = 5_000_000; // 5 USDC
        MockERC20v057(USDC).mint(inscriber, deposit);
        vm.prank(inscriber);
        network.depositBuyback(deposit);
        assertEq(network.buybackPool(), before + deposit);
    }

    function test_DepositBuybackTransfersUSDCToContract() public {
        uint256 deposit = 2_000_000; // 2 USDC
        MockERC20v057(USDC).mint(stranger, deposit);
        vm.prank(stranger);
        MockERC20v057(USDC).approve(address(network), deposit);

        uint256 contractBefore = MockERC20v057(USDC).balanceOf(address(network));
        vm.prank(stranger);
        network.depositBuyback(deposit);
        assertEq(MockERC20v057(USDC).balanceOf(address(network)), contractBefore + deposit);
    }

    function test_DepositBuybackEmitsEvent() public {
        uint256 deposit = 1_000_000; // 1 USDC
        MockERC20v057(USDC).mint(inscriber, deposit);
        vm.prank(inscriber);
        vm.expectEmit(true, false, false, true);
        emit CustosNetworkProxyV057.BuybackDeposited(inscriber, deposit);
        network.depositBuyback(deposit);
    }

    function test_DepositBuybackRevertsOnZero() public {
        vm.prank(inscriber);
        vm.expectRevert(bytes("E11"));
        network.depositBuyback(0);
    }

    function test_DepositBuybackOpenToAnyone() public {
        // stranger (no role) can deposit
        uint256 deposit = 500_000;
        MockERC20v057(USDC).mint(stranger, deposit);
        vm.prank(stranger);
        MockERC20v057(USDC).approve(address(network), deposit);
        vm.prank(stranger);
        network.depositBuyback(deposit); // must not revert
        assertEq(network.buybackPool(), deposit);
    }
}
