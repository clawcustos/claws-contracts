// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ClawsFarcaster as Claws} from "../src/ClawsFarcaster.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ClawsFarcasterTest is Test {
    Claws public claws;

    // Events to test
    event WhitelistUpdated(uint256 indexed fid, bool status);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    address public owner = address(1);
    address public verifier = address(2);
    address public treasury = address(3);
    address public trader1 = address(4);
    address public trader2 = address(5);
    address public agentWallet = address(6);
    
    uint256 public verifierPk = 0xA11CE;
    
    string public constant HANDLE = "testhandle";
    uint256 public constant FID1 = 12345;
    string public constant HANDLE2 = "anotherhandle";
    uint256 public constant FID2 = 67890;
    
    function setUp() public {
        verifier = vm.addr(verifierPk);
        
        vm.prank(owner);
        claws = new Claws(verifier, treasury);
        
        vm.deal(trader1, 100 ether);
        vm.deal(trader2, 100 ether);
        vm.deal(agentWallet, 1 ether);
    }
    
    // ============ Helpers ============

    function _signVerification(uint256 fid, address wallet, uint256 timestamp, uint256 nonce) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            claws.VERIFY_TYPEHASH(),
            fid,
            wallet,
            timestamp,
            nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", claws.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ============ Deployment ============
    
    function test_Deployment() public view {
        assertEq(claws.owner(), owner);
        assertEq(claws.verifier(), verifier);
        assertEq(claws.treasury(), treasury);
        assertEq(claws.protocolFeeBps(), 500);
        assertEq(claws.agentFeeBps(), 500);
        assertEq(claws.MAX_FEE_BPS(), 1000);
        assertEq(claws.PRICE_DIVISOR(), 48000);
    }
    
    function test_DeploymentRevertsZeroVerifier() public {
        vm.expectRevert(Claws.ZeroAddress.selector);
        new Claws(address(0), treasury);
    }
    
    function test_DeploymentRevertsZeroTreasury() public {
        vm.expectRevert(Claws.ZeroAddress.selector);
        new Claws(verifier, address(0));
    }
    
    // ============ Market Creation ============
    
    function test_CreateMarket() public {
        claws.createMarket(FID1, HANDLE);
        
        assertTrue(claws.marketExists(FID1));
        
        (uint256 supply,,,,,,uint256 createdAt,,) = claws.getMarket(FID1);
        assertEq(supply, 0);
        assertGt(createdAt, 0);
    }
    
    function test_CreateMarketAutoCreatesOnBuy() public {
        // Whitelist handle for free first claw (legacy behavior)
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        assertFalse(claws.marketExists(FID1));

        uint256 price = claws.getBuyPriceByFid(FID1, 1);
        uint256 totalCost = price + (price * 1000 / 10000); // 10% fees

        vm.prank(trader1);
        claws.buyClaws{value: totalCost + 0.01 ether}(FID1, 1, 0);

        assertTrue(claws.marketExists(FID1));
    }
    
    function test_CreateMarketWithDifferentFids() public {
        claws.createMarket(FID1, HANDLE);
        claws.createMarket(FID2, HANDLE2);
        assertTrue(claws.marketExists(FID1));
        assertTrue(claws.marketExists(FID2));
    }
    
    function test_CreateMarketRevertsAlreadyExists() public {
        claws.createMarket(FID1, HANDLE);
        vm.expectRevert(Claws.MarketAlreadyExists.selector);
        claws.createMarket(FID1, HANDLE);
    }
    
    // ============ Buy Claws ============
    
    function test_BuyClaws() public {
        // Whitelist handle so we can buy min 1
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // Whitelisted first buy of 1: first claw (supply=0) is free
        uint256 treasuryBefore = treasury.balance;

        vm.prank(trader1);
        claws.buyClaws{value: 0}(FID1, 1, 0);

        // Buy 1, get 1 (the free supply=0 claw)
        assertEq(claws.getBalance(FID1, trader1), 1);

        (uint256 supply, uint256 pendingFees,,,,,,, ) = claws.getMarket(FID1);
        assertEq(supply, 1);
        assertEq(pendingFees, 0); // No fees on free claw
        assertEq(treasury.balance - treasuryBefore, 0);
    }
    
    function test_BuyMultipleClaws() public {
        (uint256 price,,,uint256 totalCost) = claws.getBuyCostBreakdown(FID1, 5);

        vm.prank(trader1);
        claws.buyClaws{value: totalCost}(FID1, 5, 0);

        assertEq(claws.getBalance(FID1, trader1), 5);
        
        (uint256 supply,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supply, 5);
    }
    
    function test_BuyClawsRefundsExcess() public {
        // Whitelist handle
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // Buy 2 on whitelisted: first claw free, second costs 1^2/48000
        uint256 price = 0.000020833333333333 ether;
        uint256 protocolFee = price * 500 / 10000;
        uint256 agentFee = price * 500 / 10000;
        uint256 totalCost = price + protocolFee + agentFee;
        uint256 excess = 1 ether;

        uint256 balanceBefore = trader1.balance;

        vm.prank(trader1);
        claws.buyClaws{value: totalCost + excess}(FID1, 2, 0);

        assertEq(balanceBefore - trader1.balance, totalCost);
    }
    
    function test_BuyClawsRevertsZeroAmount() public {
        vm.prank(trader1);
        vm.expectRevert(Claws.InvalidAmount.selector);
        claws.buyClaws{value: 1 ether}(FID1, 0, 0);
    }
    
    function test_BuyClawsRevertsInsufficientPayment() public {
        // Test with 2 claws (which costs 0.000020833333333333 ETH + fees)
        vm.prank(trader1);
        vm.expectRevert(Claws.InsufficientPayment.selector);
        claws.buyClaws{value: 0.00001 ether}(FID1, 2, 0);
    }
    
    // ============ Sell Claws ============
    
    function test_SellClaws() public {
        // First buy some claws
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);
        
        // Then sell some
        (uint256 sellPrice,,, uint256 proceeds) = claws.getSellProceedsBreakdown(FID1, 2);
        
        uint256 balanceBefore = trader1.balance;
        
        vm.prank(trader1);
        claws.sellClaws(FID1, 2, proceeds);
        
        assertEq(claws.getBalance(FID1, trader1), 3);
        assertEq(trader1.balance - balanceBefore, proceeds);
        
        (uint256 supply,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supply, 3);
    }
    
    function test_SellClawsRevertsInsufficientBalance() public {
        // Whitelist handle for free first claw
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // Price from supply 1 for 1 claw = 1^2/48000 = 0.000020833333333333 ETH
        uint256 buyPrice = 0.000020833333333333 ether;
        uint256 buyCost = buyPrice + (buyPrice * 1000 / 10000);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 1, 0);

        // Has 2 claws (with bonus), try to sell 5
        vm.prank(trader1);
        vm.expectRevert(Claws.InsufficientBalance.selector);
        claws.sellClaws(FID1, 5, 0);
    }
    
    function test_SellClawsRevertsCannotSellLast() public {
        // Create market with non-whitelisted handle to avoid bonus claw complications
        // Buy 3 claws (minimum 2 for first buy on non-whitelisted)
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 3);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 3, 0);

        // Verify we have 3 claws
        assertEq(claws.getBalance(FID1, trader1), 3);

        // Sell 2, leaving 1
        vm.prank(trader1);
        claws.sellClaws(FID1, 2, 0);

        // Verify we have 1 claw left
        assertEq(claws.getBalance(FID1, trader1), 1);

        // Now try to sell the last one - should revert
        vm.prank(trader1);
        vm.expectRevert(Claws.CannotSellLastClaw.selector);
        claws.sellClaws(FID1, 1, 0);
    }
    
    function test_SellClawsRevertsSlippageExceeded() public {
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);
        
        vm.prank(trader1);
        vm.expectRevert(Claws.SlippageExceeded.selector);
        claws.sellClaws(FID1, 2, 100 ether); // Unrealistic minProceeds
    }
    
    // ============ Price Calculations ============
    
    function test_BondingCurvePricing() public view {
        // At supply=0, buying 1 claw: sum of squares from 0 to 0 = 0^2 = 0
        uint256 price1 = claws.getBuyPriceByFid(FID1, 1);
        assertEq(price1, 0);

        // At supply=0, buying 2 claws: sum of squares from 0 to 1 = 0^2 + 1^2 = 1
        // Price = 1 * 1 ether / 48000 = 0.000020833333333333 ETH
        uint256 price2 = claws.getBuyPriceByFid(FID1, 2);
        assertEq(price2, 0.000020833333333333 ether);
    }
    
    function test_GetCurrentPrice() public {
        // Whitelist handle for free first claw behavior
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // At supply=0, next claw price = 0^2/48000 = 0
        assertEq(claws.getCurrentPrice(FID1), 0);

        // Buy 1 claw (whitelisted: first claw is free)
        vm.prank(trader1);
        claws.buyClaws{value: 0}(FID1, 1, 0);

        // At supply=1, next claw price = 1^2/48000 = 0.000020833333333333 ETH
        assertEq(claws.getCurrentPrice(FID1), 0.000020833333333333 ether);
    }
    
    function test_GetBuyCostBreakdown() public view {
        (uint256 price, uint256 protocolFee, uint256 agentFee, uint256 totalCost) = 
            claws.getBuyCostBreakdown(FID1, 1);
        
        assertEq(protocolFee, price * 500 / 10000);
        assertEq(agentFee, price * 500 / 10000);
        assertEq(totalCost, price + protocolFee + agentFee);
    }
    
    function test_GetSellProceedsBreakdown() public {
        // Buy first
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);
        
        (uint256 price, uint256 protocolFee, uint256 agentFee, uint256 proceeds) = 
            claws.getSellProceedsBreakdown(FID1, 2);
        
        assertEq(protocolFee, price * 500 / 10000);
        assertEq(agentFee, price * 500 / 10000);
        assertEq(proceeds, price - protocolFee - agentFee);
    }
    
    // ============ Verification ============
    
    function test_VerifyAndClaim() public {
        // Buy some claws first (generates fees)
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 10);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 10, 0);
        
        (,uint256 pendingFees,,,,,,,) = claws.getMarket(FID1);
        assertGt(pendingFees, 0);
        
        // Create verification signature
        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;

        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        uint256 walletBefore = agentWallet.balance;

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);
        
        // Check verification state
        (,uint256 newPendingFees,,,address verifiedWallet, bool isVerified,,,) = claws.getMarket(FID1);
        assertTrue(isVerified);
        assertEq(verifiedWallet, agentWallet);
        assertEq(newPendingFees, 0);
        assertEq(agentWallet.balance - walletBefore, pendingFees);
    }
    
    function test_VerifyRevertsInvalidSignature() public {
        claws.createMarket(FID1, HANDLE);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;

        // Sign with wrong key using EIP-712
        uint256 wrongPk = 0xBAD;
        bytes32 structHash = keccak256(abi.encode(
            claws.VERIFY_TYPEHASH(),
            FID1,
            agentWallet,
            timestamp,
            nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", claws.DOMAIN_SEPARATOR(), structHash));
        (uint8 vWrong, bytes32 rWrong, bytes32 sWrong) = vm.sign(wrongPk, digest);
        bytes memory signature = abi.encodePacked(rWrong, sWrong, vWrong);

        vm.prank(agentWallet);
        vm.expectRevert(Claws.InvalidSignature.selector);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);
    }
    
    function test_VerifyRevertsAlreadyVerified() public {
        // Whitelist handle for free first claw
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // First buy - price from supply 1 for 1 claw = 1^2/48000 = 0.000020833333333333 ETH
        uint256 buyPrice = 0.000020833333333333 ether;
        uint256 buyCost = buyPrice + (buyPrice * 1000 / 10000);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 1, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;

        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Try to verify again
        uint256 newNonce = 99999;
        signature = _signVerification(FID1, agentWallet, timestamp, newNonce);

        vm.prank(agentWallet);
        vm.expectRevert(Claws.AlreadyVerified.selector);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, newNonce, signature);
    }
    
    // ============ Claim Fees ============
    
    function test_ClaimFees() public {
        // Buy claws, verify, then buy more to generate new fees
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        // Verify
        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Buy more (generates new fees)
        (,,,uint256 buyCost2) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader2);
        claws.buyClaws{value: buyCost2}(FID1, 5, 0);
        
        (,uint256 pendingFees,,,,,,,) = claws.getMarket(FID1);
        assertGt(pendingFees, 0);
        
        uint256 walletBefore = agentWallet.balance;
        
        vm.prank(agentWallet);
        claws.claimFees(FID1);
        
        assertEq(agentWallet.balance - walletBefore, pendingFees);
        
        (,uint256 newPendingFees,,,,,,,) = claws.getMarket(FID1);
        assertEq(newPendingFees, 0);
    }
    
    function test_ClaimFeesRevertsNotVerified() public {
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);
        
        vm.prank(agentWallet);
        vm.expectRevert(Claws.NotVerified.selector);
        claws.claimFees(FID1);
    }
    
    function test_ClaimFeesRevertsWrongWallet() public {
        // Buy and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes32 structHash = keccak256(abi.encode(
            claws.VERIFY_TYPEHASH(),
            FID1,
            agentWallet,
            timestamp,
            nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", claws.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Buy more
        (,,,uint256 buyCost2) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader2);
        claws.buyClaws{value: buyCost2}(FID1, 5, 0);

        // Wrong wallet tries to claim
        vm.prank(trader1);
        vm.expectRevert(Claws.NotVerified.selector);
        claws.claimFees(FID1);
    }

    // ============ Agent Metadata ============

    function test_SetAgentMetadata() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Set metadata as verified agent
        string memory bio = "AI agent for crypto trading";
        string memory website = "https://myagent.xyz";
        address token = address(0x123);

        vm.prank(agentWallet);
        claws.setAgentMetadata(FID1, bio, website, token);

        // Verify metadata was set
        (string memory storedBio, string memory storedWebsite, address storedToken) = claws.getAgentMetadata(FID1);
        assertEq(storedBio, bio);
        assertEq(storedWebsite, website);
        assertEq(storedToken, token);
    }

    function test_SetAgentMetadataEmitsEvent() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Expect MetadataUpdated event
        vm.expectEmit(true, false, false, true);
        emit Claws.MetadataUpdated(FID1);

        vm.prank(agentWallet);
        claws.setAgentMetadata(FID1, "Bio", "https://example.com", address(0));
    }

    function test_SetAgentMetadataRevertsNotVerified() public {
        // Create market but don't verify
        claws.createMarket(FID1, HANDLE);

        // Non-verified agent tries to set metadata
        vm.prank(agentWallet);
        vm.expectRevert(Claws.NotVerified.selector);
        claws.setAgentMetadata(FID1, "Bio", "https://example.com", address(0));
    }

    function test_SetAgentMetadataRevertsWrongWallet() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Wrong wallet tries to set metadata
        vm.prank(trader1);
        vm.expectRevert(Claws.NotVerified.selector);
        claws.setAgentMetadata(FID1, "Bio", "https://example.com", address(0));
    }

    function test_SetAgentMetadataRevertsBioTooLong() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Create bio with 281 characters (too long)
        string memory longBio = string(new bytes(281));

        // Try to set metadata with long bio
        vm.prank(agentWallet);
        vm.expectRevert(Claws.BioTooLong.selector);
        claws.setAgentMetadata(FID1, longBio, "https://example.com", address(0));
    }

    function test_SetAgentMetadataMaxBioLength() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Create bio with exactly 280 characters (max allowed)
        string memory maxBio = string(new bytes(280));

        // Should succeed
        vm.prank(agentWallet);
        claws.setAgentMetadata(FID1, maxBio, "https://example.com", address(0));

        // Verify metadata was set
        (string memory storedBio,,) = claws.getAgentMetadata(FID1);
        assertEq(bytes(storedBio).length, 280);
    }

    function test_GetAgentMetadataReturnsCorrectData() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Set metadata
        string memory bio = "AI agent for crypto trading";
        string memory website = "https://myagent.xyz";
        address token = address(0xABC);

        vm.prank(agentWallet);
        claws.setAgentMetadata(FID1, bio, website, token);

        // Get metadata and verify all fields
        (string memory storedBio, string memory storedWebsite, address storedToken) = claws.getAgentMetadata(FID1);
        assertEq(storedBio, bio);
        assertEq(storedWebsite, website);
        assertEq(storedToken, token);
    }

    function test_AgentMetadataCanBeUpdated() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Set initial metadata
        vm.prank(agentWallet);
        claws.setAgentMetadata(FID1, "Initial bio", "https://initial.com", address(0x111));

        // Update metadata
        vm.prank(agentWallet);
        claws.setAgentMetadata(FID1, "Updated bio", "https://updated.com", address(0x222));

        // Verify metadata was updated
        (string memory storedBio, string memory storedWebsite, address storedToken) = claws.getAgentMetadata(FID1);
        assertEq(storedBio, "Updated bio");
        assertEq(storedWebsite, "https://updated.com");
        assertEq(storedToken, address(0x222));
    }

    function test_GetAgentMetadataEmptyReturnsDefaults() public {
        // Query metadata for handle that hasn't set any metadata
        (string memory bio, string memory website, address token) = claws.getAgentMetadata(FID1);

        // Should return empty strings and zero address
        assertEq(bio, "");
        assertEq(website, "");
        assertEq(token, address(0));
    }

    function test_AgentMetadataAfterRevocation() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Set metadata
        vm.prank(agentWallet);
        claws.setAgentMetadata(FID1, "My bio", "https://example.com", address(0x123));

        // Revoke verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        // Original wallet can no longer set metadata
        vm.prank(agentWallet);
        vm.expectRevert(Claws.NotVerified.selector);
        claws.setAgentMetadata(FID1, "New bio", "https://new.com", address(0x456));

        // But metadata remains stored (not cleared on revocation)
        (string memory bio, string memory website, address token) = claws.getAgentMetadata(FID1);
        assertEq(bio, "My bio");
        assertEq(website, "https://example.com");
        assertEq(token, address(0x123));
    }
    
    // ============ Handle Normalization ============
    
    function test_FidUniqueness() public {
        claws.createMarket(FID1, HANDLE);
        vm.expectRevert(Claws.MarketAlreadyExists.selector);
        claws.createMarket(FID1, "differentname");
    }
    
    // ============ Admin Functions ============

    function test_UpdateAgentWallet() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Owner updates wallet
        address newWallet = address(99);
        vm.prank(owner);
        claws.updateAgentWallet(FID1, newWallet);

        (,,,,address verifiedWallet, bool isVerified,,,) = claws.getMarket(FID1);
        assertEq(verifiedWallet, newWallet);
        assertTrue(isVerified);
    }

    function test_UpdateAgentWalletRevertsNotOwner() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Non-owner tries to update
        address newWallet = address(99);
        vm.prank(trader1);
        vm.expectRevert();
        claws.updateAgentWallet(FID1, newWallet);
    }

    function test_UpdateAgentWalletRevertsZeroAddress() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Owner tries to set zero address
        vm.prank(owner);
        vm.expectRevert(Claws.ZeroAddress.selector);
        claws.updateAgentWallet(FID1, address(0));
    }

    function test_UpdateAgentWalletRevertsMarketNotVerified() public {
        // Create market but don't verify
        claws.createMarket(FID1, HANDLE);

        // Owner tries to update wallet on unverified market
        vm.prank(owner);
        vm.expectRevert(Claws.MarketNotVerified.selector);
        claws.updateAgentWallet(FID1, address(99));
    }

    // ============================================
    // Self-Service Wallet Update (updateMyWallet)
    // ============================================

    function test_UpdateMyWallet() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Agent updates their own wallet
        address newWallet = address(0xBEEF);
        vm.prank(agentWallet);
        claws.updateMyWallet(FID1, newWallet);

        (,,,,address verifiedWallet, bool isVerified,,,) = claws.getMarket(FID1);
        assertEq(verifiedWallet, newWallet);
        assertTrue(isVerified);
    }

    function test_UpdateMyWalletRevertsNotVerifiedWallet() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Random address tries to update — should revert
        vm.prank(trader1);
        vm.expectRevert(Claws.NotVerifiedAgent.selector);
        claws.updateMyWallet(FID1, address(0xBEEF));
    }

    function test_UpdateMyWalletRevertsZeroAddress() public {
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        vm.prank(agentWallet);
        vm.expectRevert(Claws.ZeroAddress.selector);
        claws.updateMyWallet(FID1, address(0));
    }

    function test_UpdateMyWalletRevertsMarketNotVerified() public {
        claws.createMarket(FID1, HANDLE);

        vm.prank(trader1);
        vm.expectRevert(Claws.MarketNotVerified.selector);
        claws.updateMyWallet(FID1, address(0xBEEF));
    }

    function test_UpdateMyWalletThenClaimFees() public {
        // Setup: Buy claws, verify, generate fees
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Generate some fees with another trade
        (,,,uint256 buyCost2) = claws.getBuyCostBreakdown(FID1, 3);
        vm.prank(trader2);
        claws.buyClaws{value: buyCost2}(FID1, 3, 0);

        // Agent updates wallet
        address newWallet = address(0xBEEF);
        vm.prank(agentWallet);
        claws.updateMyWallet(FID1, newWallet);

        // New wallet can claim fees
        (,uint256 pendingFees,,,,,,,) = claws.getMarket(FID1);
        assertGt(pendingFees, 0);

        uint256 balBefore = newWallet.balance;
        vm.prank(newWallet);
        claws.claimFees(FID1);
        assertGt(newWallet.balance, balBefore);
    }

    function test_RevokeVerification() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Owner revokes verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        (,,,,address verifiedWallet, bool isVerified,,,) = claws.getMarket(FID1);
        assertEq(verifiedWallet, address(0));
        assertFalse(isVerified);
    }

    function test_RevokeVerificationRevertsNotOwner() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Non-owner tries to revoke
        vm.prank(trader1);
        vm.expectRevert();
        claws.revokeVerification(FID1);
    }

    function test_RevokeVerificationRevertsMarketNotVerified() public {
        // Create market but don't verify
        claws.createMarket(FID1, HANDLE);

        // Owner tries to revoke unverified market
        vm.prank(owner);
        vm.expectRevert(Claws.MarketNotVerified.selector);
        claws.revokeVerification(FID1);
    }

    function test_ClaimFeesFailsAfterRevocation() public {
        // Setup: Buy claws, verify, buy more to generate fees
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Buy more to generate fees
        (,,,uint256 buyCost2) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader2);
        claws.buyClaws{value: buyCost2}(FID1, 5, 0);

        // Revoke verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        // Original wallet should not be able to claim fees anymore
        vm.prank(agentWallet);
        vm.expectRevert(Claws.NotVerified.selector);
        claws.claimFees(FID1);
    }

    function test_PendingFeesRemainAfterRevocation() public {
        // Setup: Buy claws, verify, buy more to generate fees
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Buy more to generate fees
        (,,,uint256 buyCost2) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader2);
        claws.buyClaws{value: buyCost2}(FID1, 5, 0);

        // Check pending fees
        (,uint256 pendingFeesBefore,,,,,,,) = claws.getMarket(FID1);
        assertGt(pendingFeesBefore, 0);

        // Revoke verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        // Pending fees should remain
        (,uint256 pendingFeesAfter,,,,,,,) = claws.getMarket(FID1);
        assertEq(pendingFeesAfter, pendingFeesBefore);
    }

    function test_SupplyAndBalancesUnchangedAfterRevocation() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        uint256 supplyBefore = claws.getBalance(FID1, agentWallet);
        (uint256 marketSupplyBefore,,,,,,,,) = claws.getMarket(FID1);

        // Revoke verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        // Agent's balance should remain unchanged
        assertEq(claws.getBalance(FID1, agentWallet), supplyBefore);

        // Market supply should remain unchanged
        (uint256 marketSupplyAfter,,,,,,,,) = claws.getMarket(FID1);
        assertEq(marketSupplyAfter, marketSupplyBefore);
    }

    function test_AgentCanReverifyAfterRevocation() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Revoke verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        // Re-verify with same wallet
        uint256 newTimestamp = block.timestamp + 1;
        uint256 newNonce = 99999;
        signature = _signVerification(FID1, agentWallet, newTimestamp, newNonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, newTimestamp, newNonce, signature);

        (,,,,address verifiedWallet, bool isVerified,,,) = claws.getMarket(FID1);
        assertTrue(isVerified);
        assertEq(verifiedWallet, agentWallet);
    }

    function test_AgentCanReverifyWithDifferentWalletAfterRevocation() public {
        // Setup: Buy claws and verify
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Revoke verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        // Re-verify with a different wallet
        address newWallet = address(99);
        uint256 newTimestamp = block.timestamp + 1;
        uint256 newNonce = 99999;
        signature = _signVerification(FID1, newWallet, newTimestamp, newNonce);

        vm.prank(newWallet);
        claws.verifyAndClaim(FID1, newWallet, newTimestamp, newNonce, signature);

        (,,,,address verifiedWallet, bool isVerified,,,) = claws.getMarket(FID1);
        assertTrue(isVerified);
        assertEq(verifiedWallet, newWallet);
    }

    function test_PendingFeesClaimableAfterReverification() public {
        // Setup: Buy claws, verify, buy more to generate fees
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);

        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);

        // Buy more to generate fees
        (,,,uint256 buyCost2) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader2);
        claws.buyClaws{value: buyCost2}(FID1, 5, 0);

        // Track pending fees before revocation
        (,uint256 pendingFees,,,,,,,) = claws.getMarket(FID1);
        assertGt(pendingFees, 0);

        // Revoke verification
        vm.prank(owner);
        claws.revokeVerification(FID1);

        // Re-verify
        address newWallet = address(99);
        vm.deal(newWallet, 1 ether);
        uint256 newTimestamp = block.timestamp + 1;
        uint256 newNonce = 99999;
        signature = _signVerification(FID1, newWallet, newTimestamp, newNonce);

        uint256 walletBefore = newWallet.balance;

        vm.prank(newWallet);
        claws.verifyAndClaim(FID1, newWallet, newTimestamp, newNonce, signature);

        // New wallet should receive the pending fees that were frozen during revocation
        assertEq(newWallet.balance - walletBefore, pendingFees);
    }

    function test_SetVerifier() public {
        address newVerifier = address(99);
        
        vm.prank(owner);
        claws.setVerifier(newVerifier);
        
        assertEq(claws.verifier(), newVerifier);
    }
    
    function test_SetVerifierRevertsNotOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        claws.setVerifier(address(99));
    }
    
    function test_SetTreasury() public {
        address newTreasury = address(88);
        
        vm.prank(owner);
        claws.setTreasury(newTreasury);
        
        assertEq(claws.treasury(), newTreasury);
    }
    
    function test_SetTreasuryRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Claws.ZeroAddress.selector);
        claws.setTreasury(address(0));
    }
    
    // ============ Volume & Fee Tracking ============
    
    function test_LifetimeVolumeTracking() public {
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);
        
        (,,uint256 lifetimeFees, uint256 lifetimeVolume,,,,,) = claws.getMarket(FID1);
        assertGt(lifetimeFees, 0);
        assertGt(lifetimeVolume, 0);
    }
    
    // ============ Multiple Markets ============
    
    function test_MultipleMarkets() public {
        (,,,uint256 cost1) = claws.getBuyCostBreakdown(FID1, 3);
        (,,,uint256 cost2) = claws.getBuyCostBreakdown(FID2, 5);
        
        vm.prank(trader1);
        claws.buyClaws{value: cost1}(FID1, 3, 0);
        
        vm.prank(trader1);
        claws.buyClaws{value: cost2}(FID2, 5, 0);
        
        assertEq(claws.getBalance(FID1, trader1), 3);
        assertEq(claws.getBalance(FID2, trader1), 5);
        
        (uint256 supply1,,,,,,,,) = claws.getMarket(FID1);
        (uint256 supply2,,,,,,,,) = claws.getMarket(FID2);
        
        assertEq(supply1, 3);
        assertEq(supply2, 5);
    }
    
    // ============ Pause Functionality ============
    
    function test_Pause() public {
        vm.prank(owner);
        claws.pause();
        
        assertTrue(claws.paused());
    }
    
    function test_PauseBlocksBuying() public {
        vm.prank(owner);
        claws.pause();
        
        vm.prank(trader1);
        vm.expectRevert();
        claws.buyClaws{value: 1 ether}(FID1, 1, 0);
    }
    
    function test_PauseBlocksSelling() public {
        // Buy first
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);
        
        // Pause
        vm.prank(owner);
        claws.pause();
        
        // Try to sell
        vm.prank(trader1);
        vm.expectRevert();
        claws.sellClaws(FID1, 2, 0);
    }
    
    function test_Unpause() public {
        // Whitelist handle for free first claw
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        vm.prank(owner);
        claws.pause();
        assertTrue(claws.paused());

        vm.prank(owner);
        claws.unpause();
        assertFalse(claws.paused());

        // Can trade again (whitelisted first claw is free)
        vm.prank(trader1);
        claws.buyClaws{value: 0}(FID1, 1, 0);
        assertEq(claws.getBalance(FID1, trader1), 1);
    }
    
    function test_PauseOnlyOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        claws.pause();
    }
    
    // ============ Verified Agent Gets Free Claw ============
    
    function test_VerifiedAgentDoesNotGetFreeClawOnVerify() public {
        // Buy some claws first (generates fees)
        (,,,uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);
        
        (uint256 supplyBefore,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supplyBefore, 5);
        
        // Verify agent
        uint256 timestamp = block.timestamp;
        uint256 nonce = 99999;
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);
        
        vm.prank(agentWallet);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);
        
        // Agent should NOT have any claws (no free claw on verification)
        assertEq(claws.getBalance(FID1, agentWallet), 0);
        
        // Supply should remain unchanged
        (uint256 supplyAfter,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supplyAfter, 5);
    }
    
    function test_VerifyRevertsExpiredSignature() public {
        claws.createMarket(FID1, HANDLE);
        
        uint256 timestamp = block.timestamp;
        uint256 nonce = 12345;
        
        bytes memory signature = _signVerification(FID1, agentWallet, timestamp, nonce);
        
        // Warp forward 2 hours (past the 1-hour expiry)
        vm.warp(block.timestamp + 7200);
        
        vm.prank(agentWallet);
        vm.expectRevert(Claws.SignatureExpired.selector);
        claws.verifyAndClaim(FID1, agentWallet, timestamp, nonce, signature);
    }
    
    // ============ Whitelist Tier System ============

    function test_SetWhitelisted() public {
        // Owner can whitelist
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        assertTrue(claws.isWhitelisted(FID1));
        assertTrue(claws.whitelisted(FID1));

        // Owner can unwhitelist
        vm.prank(owner);
        claws.setWhitelisted(FID1, false);

        assertFalse(claws.isWhitelisted(FID1));
    }

    function test_SetWhitelistedRevertsNotOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        claws.setWhitelisted(FID1, true);
    }

    function test_SetWhitelistedBatch() public {
        uint256[] memory fids = new uint256[](3);
        fids[0] = FID1;
        fids[1] = FID2;
        fids[2] = 99999;

        vm.prank(owner);
        claws.setWhitelistedBatch(fids, true);

        assertTrue(claws.isWhitelisted(FID1));
        assertTrue(claws.isWhitelisted(FID2));
        assertTrue(claws.isWhitelisted(99999));
    }

    function test_SetWhitelistedBatchRevertsNotOwner() public {
        uint256[] memory fids = new uint256[](2);
        fids[0] = FID1;
        fids[1] = FID2;

        vm.prank(trader1);
        vm.expectRevert();
        claws.setWhitelistedBatch(fids, true);
    }

    function test_IsWhitelisted() public {
        assertFalse(claws.isWhitelisted(FID1));

        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        assertTrue(claws.isWhitelisted(FID1));
    }

    function test_WhitelistedFirstBuyGetsBonusClaw() public {
        // Whitelist the handle
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // For whitelisted first buy: price is calculated from supply 1
        // Price for 1 claw from supply 1 = 1^2/48000 = 0.000020833333333333 ETH
        // Buy 1 on whitelisted: first claw is free
        vm.prank(trader1);
        claws.buyClaws{value: 0}(FID1, 1, 0);

        // Should have 1 claw (the free supply=0 claw)
        assertEq(claws.getBalance(FID1, trader1), 1);

        (uint256 supply,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supply, 1);
    }

    function test_WhitelistedFirstBuyMultipleGetsBonusClaw() public {
        // Whitelist the handle
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // Buy 3 claws: first is free, pay for 2 priced from supply 1-2
        // Price = sum of i^2 from 1 to 2 = 1 + 4 = 5
        // Price in ETH = 5 / 48000 = 0.000104166666666666 ETH
        uint256 price = 0.0003125 ether;
        uint256 protocolFee = price * 500 / 10000;
        uint256 agentFee = price * 500 / 10000;
        uint256 totalCost = price + protocolFee + agentFee;

        vm.prank(trader1);
        claws.buyClaws{value: totalCost}(FID1, 3, 0);

        // Should have 3 claws
        assertEq(claws.getBalance(FID1, trader1), 3);

        (uint256 supply,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supply, 3);
    }

    function test_NonWhitelistedFirstBuyOneClawReverts() public {
        // Not whitelisted
        assertFalse(claws.isWhitelisted(FID1));

        // First buy of 1 claw should revert (must buy >= 2)
        vm.prank(trader1);
        vm.expectRevert(Claws.InvalidAmount.selector);
        claws.buyClaws{value: 1 ether}(FID1, 1, 0);
    }

    function test_NonWhitelistedFirstBuyTwoClawsWorks() public {
        // Not whitelisted
        assertFalse(claws.isWhitelisted(FID1));

        // First buy of 2 claws: first is free, pay for 1 (supply 1)
        (,,, uint256 totalCost) = claws.getBuyCostBreakdown(FID1, 2);

        vm.prank(trader1);
        claws.buyClaws{value: totalCost}(FID1, 2, 0);

        // Should have exactly 2 claws
        assertEq(claws.getBalance(FID1, trader1), 2);

        // Supply should be 2
        (uint256 supply,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supply, 2);
    }

    function test_NonWhitelistedFirstBuyFiveClawsWorks() public {
        // Not whitelisted
        assertFalse(claws.isWhitelisted(FID1));

        // First buy of 5 claws should work
        (,,, uint256 totalCost) = claws.getBuyCostBreakdown(FID1, 5);

        vm.prank(trader1);
        claws.buyClaws{value: totalCost}(FID1, 5, 0);

        // Should have exactly 5 claws (no bonus)
        assertEq(claws.getBalance(FID1, trader1), 5);
    }

    function test_AfterFirstBuyBothTiersBehaveIdentically() public {
        // Whitelist HANDLE, not HANDLE2
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // First buy on whitelisted market: buy 2 (first free, pay for 1)
        (,,, uint256 whitelistedCost) = claws.getBuyCostBreakdown(FID1, 2);
        vm.prank(trader1);
        claws.buyClaws{value: whitelistedCost}(FID1, 2, 0);
        assertEq(claws.getBalance(FID1, trader1), 2); // bought 2

        // First buy on non-whitelisted market (min 2, first free)
        (,,, uint256 nonWhitelistedCost) = claws.getBuyCostBreakdown(FID2, 2);
        vm.prank(trader2);
        claws.buyClaws{value: nonWhitelistedCost}(FID2, 2, 0);
        assertEq(claws.getBalance(FID2, trader2), 2);

        // Now both markets have supply 2
        // Buying more should behave the same

        // Buy 3 more on whitelisted market
        (uint256 wPriceBefore,,,) = claws.getBuyCostBreakdown(FID1, 3);
        (,,, uint256 wCost) = claws.getBuyCostBreakdown(FID1, 3);
        vm.prank(trader1);
        claws.buyClaws{value: wCost}(FID1, 3, 0);

        // Buy 3 more on non-whitelisted market
        (uint256 nwPriceBefore,,,) = claws.getBuyCostBreakdown(FID2, 3);
        (,,, uint256 nwCost) = claws.getBuyCostBreakdown(FID2, 3);
        vm.prank(trader2);
        claws.buyClaws{value: nwCost}(FID2, 3, 0);

        // Prices should be the same (supply is 2 in both markets, buying 3)
        assertEq(wPriceBefore, nwPriceBefore);

        assertEq(claws.getBalance(FID1, trader1), 5); // 2 + 3
        assertEq(claws.getBalance(FID2, trader2), 5); // 2 + 3
    }

    function test_WhitelistCanBeToggled() public {
        // Whitelist then unwhitelist
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);
        assertTrue(claws.isWhitelisted(FID1));

        vm.prank(owner);
        claws.setWhitelisted(FID1, false);
        assertFalse(claws.isWhitelisted(FID1));

        // Can whitelist again
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);
        assertTrue(claws.isWhitelisted(FID1));
    }

    function test_WhitelistRemovedDoesNotAffectExistingMarkets() public {
        // Whitelist and create market
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // Buy 1 claw (free on whitelisted)
        vm.prank(trader1);
        claws.buyClaws{value: 0}(FID1, 1, 0);

        // Unwhitelist
        vm.prank(owner);
        claws.setWhitelisted(FID1, false);

        // Existing supply and balances unchanged
        (uint256 supply,,,,,,,,) = claws.getMarket(FID1);
        assertEq(supply, 1);
        assertEq(claws.getBalance(FID1, trader1), 1);

        // New purchases should work normally (no first buy restriction since supply > 0)
        (,,, uint256 cost2) = claws.getBuyCostBreakdown(FID1, 1);
        vm.prank(trader2);
        claws.buyClaws{value: cost2}(FID1, 1, 0);
        assertEq(claws.getBalance(FID1, trader2), 1);
    }

    function test_WhitelistPriceIsCorrect() public {
        // Price for whitelisted first buy (1 claw) — first claw is free
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        uint256 price = claws.getBuyPriceByFid(FID1, 1);
        assertEq(price, 0); // 1 claw at supply=0 is free

        // Buying 2: first free, pay for 1 at supply 1
        uint256 price2 = claws.getBuyPriceByFid(FID1, 2);
        assertEq(price2, 0.000020833333333333 ether); // 1^2 / 48000

        // Current price still 0 (market doesn't exist yet, supply=0)
        uint256 currentPrice = claws.getCurrentPrice(FID1);
        assertEq(currentPrice, 0);
    }

    function test_NonWhitelistedPriceIsCorrect() public {
        // Price for non-whitelisted buying 2 claws: first free, pay for 1 at supply 1
        // Price = 1^2 / 48000 = 0.000020833333333333 ETH
        uint256 price = claws.getBuyPriceByFid(FID1, 2);
        assertEq(price, 0.000020833333333333 ether);
    }

    function test_PriceAfterFirstBuySameForBoth() public {
        // Set up whitelisted market — buy 2 (first free, pay for 1)
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);
        (,,, uint256 wCost1) = claws.getBuyCostBreakdown(FID1, 2);
        vm.prank(trader1);
        claws.buyClaws{value: wCost1}(FID1, 2, 0);

        // Set up non-whitelisted market — buy 2 (first free, pay for 1)
        (,,, uint256 nwCost1) = claws.getBuyCostBreakdown(FID2, 2);
        vm.prank(trader2);
        claws.buyClaws{value: nwCost1}(FID2, 2, 0);

        // Both markets now have supply 2
        // Price for buying 1 more claw should be identical
        uint256 wPrice = claws.getBuyPriceByFid(FID1, 1);
        uint256 nwPrice = claws.getBuyPriceByFid(FID2, 1);
        assertEq(wPrice, nwPrice);

        // Current price should also be identical
        uint256 wCurrent = claws.getCurrentPrice(FID1);
        uint256 nwCurrent = claws.getCurrentPrice(FID2);
        assertEq(wCurrent, nwCurrent);
    }

    function test_WhitelistedEventEmitted() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit WhitelistUpdated(FID1, true);
        claws.setWhitelisted(FID1, true);
    }

    function test_BatchWhitelistEventsEmitted() public {
        uint256[] memory fids = new uint256[](2);
        fids[0] = FID1;
        fids[1] = FID2;

        vm.prank(owner);
        // Expect 2 events to be emitted
        vm.expectEmit(true, false, false, true);
        emit WhitelistUpdated(FID1, true);
        vm.expectEmit(true, false, false, true);
        emit WhitelistUpdated(FID2, true);

        claws.setWhitelistedBatch(fids, true);
    }

    function test_FirstClawIsFreeForWhitelisted() public {
        // Whitelist the handle
        vm.prank(owner);
        claws.setWhitelisted(FID1, true);

        // getBuyCostBreakdown for 1 claw on whitelisted = free (supply=0 claw)
        (uint256 price,,, uint256 totalCost) = claws.getBuyCostBreakdown(FID1, 1);
        assertEq(price, 0);
        assertEq(totalCost, 0);

        // Can buy for free — frontend sends 0 ETH
        vm.prank(trader1);
        claws.buyClaws{value: 0}(FID1, 1, 0);

        assertEq(claws.getBalance(FID1, trader1), 1); // 1 free claw
    }

    function test_FirstClawNotFreeForNonWhitelisted() public {
        // Not whitelisted
        assertFalse(claws.isWhitelisted(FID1));

        // First claw is NOT free - can't buy just 1
        vm.prank(trader1);
        vm.expectRevert(Claws.InvalidAmount.selector);
        claws.buyClaws{value: 0}(FID1, 1, 0);

        // Must buy at least 2
        (uint256 price,,,) = claws.getBuyCostBreakdown(FID1, 2);
        assertGt(price, 0);
    }

    // ============ Adjustable Fee Tests ============

    function test_SetProtocolFeeBps() public {
        // Owner can set protocol fee
        vm.prank(owner);
        claws.setProtocolFeeBps(300); // 3%

        assertEq(claws.protocolFeeBps(), 300);
    }

    function test_SetProtocolFeeBpsEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Claws.ProtocolFeeUpdated(500, 300);
        claws.setProtocolFeeBps(300);
    }

    function test_SetProtocolFeeBpsRevertsNotOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        claws.setProtocolFeeBps(300);
    }

    function test_SetProtocolFeeBpsRevertsAboveMax() public {
        // 1001 bps > 1000 max
        vm.prank(owner);
        vm.expectRevert(Claws.InvalidAmount.selector);
        claws.setProtocolFeeBps(1001);
    }

    function test_SetProtocolFeeBpsMaxBoundary() public {
        // 1000 bps is exactly at max (10%)
        vm.prank(owner);
        claws.setProtocolFeeBps(1000);
        assertEq(claws.protocolFeeBps(), 1000);
    }

    function test_SetProtocolFeeBpsZeroAllowed() public {
        // 0 bps is allowed (no fee)
        vm.prank(owner);
        claws.setProtocolFeeBps(0);
        assertEq(claws.protocolFeeBps(), 0);
    }

    function test_SetAgentFeeBps() public {
        // Owner can set agent fee
        vm.prank(owner);
        claws.setAgentFeeBps(200); // 2%

        assertEq(claws.agentFeeBps(), 200);
    }

    function test_SetAgentFeeBpsEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Claws.AgentFeeUpdated(500, 200);
        claws.setAgentFeeBps(200);
    }

    function test_SetAgentFeeBpsRevertsNotOwner() public {
        vm.prank(trader1);
        vm.expectRevert();
        claws.setAgentFeeBps(200);
    }

    function test_SetAgentFeeBpsRevertsAboveMax() public {
        // 1001 bps > 1000 max
        vm.prank(owner);
        vm.expectRevert(Claws.InvalidAmount.selector);
        claws.setAgentFeeBps(1001);
    }

    function test_SetAgentFeeBpsMaxBoundary() public {
        // 1000 bps is exactly at max (10%)
        vm.prank(owner);
        claws.setAgentFeeBps(1000);
        assertEq(claws.agentFeeBps(), 1000);
    }

    function test_SetAgentFeeBpsZeroAllowed() public {
        // 0 bps is allowed (no fee)
        vm.prank(owner);
        claws.setAgentFeeBps(0);
        assertEq(claws.agentFeeBps(), 0);
    }

    function test_ProtocolFeeAppliedCorrectlyAfterChange() public {
        // Change protocol fee to 3%
        vm.prank(owner);
        claws.setProtocolFeeBps(300);

        // Buy claws and verify fee is 3%
        uint256 price = claws.getBuyPriceByFid(FID1, 5);
        (,,, uint256 totalCost) = claws.getBuyCostBreakdown(FID1, 5);

        // Expected: price + 3% protocol fee + 5% agent fee (unchanged)
        uint256 expectedProtocolFee = (price * 300) / 10000;
        uint256 expectedAgentFee = (price * 500) / 10000;
        uint256 expectedTotal = price + expectedProtocolFee + expectedAgentFee;

        assertEq(totalCost, expectedTotal);

        // Execute the trade and verify
        uint256 treasuryBefore = treasury.balance;

        vm.prank(trader1);
        claws.buyClaws{value: totalCost}(FID1, 5, 0);

        // Treasury should receive 3% of price
        assertEq(treasury.balance - treasuryBefore, expectedProtocolFee);
    }

    function test_AgentFeeAppliedCorrectlyAfterChange() public {
        // Change agent fee to 2%
        vm.prank(owner);
        claws.setAgentFeeBps(200);

        // Buy claws and verify fee is 2%
        uint256 price = claws.getBuyPriceByFid(FID1, 5);
        (,,, uint256 totalCost) = claws.getBuyCostBreakdown(FID1, 5);

        // Expected: price + 5% protocol fee (unchanged) + 2% agent fee
        uint256 expectedProtocolFee = (price * 500) / 10000;
        uint256 expectedAgentFee = (price * 200) / 10000;
        uint256 expectedTotal = price + expectedProtocolFee + expectedAgentFee;

        assertEq(totalCost, expectedTotal);

        // Execute the trade and verify
        vm.prank(trader1);
        claws.buyClaws{value: totalCost}(FID1, 5, 0);

        (, uint256 pendingFees,,,,,,,) = claws.getMarket(FID1);

        // Pending fees should be 2% of price
        assertEq(pendingFees, expectedAgentFee);
    }

    function test_BothFeesChangedAppliedCorrectly() public {
        // Change both fees
        vm.prank(owner);
        claws.setProtocolFeeBps(1000); // 10%
        vm.prank(owner);
        claws.setAgentFeeBps(1000); // 10%

        uint256 price = claws.getBuyPriceByFid(FID1, 5);
        (uint256 breakdownPrice, uint256 protocolFee, uint256 agentFee, uint256 totalCost) =
            claws.getBuyCostBreakdown(FID1, 5);

        // Verify breakdown
        assertEq(breakdownPrice, price);
        assertEq(protocolFee, (price * 1000) / 10000);
        assertEq(agentFee, (price * 1000) / 10000);
        assertEq(totalCost, price + protocolFee + agentFee);
    }

    function test_SellFeesAppliedCorrectlyAfterChange() public {
        // First buy some claws with default fees
        (,,, uint256 buyCost) = claws.getBuyCostBreakdown(FID1, 5);
        vm.prank(trader1);
        claws.buyClaws{value: buyCost}(FID1, 5, 0);

        // Change fees
        vm.prank(owner);
        claws.setProtocolFeeBps(300); // 3%
        vm.prank(owner);
        claws.setAgentFeeBps(200); // 2%

        // Now sell and verify new fees are applied
        uint256 sellPrice = claws.getSellPriceByFid(FID1, 2);
        (uint256 price, uint256 protocolFee, uint256 agentFee, uint256 proceeds) =
            claws.getSellProceedsBreakdown(FID1, 2);

        // Verify breakdown uses new fees
        assertEq(price, sellPrice);
        assertEq(protocolFee, (sellPrice * 300) / 10000);
        assertEq(agentFee, (sellPrice * 200) / 10000);
        assertEq(proceeds, sellPrice - protocolFee - agentFee);

        // Execute the sale and verify
        uint256 treasuryBefore = treasury.balance;
        uint256 traderBefore = trader1.balance;

        vm.prank(trader1);
        claws.sellClaws(FID1, 2, 0);

        // Treasury should receive 3% of sell price
        assertEq(treasury.balance - treasuryBefore, (sellPrice * 300) / 10000);
        // Trader should receive sell price minus fees
        assertEq(trader1.balance - traderBefore, proceeds);
    }

    // ============ Two-Step Ownership Transfer Tests ============

    function test_TransferOwnership() public {
        address newOwner = address(99);

        // Owner initiates transfer
        vm.prank(owner);
        claws.transferOwnership(newOwner);

        assertEq(claws.pendingOwner(), newOwner);
        // Owner hasn't changed yet
        assertEq(claws.owner(), owner);
    }

    function test_TransferOwnershipRevertsNotOwner() public {
        address newOwner = address(99);

        vm.prank(trader1);
        vm.expectRevert();
        claws.transferOwnership(newOwner);
    }

    function test_TransferOwnershipRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Claws.ZeroAddress.selector);
        claws.transferOwnership(address(0));
    }

    function test_AcceptOwnership() public {
        address newOwner = address(99);
        vm.deal(newOwner, 1 ether);

        // Owner initiates transfer
        vm.prank(owner);
        claws.transferOwnership(newOwner);

        // New owner accepts
        vm.prank(newOwner);
        claws.acceptOwnership();

        // Ownership should be transferred
        assertEq(claws.owner(), newOwner);
        assertEq(claws.pendingOwner(), address(0));
    }

    function test_AcceptOwnershipEmitsEvent() public {
        address newOwner = address(99);
        vm.deal(newOwner, 1 ether);

        vm.prank(owner);
        claws.transferOwnership(newOwner);

        // Expect OpenZeppelin's OwnershipTransferred event
        vm.prank(newOwner);
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);
        claws.acceptOwnership();
    }

    function test_AcceptOwnershipRevertsNotPendingOwner() public {
        address newOwner = address(99);

        vm.prank(owner);
        claws.transferOwnership(newOwner);

        // Random address tries to accept
        vm.prank(trader1);
        vm.expectRevert(Claws.NotPendingOwner.selector);
        claws.acceptOwnership();
    }

    function test_AcceptOwnershipRevertsOwner() public {
        address newOwner = address(99);

        vm.prank(owner);
        claws.transferOwnership(newOwner);

        // Current owner tries to accept (should fail)
        vm.prank(owner);
        vm.expectRevert(Claws.NotPendingOwner.selector);
        claws.acceptOwnership();
    }

    function test_NewOwnerCanUseOwnerFunctions() public {
        address newOwner = address(99);
        vm.deal(newOwner, 1 ether);

        // Transfer ownership
        vm.prank(owner);
        claws.transferOwnership(newOwner);

        vm.prank(newOwner);
        claws.acceptOwnership();

        // New owner can set fees
        vm.prank(newOwner);
        claws.setProtocolFeeBps(300);

        assertEq(claws.protocolFeeBps(), 300);
    }

    function test_OldOwnerCannotUseOwnerFunctionsAfterTransfer() public {
        address newOwner = address(99);
        vm.deal(newOwner, 1 ether);

        // Transfer ownership
        vm.prank(owner);
        claws.transferOwnership(newOwner);

        vm.prank(newOwner);
        claws.acceptOwnership();

        // Old owner can no longer set fees
        vm.prank(owner);
        vm.expectRevert();
        claws.setProtocolFeeBps(300);
    }

    function test_TransferOwnershipCanBeChanged() public {
        address newOwner1 = address(99);
        address newOwner2 = address(98);

        // Owner sets pending owner 1
        vm.prank(owner);
        claws.transferOwnership(newOwner1);
        assertEq(claws.pendingOwner(), newOwner1);

        // Owner changes to pending owner 2
        vm.prank(owner);
        claws.transferOwnership(newOwner2);
        assertEq(claws.pendingOwner(), newOwner2);

        // First pending owner cannot accept
        vm.prank(newOwner1);
        vm.expectRevert(Claws.NotPendingOwner.selector);
        claws.acceptOwnership();

        // Second pending owner can accept
        vm.prank(newOwner2);
        claws.acceptOwnership();
        assertEq(claws.owner(), newOwner2);
    }

    function test_TransferOwnershipToSameAddress() public {
        // Owner can set themselves as pending owner (though pointless)
        vm.prank(owner);
        claws.transferOwnership(owner);

        assertEq(claws.pendingOwner(), owner);

        // Owner accepts (no change)
        vm.prank(owner);
        claws.acceptOwnership();

        assertEq(claws.owner(), owner);
    }

    function test_CancelOwnershipTransfer() public {
        address newOwner = address(99);

        // Owner initiates transfer
        vm.prank(owner);
        claws.transferOwnership(newOwner);
        assertEq(claws.pendingOwner(), newOwner);

        // Owner "cancels" by setting pending owner to address(0) (will revert)
        vm.prank(owner);
        vm.expectRevert(Claws.ZeroAddress.selector);
        claws.transferOwnership(address(0));

        // Or owner can transfer to themselves to effectively cancel
        vm.prank(owner);
        claws.transferOwnership(owner);

        // Now newOwner cannot accept
        vm.prank(newOwner);
        vm.expectRevert(Claws.NotPendingOwner.selector);
        claws.acceptOwnership();
    }
}
