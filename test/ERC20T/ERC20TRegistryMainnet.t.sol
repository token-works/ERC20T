// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {IERC20TGlobalDistributorRegistry} from "../../src/ERC20T/ERC20TInterfaces.sol";
import {ERC20TExternalBaseForkRouter} from "./ERC20TExternalBaseMainnet.t.sol";

/// @notice Opt-in compatibility test against the deployed factory and TokenWorks registry.
/// @dev Use a mainnet fork at block 26220519. All deployments, transfers and swaps
///      execute only in Forge's local fork; live factory, implementation and registry code is preserved.
contract ERC20TRegistryMainnetTest is Test {
    using TransientStateLibrary for IPoolManager;

    address constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSM = address(bytes20(hex"bd216513d74c8cf14cf4747e6aaa6420ff64ee9e"));
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant FACTORY = 0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173;
    address constant IMPLEMENTATION = address(bytes20(hex"2df7dcf4d19a7924e00ae96629cc1d1261670eee"));
    address constant REGISTRY = 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D;
    address constant HOOK_OWNER = 0x019817aD02a31B990433542097bE29D97613E8Cb;
    address constant GLOBAL_DISTRIBUTOR = 0x23617e59A5925b2A4Bf75d73ff6711cD0b29De85;
    address constant UNAPPROVED_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant ETH_INPUT = 0.01 ether;

    IPoolManager manager;
    ERC20THook hook;
    ERC20TFactory factory;
    ERC20TExternalBaseForkRouter router;
    address tokenOwner = makeAddr("registryMainnetTokenOwner");
    address alice = makeAddr("registryMainnetAlice");
    address tokenFees = makeAddr("registryMainnetTokenFees");
    address protocolFees = makeAddr("registryMainnetProtocolFees");
    uint256 initialHookEth;
    uint256 initialRouterEth;

    function setUp() public {
        if (block.chainid != 1 || FACTORY.code.length == 0) {
            vm.skip(true);
            return;
        }
        assertGt(MANAGER.code.length, 0);
        assertGt(POSM.code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        assertGt(REGISTRY.code.length, 0);
        assertGt(IMPLEMENTATION.code.length, 0);
        factory = ERC20TFactory(payable(FACTORY));
        assertEq(factory.implementation(), IMPLEMENTATION);
        manager = IPoolManager(MANAGER);
        ERC20THook.ExternalBaseConfig[] memory bases = new ERC20THook.ExternalBaseConfig[](0);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, HOOK_OWNER, protocolFees, bases, REGISTRY)
        );
        vm.prank(CREATE2_DEPLOYER);
        hook = new ERC20THook{salt: salt}(manager, HOOK_OWNER, protocolFees, bases, REGISTRY);
        assertEq(address(hook), expected);
        assertEq(hook.owner(), HOOK_OWNER);
        assertEq(hook.globalDistributorRegistry(), REGISTRY);
        router = new ERC20TExternalBaseForkRouter(manager);
        initialHookEth = address(hook).balance;
        initialRouterEth = address(router).balance;
        vm.deal(alice, 1 ether);
    }

    function testFork_existingFactoryLaunchesAndTradesWithLiveGlobalRegistry() public {
        assertGt(GLOBAL_DISTRIBUTOR.code.length, 0);
        assertTrue(IERC20TGlobalDistributorRegistry(REGISTRY).isGlobalDistributor(GLOBAL_DISTRIBUTOR));
        assertFalse(IERC20TGlobalDistributorRegistry(REGISTRY).isGlobalDistributor(UNAPPROVED_ROUTER));
        assertFalse(hook.isHookDistributor(GLOBAL_DISTRIBUTOR));
        assertTrue(hook.isDistributor(GLOBAL_DISTRIBUTOR));
        assertFalse(hook.isDistributor(UNAPPROVED_ROUTER));

        ERC20T.Config memory config = ERC20T.Config({
            name: "Existing Factory Registry Fork",
            symbol: "REGFORK",
            supply: SUPPLY,
            lpSupply: SUPPLY * 8 / 10,
            owner: tokenOwner,
            hook: address(hook),
            quoteToken: address(0),
            positionManager: IPositionManager(POSM),
            permit2: IAllowanceTransfer(PERMIT2),
            taxBps: 300,
            feeRecipient: tokenFees,
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0,
            feeDecayRecipient: tokenFees
        });
        ERC20T token = factory.createAndLaunchAtPrice(config, 2_000, 0.000001 ether);
        assertEq(LibClone.implementationOf(address(token)), IMPLEMENTATION);
        assertEq(token.owner(), tokenOwner);
        assertEq(token.hook(), address(hook));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(tokenOwner), SUPPLY / 5);
        assertTrue(token.launched());
        assertTrue(hook.poolInitialized(address(token)));
        assertTrue(token.useGlobalDistributors());
        assertTrue(token.isDistributor(GLOBAL_DISTRIBUTOR));
        assertFalse(token.isLocalDistributor(GLOBAL_DISTRIBUTOR));
        assertFalse(token.isDistributor(UNAPPROVED_ROUTER));

        // The old implementation must enforce the new hook's live external approval.
        vm.prank(tokenOwner);
        token.transfer(alice, 2 ether);
        vm.prank(alice);
        token.transfer(GLOBAL_DISTRIBUTOR, 1 ether);
        assertEq(token.balanceOf(GLOBAL_DISTRIBUTOR), 1 ether);
        vm.prank(tokenOwner);
        token.setUseGlobalDistributors(false);
        assertFalse(token.isDistributor(GLOBAL_DISTRIBUTOR));
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(GLOBAL_DISTRIBUTOR, 1 ether);
        vm.prank(tokenOwner);
        token.setUseGlobalDistributors(true);

        PoolKey[] memory path = new PoolKey[](1);
        path[0] = token.poolKey();
        uint256 tokenBalanceBefore = token.balanceOf(alice);
        uint256 tokenFeesBefore = tokenFees.balance;
        uint256 protocolFeesBefore = protocolFees.balance;
        vm.prank(alice);
        uint256 bought = router.swap{value: ETH_INPUT}(path, address(0), ETH_INPUT);
        assertGt(bought, 0);
        assertEq(token.balanceOf(alice), tokenBalanceBefore + bought);
        assertGt(tokenFees.balance, tokenFeesBefore);
        assertGt(protocolFees.balance, protocolFeesBefore);
        _assertSettled(token);

        vm.prank(alice);
        token.approve(address(router), bought);
        uint256 aliceEthBefore = alice.balance;
        tokenFeesBefore = tokenFees.balance;
        protocolFeesBefore = protocolFees.balance;
        vm.prank(alice);
        uint256 sold = router.swap(path, address(token), bought);
        assertGt(sold, 0);
        assertLt(sold, ETH_INPUT);
        assertEq(alice.balance, aliceEthBefore + sold);
        assertEq(token.balanceOf(alice), tokenBalanceBefore);
        assertGt(tokenFees.balance, tokenFeesBefore);
        assertGt(protocolFees.balance, protocolFeesBefore);
        _assertSettled(token);
    }

    function _assertSettled(ERC20T token) private view {
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getNetTransferAllowance(), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(address(hook).balance, initialHookEth);
        assertEq(address(router).balance, initialRouterEth);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertEq(manager.currencyDelta(address(router), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(router), Currency.wrap(address(token))), 0);
    }
}
