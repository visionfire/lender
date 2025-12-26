// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./WadRayMath.sol";

library PoolUtils {

    function to18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        else return amount / (10 ** (decimals - 18));
    }

    function from18(uint256 amount18, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount18;
        if (decimals < 18) return amount18 / (10 ** (18 - decimals));
        else return amount18 * (10 ** (decimals - 18));
    }
}
