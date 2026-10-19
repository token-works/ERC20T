// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DeployERC20THook} from "../../script/ERC20T/DeployERC20T.s.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {IERC20TGlobalDistributorRegistry} from "../../src/ERC20T/ERC20TInterfaces.sol";

/// @dev Resolve defaults exactly as production does without reading or changing process environment.
contract ERC20TGenericHookScriptHarness is DeployERC20THook {
    IPoolManager private immutable configuredManager;
    mapping(bytes32 key => bool configured) private hasOverride;
    mapping(bytes32 key => address value) private overrides;

    constructor(IPoolManager manager) {
        configuredManager = manager;
    }

    function setAddressInput(string memory name, address value) external {
        bytes32 key = keccak256(bytes(name));
        hasOverride[key] = true;
        overrides[key] = value;
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return configuredManager;
    }

    function _envAddressOr(string memory name, address defaultValue) internal view override returns (address) {
        bytes32 key = keccak256(bytes(name));
        return hasOverride[key] ? overrides[key] : defaultValue;
    }

    function broadcastSender() external returns (address sender) {
        vm.startBroadcast();
        (, sender,) = vm.readCallers();
        vm.stopBroadcast();
    }
}

/// @notice Run the generic deployment script locally with isolated inputs and infrastructure stubs.
contract ERC20TGenericHookScriptTest is Test {
    address constant TOKENWORKS_REGISTRY = 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D;
    address constant DEFAULT_PROTOCOL_RECIPIENT = 0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    ERC20TGenericHookScriptHarness script;
    address manager = makeAddr("genericHookScriptManager");
    address distributor = makeAddr("genericHookScriptDistributor");
    address broadcaster;

    function setUp() public {
        vm.chainId(31_337);
        vm.etch(manager, hex"00");
        vm.etch(distributor, hex"00");
        script = new ERC20TGenericHookScriptHarness(IPoolManager(manager));
        broadcaster = script.broadcastSender();
    }

    function _prepareRegistry(address registry) private {
        vm.etch(registry, hex"00");
        vm.mockCall(
            registry,
            abi.encodeCall(IERC20TGlobalDistributorRegistry.isGlobalDistributor, (address(0))),
            abi.encode(false)
        );
        vm.mockCall(
            registry,
            abi.encodeCall(IERC20TGlobalDistributorRegistry.isGlobalDistributor, (distributor)),
            abi.encode(true)
        );
    }

    function _assertDeployment(ERC20THook hook, address owner, address registry, address protocolRecipient)
        private
        view
    {
        assertGt(address(hook).code.length, 0);
        assertEq(address(hook.poolManager()), manager);
        assertEq(hook.owner(), owner);
        assertEq(hook.globalDistributorRegistry(), registry);
        assertEq(hook.protocolFeeRecipient(), protocolRecipient);
        assertNotEq(hook.owner(), TOKENWORKS_REGISTRY);
        (VmSafe.CallerMode callerMode,,) = vm.readCallers();
        assertEq(uint256(callerMode), uint256(VmSafe.CallerMode.None));
    }

    function test_genericNonMainnetDefaultsOwnerToBroadcasterAndDisablesExternalRegistry() public {
        ERC20THook hook = script.run();
        _assertDeployment(hook, broadcaster, address(0), DEFAULT_PROTOCOL_RECIPIENT);
        assertFalse(hook.isDistributor(distributor));
    }

    function test_genericMainnetDefaultsToTokenWorksRegistryAndBroadcasterOwner() public {
        vm.chainId(1);
        _prepareRegistry(TOKENWORKS_REGISTRY);
        ERC20THook hook = script.run();
        _assertDeployment(hook, broadcaster, TOKENWORKS_REGISTRY, DEFAULT_PROTOCOL_RECIPIENT);
        assertFalse(hook.isHookDistributor(distributor));
        assertTrue(hook.isDistributor(distributor));
    }

    function test_genericExplicitOwnerRegistryAndProtocolRecipientOverrideDefaults() public {
        address owner = makeAddr("genericHookScriptExplicitOwner");
        address registry = makeAddr("genericHookScriptExplicitRegistry");
        address protocolRecipient = makeAddr("genericHookScriptExplicitProtocolRecipient");
        assertNotEq(owner, broadcaster);
        _prepareRegistry(registry);
        script.setAddressInput("HOOK_OWNER", owner);
        script.setAddressInput("GLOBAL_DISTRIBUTOR_REGISTRY", registry);
        script.setAddressInput("PROTOCOL_FEE_RECIPIENT", protocolRecipient);

        ERC20THook hook = script.run();
        _assertDeployment(hook, owner, registry, protocolRecipient);
        assertFalse(hook.isHookDistributor(distributor));
        assertTrue(hook.isDistributor(distributor));
    }

    function test_genericRejectsTokenWorksAsOwnerEvenWhenRegistryIsDisabledBeforeDeployment() public {
        vm.chainId(1);
        script.setAddressInput("HOOK_OWNER", TOKENWORKS_REGISTRY);
        script.setAddressInput("GLOBAL_DISTRIBUTOR_REGISTRY", address(0));
        uint64 broadcasterNonce = vm.getNonce(broadcaster);
        uint64 deployerNonce = vm.getNonce(CREATE2_DEPLOYER);
        uint64 scriptNonce = vm.getNonce(address(script));
        vm.recordLogs();
        vm.expectRevert(bytes("Registry cannot own hook"));
        script.run();
        assertEq(vm.getNonce(broadcaster), broadcasterNonce);
        assertEq(vm.getNonce(CREATE2_DEPLOYER), deployerNonce);
        assertEq(vm.getNonce(address(script)), scriptNonce);
        assertEq(vm.getRecordedLogs().length, 0);
        (VmSafe.CallerMode callerMode,,) = vm.readCallers();
        assertEq(uint256(callerMode), uint256(VmSafe.CallerMode.None));
    }
}
