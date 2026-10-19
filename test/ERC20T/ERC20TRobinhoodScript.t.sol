// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DeployERC20TRobinhood} from "../../script/ERC20T/DeployERC20TRobinhood.s.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20TGlobalDistributorRegistry} from "../../src/ERC20T/ERC20TGlobalDistributorRegistry.sol";

/// @dev Keep deployment tests independent of process-wide environment variables.
contract ERC20TRobinhoodScriptHarness is DeployERC20TRobinhood {
    address private configuredOwner = DEFAULT_HOOK_OWNER;
    address[] private configuredDistributors;
    bool private useDefaults;

    function setOwner(address owner) external {
        configuredOwner = owner;
    }

    function setDistributors(address[] memory distributors) external {
        configuredDistributors = distributors;
        useDefaults = false;
    }

    function useDefaultDistributors() external {
        useDefaults = true;
    }

    function _readHookOwner() internal view override returns (address) {
        return configuredOwner;
    }

    function _readGlobalDistributors() internal view override returns (address[] memory) {
        if (useDefaults) return super._readGlobalDistributors();
        return configuredDistributors;
    }

    function environmentOwner() external view returns (address) {
        return super._readHookOwner();
    }

    function environmentDistributors() external view returns (address[] memory) {
        return super._readGlobalDistributors();
    }

    function broadcastSender() external returns (address sender) {
        vm.startBroadcast();
        (, sender,) = vm.readCallers();
        vm.stopBroadcast();
    }
}

contract ERC20TRobinhoodScriptDistributor {}

