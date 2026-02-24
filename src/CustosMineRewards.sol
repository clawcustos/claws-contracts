// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICustosMineController {
    function receiveCustos(uint256 amount) external;
}

/**
 * @title CustosMineRewards
 * @notice Accumulates WETH from 0xSplits R&D allocation.
 *         On epoch open: swaps WETH → $CUSTOS via 0x allowance-holder,
 *         forwards $CUSTOS to CustosMineController as epoch reward pool.
 *
 * Access: oracle (Custos) or custodian (Pizza) only.
 * No timelock on recoverFunds — trusted parties only.
 *
 * Flow:
 *   0xSplits → this contract (WETH) → swapAndSend() → CustosMineController
 */
contract CustosMineRewards {
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────────────────

    address public oracle;
    address public custodian;
    address public controller;      // CustosMineController

    address public immutable WETH;
    address public immutable CUSTOS_TOKEN;
    address public immutable ALLOWANCE_HOLDER; // 0x allowance-holder router

    // ─── Events ───────────────────────────────────────────────────────────────

    event SwappedAndSent(uint256 wethIn, uint256 custosOut, address indexed to);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ControllerUpdated(address indexed oldController, address indexed newController);
    event FundsRecovered(address indexed token, uint256 amount, address indexed to);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyAuthorised() {
        require(msg.sender == oracle || msg.sender == custodian, "not authorised");
        _;
    }

    modifier onlyCustodian() {
        require(msg.sender == custodian, "not custodian");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _oracle,
        address _custodian,
        address _controller,
        address _weth,
        address _custosToken,
        address _allowanceHolder
    ) {
        require(_oracle != address(0), "zero oracle");
        require(_custodian != address(0), "zero custodian");
        require(_controller != address(0), "zero controller");
        require(_weth != address(0), "zero weth");
        require(_custosToken != address(0), "zero token");
        require(_allowanceHolder != address(0), "zero router");

        oracle = _oracle;
        custodian = _custodian;
        controller = _controller;
        WETH = _weth;
        CUSTOS_TOKEN = _custosToken;
        ALLOWANCE_HOLDER = _allowanceHolder;
    }

    // ─── Core ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap all held WETH → $CUSTOS, send to CustosMineController.
     * @dev Called by oracle at each epoch open.
     *      swapCalldata: pre-computed 0x API calldata targeting ALLOWANCE_HOLDER.
     *      Uses 0x allowance-holder pattern (standard ERC20 approve — NOT permit2).
     *      minAmountOut: slippage guard. Reverts if $CUSTOS received < minAmountOut.
     * @param swapCalldata  0x API calldata
     * @param minAmountOut  Minimum $CUSTOS to receive (set to market rate * 0.98 off-chain)
     */
    function swapAndSend(
        bytes calldata swapCalldata,
        uint256 minAmountOut
    ) external onlyAuthorised {
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        require(wethBalance > 0, "no WETH to swap");

        // Approve allowance-holder to spend WETH
        IERC20(WETH).approve(ALLOWANCE_HOLDER, wethBalance);

        // Execute swap via 0x allowance-holder
        uint256 custosBalanceBefore = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        (bool success,) = ALLOWANCE_HOLDER.call(swapCalldata);
        require(success, "swap failed");

        uint256 custosReceived = IERC20(CUSTOS_TOKEN).balanceOf(address(this)) - custosBalanceBefore;
        require(custosReceived >= minAmountOut, "slippage exceeded");

        // Clear any residual approval
        IERC20(WETH).approve(ALLOWANCE_HOLDER, 0);

        // Forward to controller and notify it for accounting
        IERC20(CUSTOS_TOKEN).safeTransfer(controller, custosReceived);
        ICustosMineController(controller).receiveCustos(custosReceived);

        emit SwappedAndSent(wethBalance, custosReceived, controller);
    }

    /**
     * @notice Receive WETH from 0xSplits or manual transfer.
     * @dev 0xSplits sends via transferFrom — caller must approve first.
     *      Or send WETH directly (contract holds it passively).
     */
    function receiveWeth(uint256 amount) external {
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Accept raw ETH, wrap to WETH if needed (convenience)
    receive() external payable {}

    // ─── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Emergency fund recovery. No timelock — oracle + custodian trusted.
     * @dev Custodian only. Recovers any ERC20 (WETH, $CUSTOS, or stuck tokens).
     */
    function recoverFunds(
        address token,
        uint256 amount,
        address to
    ) external onlyCustodian {
        require(to != address(0), "zero recipient");
        IERC20(token).safeTransfer(to, amount);
        emit FundsRecovered(token, amount, to);
    }

    function setOracle(address newOracle) external onlyCustodian {
        require(newOracle != address(0), "zero");
        emit OracleUpdated(oracle, newOracle);
        oracle = newOracle;
    }

    function setController(address newController) external onlyCustodian {
        require(newController != address(0), "zero");
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
