// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracle} from "../SpotMarginHook.sol";
import {PoolKey} from "../types/PoolKey.sol";

contract MockOracle is IOracle {
    uint160 public price;

    function setPrice(uint160 _price) external {
        price = _price;
    }

    function getSqrtPriceX96(PoolKey calldata) external view override returns (uint160) {
        return price;
    }
}
