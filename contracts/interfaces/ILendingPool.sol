// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ILendingPool {

    function getReserveLiquidityIndex(address asset) external view returns (uint256);

    function getReserveVariableBorrowIndex(address asset) external view returns (uint256);
}
