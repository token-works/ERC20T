// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockV4Router} from "@uniswap/v4-periphery/test/mocks/MockV4Router.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20T_TICK_SPACING} from "../../src/ERC20T/ERC20TInterfaces.sol";
import {TokenPosmHelper} from "../support/TokenPosmHelper.sol";
import {ERC20TRejectingFeeRecipient, ERC20TReentrantFeeRecipient} from "./ERC20T.t.sol";

/// @dev Minimal exact-input two-hop router. Intermediate X is netted inside PoolManager;
/// the last token is taken directly to the trader, with no distributor exemption.
contract ERC20TAtomicRoute is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct Route {
        address trader;
        ERC20T x;
        ERC20T y;
        bool buy;
        uint256 amountIn;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(ERC20T x, ERC20T y, bool buy, uint256 amountIn) external payable returns (uint256 amountOut) {
        amountOut = abi.decode(manager.unlock(abi.encode(Route(msg.sender, x, y, buy, amountIn))), (uint256));
        uint256 refund = address(this).balance;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Route memory route = abi.decode(data, (Route));
        Currency xCurrency = Currency.wrap(address(route.x));
        Currency yCurrency = Currency.wrap(address(route.y));
        Currency native = Currency.wrap(address(0));
        uint256 intermediate = route.buy
            ? _swap(route.x.poolKey(), native, route.amountIn)
            : _swap(route.y.poolKey(), yCurrency, route.amountIn);
        uint256 amountOut = route.buy
            ? _swap(route.y.poolKey(), xCurrency, intermediate)
            : _swap(route.x.poolKey(), xCurrency, intermediate);
        require(manager.currencyDelta(address(this), xCurrency) == 0, "intermediate X did not net");
        if (route.buy) {
            manager.settle{value: route.amountIn}();
            manager.take(yCurrency, route.trader, amountOut);
        } else {
            manager.sync(yCurrency);
            route.y.transferFrom(route.trader, address(manager), route.amountIn);
            manager.settle();
            manager.take(native, route.trader, amountOut);
        }
        return abi.encode(amountOut);
    }

    function _swap(PoolKey memory key, Currency input, uint256 amountIn) private returns (uint256 amountOut) {
        bool zeroForOne = Currency.unwrap(input) == Currency.unwrap(key.currency0);
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        require(uint256(-int256(inputDelta)) == amountIn, "partial route input");
        amountOut = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
    }
}

