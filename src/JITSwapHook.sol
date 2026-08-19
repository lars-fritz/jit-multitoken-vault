// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/src/types/PoolOperation.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IJITCoordinator } from "./interfaces/IJITCoordinator.sol";

/// @notice Mandatory gate: a swap can execute only inside an active coordinator JIT cycle.
/// @dev Deploy to an address carrying Hooks.BEFORE_SWAP_FLAG (bit 7), normally using HookMiner.
contract JITSwapHook is IHooks, Ownable {
    error CoordinatorOnly();
    error InactiveCycle();
    error PoolManagerOnly();
    error PoolNotRegistered();
    error UnsupportedCallback();
    error ZeroAddress();

    event CoordinatorSet(address indexed coordinator);
    event PoolRegistrationSet(PoolId indexed poolId, bool registered);

    IPoolManager public immutable poolManager;
    IJITCoordinator public coordinator;
    mapping(PoolId poolId => bool) public registeredPool;

    constructor(IPoolManager poolManager_, address initialOwner) Ownable(initialOwner) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert PoolManagerOnly();
        _;
    }

    function permissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    function validateHookAddress() external view {
        Hooks.validateHookPermissions(IHooks(address(this)), permissions());
    }

    function setCoordinator(IJITCoordinator coordinator_) external onlyOwner {
        if (address(coordinator_) == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorSet(address(coordinator_));
    }

    function setPoolRegistered(PoolKey calldata key, bool registered) external onlyOwner {
        if (address(key.hooks) != address(this)) revert PoolNotRegistered();
        PoolId id = key.toId();
        registeredPool[id] = registered;
        emit PoolRegistrationSet(id, registered);
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (!registeredPool[id]) revert PoolNotRegistered();
        if (sender != address(coordinator)) revert CoordinatorOnly();
        if (!coordinator.isActive(id)) revert InactiveCycle();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert UnsupportedCallback();
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

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert UnsupportedCallback();
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

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert UnsupportedCallback();
    }
}

