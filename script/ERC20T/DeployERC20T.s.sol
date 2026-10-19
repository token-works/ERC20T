// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";

/// @dev Shared CREATE2 address mining for the generic and fixed-mainnet deployment scripts.
abstract contract ERC20THookDeployment is Script {
    address private constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function _mineHook(
        IPoolManager manager,
        address initialOwner,
        address initialProtocolFeeRecipient,
        ERC20THook.ExternalBaseConfig[] memory initialBases,
        address globalDistributorRegistry
    ) internal view returns (address expectedAddress, bytes32 salt) {
        // Match ERC20THook.getHookPermissions(); BaseHook validates this mask in its constructor.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        return HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, initialOwner, initialProtocolFeeRecipient, initialBases, globalDistributorRegistry)
        );
    }
}

/// @notice Deploy the shared hook once per chain; token deployments reuse its address.
/// @dev Requires POOL_MANAGER. HOOK_OWNER defaults to the Forge broadcaster;
///      GLOBAL_DISTRIBUTOR_REGISTRY defaults to TokenWorks on Ethereum and zero elsewhere.
///      PROTOCOL_FEE_RECIPIENT overrides the mainnet FWABuyAndBurn default.
contract DeployERC20THook is ERC20THookDeployment {
    address private constant MAINNET_GLOBAL_DISTRIBUTOR_REGISTRY = 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D;
    address private constant DEFAULT_PROTOCOL_FEE_RECIPIENT = 0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12;

    function run() external returns (ERC20THook hook) {
        IPoolManager manager = _poolManager();
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        vm.stopBroadcast();
        address initialOwner = _envAddressOr("HOOK_OWNER", broadcaster);
        address globalDistributorRegistry = _envAddressOr(
            "GLOBAL_DISTRIBUTOR_REGISTRY", block.chainid == 1 ? MAINNET_GLOBAL_DISTRIBUTOR_REGISTRY : address(0)
        );
        // This known registry cannot execute admin calls, even when external reads are disabled.
        require(initialOwner != MAINNET_GLOBAL_DISTRIBUTOR_REGISTRY, "Registry cannot own hook");
        address initialProtocolFeeRecipient = _envAddressOr("PROTOCOL_FEE_RECIPIENT", DEFAULT_PROTOCOL_FEE_RECIPIENT);
        ERC20THook.ExternalBaseConfig[] memory initialBases = new ERC20THook.ExternalBaseConfig[](0);
        (address expectedAddress, bytes32 salt) =
            _mineHook(manager, initialOwner, initialProtocolFeeRecipient, initialBases, globalDistributorRegistry);

        vm.startBroadcast();
        hook = new ERC20THook{salt: salt}(
            manager, initialOwner, initialProtocolFeeRecipient, initialBases, globalDistributorRegistry
        );
        vm.stopBroadcast();

        require(address(hook) == expectedAddress, "Unexpected CREATE2 hook address");
        console.log("ERC20T_HOOK", address(hook));
        console.log("HOOK_OWNER", hook.owner());
        console.log("GLOBAL_DISTRIBUTOR_REGISTRY", hook.globalDistributorRegistry());
        console.log("PROTOCOL_FEE_RECIPIENT", hook.protocolFeeRecipient());
    }

    function _poolManager() internal view virtual returns (IPoolManager) {
        return IPoolManager(vm.envAddress("POOL_MANAGER"));
    }

    function _envAddressOr(string memory name, address defaultValue) internal view virtual returns (address) {
        return vm.envOr(name, defaultValue);
    }
}

/// @dev A positive TAX_DECAY_INTERVAL_SECONDS enables a fixed 99% launch tax that decreases
///      by 100 bps per interval toward TAX_BPS. Legacy LAUNCH_TAX_BPS may only be zero or 9900.
abstract contract ERC20TScriptConfig is Script {
    error InvalidTaxBps(uint256 taxBps);
    error InvalidTaxDecayConfiguration(uint256 launchTaxBps, uint256 intervalSeconds);

    function _readTokenConfig() internal view returns (ERC20T.Config memory config) {
        return _readTokenConfig(vm.envUint("LP_SUPPLY"));
    }

    function _readTokenConfig(uint256 lpSupply) internal view returns (ERC20T.Config memory config) {
        uint256 rawTaxBps = vm.envOr("TAX_BPS", uint256(100));
        if (rawTaxBps < 30 || rawTaxBps > 500) revert InvalidTaxBps(rawTaxBps);
        uint256 rawLaunchTaxBps = vm.envOr("LAUNCH_TAX_BPS", uint256(0));
        uint256 rawIntervalSeconds = vm.envOr("TAX_DECAY_INTERVAL_SECONDS", uint256(0));
        if (
            (rawLaunchTaxBps != 0 && rawLaunchTaxBps != 9900) || (rawLaunchTaxBps != 0 && rawIntervalSeconds == 0)
                || rawIntervalSeconds > type(uint32).max
        ) revert InvalidTaxDecayConfiguration(rawLaunchTaxBps, rawIntervalSeconds);

        config = ERC20T.Config({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            supply: vm.envUint("TOKEN_SUPPLY"),
            lpSupply: lpSupply,
            owner: vm.envAddress("TOKEN_OWNER"),
            hook: vm.envAddress("ERC20T_HOOK"),
            quoteToken: vm.envOr("QUOTE_TOKEN", address(0)),
            positionManager: IPositionManager(vm.envAddress("POSITION_MANAGER")),
            permit2: IAllowanceTransfer(vm.envAddress("PERMIT2")),
            taxBps: uint16(rawTaxBps),
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            launchTaxBps: rawIntervalSeconds == 0 ? 0 : 9900,
            taxDecayIntervalSeconds: uint32(rawIntervalSeconds),
            feeDecayRecipient: vm.envOr("FEE_DECAY_RECIPIENT", address(0))
        });
    }
}

