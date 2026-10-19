// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {
    DeployERC20TMainnet,
    DeployERC20THookMainnet,
    ERC20TMainnetDeployment
} from "../../script/ERC20T/DeployERC20TMainnet.s.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";

contract ERC20TMainnetScriptTest is Test {
    DeployERC20TMainnet script;

    function setUp() public {
        script = new DeployERC20TMainnet();
        // The script's chain configuration is fixed. Model only its read-only deployment inputs;
        // external-base integration and fork tests exercise actual PoolManager pools and swaps.
        vm.etch(script.POOL_MANAGER(), hex"00");
        vm.etch(script.GLOBAL_DISTRIBUTOR_REGISTRY(), hex"00");
        vm.mockCall(
            script.GLOBAL_DISTRIBUTOR_REGISTRY(),
            abi.encodeWithSignature("isGlobalDistributor(address)"),
            abi.encode(false)
        );
        ERC20THook.ExternalBaseConfig[] memory bases = script.initialBases();
        for (uint256 i; i < bases.length; ++i) {
            vm.etch(bases[i].token, hex"00");
            vm.etch(address(bases[i].ethPool.hooks), hex"00");
            bytes32 slot = keccak256(abi.encode(keccak256(abi.encode(bases[i].ethPool)), uint256(6)));
            vm.mockCall(
                script.POOL_MANAGER(), abi.encodeWithSignature("extsload(bytes32)", slot), abi.encode(uint256(1 << 96))
            );
        }
        vm.mockCall(
            script.FWA_TOKEN(),
            abi.encodeWithSignature("isDistributor(address)", script.POOL_MANAGER()),
            abi.encode(true)
        );
        vm.mockCall(script.FWA_ETH_HOOK(), abi.encodeWithSignature("externalBuysEnabled()"), abi.encode(true));
    }

    function test_deploysSharedSystemWithFixedMainnetSettings() public {
        vm.chainId(1);
        (ERC20THook hook, ERC20TFactory factory) = script.run();

        assertEq(address(hook.poolManager()), script.POOL_MANAGER());
        assertEq(hook.owner(), 0x019817aD02a31B990433542097bE29D97613E8Cb);
        assertEq(hook.owner(), script.HOOK_OWNER());
        assertEq(hook.globalDistributorRegistry(), 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D);
        assertNotEq(hook.owner(), hook.globalDistributorRegistry());
        assertEq(hook.protocolFeeRecipient(), script.PROTOCOL_FEE_RECIPIENT());
        uint160 permissions = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, permissions);
        assertGt(address(hook).code.length, 0);
        assertGt(address(factory).code.length, 0);
        address implementation = factory.implementation();
        assertGt(implementation.code.length, 0);
        ERC20THook.ExternalBaseConfig[] memory bases = script.initialBases();
        for (uint256 i; i < bases.length; ++i) {
            (bool registered, bool enabled) = hook.externalBases(bases[i].token);
            assertTrue(registered);
            assertTrue(enabled);
            assertEq(abi.encode(hook.externalBasePool(bases[i].token)), abi.encode(bases[i].ethPool));
        }

        ERC20T.Config memory config;
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        ERC20T(implementation).initialize(config);
    }

    function test_rejectsWrongChainBeforeDeployment() public {
        vm.chainId(11_155_111);
        // The chain check must fail before mining or constructor validation.
        vm.expectRevert(abi.encodeWithSelector(ERC20TMainnetDeployment.WrongChain.selector, uint256(11_155_111)));
        script.run();
    }

    function test_rejectsUnavailableFWATradingBeforeDeployment() public {
        vm.chainId(1);
        bytes memory permission = abi.encodeWithSignature("isDistributor(address)", script.POOL_MANAGER());
        vm.mockCall(script.FWA_TOKEN(), permission, abi.encode(false));
        vm.expectRevert(ERC20TMainnetDeployment.FWATradingUnavailable.selector);
        script.run();

        vm.mockCall(script.FWA_TOKEN(), permission, abi.encode(true));
        vm.mockCall(script.FWA_ETH_HOOK(), abi.encodeWithSignature("externalBuysEnabled()"), abi.encode(false));
        vm.expectRevert(ERC20TMainnetDeployment.FWATradingUnavailable.selector);
        script.run();
    }

    function test_mainnetRegistryIsReadLiveAndSeparateFromHookAdministration() public {
        vm.chainId(1);
        (ERC20THook hook,) = script.run();
        address distributor = makeAddr("mock router");
        vm.etch(distributor, hex"00");
        bytes memory query = abi.encodeWithSignature("isGlobalDistributor(address)", distributor);
        assertFalse(hook.isDistributor(distributor));
        vm.mockCall(script.GLOBAL_DISTRIBUTOR_REGISTRY(), query, abi.encode(true));
        assertTrue(hook.isDistributor(distributor));
        assertFalse(hook.isHookDistributor(distributor));
        vm.mockCall(script.GLOBAL_DISTRIBUTOR_REGISTRY(), query, abi.encode(false));
        assertFalse(hook.isDistributor(distributor));
        address[] memory accounts = new address[](1);
        accounts[0] = distributor;
        address registry = hook.globalDistributorRegistry();
        vm.prank(registry);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setDistributors(accounts, true);
        vm.prank(script.HOOK_OWNER());
        hook.setDistributors(accounts, true);
        assertTrue(hook.isHookDistributor(distributor));
    }

    function _replacementScript() private returns (DeployERC20THookMainnet replacement) {
        replacement = new DeployERC20THookMainnet();
        vm.etch(replacement.EXISTING_FACTORY(), hex"00");
        vm.etch(replacement.EXISTING_IMPLEMENTATION(), hex"00");
        vm.mockCall(
            replacement.EXISTING_FACTORY(),
            abi.encodeWithSignature("implementation()"),
            abi.encode(replacement.EXISTING_IMPLEMENTATION())
        );
    }

    function test_hookOnlyReplacementUsesExistingFactoryWithoutChangingIt() public {
        vm.chainId(1);
        DeployERC20THookMainnet replacement = _replacementScript();
        address factory = replacement.EXISTING_FACTORY();
        address implementation = replacement.EXISTING_IMPLEMENTATION();
        bytes32 factoryCode = factory.codehash;
        uint64 factoryNonce = vm.getNonce(factory);
        ERC20THook hook = replacement.run();
        assertEq(hook.owner(), replacement.HOOK_OWNER());
        assertEq(hook.globalDistributorRegistry(), replacement.GLOBAL_DISTRIBUTOR_REGISTRY());
        assertEq(address(hook.poolManager()), replacement.POOL_MANAGER());
        assertEq(factory.codehash, factoryCode);
        assertEq(vm.getNonce(factory), factoryNonce);
        assertEq(ERC20TFactory(payable(factory)).implementation(), implementation);
        assertFalse(hook.poolInitialized(address(0)));
    }

    function test_hookOnlyReplacementRejectsMissingOrMismatchedExistingFactory() public {
        vm.chainId(1);
        DeployERC20THookMainnet replacement = _replacementScript();
        address factory = replacement.EXISTING_FACTORY();
        address implementation = replacement.EXISTING_IMPLEMENTATION();
        vm.etch(factory, "");
        vm.expectRevert("Existing factory has no code");
        replacement.run();
        vm.etch(factory, hex"00");
        vm.mockCall(factory, abi.encodeWithSignature("implementation()"), abi.encode(address(123)));
        vm.expectRevert("Existing implementation mismatch");
        replacement.run();
        vm.mockCall(factory, abi.encodeWithSignature("implementation()"), abi.encode(implementation));
        vm.etch(implementation, "");
        vm.expectRevert("Existing implementation mismatch");
        replacement.run();
        vm.chainId(4_663);
        vm.expectRevert(abi.encodeWithSelector(ERC20TMainnetDeployment.WrongChain.selector, uint256(4_663)));
        replacement.run();
    }
}
