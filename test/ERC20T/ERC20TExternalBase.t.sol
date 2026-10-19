// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockV4Router} from "@uniswap/v4-periphery/test/mocks/MockV4Router.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20T_TICK_SPACING} from "../../src/ERC20T/ERC20TInterfaces.sol";
import {TokenPosmHelper} from "../support/TokenPosmHelper.sol";

/// @dev A separate protocol charging 1% of swap output. Its callback must also run
/// when ERC20THook converts child fees through the registered ETH/base pool.
contract ExternalBaseOutputTaxHook is BaseHook {
    address public immutable recipient;

    event ExternalOutputFee(address indexed sender, address indexed currency, uint256 grossOutput, uint256 fee);

    constructor(IPoolManager manager, address recipient_) BaseHook(manager) {
        recipient = recipient_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        require(params.amountSpecified < 0, "fixture: exact input only");
        uint256 gross = uint256(int256(params.zeroForOne ? delta.amount1() : delta.amount0()));
        uint256 fee = gross / 100;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        if (fee != 0) poolManager.take(output, recipient, fee);
        emit ExternalOutputFee(sender, Currency.unwrap(output), gross, fee);
        return (BaseHook.afterSwap.selector, int128(int256(fee)));
    }
}

contract ExternalBaseShortFallbackToken is MockERC20 {
    constructor() MockERC20("Short fallback base", "SHORT", 18) {}

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 1)
        }
    }
}

