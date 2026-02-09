// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ClawsUSDC
 * @notice Bonding curve speculation market for AI agents using USDC
 * @dev Handle-based markets with USDC pricing for multi-chain support
 * 
 * Key differences from ETH version:
 * - Uses USDC (6 decimals) instead of ETH (18 decimals)
 * - Pricing in USD cents for precision
 * - Cross-chain compatible (Base, Ethereum, Polygon, Arbitrum)
 * - Same pricing formula across all chains
 */
contract ClawsUSDC is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============
    
    /// @notice USDC token (6 decimals)
    IERC20 public immutable usdc;
    
    /// @notice Protocol fee: 5% (500 basis points)
    uint256 public constant PROTOCOL_FEE_BPS = 500;
    
    /// @notice Agent fee: 5% (500 basis points)  
    uint256 public constant AGENT_FEE_BPS = 500;
    
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    /// @notice Price curve divisor (adjusted for USDC 6 decimals)
    /// Formula: price = supply^2 / PRICE_DIVISOR
    /// At supply=100, price = 10000 / 160000 = 0.0625 USDC ($0.06)
    /// At supply=1000, price = 1000000 / 160000 = 6.25 USDC ($6.25)
    uint256 public constant PRICE_DIVISOR = 160000;
    
    // ============ State ============
    
    /// @notice Market data for each X handle (hashed)
    struct Market {
        uint256 supply;           // Total claws in circulation
        uint256 pendingFees;      // Unclaimed agent fees (USDC)
        uint256 lifetimeFees;     // Total fees earned (USDC)
        uint256 lifetimeVolume;   // Total trade volume (USDC)
        address verifiedWallet;   // Bound wallet (zero until verified)
        bool isVerified;          // Whether agent has verified
        uint256 createdAt;        // Block timestamp of market creation
    }
    
    /// @notice Markets indexed by keccak256(handle)
    mapping(bytes32 => Market) public markets;
    
    /// @notice Claw balances: handleHash => holder => balance
    mapping(bytes32 => mapping(address => uint256)) public clawsBalance;
    
    /// @notice Handle string storage (for frontend)
    mapping(bytes32 => string) public handleStrings;
    
    /// @notice Trusted verifier address (signs verification proofs)
    address public verifier;
    
    /// @notice Protocol treasury
    address public treasury;
    
    /// @notice Used nonces for verification (prevent replay)
    mapping(bytes32 => bool) public usedNonces;
    
    // ============ Events ============
    
    event MarketCreated(bytes32 indexed handleHash, string handle, address creator);
    event Trade(
        bytes32 indexed handleHash,
        address indexed trader,
        bool isBuy,
        uint256 amount,
        uint256 price,
        uint256 protocolFee,
        uint256 agentFee,
        uint256 newSupply
    );
    event AgentVerified(bytes32 indexed handleHash, string handle, address wallet);
    event FeesClaimed(bytes32 indexed handleHash, address wallet, uint256 amount);
    event VerifierUpdated(address oldVerifier, address newVerifier);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    
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
    error NoFeesPending();
    error TransferFailed();
    error InvalidHandle();
    error ZeroAddress();
    
    // ============ Constructor ============
    
    constructor(
        address _usdc,
        address _verifier,
        address _treasury
    ) Ownable(msg.sender) {
        if (_usdc == address(0) || _verifier == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20(_usdc);
        verifier = _verifier;
        treasury = _treasury;
    }
    
    // ============ Market Creation ============
    
    /**
     * @notice Create a market for an X handle (permissionless)
     * @param handle The X handle (without @)
     */
    function createMarket(string calldata handle) external {
        if (bytes(handle).length == 0 || bytes(handle).length > 32) {
            revert InvalidHandle();
        }
        
        bytes32 handleHash = _hashHandle(handle);
        
        if (markets[handleHash].createdAt != 0) {
            revert MarketAlreadyExists();
        }
        
        markets[handleHash] = Market({
            supply: 0,
            pendingFees: 0,
            lifetimeFees: 0,
            lifetimeVolume: 0,
            verifiedWallet: address(0),
            isVerified: false,
            createdAt: block.timestamp
        });
        
        handleStrings[handleHash] = handle;
        
        emit MarketCreated(handleHash, handle, msg.sender);
    }
    
    // ============ Trading ============
    
    /**
     * @notice Buy claws for a handle
     * @param handle The X handle
     * @param amount Number of claws to buy
     * @param maxCost Maximum USDC willing to spend (slippage protection)
     */
    function buyClaws(
        string calldata handle,
        uint256 amount,
        uint256 maxCost
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        bytes32 handleHash = _hashHandle(handle);
        Market storage market = markets[handleHash];
        
        // Auto-create market if doesn't exist
        if (market.createdAt == 0) {
            market.createdAt = block.timestamp;
            handleStrings[handleHash] = handle;
            emit MarketCreated(handleHash, handle, msg.sender);
        }
        
        uint256 price = getBuyPrice(handleHash, amount);
        uint256 protocolFee = (price * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 agentFee = (price * AGENT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalCost = price + protocolFee + agentFee;
        
        if (totalCost > maxCost) revert SlippageExceeded();
        
        // Transfer USDC from buyer
        usdc.safeTransferFrom(msg.sender, address(this), totalCost);
        
        // Send protocol fee to treasury
        usdc.safeTransfer(treasury, protocolFee);
        
        // Accumulate agent fee (claimable after verification)
        market.pendingFees += agentFee;
        market.lifetimeFees += agentFee;
        market.lifetimeVolume += price;
        
        // Update balances
        market.supply += amount;
        clawsBalance[handleHash][msg.sender] += amount;
        
        emit Trade(
            handleHash,
            msg.sender,
            true,
            amount,
            price,
            protocolFee,
            agentFee,
            market.supply
        );
    }
    
    /**
     * @notice Sell claws for a handle
     * @param handle The X handle
     * @param amount Number of claws to sell
     * @param minProceeds Minimum USDC to receive (slippage protection)
     */
    function sellClaws(
        string calldata handle,
        uint256 amount,
        uint256 minProceeds
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        bytes32 handleHash = _hashHandle(handle);
        Market storage market = markets[handleHash];
        
        if (market.createdAt == 0) revert MarketDoesNotExist();
        if (clawsBalance[handleHash][msg.sender] < amount) revert InsufficientBalance();
        
        uint256 price = getSellPrice(handleHash, amount);
        uint256 protocolFee = (price * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 agentFee = (price * AGENT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 proceeds = price - protocolFee - agentFee;
        
        if (proceeds < minProceeds) revert SlippageExceeded();
        
        // Update balances first (CEI pattern)
        market.supply -= amount;
        clawsBalance[handleHash][msg.sender] -= amount;
        
        // Accumulate fees
        market.pendingFees += agentFee;
        market.lifetimeFees += agentFee;
        market.lifetimeVolume += price;
        
        // Transfer USDC
        usdc.safeTransfer(treasury, protocolFee);
        usdc.safeTransfer(msg.sender, proceeds);
        
        emit Trade(
            handleHash,
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
     * @notice Verify ownership and bind wallet to handle
     * @param handle The X handle being verified
     * @param wallet The wallet to bind
     * @param timestamp Signature timestamp
     * @param nonce Unique nonce to prevent replay
     * @param signature Verifier's signature
     */
    function verifyAndClaim(
        string calldata handle,
        address wallet,
        uint256 timestamp,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant {
        bytes32 handleHash = _hashHandle(handle);
        Market storage market = markets[handleHash];
        
        if (market.createdAt == 0) revert MarketDoesNotExist();
        if (market.isVerified) revert AlreadyVerified();
        
        // Verify signature from trusted verifier
        bytes32 nonceHash = keccak256(abi.encodePacked(handle, wallet, timestamp, nonce));
        if (usedNonces[nonceHash]) revert NonceAlreadyUsed();
        
        bytes32 messageHash = keccak256(
            abi.encodePacked(handle, wallet, timestamp, nonce)
        );
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        
        if (ethSignedHash.recover(signature) != verifier) {
            revert InvalidSignature();
        }
        
        // Mark nonce as used
        usedNonces[nonceHash] = true;
        
        // Bind wallet and mark verified
        market.verifiedWallet = wallet;
        market.isVerified = true;
        
        emit AgentVerified(handleHash, handle, wallet);
        
        // Auto-claim any pending fees
        if (market.pendingFees > 0) {
            uint256 fees = market.pendingFees;
            market.pendingFees = 0;
            usdc.safeTransfer(wallet, fees);
            emit FeesClaimed(handleHash, wallet, fees);
        }
    }
    
    /**
     * @notice Claim accumulated fees (verified agents only)
     * @param handle The X handle
     */
    function claimFees(string calldata handle) external nonReentrant {
        bytes32 handleHash = _hashHandle(handle);
        Market storage market = markets[handleHash];
        
        if (!market.isVerified) revert NotVerified();
        if (msg.sender != market.verifiedWallet) revert NotVerified();
        if (market.pendingFees == 0) revert NoFeesPending();
        
        uint256 fees = market.pendingFees;
        market.pendingFees = 0;
        
        usdc.safeTransfer(msg.sender, fees);
        
        emit FeesClaimed(handleHash, msg.sender, fees);
    }
    
    // ============ Price Calculations ============
    
    /**
     * @notice Get the price to buy `amount` claws
     * @param handleHash The handle hash
     * @param amount Number of claws
     * @return Total price in USDC (6 decimals)
     */
    function getBuyPrice(bytes32 handleHash, uint256 amount) public view returns (uint256) {
        uint256 supply = markets[handleHash].supply;
        return _getPrice(supply, amount);
    }
    
    /**
     * @notice Get the price to buy `amount` claws (by handle string)
     */
    function getBuyPriceByHandle(string calldata handle, uint256 amount) external view returns (uint256) {
        return getBuyPrice(_hashHandle(handle), amount);
    }
    
    /**
     * @notice Get the proceeds from selling `amount` claws
     * @param handleHash The handle hash
     * @param amount Number of claws
     * @return Total proceeds in USDC (6 decimals)
     */
    function getSellPrice(bytes32 handleHash, uint256 amount) public view returns (uint256) {
        uint256 supply = markets[handleHash].supply;
        if (amount > supply) revert InsufficientBalance();
        return _getPrice(supply - amount, amount);
    }
    
    /**
     * @notice Get the proceeds from selling `amount` claws (by handle string)
     */
    function getSellPriceByHandle(string calldata handle, uint256 amount) external view returns (uint256) {
        return getSellPrice(_hashHandle(handle), amount);
    }
    
    /**
     * @notice Calculate price using bonding curve
     * @dev Price = sum of (supply + i)^2 / PRICE_DIVISOR for i = 0 to amount-1
     *      Simplified: (sum of squares from supply+1 to supply+amount) / PRICE_DIVISOR
     */
    function _getPrice(uint256 supply, uint256 amount) internal pure returns (uint256) {
        // Sum of squares formula: n(n+1)(2n+1)/6
        // We want sum from (supply+1) to (supply+amount)
        // = sum(1 to supply+amount) - sum(1 to supply)
        
        uint256 endSupply = supply + amount;
        
        uint256 sumEnd = (endSupply * (endSupply + 1) * (2 * endSupply + 1)) / 6;
        uint256 sumStart = (supply * (supply + 1) * (2 * supply + 1)) / 6;
        
        uint256 sumSquares = sumEnd - sumStart;
        
        // Convert to USDC (6 decimals)
        // Multiply by 1e6 for USDC precision, then divide by price divisor
        return (sumSquares * 1e6) / PRICE_DIVISOR;
    }
    
    /**
     * @notice Get cost breakdown for buying
     */
    function getBuyCostBreakdown(
        string calldata handle,
        uint256 amount
    ) external view returns (
        uint256 price,
        uint256 protocolFee,
        uint256 agentFee,
        uint256 totalCost
    ) {
        bytes32 handleHash = _hashHandle(handle);
        price = getBuyPrice(handleHash, amount);
        protocolFee = (price * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        agentFee = (price * AGENT_FEE_BPS) / BPS_DENOMINATOR;
        totalCost = price + protocolFee + agentFee;
    }
    
    /**
     * @notice Get proceeds breakdown for selling
     */
    function getSellProceedsBreakdown(
        string calldata handle,
        uint256 amount
    ) external view returns (
        uint256 price,
        uint256 protocolFee,
        uint256 agentFee,
        uint256 proceeds
    ) {
        bytes32 handleHash = _hashHandle(handle);
        price = getSellPrice(handleHash, amount);
        protocolFee = (price * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        agentFee = (price * AGENT_FEE_BPS) / BPS_DENOMINATOR;
        proceeds = price - protocolFee - agentFee;
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get market data for a handle
     */
    function getMarket(string calldata handle) external view returns (
        uint256 supply,
        uint256 pendingFees,
        uint256 lifetimeFees,
        uint256 lifetimeVolume,
        address verifiedWallet,
        bool isVerified,
        uint256 createdAt,
        uint256 currentPrice
    ) {
        bytes32 handleHash = _hashHandle(handle);
        Market storage market = markets[handleHash];
        
        supply = market.supply;
        pendingFees = market.pendingFees;
        lifetimeFees = market.lifetimeFees;
        lifetimeVolume = market.lifetimeVolume;
        verifiedWallet = market.verifiedWallet;
        isVerified = market.isVerified;
        createdAt = market.createdAt;
        
        // Current price to buy 1 claw
        if (supply > 0) {
            currentPrice = getBuyPrice(handleHash, 1);
        }
    }
    
    /**
     * @notice Get user's claw balance for a handle
     */
    function getBalance(string calldata handle, address user) external view returns (uint256) {
        return clawsBalance[_hashHandle(handle)][user];
    }
    
    /**
     * @notice Check if a market exists
     */
    function marketExists(string calldata handle) external view returns (bool) {
        return markets[_hashHandle(handle)].createdAt != 0;
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
    
    // ============ Internal ============
    
    function _hashHandle(string memory handle) internal pure returns (bytes32) {
        // Normalize to lowercase for consistent hashing
        bytes memory handleBytes = bytes(handle);
        for (uint256 i = 0; i < handleBytes.length; i++) {
            if (handleBytes[i] >= 0x41 && handleBytes[i] <= 0x5A) {
                handleBytes[i] = bytes1(uint8(handleBytes[i]) + 32);
            }
        }
        return keccak256(handleBytes);
    }
}
