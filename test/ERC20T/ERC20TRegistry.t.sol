// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20TDistributor} from "./ERC20T.t.sol";
import {TokenPosmHelper} from "../support/TokenPosmHelper.sol";

contract ERC20TExternalRegistryMock {
    mapping(address => bool) public approved;
    uint8 public mode;

    function setDistributor(address account, bool enabled) external {
        approved[account] = enabled;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function isGlobalDistributor(address account) external view returns (bool) {
        uint8 response = mode;
        if (response == 1) revert("registry unavailable");
        if (response == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (response == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (response == 4) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (response == 5) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 0)
                return(0, 64)
            }
        }
        return approved[account];
    }
}

/// @notice Exercises live external membership through real tokens and the unchanged factory ABI.
contract ERC20TRegistryTest is Deployers, TokenPosmHelper {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    ERC20THook hook;
    ERC20T token;
    ERC20TFactory factory;
    ERC20TExternalRegistryMock registry;
    ERC20TDistributor distributor;
    ERC20TDistributor supplemental;
    address alice = makeAddr("registry Alice");
    address bob = makeAddr("registry Bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        _deployPosm(manager);
        registry = new ERC20TExternalRegistryMock();
        hook = _deployHook(address(registry), address(this));
        factory = new ERC20TFactory();
        token = factory.create(_config(hook));
        distributor = new ERC20TDistributor();
        supplemental = new ERC20TDistributor();
        token.transfer(alice, 20 ether);
    }

    function _config(ERC20THook target) private view returns (ERC20T.Config memory config) {
        config = ERC20T.Config({
            name: "Registry Token",
            symbol: "REG",
            supply: 1_000 ether,
            lpSupply: 800 ether,
            owner: address(this),
            hook: address(target),
            quoteToken: address(0),
            positionManager: posm,
            permit2: IAllowanceTransfer(PERMIT2_ADDR),
            taxBps: 100,
            feeRecipient: bob,
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0,
            feeDecayRecipient: address(0)
        });
    }

    function _hookSalt(address source, address owner) private view returns (bytes32 salt) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, owner, bob, new ERC20THook.ExternalBaseConfig[](0), source)
        );
    }

    function _deployHook(address source, address owner) private returns (ERC20THook result) {
        bytes32 salt = _hookSalt(source, owner);
        vm.prank(CREATE2_DEPLOYER);
        result = new ERC20THook{salt: salt}(manager, owner, bob, new ERC20THook.ExternalBaseConfig[](0), source);
    }

    function _accounts(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function test_registryLiveMembershipEnablesTransfersWithoutCopyingApprovals() public {
        assertEq(hook.globalDistributorRegistry(), address(registry));
        assertEq(hook.owner(), address(this));
        assertFalse(token.isDistributor(address(distributor)));
        registry.setDistributor(address(distributor), true);
        assertTrue(token.isDistributor(address(distributor)));
        assertFalse(hook.isHookDistributor(address(distributor)));
        assertFalse(token.isLocalDistributor(address(distributor)));
        vm.prank(alice);
        token.transfer(address(distributor), 1 ether);
        distributor.send(token, bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
        registry.setDistributor(address(distributor), false);
        assertFalse(token.isDistributor(address(distributor)));
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(distributor), 1 ether);
    }

    function test_registryOptOutIsPerTokenAndKeepsTokenLocalApprovals() public {
        ERC20T second = factory.create(_config(hook));
        registry.setDistributor(address(distributor), true);
        hook.setDistributors(_accounts(address(supplemental)), true);
        token.setUseGlobalDistributors(false);
        assertFalse(token.isDistributor(address(distributor)));
        assertFalse(token.isDistributor(address(supplemental)));
        assertTrue(second.isDistributor(address(distributor)));
        assertTrue(second.isDistributor(address(supplemental)));
        token.setDistributors(_accounts(address(distributor)), true);
        vm.prank(alice);
        token.transfer(address(distributor), 1 ether);
        distributor.send(token, bob, 1 ether);
        token.setDistributors(_accounts(address(distributor)), false);
        assertFalse(token.isDistributor(address(distributor)));
        token.setUseGlobalDistributors(true);
        assertTrue(token.isDistributor(address(distributor)));
    }

    function test_registrySupplementalRemovalDoesNotVetoExternalMembership() public {
        hook.setDistributors(_accounts(address(distributor)), true);
        registry.setDistributor(address(distributor), true);
        hook.setDistributors(_accounts(address(distributor)), false);
        assertFalse(hook.isHookDistributor(address(distributor)));
        assertTrue(hook.isDistributor(address(distributor)));
        registry.setDistributor(address(distributor), false);
        assertFalse(hook.isDistributor(address(distributor)));
    }

    function test_registryExternalApprovalDoesNotExemptAnOrdinaryTransferFromCaller() public {
        registry.setDistributor(address(distributor), true);
        vm.prank(alice);
        token.approve(address(distributor), 1 ether);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        distributor.pull(token, alice, bob, 1 ether);
        assertEq(token.balanceOf(alice), 20 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_registryCannotBypassPoolManagerSettlementPermissions() public {
        registry.setDistributor(address(distributor), true);
        registry.setDistributor(address(manager), true);
        token.transfer(address(distributor), 1 ether);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        distributor.send(token, address(manager), 1 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(distributor)), 1 ether);
    }

    function test_registryRejectsEoaAndReservedExternalApprovalsAndRequiresCurrentCode() public {
        address[4] memory forbidden = [address(0), address(manager), address(hook), alice];
        for (uint256 i; i < forbidden.length; ++i) {
            registry.setDistributor(forbidden[i], true);
            assertFalse(hook.isDistributor(forbidden[i]));
        }
        registry.setDistributor(address(distributor), true);
        assertTrue(hook.isDistributor(address(distributor)));
        vm.etch(address(distributor), "");
        assertFalse(hook.isDistributor(address(distributor)));
    }

    function test_registryFailuresDoNotBlockWalletOrLocallyAuthorizedTransfers() public {
        registry.setDistributor(address(distributor), true);
        hook.setDistributors(_accounts(address(supplemental)), true);
        for (uint8 mode = 1; mode <= 5; ++mode) {
            registry.setMode(mode);
            assertFalse(hook.isDistributor(address(distributor)));
            assertTrue(hook.isDistributor(address(supplemental)));
            vm.prank(alice, alice);
            token.transfer(bob, 1 ether);
            vm.prank(alice);
            token.transfer(address(supplemental), 1 ether);
            supplemental.send(token, bob, 1 ether);
        }
        assertEq(token.balanceOf(bob), 10 ether);
        token.setDistributors(_accounts(address(distributor)), true);
        vm.prank(alice);
        token.transfer(address(distributor), 1 ether);
        distributor.send(token, bob, 1 ether);
        assertEq(token.balanceOf(bob), 11 ether);
    }

    function test_registryDisabledSourceKeepsHookLocalRegistryAvailable() public {
        ERC20THook standalone = _deployHook(address(0), address(this));
        assertEq(standalone.globalDistributorRegistry(), address(0));
        standalone.setDistributors(_accounts(address(distributor)), true);
        ERC20T localToken = factory.create(_config(standalone));
        assertTrue(localToken.isDistributor(address(distributor)));
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        standalone.setDistributors(_accounts(address(supplemental)), true);
    }

    function test_registryConstructorRejectsMissingCodeAndRegistryAsOwner() public {
        bytes32 salt = _hookSalt(alice, address(this));
        vm.prank(CREATE2_DEPLOYER);
        vm.expectRevert(ERC20THook.InvalidGlobalDistributorRegistry.selector);
        new ERC20THook{salt: salt}(manager, address(this), bob, new ERC20THook.ExternalBaseConfig[](0), alice);
        salt = _hookSalt(address(registry), address(registry));
        vm.prank(CREATE2_DEPLOYER);
        vm.expectRevert(ERC20THook.InvalidAddress.selector);
        new ERC20THook{salt: salt}(
            manager, address(registry), bob, new ERC20THook.ExternalBaseConfig[](0), address(registry)
        );
    }

    function test_registryConstructorRejectsFailedOrMalformedInterfaceProbe() public {
        for (uint8 mode = 1; mode <= 5; ++mode) {
            ERC20TExternalRegistryMock invalid = new ERC20TExternalRegistryMock();
            invalid.setMode(mode);
            bytes32 salt = _hookSalt(address(invalid), address(this));
            vm.prank(CREATE2_DEPLOYER);
            vm.expectRevert(ERC20THook.InvalidGlobalDistributorRegistry.selector);
            new ERC20THook{salt: salt}(
                manager, address(this), bob, new ERC20THook.ExternalBaseConfig[](0), address(invalid)
            );
        }
    }
}
