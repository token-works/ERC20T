// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {TokenPosmHelper} from "../support/TokenPosmHelper.sol";

/// @notice Reproducible native-pool deployment and swap gas measurements.
/// @dev Uses gasleft around the operation: execution gas before refunds, excluding intrinsic
///      transaction/calldata gas, setup, assertions and logging. vm.cool resets all external
///      accounts and storage first; the warm variants warm only the shared implementation.
///      The optional implementation lookup keeps this harness comparable with the pre-clone factory.
contract ERC20TGasTest is Test, TokenPosmHelper {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant PRICE = 0.00001 ether;
    uint256 constant BUY = 0.1 ether;
    address constant OWNER = address(0x10001);
    address constant ALICE = address(0x10002);
    address constant BOB = address(0x10003);
    address constant TREASURY = address(0x10004);
    address constant PROTOCOL = address(0x10005);
    IPoolManager manager;
    PoolSwapTest router;
    ERC20THook hook;
    ERC20TFactory factory;
    ERC20T token;
    address implementation;
    PoolKey key;
    uint256 sellAmount;

    function setUp() public {
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        _deployPosm(manager);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, address(this), PROTOCOL, new ERC20THook.ExternalBaseConfig[](0), address(0))
        );
        vm.prank(CREATE2_DEPLOYER);
        hook = new ERC20THook{salt: salt}(
            manager, address(this), PROTOCOL, new ERC20THook.ExternalBaseConfig[](0), address(0)
        );
        factory = new ERC20TFactory();
        (bool hasImplementation, bytes memory data) =
            address(factory).staticcall(abi.encodeWithSignature("implementation()"));
        if (hasImplementation && data.length == 32) implementation = abi.decode(data, (address));
        token = factory.createAndLaunchAtPrice(_config(), 2_000, PRICE);
        key = token.poolKey();
        vm.deal(address(manager), 100 ether);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        vm.prank(ALICE);
        router.swap{value: BUY}(
            key,
            SwapParams(true, -int256(BUY), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        sellAmount = token.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        token.approve(address(router), type(uint256).max);
    }

    function _config() private view returns (ERC20T.Config memory) {
        return ERC20T.Config({
            name: "Gas Benchmark",
            symbol: "GAS",
            supply: SUPPLY,
            lpSupply: 800_000 ether,
            owner: OWNER,
            hook: address(hook),
            quoteToken: address(0),
            positionManager: posm,
            permit2: IAllowanceTransfer(PERMIT2_ADDR),
            taxBps: 100,
            feeRecipient: TREASURY,
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0,
            feeDecayRecipient: address(0)
        });
    }

    function _cool() private {
        vm.cool(address(factory));
        vm.cool(address(token));
        vm.cool(address(hook));
        vm.cool(address(manager));
        vm.cool(address(router));
        vm.cool(address(posm));
        vm.cool(PERMIT2_ADDR);
        vm.cool(OWNER);
        vm.cool(ALICE);
        vm.cool(BOB);
        vm.cool(TREASURY);
        vm.cool(PROTOCOL);
        if (implementation != address(0)) vm.cool(implementation);
    }

    function _warmImplementation() private view {
        if (implementation != address(0)) require(implementation.code.length > 0);
    }

    function testGasFactoryDeployment() public {
        _cool();
        uint256 start = gasleft();
        ERC20TFactory another = new ERC20TFactory();
        uint256 used = start - gasleft();
        emit log_named_uint("factory_deployment", used);
        assertGt(address(another).code.length, 0);
    }

    function testGasCreateAndLaunch() public {
        ERC20T.Config memory config = _config();
        _cool();
        uint256 start = gasleft();
        ERC20T another = factory.createAndLaunchAtPrice(config, 2_000, PRICE);
        uint256 used = start - gasleft();
        emit log_named_uint("create_and_launch", used);
        assertEq(another.totalSupply(), SUPPLY);
        assertEq(another.owner(), OWNER);
        assertTrue(another.launched());
    }

    function _benchBuy(bool warmImplementation) private {
        _cool();
        if (warmImplementation) _warmImplementation();
        vm.prank(BOB);
        uint256 start = gasleft();
        BalanceDelta delta = router.swap{value: BUY}(
            key,
            SwapParams(true, -int256(BUY), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 used = start - gasleft();
        emit log_named_uint(warmImplementation ? "buy_impl_warm" : "buy_cold", used);
        assertGt(int256(delta.amount1()), 0);
    }

    function _benchSell(bool warmImplementation) private {
        uint256 amount = sellAmount;
        _cool();
        if (warmImplementation) _warmImplementation();
        vm.prank(ALICE);
        uint256 start = gasleft();
        BalanceDelta delta = router.swap(
            key,
            SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 used = start - gasleft();
        emit log_named_uint(warmImplementation ? "sell_impl_warm" : "sell_cold", used);
        assertGt(int256(delta.amount0()), 0);
    }

    function testGasColdBuy() public {
        _benchBuy(false);
    }

    function testGasColdSell() public {
        _benchSell(false);
    }

    function testGasImplementationWarmBuy() public {
        _benchBuy(true);
    }

    function testGasImplementationWarmSell() public {
        _benchSell(true);
    }
}
