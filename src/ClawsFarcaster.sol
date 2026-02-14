// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title ClawsFarcaster
 * @notice Bonding curve speculation market for Farcaster accounts
 * @dev FID-based markets using bonding curve pricing with verification
 *
 * Formula: price = supply² / 48000 ETH (Claws bonding curve — flattened 3x)
 * - 1st claw: FREE for whitelisted FIDs only (bonus claw on first buy)
 * - Non-whitelisted: no free claw, minimum 2 claws on first buy
 * - 10th claw: ~0.002 ETH (~$5)
 * - 50th claw: ~0.052 ETH (~$130)
 * - 100th claw: ~0.208 ETH (~$520)
 * - Flatter curve keeps markets accessible longer, drives sustained volume
 *
 * WHOLE CLAWS ONLY: Minimum 1 claw per trade. No fractional purchases.
 *
 * VERIFIED AGENTS: Earn 5% of all trade fees. No free claws on verification.
 * 
 * FARCASTER SPECIFIC: Markets are keyed by FID (Farcaster ID) for on-chain
 * Farcaster identity association. Username is stored as display metadata.
 */
contract ClawsFarcaster is ReentrancyGuard, Ownable, Pausable, EIP712 {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============
    
    /// @notice Contract version
    string public constant VERSION = "2.0.0";
    
    /// @notice Maximum fee: 10% (1000 basis points)
    uint256 public constant MAX_FEE_BPS = 1000;
    
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // ============ Fee State ============
    
    /// @notice Protocol fee: 5% (500 basis points) initially
    uint256 public protocolFeeBps = 500;
    
    /// @notice Agent fee: 5% (500 basis points) initially
    uint256 public agentFeeBps = 500;
    
    /// @notice Price curve divisor (bonding curve formula)
    /// Formula: price = supply² / PRICE_DIVISOR
    uint256 public constant PRICE_DIVISOR = 48000;
    
    /// @notice EIP-712 typehash for verification signatures
    /// @dev Field order: fid, wallet, timestamp, nonce — matches abi.encode in verifyAndClaim
    bytes32 public constant VERIFY_TYPEHASH = keccak256(
        "Verify(uint256 fid,address wallet,uint256 timestamp,uint256 nonce)"
    );
    
    // ============ State ============
    
    /// @notice Market data for each FID
    struct Market {
        uint256 supply;           // Total claws in circulation
        uint256 pendingFees;      // Unclaimed agent fees (ETH)
        uint256 lifetimeFees;     // Total fees earned (ETH)
        uint256 lifetimeVolume;   // Total trade volume (ETH)
        address verifiedWallet;   // Bound wallet (zero until verified)
        bool isVerified;          // Whether agent has verified
        uint256 createdAt;        // Block timestamp of market creation
    }

    /// @notice Agent metadata for verified FIDs
    struct AgentMetadata {
        string bio;         // Short description (max 280 chars)
        string website;     // URL
        address token;      // Token contract address (address(0) if none)
    }
    
    /// @notice Markets indexed by FID (uint256)
    mapping(uint256 => Market) public markets;
    
    /// @notice Claw balances: fid => holder => balance
    mapping(uint256 => mapping(address => uint256)) public clawsBalance;
    
    /// @notice Username storage by FID (for frontend display)
    mapping(uint256 => string) public fidUsernames;
    
    /// @notice Trusted verifier address (signs verification proofs)
    address public verifier;
    
    /// @notice Protocol treasury
    address public treasury;
    
    /// @notice Used nonces for verification (prevent replay)
    mapping(bytes32 => bool) public usedNonces;
    
    /// @notice Whitelisted FIDs that get free first claw (tier system)
    mapping(uint256 => bool) public whitelisted;

    /// @notice Agent metadata by FID (only for verified agents)
    mapping(uint256 => AgentMetadata) public agentMetadata;
    
    /// @notice Pending owner for two-step ownership transfer
    address public pendingOwner;
    
    // ============ Events ============
    
    event MarketCreated(uint256 indexed fid, string username, address creator);
    event Trade(
        uint256 indexed fid,
        address indexed trader,
        bool isBuy,
        uint256 amount,
        uint256 price,
        uint256 protocolFee,
        uint256 agentFee,
        uint256 newSupply
    );
    event AgentVerified(uint256 indexed fid, address wallet);
    event FeesClaimed(uint256 indexed fid, address wallet, uint256 amount);
    event VerifierUpdated(address oldVerifier, address newVerifier);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event AgentWalletUpdated(uint256 indexed fid, address oldWallet, address newWallet);
    event VerificationRevoked(uint256 indexed fid);
    event WhitelistUpdated(uint256 indexed fid, bool status);
    event MetadataUpdated(uint256 indexed fid);
    event ProtocolFeeUpdated(uint256 oldBps, uint256 newBps);
    event AgentFeeUpdated(uint256 oldBps, uint256 newBps);
    event UsernameUpdated(uint256 indexed fid, string oldUsername, string newUsername);
    
    // ============ Errors ============
    
    error MarketAlreadyExists();
    error MarketDoesNotExist();
    error InvalidAmount();
    error InsufficientBalance();
    error InsufficientPayment();
    error SlippageExceeded();
    error AlreadyVerified();
    error InvalidSignature();
    error NonceAlreadyUsed();
    error NotVerified();
    error NotVerifiedAgent();
    error NoFeesPending();
    error TransferFailed();
    error ZeroAddress();
    error CannotSellLastClaw();
    error MarketNotVerified();
    error AlreadyRevoked();
    error SignatureExpired();
    error BioTooLong();
    error NotPendingOwner();
    error InvalidUsername();
    error NotVerifiedWallet();
    
    // ============ Constructor ============

    constructor(
        address _verifier,
        address _treasury
    ) Ownable(msg.sender) EIP712("ClawsFarcaster", "2") {
        if (_verifier == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        verifier = _verifier;
        treasury = _treasury;
    }
    
    // ============ Market Creation ============
    
    /**
     * @notice Create a market for a Farcaster user (permissionless)
     * @param fid The Farcaster ID
     * @param username The Farcaster username (for display)
     */
    function createMarket(uint256 fid, string calldata username) external {
        if (fid == 0) revert InvalidAmount();
        if (bytes(username).length == 0 || bytes(username).length > 32) revert InvalidUsername();
        
        if (markets[fid].createdAt != 0) {
            revert MarketAlreadyExists();
        }
        
        markets[fid] = Market({
            supply: 0,
            pendingFees: 0,
            lifetimeFees: 0,
            lifetimeVolume: 0,
            verifiedWallet: address(0),
            isVerified: false,
            createdAt: block.timestamp
        });
        
        fidUsernames[fid] = username;
        
        emit MarketCreated(fid, username, msg.sender);
    }
    
    // ============ Trading ============
    
    /**
     * @notice Buy claws for a FID
     * @param fid The Farcaster ID
     * @param amount Number of whole claws to buy (minimum 1, no fractions)
     * @param maxTotalCost Maximum total cost willing to pay (0 = no limit, for backwards compatibility)
     * @dev Whitelisted FIDs get 1 free claw on first buy (supply == 0).
     *      The free claw is minted at supply 0 (no ETH cost), then `amount` claws
     *      are priced from supply 1 onward, ensuring proper liquidity backing.
     * @dev Non-whitelisted FIDs must buy >= 2 claws on first buy
     */
    function buyClaws(uint256 fid, uint256 amount, uint256 maxTotalCost) external payable nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (fid == 0) revert InvalidAmount();

        Market storage market = markets[fid];

        // Auto-create market if doesn't exist (permissionless market creation)
        if (market.createdAt == 0) {
            market.createdAt = block.timestamp;
            emit MarketCreated(fid, "", msg.sender);
        }

        // First buy logic: supply=0 claw is always free
        if (market.supply == 0) {
            if (!whitelisted[fid]) {
                // Community: must buy at least 2 (free claw + 1 paid)
                if (amount < 2) revert InvalidAmount();
            }
            // Whitelisted: min 1 (can grab just the free claw)
        }

        // Price calculation: first claw (supply=0) is free, charge for remainder from supply 1
        uint256 price;
        if (market.supply == 0) {
            // Buying `amount` claws starting from empty market
            // First claw is free, pay for (amount - 1) claws priced from supply 1
            price = (amount > 1) ? _getPrice(1, amount - 1) : 0;
        } else {
            price = getBuyPrice(fid, amount);
        }
        uint256 protocolFee = (price * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 agentFee = (price * agentFeeBps) / BPS_DENOMINATOR;
        uint256 totalCost = price + protocolFee + agentFee;

        // Slippage protection: if maxTotalCost is 0, treat as "no limit" (backwards compatibility)
        if (maxTotalCost != 0 && totalCost > maxTotalCost) revert SlippageExceeded();

        if (msg.value < totalCost) revert InsufficientPayment();

        // Send protocol fee to treasury
        (bool sent,) = treasury.call{value: protocolFee}("");
        if (!sent) revert TransferFailed();

        // Accumulate agent fee (claimable after verification)
        market.pendingFees += agentFee;
        market.lifetimeFees += agentFee;
        market.lifetimeVolume += price;

        // Update balances
        market.supply += amount;
        clawsBalance[fid][msg.sender] += amount;

        // Refund excess ETH
        if (msg.value > totalCost) {
            (bool refunded,) = msg.sender.call{value: msg.value - totalCost}("");
            if (!refunded) revert TransferFailed();
        }

        emit Trade(fid, msg.sender, true, amount, price, protocolFee, agentFee, market.supply);
    }
    
    /**
     * @notice Sell claws for a FID
     * @param fid The Farcaster ID
     * @param amount Number of whole claws to sell (minimum 1, no fractions)
     * @param minProceeds Minimum ETH to receive (slippage protection)
     */
    function sellClaws(
        uint256 fid,
        uint256 amount,
        uint256 minProceeds
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (fid == 0) revert InvalidAmount();
        
        Market storage market = markets[fid];
        
        if (market.createdAt == 0) revert MarketDoesNotExist();
        if (clawsBalance[fid][msg.sender] < amount) revert InsufficientBalance();
        
        // Cannot sell if it would leave supply at 0 (market integrity)
        if (market.supply == amount) revert CannotSellLastClaw();
        
        uint256 price = getSellPrice(fid, amount);
        uint256 protocolFee = (price * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 agentFee = (price * agentFeeBps) / BPS_DENOMINATOR;
        uint256 proceeds = price - protocolFee - agentFee;
        
        if (proceeds < minProceeds) revert SlippageExceeded();
        
        // Update balances first (CEI pattern)
        market.supply -= amount;
        clawsBalance[fid][msg.sender] -= amount;
        
        // Accumulate fees
        market.pendingFees += agentFee;
        market.lifetimeFees += agentFee;
        market.lifetimeVolume += price;
        
        // Transfer fees and proceeds
        (bool feeSent, ) = treasury.call{value: protocolFee}("");
        if (!feeSent) revert TransferFailed();
        
        (bool proceedsSent, ) = msg.sender.call{value: proceeds}("");
        if (!proceedsSent) revert TransferFailed();
        
        emit Trade(
            fid,
            msg.sender,
            false,
            amount,
            price,
            protocolFee,
            agentFee,
            market.supply
        );
    }
    
    // ============ Verification ============
    
    /**
     * @notice Verify ownership and bind wallet to FID
     * @param fid The Farcaster ID being verified
     * @param wallet The wallet to bind
     * @param timestamp Signature timestamp
     * @param nonce Unique nonce to prevent replay
     * @param signature Verifier's EIP-712 signature
     * @dev Backend /api/verify/complete must sign with EIP-712: 
     *      structHash = keccak256(abi.encode(VERIFY_TYPEHASH, fid, wallet, timestamp, nonce))
     *      finalHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash))
     */
    function verifyAndClaim(
        uint256 fid,
        address wallet,
        uint256 timestamp,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant {
        if (fid == 0) revert InvalidAmount();
        
        Market storage market = markets[fid];

        if (market.createdAt == 0) revert MarketDoesNotExist();
        if (market.isVerified) revert AlreadyVerified();

        // Signature must be less than 1 hour old
        if (block.timestamp > timestamp + 3600) revert SignatureExpired();

        // Construct EIP-712 digest (domain-bound to prevent cross-chain replay)
        bytes32 structHash = keccak256(abi.encode(VERIFY_TYPEHASH, fid, wallet, timestamp, nonce));
        bytes32 digest = _hashTypedDataV4(structHash);

        if (usedNonces[digest]) revert NonceAlreadyUsed();

        if (digest.recover(signature) != verifier) {
            revert InvalidSignature();
        }

        // Mark nonce as used
        usedNonces[digest] = true;
        
        // Bind wallet and mark verified
        market.verifiedWallet = wallet;
        market.isVerified = true;
        
        emit AgentVerified(fid, wallet);
        
        // Auto-claim any pending fees
        if (market.pendingFees > 0) {
            uint256 fees = market.pendingFees;
            market.pendingFees = 0;
            (bool sent, ) = wallet.call{value: fees}("");
            if (!sent) revert TransferFailed();
            emit FeesClaimed(fid, wallet, fees);
        }
    }
    
    /**
     * @notice Claim accumulated fees (verified agents only)
     * @param fid The Farcaster ID
     */
    function claimFees(uint256 fid) external nonReentrant {
        if (fid == 0) revert InvalidAmount();
        
        Market storage market = markets[fid];
        
        if (!market.isVerified) revert NotVerified();
        if (msg.sender != market.verifiedWallet) revert NotVerified();
        if (market.pendingFees == 0) revert NoFeesPending();
        
        uint256 fees = market.pendingFees;
        market.pendingFees = 0;
        
        (bool sent, ) = msg.sender.call{value: fees}("");
        if (!sent) revert TransferFailed();
        
        emit FeesClaimed(fid, msg.sender, fees);
    }

    // ============ Username Updates ============

    /**
     * @notice Update username for a verified FID
     * @param fid The Farcaster ID
     * @param newUsername The new username
     * @dev Only callable by the verified wallet. Handles FC username changes.
     */
    function updateUsername(uint256 fid, string calldata newUsername) external {
        if (fid == 0) revert InvalidAmount();
        if (bytes(newUsername).length == 0 || bytes(newUsername).length > 32) revert InvalidUsername();
        
        Market storage market = markets[fid];
        
        if (!market.isVerified) revert NotVerified();
        if (msg.sender != market.verifiedWallet) revert NotVerifiedWallet();
        
        string memory oldUsername = fidUsernames[fid];
        fidUsernames[fid] = newUsername;
        
        emit UsernameUpdated(fid, oldUsername, newUsername);
    }

    // ============ Agent Metadata ============

    /**
     * @notice Set metadata for a verified agent
     * @param fid The Farcaster ID
     * @param bio Short description (max 280 characters)
     * @param website URL for the agent's website
     * @param token Token contract address (address(0) if none)
     * @dev Only callable by the verified wallet for that FID
     */
    function setAgentMetadata(
        uint256 fid,
        string calldata bio,
        string calldata website,
        address token
    ) external {
        if (fid == 0) revert InvalidAmount();
        
        Market storage market = markets[fid];

        // Only verified wallet can set metadata
        if (!market.isVerified || msg.sender != market.verifiedWallet) {
            revert NotVerified();
        }

        // Validate bio length (max 280 chars like a tweet)
        if (bytes(bio).length > 280) {
            revert BioTooLong();
        }

        agentMetadata[fid] = AgentMetadata({
            bio: bio,
            website: website,
            token: token
        });

        emit MetadataUpdated(fid);
    }

    /**
     * @notice Get metadata for an agent
     * @param fid The Farcaster ID
     * @return bio Short description
     * @return website URL
     * @return token Token contract address
     */
    function getAgentMetadata(uint256 fid) external view returns (
        string memory bio,
        string memory website,
        address token
    ) {
        AgentMetadata storage metadata = agentMetadata[fid];
        return (metadata.bio, metadata.website, metadata.token);
    }

    // ============ EIP-712 ============

    /**
     * @notice Returns the EIP-712 domain separator for this contract
     */
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============ Price Calculations ============
    
    /**
     * @notice Get the price to buy `amount` claws
     * @param fid The Farcaster ID
     * @param amount Number of claws
     * @return Total price in ETH (wei)
     */
    function getBuyPrice(uint256 fid, uint256 amount) public view returns (uint256) {
        uint256 supply = markets[fid].supply;
        return _getPrice(supply, amount);
    }
    
    /**
     * @notice Get the price to buy `amount` claws (by FID)
     */
    function getBuyPriceByFid(uint256 fid, uint256 amount) external view returns (uint256) {
        Market storage market = markets[fid];
        // First claw (supply=0) is free for everyone
        if (market.supply == 0) {
            return (amount > 1) ? _getPrice(1, amount - 1) : 0;
        }
        return getBuyPrice(fid, amount);
    }
    
    /**
     * @notice Get the proceeds from selling `amount` claws
     * @param fid The Farcaster ID
     * @param amount Number of claws
     * @return Total proceeds in ETH (wei)
     */
    function getSellPrice(uint256 fid, uint256 amount) public view returns (uint256) {
        uint256 supply = markets[fid].supply;
        if (amount > supply) revert InsufficientBalance();
        return _getPrice(supply - amount, amount);
    }
    
    /**
     * @notice Get the proceeds from selling `amount` claws (by FID)
     */
    function getSellPriceByFid(uint256 fid, uint256 amount) external view returns (uint256) {
        return getSellPrice(fid, amount);
    }
    
    /**
     * @notice Calculate price using bonding curve (pure bonding curve math)
     * @dev Price = sum of squares from supply to supply+amount-1
     *      Sum of squares bonding curve: sum(n²) from supply to supply+amount-1
     *      No free claws - pure math only
     */
    function _getPrice(uint256 supply, uint256 amount) internal pure returns (uint256) {
        // bonding curve formula: sum squares from supply to (supply + amount - 1)
        // Using sum of squares: n(n+1)(2n+1)/6 for 1 to n

        // sum1 = sum of squares from 1 to (supply - 1), or 0 if supply is 0
        uint256 sum1 = supply == 0 ? 0 : (supply - 1) * supply * (2 * (supply - 1) + 1) / 6;

        // sum2 = sum of squares from 1 to (supply + amount - 1)
        uint256 sum2 =
            (supply + amount - 1) * (supply + amount) * (2 * (supply + amount - 1) + 1) / 6;

        uint256 summation = sum2 - sum1;

        // Convert to ETH
        return (summation * 1 ether) / PRICE_DIVISOR;
    }
    
    /**
     * @notice Get current price for 1 claw (next buy price)
     * @dev Price = supply² / PRICE_DIVISOR
     *      No special first claw pricing - bonding curve math only
     */
    function getCurrentPrice(uint256 fid) external view returns (uint256) {
        uint256 supply = markets[fid].supply;
        // Price of the next claw = supply² / PRICE_DIVISOR
        return (supply * supply * 1 ether) / PRICE_DIVISOR;
    }
    
    /**
     * @notice Get cost breakdown for buying
     */
    function getBuyCostBreakdown(
        uint256 fid,
        uint256 amount
    ) external view returns (
        uint256 price,
        uint256 protocolFee,
        uint256 agentFee,
        uint256 totalCost
    ) {
        Market storage market = markets[fid];

        // Mirror first-buy logic: supply=0 claw is free for everyone
        if (market.supply == 0) {
            price = (amount > 1) ? _getPrice(1, amount - 1) : 0;
        } else {
            price = getBuyPrice(fid, amount);
        }

        protocolFee = (price * protocolFeeBps) / BPS_DENOMINATOR;
        agentFee = (price * agentFeeBps) / BPS_DENOMINATOR;
        totalCost = price + protocolFee + agentFee;
    }
    
    /**
     * @notice Get proceeds breakdown for selling
     */
    function getSellProceedsBreakdown(
        uint256 fid,
        uint256 amount
    ) external view returns (
        uint256 price,
        uint256 protocolFee,
        uint256 agentFee,
        uint256 proceeds
    ) {
        price = getSellPrice(fid, amount);
        protocolFee = (price * protocolFeeBps) / BPS_DENOMINATOR;
        agentFee = (price * agentFeeBps) / BPS_DENOMINATOR;
        proceeds = price - protocolFee - agentFee;
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get market data for a FID
     * @return supply Total claws in circulation
     * @return pendingFees Unclaimed agent fees (ETH)
     * @return lifetimeFees Total fees earned (ETH)
     * @return lifetimeVolume Total trade volume (ETH)
     * @return verifiedWallet Bound wallet (zero until verified)
     * @return isVerified Whether agent has verified
     * @return createdAt Block timestamp of market creation
     * @return currentPrice Current price to buy 1 claw
     * @return username The stored username for display
     */
    function getMarket(uint256 fid) external view returns (
        uint256 supply,
        uint256 pendingFees,
        uint256 lifetimeFees,
        uint256 lifetimeVolume,
        address verifiedWallet,
        bool isVerified,
        uint256 createdAt,
        uint256 currentPrice,
        string memory username
    ) {
        Market storage market = markets[fid];
        
        supply = market.supply;
        pendingFees = market.pendingFees;
        lifetimeFees = market.lifetimeFees;
        lifetimeVolume = market.lifetimeVolume;
        verifiedWallet = market.verifiedWallet;
        isVerified = market.isVerified;
        createdAt = market.createdAt;
        username = fidUsernames[fid];
        
        // Current price to buy 1 claw
        currentPrice = (supply * supply * 1 ether) / PRICE_DIVISOR;
    }
    
    /**
     * @notice Get user's claw balance for a FID
     */
    function getBalance(uint256 fid, address user) external view returns (uint256) {
        return clawsBalance[fid][user];
    }
    
    /**
     * @notice Check if a market exists
     */
    function marketExists(uint256 fid) external view returns (bool) {
        return markets[fid].createdAt != 0;
    }
    
    // ============ Admin Functions ============
    
    function setVerifier(address _verifier) external onlyOwner {
        if (_verifier == address(0)) revert ZeroAddress();
        emit VerifierUpdated(verifier, _verifier);
        verifier = _verifier;
    }
    
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }
    
    /// @notice Emergency pause - stops all trading
    function pause() external onlyOwner {
        _pause();
    }
    
    /// @notice Resume trading after pause
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update the verified wallet for a market (owner only)
     * @param fid The Farcaster ID
     * @param newWallet The new wallet address to set
     */
    function updateAgentWallet(uint256 fid, address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert ZeroAddress();
        if (fid == 0) revert InvalidAmount();

        Market storage market = markets[fid];

        if (market.createdAt == 0) revert MarketDoesNotExist();
        if (!market.isVerified) revert MarketNotVerified();

        address oldWallet = market.verifiedWallet;
        market.verifiedWallet = newWallet;

        emit AgentWalletUpdated(fid, oldWallet, newWallet);
    }

    /**
     * @notice Self-service wallet update for verified agents
     * @dev Only callable by the currently verified wallet (msg.sender == verifiedWallet)
     * @dev Pure on-chain auth — no signatures, no backend, immune to social engineering
     * @param fid The Farcaster ID
     * @param newWallet The new wallet address to bind
     */
    function updateMyWallet(uint256 fid, address newWallet) external nonReentrant {
        if (newWallet == address(0)) revert ZeroAddress();
        if (fid == 0) revert InvalidAmount();

        Market storage market = markets[fid];

        if (market.createdAt == 0) revert MarketDoesNotExist();
        if (!market.isVerified) revert MarketNotVerified();
        if (msg.sender != market.verifiedWallet) revert NotVerifiedAgent();

        address oldWallet = market.verifiedWallet;
        market.verifiedWallet = newWallet;

        emit AgentWalletUpdated(fid, oldWallet, newWallet);
    }

    /**
     * @notice Revoke verification for a market (owner only)
     * @dev Sets isVerified to false and verifiedWallet to address(0)
     * @dev Pending fees remain frozen until re-verification
     * @param fid The Farcaster ID
     */
    function revokeVerification(uint256 fid) external onlyOwner {
        if (fid == 0) revert InvalidAmount();
        
        Market storage market = markets[fid];

        if (market.createdAt == 0) revert MarketDoesNotExist();
        if (!market.isVerified) revert MarketNotVerified();

        market.isVerified = false;
        market.verifiedWallet = address(0);

        emit VerificationRevoked(fid);
    }

    /**
     * @notice Set protocol fee in basis points (owner only)
     * @param newBps New fee in basis points (max 1000 = 10%)
     */
    function setProtocolFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert InvalidAmount();
        uint256 oldBps = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeUpdated(oldBps, newBps);
    }

    /**
     * @notice Set agent fee in basis points (owner only)
     * @param newBps New fee in basis points (max 1000 = 10%)
     */
    function setAgentFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert InvalidAmount();
        uint256 oldBps = agentFeeBps;
        agentFeeBps = newBps;
        emit AgentFeeUpdated(oldBps, newBps);
    }

    /**
     * @notice Initiate two-step ownership transfer (owner only)
     * @param newOwner Address of the pending owner
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    /**
     * @notice Accept ownership transfer (pending owner only)
     */
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        _transferOwnership(pendingOwner);
        pendingOwner = address(0);
    }

    // ============ Whitelist Functions ============

    /**
     * @notice Set whitelist status for a single FID (owner only)
     * @param fid The Farcaster ID to whitelist
     * @param status True to whitelist, false to remove
     * @dev Whitelisted FIDs get 1 bonus claw on first buy
     */
    function setWhitelisted(uint256 fid, bool status) external onlyOwner {
        if (fid == 0) revert InvalidAmount();
        whitelisted[fid] = status;
        emit WhitelistUpdated(fid, status);
    }

    /**
     * @notice Batch set whitelist status for multiple FIDs (owner only)
     * @param fids Array of Farcaster IDs to whitelist
     * @param status True to whitelist, false to remove
     */
    function setWhitelistedBatch(uint256[] calldata fids, bool status) external onlyOwner {
        for (uint256 i = 0; i < fids.length; i++) {
            uint256 fid = fids[i];
            if (fid == 0) continue; // Skip invalid FIDs
            whitelisted[fid] = status;
            emit WhitelistUpdated(fid, status);
        }
    }

    /**
     * @notice Check if a FID is whitelisted
     * @param fid The Farcaster ID to check
     * @return True if whitelisted
     */
    function isWhitelisted(uint256 fid) external view returns (bool) {
        return whitelisted[fid];
    }

    // ============ Receive ============
    
    receive() external payable {}
}