contract ERC20TCrossPairTest is Deployers, TokenPosmHelper {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LP_SUPPLY = 800_000_000 ether;
    bytes32 constant FEE_EVENT = keccak256("HookFee(address,address,address,uint256,uint256)");
    bytes32 constant PROTOCOL_EVENT = keccak256("ProtocolFee(address,address,address,uint256)");
    bytes32 constant DECAY_EVENT = keccak256("FeeDecay(address,address,address,uint256)");
    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    struct RouteFees {
        uint256[2] tokenEth;
        uint256[2] protocolEth;
        uint256[2] decayEth;
        uint256[2] tokenEvents;
        uint256[2] protocolEvents;
        uint256[2] decayEvents;
        uint256 swaps;
    }

    ERC20THook hook;
    ERC20TFactory factory;
    ERC20TAtomicRoute router;
    ERC20T x;
    ERC20T y0;
    ERC20T y1;
    address alice = makeAddr("crossPairAlice");
    address bob = makeAddr("crossPairBob");
    address xFees = makeAddr("xFees");
    address protocolFees = makeAddr("crossPairProtocolFees");
    address y0Fees = makeAddr("y0Fees");
    address y1Fees = makeAddr("y1Fees");
    address xDecayFees = makeAddr("xDecayFees");
    address yDecayFees = makeAddr("yDecayFees");
    address parentSeeder = makeAddr("parentSeeder");

    function setUp() public {
        deployFreshManagerAndRouters();
        _deployPosm(manager);
        hook = _deployHook();
        factory = new ERC20TFactory();
        router = new ERC20TAtomicRoute(manager);
        x = factory.create(_config(address(0), 100, xFees));
        x.launch(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
        x.setPairingEnabled(true);
        y0 = _deployChild(true, 300, y0Fees);
        y1 = _deployChild(false, 500, y1Fees);
        _launchChild(y0);
        _launchChild(y1);
        vm.deal(address(this), 100 ether);
        vm.deal(alice, 10 ether);
        vm.deal(address(manager), 100 ether);
    }

    function _deployHook() internal returns (ERC20THook deployed) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, address(this), protocolFees, new ERC20THook.ExternalBaseConfig[](0), address(0))
        );
        vm.prank(CREATE2_DEPLOYER);
        deployed = new ERC20THook{salt: salt}(
            manager, address(this), protocolFees, new ERC20THook.ExternalBaseConfig[](0), address(0)
        );
        assertEq(address(deployed), expected);
    }

    function _config(address quote, uint16 tax, address recipient) internal view returns (ERC20T.Config memory) {
        return ERC20T.Config({
            name: "Cross Pair Token",
            symbol: "PAIR",
            supply: SUPPLY,
            lpSupply: LP_SUPPLY,
            owner: address(this),
            hook: address(hook),
            quoteToken: quote,
            positionManager: posm,
            permit2: IAllowanceTransfer(PERMIT2_ADDR),
            taxBps: tax,
            feeRecipient: recipient,
            feeDecayRecipient: address(0),
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0
        });
    }

    function _deployChild(bool childIsCurrency0, uint16 tax, address recipient) internal returns (ERC20T child) {
        return _deployChild(childIsCurrency0, _config(address(x), tax, recipient));
    }

    function _deployChild(bool childIsCurrency0, ERC20T.Config memory config) internal returns (ERC20T child) {
        address implementation = factory.implementation();
        bytes memory args = abi.encodePacked(
            config.hook,
            config.quoteToken,
            address(config.positionManager.poolManager()),
            address(config.positionManager),
            address(config.permit2)
        );
        bytes32 initCodeHash = LibClone.initCodeHash(implementation, args);
        for (uint256 i; i < 1_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = LibClone.predictDeterministicAddress(initCodeHash, salt, address(this));
            if ((predicted < address(x)) == childIsCurrency0) {
                child = ERC20T(LibClone.cloneDeterministic(implementation, args, salt));
                child.initialize(config);
                assertEq(address(child), predicted);
                return child;
            }
        }
        revert("could not select token ordering");
    }

    function _launchChild(ERC20T child) internal {
        if (address(child) < child.quoteToken()) {
            child.launch(SQRT_PRICE_1_1, 0, TickMath.maxUsableTick(ERC20T_TICK_SPACING));
        } else {
            child.launch(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
        }
    }

    function _hookError(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _expectInitAndLaunchFailure(ERC20T child, bytes4 reason) internal {
        PoolKey memory poolKey = child.poolKey();
        bool childIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(child);
        int24 lower = childIsCurrency0 ? int24(0) : TickMath.minUsableTick(ERC20T_TICK_SPACING);
        int24 upper = childIsCurrency0 ? TickMath.maxUsableTick(ERC20T_TICK_SPACING) : int24(0);
        bytes memory expected = _hookError(IHooks.beforeInitialize.selector, reason);
        vm.expectRevert(expected);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        // PositionManager's initializer catches hook errors. The subsequent mint then
        // fails because initialization did not succeed; the full launch rolls back.
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        child.launch(SQRT_PRICE_1_1, lower, upper);
        assertFalse(child.launched());
        assertFalse(hook.poolInitialized(address(child)));
    }

    function _assertNoSettlementResidue(ERC20T child) internal view {
        assertEq(x.balanceOf(address(router)), 0);
        assertEq(child.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(x.balanceOf(address(hook)), 0);
        assertEq(child.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(x.getTransferAllowance(false), 0);
        assertEq(x.getTransferAllowance(true), 0);
        assertEq(child.getTransferAllowance(false), 0);
        assertEq(child.getTransferAllowance(true), 0);
        assertEq(x.getNetTransferAllowance(), 0);
        assertEq(child.getNetTransferAllowance(), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(x))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(child))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
    }

    function _seedParent(uint256 ethIn) internal {
        PoolKey memory parentKey = x.poolKey();
        vm.deal(parentSeeder, ethIn);
        vm.prank(parentSeeder);
        swapRouter.swap{value: ethIn}(
            parentKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertGt(x.balanceOf(parentSeeder), 0);
    }

    function _assertRouteFeeEvents(
        ERC20T child,
        uint256 parentFeeBefore,
        uint256 childFeeBefore,
        uint256 protocolFeeBefore,
        bool buy
    ) internal returns (RouteFees memory fees) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) ++fees.swaps;
            if (logs[i].emitter != address(hook)) continue;
            bool tokenEvent = logs[i].topics[0] == FEE_EVENT;
            bool protocolEvent = logs[i].topics[0] == PROTOCOL_EVENT;
            bool decayEvent = logs[i].topics[0] == DECAY_EVENT;
            if (!tokenEvent && !protocolEvent && !decayEvent) continue;
            address primary = address(uint160(uint256(logs[i].topics[1])));
            uint256 index = primary == address(x) ? 0 : 1;
            if (index == 1) assertEq(primary, address(child));
            address recipient = address(uint160(uint256(logs[i].topics[3])));
            if (tokenEvent) {
                assertEq(recipient, index == 0 ? xFees : child.feeRecipient());
                (, fees.tokenEth[index]) = abi.decode(logs[i].data, (uint256, uint256));
                ++fees.tokenEvents[index];
            } else if (protocolEvent) {
                assertEq(recipient, protocolFees);
                fees.protocolEth[index] = abi.decode(logs[i].data, (uint256));
                ++fees.protocolEvents[index];
            } else {
                assertEq(recipient, index == 0 ? x.feeDecayRecipient() : child.feeDecayRecipient());
                fees.decayEth[index] = abi.decode(logs[i].data, (uint256));
                ++fees.decayEvents[index];
            }
        }
        for (uint256 i; i < 2; ++i) {
            assertEq(fees.tokenEvents[i], 1);
            assertEq(fees.protocolEvents[i], 1);
            uint256 totalEth = fees.tokenEth[i] + fees.protocolEth[i] + fees.decayEth[i];
            uint256 rate = i == 0 ? x.taxBps() : child.taxBps();
            uint256 restingRate = i == 0 ? x.restingTaxBps() : child.restingTaxBps();
            assertEq(fees.protocolEth[i], totalEth * 15 / rate);
            assertEq(fees.decayEth[i], totalEth * (rate - restingRate) / rate);
            assertEq(fees.decayEvents[i], fees.decayEth[i] == 0 ? 0 : 1);
            assertEq(fees.tokenEth[i], totalEth - fees.protocolEth[i] - fees.decayEth[i]);
            assertGt(fees.tokenEth[i], 0);
            assertGt(fees.protocolEth[i], 0);
        }
        assertEq(xFees.balance - parentFeeBefore, fees.tokenEth[0]);
        assertEq(child.feeRecipient().balance - childFeeBefore, fees.tokenEth[1]);
        assertEq(protocolFees.balance - protocolFeeBefore, fees.protocolEth[0] + fees.protocolEth[1]);
        // Two outer swaps, with each combined fee converted only once at each required pool.
        // No extra conversion or recursive tax is introduced by splitting the ETH proceeds.
        assertEq(fees.swaps, buy ? 5 : 3);
    }

    function _roundTrip(ERC20T child) internal {
        address childFees = child.feeRecipient();
        uint256 xEthFeesBefore = xFees.balance;
        uint256 childFeesBefore = childFees.balance;
        uint256 protocolFeesBefore = protocolFees.balance;
        uint256[2] memory decayBefore = [xDecayFees.balance, yDecayFees.balance];
        vm.recordLogs();
        vm.prank(alice);
        uint256 bought = router.swap{value: 1 ether}(x, child, true, 1 ether);
        RouteFees memory fees = _assertRouteFeeEvents(child, xEthFeesBefore, childFeesBefore, protocolFeesBefore, true);
        assertEq(xDecayFees.balance - decayBefore[0], fees.decayEth[0]);
        assertEq(yDecayFees.balance - decayBefore[1], fees.decayEth[1]);
        assertGt(bought, 0);
        assertEq(child.balanceOf(alice), bought);
        assertEq(x.balanceOf(alice), 0);
        assertEq(x.balanceOf(childFees), 0);
        assertEq(x.balanceOf(protocolFees), 0);
        assertEq(x.balanceOf(xFees), 0);
        _assertNoSettlementResidue(child);
        assertFalse(x.isDistributor(address(router)));
        assertFalse(child.isDistributor(address(router)));

        xEthFeesBefore = xFees.balance;
        childFeesBefore = childFees.balance;
        protocolFeesBefore = protocolFees.balance;
        decayBefore = [xDecayFees.balance, yDecayFees.balance];
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        child.approve(address(router), type(uint256).max);
        vm.recordLogs();
        vm.prank(alice);
        uint256 returnedEth = router.swap(x, child, false, bought);
        fees = _assertRouteFeeEvents(child, xEthFeesBefore, childFeesBefore, protocolFeesBefore, false);
        assertEq(xDecayFees.balance - decayBefore[0], fees.decayEth[0]);
        assertEq(yDecayFees.balance - decayBefore[1], fees.decayEth[1]);
        assertGt(returnedEth, 0);
        assertLt(returnedEth, 1 ether);
        assertEq(alice.balance, aliceEthBefore + returnedEth);
        assertEq(child.balanceOf(alice), 0);
        assertEq(x.balanceOf(alice), 0);
        assertEq(x.balanceOf(childFees), 0);
        assertEq(x.balanceOf(protocolFees), 0);
        _assertNoSettlementResidue(child);
    }

    function test_crossPairAtomicEthToXToYAndBackWithYAsCurrency0() public {
        assertLt(uint160(address(y0)), uint160(address(x)));
        _roundTrip(y0);
    }

    function test_crossPairAtomicEthToXToYAndBackWithYAsCurrency1() public {
        assertGt(uint160(address(y1)), uint160(address(x)));
        _roundTrip(y1);
    }

    function test_crossPairRoutesSplitProtocolFeesAtIndependentMinimumRatesInBothOrderings() public {
        uint16[3] memory parentRates = [uint16(100), 30, 30];
        uint16[3] memory childRates = [uint16(30), 300, 30];
        for (uint256 i; i < parentRates.length; ++i) {
            x.setTaxBps(parentRates[i]);
            y0.setTaxBps(childRates[i]);
            y1.setTaxBps(childRates[i]);
            _roundTrip(y0);
            _roundTrip(y1);
        }
    }

    function _decliningTaxRoundTrips(bool childIsCurrency0) private {
        vm.warp(1_000);
        ERC20T.Config memory parentConfig = _config(address(0), 130, xFees);
        parentConfig.launchTaxBps = 9_900;
        parentConfig.feeDecayRecipient = xDecayFees;
        parentConfig.taxDecayIntervalSeconds = 60;
        x = factory.create(parentConfig);
        x.launch(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
        x.setPairingEnabled(true);

        vm.warp(1_030);
        ERC20T.Config memory childConfig = _config(address(x), 30, y0Fees);
        childConfig.launchTaxBps = 9_900;
        childConfig.feeDecayRecipient = yDecayFees;
        childConfig.taxDecayIntervalSeconds = 40;
        ERC20T child = _deployChild(childIsCurrency0, childConfig);
        vm.warp(1_050);
        _launchChild(child);
        assertEq(address(child) < address(x), childIsCurrency0);
        assertEq(x.launchedAt(), 1_000);
        assertEq(child.launchedAt(), 1_050);

        // Both start at 99%; independent clocks let Y reach its floor before X.
        uint256[5] memory timestamps = [uint256(1_050), 1_060, 1_090, 5_010, 6_880];
        uint16[5] memory parentRates = [uint16(9_900), 9_800, 9_800, 3_300, 130];
        uint16[5] memory childRates = [uint16(9_900), 9_900, 9_800, 30, 30];
        for (uint256 i; i < timestamps.length; ++i) {
            vm.warp(timestamps[i]);
            assertEq(x.taxBps(), parentRates[i]);
            assertEq(child.taxBps(), childRates[i]);
            // Both directions check per-token ETH splits, conversion counts and settled balances.
            _roundTrip(child);
        }
    }

    function test_crossPairIndependentTaxDecayAndFeeSplitsWithYAsCurrency0() public {
        _decliningTaxRoundTrips(true);
    }

    function test_crossPairIndependentTaxDecayAndFeeSplitsWithYAsCurrency1() public {
        _decliningTaxRoundTrips(false);
    }

    function _standardRouteData(ERC20T child, bool buy, uint128 amountIn, uint128 minOut)
        internal
        view
        returns (bytes memory)
    {
        Currency input = Currency.wrap(buy ? address(0) : address(child));
        Currency output = Currency.wrap(buy ? address(child) : address(0));
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(address(x)), 0, ERC20T_TICK_SPACING, IHooks(address(hook)), "");
        path[1] = PathKey(output, 0, ERC20T_TICK_SPACING, IHooks(address(hook)), "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputParams(input, path, amountIn, minOut));
        params[1] = abi.encode(input, uint256(amountIn));
        params[2] = abi.encode(output, uint256(minOut));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        return abi.encode(actions, params);
    }

    function _standardRoundTrip(ERC20T child, MockV4Router standardRouter) internal {
        bytes memory tooTight = _standardRouteData(child, true, 1 ether, 0.99 ether);
        uint256 nativeFeesBefore = xFees.balance;
        uint256 childFeesBefore = child.feeRecipient().balance;
        uint256 protocolFeesBefore = protocolFees.balance;
        vm.prank(alice);
        vm.expectPartialRevert(IV4Router.V4TooLittleReceived.selector);
        standardRouter.executeActions{value: 1 ether}(tooTight);
        assertEq(xFees.balance, nativeFeesBefore);
        assertEq(child.feeRecipient().balance, childFeesBefore);
        assertEq(protocolFees.balance, protocolFeesBefore);

        bytes memory buy = _standardRouteData(child, true, 1 ether, 0.9 ether);
        vm.recordLogs();
        vm.prank(alice);
        standardRouter.executeActions{value: 1 ether}(buy);
        _assertRouteFeeEvents(child, nativeFeesBefore, childFeesBefore, protocolFeesBefore, true);
        uint256 bought = child.balanceOf(alice);
        assertGt(bought, 0.9 ether);
        assertEq(x.balanceOf(alice), 0);
        assertEq(x.balanceOf(address(standardRouter)), 0);
        assertEq(child.balanceOf(address(standardRouter)), 0);
        assertEq(address(standardRouter).balance, 0);
        _assertNoSettlementResidue(child);

        bytes memory sell = _standardRouteData(child, false, uint128(bought), uint128(bought * 9 / 10));
        vm.prank(alice);
        child.approve(address(standardRouter), type(uint256).max);
        uint256 nativeBefore = alice.balance;
        nativeFeesBefore = xFees.balance;
        childFeesBefore = child.feeRecipient().balance;
        protocolFeesBefore = protocolFees.balance;
        vm.recordLogs();
        vm.prank(alice);
        standardRouter.executeActions(sell);
        _assertRouteFeeEvents(child, nativeFeesBefore, childFeesBefore, protocolFeesBefore, false);
        assertGt(alice.balance, nativeBefore);
        assertEq(child.balanceOf(alice), 0);
        assertEq(x.balanceOf(alice), 0);
        assertEq(x.balanceOf(address(standardRouter)), 0);
        assertEq(child.balanceOf(address(standardRouter)), 0);
        assertEq(address(standardRouter).balance, 0);
        _assertNoSettlementResidue(child);
    }

    function test_crossPairStandardV4RouterRoutesBothOrdersAndEnforcesPostTaxMinimums() public {
        MockV4Router standardRouter = new MockV4Router(manager);
        _standardRoundTrip(y0, standardRouter);
        _standardRoundTrip(y1, standardRouter);
    }

    function test_crossPairCanonicalKeysAndPrimaryTokensAreIndependent() public view {
        assertEq(x.quoteToken(), address(0));
        assertEq(y0.quoteToken(), address(x));
        assertEq(y1.quoteToken(), address(x));
        PoolKey memory first = y0.poolKey();
        PoolKey memory second = y1.poolKey();
        assertEq(Currency.unwrap(first.currency0), address(y0));
        assertEq(Currency.unwrap(first.currency1), address(x));
        assertEq(Currency.unwrap(second.currency0), address(x));
        assertEq(Currency.unwrap(second.currency1), address(y1));
        assertNotEq(PoolId.unwrap(first.toId()), PoolId.unwrap(second.toId()));
        assertEq(hook.poolToken(first.toId()), address(y0));
        assertEq(hook.poolToken(second.toId()), address(y1));
        assertTrue(hook.poolInitialized(address(y0)));
        assertTrue(hook.poolInitialized(address(y1)));
        assertFalse(y0.pairingEnabled());
        assertFalse(y1.pairingEnabled());
    }

    function _directBuy(ERC20T child, uint256 amountIn) internal returns (uint256 bought) {
        x.transfer(alice, amountIn);
        vm.prank(alice);
        x.approve(address(swapRouter), type(uint256).max);
        PoolKey memory poolKey = child.poolKey();
        bool quoteIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(x);
        uint256 before = child.balanceOf(alice);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: quoteIsCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: quoteIsCurrency0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        return child.balanceOf(alice) - before;
    }

    function test_crossPairDirectXToYWorksForBothOrderingsAndPaysOnlyChildEthFees() public {
        _seedParent(10 ether);
        uint256 nativeFeesBefore = xFees.balance;
        assertGt(_directBuy(y0, 1 ether), 0);
        assertGt(_directBuy(y1, 1 ether), 0);
        assertEq(xFees.balance, nativeFeesBefore);
        assertEq(x.balanceOf(y0Fees), 0);
        assertEq(x.balanceOf(y1Fees), 0);
        assertGt(y0Fees.balance, 0);
        assertGt(y1Fees.balance, 0);
        assertEq(x.balanceOf(alice), 0);
        _assertNoSettlementResidue(y0);
        _assertNoSettlementResidue(y1);
    }

    function test_crossPairRejectsZeroAndBelowMinimumTaxInBothOrderings() public {
        ERC20T[3] memory tokens = [x, y0, y1];
        for (uint256 i; i < tokens.length; ++i) {
            vm.expectRevert(ERC20T.InvalidTax.selector);
            tokens[i].setTaxBps(0);
            vm.expectRevert(ERC20T.InvalidTax.selector);
            tokens[i].setTaxBps(29);
        }
    }

    function _assertMinimumFeeSplit(ERC20T child, uint256 tokenBefore, uint256 protocolBefore) private view {
        uint256 tokenPaid = child.feeRecipient().balance - tokenBefore;
        uint256 protocolPaid = protocolFees.balance - protocolBefore;
        assertGt(tokenPaid, 0);
        assertGt(protocolPaid, 0);
        assertEq(protocolPaid, (tokenPaid + protocolPaid) / 2);
    }

    function test_crossPairMinimumTaxStillNeedsParentLiquidityAndSplitsDirectTradesInBothOrderings() public {
        y0.setTaxBps(30);
        y1.setTaxBps(30);
        _expectChildFeeConversionFailure(y0);
        _expectChildFeeConversionFailure(y1);
        _seedParent(10 ether);
        uint256 parentFeesBefore = xFees.balance;
        ERC20T[2] memory children = [y0, y1];
        for (uint256 i; i < children.length; ++i) {
            ERC20T child = children[i];
            uint256 tokenBefore = child.feeRecipient().balance;
            uint256 protocolBefore = protocolFees.balance;
            uint256 bought = _directBuy(child, 1 ether);
            _assertMinimumFeeSplit(child, tokenBefore, protocolBefore);
            tokenBefore = child.feeRecipient().balance;
            protocolBefore = protocolFees.balance;
            _directSell(child, bought);
            _assertMinimumFeeSplit(child, tokenBefore, protocolBefore);
            _assertNoSettlementResidue(child);
        }
        assertEq(xFees.balance, parentFeesBefore);
        assertEq(x.balanceOf(protocolFees), 0);
    }

    function test_crossPairOutputTaxUsesChildRateAndPaysEth() public {
        _seedParent(10 ether);
        uint256 protocolBefore = protocolFees.balance;
        vm.recordLogs();
        uint256 received = _directBuy(y0, 2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FEE_EVENT) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(y0));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), y0Fees);
                (uint256 childTokenFee, uint256 ethFee) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(childTokenFee, (received + childTokenFee) * y0.taxBps() / 10_000);
                assertEq(ethFee, y0Fees.balance);
                assertGt(ethFee, 0);
                assertEq(x.balanceOf(y0Fees), 0);
                found = true;
            }
        }
        assertTrue(found);
        uint256 protocolPaid = protocolFees.balance - protocolBefore;
        assertGt(protocolPaid, 0);
        assertEq(protocolPaid, (y0Fees.balance + protocolPaid) * 15 / y0.taxBps());
    }

    function _directSell(ERC20T child, uint256 amountIn) internal {
        vm.prank(alice);
        child.approve(address(swapRouter), type(uint256).max);
        PoolKey memory poolKey = child.poolKey();
        bool tokenIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(child);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: tokenIsCurrency0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: tokenIsCurrency0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _poolState(PoolKey memory poolKey) internal view returns (bytes32) {
        (uint160 sqrtPrice, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolKey.toId());
        return keccak256(abi.encode(sqrtPrice, tick, protocolFee, lpFee, manager.getLiquidity(poolKey.toId())));
    }

    function _tradeState(ERC20T child) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _poolState(x.poolKey()),
                _poolState(child.poolKey()),
                x.balanceOf(alice),
                child.balanceOf(alice),
                address(manager).balance,
                x.balanceOf(address(manager)),
                child.balanceOf(address(manager)),
                xFees.balance,
                child.feeRecipient().balance,
                protocolFees.balance
            )
        );
    }

    function _expectChildFeeConversionFailure(ERC20T child) internal {
        x.transfer(alice, 1 ether);
        vm.prank(alice);
        x.approve(address(swapRouter), type(uint256).max);
        PoolKey memory poolKey = child.poolKey();
        bool quoteIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(x);
        bytes32 before = _tradeState(child);
        bytes memory expected = _hookError(IHooks.afterSwap.selector, ERC20THook.PartialFeeSwap.selector);
        vm.prank(alice);
        vm.expectRevert(expected);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: quoteIsCurrency0,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: quoteIsCurrency0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertEq(_tradeState(child), before, "partial ETH fee conversion changed trade or pool state");
        assertEq(x.balanceOf(child.feeRecipient()), 0);
        _assertNoSettlementResidue(child);
    }

    function test_crossPairUnseededParentFeeConversionRevertsAtomicallyInBothOrderings() public {
        (uint160 sqrtPrice,,,) = manager.getSlot0(x.poolKey().toId());
        assertEq(sqrtPrice, SQRT_PRICE_1_1);
        assertEq(x.balanceOf(parentSeeder), 0);
        // The singleton's physical ETH balance does not supply ETH liquidity to this pool.
        assertEq(address(manager).balance, 100 ether);
        _expectChildFeeConversionFailure(y0);
        _expectChildFeeConversionFailure(y1);
    }

    function test_crossPairPartiallyFillableParentFeeConversionRevertsAtomicallyInBothOrderings() public {
        _seedParent(0.001 ether);
        PoolKey memory parentKey = x.poolKey();
        (uint160 sqrtPrice,,,) = manager.getSlot0(parentKey.toId());
        assertLt(sqrtPrice, SQRT_PRICE_1_1);
        uint256 xCapacity =
            SqrtPriceMath.getAmount1Delta(sqrtPrice, SQRT_PRICE_1_1, manager.getLiquidity(parentKey.toId()), true);
        // Some X can be sold, but less than the 3% or 5% fee from a one-X child buy.
        assertGt(xCapacity, 0);
        assertLt(xCapacity, 0.01 ether);
        _expectChildFeeConversionFailure(y0);
        _expectChildFeeConversionFailure(y1);
    }

    function test_crossPairRejectingRecipientReceivesConvertedEthOnBuyAndSell() public {
        _seedParent(10 ether);
        ERC20TRejectingFeeRecipient recipient = new ERC20TRejectingFeeRecipient();
        y0.setFeeRecipient(address(recipient));
        uint256 parentFees = xFees.balance;
        uint256 bought = _directBuy(y0, 2 ether);
        uint256 buyFees = address(recipient).balance;
        assertGt(buyFees, 0);
        _directSell(y0, bought);
        assertGt(address(recipient).balance, buyFees);
        assertEq(x.balanceOf(address(recipient)), 0);
        assertEq(y0.balanceOf(address(recipient)), 0);
        assertEq(xFees.balance, parentFees);
        assertEq(y0.balanceOf(alice), 0);
        _assertNoSettlementResidue(y0);
    }

    function test_crossPairEthRecipientCannotReenterParentPoolDuringFeePayout() public {
        _seedParent(10 ether);
        ERC20TReentrantFeeRecipient recipient = new ERC20TReentrantFeeRecipient(manager, x.poolKey());
        y0.setFeeRecipient(address(recipient));
        _directBuy(y0, 2 ether);
        assertTrue(recipient.attempted());
        assertFalse(recipient.succeeded());
        assertEq(
            recipient.failureHash(),
            keccak256(_hookError(IHooks.afterSwap.selector, ReentrancyGuard.Reentrancy.selector))
        );
        assertGt(address(recipient).balance, 0);
        assertEq(x.balanceOf(address(recipient)), 0);
        assertEq(y0.balanceOf(address(recipient)), 0);
        _assertNoSettlementResidue(y0);
    }

    function _exerciseExternalLiquidity(ERC20T child) internal {
        x.transfer(bob, 1 ether);
        child.transfer(bob, 1 ether);
        vm.startPrank(bob);
        x.approve(address(modifyLiquidityRouter), type(uint256).max);
        child.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
        PoolKey memory poolKey = child.poolKey();
        vm.prank(bob);
        vm.expectRevert(_hookError(IHooks.afterAddLiquidity.selector, ERC20THook.ExternalLiquidityDisabled.selector));
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        child.setExternalLiquidityEnabled(true);
        uint256 xBefore = x.balanceOf(bob);
        uint256 yBefore = child.balanceOf(bob);
        vm.prank(bob);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertLt(x.balanceOf(bob), xBefore);
        assertLt(child.balanceOf(bob), yBefore);
        _assertNoSettlementResidue(child);
        // Closing new-pair and LP entry gates must not trap an existing LP's two currencies.
        x.setPairingEnabled(false);
        child.setExternalLiquidityEnabled(false);
        vm.prank(bob);
        vm.expectRevert(_hookError(IHooks.afterAddLiquidity.selector, ERC20THook.ExternalLiquidityDisabled.selector));
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        xBefore = x.balanceOf(bob);
        yBefore = child.balanceOf(bob);
        vm.prank(bob);
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertGt(x.balanceOf(bob), xBefore);
        assertGt(child.balanceOf(bob), yBefore);
        _assertNoSettlementResidue(child);
    }

    function test_crossPairExternalLiquidityAndWithdrawalAuthorizeBothCurrenciesInBothOrderings() public {
        assertFalse(x.externalLiquidityEnabled());
        _exerciseExternalLiquidity(y0);
        _exerciseExternalLiquidity(y1);
    }

    function test_crossPairDisablingPairingPreservesExistingRoutes() public {
        x.setPairingEnabled(false);
        _roundTrip(y0);
        _roundTrip(y1);
        ERC20T.Config memory config = _config(address(x), 100, y0Fees);
        ERC20T blocked = factory.create(config);
        _expectInitAndLaunchFailure(blocked, ERC20THook.PairingDisabled.selector);
    }

    function test_crossPairPairingToggleIsOwnerOnlyAndDefaultsOff() public {
        ERC20T fresh = factory.create(_config(address(0), 100, xFees));
        assertFalse(fresh.pairingEnabled());
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        fresh.setPairingEnabled(true);
        fresh.setPairingEnabled(true);
        assertTrue(fresh.pairingEnabled());
        fresh.setPairingEnabled(false);
        assertFalse(fresh.pairingEnabled());
        vm.expectRevert(ERC20T.InvalidQuoteToken.selector);
        y0.setPairingEnabled(true);
    }

    function test_crossPairRejectsUnlaunchedQuote() public {
        ERC20T unlaunched = factory.create(_config(address(0), 100, xFees));
        unlaunched.setPairingEnabled(true);
        ERC20T.Config memory config = _config(address(unlaunched), 100, y0Fees);
        ERC20T blocked = factory.create(config);
        _expectInitAndLaunchFailure(blocked, ERC20THook.InvalidPool.selector);
    }

    function test_crossPairRejectsNestedQuote() public {
        ERC20T.Config memory config = _config(address(y0), 100, y0Fees);
        ERC20T blocked = factory.create(config);
        _expectInitAndLaunchFailure(blocked, ERC20THook.InvalidPool.selector);
    }

    function test_crossPairRejectsQuoteLaunchedThroughAnotherHook() public {
        ERC20THook otherHook = _deployHook();
        ERC20T.Config memory quoteConfig = _config(address(0), 100, xFees);
        quoteConfig.hook = address(otherHook);
        ERC20T foreignQuote = factory.create(quoteConfig);
        foreignQuote.launch(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
        foreignQuote.setPairingEnabled(true);
        assertTrue(otherHook.poolInitialized(address(foreignQuote)));
        assertFalse(hook.poolInitialized(address(foreignQuote)));
        ERC20T child = factory.create(_config(address(foreignQuote), 100, y0Fees));
        _expectInitAndLaunchFailure(child, ERC20THook.InvalidPool.selector);
    }

    function test_crossPairRejectsEoaQuote() public {
        ERC20T.Config memory config = _config(alice, 100, y0Fees);
        vm.expectRevert(ERC20T.InvalidQuoteToken.selector);
        factory.create(config);
    }

    function test_crossPairRejectsNativeValueForQuotedLaunch() public {
        ERC20T child = factory.create(_config(address(x), 100, y0Fees));
        bool tokenIsCurrency0 = address(child) < address(x);
        int24 lower = tokenIsCurrency0 ? int24(0) : TickMath.minUsableTick(ERC20T_TICK_SPACING);
        int24 upper = tokenIsCurrency0 ? TickMath.maxUsableTick(ERC20T_TICK_SPACING) : int24(0);
        vm.expectRevert(ERC20T.NativeValueNotAllowed.selector);
        child.launch{value: 1}(SQRT_PRICE_1_1, lower, upper);
        assertFalse(child.launched());
    }

    function test_crossPairExactOutputRemainsUnsupportedForBothOrderings() public {
        _seedParent(10 ether);
        _directBuy(y0, 2 ether);
        _directBuy(y1, 2 ether);
        ERC20T[2] memory children = [y0, y1];
        for (uint256 i; i < children.length; ++i) {
            PoolKey memory poolKey = children[i].poolKey();
            for (uint256 direction; direction < 2; ++direction) {
                bool zeroForOne = direction == 0;
                bytes memory expected = _hookError(IHooks.afterSwap.selector, ERC20THook.ExactOutputNotAllowed.selector);
                vm.expectRevert(expected);
                swapRouter.swap(
                    poolKey,
                    SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: 0.01 ether,
                        sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ZERO_BYTES
                );
            }
        }
    }

    function test_crossPairFactoryDerivesOrientationForQuotedPriceAndLaunchesAtomically() public {
        ERC20T.Config memory config = _config(address(x), 250, y0Fees);
        config.owner = bob;
        ERC20T child = factory.createAndLaunchAtPrice(config, 1_000, 2 ether);
        bool childIsCurrency0 = address(child) < address(x);
        ERC20TFactory.LaunchPreview memory preview =
            factory.previewQuotedLaunch(SUPPLY, 1_000, 2 ether, childIsCurrency0);
        assertEq(child.owner(), bob);
        assertEq(child.quoteToken(), address(x));
        assertEq(child.balanceOf(bob), preview.creatorSupply);
        assertEq(child.balanceOf(address(manager)) + child.balanceOf(address(child)), preview.lpSupply);
        assertEq(child.balanceOf(address(factory)), 0);
        PoolKey memory poolKey = child.poolKey();
        (uint160 sqrtPrice,,,) = manager.getSlot0(poolKey.toId());
        assertEq(sqrtPrice, preview.sqrtPriceX96);
        assertGe(preview.effectivePriceWei, 2 ether);
        _seedParent(10 ether);
        assertGt(_directBuy(child, 1 ether), 0);
        _assertNoSettlementResidue(child);
    }

    function test_crossPairQuotedPricePreviewAlignsBothOrientations() public view {
        uint256[3] memory prices = [uint256(0.1 ether), 1 ether, 2 ether];
        for (uint256 order; order < 2; ++order) {
            bool childIsCurrency0 = order == 0;
            for (uint256 i; i < prices.length; ++i) {
                ERC20TFactory.LaunchPreview memory preview =
                    factory.previewQuotedLaunch(SUPPLY, 2_000, prices[i], childIsCurrency0);
                assertEq(preview.creatorSupply, SUPPLY / 5);
                assertEq(preview.lpSupply, LP_SUPPLY);
                assertEq(preview.tickLower % ERC20T_TICK_SPACING, 0);
                assertEq(preview.tickUpper % ERC20T_TICK_SPACING, 0);
                int24 boundary = childIsCurrency0 ? preview.tickLower : preview.tickUpper;
                assertEq(preview.sqrtPriceX96, TickMath.getSqrtPriceAtTick(boundary));
                assertGe(preview.effectivePriceWei, prices[i]);
                assertLe(preview.effectivePriceWei, prices[i] * 10_070 / 10_000 + 1);
            }
        }
    }
}
