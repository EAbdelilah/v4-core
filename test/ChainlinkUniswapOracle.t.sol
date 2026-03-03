// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkUniswapOracle} from "../src/oracles/ChainlinkUniswapOracle.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency} from "../src/types/Currency.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {Deployers} from "./utils/Deployers.sol";
import {IHooks} from "../src/interfaces/IHooks.sol";

contract MockChainlinkAggregator {
    uint8 public _decimals;
    int256 public answer;

    constructor(uint8 decimals_, int256 _answer) {
        _decimals = decimals_;
        answer = _answer;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 _answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract ChainlinkUniswapOracleTest is Test, Deployers {
    ChainlinkUniswapOracle oracle;

    function setUp() public {
        deployFreshManagerAndRouters();
        oracle = new ChainlinkUniswapOracle(manager, address(this));
    }

    function test_chainlink_pricing() public {
        // Mock tokens: WBTC (8 decimals) and USDC (6 decimals)
        address wbtc = address(0x1);
        address usdc = address(0x2);

        // Mock Aggregators
        // WBTC/USD: $60,000 (8 decimals)
        MockChainlinkAggregator aggWBTC = new MockChainlinkAggregator(8, 60000 * 10**8);
        // USDC/USD: $1 (8 decimals)
        MockChainlinkAggregator aggUSDC = new MockChainlinkAggregator(8, 1 * 10**8);

        oracle.setAggregator(wbtc, address(aggWBTC), 8);
        oracle.setAggregator(usdc, address(aggUSDC), 6);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdc), // USDC
            currency1: Currency.wrap(wbtc), // WBTC
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPriceX96 = oracle.getSqrtPriceX96(key);

        // Let's use simpler prices for precise checking
        // WBTC/USD: $1 (8 decimals) -> answer = 1e8
        // USDC/USD: $1 (8 decimals) -> answer = 1e8
        // WBTC (8 dec), USDC (6 dec)
        // 1 unit WBTC = $1 / 10^8
        // 1 unit USDC = $1 / 10^6
        // Relative price (WBTC in USDC) = (1/10^8) / (1/10^6) = 1/100 = 0.01.
        // Price = 0.01 units of USDC per 1 unit of WBTC.

        // PriceX96 (token1 per token0) = (price0 * 2^96) / price1
        // token0 = USDC, token1 = WBTC
        // price0 = USD value of 1 unit of USDC = 1/10^6
        // price1 = USD value of 1 unit of WBTC = 1/10^8
        // PriceX96 = (1/10^6 * 2^96) / (1/10^8) = 100 * 2^96.
        // sqrtPriceX96 = sqrt(100 * 2^96 * 2^96) = sqrt(100 * 2^192) = 10 * 2^96.

        MockChainlinkAggregator aggWBTC_2 = new MockChainlinkAggregator(8, 1 * 10**8);
        MockChainlinkAggregator aggUSDC_2 = new MockChainlinkAggregator(8, 1 * 10**8);
        oracle.setAggregator(wbtc, address(aggWBTC_2), 8);
        oracle.setAggregator(usdc, address(aggUSDC_2), 6);

        sqrtPriceX96 = oracle.getSqrtPriceX96(key);
        assertEq(sqrtPriceX96, 10 * 2**96);
    }

    function test_uniswap_fallback() public {
        address token0 = address(0x11);
        address token1 = address(0x22);
        if (token0 > token1) (token0, token1) = (token1, token0);

        (key, ) = initPool(Currency.wrap(token0), Currency.wrap(token1), IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // Aggregators not set, should fallback to Uniswap
        uint160 sqrtPriceX96 = oracle.getSqrtPriceX96(key);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }

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
