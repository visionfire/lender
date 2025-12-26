// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./utils/WadRayMath.sol";

contract InterestRateStrategy {
    using WadRayMath for uint256;

    uint256 public optimalUtilizationRate;
    uint256 public baseVariableBorrowRate;
    uint256 public variableRateSlope1;
    uint256 public variableRateSlope2;

    constructor(
        uint256 _optimalUtilizationRate,
        uint256 _baseVariableBorrowRate,
        uint256 _variableRateSlope1,
        uint256 _variableRateSlope2
    ) {
        optimalUtilizationRate = _optimalUtilizationRate;
        baseVariableBorrowRate = _baseVariableBorrowRate;
        variableRateSlope1 = _variableRateSlope1;
        variableRateSlope2 = _variableRateSlope2;
    }

    function calculateRates(
        uint256 availableLiquidity,
        uint256 totalBorrows,
        uint256 reserveFactor
    ) external view returns (uint256 liquidityRate, uint256 variableBorrowRate) {
        // util = totalBorrows / (availableLiquidity + totalBorrows)
        uint256 util = 0;
        if (totalBorrows > 0) {
            util = WadRayMath.rayDiv(totalBorrows * 1e9, (availableLiquidity + totalBorrows) * 1e9);
        }

        if (util <= optimalUtilizationRate) {
            // borrowRate = base + (util / opt) * slope1
            uint256 part = WadRayMath.rayDiv(util, optimalUtilizationRate);
            variableBorrowRate = baseVariableBorrowRate + WadRayMath.rayMul(variableRateSlope1, part);
        } else {
            // borrowRate = base + slope1 + ((util - opt) / (1 - opt)) * slope2
            uint256 excessUtil = util - optimalUtilizationRate;
            uint256 denom = WadRayMath.RAY - optimalUtilizationRate;
            uint256 part = WadRayMath.rayDiv(excessUtil, denom);
            variableBorrowRate = baseVariableBorrowRate + variableRateSlope1 + WadRayMath.rayMul(variableRateSlope2, part);
        }

        uint256 oneMinusReserve = WadRayMath.RAY - reserveFactor;
        liquidityRate = WadRayMath.rayMul(WadRayMath.rayMul(variableBorrowRate, util), oneMinusReserve);
        return (liquidityRate, variableBorrowRate);
    }
}
