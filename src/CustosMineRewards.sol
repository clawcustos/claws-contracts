// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICustosMineController {
    function receiveCustos(uint256 amount) external;
}

/**
 * @title CustosMineRewards
 * @notice Accumulates WETH, swaps to $CUSTOS, and forwards to CustosMineController as epoch rewards.
 *         Swap is executed via 0x allowance-holder router (standard ERC20 approve — not permit2).
 *
 * Access: oracle or custodian only.
 */
contract CustosMineRewards {
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────────────────

    address public owner;
    mapping(address => bool) public custodians;
    address public oracle;
    address public controller;      // CustosMineController

    address public immutable WETH;
    address public immutable CUSTOS_TOKEN;
    address public immutable ALLOWANCE_HOLDER; // 0x allowance-holder router

    // ─── Events ───────────────────────────────────────────────────────────────

    event SwappedAndSent(uint256 wethIn, uint256 custosOut, address indexed to);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ControllerUpdated(address indexed oldController, address indexed newController);
    event FundsRecovered(address indexed token, uint256 amount, address indexed to);
    event ETHRecovered(uint256 amount, address indexed to);
    event ETHReceived(uint256 amount, address indexed from);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event CustodianSet(address indexed account, bool enabled);

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
        require(_owner != address(0), "E29");
        require(_oracle != address(0), "E29");
        require(_custodians.length > 0, "E29");
        require(_controller != address(0), "E29");
        require(_weth != address(0), "E29");
        require(_custosToken != address(0), "E29");
        require(_allowanceHolder != address(0), "E29");

        owner = _owner;
        for (uint256 i = 0; i < _custodians.length; i++) {
            require(_custodians[i] != address(0), "E29");
            custodians[_custodians[i]] = true;
            emit CustodianSet(_custodians[i], true);
        }
        oracle = _oracle;
        controller = _controller;
        WETH = _weth;
        CUSTOS_TOKEN = _custosToken;
        ALLOWANCE_HOLDER = _allowanceHolder;
    }

    // ─── Core ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap all held WETH → $CUSTOS and forward to CustosMineController.
     * @dev Uses 0x allowance-holder pattern (standard ERC20 approve — NOT permit2).
     * @param swapCalldata  Pre-computed 0x API calldata targeting ALLOWANCE_HOLDER.
     * @param minAmountOut  Slippage guard — reverts if $CUSTOS received is below this.
     */
    function swapAndSend(
        bytes calldata swapCalldata,
        uint256 minAmountOut
    ) external onlyAuthorised {
        uint256 wethIn = IERC20(WETH).balanceOf(address(this));
        require(wethIn > 0, "E46");

        // Approve allowance-holder to spend WETH
        IERC20(WETH).approve(ALLOWANCE_HOLDER, wethIn);

        // Execute swap via 0x allowance-holder
        uint256 custosBalanceBefore = IERC20(CUSTOS_TOKEN).balanceOf(address(this));
        (bool success,) = ALLOWANCE_HOLDER.call(swapCalldata);

        // Always clear approval — even on failure path
        IERC20(WETH).approve(ALLOWANCE_HOLDER, 0);

        require(success, "E42");

        uint256 custosReceived = IERC20(CUSTOS_TOKEN).balanceOf(address(this)) - custosBalanceBefore;
        require(custosReceived >= minAmountOut, "E42");

        // Transfer $CUSTOS to controller, then notify for accounting.
        // safeTransfer reverts on failure — receiveCustos is only called if tokens arrived.
        IERC20(CUSTOS_TOKEN).safeTransfer(controller, custosReceived);
        ICustosMineController(controller).receiveCustos(custosReceived);

        emit SwappedAndSent(wethIn, custosReceived, controller);
    }

    /// @notice Pull WETH from caller into this contract. Caller must approve first.
    function receiveWeth(uint256 amount) external {
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Accept raw ETH (e.g. unwrapped rewards sent directly).
    receive() external payable {
        emit ETHReceived(msg.value, msg.sender);
    }

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
        require(to != address(0), "E29");
        IERC20(token).safeTransfer(to, amount);
        emit FundsRecovered(token, amount, to);
    }

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
