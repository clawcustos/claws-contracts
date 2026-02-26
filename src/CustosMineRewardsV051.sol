// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICustosMineController {
    function receiveCustos(uint256 amount) external;
}

/**
 * @title CustosMineRewardsV051
 * @notice Accumulates WETH, swaps to $CUSTOS via 0x AllowanceHolder, and forwards
 *         to CustosMineControllerV051 as epoch rewards via receiveCustos().
 *
 *         Flow:
 *           1. 0xSplits R&D allocation → WETH arrives via receiveWeth() or direct transfer
 *           2. Custodian calls swapAndSend(calldata, minOut) with 0x API calldata
 *           3. WETH swapped → $CUSTOS, forwarded to controller → loads rewardBuffer
 *           4. On next openEpoch(): rewardBuffer becomes the epoch prize pool
 *
 * Access model:
 *   - owner:      transferOwnership, setCustodian, setController
 *   - custodian:  swapAndSend, receiveWeth, recoverFunds, recoverETH, setOracle
 *   - oracle:     swapAndSend (for automation)
 *
 * Version: v0.5.1 — matches CustosMineControllerV051 series.
 */
contract CustosMineRewardsV051 {
    using SafeERC20 for IERC20;

    string public constant VERSION = "v0.5.1";

    // ─── State ────────────────────────────────────────────────────────────────

    address public owner;
    mapping(address => bool) public custodians;
    address public oracle;
    address public controller;      // CustosMineControllerV051

    address public immutable WETH;
    address public immutable CUSTOS_TOKEN;
    address public immutable ALLOWANCE_HOLDER; // 0x AllowanceHolder router

    // ─── Events ───────────────────────────────────────────────────────────────

    event SwappedAndSent(uint256 wethIn, uint256 custosOut, address indexed to);
    event WethReceived(uint256 amount, address indexed from);
    event ETHReceived(uint256 amount, address indexed from);
    event FundsRecovered(address indexed token, uint256 amount, address indexed to);
    event ETHRecovered(uint256 amount, address indexed to);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event CustodianSet(address indexed account, bool enabled);
    event OracleUpdated(address indexed prev, address indexed next);
    event ControllerUpdated(address indexed prev, address indexed next);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "E26");
        _;
    }

    modifier onlyCustodian() {
        require(custodians[msg.sender], "E25");
        _;
    }

    modifier onlyAuthorised() {
        require(msg.sender == oracle || custodians[msg.sender], "E24");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _owner,
        address[] memory _custodians,
        address _oracle,
        address _controller,
        address _weth,
        address _custosToken,
        address _allowanceHolder
    ) {
        require(_owner          != address(0), "E29");
        require(_oracle         != address(0), "E29");
        require(_custodians.length > 0,        "E29");
        require(_controller     != address(0), "E29");
        require(_weth           != address(0), "E29");
        require(_custosToken    != address(0), "E29");
        require(_allowanceHolder != address(0), "E29");

        owner            = _owner;
        oracle           = _oracle;
        controller       = _controller;
        WETH             = _weth;
        CUSTOS_TOKEN     = _custosToken;
        ALLOWANCE_HOLDER = _allowanceHolder;

        for (uint256 i = 0; i < _custodians.length; i++) {
            require(_custodians[i] != address(0), "E29");
            custodians[_custodians[i]] = true;
            emit CustodianSet(_custodians[i], true);
        }
    }

    // ─── Core ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap all held WETH → $CUSTOS and forward to CustosMineControllerV051.
     * @dev Uses 0x AllowanceHolder pattern (standard ERC20 approve — NOT permit2).
     *      Approval is always cleared after the call, even on failure.
     * @param swapCalldata  Pre-computed 0x API calldata targeting ALLOWANCE_HOLDER.
     * @param minAmountOut  Slippage guard — reverts E42 if $CUSTOS received < this.
     */
    function swapAndSend(
        bytes calldata swapCalldata,
        uint256 minAmountOut
    ) external onlyAuthorised {
        uint256 wethIn = IERC20(WETH).balanceOf(address(this));
        require(wethIn > 0, "E46");

        // Approve AllowanceHolder to spend WETH
        IERC20(WETH).approve(ALLOWANCE_HOLDER, wethIn);

        // Execute swap — always clear approval after, success or failure
        uint256 custosBalanceBefore = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        (bool success,) = ALLOWANCE_HOLDER.call(swapCalldata);
        IERC20(WETH).approve(ALLOWANCE_HOLDER, 0);

        require(success, "E63");

        uint256 custosReceived = IERC20(CUSTOS_TOKEN).balanceOf(address(this)) - custosBalanceBefore;
        require(custosReceived >= minAmountOut, "E42");

        // safeTransfer reverts on failure — receiveCustos only called if tokens arrived
        IERC20(CUSTOS_TOKEN).safeTransfer(controller, custosReceived);
        ICustosMineController(controller).receiveCustos(custosReceived);

        emit SwappedAndSent(wethIn, custosReceived, controller);
    }

    /**
     * @notice Pull WETH from caller into this contract.
     *         Caller must approve this contract to spend WETH first.
     *         Used by 0xSplits withdrawal flow.
     */
    function receiveWeth(uint256 amount) external {
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), amount);
        emit WethReceived(amount, msg.sender);
    }

    /// @notice Accept raw ETH (e.g. WETH unwrapped and sent directly).
    receive() external payable {
        emit ETHReceived(msg.value, msg.sender);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Emergency ERC20 recovery. Custodian only.
     *         Covers stuck WETH, $CUSTOS, or any other token.
     */
    function recoverFunds(
        address token,
        uint256 amount,
        address to
    ) external onlyCustodian {
        require(to != address(0), "E29");
        IERC20(token).safeTransfer(to, amount);
        emit FundsRecovered(token, amount, to);
    }

    /// @notice Emergency ETH recovery. Custodian only.
    function recoverETH(address payable to) external onlyCustodian {
        require(to != address(0), "E29");
        uint256 bal = address(this).balance;
        require(bal > 0, "E46");
        (bool ok,) = to.call{value: bal}("");
        require(ok, "E47");
        emit ETHRecovered(bal, to);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "E29");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setCustodian(address account, bool enabled) external onlyOwner {
        require(account != address(0), "E29");
        custodians[account] = enabled;
        emit CustodianSet(account, enabled);
    }

    function setOracle(address newOracle) external onlyCustodian {
        require(newOracle != address(0), "E29");
        emit OracleUpdated(oracle, newOracle);
        oracle = newOracle;
    }

    /// @notice Update controller address. Owner only. Used when migrating to a new MineController version.
    function setController(address newController) external onlyOwner {
        require(newController != address(0), "E29");
        emit ControllerUpdated(controller, newController);
        controller = newController;
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function wethBalance() external view returns (uint256) {
        return IERC20(WETH).balanceOf(address(this));
    }

    function custosBalance() external view returns (uint256) {
        return IERC20(CUSTOS_TOKEN).balanceOf(address(this));
    }
}