/// @notice Local script execution only. Readiness mocks model deployed infrastructure;
/// real PoolManager integration is covered by the ERC20T token and external-base suites.
contract ERC20TRobinhoodScriptTest is Test {
    ERC20TRobinhoodScriptHarness script;
    ERC20TRobinhoodScriptDistributor first;
    ERC20TRobinhoodScriptDistributor second;
    address finalOwner = makeAddr("Robinhood registry owner");
    address broadcaster;

    function setUp() public {
        script = new ERC20TRobinhoodScriptHarness();
        first = new ERC20TRobinhoodScriptDistributor();
        second = new ERC20TRobinhoodScriptDistributor();
        vm.chainId(4_663);
        vm.etch(script.POOL_MANAGER(), hex"00");
        vm.etch(script.POSITION_MANAGER(), hex"00");
        vm.etch(script.PERMIT2(), hex"00");
        vm.etch(script.IMD_TOKEN(), hex"00");
        vm.mockCall(
            script.POSITION_MANAGER(), abi.encodeWithSignature("poolManager()"), abi.encode(script.POOL_MANAGER())
        );
        vm.mockCall(script.POSITION_MANAGER(), abi.encodeWithSignature("permit2()"), abi.encode(script.PERMIT2()));
        vm.mockCall(script.POOL_MANAGER(), abi.encodeWithSignature("extsload(bytes32)"), abi.encode(uint256(0)));
        bytes32 slot = _imdPoolSlot();
        vm.mockCall(
            script.POOL_MANAGER(), abi.encodeWithSignature("extsload(bytes32)", slot), abi.encode(uint256(1 << 96))
        );
        vm.mockCall(
            script.POOL_MANAGER(),
            abi.encodeWithSignature("extsload(bytes32)", bytes32(uint256(slot) + 3)),
            abi.encode(uint256(1 ether))
        );
        broadcaster = script.broadcastSender();
    }

    function _imdPoolSlot() private view returns (bytes32) {
        ERC20THook.ExternalBaseConfig[] memory bases = script.initialBases();
        return keccak256(abi.encode(keccak256(abi.encode(bases[0].ethPool)), uint256(6)));
    }

    function _distributors() private view returns (address[] memory accounts) {
        accounts = new address[](2);
        accounts[0] = address(first);
        accounts[1] = address(second);
    }

    function _assertSystem(ERC20THook hook, ERC20TFactory factory, address owner) private view {
        assertEq(address(hook.poolManager()), script.POOL_MANAGER());
        assertEq(hook.owner(), owner);
        ERC20TGlobalDistributorRegistry registry = ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry());
        assertGt(address(registry).code.length, 0);
        assertNotEq(address(registry), address(hook));
        assertEq(registry.owner(), owner);
        assertEq(hook.protocolFeeRecipient(), script.PROTOCOL_FEE_RECIPIENT());
        uint160 permissions = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, permissions);
        assertGt(address(hook).code.length, 0);
        assertGt(address(factory).code.length, 0);
        assertGt(factory.implementation().code.length, 0);
        (bool registered, bool enabled) = hook.externalBases(script.IMD_TOKEN());
        assertTrue(registered && enabled);
        PoolKey memory poolKey = hook.externalBasePool(script.IMD_TOKEN());
        assertEq(Currency.unwrap(poolKey.currency0), address(0));
        assertEq(Currency.unwrap(poolKey.currency1), script.IMD_TOKEN());
        assertEq(poolKey.fee, 10_000);
        assertEq(poolKey.tickSpacing, 100);
        assertEq(address(poolKey.hooks), address(0));
    }

    function test_robinhoodDeploysPinnedSystemWithSeparateEmptyRegistry() public {
        assertEq(script.CHAIN_ID(), 4_663);
        assertEq(script.POOL_MANAGER(), address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951")));
        assertEq(script.POSITION_MANAGER(), address(bytes20(hex"58daec3116aae6d93017baaea7749052e8a04fa7")));
        assertEq(script.PERMIT2(), 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        assertEq(script.DEFAULT_HOOK_OWNER(), 0x019817aD02a31B990433542097bE29D97613E8Cb);
        assertEq(script.PROTOCOL_FEE_RECIPIENT(), 0x3b78975E598731aa04AF1388E4E3BE099a29dC71);
        assertEq(script.IMD_TOKEN(), address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127")));
        ERC20THook.ExternalBaseConfig[] memory bases = script.initialBases();
        assertEq(bases.length, 1);
        assertEq(bases[0].token, script.IMD_TOKEN());

        (ERC20THook hook, ERC20TFactory factory) = script.run();
        _assertSystem(hook, factory, script.DEFAULT_HOOK_OWNER());
        assertFalse(hook.isDistributor(address(first)));
        assertFalse(hook.isDistributor(script.POSITION_MANAGER()));
        assertFalse(hook.isDistributor(script.PERMIT2()));
        assertFalse(hook.isDistributor(script.DEFAULT_HOOK_OWNER()));
        ERC20T.Config memory config;
        address implementation = factory.implementation();
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        ERC20T(implementation).initialize(config);
    }

    function test_robinhoodSeedsExternalRegistryUnderFinalOwnerWithoutSignerAdministration() public {
        address sender = broadcaster;
        assertNotEq(sender, finalOwner);
        script.setOwner(finalOwner);
        script.setDistributors(_distributors());
        (ERC20THook hook, ERC20TFactory factory) = script.run();
        _assertSystem(hook, factory, finalOwner);
        ERC20TGlobalDistributorRegistry registry = ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry());
        assertTrue(registry.isGlobalDistributor(address(first)));
        assertTrue(registry.isGlobalDistributor(address(second)));
        assertTrue(hook.isDistributor(address(first)));
        assertTrue(hook.isDistributor(address(second)));
        assertFalse(hook.isHookDistributor(address(first)));
        assertFalse(hook.isHookDistributor(address(second)));
        address[] memory accounts = _distributors();
        vm.prank(sender);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setDistributors(accounts, false);
        vm.prank(sender);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setDistributors(accounts, false);
        vm.prank(finalOwner);
        registry.setDistributors(accounts, false);
        assertFalse(registry.isGlobalDistributor(address(first)));
        assertFalse(registry.isGlobalDistributor(address(second)));
        assertFalse(hook.isDistributor(address(first)));
        assertFalse(hook.isDistributor(address(second)));
        vm.prank(finalOwner);
        registry.setDistributor(address(first), true);
        assertTrue(hook.isDistributor(address(first)));
        assertFalse(hook.isDistributor(address(second)));
    }

    function test_robinhoodSeedsWhenFinalOwnerIsAlreadyBroadcastSigner() public {
        address sender = broadcaster;
        script.setOwner(sender);
        script.setDistributors(_distributors());
        (ERC20THook hook, ERC20TFactory factory) = script.run();
        _assertSystem(hook, factory, sender);
        assertTrue(
            ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry()).isGlobalDistributor(address(first))
        );
        assertTrue(hook.isDistributor(address(first)));
        assertTrue(hook.isDistributor(address(second)));
    }

    function _assertReviewedDefaultRouterDeployment() private {
        address[] memory accounts = script.defaultGlobalDistributors();
        assertGt(accounts.length, 0, "default router list must be populated");
        for (uint256 i; i < accounts.length; ++i) {
            vm.etch(accounts[i], hex"00");
        }
        script.useDefaultDistributors();
        (ERC20THook hook, ERC20TFactory factory) = script.run();
        _assertSystem(hook, factory, script.DEFAULT_HOOK_OWNER());
        ERC20TGlobalDistributorRegistry registry = ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry());
        for (uint256 i; i < accounts.length; ++i) {
            assertTrue(registry.isGlobalDistributor(accounts[i]));
            assertTrue(hook.isDistributor(accounts[i]));
            assertFalse(hook.isHookDistributor(accounts[i]));
        }
    }

    function test_robinhoodRejectsWrongChainBeforeInfrastructureChecks() public {
        vm.chainId(1);
        vm.etch(script.POOL_MANAGER(), "");
        _expectPreflightFailure(abi.encodeWithSelector(DeployERC20TRobinhood.WrongChain.selector, uint256(1)));
    }

    function _expectPreflightFailure(bytes memory reason) private {
        address sender = broadcaster;
        uint64 senderNonce = vm.getNonce(sender);
        address deployer = script.CREATE2_DEPLOYER();
        uint64 deployerNonce = vm.getNonce(deployer);
        vm.recordLogs();
        vm.expectRevert(reason);
        script.run();
        assertEq(vm.getNonce(sender), senderNonce);
        assertEq(vm.getNonce(deployer), deployerNonce);
        assertEq(vm.getRecordedLogs().length, 0);
        (VmSafe.CallerMode callerMode,,) = vm.readCallers();
        assertEq(uint256(callerMode), uint256(VmSafe.CallerMode.None));
    }

    function test_robinhoodRejectsMissingInfrastructureBeforeDeployment() public {
        address[5] memory required = [
            script.POOL_MANAGER(),
            script.POSITION_MANAGER(),
            script.PERMIT2(),
            script.CREATE2_DEPLOYER(),
            script.IMD_TOKEN()
        ];
        for (uint256 i; i < required.length; ++i) {
            bytes memory code = required[i].code;
            assertGt(code.length, 0, "fixture infrastructure missing");
            vm.etch(required[i], "");
            _expectPreflightFailure(
                abi.encodeWithSelector(DeployERC20TRobinhood.InvalidInfrastructure.selector, required[i])
            );
            vm.etch(required[i], code);
        }
    }

    function test_robinhoodRejectsMismatchedPositionManagerInfrastructure() public {
        vm.mockCall(script.POSITION_MANAGER(), abi.encodeWithSignature("poolManager()"), abi.encode(address(first)));
        bytes memory expected =
            abi.encodeWithSelector(DeployERC20TRobinhood.InvalidInfrastructure.selector, script.POSITION_MANAGER());
        _expectPreflightFailure(expected);
        vm.mockCall(
            script.POSITION_MANAGER(), abi.encodeWithSignature("poolManager()"), abi.encode(script.POOL_MANAGER())
        );
        vm.mockCall(script.POSITION_MANAGER(), abi.encodeWithSignature("permit2()"), abi.encode(address(first)));
        _expectPreflightFailure(expected);
    }

    function test_robinhoodRejectsUninitializedImdRouteBeforeDeployment() public {
        vm.mockCall(
            script.POOL_MANAGER(), abi.encodeWithSignature("extsload(bytes32)", _imdPoolSlot()), abi.encode(uint256(0))
        );
        _expectPreflightFailure(abi.encodeWithSelector(DeployERC20TRobinhood.IMDPoolUnavailable.selector));
    }

    function test_robinhoodRejectsZeroOwnerAndInvalidDistributorBatchBeforeDeployment() public {
        script.setOwner(address(0));
        _expectPreflightFailure(abi.encodeWithSelector(DeployERC20TRobinhood.InvalidHookOwner.selector, address(0)));
        script.setOwner(0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D);
        _expectPreflightFailure(
            abi.encodeWithSelector(
                DeployERC20TRobinhood.InvalidHookOwner.selector, 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D
            )
        );
        script.setOwner(finalOwner);
        address[3] memory invalid = [address(0), script.POOL_MANAGER(), makeAddr("distributor without code")];
        address[] memory accounts = _distributors();
        for (uint256 i; i < invalid.length; ++i) {
            accounts[1] = invalid[i];
            script.setDistributors(accounts);
            _expectPreflightFailure(
                abi.encodeWithSelector(DeployERC20TRobinhood.InvalidDistributor.selector, invalid[i])
            );
        }
    }

    // Environment-dependent cases are grouped in one test because vm.setEnv is process-wide.
    function test_robinhoodDefaultRouterDeploymentAndOptionalDistributorEnvironment() public {
        string memory previousOwner = vm.envOr("HOOK_OWNER", string(""));
        string memory previousDistributors = vm.envOr("ROBINHOOD_GLOBAL_DISTRIBUTORS", string(""));
        vm.setEnv("HOOK_OWNER", vm.toString(finalOwner));
        vm.setEnv("ROBINHOOD_GLOBAL_DISTRIBUTORS", "");
        assertEq(script.environmentOwner(), finalOwner);
        assertEq(script.environmentDistributors(), script.defaultGlobalDistributors());
        _assertReviewedDefaultRouterDeployment();
        vm.setEnv(
            "ROBINHOOD_GLOBAL_DISTRIBUTORS",
            string.concat(vm.toString(address(first)), ",", vm.toString(address(second)))
        );
        address[] memory accounts = script.environmentDistributors();
        assertEq(accounts.length, 2);
        assertEq(accounts[0], address(first));
        assertEq(accounts[1], address(second));
        vm.setEnv("ROBINHOOD_GLOBAL_DISTRIBUTORS", "not-an-address");
        vm.expectRevert();
        script.environmentDistributors();
        vm.setEnv("HOOK_OWNER", previousOwner);
        vm.setEnv("ROBINHOOD_GLOBAL_DISTRIBUTORS", previousDistributors);
    }
}
