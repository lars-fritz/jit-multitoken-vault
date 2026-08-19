// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/src/libraries/TransientStateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/src/types/PoolOperation.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

import { JITFundVault } from "./JITFundVault.sol";
import { IJITCoordinator } from "./interfaces/IJITCoordinator.sol";

/// @notice Atomic add-liquidity -> swap -> remove-liquidity coordinator.
/// @dev Exact-input ERC20 pairs only. Execution bounds come from owner-controlled pool risk settings.
contract JITSwapCoordinator is IUnlockCallback, IJITCoordinator, ReentrancyGuard, Ownable {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    error BadPair();
    error BadRange();
    error CallbackOnly();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error NativeCurrencyUnsupported();
    error NotActive();
    error PartialFill();
    error PoolDisabled();
    error TradeTooLarge();

    event JITSwap(
        PoolId indexed poolId,
        address indexed trader,
        address indexed recipient,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    event PoolRiskConfigSet(
        PoolId indexed poolId,
        bool enabled,
        int24 rangeHalfWidthTicks,
        int24 maxTickMove,
        uint16 maxTradeBps
    );

    struct PoolRiskConfig {
        bool enabled;
        int24 rangeHalfWidthTicks;
        int24 maxTickMove;
        uint16 maxTradeBps;
    }

    struct Request {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
        uint160 sqrtPriceLimitX96;
        int24 tickLower;
        int24 tickUpper;
        address trader;
        address recipient;
        uint256 vaultAmount0;
        uint256 vaultAmount1;
        bytes32 salt;
    }

    IPoolManager public immutable poolManager;
    JITFundVault public immutable vault;
    mapping(PoolId poolId => bool) private activePool;
    mapping(PoolId poolId => PoolRiskConfig) public poolRiskConfig;
    uint256 public nonce;

    constructor(IPoolManager poolManager_, JITFundVault vault_, address initialOwner)
        Ownable(initialOwner)
    {
        poolManager = poolManager_;
        vault = vault_;
    }

    function setPoolRiskConfig(
        PoolKey calldata key,
        bool enabled,
        int24 rangeHalfWidthTicks,
        int24 maxTickMove,
        uint16 maxTradeBps
    ) external onlyOwner {
        if (
            rangeHalfWidthTicks <= 0 || rangeHalfWidthTicks % key.tickSpacing != 0
                || maxTickMove <= 0 || maxTickMove >= rangeHalfWidthTicks || maxTradeBps == 0
                || maxTradeBps > 10_000
        ) revert BadRange();
        PoolId id = key.toId();
        poolRiskConfig[id] = PoolRiskConfig(enabled, rangeHalfWidthTicks, maxTickMove, maxTradeBps);
        emit PoolRiskConfigSet(id, enabled, rangeHalfWidthTicks, maxTickMove, maxTradeBps);
    }

    function isActive(PoolId poolId) external view override returns (bool) {
        return activePool[poolId];
    }

    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 == address(0) || currency1 == address(0)) revert NativeCurrencyUnsupported();
        if (recipient == address(0) || amountIn == 0) revert BadPair();

        (uint256 vaultAmount0, uint256 vaultAmount1) = vault.beginOperation(currency0, currency1);
        address tokenIn = zeroForOne ? currency0 : currency1;
        PoolId id = key.toId();
        PoolRiskConfig memory risk = poolRiskConfig[id];
        if (!risk.enabled) revert PoolDisabled();
        uint256 inputInventory = zeroForOne ? vaultAmount0 : vaultAmount1;
        if (amountIn > (inputInventory * risk.maxTradeBps) / 10_000) revert TradeTooLarge();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (activePool[id]) revert NotActive();
        activePool[id] = true;
        (int24 tickLower, int24 tickUpper, uint160 sqrtPriceLimitX96) =
            _executionBounds(key, zeroForOne, risk);
        bytes32 salt = keccak256(abi.encodePacked(address(this), ++nonce));
        Request memory request = Request({
            key: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            tickLower: tickLower,
            tickUpper: tickUpper,
            trader: msg.sender,
            recipient: recipient,
            vaultAmount0: vaultAmount0,
            vaultAmount1: vaultAmount1,
            salt: salt
        });

        uint128 liquidity;
        (amountOut, liquidity) =
            abi.decode(poolManager.unlock(abi.encode(request)), (uint256, uint128));
        activePool[id] = false;

        address tokenOut = zeroForOne ? currency1 : currency0;
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        _returnBalance(currency0);
        _returnBalance(currency1);
        vault.endOperation(currency0, currency1);

        emit JITSwap(
            id, msg.sender, recipient, tokenIn, amountIn, amountOut, liquidity, tickLower, tickUpper
        );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackOnly();
        Request memory request = abi.decode(data, (Request));
        PoolId id = request.key.toId();
        if (!activePool[id]) revert NotActive();

        uint128 liquidity = _liquidityFor(request);
        if (liquidity == 0) revert InsufficientLiquidity();
        ModifyLiquidityParams memory position = ModifyLiquidityParams({
            tickLower: request.tickLower,
            tickUpper: request.tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: request.salt
        });
        poolManager.modifyLiquidity(request.key, position, bytes(""));

        BalanceDelta swapDelta = poolManager.swap(
            request.key,
            SwapParams({
                zeroForOne: request.zeroForOne,
                amountSpecified: -int256(request.amountIn),
                sqrtPriceLimitX96: request.sqrtPriceLimitX96
            }),
            bytes("")
        );
        int128 rawIn = request.zeroForOne ? swapDelta.amount0() : swapDelta.amount1();
        if (int256(rawIn) != -int256(request.amountIn)) revert PartialFill();
        int128 rawOut = request.zeroForOne ? swapDelta.amount1() : swapDelta.amount0();
        if (rawOut <= 0) revert InsufficientOutput();
        uint256 amountOut = uint128(rawOut);
        if (amountOut < request.minAmountOut) revert InsufficientOutput();

        position.liquidityDelta = -int256(uint256(liquidity));
        poolManager.modifyLiquidity(request.key, position, bytes(""));
        _resolve(request.key.currency0);
        _resolve(request.key.currency1);
        return abi.encode(amountOut, liquidity);
    }

    function _executionBounds(PoolKey calldata key, bool zeroForOne, PoolRiskConfig memory risk)
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint160 sqrtPriceLimitX96)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 centerTick = (currentTick / key.tickSpacing) * key.tickSpacing;
        tickLower = centerTick - risk.rangeHalfWidthTicks;
        tickUpper = centerTick + risk.rangeHalfWidthTicks;
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert BadRange();

        int24 limitTick =
            zeroForOne ? currentTick - risk.maxTickMove : currentTick + risk.maxTickMove;
        if (limitTick <= tickLower || limitTick >= tickUpper) revert BadRange();
        sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(limitTick);
    }

    function _liquidityFor(Request memory request) internal view returns (uint128 liquidity) {
        if (
            request.tickLower >= request.tickUpper
                || request.tickLower % request.key.tickSpacing != 0
                || request.tickUpper % request.key.tickSpacing != 0
        ) revert BadRange();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(request.key.toId());
        if (tick < request.tickLower || tick >= request.tickUpper) revert BadRange();
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(request.tickLower),
            TickMath.getSqrtPriceAtTick(request.tickUpper),
            request.vaultAmount0,
            request.vaultAmount1
        );
    }

    function _resolve(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 amount = uint256(-delta);
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }

    function _returnBalance(address token) internal {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(address(vault), amount);
    }
}
