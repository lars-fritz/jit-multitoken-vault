// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { SwapParams } from "v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";

import { JITFundVault } from "../src/JITFundVault.sol";
import { JITSwapCoordinator } from "../src/JITSwapCoordinator.sol";
import { JITSwapHook } from "../src/JITSwapHook.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

contract JITSystemTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    IPoolManager internal manager;
    JITFundVault internal vault;
    JITSwapCoordinator internal coordinator;
    JITSwapHook internal hook;
    MockERC20 internal x;
    MockERC20 internal y;
    MockERC20 internal z;
    PoolKey internal xy;
    PoolKey internal xz;
    PoolKey internal yz;

    function setUp() public {
        manager = new PoolManager(address(this));
        x = new MockERC20("X", "X");
        y = new MockERC20("Y", "Y");
        z = new MockERC20("Z", "Z");

        address[3] memory assets = [address(x), address(y), address(z)];
        vault = new JITFundVault(assets, address(this));
        coordinator = new JITSwapCoordinator(manager, vault, address(this));

        // V4 dispatches callbacks from address bits. Foundry places the fully
        // constructed hook at a deterministic address carrying BEFORE_SWAP_FLAG.
        address hookAddress = address(uint160(0x10000 | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("JITSwapHook.sol:JITSwapHook", abi.encode(manager, address(this)), hookAddress);
        hook = JITSwapHook(hookAddress);
        hook.validateHookAddress();
        hook.setCoordinator(coordinator);
        vault.setCoordinator(address(coordinator));

        xy = _initializePair(x, y);
        xz = _initializePair(x, z);
        yz = _initializePair(y, z);
        _configurePair(xy);
        _configurePair(xz);
        _configurePair(yz);

        uint256 initial = 1_000_000 ether;
        x.mint(address(this), initial);
        y.mint(address(this), initial);
        z.mint(address(this), initial);
        x.approve(address(vault), type(uint256).max);
        y.approve(address(vault), type(uint256).max);
        z.approve(address(vault), type(uint256).max);
        vault.bootstrap([initial, initial, initial], 1_000_000 ether, address(this));

        x.mint(alice, 100_000 ether);
        y.mint(alice, 100_000 ether);
        z.mint(alice, 100_000 ether);
        vm.startPrank(alice);
        x.approve(address(coordinator), type(uint256).max);
        y.approve(address(coordinator), type(uint256).max);
        z.approve(address(coordinator), type(uint256).max);
        vm.stopPrank();
    }

    function testProportionalDepositAndWithdrawal() public {
        x.mint(bob, 100_000 ether);
        y.mint(bob, 120_000 ether);
        z.mint(bob, 110_000 ether);
        vm.startPrank(bob);
        x.approve(address(vault), type(uint256).max);
        y.approve(address(vault), type(uint256).max);
        z.approve(address(vault), type(uint256).max);
        (uint256 shares, uint256[3] memory accepted) = vault.depositBasket(
            [uint256(100_000 ether), 120_000 ether, 110_000 ether], 100_000 ether, bob
        );
        assertEq(shares, 100_000 ether);
        assertEq(accepted[0], 100_000 ether);
        assertEq(accepted[1], 100_000 ether);
        assertEq(accepted[2], 100_000 ether);

        vault.withdrawBasket(shares, [uint256(0), 0, 0], bob);
        vm.stopPrank();
        assertEq(x.balanceOf(address(vault)), 1_000_000 ether);
        assertEq(y.balanceOf(address(vault)), 1_000_000 ether);
        assertEq(z.balanceOf(address(vault)), 1_000_000 ether);
    }

    function testAtomicJITSwapReturnsAllLiquidityToVault() public {
        uint256 xBefore = x.balanceOf(address(vault));
        uint256 yBefore = y.balanceOf(address(vault));
        uint256 aliceYBefore = y.balanceOf(alice);

        vm.prank(alice);
        uint256 amountOut = _swap(xy, address(x), address(y), 10_000 ether, alice);

        assertGt(amountOut, 0);
        assertEq(y.balanceOf(alice), aliceYBefore + amountOut);
        // Add/remove liquidity can leave a couple of wei in PoolManager because
        // the core deliberately rounds token amounts in opposite directions.
        assertApproxEqAbs(x.balanceOf(address(vault)), xBefore + 10_000 ether, 2);
        assertApproxEqAbs(y.balanceOf(address(vault)), yBefore - amountOut, 2);
        assertEq(x.balanceOf(address(coordinator)), 0);
        assertEq(y.balanceOf(address(coordinator)), 0);
        assertFalse(vault.activeOperation());
        assertFalse(coordinator.isActive(xy.toId()));
    }

    function testCrossPairSequence() public {
        vm.startPrank(alice);
        uint256 outY1 = _swap(xy, address(x), address(y), 5_000 ether, alice);
        uint256 outY2 = _swap(yz, address(z), address(y), 7_000 ether, alice);
        uint256 backX = _swap(xy, address(y), address(x), outY1 / 2, alice);
        vm.stopPrank();

        assertGt(outY1, 0);
        assertGt(outY2, 0);
        assertGt(backX, 0);
        assertGt(x.balanceOf(address(vault)), 0);
        assertGt(y.balanceOf(address(vault)), 0);
        assertGt(z.balanceOf(address(vault)), 0);
        assertFalse(vault.activeOperation());
    }

    function testDirectSwapBypassReverts() public {
        PoolSwapTest bypassRouter = new PoolSwapTest(manager);
        x.mint(address(this), 1_000 ether);
        x.approve(address(bypassRouter), type(uint256).max);
        SwapParams memory params = SwapParams({
            zeroForOne: Currency.unwrap(xy.currency0) == address(x),
            amountSpecified: -int256(100 ether),
            sqrtPriceLimitX96: Currency.unwrap(xy.currency0) == address(x)
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.expectRevert();
        bypassRouter.swap(xy, params, PoolSwapTest.TestSettings(false, false), bytes(""));
    }

    function testTradeAboveInventoryCapRevertsAndUnlocksVault() public {
        vm.prank(alice);
        vm.expectRevert(JITSwapCoordinator.TradeTooLarge.selector);
        _swap(xy, address(x), address(y), 100_001 ether, alice);
        assertFalse(vault.activeOperation());
        assertEq(x.balanceOf(address(vault)), 1_000_000 ether);
        assertEq(y.balanceOf(address(vault)), 1_000_000 ether);
    }

    function testTerminalTickLimitRejectsPartialFill() public {
        coordinator.setPoolRiskConfig(xy, true, 1200, 60, 1000);
        vm.prank(alice);
        vm.expectRevert(JITSwapCoordinator.PartialFill.selector);
        _swap(xy, address(x), address(y), 100_000 ether, alice);
        assertFalse(vault.activeOperation());
        assertEq(x.balanceOf(address(vault)), 1_000_000 ether);
        assertEq(y.balanceOf(address(vault)), 1_000_000 ether);
    }

    function testTraderCannotChooseRangeOrPriceLimit() public pure {
        assertEq(
            JITSwapCoordinator.swapExactIn.selector,
            bytes4(
                keccak256(
                    "swapExactIn((address,address,uint24,int24,address),bool,uint256,uint256,address)"
                )
            )
        );
    }

    function _initializePair(MockERC20 a, MockERC20 b) internal returns (PoolKey memory key) {
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        key = PoolKey(c0, c1, FEE, TICK_SPACING, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.setPoolRegistered(key, true);
    }

    function _configurePair(PoolKey memory key) internal {
        coordinator.setPoolRiskConfig(key, true, 1200, 600, 1000);
    }

    function _swap(
        PoolKey memory key,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256) {
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        assertEq(Currency.unwrap(zeroForOne ? key.currency1 : key.currency0), tokenOut);
        return coordinator.swapExactIn(key, zeroForOne, amountIn, 1, recipient);
    }
}
