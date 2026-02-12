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
import {ModifyLiquidityParams, SwapParams} from "../src/types/PoolOperation.sol";
import {PoolSwapTest} from "../src/test/PoolSwapTest.sol";
import {SpotMarginHook, IOracle} from "../src/SpotMarginHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockOracle} from "../src/test/MockOracle.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {Constants} from "./utils/Constants.sol";

contract SpotMarginHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SpotMarginHook hook;
    MockOracle oracle;

    function setUp() public {
        deployFreshManagerAndRouters();

        // Permissions: beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta
        // 0xCC = 204
        address hookAddress = address(uint160(204));
        SpotMarginHook hookImpl = new SpotMarginHook(manager, address(this));
        vm.etch(hookAddress, address(hookImpl).code);
        hook = SpotMarginHook(payable(hookAddress));

        // Initialize storage at etched address
        vm.store(hookAddress, bytes32(uint256(0)), bytes32(uint256(uint160(address(this)))));

        (currency0, currency1) = deployMintAndApprove2Currencies();

        (key, ) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        // Add liquidity with a wide range
        LIQUIDITY_PARAMS = ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 0, salt: 0});
        seedMoreLiquidity(key, 100e18, 100e18);

        // Deploy and set oracle
        oracle = new MockOracle();
        oracle.setPrice(SQRT_PRICE_1_1);
        hook.setOracle(address(oracle));

        // Fund the hook via deposit
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), 100e18);
        hook.deposit(currency0, 100e18);

        MockERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), 100e18);
        hook.deposit(currency1, 100e18);
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
        uint256 collateralProvided = 10e18;
        uint256 borrowAmount = 1e18;

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

    function test_revert_exceedsLTV() public {
        uint256 collateralProvided = 1e18;
        // At 1:1 price, if we borrow 10e18 against 1e18 input, total input is 11e18.
        // Output will be ~11e18.
        // Debt 10e18, Collateral 11e18. LTV = 10/11 = 90.9% > 75%. Should revert.
        uint256 borrowAmount = 10e18;

        MockERC20(Currency.unwrap(currency0)).mint(address(this), collateralProvided);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), collateralProvided);

        bytes memory hookData = abi.encode(address(this), borrowAmount);

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

    function test_liquidation() public {
        uint256 collateralProvided = 1e18;
        // Borrow 2e18. Total input 3e18. Output ~3e18.
        // Debt 2e18, Collateral 3e18. LTV = 2/3 = 66% < 75%. Safe.
        uint256 borrowAmount = 2e18;

        MockERC20(Currency.unwrap(currency0)).mint(address(this), collateralProvided);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), collateralProvided);

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

        // Check health factor
        uint256 hf = hook.getHealthFactor(address(this), key);
        // console.log("HF initially:", hf);
        assertTrue(hf >= 1 ether, "Should be healthy initially");

        // Move price to make it liquidatable
        // Currently 1 token0 = 1 token1.
        // Collateral is token1. Debt is token0.
        // If price of token1 drops relative to token0, HF decreases.
        // Token1 value in token0 = amount1 * price1/price0.
        // Swap token1 for token0 (zeroForOne=false) to push price up (token1 becomes cheaper relative to token0).
        // Wait, if P = token1/token0 increases, it means more token1 per token0, so token1 is cheaper.
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 90e18);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 90e18);
        swapRouter.swap(key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -90e18,
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Pushing pool price down shouldn't affect HF if oracle stays same
        hf = hook.getHealthFactor(address(this), key);
        assertTrue(hf >= 1 ether, "Should stay healthy if oracle is stable");

        // Move ORACLE price to make it liquidatable
        oracle.setPrice(uint160(uint256(SQRT_PRICE_1_1) * 2)); // Token1 is now 4x cheaper relative to token0?
        // Wait, if P = token1/token0, P increases means token1 is more plentiful/cheaper.
        // P = (sqrtPrice/2^96)^2.
        // If sqrtPrice doubles, P quadruples.
        // Token1 value in token0 = 1/P. So it drops to 1/4.

        hf = hook.getHealthFactor(address(this), key);
        assertTrue(hf < 1 ether, "Should be liquidatable after ORACLE price drop");

        // Liquidate
        address liquidator = makeAddr("liquidator");
        MockERC20(Currency.unwrap(currency0)).mint(liquidator, borrowAmount);

        vm.startPrank(liquidator);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), borrowAmount);

        uint256 balanceBefore = currency1.balanceOf(liquidator);
        hook.liquidate(address(this), key);
        uint256 balanceAfter = currency1.balanceOf(liquidator);

        assertTrue(balanceAfter > balanceBefore, "Liquidator should get collateral");
        vm.stopPrank();

        (uint256 collateral,,,) = hook.positions(address(this), key.toId());
        assertEq(collateral, 0, "Position should be deleted after liquidation");
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

    function test_lender_withdrawal() public {
        address lender = makeAddr("lender");
        uint256 amount = 10e18;
        MockERC20(Currency.unwrap(currency0)).mint(lender, amount);

        vm.startPrank(lender);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), amount);
        hook.deposit(currency0, amount);

        assertEq(hook.lenderBalances(lender, currency0), amount);

        hook.withdraw(currency0, amount);
        assertEq(hook.lenderBalances(lender, currency0), 0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(lender), amount);
        vm.stopPrank();
    }

    function test_events() public {
        uint256 collateralProvided = 10e18;
        uint256 borrowAmount = 2e18;

        MockERC20(Currency.unwrap(currency0)).mint(address(this), collateralProvided);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), collateralProvided);

        bytes memory hookData = abi.encode(address(this), borrowAmount);

        vm.expectEmit(true, true, false, false);
        emit SpotMarginHook.PositionOpened(address(this), key.toId(), 0, borrowAmount, currency1, currency0);
        // Note: we use 0 for collateralAmount because we don't know the exact output yet,
        // but forge's expectEmit with 'true' for that field will match any value if we handle it correctly.
        // Actually, let's just check the ones we know.

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
}
