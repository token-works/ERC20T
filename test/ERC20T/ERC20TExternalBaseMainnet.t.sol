// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20T_TICK_SPACING} from "../../src/ERC20T/ERC20TInterfaces.sol";

interface IERC20TMainnetBase {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function poolKey() external view returns (PoolKey memory);
    function poolManager() external view returns (IPoolManager);
    function isDistributor(address account) external view returns (bool);
    function externalBuysEnabled() external view returns (bool);
}

/// @dev Exact-input route helper that settles only the initial input and final output.
/// All deployments and trades in this file take place in Forge's local fork state.
contract ERC20TExternalBaseForkRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey[] memory path, address input, uint256 amountIn) external payable returns (uint256) {
        require(msg.value == (input == address(0) ? amountIn : 0), "wrong native input");
        return abi.decode(manager.unlock(abi.encode(msg.sender, path, input, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address trader, PoolKey[] memory path, address input, uint256 amountIn) =
            abi.decode(data, (address, PoolKey[], address, uint256));
        Currency current = Currency.wrap(input);
        uint256 amountOut = amountIn;
        for (uint256 i; i < path.length; ++i) {
            bool zeroForOne = current == path[i].currency0;
            require(zeroForOne || current == path[i].currency1, "disconnected route");
            BalanceDelta delta = manager.swap(
                path[i],
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountOut),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            assert(uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1())) == amountOut);
            if (i != 0) require(manager.currencyDelta(address(this), current) == 0, "intermediate did not net");
            amountOut = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
            current = zeroForOne ? path[i].currency1 : path[i].currency0;
        }
        if (input == address(0)) {
            manager.settle{value: amountIn}();
        } else {
            manager.sync(Currency.wrap(input));
            SafeTransferLib.safeTransferFrom(input, trader, address(manager), amountIn);
            manager.settle();
        }
        manager.take(current, trader, amountOut);
        return abi.encode(amountOut);
    }
}

contract ERC20TExternalBaseRestrictedReceiver {}

