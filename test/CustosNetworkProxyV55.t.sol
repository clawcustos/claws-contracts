// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/CustosNetworkProxyV55.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CustosNetworkProxyV55Test is Test {
    CustosNetworkProxyV55 network;

    address constant USDC     = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TREASURY = 0x701450B24C2e603c961D4546e364b418a9e021D7;
    address constant CUSTOS   = 0x0528B8FE114020cc895FCf709081Aae2077b9aFE;
    address constant PIZZA    = 0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F;

    address skillWallet  = makeAddr("skill");
    address clientWallet = makeAddr("client");
    address validatorA   = makeAddr("validatorA");
    address validatorB   = makeAddr("validatorB");

    uint256 constant SKILL_FEE = 1_000_000; // 1 USDC

    function setUp() public {
        CustosNetworkProxyV55 impl = new CustosNetworkProxyV55();
        bytes memory initData = abi.encodeCall(CustosNetworkProxyV55.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        network = CustosNetworkProxyV55(address(proxy));

        // Mock USDC
        MockERC20 mockUsdc = new MockERC20();
        vm.etch(USDC, address(mockUsdc).code);
        MockERC20(USDC).mint(skillWallet,  100e6);
        MockERC20(USDC).mint(clientWallet, 100e6);

        vm.prank(skillWallet);
        MockERC20(USDC).approve(address(network), type(uint256).max);
        vm.prank(clientWallet);
        MockERC20(USDC).approve(address(network), type(uint256).max);

        // Register client as an agent first (needs inscribeCount > 0)
        // Client auto-registers via proveExecution — but needs skill first
        // So register skill first, then client will auto-reg on proveExecution
    }

    // ─── registerSkill ────────────────────────────────────────────────────────

    function test_RegisterSkill() public {
        vm.prank(skillWallet);
        network.registerSkill("TestSkill", "1.0.0", SKILL_FEE);

        uint256 agentId = network.agentIdByWallet(skillWallet);
        assertGt(agentId, 0);

        CustosNetworkProxyV55.SkillMetadata memory meta = network.getSkillMetadata(agentId);
        assertEq(meta.name, "TestSkill");
        assertEq(meta.version, "1.0.0");
        assertEq(meta.feePerExecution, SKILL_FEE);
        assertEq(meta.active, true);

        // SKILL_INSCRIPTION_FEE deducted from skillWallet
        assertEq(MockERC20(USDC).balanceOf(TREASURY), 10_000);
    }

    function test_RegisterSkill_BadArgs() public {
        vm.prank(skillWallet);
        vm.expectRevert("bad args");
        network.registerSkill("", "1.0.0", SKILL_FEE);

        vm.prank(skillWallet);
        vm.expectRevert("bad args");
        network.registerSkill("TestSkill", "1.0.0", 0);
    }

    // ─── proveExecution ───────────────────────────────────────────────────────

    function _registerSkillAndClient() internal returns (uint256 skillAgentId) {
        vm.prank(skillWallet);
        network.registerSkill("TestSkill", "1.0.0", SKILL_FEE);
        skillAgentId = network.agentIdByWallet(skillWallet);

        // Register client via inscribe (auto-registration)
        // Need to seed client as agent — use registerSkill with different name
        vm.prank(clientWallet);
        network.registerSkill("ClientAgent", "1.0.0", 1); // registers client as agent
    }

    function test_ProveExecution() public {
        uint256 skillAgentId = _registerSkillAndClient();

        bytes32 execHash = keccak256("input+output+timestamp");
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, execHash);

        assertEq(network.executionCount(), 1);
        CustosNetworkProxyV55.ExecutionRecord memory exec = network.getExecution(1);
        assertEq(exec.skillAgentId, skillAgentId);
        assertEq(exec.fee, SKILL_FEE);
        assertEq(uint8(exec.status), uint8(CustosNetworkProxyV55.ExecutionStatus.Pending));

        // 2x fee locked in contract
        assertEq(MockERC20(USDC).balanceOf(address(network)), SKILL_FEE * 2);
    }

    function test_ProveExecution_InactiveSkill() public {
        _registerSkillAndClient();
        uint256 skillAgentId = network.agentIdByWallet(skillWallet);

        vm.prank(CUSTOS);
        network.deactivateSkill(skillAgentId);

        bytes32 execHash = keccak256("input+output");
        vm.prank(clientWallet);
        vm.expectRevert("invalid");
        network.proveExecution(skillAgentId, execHash);
    }

    function test_ProveExecution_SelfExecuteReverts() public {
        uint256 skillAgentId = _registerSkillAndClient();

        bytes32 execHash = keccak256("self");
        vm.prank(skillWallet);
        vm.expectRevert("bad client");
        network.proveExecution(skillAgentId, execHash);
    }

    // ─── claimPayment ─────────────────────────────────────────────────────────

    function test_ClaimPayment_AfterWindow() public {
        uint256 skillAgentId = _registerSkillAndClient();
        bytes32 execHash = keccak256("work done");

        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, execHash);

        // Warp past 24h window
        vm.warp(block.timestamp + 25 hours);

        uint256 skillBefore  = MockERC20(USDC).balanceOf(skillWallet);
        uint256 clientBefore = MockERC20(USDC).balanceOf(clientWallet);

        vm.prank(skillWallet);
        network.claimPayment(1);

        // Skill gets fee, client gets bond refund
        assertEq(MockERC20(USDC).balanceOf(skillWallet),  skillBefore  + SKILL_FEE);
        assertEq(MockERC20(USDC).balanceOf(clientWallet), clientBefore + SKILL_FEE);
        assertEq(uint8(network.getExecution(1).status), uint8(CustosNetworkProxyV55.ExecutionStatus.Released));
    }

    function test_ClaimPayment_BeforeWindowReverts() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("work"));

        vm.prank(skillWallet);
        vm.expectRevert("window open");
        network.claimPayment(1);
    }

    function test_ClaimPayment_WrongCallerReverts() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("work"));
        vm.warp(block.timestamp + 25 hours);

        vm.prank(clientWallet);
        vm.expectRevert("not skill");
        network.claimPayment(1);
    }

    // ─── fileDispute ──────────────────────────────────────────────────────────

    function test_FileDispute() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("work"));

        vm.prank(clientWallet);
        network.fileDispute(1);

        assertEq(uint8(network.getExecution(1).status), uint8(CustosNetworkProxyV55.ExecutionStatus.Disputed));
        assertEq(network.getDisputeBond(1), SKILL_FEE);
    }

    function test_FileDispute_AfterWindowReverts() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("work"));

        vm.warp(block.timestamp + 25 hours);
        vm.prank(clientWallet);
        vm.expectRevert("window closed");
        network.fileDispute(1);
    }

    function test_FileDispute_WrongClientReverts() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("work"));

        vm.prank(skillWallet); // wrong caller
        vm.expectRevert("not client");
        network.fileDispute(1);
    }

    // ─── dispute resolution (admin) ───────────────────────────────────────────

    function test_AdminResolvesDisputeForClient() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("bad output"));

        vm.prank(clientWallet);
        network.fileDispute(1);

        uint256 clientBefore = MockERC20(USDC).balanceOf(clientWallet);

        vm.prank(CUSTOS);
        network.resolveDisputeAdmin(1, true); // client wins

        // Client gets fee + bond back (2x fee)
        assertEq(MockERC20(USDC).balanceOf(clientWallet), clientBefore + SKILL_FEE * 2);
        assertEq(uint8(network.getExecution(1).status), uint8(CustosNetworkProxyV55.ExecutionStatus.ResolvedForClient));
    }

    function test_AdminResolvesDisputeForSkill() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("good output"));

        vm.prank(clientWallet);
        network.fileDispute(1);

        uint256 skillBefore = MockERC20(USDC).balanceOf(skillWallet);

        vm.prank(PIZZA);
        network.resolveDisputeAdmin(1, false); // skill wins

        // Skill gets fee + bond (2x fee, penalty for false dispute)
        assertEq(MockERC20(USDC).balanceOf(skillWallet), skillBefore + SKILL_FEE * 2);
        assertEq(uint8(network.getExecution(1).status), uint8(CustosNetworkProxyV55.ExecutionStatus.ResolvedForSkill));
    }

    function test_AdminResolveOnlyByCustodian() public {
        uint256 skillAgentId = _registerSkillAndClient();
        vm.prank(clientWallet);
        network.proveExecution(skillAgentId, keccak256("work"));
        vm.prank(clientWallet);
        network.fileDispute(1);

        vm.prank(makeAddr("rando"));
        vm.expectRevert("not custodian");
        network.resolveDisputeAdmin(1, true);
    }

    // ─── deactivateSkill ──────────────────────────────────────────────────────

    function test_DeactivateSkill() public {
        vm.prank(skillWallet);
        network.registerSkill("TestSkill", "1.0.0", SKILL_FEE);
        uint256 agentId = network.agentIdByWallet(skillWallet);

        vm.prank(CUSTOS);
        network.deactivateSkill(agentId);

        assertEq(network.getSkillMetadata(agentId).active, false);
    }
}

// ─── Mock ERC20 ───────────────────────────────────────────────────────────────

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