contract ERC20TExternalBaseTest is Deployers, TokenPosmHelper {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LP_SUPPLY = SUPPLY * 4 / 5;
    bytes32 constant TOKEN_FEE = keccak256("HookFee(address,address,address,uint256,uint256)");
    bytes32 constant PROTOCOL_FEE = keccak256("ProtocolFee(address,address,address,uint256)");
    bytes32 constant DECAY_FEE = keccak256("FeeDecay(address,address,address,uint256)");
    bytes32 constant EXTERNAL_FEE = keccak256("ExternalOutputFee(address,address,uint256,uint256)");

    ERC20THook hook;
    ERC20TFactory factory;
    ExternalBaseOutputTaxHook externalHook;
    MockV4Router router;
    MockERC20 base;
    PoolKey baseKey;
    ERC20T child0;
    ERC20T child1;
    address alice = makeAddr("externalBaseAlice");
    address bob = makeAddr("externalBaseBob");
    address tokenFees = makeAddr("externalBaseTokenFees");
    address protocolFees = makeAddr("externalBaseProtocolFees");
    address decayFees = makeAddr("externalBaseDecayFees");
    address externalFees = makeAddr("externalBaseExternalFees");

    struct FeeSummary {
        uint256 tokenFee;
        uint256 creatorEth;
        uint256 protocolEth;
        uint256 decayEth;
        uint256 externalGrossEth;
        uint256 externalEth;
        uint256 tokenEvents;
        uint256 protocolEvents;
        uint256 decayEvents;
        uint256 conversionEvents;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        _deployPosm(manager);
        vm.deal(address(this), 10_000_000 ether);
        vm.deal(alice, 100 ether);
        externalHook = _deployExternalHook();
        (base, baseKey) = _basePool(true);
        ERC20THook.ExternalBaseConfig[] memory initialBases = new ERC20THook.ExternalBaseConfig[](1);
        initialBases[0] = ERC20THook.ExternalBaseConfig(address(base), baseKey);
        hook = _deployHook(initialBases);
        factory = new ERC20TFactory();
        router = new MockV4Router(manager);
        child0 = _orderedChild(true);
        child1 = _orderedChild(false);
        _launch(child0);
        _launch(child1);
    }

    function _deployExternalHook() private returns (ExternalBaseOutputTaxHook deployed) {
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(ExternalBaseOutputTaxHook).creationCode, abi.encode(manager, externalFees)
        );
        vm.prank(CREATE2_DEPLOYER);
        deployed = new ExternalBaseOutputTaxHook{salt: salt}(manager, externalFees);
        assertEq(address(deployed), expected);
    }

    function _deployHook(ERC20THook.ExternalBaseConfig[] memory initialBases) private returns (ERC20THook deployed) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, address(this), protocolFees, initialBases, address(0))
        );
        vm.prank(CREATE2_DEPLOYER);
        deployed = new ERC20THook{salt: salt}(manager, address(this), protocolFees, initialBases, address(0));
        assertEq(address(deployed), expected);
    }

    function _basePool(bool nativeLiquidity) private returns (MockERC20 token, PoolKey memory poolKey) {
        token = new MockERC20("Ordinary external base", "BASE", 18);
        token.mint(address(this), 1_000_000_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        poolKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3_000, 200, externalHook);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: nativeLiquidity ? 1_000_000 ether : 0}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(200),
                tickUpper: nativeLiquidity ? TickMath.maxUsableTick(200) : int24(0),
                liquidityDelta: 1_000_000 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _config(address quote) private view returns (ERC20T.Config memory) {
        return ERC20T.Config({
            name: "Externally Quoted Child",
            symbol: "CHILD",
            supply: SUPPLY,
            lpSupply: LP_SUPPLY,
            owner: address(this),
            hook: address(hook),
            quoteToken: quote,
            positionManager: posm,
            permit2: IAllowanceTransfer(PERMIT2_ADDR),
            taxBps: 300,
            feeRecipient: tokenFees,
            feeDecayRecipient: decayFees,
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0
        });
    }

    function _orderedChild(bool childIsCurrency0) private returns (ERC20T child) {
        ERC20T.Config memory config = _config(address(base));
        address implementation = factory.implementation();
        bytes memory args =
            abi.encodePacked(address(hook), address(base), address(manager), address(posm), PERMIT2_ADDR);
        bytes32 initCodeHash = LibClone.initCodeHash(implementation, args);
        for (uint256 i; i < 1_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = LibClone.predictDeterministicAddress(initCodeHash, salt, address(this));
            if ((predicted < address(base)) == childIsCurrency0) {
                child = ERC20T(LibClone.cloneDeterministic(implementation, args, salt));
                child.initialize(config);
                assertEq(address(child), predicted);
                return child;
            }
        }
        revert("could not select child ordering");
    }

    function _launch(ERC20T child) private {
        bool childIsCurrency0 = address(child) < child.quoteToken();
        child.launch(
            SQRT_PRICE_1_1,
            childIsCurrency0 ? int24(0) : TickMath.minUsableTick(60),
            childIsCurrency0 ? TickMath.maxUsableTick(60) : int24(0)
        );
    }

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified) private returns (BalanceDelta) {
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _buy(ERC20T child, uint256 amount) private returns (uint256) {
        MockERC20 quote = MockERC20(child.quoteToken());
        quote.mint(alice, amount);
        vm.prank(alice);
        quote.approve(address(swapRouter), type(uint256).max);
        PoolKey memory poolKey = child.poolKey();
        uint256 before = child.balanceOf(alice);
        vm.prank(alice);
        _swap(poolKey, Currency.unwrap(poolKey.currency0) == address(quote), -int256(amount));
        return child.balanceOf(alice) - before;
    }

    function _sell(ERC20T child, uint256 amount) private {
        PoolKey memory poolKey = child.poolKey();
        vm.prank(alice);
        child.approve(address(swapRouter), type(uint256).max);
        vm.prank(alice);
        _swap(poolKey, Currency.unwrap(poolKey.currency0) == address(child), -int256(amount));
    }

    function _fees(ERC20T child, uint256 creatorBefore, uint256 protocolBefore, uint256 decayBefore)
        private
        view
        returns (FeeSummary memory fees)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(externalHook) && logs[i].topics[0] == EXTERNAL_FEE) {
                address sender = address(uint160(uint256(logs[i].topics[1])));
                address currency = address(uint160(uint256(logs[i].topics[2])));
                if (sender == address(hook) && currency == address(0)) {
                    (fees.externalGrossEth, fees.externalEth) = abi.decode(logs[i].data, (uint256, uint256));
                    ++fees.conversionEvents;
                }
            }
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == TOKEN_FEE) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(child));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), tokenFees);
                (fees.tokenFee, fees.creatorEth) = abi.decode(logs[i].data, (uint256, uint256));
                ++fees.tokenEvents;
            } else if (logs[i].topics[0] == PROTOCOL_FEE) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(child));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), protocolFees);
                fees.protocolEth = abi.decode(logs[i].data, (uint256));
                ++fees.protocolEvents;
            } else if (logs[i].topics[0] == DECAY_FEE) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(child));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), decayFees);
                fees.decayEth = abi.decode(logs[i].data, (uint256));
                ++fees.decayEvents;
            }
        }
        assertEq(fees.tokenEvents, 1);
        assertEq(fees.protocolEvents, 1);
        assertEq(fees.conversionEvents, 1, "external hook must tax child fee conversion");
        assertGt(fees.externalEth, 0);
        assertEq(fees.externalEth, fees.externalGrossEth / 100);
        uint256 netEth = fees.externalGrossEth - fees.externalEth;
        assertEq(fees.creatorEth + fees.protocolEth + fees.decayEth, netEth);
        assertEq(fees.protocolEth, netEth * 15 / child.taxBps());
        assertEq(fees.decayEth, netEth * (child.taxBps() - child.restingTaxBps()) / child.taxBps());
        assertEq(fees.decayEvents, fees.decayEth == 0 ? 0 : 1);
        assertEq(fees.creatorEth, netEth - fees.protocolEth - fees.decayEth);
        assertEq(tokenFees.balance - creatorBefore, fees.creatorEth);
        assertEq(protocolFees.balance - protocolBefore, fees.protocolEth);
        assertEq(decayFees.balance - decayBefore, fees.decayEth);
        assertGt(fees.creatorEth, 0);
        assertGt(fees.protocolEth, 0);
    }

    function _assertSettled(ERC20T child) private view {
        MockERC20 quote = MockERC20(child.quoteToken());
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(tokenFees), 0);
        assertEq(quote.balanceOf(protocolFees), 0);
        assertEq(quote.balanceOf(decayFees), 0);
        assertEq(child.balanceOf(address(hook)), 0);
        assertEq(child.balanceOf(address(router)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(child.getTransferAllowance(true), 0);
        assertEq(child.getTransferAllowance(false), 0);
        assertEq(child.getNetTransferAllowance(), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(quote))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(child))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(router), Currency.wrap(address(quote))), 0);
        assertEq(manager.currencyDelta(address(externalHook), Currency.wrap(address(quote))), 0);
        assertEq(manager.currencyDelta(address(externalHook), Currency.wrap(address(0))), 0);
    }

    function test_externalBaseOrdinaryErc20LaunchesBothOrderingsAndPaysNetEthOnBuyAndSell() public {
        // This external base deliberately does not implement any IERC20T configuration methods.
        (bool supportsERC20T,) = address(base).staticcall(abi.encodeWithSignature("quoteToken()"));
        assertFalse(supportsERC20T);
        assertLt(uint160(address(child0)), uint160(address(base)));
        assertGt(uint160(address(child1)), uint160(address(base)));
        ERC20T[2] memory children = [child0, child1];
        for (uint256 i; i < children.length; ++i) {
            ERC20T child = children[i];
            assertTrue(hook.poolInitialized(address(child)));
            assertEq(hook.poolToken(child.poolKey().toId()), address(child));
            uint256 creatorBefore = tokenFees.balance;
            uint256 protocolBefore = protocolFees.balance;
            uint256 decayBefore = decayFees.balance;
            uint256 externalBefore = externalFees.balance;
            vm.recordLogs();
            uint256 bought = _buy(child, 2 ether);
            FeeSummary memory buyFees = _fees(child, creatorBefore, protocolBefore, decayBefore);
            assertEq(buyFees.tokenFee, (bought + buyFees.tokenFee) * child.taxBps() / 10_000);
            assertEq(externalFees.balance - externalBefore, buyFees.externalEth);
            assertEq(base.balanceOf(alice), 0);
            _assertSettled(child);
            creatorBefore = tokenFees.balance;
            protocolBefore = protocolFees.balance;
            decayBefore = decayFees.balance;
            externalBefore = externalFees.balance;
            vm.recordLogs();
            _sell(child, bought);
            FeeSummary memory sellFees = _fees(child, creatorBefore, protocolBefore, decayBefore);
            assertEq(sellFees.tokenFee, 0);
            assertEq(externalFees.balance - externalBefore, sellFees.externalEth);
            assertGt(base.balanceOf(alice), 0);
            assertEq(child.balanceOf(alice), 0);
            uint256 remainingBase = base.balanceOf(alice);
            vm.prank(alice);
            base.transfer(bob, remainingBase);
            _assertSettled(child);
        }
    }

    function _route(ERC20T child, bool buy, uint128 amount, uint128 minimum) private view returns (bytes memory) {
        Currency input = Currency.wrap(buy ? address(0) : address(child));
        Currency output = Currency.wrap(buy ? address(child) : address(0));
        PathKey[] memory path = new PathKey[](2);
        path[0] = buy
            ? PathKey(Currency.wrap(address(base)), baseKey.fee, baseKey.tickSpacing, baseKey.hooks, "")
            : PathKey(Currency.wrap(address(base)), 0, 60, IHooks(address(hook)), "");
        path[1] = buy
            ? PathKey(output, 0, 60, IHooks(address(hook)), "")
            : PathKey(output, baseKey.fee, baseKey.tickSpacing, baseKey.hooks, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputParams(input, path, amount, minimum));
        params[1] = abi.encode(input, uint256(amount));
        params[2] = abi.encode(output, uint256(minimum));
        return abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)), params
        );
    }

    function _roundTrip(ERC20T child) private {
        uint256 creatorBefore = tokenFees.balance;
        uint256 protocolBefore = protocolFees.balance;
        uint256 decayBefore = decayFees.balance;
        uint256 netBps = 10_000 - uint256(child.taxBps());
        uint128 minimumBuy = uint128(1 ether * netBps / 10_000 * 9 / 10);
        bytes memory actions = _route(child, true, 1 ether, minimumBuy);
        vm.recordLogs();
        vm.prank(alice);
        router.executeActions{value: 1 ether}(actions);
        FeeSummary memory buyFees = _fees(child, creatorBefore, protocolBefore, decayBefore);
        uint256 bought = child.balanceOf(alice);
        assertGt(bought, minimumBuy);
        assertEq(buyFees.tokenFee, (bought + buyFees.tokenFee) * child.taxBps() / 10_000);
        assertEq(base.balanceOf(alice), 0);
        assertFalse(child.isDistributor(address(router)));
        _assertSettled(child);
        uint128 minimumSell = uint128(bought * netBps / 10_000 * 9 / 10);
        actions = _route(child, false, uint128(bought), minimumSell);
        vm.prank(alice);
        child.approve(address(router), type(uint256).max);
        creatorBefore = tokenFees.balance;
        protocolBefore = protocolFees.balance;
        decayBefore = decayFees.balance;
        uint256 aliceEthBefore = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        router.executeActions(actions);
        _fees(child, creatorBefore, protocolBefore, decayBefore);
        assertGt(alice.balance, aliceEthBefore);
        assertEq(child.balanceOf(alice), 0);
        assertEq(base.balanceOf(alice), 0);
        _assertSettled(child);
    }

    function test_externalBaseStandardRouterNetsIntermediateBaseBothDirectionsAndOrderings() public {
        _roundTrip(child0);
        _roundTrip(child1);
        assertGt(base.balanceOf(externalFees), 0, "external hook taxes outer ETH-to-base output");
    }

    function test_externalBaseFactorySupportsOneTransactionAndDelayedOwnerLaunch() public {
        ERC20T.Config memory config = _config(address(base));
        config.owner = bob;
        config.launchTaxBps = 9_900;
        config.taxDecayIntervalSeconds = 60;
        ERC20T atomic = factory.createAndLaunchAtPrice(config, 2_000, 1 ether);
        assertTrue(atomic.launched());
        assertEq(atomic.owner(), bob);
        assertEq(atomic.taxBps(), 9_900);
        assertEq(atomic.balanceOf(bob), SUPPLY / 5);
        assertEq(atomic.balanceOf(address(factory)), 0);
        assertEq(atomic.balanceOf(address(manager)) + atomic.balanceOf(address(atomic)), LP_SUPPLY);
        _roundTrip(atomic);

        ERC20T delayed = factory.create(config);
        assertFalse(delayed.launched());
        assertFalse(hook.poolInitialized(address(delayed)));
        assertEq(delayed.owner(), bob);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(delayed.taxBps(), 9_900);
        assertEq(atomic.taxBps(), 300);
        _roundTrip(atomic);
        bool childIsCurrency0 = address(delayed) < address(base);
        int24 lower = childIsCurrency0 ? int24(0) : TickMath.minUsableTick(60);
        int24 upper = childIsCurrency0 ? TickMath.maxUsableTick(60) : int24(0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        delayed.launch(SQRT_PRICE_1_1, lower, upper);
        vm.prank(bob);
        delayed.launch(SQRT_PRICE_1_1, lower, upper);
        assertEq(delayed.launchedAt(), vm.getBlockTimestamp());
        assertEq(delayed.taxBps(), 9_900);
        _roundTrip(delayed);
        vm.warp(delayed.launchedAt() + 96 * 60);
        assertEq(delayed.taxBps(), 300);
        _roundTrip(delayed);
    }

    function _hookError(bytes4 callback, bytes4 reason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _expectLaunchFailure(ERC20T child, bytes4 reason) private {
        PoolKey memory poolKey = child.poolKey();
        bool childIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(child);
        int24 lower = childIsCurrency0 ? int24(0) : TickMath.minUsableTick(60);
        int24 upper = childIsCurrency0 ? TickMath.maxUsableTick(60) : int24(0);
        bytes memory wrapped = _hookError(IHooks.beforeInitialize.selector, reason);
        vm.expectRevert(wrapped);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        child.launch(SQRT_PRICE_1_1, lower, upper);
        assertFalse(child.launched());
        assertEq(child.launchedAt(), 0);
        assertFalse(hook.poolInitialized(address(child)));
    }

    function test_externalBaseRegistryIsOwnerOnlyAndConversionRouteCannotBeReplaced() public {
        (bool registered, bool enabled) = hook.externalBases(address(base));
        assertTrue(registered);
        assertTrue(enabled);
        assertEq(PoolId.unwrap(hook.externalBasePool(address(base)).toId()), PoolId.unwrap(baseKey.toId()));
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setExternalBaseEnabled(address(base), false);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.registerExternalBase(address(base), baseKey);
        vm.expectRevert(ERC20THook.ExternalBaseAlreadyRegistered.selector);
        hook.registerExternalBase(address(base), baseKey);
        hook.setExternalBaseEnabled(address(base), false);
        vm.expectRevert(ERC20THook.ExternalBaseAlreadyRegistered.selector);
        hook.registerExternalBase(address(base), baseKey);
        hook.setExternalBaseEnabled(address(base), true);
        (registered, enabled) = hook.externalBases(address(base));
        assertTrue(registered && enabled);
        vm.expectRevert(ERC20THook.ExternalBaseNotRegistered.selector);
        hook.setExternalBaseEnabled(alice, true);
    }

    function _expectInvalidBase(address token, PoolKey memory poolKey) private {
        vm.expectRevert(ERC20THook.InvalidExternalBase.selector);
        hook.registerExternalBase(token, poolKey);
    }

    function _candidateKey(address token) private view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), 3_000, 60, externalHook);
    }

    function test_externalBaseRejectsInvalidCurrenciesRoutesHooksAndUninitializedPools() public {
        MockERC20 fresh = new MockERC20("Unregistered", "UNREG", 18);
        PoolKey memory valid = _candidateKey(address(fresh));
        _expectInvalidBase(address(0), valid);
        _expectInvalidBase(alice, valid);
        _expectInvalidBase(address(manager), valid);
        _expectInvalidBase(address(hook), valid);
        _expectInvalidBase(address(fresh), baseKey);
        _expectInvalidBase(address(fresh), valid); // Correct shape, not initialized on this manager.
        manager.initialize(valid, SQRT_PRICE_1_1);
        PoolKey memory wrong = _candidateKey(address(fresh));
        wrong.currency0 = Currency.wrap(address(base));
        _expectInvalidBase(address(fresh), wrong);
        wrong = _candidateKey(address(fresh));
        wrong.hooks = IHooks(address(hook));
        _expectInvalidBase(address(fresh), wrong);
        wrong = _candidateKey(address(fresh));
        wrong.hooks = IHooks(alice);
        _expectInvalidBase(address(fresh), wrong);
        wrong = _candidateKey(address(fresh));
        wrong.tickSpacing = 0;
        _expectInvalidBase(address(fresh), wrong);
        wrong = _candidateKey(address(fresh));
        wrong.fee = 1_000_001;
        _expectInvalidBase(address(fresh), wrong);
        hook.registerExternalBase(address(fresh), valid);
        (bool registered, bool enabled) = hook.externalBases(address(fresh));
        assertTrue(registered && enabled);
    }

    function test_externalBaseWithShortFallbackCanRegisterWithoutHookGetter() public {
        ExternalBaseShortFallbackToken shortFallback = new ExternalBaseShortFallbackToken();
        (bool success, bytes memory returned) = address(shortFallback).staticcall(abi.encodeWithSignature("hook()"));
        assertTrue(success);
        assertEq(returned.length, 1);
        PoolKey memory poolKey = _candidateKey(address(shortFallback));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        hook.registerExternalBase(address(shortFallback), poolKey);
        (bool registered, bool enabled) = hook.externalBases(address(shortFallback));
        assertTrue(registered && enabled);
        ERC20T child = factory.create(_config(address(shortFallback)));
        _launch(child);
        assertTrue(child.launched());
    }

    function test_externalBaseUnregisteredBaseCannotLaunchUntilOwnerRegistersItsRoute() public {
        (MockERC20 unregistered, PoolKey memory poolKey) = _basePool(true);
        ERC20T child = factory.create(_config(address(unregistered)));
        _expectLaunchFailure(child, ERC20THook.InvalidPool.selector);
        hook.registerExternalBase(address(unregistered), poolKey);
        _launch(child);
        assertGt(_buy(child, 1 ether), 0);
        _assertSettled(child);
    }

    function test_externalBaseCannotRegisterManagedErc20TToBypassPairingPolicy() public {
        ERC20T managed = factory.create(_config(address(0)));
        PoolKey memory foreign =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(managed)), 3_000, 60, externalHook);
        manager.initialize(foreign, SQRT_PRICE_1_1);
        _expectInvalidBase(address(managed), foreign);
        managed.launch(SQRT_PRICE_1_1, TickMath.minUsableTick(60), 0);
        _expectInvalidBase(address(managed), foreign);
        _expectInvalidBase(address(managed), managed.poolKey());
    }

    function test_externalBaseOwnerCanRegisterNewBaseThenLaunchWithoutBaseIerc20TMethods() public {
        (MockERC20 second, PoolKey memory secondKey) = _basePool(true);
        hook.registerExternalBase(address(second), secondKey);
        ERC20T child = factory.create(_config(address(second)));
        _launch(child);
        assertGt(_buy(child, 1 ether), 0);
        _assertSettled(child);
    }

    function test_externalBaseDisableBlocksNewLaunchesButPreservesSwapsAndLpWithdrawals() public {
        ERC20T[2] memory children = [child0, child1];
        for (uint256 i; i < children.length; ++i) {
            ERC20T child = children[i];
            _roundTrip(child);
            base.mint(bob, 1 ether);
            child.transfer(bob, 1 ether);
            vm.startPrank(bob);
            base.approve(address(modifyLiquidityRouter), type(uint256).max);
            child.approve(address(modifyLiquidityRouter), type(uint256).max);
            vm.stopPrank();
            child.setExternalLiquidityEnabled(true);
            PoolKey memory poolKey = child.poolKey();
            uint256 baseBefore = base.balanceOf(bob);
            uint256 childBefore = child.balanceOf(bob);
            vm.prank(bob);
            modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
            assertLt(base.balanceOf(bob), baseBefore);
            assertLt(child.balanceOf(bob), childBefore);
        }
        hook.setExternalBaseEnabled(address(base), false);
        ERC20T blocked = factory.create(_config(address(base)));
        _expectLaunchFailure(blocked, ERC20THook.ExternalBaseDisabled.selector);
        for (uint256 i; i < children.length; ++i) {
            ERC20T child = children[i];
            _roundTrip(child);
            child.setExternalLiquidityEnabled(false);
            PoolKey memory poolKey = child.poolKey();
            uint256 baseBefore = base.balanceOf(bob);
            uint256 childBefore = child.balanceOf(bob);
            vm.prank(bob);
            modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
            assertGt(base.balanceOf(bob), baseBefore);
            assertGt(child.balanceOf(bob), childBefore);
            _assertSettled(child);
        }
        hook.setExternalBaseEnabled(address(base), true);
        _launch(blocked);
        assertTrue(blocked.launched());
    }

    function _poolState(PoolKey memory poolKey) private view returns (bytes32) {
        (uint160 sqrtPrice, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolKey.toId());
        return keccak256(abi.encode(sqrtPrice, tick, protocolFee, lpFee, manager.getLiquidity(poolKey.toId())));
    }

    function _state(ERC20T child, MockERC20 quote, PoolKey memory quoteKey) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _poolState(quoteKey),
                _poolState(child.poolKey()),
                quote.balanceOf(alice),
                child.balanceOf(alice),
                alice.balance,
                address(manager).balance,
                quote.balanceOf(address(manager)),
                child.balanceOf(address(manager)),
                tokenFees.balance,
                protocolFees.balance,
                externalFees.balance,
                quote.balanceOf(externalFees)
            )
        );
    }

    function _expectConversionFailure(bool partiallyFillable) private {
        (MockERC20 scarce, PoolKey memory scarceKey) = _basePool(false);
        hook.registerExternalBase(address(scarce), scarceKey);
        ERC20T child = factory.create(_config(address(scarce)));
        _launch(child);
        if (partiallyFillable) {
            vm.deal(bob, 0.001 ether);
            vm.prank(bob);
            swapRouter.swap{value: 0.001 ether}(
                scarceKey,
                SwapParams(true, -int256(0.001 ether), MIN_PRICE_LIMIT),
                PoolSwapTest.TestSettings(false, false),
                ZERO_BYTES
            );
            (uint160 sqrtPrice,,,) = manager.getSlot0(scarceKey.toId());
            uint256 capacity =
                SqrtPriceMath.getAmount1Delta(sqrtPrice, SQRT_PRICE_1_1, manager.getLiquidity(scarceKey.toId()), true);
            assertGt(capacity, 0);
            assertLt(capacity, 0.01 ether);
            assertGt(scarce.balanceOf(bob), 0);
        }
        // The singleton holds substantial ETH for the other pool; only this route's liquidity counts.
        assertGt(address(manager).balance, 100 ether);
        scarce.mint(alice, 1 ether);
        vm.prank(alice);
        scarce.approve(address(swapRouter), type(uint256).max);
        PoolKey memory poolKey = child.poolKey();
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(scarce);
        bytes32 before = _state(child, scarce, scarceKey);
        bytes memory expected = _hookError(IHooks.afterSwap.selector, ERC20THook.PartialFeeSwap.selector);
        vm.prank(alice);
        vm.expectRevert(expected);
        _swap(poolKey, zeroForOne, -int256(1 ether));
        assertEq(_state(child, scarce, scarceKey), before);
        _assertSettled(child);
    }

    function test_externalBaseEmptyEthConversionRollsBackTradeAndBothProtocolsFees() public {
        _expectConversionFailure(false);
    }

    function test_externalBasePartialEthConversionRollsBackTradeAndBothProtocolsFees() public {
        _expectConversionFailure(true);
    }

    function test_externalBaseRouterPostTaxMinimumRevertsAllPoolsAndFeePayouts() public {
        ERC20T[2] memory children = [child0, child1];
        for (uint256 i; i < children.length; ++i) {
            ERC20T child = children[i];
            bytes memory actions = _route(child, true, 1 ether, 1 ether);
            bytes32 before = _state(child, base, baseKey);
            vm.prank(alice);
            vm.expectPartialRevert(IV4Router.V4TooLittleReceived.selector);
            router.executeActions{value: 1 ether}(actions);
            assertEq(_state(child, base, baseKey), before);
            _assertSettled(child);
        }
    }

    function test_externalBaseExactOutputIsRejectedInBothDirectionsAndOrderings() public {
        ERC20T[2] memory children = [child0, child1];
        for (uint256 i; i < children.length; ++i) {
            _buy(children[i], 1 ether);
            PoolKey memory poolKey = children[i].poolKey();
            for (uint256 direction; direction < 2; ++direction) {
                bytes memory expected = _hookError(IHooks.afterSwap.selector, ERC20THook.ExactOutputNotAllowed.selector);
                vm.expectRevert(expected);
                _swap(poolKey, direction == 0, int256(0.01 ether));
            }
        }
    }
}