/// @notice Opt-in live-pool integration: invoke forge test --fork-url mainnet.
/// @dev Ordinary nonfork runs skip. Uses real mainnet token, hook, PoolManager,
///      PositionManager and Permit2 state; only trader ETH balances are funded locally.
contract ERC20TExternalBaseMainnetTest is Test {
    using TransientStateLibrary for IPoolManager;

    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM = address(bytes20(hex"bd216513d74c8cf14cf4747e6aaa6420ff64ee9e"));
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant FWA_HOOK = address(bytes20(hex"2c67eba8a50af0db5fba55f725247a75cbda6444"));
    address constant IMD_HOOK = address(bytes20(hex"c6c965bd164c483e87d0b550671798e9a3602840"));
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant LP_SUPPLY = 800_000 ether;
    uint256 constant ETH_INPUT = 0.01 ether;
    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant FEE_EVENT = keccak256("HookFee(address,address,address,uint256,uint256)");
    bytes32 constant PROTOCOL_EVENT = keccak256("ProtocolFee(address,address,address,uint256)");
    bytes32 constant DECAY_EVENT = keccak256("FeeDecay(address,address,address,uint256)");
    bytes32 constant FWA_FEE_EVENT = keccak256("HookFee(bytes32,address,uint128,uint128)");

    struct Fees {
        uint256 tokenFee;
        uint256 tokenEth;
        uint256 protocolEth;
        uint256 decayEth;
        uint256 conversionEth;
        uint256 conversionBase;
        uint256 grossChildOutput;
        uint256 externalTaxEth;
        uint256 tokenEvents;
        uint256 protocolEvents;
        uint256 decayEvents;
        uint256 conversions;
    }

    struct FeeBalances {
        uint256 token;
        uint256 protocol;
        uint256 decay;
    }

    IPoolManager manager;
    ERC20THook hook;
    ERC20TFactory factory;
    ERC20TExternalBaseForkRouter router;
    ERC20TExternalBaseRestrictedReceiver restrictedReceiver;
    PoolKey fwaPool;
    PoolKey imdPool;
    uint256 hookInitialEth;
    uint256 routerInitialEth;
    address alice = makeAddr("externalBaseForkAlice");
    address tokenFees = makeAddr("externalBaseForkTokenFees");
    address protocolFees = makeAddr("externalBaseForkProtocolFees");
    address decayFees = makeAddr("externalBaseForkDecayFees");

    function setUp() public {
        if (block.chainid != 1 || MANAGER.code.length == 0) {
            vm.skip(true);
            return;
        }
        assertGt(POSM.code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        manager = IPoolManager(MANAGER);
        fwaPool = IERC20TMainnetBase(FWA).poolKey();
        imdPool = IERC20TMainnetBase(IMD_HOOK).poolKey();
        _assertNativePool(fwaPool, FWA, FWA_HOOK, 0);
        _assertNativePool(imdPool, IMD, IMD_HOOK, 10_000);
        assertEq(address(IERC20TMainnetBase(FWA).poolManager()), MANAGER);
        assertEq(address(IERC20TMainnetBase(IMD_HOOK).poolManager()), MANAGER);
        assertTrue(IERC20TMainnetBase(FWA).isDistributor(MANAGER), "FWA settlement permission missing");
        assertTrue(IERC20TMainnetBase(FWA_HOOK).externalBuysEnabled(), "FWA external buys disabled");

        ERC20THook.ExternalBaseConfig[] memory bases = new ERC20THook.ExternalBaseConfig[](2);
        bases[0] = ERC20THook.ExternalBaseConfig(FWA, fwaPool);
        bases[1] = ERC20THook.ExternalBaseConfig(IMD, imdPool);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, address(this), protocolFees, bases, address(0))
        );
        vm.prank(CREATE2_DEPLOYER);
        hook = new ERC20THook{salt: salt}(manager, address(this), protocolFees, bases, address(0));
        assertEq(address(hook), expected);
        factory = new ERC20TFactory();
        router = new ERC20TExternalBaseForkRouter(manager);
        restrictedReceiver = new ERC20TExternalBaseRestrictedReceiver();
        // CREATE addresses can already hold ETH on a fork; swaps must preserve that balance.
        hookInitialEth = address(hook).balance;
        routerInitialEth = address(router).balance;
        vm.deal(alice, 10 ether);
    }

    function _assertNativePool(PoolKey memory key, address base, address baseHook, uint24 fee) private pure {
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), base);
        assertEq(address(key.hooks), baseHook);
        assertEq(key.fee, fee);
        assertEq(key.tickSpacing, 60);
    }

    function _launchChild(address base, bool childIsCurrency0, bool decliningTax) private returns (ERC20T child) {
        ERC20T.Config memory config = ERC20T.Config({
            name: "Mainnet Fork Child",
            symbol: "FORK",
            supply: SUPPLY,
            lpSupply: LP_SUPPLY,
            owner: address(this),
            hook: address(hook),
            quoteToken: base,
            positionManager: IPositionManager(POSM),
            permit2: IAllowanceTransfer(PERMIT2),
            taxBps: 300,
            feeRecipient: tokenFees,
            feeDecayRecipient: decayFees,
            launchTaxBps: decliningTax ? 9_900 : 0,
            taxDecayIntervalSeconds: decliningTax ? 60 : 0
        });
        bytes memory args = abi.encodePacked(address(hook), base, MANAGER, POSM, PERMIT2);
        address implementation = factory.implementation();
        bytes32 initHash = LibClone.initCodeHash(implementation, args);
        for (uint256 i; i < 10_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = LibClone.predictDeterministicAddress(initHash, salt, address(this));
            if ((predicted < base) == childIsCurrency0 && predicted.code.length == 0) {
                child = ERC20T(LibClone.cloneDeterministic(implementation, args, salt));
                child.initialize(config);
                break;
            }
        }
        assertTrue(address(child) != address(0), "could not select child ordering");
        uint256 baseBefore = IERC20TMainnetBase(base).balanceOf(MANAGER);
        child.launch(
            uint160(1 << 96),
            childIsCurrency0 ? int24(0) : TickMath.minUsableTick(ERC20T_TICK_SPACING),
            childIsCurrency0 ? TickMath.maxUsableTick(ERC20T_TICK_SPACING) : int24(0)
        );
        assertEq(child.quoteToken(), base);
        assertEq(address(child) < base, childIsCurrency0);
        assertTrue(child.launched());
        assertTrue(hook.poolInitialized(address(child)));
        assertEq(IERC20TMainnetBase(base).balanceOf(MANAGER), baseBefore, "launch spent quote tokens");
        assertEq(IERC20TMainnetBase(base).balanceOf(address(child)), 0);
        assertEq(child.balanceOf(MANAGER) + child.balanceOf(address(child)), LP_SUPPLY);
        assertEq(child.balanceOf(address(this)), SUPPLY - LP_SUPPLY);
        assertEq(child.allowance(address(child), PERMIT2), 0);
    }

    function _path(PoolKey memory key) private pure returns (PoolKey[] memory path) {
        path = new PoolKey[](1);
        path[0] = key;
    }

    function _path(PoolKey memory first, PoolKey memory second) private pure returns (PoolKey[] memory path) {
        path = new PoolKey[](2);
        path[0] = first;
        path[1] = second;
    }

    function _assertFees(ERC20T child, PoolKey memory nativePool, FeeBalances memory balancesBefore, bool buy)
        private
        view
        returns (Fees memory fees)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nativePoolId = PoolId.unwrap(nativePool.toId());
        bytes32 childPoolId = PoolId.unwrap(child.poolKey().toId());
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (
                logs[i].emitter == MANAGER && logs[i].topics[0] == SWAP_EVENT && logs[i].topics[1] == nativePoolId
                    && address(uint160(uint256(logs[i].topics[2]))) == address(hook)
            ) {
                (int128 ethDelta, int128 baseDelta,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertGt(int256(ethDelta), 0);
                fees.conversionEth += uint256(int256(ethDelta));
                fees.conversionBase += uint256(-int256(baseDelta));
                ++fees.conversions;
            }
            if (
                logs[i].emitter == MANAGER && logs[i].topics[0] == SWAP_EVENT && logs[i].topics[1] == childPoolId
                    && address(uint160(uint256(logs[i].topics[2]))) == address(router)
            ) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                bool outputIsCurrency0 = (address(child) < child.quoteToken()) == buy;
                fees.grossChildOutput = uint256(int256(outputIsCurrency0 ? amount0 : amount1));
            }
            if (
                logs[i].emitter == FWA_HOOK && logs[i].topics[0] == FWA_FEE_EVENT
                    && address(uint160(uint256(logs[i].topics[2]))) == address(hook)
            ) {
                (uint128 ethFee, uint128 tokenFee) = abi.decode(logs[i].data, (uint128, uint128));
                assertEq(tokenFee, 0);
                fees.externalTaxEth += ethFee;
            }
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == FEE_EVENT) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(child));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), tokenFees);
                (fees.tokenFee, fees.tokenEth) = abi.decode(logs[i].data, (uint256, uint256));
                ++fees.tokenEvents;
            } else if (logs[i].topics[0] == PROTOCOL_EVENT) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(child));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), protocolFees);
                fees.protocolEth = abi.decode(logs[i].data, (uint256));
                ++fees.protocolEvents;
            } else if (logs[i].topics[0] == DECAY_EVENT) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(child));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), decayFees);
                fees.decayEth = abi.decode(logs[i].data, (uint256));
                ++fees.decayEvents;
            }
        }
        assertEq(fees.conversions, 1);
        assertEq(fees.tokenEvents, 1);
        assertEq(fees.protocolEvents, 1);
        assertGt(fees.tokenEth, 0);
        assertGt(fees.protocolEth, 0);
        uint256 totalEth = fees.tokenEth + fees.protocolEth + fees.decayEth;
        assertEq(totalEth, fees.conversionEth - fees.externalTaxEth, "payout must use net conversion ETH");
        assertEq(fees.protocolEth, totalEth * 15 / child.taxBps());
        assertEq(fees.decayEth, totalEth * (child.taxBps() - child.restingTaxBps()) / child.taxBps());
        assertEq(fees.decayEvents, fees.decayEth == 0 ? 0 : 1);
        assertEq(fees.tokenEth, totalEth - fees.protocolEth - fees.decayEth);
        assertGt(fees.grossChildOutput, 0);
        uint256 expectedOutputTax = fees.grossChildOutput * child.taxBps() / 10_000;
        assertEq(buy ? fees.tokenFee : fees.conversionBase, expectedOutputTax);
        assertEq(tokenFees.balance - balancesBefore.token, fees.tokenEth);
        assertEq(protocolFees.balance - balancesBefore.protocol, fees.protocolEth);
        assertEq(decayFees.balance - balancesBefore.decay, fees.decayEth);
        if (child.quoteToken() == FWA) {
            assertEq(fees.externalTaxEth, fees.conversionEth / 100, "FWA conversion retains its own 1% tax");
        } else {
            assertEq(fees.externalTaxEth, 0);
        }
    }

    function _assertSettled(ERC20T child, address base) private view {
        assertEq(child.quoteToken(), base);
        assertEq(child.getTransferAllowance(true), 0);
        assertEq(child.getTransferAllowance(false), 0);
        assertEq(child.getNetTransferAllowance(), 0);
        assertEq(child.balanceOf(address(hook)), 0);
        assertEq(child.balanceOf(address(router)), 0);
        assertEq(IERC20TMainnetBase(base).balanceOf(address(hook)), 0);
        assertEq(IERC20TMainnetBase(base).balanceOf(address(router)), 0);
        assertEq(address(hook).balance, hookInitialEth, "hook retained swap ETH");
        assertEq(address(router).balance, routerInitialEth, "router retained swap ETH");
        address[2] memory callers = [address(hook), address(router)];
        for (uint256 i; i < callers.length; ++i) {
            assertEq(manager.currencyDelta(callers[i], Currency.wrap(base)), 0);
            assertEq(manager.currencyDelta(callers[i], Currency.wrap(address(child))), 0);
            assertEq(manager.currencyDelta(callers[i], Currency.wrap(address(0))), 0);
        }
    }

    function _roundTrip(address base, PoolKey memory nativePool, bool childIsCurrency0, bool multiHop) private {
        ERC20T child = _launchChild(base, childIsCurrency0, false);
        _tradeRoundTrip(child, base, nativePool, multiHop);
    }

    function _decliningTaxRoundTrip(address base, PoolKey memory nativePool, bool childIsCurrency0, bool multiHop)
        private
    {
        ERC20T child = _launchChild(base, childIsCurrency0, true);
        assertEq(child.taxBps(), 9_900);
        _tradeRoundTrip(child, base, nativePool, multiHop);
        vm.warp(child.launchedAt() + 96 * 60);
        assertEq(child.taxBps(), 300);
        assertFalse(child.taxDecayActive());
        _tradeRoundTrip(child, base, nativePool, multiHop);
    }

    function _tradeRoundTrip(ERC20T child, address base, PoolKey memory nativePool, bool multiHop) private {
        PoolKey memory childPool = child.poolKey();
        uint256 amountIn = ETH_INPUT;
        if (!multiHop) {
            vm.prank(alice);
            amountIn = router.swap{value: ETH_INPUT}(_path(nativePool), address(0), ETH_INPUT);
            assertGt(amountIn, 0);
            amountIn /= 2;
            vm.prank(alice);
            IERC20TMainnetBase(base).approve(address(router), type(uint256).max);
        }
        FeeBalances memory balancesBefore = FeeBalances(tokenFees.balance, protocolFees.balance, decayFees.balance);
        vm.recordLogs();
        vm.prank(alice);
        uint256 bought = router.swap{value: multiHop ? amountIn : 0}(
            multiHop ? _path(nativePool, childPool) : _path(childPool), multiHop ? address(0) : base, amountIn
        );
        Fees memory buyFees = _assertFees(child, nativePool, balancesBefore, true);
        assertGt(bought, 0);
        assertEq(bought, buyFees.grossChildOutput - buyFees.tokenFee);
        assertEq(child.balanceOf(alice), bought);
        _assertSettled(child, base);
        assertFalse(child.isDistributor(address(router)));
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        child.transfer(address(restrictedReceiver), 1);

        vm.prank(alice);
        child.approve(address(router), type(uint256).max);
        balancesBefore = FeeBalances(tokenFees.balance, protocolFees.balance, decayFees.balance);
        uint256 balanceBefore = multiHop ? alice.balance : IERC20TMainnetBase(base).balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 sold = router.swap(multiHop ? _path(childPool, nativePool) : _path(childPool), address(child), bought);
        _assertFees(child, nativePool, balancesBefore, false);
        assertGt(sold, 0);
        assertLt(sold, amountIn);
        uint256 balanceAfter = multiHop ? alice.balance : IERC20TMainnetBase(base).balanceOf(alice);
        assertEq(balanceAfter, balanceBefore + sold);
        assertEq(child.balanceOf(alice), 0);
        _assertSettled(child, base);
    }

    function testFork_fwaDirectRoundTripBothChildOrderings() public {
        _roundTrip(FWA, fwaPool, true, false);
        _roundTrip(FWA, fwaPool, false, false);
    }

    function testFork_fwaEthMultihopRoundTripBothChildOrderings() public {
        _roundTrip(FWA, fwaPool, true, true);
        _roundTrip(FWA, fwaPool, false, true);
    }

    function testFork_imdDirectRoundTripBothChildOrderings() public {
        _roundTrip(IMD, imdPool, true, false);
        _roundTrip(IMD, imdPool, false, false);
    }

    function testFork_imdEthMultihopRoundTripBothChildOrderings() public {
        _roundTrip(IMD, imdPool, true, true);
        _roundTrip(IMD, imdPool, false, true);
    }

    function testFork_fwaDirectRoundTripAt99PercentAndRestingRateBothChildOrderings() public {
        _decliningTaxRoundTrip(FWA, fwaPool, true, false);
        _decliningTaxRoundTrip(FWA, fwaPool, false, false);
    }

    function testFork_fwaEthMultihopRoundTripAt99PercentAndRestingRateBothChildOrderings() public {
        _decliningTaxRoundTrip(FWA, fwaPool, true, true);
        _decliningTaxRoundTrip(FWA, fwaPool, false, true);
    }

    function testFork_imdDirectRoundTripAt99PercentAndRestingRateBothChildOrderings() public {
        _decliningTaxRoundTrip(IMD, imdPool, true, false);
        _decliningTaxRoundTrip(IMD, imdPool, false, false);
    }

    function testFork_imdEthMultihopRoundTripAt99PercentAndRestingRateBothChildOrderings() public {
        _decliningTaxRoundTrip(IMD, imdPool, true, true);
        _decliningTaxRoundTrip(IMD, imdPool, false, true);
    }
}
