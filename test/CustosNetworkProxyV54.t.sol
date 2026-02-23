// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/CustosNetworkProxyV54.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @notice Tests for V5.4 commit-reveal additions.
 * Deploys V54 fresh (not via proxy upgrade) for unit testing.
 */
contract CustosNetworkProxyV54Test is Test {
    CustosNetworkProxyV54 network;

    address constant CUSTOS  = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE;
    address constant PIZZA   = 0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F;
    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TREASURY = 0x701450B24C2e603c961D4546e364b418a9e021D7;

    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");

    function setUp() public {
        // Deploy via ERC1967Proxy (matches production deployment pattern)
        CustosNetworkProxyV54 impl = new CustosNetworkProxyV54();
        bytes memory initData = abi.encodeCall(CustosNetworkProxyV54.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        network = CustosNetworkProxyV54(address(proxy));
        // initializeV54() has no state changes — all V5.4 storage slots default to zero.

        // Deploy a mock ERC20 at the USDC address
        MockERC20 mockUsdc = new MockERC20();
        vm.etch(USDC, address(mockUsdc).code);

        MockERC20(USDC).mint(agent1, 100e6);
        MockERC20(USDC).mint(agent2, 100e6);
        MockERC20(USDC).mint(TREASURY, 0); // ensure it exists

        vm.prank(agent1);
        IERC20(USDC).approve(address(network), type(uint256).max);
        vm.prank(agent2);
        IERC20(USDC).approve(address(network), type(uint256).max);
    }

    function _inscribePublic(address agent, bytes32 prevHash, string memory summary) internal returns (bytes32 proofHash) {
        proofHash = keccak256(abi.encodePacked(summary, block.timestamp));
        vm.prank(agent);
        network.inscribe(proofHash, prevHash, "build", summary, bytes32(0));
    }

    function _inscribePrivate(address agent, bytes32 prevHash, string memory content, bytes32 salt) internal returns (bytes32 proofHash, bytes32 contentHash, uint256 inscriptionId) {
        contentHash = keccak256(abi.encodePacked(content, salt));
        proofHash = keccak256(abi.encodePacked(content, salt, block.timestamp));
        vm.prank(agent);
        network.inscribe(proofHash, prevHash, "research", "private work", contentHash);
        inscriptionId = network.inscriptionCount();
    }

    // ─── Public (legacy) inscriptions ────────────────────────────────────────

    function test_PublicInscriptionHasZeroContentHash() public {
        bytes32 proof = _inscribePublic(agent1, bytes32(0), "cycle 1");
        uint256 id = network.inscriptionCount();
        assertEq(id, 1);
        assertEq(network.inscriptionContentHash(1), bytes32(0));
        assertEq(network.inscriptionRevealed(1), false);
        assertEq(network.proofHashToInscriptionId(proof), 1);
        assertEq(network.inscriptionAgent(1), agent1);
    }

    function test_InscriptionCountIncrements() public {
        _inscribePublic(agent1, bytes32(0), "cycle 1");
        assertEq(network.inscriptionCount(), 1);
        vm.warp(block.timestamp + 301);
        _inscribePublic(agent1, network.getAgent(network.agentIdByWallet(agent1)).chainHead, "cycle 2");
        assertEq(network.inscriptionCount(), 2);
    }

    // ─── Private (commit-reveal) inscriptions ────────────────────────────────

    function test_PrivateInscriptionStoresContentHash() public {
        bytes32 salt = keccak256("mysalt");
        string memory content = "secret research output";
        (, bytes32 contentHash, uint256 id) = _inscribePrivate(agent1, bytes32(0), content, salt);

        assertEq(network.inscriptionContentHash(id), contentHash);
        assertEq(network.inscriptionRevealed(id), false);
        assertEq(network.inscriptionAgent(id), agent1);

        (bool revealed, string memory storedContent, bytes32 storedHash) = network.getInscriptionContent(id);
        assertEq(revealed, false);
        assertEq(bytes(storedContent).length, 0);
        assertEq(storedHash, contentHash);
    }

    function test_RevealContent() public {
        bytes32 salt = keccak256("salt123");
        string memory content = "the actual research finding";
        (, , uint256 id) = _inscribePrivate(agent1, bytes32(0), content, salt);

        vm.prank(agent1);
        network.reveal(id, content, salt);

        (bool revealed, string memory storedContent, ) = network.getInscriptionContent(id);
        assertEq(revealed, true);
        assertEq(storedContent, content);
        assertEq(network.inscriptionRevealed(id), true);
        assertEq(network.inscriptionRevealedContent(id), content);
    }

    function test_CannotRevealWithWrongSalt() public {
        bytes32 salt = keccak256("correct-salt");
        bytes32 wrongSalt = keccak256("wrong-salt");
        string memory content = "secret";
        (, , uint256 id) = _inscribePrivate(agent1, bytes32(0), content, salt);

        vm.prank(agent1);
        vm.expectRevert("hash mismatch");
        network.reveal(id, content, wrongSalt);
    }

    function test_CannotRevealWithWrongContent() public {
        bytes32 salt = keccak256("salt");
        (, , uint256 id) = _inscribePrivate(agent1, bytes32(0), "real content", salt);

        vm.prank(agent1);
        vm.expectRevert("hash mismatch");
        network.reveal(id, "fake content", salt);
    }

    function test_CannotRevealTwice() public {
        bytes32 salt = keccak256("salt");
        string memory content = "content";
        (, , uint256 id) = _inscribePrivate(agent1, bytes32(0), content, salt);

        vm.prank(agent1);
        network.reveal(id, content, salt);

        vm.prank(agent1);
        vm.expectRevert("already revealed");
        network.reveal(id, content, salt);
    }

    function test_CannotRevealPublicInscription() public {
        _inscribePublic(agent1, bytes32(0), "public cycle");
        uint256 id = network.inscriptionCount();

        vm.prank(agent1);
        vm.expectRevert("public inscription");
        network.reveal(id, "anything", bytes32(0));
    }

    function test_CannotRevealIfNotInscriber() public {
        bytes32 salt = keccak256("salt");
        string memory content = "private";
        (, , uint256 id) = _inscribePrivate(agent1, bytes32(0), content, salt);

        vm.prank(agent2);
        vm.expectRevert("not inscriber");
        network.reveal(id, content, salt);
    }

    function test_InvalidInscriptionIdReverts() public {
        vm.expectRevert("invalid id");
        network.getInscriptionContent(0);

        vm.expectRevert("invalid id");
        network.getInscriptionContent(999);
    }

    function test_MultipleAgentsGetSeparateInscriptionIds() public {
        _inscribePublic(agent1, bytes32(0), "agent1 cycle1");
        uint256 id1 = network.inscriptionCount();

        _inscribePublic(agent2, bytes32(0), "agent2 cycle1");
        uint256 id2 = network.inscriptionCount();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(network.inscriptionAgent(1), agent1);
        assertEq(network.inscriptionAgent(2), agent2);
    }

    function test_ProofInscribedEventEmitsContentHashAndId() public {
        bytes32 salt = keccak256("salt");
        string memory content = "event test";
        bytes32 contentHash = keccak256(abi.encodePacked(content, salt));
        bytes32 proofHash = keccak256(abi.encodePacked(content, salt, block.timestamp));

        vm.expectEmit(true, true, false, true);
        emit CustosNetworkProxyV54.ProofInscribed(
            1, proofHash, bytes32(0), "research", "private work",
            1, contentHash, 1
        );
        vm.prank(agent1);
        network.inscribe(proofHash, bytes32(0), "research", "private work", contentHash);
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
