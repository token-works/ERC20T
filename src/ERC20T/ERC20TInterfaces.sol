// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

uint24 constant ERC20T_POOL_FEE = 0;
int24 constant ERC20T_TICK_SPACING = 60;

/// @notice The shared hook's token-facing configuration.
interface IERC20THook {
    function poolManager() external view returns (IPoolManager);
    function isDistributor(address account) external view returns (bool);
}

/// @notice Existing global distributor list optionally consumed by the shared hook.
interface IERC20TGlobalDistributorRegistry {
    function isGlobalDistributor(address account) external view returns (bool);
}

/// @notice Configuration and transfer permissions consumed by ERC20THook.
interface IERC20T {
    function hook() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function launching() external view returns (bool);
    function quoteToken() external view returns (address);
    function pairingEnabled() external view returns (bool);
    function taxBps() external view returns (uint16);
    function restingTaxBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function feeDecayRecipient() external view returns (address);
    function externalLiquidityEnabled() external view returns (bool);
    function increaseTransferAllowance(uint256 amount, bool fromPoolManager) external;
    function accountTransferDelta(int128 delta) external;
}
