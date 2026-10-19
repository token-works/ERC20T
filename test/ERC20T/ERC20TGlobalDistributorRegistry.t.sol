// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ERC20TGlobalDistributorRegistry} from "../../src/ERC20T/ERC20TGlobalDistributorRegistry.sol";

contract ERC20TRegistryApprovedContract {}

contract ERC20TGlobalDistributorRegistryTest is Test {
    ERC20TGlobalDistributorRegistry registry;
    ERC20TRegistryApprovedContract first;
    ERC20TRegistryApprovedContract second;
    address owner = makeAddr("global registry owner");
    address other = makeAddr("unprivileged caller");

    function setUp() public {
        first = new ERC20TRegistryApprovedContract();
        second = new ERC20TRegistryApprovedContract();
        registry = new ERC20TGlobalDistributorRegistry(owner, new address[](0));
    }

    function _accounts() private view returns (address[] memory accounts) {
        accounts = new address[](2);
        accounts[0] = address(first);
        accounts[1] = address(second);
    }

    function test_constructorSeedsUnderFinalOwnerWithoutGivingDeployerControl() public {
        ERC20TGlobalDistributorRegistry seeded = new ERC20TGlobalDistributorRegistry(owner, _accounts());
        assertEq(seeded.owner(), owner);
        assertTrue(seeded.isGlobalDistributor(address(first)));
        assertTrue(seeded.isGlobalDistributor(address(second)));
        assertFalse(seeded.isGlobalDistributor(owner));
        vm.expectRevert(Ownable.Unauthorized.selector);
        seeded.setDistributor(address(first), false);
        vm.prank(owner);
        seeded.setDistributor(address(first), false);
        assertFalse(seeded.isGlobalDistributor(address(first)));
        assertTrue(seeded.isGlobalDistributor(address(second)));
    }

    function test_constructorRejectsZeroOwnerAndInvalidSeed() public {
        vm.expectRevert(ERC20TGlobalDistributorRegistry.InvalidOwner.selector);
        new ERC20TGlobalDistributorRegistry(address(0), new address[](0));
        address[] memory accounts = _accounts();
        address[2] memory invalid = [address(0), other];
        for (uint256 i; i < invalid.length; ++i) {
            accounts[1] = invalid[i];
            vm.expectRevert(
                abi.encodeWithSelector(ERC20TGlobalDistributorRegistry.InvalidDistributor.selector, invalid[i])
            );
            new ERC20TGlobalDistributorRegistry(owner, accounts);
        }
    }

    function test_onlyOwnerCanUpdateSingleOrBatchApprovals() public {
        vm.prank(other);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setDistributor(address(first), true);
        address[] memory accounts = _accounts();
        vm.prank(other);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setDistributors(accounts, true);
        assertFalse(registry.isGlobalDistributor(address(first)));
        assertFalse(registry.isGlobalDistributor(address(second)));
        vm.prank(owner);
        registry.setDistributors(accounts, true);
        assertTrue(registry.isGlobalDistributor(address(first)));
        assertTrue(registry.isGlobalDistributor(address(second)));
        vm.prank(owner);
        registry.setDistributors(accounts, false);
        assertFalse(registry.isGlobalDistributor(address(first)));
        assertFalse(registry.isGlobalDistributor(address(second)));
    }

    function test_invalidMemberRevertsEntireApprovalBatch() public {
        address[] memory accounts = _accounts();
        address[3] memory invalid = [address(0), other, address(registry)];
        for (uint256 i; i < invalid.length; ++i) {
            accounts[1] = invalid[i];
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(ERC20TGlobalDistributorRegistry.InvalidDistributor.selector, invalid[i])
            );
            registry.setDistributors(accounts, true);
            assertFalse(registry.isGlobalDistributor(address(first)), "partial batch approval persisted");
            assertFalse(registry.isGlobalDistributor(invalid[i]));
        }
    }

    function test_revocationStillWorksAfterApprovedContractLosesCode() public {
        vm.prank(owner);
        registry.setDistributor(address(first), true);
        vm.etch(address(first), "");
        vm.prank(owner);
        registry.setDistributor(address(first), false);
        assertFalse(registry.isGlobalDistributor(address(first)));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20TGlobalDistributorRegistry.InvalidDistributor.selector, address(first))
        );
        registry.setDistributor(address(first), true);
    }

    function test_transferringOwnershipMovesRegistryAdministration() public {
        vm.prank(owner);
        registry.transferOwnership(other);
        assertEq(registry.owner(), other);
        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setDistributor(address(first), true);
        vm.prank(other);
        registry.setDistributor(address(first), true);
        assertTrue(registry.isGlobalDistributor(address(first)));
    }
}
