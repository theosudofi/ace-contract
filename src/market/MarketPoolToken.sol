// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @notice Transferable LP share token and shared custody vault for one pool.
contract MarketPoolToken {
    using SafeTransferLib for address;

    error Unauthorized();
    error InvalidAddress();

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    address public immutable controller;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, address controller_) {
        if (controller_ == address(0)) revert InvalidAddress();
        name = name_;
        symbol = symbol_;
        controller = controller_;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert Unauthorized();
        _;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyController {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyController {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transferToken(address token, address to, uint256 amount) external onlyController {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        token.safeTransfer(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidAddress();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
