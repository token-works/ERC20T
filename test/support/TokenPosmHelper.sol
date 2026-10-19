// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";

/// @dev Test helper: deploys a real v4 PositionManager + Permit2 so `ERC20T.launch()` can be exercised
///      end-to-end. Permit2 is etched at its canonical address from precompiled bytecode (no descriptor
///      or WETH wiring is needed for the native-ETH/ERC20T launch path).
abstract contract TokenPosmHelper is DeployPermit2 {
    address internal constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    IPositionManager internal posm;

    function _deployPosm(IPoolManager poolManager) internal {
        deployPermit2(); // etches Permit2 at PERMIT2_ADDR
        posm = new PositionManager(
            poolManager,
            IAllowanceTransfer(PERMIT2_ADDR),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(payable(address(0xeee)))
        );
    }
}
