// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ILendingPool.sol";



contract UserVault {

    // 用户
    address public owner;

    // lendingPool
    address public pool;

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }
    modifier onlyPool() {
        require(msg.sender == pool, "only pool");
        _;
    }

    event Executed(address indexed target, bytes data, bytes result);
    event TransferredByPool(address indexed token, address indexed to, uint256 amount);
    event SweptTokens(address indexed to, address[] tokens, uint256[] amounts);

    constructor(address _owner, address _pool) {
        require(_owner != address(0) && _pool != address(0), "zero address");
        owner = _owner;
        pool = _pool;
    }

    // 供用户调用其他允许过的dex, router等地址
    function execute(address target, bytes calldata data) external onlyOwner returns (bytes memory) {
        require(ILendingPool(pool).isAllowedTarget(target), "target not allowed");
        (bool ok, bytes memory res) = target.call(data);
        require(ok, "execute failed");
        emit Executed(target, data, res);
        return res;
    }


    // 只能允许lendingPool转账托管账户里的资产
    function transferByPool(address token, address to, uint256 amount) external onlyPool {
        require(to != address(0), "zero to");
        IERC20(token).transfer(to, amount);
        emit TransferredByPool(token, to, amount);
    }

    // 暂时预留的给lendingPool转移多个token的方法
    function sweepTokens(address[] calldata tokens, address to) external onlyPool returns (uint256[] memory) {
        require(to != address(0), "zero to");
        uint256 n = tokens.length;
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IERC20 t = IERC20(tokens[i]);
            uint256 balance = t.balanceOf(address(this));
            if (balance > 0) {
                t.transfer(to, balance);
                amounts[i] = balance;
            } else {
                amounts[i] = 0;
            }
        }
        emit SweptTokens(to, tokens, amounts);
        return amounts;
    }

    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

}
