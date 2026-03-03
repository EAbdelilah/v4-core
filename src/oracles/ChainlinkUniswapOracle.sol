// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "../types/PoolKey.sol";
import {Currency} from "../types/Currency.sol";
import {StateLibrary} from "../libraries/StateLibrary.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {FixedPoint96} from "../libraries/FixedPoint96.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracle} from "../interfaces/IOracle.sol";

interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

/// @title ChainlinkUniswapOracle
/// @notice A hybrid oracle using Chainlink for base prices and Uniswap v4 for fallback.
contract ChainlinkUniswapOracle is IOracle, Ownable {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    // token => aggregator
    mapping(address => address) public aggregators;
    // token => decimals
    mapping(address => uint8) public tokenDecimals;

    constructor(IPoolManager _manager, address _owner) Ownable(_owner) {
        manager = _manager;
    }

    function setAggregator(address token, address aggregator, uint8 decimals) external onlyOwner {
        aggregators[token] = aggregator;
        tokenDecimals[token] = decimals;
    }

    /// @notice Returns the sqrt price of token1 in terms of token0.
    /// Price = token1 / token0  (how many token1 per 1 token0)
    /// sqrtPriceX96 = sqrt(Price) * 2^96
    function getSqrtPriceX96(PoolKey calldata key) external view override returns (uint160) {
        address agg0 = aggregators[Currency.unwrap(key.currency0)];
        address agg1 = aggregators[Currency.unwrap(key.currency1)];

        if (agg0 != address(0) && agg1 != address(0)) {
            try this.getChainlinkPrice(agg0, agg1, tokenDecimals[Currency.unwrap(key.currency0)], tokenDecimals[Currency.unwrap(key.currency1)]) returns (uint256 priceX96) {
                // sqrtPriceX96 = sqrt(priceX96 / 2^96) * 2^96 = sqrt(priceX96 * 2^96)
                // priceX96 is (token1/token0) * 2^96
                // In Uniswap v4, sqrtPriceX96 = sqrt(token1/token0) * 2^96
                // Our priceX96 here is (token1/token0) * 2^96
                // So we want sqrt(priceX96 * 2^96) = sqrt(priceX96) * 2^48
                return uint160(sqrt(priceX96) * 2**48);
            } catch {
                return getUniswapPrice(key);
            }
        }

        return getUniswapPrice(key);
    }

    function getChainlinkPrice(address agg0, address agg1, uint8 dec0, uint8 dec1) external view returns (uint256) {
        (, int256 p0, , , ) = AggregatorV3Interface(agg0).latestRoundData();
        (, int256 p1, , , ) = AggregatorV3Interface(agg1).latestRoundData();

        require(p0 > 0 && p1 > 0, "Invalid oracle price");

        uint8 aggDec0 = AggregatorV3Interface(agg0).decimals();
        uint8 aggDec1 = AggregatorV3Interface(agg1).decimals();

        // Standardize to 18 decimals for internal calculation
        uint256 price0 = uint256(p0);
        if (aggDec0 < 18) price0 *= (10**(18 - aggDec0));
        uint256 price1 = uint256(p1);
        if (aggDec1 < 18) price1 *= (10**(18 - aggDec1));

        // Adjust for token decimals
        // Value0 = (amount0 / 10^dec0) * price0
        // Value1 = (amount1 / 10^dec1) * price1
        // For Value0 = Value1:
        // amount1 = amount0 * (price0 / price1) * (10^dec1 / 10^dec0)

        if (dec1 > dec0) {
            price0 = price0 * (10**(dec1 - dec0));
        } else if (dec0 > dec1) {
            price1 = price1 * (10**(dec0 - dec1));
        }

        // PriceX96 (token1 per token0) = (price0 * 2^96) / price1
        return FullMath.mulDiv(price0, FixedPoint96.Q96, price1);
    }

    function getUniswapPrice(PoolKey calldata key) public view returns (uint160) {
        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        return sqrtPriceX96;
    }

    // Helper to calculate sqrt
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
