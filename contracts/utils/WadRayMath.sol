// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


library WadRayMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = RAY / 2;
    uint256 internal constant SECONDS_PER_YEAR = 31536000;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_RAY) / RAY;
    }

    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "WadRayMath: division by zero");
        return (a * RAY + b / 2) / b;
    }

    function wadToRay(uint256 a) internal pure returns (uint256) {
        return a * (RAY / WAD);
    }

    function rayToWad(uint256 a) internal pure returns (uint256) {
        return a / (RAY / WAD);
    }
}