/// @notice Create a token clone using an existing factory. The owner launches its pool separately.
/// @dev Requires ERC20T_FACTORY. Supply values are base units (18 decimals). TAX_BPS defaults to 100 (1%).
contract DeployERC20T is ERC20TScriptConfig {
    function run() external returns (ERC20T token) {
        ERC20T.Config memory config = _readTokenConfig();
        ERC20TFactory factory = ERC20TFactory(payable(vm.envAddress("ERC20T_FACTORY")));

        vm.startBroadcast();
        token = factory.create(config);
        vm.stopBroadcast();

        console.log("ERC20T", address(token));
        console.log("TOKEN_OWNER", token.owner());
        console.log("ERC20T_HOOK", token.hook());
    }
}

/// @notice Deploy the permissionless factory and its shared implementation in one transaction.
contract DeployERC20TFactory is Script {
    function run() external returns (ERC20TFactory factory) {
        vm.startBroadcast();
        factory = new ERC20TFactory();
        vm.stopBroadcast();

        console.log("ERC20T_FACTORY", address(factory));
        console.log("ERC20T_IMPLEMENTATION", factory.implementation());
    }
}

/// @notice Create a token and launch its pool through an existing factory in one transaction.
/// @dev Uses the token configuration plus ERC20T_FACTORY, SQRT_PRICE_X96, TICK_LOWER,
///      TICK_UPPER and optional LAUNCH_ETH (wei, default 0). Ticks may be negative.
contract CreateAndLaunchERC20T is ERC20TScriptConfig {
    error InvalidSqrtPrice(uint256 sqrtPriceX96);
    error InvalidTick(int256 tick);

    function run() external returns (ERC20T token) {
        ERC20T.Config memory config = _readTokenConfig();
        ERC20TFactory factory = ERC20TFactory(payable(vm.envAddress("ERC20T_FACTORY")));
        uint256 rawSqrtPriceX96 = vm.envUint("SQRT_PRICE_X96");
        int256 rawTickLower = vm.envInt("TICK_LOWER");
        int256 rawTickUpper = vm.envInt("TICK_UPPER");
        uint256 launchEth = vm.envOr("LAUNCH_ETH", uint256(0));

        if (rawSqrtPriceX96 > type(uint160).max) revert InvalidSqrtPrice(rawSqrtPriceX96);
        if (rawTickLower < type(int24).min || rawTickLower > type(int24).max) revert InvalidTick(rawTickLower);
        if (rawTickUpper < type(int24).min || rawTickUpper > type(int24).max) revert InvalidTick(rawTickUpper);

        vm.startBroadcast();
        token = factory.createAndLaunch{value: launchEth}(
            config, uint160(rawSqrtPriceX96), int24(rawTickLower), int24(rawTickUpper)
        );
        vm.stopBroadcast();

        console.log("ERC20T", address(token));
        console.log("TOKEN_OWNER", token.owner());
        console.log("ERC20T_HOOK", token.hook());
    }
}

/// @notice Create and launch from a quote/token price and creator allocation, without entering ticks.
/// @dev QUOTE_TOKEN defaults to native ETH (zero). Use STARTING_PRICE_WEI for ETH or
///      STARTING_PRICE_QUOTE for ERC20 quotes, in quote base units per whole token.
///      CREATOR_ALLOCATION_BPS is 0..2000 (default 0). No LP_SUPPLY or raw ticks are needed.
contract CreateAndLaunchERC20TAtPrice is ERC20TScriptConfig {
    error InvalidCreatorAllocation(uint256 bps);

    function run() external returns (ERC20T token) {
        ERC20TFactory factory = ERC20TFactory(payable(vm.envAddress("ERC20T_FACTORY")));
        uint256 rawCreatorBps = vm.envOr("CREATOR_ALLOCATION_BPS", uint256(0));
        if (rawCreatorBps > 2_000) revert InvalidCreatorAllocation(rawCreatorBps);
        ERC20T.Config memory config = _readTokenConfig(0);
        uint256 startingPriceQuote =
            config.quoteToken == address(0) ? vm.envUint("STARTING_PRICE_WEI") : vm.envUint("STARTING_PRICE_QUOTE");
        vm.startBroadcast();
        token = factory.createAndLaunchAtPrice(config, uint16(rawCreatorBps), startingPriceQuote);
        vm.stopBroadcast();

        ERC20TFactory.LaunchPreview memory preview = factory.previewQuotedLaunch(
            config.supply, uint16(rawCreatorBps), startingPriceQuote, address(token) < config.quoteToken
        );
        console.log("CREATOR_SUPPLY", preview.creatorSupply);
        console.log("LP_SUPPLY", preview.lpSupply);
        console.log("EFFECTIVE_PRICE_QUOTE", preview.effectivePriceWei);

        console.log("ERC20T", address(token));
        console.log("TOKEN_OWNER", token.owner());
        console.log("ERC20T_HOOK", token.hook());
    }
}
