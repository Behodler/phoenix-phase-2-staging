// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockYieldStrategy
 * @notice Mock ERC4626-style vault for yield strategy testing
 * @dev Simplified implementation for local testing
 */
contract MockYieldStrategy is Ownable {
    using SafeERC20 for IERC20;

    // Track principal deposits per client
    mapping(address => mapping(address => uint256)) private _principals;

    // Track accumulated yield per client (simulated)
    mapping(address => mapping(address => uint256)) private _yields;

    // Authorized clients
    mapping(address => bool) public authorizedClients;

    // Authorized withdrawers
    mapping(address => bool) public authorizedWithdrawers;

    // Yield rate in basis points (e.g., 500 = 5% per year)
    uint256 public yieldRateBps = 500;

    // Last update timestamp per account
    mapping(address => mapping(address => uint256)) private _lastUpdate;

    event Deposited(address indexed token, address indexed client, uint256 amount, address indexed recipient);
    event Withdrawn(address indexed token, address indexed client, uint256 amount, address indexed recipient);
    event ClientAuthorized(address indexed client, bool authorized);
    event WithdrawerAuthorized(address indexed withdrawer, bool authorized);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Deposit tokens into the strategy
     * @param token The token address to deposit
     * @param amount The amount of tokens to deposit
     * @param recipient The address that will own the deposited tokens
     */
    function deposit(address token, uint256 amount, address recipient) external {
        require(authorizedClients[msg.sender], "Client not authorized");

        // Update yield before modifying principal
        _updateYield(token, recipient);

        // Transfer tokens from caller
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Track principal
        _principals[token][recipient] += amount;

        emit Deposited(token, msg.sender, amount, recipient);
    }

    /**
     * @notice Withdraw tokens from the strategy
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param recipient The address that will receive the tokens
     */
    function withdraw(address token, uint256 amount, address recipient) external {
        require(authorizedClients[msg.sender], "Client not authorized");

        // Update yield before withdrawal
        _updateYield(token, msg.sender);

        uint256 total = _principals[token][msg.sender] + _yields[token][msg.sender];
        require(total >= amount, "Insufficient balance");

        // Deduct from yield first, then principal
        if (_yields[token][msg.sender] >= amount) {
            _yields[token][msg.sender] -= amount;
        } else {
            uint256 fromYield = _yields[token][msg.sender];
            uint256 fromPrincipal = amount - fromYield;
            _yields[token][msg.sender] = 0;
            _principals[token][msg.sender] -= fromPrincipal;
        }

        // Transfer tokens
        IERC20(token).safeTransfer(recipient, amount);

        emit Withdrawn(token, msg.sender, amount, recipient);
    }

    /**
     * @notice Withdraw from specific client (for surplus extraction)
     * @param token The token address to withdraw
     * @param client The client address whose balance to withdraw from
     * @param amount The amount to withdraw
     * @param recipient The address that will receive the tokens
     */
    function withdrawFrom(
        address token,
        address client,
        uint256 amount,
        address recipient
    ) external {
        require(authorizedWithdrawers[msg.sender], "Not authorized withdrawer");

        // Update yield before withdrawal
        _updateYield(token, client);

        uint256 total = _principals[token][client] + _yields[token][client];
        require(total >= amount, "Insufficient balance");

        // Deduct from yield first, then principal
        if (_yields[token][client] >= amount) {
            _yields[token][client] -= amount;
        } else {
            uint256 fromYield = _yields[token][client];
            uint256 fromPrincipal = amount - fromYield;
            _yields[token][client] = 0;
            _principals[token][client] -= fromPrincipal;
        }

        // Transfer tokens
        IERC20(token).safeTransfer(recipient, amount);

        emit Withdrawn(token, client, amount, recipient);
    }

    /**
     * @notice Get principal balance (deposits only, no yield)
     * @param token The token address
     * @param account The account address
     * @return The principal balance
     */
    function principalOf(address token, address account) external view returns (uint256) {
        return _principals[token][account];
    }

    /**
     * @notice Get total balance including yield
     * @param token The token address
     * @param account The account address
     * @return The total balance (principal + yield)
     */
    function totalBalanceOf(address token, address account) external view returns (uint256) {
        uint256 simulatedYield = _calculateYield(token, account);
        return _principals[token][account] + _yields[token][account] + simulatedYield;
    }

    /**
     * @notice Get balance (deprecated, returns total for compatibility)
     * @param token The token address
     * @param account The account address
     * @return The balance
     */
    function balanceOf(address token, address account) external view returns (uint256) {
        uint256 simulatedYield = _calculateYield(token, account);
        return _principals[token][account] + _yields[token][account] + simulatedYield;
    }

    /**
     * @notice Set client authorization
     * @param client The address of the client contract
     * @param _auth Whether to authorize or deauthorize
     */
    function setClient(address client, bool _auth) external onlyOwner {
        authorizedClients[client] = _auth;
        emit ClientAuthorized(client, _auth);
    }

    /**
     * @notice Set withdrawer authorization
     * @param withdrawer The address of the withdrawer contract
     * @param _auth Whether to authorize or deauthorize
     */
    function setWithdrawer(address withdrawer, bool _auth) external onlyOwner {
        authorizedWithdrawers[withdrawer] = _auth;
        emit WithdrawerAuthorized(withdrawer, _auth);
    }

    /**
     * @notice Emergency withdraw for owner
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        // Not implemented for mock
    }

    /**
     * @notice Two-phase total withdrawal (not implemented for mock)
     * @param token The token address
     * @param client The client address
     */
    function totalWithdrawal(address token, address client) external onlyOwner {
        // Not implemented for mock
    }

    /**
     * @notice Set yield rate for testing
     * @param rateBps Yield rate in basis points
     */
    function setYieldRate(uint256 rateBps) external onlyOwner {
        yieldRateBps = rateBps;
    }

    /**
     * @notice Manually add yield for testing
     * @param token The token address
     * @param account The account address
     * @param amount The yield amount to add
     */
    function addYield(address token, address account, uint256 amount) external onlyOwner {
        _yields[token][account] += amount;
    }

    /**
     * @dev Update accumulated yield based on time elapsed
     */
    function _updateYield(address token, address account) internal {
        uint256 simulatedYield = _calculateYield(token, account);
        if (simulatedYield > 0) {
            _yields[token][account] += simulatedYield;
        }
        _lastUpdate[token][account] = block.timestamp;
    }

    /**
     * @dev Calculate simulated yield based on time elapsed
     */
    function _calculateYield(address token, address account) internal view returns (uint256) {
        if (_principals[token][account] == 0) {
            return 0;
        }

        uint256 lastUpdate = _lastUpdate[token][account];
        if (lastUpdate == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed == 0) {
            return 0;
        }

        // Simple yield calculation: principal * rate * time / (365 days * 10000)
        // This is very approximate for testing purposes
        uint256 principal = _principals[token][account];
        return (principal * yieldRateBps * timeElapsed) / (365 days * 10000);
    }
}
