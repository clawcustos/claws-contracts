// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/CustosNetworkImpl.sol";

/**
 * @title CustosNetworkImpl Smoke Test
 * @notice Tests the full happy-path flow:
 *   register → inscribe → approve validator → lock stake → attest → equivocation slash
 *
 * Uses a mock USDC token to avoid mainnet dependencies.
 */

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract CustosNetworkImplTest is Test {
    CustosNetworkImpl public impl;
    CustosNetworkImpl public network; // proxy cast
    MockUSDC public usdc;

    // Test actors
    address public agent1 = address(0x1001);
    address public agent2 = address(0x1002);
    address public reporter = address(0x1003);

    // Custodian (matches CUSTOS_WALLET constant)
    address public custodian = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE;

    bytes32 public genesisHead = keccak256("genesis");
    uint256 public genesisCycleCount = 108; // V4 final count

    function setUp() public {
        // Deploy mock USDC and patch the contract's USDC reference via vm.etch
        usdc = new MockUSDC();

        // Deploy impl
        impl = new CustosNetworkImpl();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            CustosNetworkImpl.initialize.selector,
            genesisHead,
            genesisCycleCount
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        network = CustosNetworkImpl(address(proxy));

        // Patch USDC address in proxy bytecode slot to mock
        // Since USDC is a constant, we patch via vm.mockCall instead
        vm.mockCall(
            network.USDC(),
            abi.encodeWithSelector(MockUSDC.transferFrom.selector),
            abi.encode(true)
        );
        vm.mockCall(
            network.USDC(),
            abi.encodeWithSelector(MockUSDC.transfer.selector),
            abi.encode(true)
        );
        vm.mockCall(
            network.USDC(),
            abi.encodeWithSelector(MockUSDC.approve.selector),
            abi.encode(true)
        );
        vm.mockCall(
            network.USDC(),
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), network.ECOSYSTEM_WALLET()),
            abi.encode(uint256(0))
        );
    }

    // ─── Registration ───────────────────────────────────────────────────────
    function test_RegisterAgent() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        CustosNetworkImpl.Agent memory a = network.getAgentByWallet(agent1);
        assertEq(a.name, "TestAgent");
        assertEq(uint8(a.role), uint8(CustosNetworkImpl.AgentRole.INSCRIBER));
        assertEq(a.cycleCount, 0);
    }

    function test_CannotRegisterTwice() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");
        vm.prank(agent1);
        vm.expectRevert("Already registered");
        network.registerAgent("TestAgent2");
    }

    // Helper: warp past rate limit then inscribe (using legacy public mode)
    function _inscribe(address agent, bytes32 proof, bytes32 prev, string memory summary) internal {
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent);
        network.inscribe(proof, prev, "build", summary, bytes32(0)); // bytes32(0) = public mode
    }

    // ─── Inscription ────────────────────────────────────────────────────────
    function test_InscribeFirstCycle() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        bytes32 proof = keccak256("cycle1content");
        _inscribe(agent1, proof, genesisHead, "first cycle");

        CustosNetworkImpl.Agent memory a = network.getAgentByWallet(agent1);
        assertEq(a.cycleCount, 1);
        assertEq(a.chainHead, proof);
    }

    function test_ChainContinuity() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        bytes32 proof1 = keccak256("cycle1");
        bytes32 proof2 = keccak256("cycle2");

        _inscribe(agent1, proof1, genesisHead, "first");
        _inscribe(agent1, proof2, proof1, "second");

        assertEq(network.getAgentByWallet(agent1).cycleCount, 2);
        assertEq(network.getAgentByWallet(agent1).chainHead, proof2);
    }

    function test_RateLimitEnforced() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        bytes32 proof1 = keccak256("cycle1");
        bytes32 proof2 = keccak256("cycle2");

        _inscribe(agent1, proof1, genesisHead, "first");

        // Immediately (no warp) — should rate limit
        vm.prank(agent1);
        vm.expectRevert("Rate limited");
        network.inscribe(proof2, proof1, "build", "too soon", bytes32(0));
    }

    function test_WrongPrevHashReverts() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        bytes32 proof = keccak256("cycle1");
        bytes32 wrongPrev = keccak256("wrong");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        vm.expectRevert("Chain break: wrong prevHash");
        network.inscribe(proof, wrongPrev, "build", "bad chain", bytes32(0));
    }

    // ─── Validator flow ──────────────────────────────────────────────────────
    function test_ValidatorApprovalAndStake() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        // Custodian approves
        vm.prank(custodian);
        network.approveValidator(1);

        assertEq(uint8(network.getAgent(1).role), uint8(CustosNetworkImpl.AgentRole.VALIDATOR));

        // Agent locks stake
        vm.prank(agent1);
        network.lockValidatorStake();

        assertEq(network.getAgent(1).validatorStake, 10e6);
    }

    // ─── Attestation ─────────────────────────────────────────────────────────
    function test_Attestation() public {
        // Register inscriber (agent1) and validator (agent2)
        vm.prank(agent1);
        network.registerAgent("Inscriber");

        vm.prank(agent2);
        network.registerAgent("Validator");

        // Promote agent2 to validator
        vm.prank(custodian);
        network.approveValidator(2);
        vm.prank(agent2);
        network.lockValidatorStake();

        // Inscribe a proof
        bytes32 proof = keccak256("cycle1");
        _inscribe(agent1, proof, genesisHead, "tested");

        // Validator attests
        vm.prank(agent2);
        network.attest(1, proof, true);

        CustosNetworkImpl.Attestation[] memory atts = network.getAttestations(proof);
        assertEq(atts.length, 1);
        assertEq(atts[0].validator, agent2);
        assertTrue(atts[0].valid);
    }

    // ─── Equivocation slashing ────────────────────────────────────────────────
    function test_EquivocationSlash() public {
        vm.prank(agent1);
        network.registerAgent("Inscriber");

        vm.prank(agent2);
        network.registerAgent("BadValidator");

        vm.prank(custodian);
        network.approveValidator(2);
        vm.prank(agent2);
        network.lockValidatorStake();

        bytes32 proof = keccak256("cycle1");
        _inscribe(agent1, proof, genesisHead, "tested");

        // Validator attests TRUE
        vm.prank(agent2);
        network.attest(1, proof, true);

        // Validator attests FALSE on same proof — prevented by hasAttested mapping
        vm.prank(agent2);
        vm.expectRevert("Already attested");
        network.attest(1, proof, false);
    }

    // ─── Epoch management ─────────────────────────────────────────────────────
    function test_CloseEpoch() public {
        vm.prank(custodian);
        network.closeEpoch();
        assertEq(network.currentEpoch(), 2);
        assertEq(network.epochInscriptions(), 0);
    }

    // ─── Pause ────────────────────────────────────────────────────────────────
    function test_PauseBlocksInscription() public {
        // Register before pausing
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        vm.prank(custodian);
        network.pause();

        bytes32 proof = keccak256("cycle1");
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        vm.expectRevert();
        network.inscribe(proof, genesisHead, "build", "paused", bytes32(0));
    }

    // ─── V5.4 Privacy Mode Tests ──────────────────────────────────────────────
    function test_InscribeWithPrivacyHash() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        bytes32 proof = keccak256("cycle1content");
        bytes32 contentHash = keccak256(abi.encodePacked("secret content", bytes32("salt")));

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        network.inscribe(proof, genesisHead, "research", "private work", contentHash);

        // Check inscription was created
        assertEq(network.inscriptionCount(), 1);
        assertEq(network.inscriptionContentHash(1), contentHash);
        assertEq(network.inscriptionAgent(1), agent1);
        assertEq(network.inscriptionRevealed(1), false);
        assertEq(network.proofHashToInscriptionId(proof), 1);

        // Check view function
        (bool revealed, string memory content, bytes32 storedHash) = network.getInscriptionContent(1);
        assertEq(revealed, false);
        assertEq(content, "");
        assertEq(storedHash, contentHash);
    }

    function test_RevealContent() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        string memory secretContent = "sensitive work details";
        bytes32 salt = keccak256("my_secret_salt");
        bytes32 contentHash = keccak256(abi.encodePacked(secretContent, salt));
        bytes32 proof = keccak256("cycle1content");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        network.inscribe(proof, genesisHead, "research", "private work", contentHash);

        // Reveal the content
        vm.prank(agent1);
        network.reveal(1, secretContent, salt);

        // Check revealed state
        assertEq(network.inscriptionRevealed(1), true);
        assertEq(network.inscriptionRevealedContent(1), secretContent);

        // Check view function
        (bool revealed, string memory content, bytes32 storedHash) = network.getInscriptionContent(1);
        assertEq(revealed, true);
        assertEq(content, secretContent);
        assertEq(storedHash, contentHash);
    }

    function test_CannotRevealWithWrongSalt() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        string memory secretContent = "sensitive work details";
        bytes32 salt = keccak256("my_secret_salt");
        bytes32 wrongSalt = keccak256("wrong_salt");
        bytes32 contentHash = keccak256(abi.encodePacked(secretContent, salt));
        bytes32 proof = keccak256("cycle1content");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        network.inscribe(proof, genesisHead, "research", "private work", contentHash);

        // Try to reveal with wrong salt
        vm.prank(agent1);
        vm.expectRevert("Hash mismatch: invalid content or salt");
        network.reveal(1, secretContent, wrongSalt);
    }

    function test_CannotRevealIfNotInscriber() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        vm.prank(agent2);
        network.registerAgent("OtherAgent");

        string memory secretContent = "sensitive work details";
        bytes32 salt = keccak256("my_secret_salt");
        bytes32 contentHash = keccak256(abi.encodePacked(secretContent, salt));
        bytes32 proof = keccak256("cycle1content");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        network.inscribe(proof, genesisHead, "research", "private work", contentHash);

        // agent2 tries to reveal
        vm.prank(agent2);
        vm.expectRevert("Only inscriber can reveal");
        network.reveal(1, secretContent, salt);
    }

    function test_CannotRevealPublicInscription() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        bytes32 proof = keccak256("cycle1content");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        network.inscribe(proof, genesisHead, "build", "public work", bytes32(0));

        // Try to reveal a public inscription
        vm.prank(agent1);
        vm.expectRevert("Public inscription, nothing to reveal");
        network.reveal(1, "content", bytes32("salt"));
    }

    function test_CannotRevealTwice() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        string memory secretContent = "sensitive work details";
        bytes32 salt = keccak256("my_secret_salt");
        bytes32 contentHash = keccak256(abi.encodePacked(secretContent, salt));
        bytes32 proof = keccak256("cycle1content");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);
        network.inscribe(proof, genesisHead, "research", "private work", contentHash);

        vm.prank(agent1);
        network.reveal(1, secretContent, salt);

        // Try to reveal again
        vm.prank(agent1);
        vm.expectRevert("Already revealed");
        network.reveal(1, secretContent, salt);
    }

    function test_InvalidInscriptionId() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        // Try to reveal invalid ID
        vm.prank(agent1);
        vm.expectRevert("Invalid inscriptionId");
        network.reveal(999, "content", bytes32("salt"));

        // Try to get content for invalid ID
        vm.expectRevert("Invalid inscriptionId");
        network.getInscriptionContent(999);
    }

    function test_ProofInscribedEventWithNewParams() public {
        vm.prank(agent1);
        network.registerAgent("TestAgent");

        bytes32 proof = keccak256("cycle1content");
        bytes32 contentHash = keccak256(abi.encodePacked("secret", bytes32("salt")));

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agent1);

        // Check event is emitted with new params
        vm.expectEmit(true, true, false, false);
        emit CustosNetworkImpl.ProofInscribed(
            1,                      // agentId
            proof,                  // proofHash
            genesisHead,            // prevHash
            "research",             // blockType
            "private work",         // summary
            contentHash,            // contentHash (NEW)
            1,                      // inscriptionId (NEW)
            block.timestamp         // timestamp
        );
        network.inscribe(proof, genesisHead, "research", "private work", contentHash);
    }
}
