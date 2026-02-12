// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "./libraries/Hooks.sol";
import {IPoolManager} from "./interfaces/IPoolManager.sol";
import {IHooks} from "./interfaces/IHooks.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "./types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "./types/PoolOperation.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {IERC20Minimal} from "./interfaces/external/IERC20Minimal.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {StateLibrary} from "./libraries/StateLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IOracle {
    /// @notice Returns the sqrt price of token1 in terms of token0: sqrt(token1/token0) * 2^96
    function getSqrtPriceX96(PoolKey calldata key) external view returns (uint160);
}

/// @title SpotMarginHook
/// @notice A Uniswap v4 hook that enables spot margin trading with 0% interest.
contract SpotMarginHook is IHooks, Ownable, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    uint256 public constant MAX_BPS = 10000;
    uint256 public constant LTV_BPS = 7500; // 75% LTV
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8500; // 85%
    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5% bonus to liquidators

    event PositionOpened(address indexed user, PoolId indexed poolId, uint256 collateralAmount, uint256 debtAmount, Currency collateralCurrency, Currency debtCurrency);
    event PositionClosed(address indexed user, PoolId indexed poolId, uint256 collateralReturned, uint256 debtRepaid);
    event Liquidated(address indexed user, address indexed liquidator, PoolId indexed poolId, uint256 collateralTaken, uint256 debtRepaid);
    event Deposit(address indexed lender, Currency indexed currency, uint256 amount);
    event Withdraw(address indexed lender, Currency indexed currency, uint256 amount);

    struct Position {
        uint256 collateralAmount;
        uint256 debtAmount;
        Currency collateralCurrency;
        Currency debtCurrency;
    }

    // user => poolId => Position
    mapping(address => mapping(PoolId => Position)) public positions;

    // lender => currency => balance
    mapping(address => mapping(Currency => uint256)) public lenderBalances;

    // currency => total amount currently lent out
    mapping(Currency => uint256) public totalLent;

    // currency => accumulated collateral from liquidations
    mapping(Currency => uint256) public insuranceFund;

    IOracle public oracle;

    constructor(IPoolManager _manager, address initialOwner) Ownable(initialOwner) {
        manager = _manager;
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = IOracle(_oracle);
    }


    modifier onlyManager() {
        require(msg.sender == address(manager), "Only manager");
        _;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    /// @notice Before a swap, if it's a margin trade, the hook provides the borrowed funds.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata hookData)
        external
        view
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Only handle exact input swaps for margin trading.
        if (hookData.length > 0 && params.amountSpecified < 0) {
            (, uint256 borrowAmount) = abi.decode(hookData, (address, uint256));
            if (borrowAmount > 0) {
                // Return a delta to indicate the hook is providing some of the input tokens.
                // A negative specified delta increases the amount swapped in the pool.
                return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(-int256(borrowAmount)), 0), 0);
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice After a swap, the hook takes the output tokens as collateral and records the position.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyManager returns (bytes4, int128) {
        if (hookData.length > 0 && params.amountSpecified < 0) {
            (address user, uint256 borrowAmount) = abi.decode(hookData, (address, uint256));
            if (borrowAmount > 0) {
                require(positions[user][key.toId()].collateralAmount == 0, "Position already exists");

                Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
                Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

                // Settle the debt the hook took on in beforeSwap
                _settle(inputCurrency, borrowAmount);

                // The output amount from the swap (positive value from pool means Pool owes caller, i.e., output)
                int128 totalOutputAmount = params.zeroForOne ? delta.amount1() : delta.amount0();

                if (totalOutputAmount > 0) {
                    require(address(oracle) != address(0), "Oracle not set");
                    uint256 absOutputAmount = uint256(int256(totalOutputAmount));
                    // Check LTV
                    uint256 collateralValue = getCollateralValue(key, absOutputAmount, outputCurrency, inputCurrency);
                    require(borrowAmount * MAX_BPS <= collateralValue * LTV_BPS, "Exceeds LTV");

                    // We take all output tokens as collateral
                    manager.take(outputCurrency, address(this), uint128(absOutputAmount));

                    positions[user][key.toId()] = Position({
                        collateralAmount: absOutputAmount,
                        debtAmount: borrowAmount,
                        collateralCurrency: outputCurrency,
                        debtCurrency: inputCurrency
                    });

                    totalLent[inputCurrency] += borrowAmount;

                    emit PositionOpened(user, key.toId(), absOutputAmount, borrowAmount, outputCurrency, inputCurrency);

                    // Return the amount we took to offset the swapDelta.
                    // Returning a positive value here means the hook takes that amount from the pool's debt to the caller.
                    return (IHooks.afterSwap.selector, totalOutputAmount);
                }
            }
        }
        return (IHooks.afterSwap.selector, 0);
    }

    function _settle(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            currency.transfer(address(manager), amount);
            manager.settle();
        }
    }

    /// @notice Lenders can deposit funds into the hook.
    function deposit(Currency currency, uint256 amount) external payable {
        if (currency.isAddressZero()) {
            require(msg.value == amount, "Incorrect ETH amount");
        } else {
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        }
        lenderBalances[msg.sender][currency] += amount;
        emit Deposit(msg.sender, currency, amount);
    }

    /// @notice Lenders can withdraw funds from the hook.
    function withdraw(Currency currency, uint256 amount) external {
        require(lenderBalances[msg.sender][currency] >= amount, "Insufficient balance");
        lenderBalances[msg.sender][currency] -= amount;
        currency.transfer(msg.sender, amount);
        emit Withdraw(msg.sender, currency, amount);
    }

    /// @notice Closes a margin position by repaying debt and reclaiming collateral.
    /// @dev 0% interest rate means the debt is the same as when it was opened.
    function closePosition(PoolKey calldata key) external payable nonReentrant {
        PoolId poolId = key.toId();
        Position storage pos = positions[msg.sender][poolId];
        require(pos.collateralAmount > 0, "No active position");

        uint256 debt = pos.debtAmount;
        uint256 collateral = pos.collateralAmount;
        Currency debtCurrency = pos.debtCurrency;
        Currency collateralCurrency = pos.collateralCurrency;

        delete positions[msg.sender][poolId];
        totalLent[debtCurrency] -= debt;

        // User pays debt (0% interest)
        if (debtCurrency.isAddressZero()) {
            require(msg.value >= debt, "Not enough ETH to pay debt");
            if (msg.value > debt) {
                (bool success, ) = payable(msg.sender).call{value: msg.value - debt}("");
                require(success, "Refund failed");
            }
        } else {
            IERC20(Currency.unwrap(debtCurrency)).safeTransferFrom(msg.sender, address(this), debt);
        }

        // Hook returns collateral
        collateralCurrency.transfer(msg.sender, collateral);
        emit PositionClosed(msg.sender, poolId, collateral, debt);
    }

    /// @notice Liquidates an underwater position.
    /// @dev Liquidator no longer pays the debt. Collateral is used to cover the debt.
    /// The debt is returned to the pool (lending pool) via the collateral being kept as insurance.
    function liquidate(address user, PoolKey calldata key) external payable nonReentrant {
        PoolId poolId = key.toId();
        Position storage pos = positions[user][poolId];
        require(pos.collateralAmount > 0, "No active position");

        uint256 healthFactor = getHealthFactor(user, key);
        require(healthFactor < 1 ether, "Position is healthy");

        uint256 debt = pos.debtAmount;
        uint256 collateral = pos.collateralAmount;
        Currency debtCurrency = pos.debtCurrency;
        Currency collateralCurrency = pos.collateralCurrency;

        delete positions[user][poolId];
        totalLent[debtCurrency] -= debt;

        // Bounty for the liquidator (incentive for triggering)
        uint256 bounty = FullMath.mulDiv(collateral, LIQUIDATION_BONUS_BPS, MAX_BPS);

        // Liquidator gets bounty
        collateralCurrency.transfer(msg.sender, bounty);

        // Remaining collateral stays in the hook as insurance/recovery for the debt
        insuranceFund[collateralCurrency] += (collateral - bounty);

        emit Liquidated(user, msg.sender, poolId, bounty, debt);
    }

    function getHealthFactor(address user, PoolKey calldata key) public view returns (uint256) {
        Position storage pos = positions[user][key.toId()];
        if (pos.debtAmount == 0) return type(uint256).max;

        uint256 collateralValue = getCollateralValue(key, pos.collateralAmount, pos.collateralCurrency, pos.debtCurrency);

        // HF = (CollateralValue * LiquidationThreshold * 1e18) / (Debt * MAX_BPS)
        return FullMath.mulDiv(collateralValue, LIQUIDATION_THRESHOLD_BPS * 1e18, pos.debtAmount * MAX_BPS);
    }

    function getCollateralValue(PoolKey calldata key, uint256 amount, Currency collateralCurrency, Currency /* debtCurrency */) public view returns (uint256) {
        require(address(oracle) != address(0), "Oracle not set");
        uint160 sqrtPriceX96 = oracle.getSqrtPriceX96(key);

        if (collateralCurrency == key.currency1) {
            // Collateral is token1, Debt is token0
            // Value in token0 = amount / (token1/token0) = amount * (2^96/sqrtPrice)^2
            uint256 temp = FullMath.mulDiv(amount, 1 << 96, uint256(sqrtPriceX96));
            return FullMath.mulDiv(temp, 1 << 96, uint256(sqrtPriceX96));
        } else {
            // Collateral is token0, Debt is token1
            // Value in token1 = amount * (token1/token0) = amount * (sqrtPrice/2^96)^2
            uint256 temp = FullMath.mulDiv(amount, uint256(sqrtPriceX96), 1 << 96);
            return FullMath.mulDiv(temp, uint256(sqrtPriceX96), 1 << 96);
        }
    }

    receive() external payable {}
}
