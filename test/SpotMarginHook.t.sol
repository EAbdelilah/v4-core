// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "./utils/Deployers.sol";
import {PoolManager} from "../src/PoolManager.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Hooks} from "../src/libraries/Hooks.sol";
import {IHooks} from "../src/interfaces/IHooks.sol";
import {SwapParams} from "../src/types/PoolOperation.sol";
import {PoolSwapTest} from "../src/test/PoolSwapTest.sol";
import {SpotMarginHook} from "../src/SpotMarginHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {Constants} from "./utils/Constants.sol";

contract SpotMarginHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SpotMarginHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Permissions: beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta
        // 0xCC = 204
        address hookAddress = address(uint160(204));
        SpotMarginHook hookImpl = new SpotMarginHook(manager);
        vm.etch(hookAddress, address(hookImpl).code);
        hook = SpotMarginHook(payable(hookAddress));

        (currency0, currency1) = deployMintAndApprove2Currencies();

        (key, ) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        // Add liquidity
        seedMoreLiquidity(key, 100e18, 100e18);

        // Fund the hook with 100 of each currency
        MockERC20(Currency.unwrap(currency0)).mint(address(hook), 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 100e18);
    }

    function test_marginSwap_long_0_interest() public {
        uint256 collateralProvided = 1e18;
        uint256 borrowAmount = 2e18;

        // User provides 1e18, hook provides 2e18. Total swap will be 3e18.
        MockERC20(Currency.unwrap(currency0)).mint(address(this), collateralProvided);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), collateralProvided);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(collateralProvided),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        bytes memory hookData = abi.encode(address(this), borrowAmount);

        swapRouter.swap(key, params, settings, hookData);

        // Verify position
        (uint256 collateral, uint256 debt, Currency collateralCurr, Currency debtCurr) = hook.positions(address(this), key.toId());

        assertEq(debt, borrowAmount, "Debt should match borrow amount");
        assertTrue(collateral > 0, "Collateral should be recorded");
        assertEq(Currency.unwrap(collateralCurr), Currency.unwrap(currency1));
        assertEq(Currency.unwrap(debtCurr), Currency.unwrap(currency0));

        // Move time forward (simulating interest period, though it's 0%)
        vm.warp(block.timestamp + 365 days);

        // Close position
        // User pays debt (still 2e18 because 0% interest)
        MockERC20(Currency.unwrap(currency0)).mint(address(this), debt);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), debt);

        uint256 balanceBefore = currency1.balanceOf(address(this));
        hook.closePosition(key);
        uint256 balanceAfter = currency1.balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, collateral, "User should receive all collateral back");

        (collateral,,, ) = hook.positions(address(this), key.toId());
        assertEq(collateral, 0, "Position should be closed");
    }

    function test_marginSwap_short_0_interest() public {
        uint256 collateralProvided = 1e18; // 1 ETH
        uint256 borrowAmount = 1e18;       // 1 ETH

        // Shorting ETH: sell ETH for USDC.
        MockERC20(Currency.unwrap(currency1)).mint(address(this), collateralProvided);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), collateralProvided);

        SwapParams memory params = SwapParams({
            zeroForOne: false, // currency1 to currency0
            amountSpecified: -int256(collateralProvided),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        bytes memory hookData = abi.encode(address(this), borrowAmount);

        swapRouter.swap(key, params, settings, hookData);

        // Verify position
        (uint256 collateral, uint256 debt, Currency collateralCurr, Currency debtCurr) = hook.positions(address(this), key.toId());

        assertEq(debt, borrowAmount, "Debt should match borrow amount");
        assertTrue(collateral > 0, "Collateral should be recorded");
        assertEq(Currency.unwrap(collateralCurr), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(debtCurr), Currency.unwrap(currency1));

        // Close position
        MockERC20(Currency.unwrap(currency1)).mint(address(this), debt);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), debt);

        uint256 balanceBefore = currency0.balanceOf(address(this));
        hook.closePosition(key);
        uint256 balanceAfter = currency0.balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, collateral, "User should receive all collateral back");
    }

    function test_revert_positionExists() public {
        uint256 collateralProvided = 1e18;
        uint256 borrowAmount = 2e18;

        MockERC20(Currency.unwrap(currency0)).mint(address(this), collateralProvided * 2);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), collateralProvided * 2);

        bytes memory hookData = abi.encode(address(this), borrowAmount);

        swapRouter.swap(key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(collateralProvided),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        // Try to open another position on the same pool
        vm.expectRevert();
        swapRouter.swap(key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(collateralProvided),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function test_exactOutput_noMargin() public {
        uint256 outputDesired = 1e18;
        uint256 borrowAmount = 2e18;

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 10e18);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 10e18);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(outputDesired), // Exact Output
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        bytes memory hookData = abi.encode(address(this), borrowAmount);

        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData);

        // Verify no position
        (uint256 collateral,,,) = hook.positions(address(this), key.toId());
        assertEq(collateral, 0, "No position should be opened for exact output");
    }
}
