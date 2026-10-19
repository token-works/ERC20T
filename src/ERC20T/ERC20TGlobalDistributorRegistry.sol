// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";

/// @notice Shared distributor list with the same read interface as GlobalDistributorHandler.
/// @dev The registry and every hook have independent ownership. This contract does not execute
///      calls on behalf of its owner. Approvals are trusted token-transfer endpoints.
contract ERC20TGlobalDistributorRegistry is Ownable {
    mapping(address account => bool allowed) public isGlobalDistributor;

    event DistributorSet(address indexed account, bool allowed);

    error InvalidOwner();
    error InvalidDistributor(address account);

    /// @notice Create and seed the list atomically under its final administrator.
    constructor(address initialOwner, address[] memory initialDistributors) {
        if (initialOwner == address(0) || initialOwner == address(this)) revert InvalidOwner();
        _initializeOwner(initialOwner);
        for (uint256 i; i < initialDistributors.length; ++i) {
            _setDistributor(initialDistributors[i], true);
        }
    }

    function setDistributor(address account, bool allowed) external onlyOwner {
        _setDistributor(account, allowed);
    }

    function setDistributors(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            _setDistributor(accounts[i], allowed);
        }
    }

    function _setDistributor(address account, bool allowed) private {
        if (account == address(0) || account == address(this) || (allowed && account.code.length == 0)) {
            revert InvalidDistributor(account);
        }
        isGlobalDistributor[account] = allowed;
        emit DistributorSet(account, allowed);
    }
}
