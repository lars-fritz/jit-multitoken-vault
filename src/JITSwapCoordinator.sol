// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
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
        uint128 lowerLiquidity,
        uint128 upperLiquidity,
        int24 lowerTick,
        int24 upperTick
    );
    event PoolRiskConfigSet(
        PoolId indexed poolId,
        bool enabled,
        int24 baseHalfWidthTicks,
        int24 maxHalfWidthTicks,
        int24 maxTickMove,
        uint16 maxTradeBps,
        uint16 volatilityWidthFactorBps,
        uint16 inventorySkewFactorBps,
        uint16 primaryTokenAllocationBps,
        int24 overlapTicks
    );

    struct PoolRiskConfig {
        bool enabled;
        int24 baseHalfWidthTicks;
        int24 maxHalfWidthTicks;
        int24 maxTickMove;
        uint16 maxTradeBps;
        uint16 volatilityWidthFactorBps;
        uint16 inventorySkewFactorBps;
        uint16 primaryTokenAllocationBps;
        int24 overlapTicks;
    }

    struct Request {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minAmountOut;
        uint160 sqrtPriceLimitX96;
        int24 lowerTickLower;
        int24 lowerTickUpper;
        int24 upperTickLower;
        int24 upperTickUpper;
        address trader;
        address recipient;
        uint256 vaultAmount0;
        uint256 vaultAmount1;
        uint16 primaryTokenAllocationBps;
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
        int24 baseHalfWidthTicks,
        int24 maxHalfWidthTicks,
        int24 maxTickMove,
        uint16 maxTradeBps,
        uint16 volatilityWidthFactorBps,
        uint16 inventorySkewFactorBps,
        uint16 primaryTokenAllocationBps,
        int24 overlapTicks
    ) external onlyOwner {
        if (
            baseHalfWidthTicks <= 0 || baseHalfWidthTicks % key.tickSpacing != 0
                || maxHalfWidthTicks < baseHalfWidthTicks
                || maxHalfWidthTicks % key.tickSpacing != 0 || maxTickMove <= 0
                || maxTickMove >= baseHalfWidthTicks || maxTradeBps == 0 || maxTradeBps > 10_000
                || inventorySkewFactorBps > 10_000 || primaryTokenAllocationBps < 5_000
                || primaryTokenAllocationBps > 10_000 || overlapTicks <= 0
                || overlapTicks % key.tickSpacing != 0 || overlapTicks >= baseHalfWidthTicks
        ) revert BadRange();
        PoolId id = key.toId();
        poolRiskConfig[id] = PoolRiskConfig({
            enabled: enabled,
            baseHalfWidthTicks: baseHalfWidthTicks,
            maxHalfWidthTicks: maxHalfWidthTicks,
            maxTickMove: maxTickMove,
            maxTradeBps: maxTradeBps,
            volatilityWidthFactorBps: volatilityWidthFactorBps,
            inventorySkewFactorBps: inventorySkewFactorBps,
            primaryTokenAllocationBps: primaryTokenAllocationBps,
            overlapTicks: overlapTicks
        });
        emit PoolRiskConfigSet(
            id,
            enabled,
            baseHalfWidthTicks,
            maxHalfWidthTicks,
            maxTickMove,
            maxTradeBps,
            volatilityWidthFactorBps,
            inventorySkewFactorBps,
            primaryTokenAllocationBps,
            overlapTicks
        );
    }

    function isActive(PoolId poolId) external view override returns (bool) {
        return activePool[poolId];
    }

    function previewExecutionBounds(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (
            int24 lowerTickLower,
            int24 lowerTickUpper,
            int24 upperTickLower,
            int24 upperTickUpper,
            uint160 sqrtPriceLimitX96
        )
    {
        PoolRiskConfig memory risk = poolRiskConfig[key.toId()];
        if (!risk.enabled) revert PoolDisabled();
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        return _executionBounds(
            key,
            zeroForOne,
            risk,
            vault.relativeVolatilityBps(currency0, currency1),
            vault.relativeImbalanceBps(currency0, currency1)
        );
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

        PoolId id = key.toId();
        PoolRiskConfig memory risk = poolRiskConfig[id];
        if (!risk.enabled) revert PoolDisabled();
        uint256 volatilityBps = vault.relativeVolatilityBps(currency0, currency1);
        int256 imbalanceBps = vault.relativeImbalanceBps(currency0, currency1);
        (
            int24 lowerTickLower,
            int24 lowerTickUpper,
            int24 upperTickLower,
            int24 upperTickUpper,
            uint160 sqrtPriceLimitX96
        ) = _executionBounds(key, zeroForOne, risk, volatilityBps, imbalanceBps);

        (uint256 vaultAmount0, uint256 vaultAmount1) = vault.beginOperation(currency0, currency1);
        address tokenIn = zeroForOne ? currency0 : currency1;
        uint256 inputInventory = zeroForOne ? vaultAmount0 : vaultAmount1;
        if (amountIn > (inputInventory * risk.maxTradeBps) / 10_000) revert TradeTooLarge();
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (activePool[id]) revert NotActive();
        activePool[id] = true;
        bytes32 salt = keccak256(abi.encodePacked(address(this), ++nonce));
        Request memory request = Request({
            key: key,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            lowerTickLower: lowerTickLower,
            lowerTickUpper: lowerTickUpper,
            upperTickLower: upperTickLower,
            upperTickUpper: upperTickUpper,
            trader: msg.sender,
            recipient: recipient,
            vaultAmount0: vaultAmount0,
            vaultAmount1: vaultAmount1,
            primaryTokenAllocationBps: risk.primaryTokenAllocationBps,
            salt: salt
        });

        uint128 lowerLiquidity;
        uint128 upperLiquidity;
        (amountOut, lowerLiquidity, upperLiquidity) =
            abi.decode(poolManager.unlock(abi.encode(request)), (uint256, uint128, uint128));
        activePool[id] = false;

        address tokenOut = zeroForOne ? currency1 : currency0;
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        _returnBalance(currency0);
        _returnBalance(currency1);
        vault.endOperation(currency0, currency1);

        emit JITSwap(
            id,
            msg.sender,
            recipient,
            tokenIn,
            amountIn,
            amountOut,
            lowerLiquidity,
            upperLiquidity,
            lowerTickLower,
            upperTickUpper
        );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackOnly();
        Request memory request = abi.decode(data, (Request));
        PoolId id = request.key.toId();
        if (!activePool[id]) revert NotActive();

        (uint128 lowerLiquidity, uint128 upperLiquidity) = _liquiditiesFor(request);
        if (lowerLiquidity == 0 || upperLiquidity == 0) revert InsufficientLiquidity();
        ModifyLiquidityParams memory lowerPosition = ModifyLiquidityParams({
            tickLower: request.lowerTickLower,
            tickUpper: request.lowerTickUpper,
            liquidityDelta: int256(uint256(lowerLiquidity)),
            salt: request.salt
        });
        ModifyLiquidityParams memory upperPosition = ModifyLiquidityParams({
            tickLower: request.upperTickLower,
            tickUpper: request.upperTickUpper,
            liquidityDelta: int256(uint256(upperLiquidity)),
            salt: keccak256(abi.encode(request.salt, uint256(1)))
        });
        poolManager.modifyLiquidity(request.key, lowerPosition, bytes(""));
        poolManager.modifyLiquidity(request.key, upperPosition, bytes(""));

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

        lowerPosition.liquidityDelta = -int256(uint256(lowerLiquidity));
        upperPosition.liquidityDelta = -int256(uint256(upperLiquidity));
        poolManager.modifyLiquidity(request.key, lowerPosition, bytes(""));
        poolManager.modifyLiquidity(request.key, upperPosition, bytes(""));
        _resolve(request.key.currency0);
        _resolve(request.key.currency1);
        return abi.encode(amountOut, lowerLiquidity, upperLiquidity);
    }

    function _executionBounds(
        PoolKey calldata key,
        bool zeroForOne,
        PoolRiskConfig memory risk,
        uint256 volatilityBps,
        int256 imbalanceBps
    )
        internal
        view
        returns (
            int24 lowerTickLower,
            int24 lowerTickUpper,
            int24 upperTickLower,
            int24 upperTickUpper,
            uint160 sqrtPriceLimitX96
        )
    {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 spacing = key.tickSpacing;
        int24 centerTick = _floorToSpacing(currentTick, spacing);

        uint256 widthMultiplierBps =
            10_000 + (volatilityBps * risk.volatilityWidthFactorBps) / 10_000;
        uint256 volatilityWidth =
            (uint256(uint24(risk.baseHalfWidthTicks)) * widthMultiplierBps) / 10_000;
        volatilityWidth = Math.min(volatilityWidth, uint256(uint24(risk.maxHalfWidthTicks)));

        uint256 absoluteImbalance = uint256(imbalanceBps < 0 ? -imbalanceBps : imbalanceBps);
        uint256 skewBps = (absoluteImbalance * risk.inventorySkewFactorBps) / 10_000;
        skewBps = Math.min(skewBps, 8_000);
        uint256 downWidth = imbalanceBps >= 0
            ? (volatilityWidth * (10_000 + skewBps)) / 10_000
            : (volatilityWidth * (10_000 - skewBps)) / 10_000;
        uint256 upWidth = imbalanceBps >= 0
            ? (volatilityWidth * (10_000 - skewBps)) / 10_000
            : (volatilityWidth * (10_000 + skewBps)) / 10_000;

        int24 minimumWidth = risk.overlapTicks + spacing;
        int24 down = _boundedAlignedWidth(downWidth, minimumWidth, risk.maxHalfWidthTicks, spacing);
        int24 up = _boundedAlignedWidth(upWidth, minimumWidth, risk.maxHalfWidthTicks, spacing);
        lowerTickLower = centerTick - down;
        lowerTickUpper = centerTick + risk.overlapTicks;
        upperTickLower = centerTick - risk.overlapTicks;
        upperTickUpper = centerTick + up;
        if (lowerTickLower < TickMath.MIN_TICK || upperTickUpper > TickMath.MAX_TICK) {
            revert BadRange();
        }

        int24 limitTick =
            zeroForOne ? currentTick - risk.maxTickMove : currentTick + risk.maxTickMove;
        if (limitTick <= lowerTickLower || limitTick >= upperTickUpper) revert BadRange();
        sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(limitTick);
    }

    function _liquiditiesFor(Request memory request)
        internal
        view
        returns (uint128 lowerLiquidity, uint128 upperLiquidity)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(request.key.toId());
        if (
            tick < request.lowerTickLower || tick >= request.lowerTickUpper
                || tick < request.upperTickLower || tick >= request.upperTickUpper
        ) revert BadRange();

        uint256 secondaryBps = 10_000 - request.primaryTokenAllocationBps;
        uint256 lowerAmount0 = (request.vaultAmount0 * secondaryBps) / 10_000;
        uint256 lowerAmount1 = (request.vaultAmount1 * request.primaryTokenAllocationBps) / 10_000;
        uint256 upperAmount0 = request.vaultAmount0 - lowerAmount0;
        uint256 upperAmount1 = request.vaultAmount1 - lowerAmount1;

        lowerLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(request.lowerTickLower),
            TickMath.getSqrtPriceAtTick(request.lowerTickUpper),
            lowerAmount0,
            lowerAmount1
        );
        upperLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(request.upperTickLower),
            TickMath.getSqrtPriceAtTick(request.upperTickUpper),
            upperAmount0,
            upperAmount1
        );
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24 compressed) {
        compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;
        compressed *= spacing;
    }

    function _boundedAlignedWidth(uint256 width, int24 minimum, int24 maximum, int24 spacing)
        internal
        pure
        returns (int24)
    {
        uint256 bounded = Math.max(width, uint256(uint24(minimum)));
        bounded = Math.min(bounded, uint256(uint24(maximum)));
        uint256 spacingUnsigned = uint256(uint24(spacing));
        bounded = ((bounded + spacingUnsigned - 1) / spacingUnsigned) * spacingUnsigned;
        if (bounded > uint256(uint24(maximum))) bounded = uint256(uint24(maximum));
        return int24(uint24(bounded));
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
