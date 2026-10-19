// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20THookDeployment} from "./DeployERC20T.s.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";

interface IERC20TMainnetFWA {
    function isDistributor(address account) external view returns (bool);
}

interface IERC20TMainnetFWAHook {
    function externalBuysEnabled() external view returns (bool);
}

/// @dev Shared mainnet settings for a new system or a replacement hook using the existing factory.
abstract contract ERC20TMainnetDeployment is ERC20THookDeployment {
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant HOOK_OWNER = 0x019817aD02a31B990433542097bE29D97613E8Cb;
    address public constant GLOBAL_DISTRIBUTOR_REGISTRY = 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D;
    address public constant PROTOCOL_FEE_RECIPIENT = 0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12;
    address public constant IMD_TOKEN = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address public constant IMD_ETH_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address public constant FWA_ETH_HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;

    error WrongChain(uint256 chainId);
    error FWATradingUnavailable();

    /// @notice Initial external bases, enabled atomically by the hook constructor under its final owner.
    /// @dev Both conversion pools use native ETH on the shared mainnet PoolManager. Their external
    ///      hooks and pool fees execute normally; this hook splits the net ETH proceeds.
    function initialBases() public pure returns (ERC20THook.ExternalBaseConfig[] memory bases) {
        bases = new ERC20THook.ExternalBaseConfig[](2);
        bases[0] = ERC20THook.ExternalBaseConfig({
            token: IMD_TOKEN,
            ethPool: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(IMD_TOKEN),
                fee: 10_000,
                tickSpacing: 60,
                hooks: IHooks(IMD_ETH_HOOK)
            })
        });
        bases[1] = ERC20THook.ExternalBaseConfig({
            token: FWA_TOKEN,
            ethPool: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(FWA_TOKEN),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(FWA_ETH_HOOK)
            })
        });
    }

    function _deployHook() internal returns (ERC20THook hook) {
        if (block.chainid != 1) revert WrongChain(block.chainid);
        // Ordinary routers settle FWA directly against PoolManager; approving this new hook
        // alone would not authorize those transfers. These are read-only readiness checks.
        if (
            !IERC20TMainnetFWA(FWA_TOKEN).isDistributor(POOL_MANAGER)
                || !IERC20TMainnetFWAHook(FWA_ETH_HOOK).externalBuysEnabled()
        ) revert FWATradingUnavailable();
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        ERC20THook.ExternalBaseConfig[] memory bases = initialBases();
        (address expectedAddress, bytes32 salt) =
            _mineHook(manager, HOOK_OWNER, PROTOCOL_FEE_RECIPIENT, bases, GLOBAL_DISTRIBUTOR_REGISTRY);

        vm.startBroadcast();
        hook =
            new ERC20THook{salt: salt}(manager, HOOK_OWNER, PROTOCOL_FEE_RECIPIENT, bases, GLOBAL_DISTRIBUTOR_REGISTRY);
        require(address(hook) == expectedAddress, "Unexpected CREATE2 hook address");
        vm.stopBroadcast();

        console.log("CHAIN_ID", block.chainid);
        console.log("POOL_MANAGER", POOL_MANAGER);
        console.log("HOOK_OWNER", HOOK_OWNER);
        console.log("GLOBAL_DISTRIBUTOR_REGISTRY", GLOBAL_DISTRIBUTOR_REGISTRY);
        console.log("PROTOCOL_FEE_RECIPIENT", PROTOCOL_FEE_RECIPIENT);
        console.log("ERC20T_HOOK", address(hook));
        console.log("IMD_BASE", IMD_TOKEN);
        console.log("IMD_ETH_HOOK", IMD_ETH_HOOK);
        console.log("FWA_BASE", FWA_TOKEN);
        console.log("FWA_ETH_HOOK", FWA_ETH_HOOK);
    }
}

/// @notice Deploy the shared hook and a new factory on Ethereum mainnet in two transactions.
/// @dev The Ledger selects the signer; contract settings are fixed above.
contract DeployERC20TMainnet is ERC20TMainnetDeployment {
    function run() external returns (ERC20THook hook, ERC20TFactory factory) {
        hook = _deployHook();
        vm.startBroadcast();
        factory = new ERC20TFactory();
        vm.stopBroadcast();
        console.log("ERC20T_FACTORY", address(factory));
        console.log("ERC20T_IMPLEMENTATION", factory.implementation());
    }
}

/// @notice Deploy only the corrected hook; reuse the deployed factory and token implementation.
/// @dev One transaction. This does not migrate existing tokens, create a token or launch a pool.
contract DeployERC20THookMainnet is ERC20TMainnetDeployment {
    address public constant EXISTING_FACTORY = 0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173;
    address public constant EXISTING_IMPLEMENTATION = 0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe;

    function run() external returns (ERC20THook hook) {
        if (block.chainid != 1) revert WrongChain(block.chainid);
        require(EXISTING_FACTORY.code.length != 0, "Existing factory has no code");
        require(
            ERC20TFactory(payable(EXISTING_FACTORY)).implementation() == EXISTING_IMPLEMENTATION
                && EXISTING_IMPLEMENTATION.code.length != 0,
            "Existing implementation mismatch"
        );
        hook = _deployHook();
        console.log("ERC20T_FACTORY", EXISTING_FACTORY);
        console.log("ERC20T_IMPLEMENTATION", EXISTING_IMPLEMENTATION);
    }
}
