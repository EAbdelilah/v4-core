// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "../types/PoolKey.sol";

interface IOracle {
    /// @notice Returns the sqrt price of token1 in terms of token0: sqrt(token1/token0) * 2^96
    function getSqrtPriceX96(PoolKey calldata key) external view returns (uint160);
}
