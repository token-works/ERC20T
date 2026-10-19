// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ERC20THookDeployment} from "./DeployERC20T.s.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20TGlobalDistributorRegistry} from "../../src/ERC20T/ERC20TGlobalDistributorRegistry.sol";

interface IERC20TRobinhoodPositionManager {
    function permit2() external view returns (address);
}

/// @notice Deploy Robinhood's shared ERC20T hook, global distributor registry and factory.
/// @dev Three transactions: seeded registry, hook, factory (including its implementation).
///      No token is created or launched. HOOK_OWNER overrides both final administrators;
///      ROBINHOOD_GLOBAL_DISTRIBUTORS overrides the reviewed Robinhood seed list.
///      Uses the standalone repository's default Foundry profile.
contract DeployERC20TRobinhood is ERC20THookDeployment {
    uint256 public constant CHAIN_ID = 4663;
    address public constant POOL_MANAGER = address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951"));
    address public constant POSITION_MANAGER = address(bytes20(hex"58daec3116aae6d93017baaea7749052e8a04fa7"));
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address public constant DEFAULT_HOOK_OWNER = 0x019817aD02a31B990433542097bE29D97613E8Cb;
    address private constant MAINNET_GLOBAL_DISTRIBUTOR_REGISTRY = 0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D;
    address public constant PROTOCOL_FEE_RECIPIENT = 0x3b78975E598731aa04AF1388E4E3BE099a29dC71;
    address public constant IMD_TOKEN = address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"));

    struct DeploymentConfig {
        address owner;
        address broadcaster;
        address[] distributors;
    }

    error WrongChain(uint256 chainId);
    error InvalidInfrastructure(address target);
    error InvalidHookOwner(address owner);
    error InvalidProtocolFeeRecipient(address recipient);
    error InvalidDistributor(address distributor);
    error IMDPoolUnavailable();
    error UnexpectedHookAddress();

    /// @notice The initialized native ETH/IMD conversion route on Robinhood's PoolManager.
    /// @dev This pool has a 1% LP fee, spacing 100 and no hook; these are Robinhood-specific settings.
    function initialBases() public pure returns (ERC20THook.ExternalBaseConfig[] memory bases) {
        bases = new ERC20THook.ExternalBaseConfig[](1);
        bases[0] = ERC20THook.ExternalBaseConfig({
            token: IMD_TOKEN,
            ethPool: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(IMD_TOKEN),
                fee: 10_000,
                tickSpacing: 100,
                hooks: IHooks(address(0))
            })
        });
    }

    function run() external returns (ERC20THook hook, ERC20TFactory factory) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        DeploymentConfig memory config;
        config.owner = _readHookOwner();
        config.distributors = _readGlobalDistributors();
        ERC20THook.ExternalBaseConfig[] memory bases = initialBases();
        _validatePreflight(config, bases[0].ethPool);

        // Resolve the signer chosen by Forge (including --sender/Ledger) without recording
        // a transaction. Do not infer it from the script caller, tx.origin or the final owner.
        vm.startBroadcast();
        (, config.broadcaster,) = vm.readCallers();
        vm.stopBroadcast();

        vm.startBroadcast(config.broadcaster);
        ERC20TGlobalDistributorRegistry registry =
            new ERC20TGlobalDistributorRegistry(config.owner, config.distributors);
        vm.stopBroadcast();

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        (address expectedAddress, bytes32 salt) =
            _mineHook(manager, config.owner, PROTOCOL_FEE_RECIPIENT, bases, address(registry));
        if (PROTOCOL_FEE_RECIPIENT == expectedAddress) {
            revert InvalidProtocolFeeRecipient(PROTOCOL_FEE_RECIPIENT);
        }
        for (uint256 i; i < config.distributors.length; ++i) {
            if (config.distributors[i] == expectedAddress) revert InvalidDistributor(config.distributors[i]);
        }

        vm.startBroadcast(config.broadcaster);
        hook = new ERC20THook{salt: salt}(manager, config.owner, PROTOCOL_FEE_RECIPIENT, bases, address(registry));
        if (address(hook) != expectedAddress) revert UnexpectedHookAddress();
        factory = new ERC20TFactory();
        vm.stopBroadcast();

        _logDeployment(config, hook, factory, bases[0].ethPool);
    }

    function _readHookOwner() internal view virtual returns (address) {
        return vm.envOr("HOOK_OWNER", DEFAULT_HOOK_OWNER);
    }

    function _readGlobalDistributors() internal view virtual returns (address[] memory) {
        string memory configured = vm.envOr("ROBINHOOD_GLOBAL_DISTRIBUTORS", string(""));
        if (bytes(configured).length == 0) return defaultGlobalDistributors();
        return vm.envAddress("ROBINHOOD_GLOBAL_DISTRIBUTORS", ",");
    }

    /// @notice Reviewed Robinhood routers and swap executors; never copied from Ethereum by assumption.
    /// @dev Checked 2026-10-18 against Kyber's deployment table, Relay's chain API, and
    ///      0x's deployment registry. Both current and previous 0x generations serve API routes.
    ///      The final address is an observed Fomo routing coordinator from transaction
    ///      0xeed7631c034ddd1237def3648a182a23373e92ac652ec42d75fdf6d97b5e4953.
    ///      Its source/provider identity is unverified; no Fomo ownership claim is made.
    function defaultGlobalDistributors() public pure returns (address[] memory accounts) {
        accounts = new address[](10);
        accounts[0] = 0x24A4d86c8A76B00EE9566eD9C9Ff4f0c3Faf0da7; // 0x taker Settler
        accounts[1] = 0x8627977302C8b880F3954F255029c745E94Fc9c4; // 0x gasless Settler
        accounts[2] = 0x6aa80DbBed9ae5aB45FbF61f9644faDA3b29326E; // 0x previous taker Settler
        accounts[3] = 0x03390030a8054ceDbf49920A91ec84d3210B2EAE; // 0x previous gasless Settler
        accounts[4] = 0x6868D319c8c9A78F7d39DC3602C5c917315132D7; // Kyber KSAggregationRouterV3
        accounts[5] = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5; // Kyber MetaAggregationRouterV2
        accounts[6] = 0x8F10B468b06c6FD214B65F87778827F7D113f996; // Kyber AggregationExecutorProxy
        accounts[7] = 0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f; // RelayRouterV3
        accounts[8] = 0x0729E2a4716d9f7dD17858d5d504426D228697f7; // RelayRouterV3.2
        accounts[9] = 0x0da5899dbB36Bd741885D4228f04cD9c6304FC56; // Observed Fomo routing coordinator
    }

    function _validatePreflight(DeploymentConfig memory config, PoolKey memory imdPool) private view {
        if (config.owner == address(0) || config.owner == MAINNET_GLOBAL_DISTRIBUTOR_REGISTRY) {
            revert InvalidHookOwner(config.owner);
        }
        if (PROTOCOL_FEE_RECIPIENT == address(0) || PROTOCOL_FEE_RECIPIENT == POOL_MANAGER) {
            revert InvalidProtocolFeeRecipient(PROTOCOL_FEE_RECIPIENT);
        }
        if (POOL_MANAGER.code.length == 0) revert InvalidInfrastructure(POOL_MANAGER);
        if (POSITION_MANAGER.code.length == 0) revert InvalidInfrastructure(POSITION_MANAGER);
        if (PERMIT2.code.length == 0) revert InvalidInfrastructure(PERMIT2);
        if (CREATE2_DEPLOYER.code.length == 0) revert InvalidInfrastructure(CREATE2_DEPLOYER);
        if (IMD_TOKEN.code.length == 0) revert InvalidInfrastructure(IMD_TOKEN);
        if (
            address(IPositionManager(POSITION_MANAGER).poolManager()) != POOL_MANAGER
                || IERC20TRobinhoodPositionManager(POSITION_MANAGER).permit2() != PERMIT2
        ) revert InvalidInfrastructure(POSITION_MANAGER);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(POOL_MANAGER), imdPool.toId());
        if (sqrtPriceX96 == 0) revert IMDPoolUnavailable();
        for (uint256 i; i < config.distributors.length; ++i) {
            address distributor = config.distributors[i];
            if (distributor == address(0) || distributor == POOL_MANAGER || distributor.code.length == 0) {
                revert InvalidDistributor(distributor);
            }
        }
    }

    function _logDeployment(
        DeploymentConfig memory config,
        ERC20THook hook,
        ERC20TFactory factory,
        PoolKey memory imdPool
    ) private view {
        console.log("CHAIN_ID", CHAIN_ID);
        console.log("BROADCASTER", config.broadcaster);
        console.log("POOL_MANAGER", POOL_MANAGER);
        console.log("POSITION_MANAGER", POSITION_MANAGER);
        console.log("PERMIT2", PERMIT2);
        console.log("CREATE2_DEPLOYER", CREATE2_DEPLOYER);
        console.log("HOOK_OWNER", hook.owner());
        console.log("PROTOCOL_FEE_RECIPIENT", PROTOCOL_FEE_RECIPIENT);
        console.log("ERC20T_HOOK", address(hook));
        console.log("GLOBAL_DISTRIBUTOR_REGISTRY", hook.globalDistributorRegistry());
        console.log(
            "GLOBAL_DISTRIBUTOR_OWNER", ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry()).owner()
        );
        console.log("SUPPLEMENTAL_DISTRIBUTOR_REGISTRY", address(hook));
        console.log("ERC20T_FACTORY", address(factory));
        console.log("ERC20T_IMPLEMENTATION", factory.implementation());
        console.log("IMD_BASE", IMD_TOKEN);
        console.log("IMD_ETH_POOL_ID");
        console.logBytes32(keccak256(abi.encode(imdPool)));
        console.log("IMD_ETH_POOL_FEE", uint256(imdPool.fee));
        console.log("IMD_ETH_TICK_SPACING", int256(imdPool.tickSpacing));
        console.log("IMD_ETH_HOOK", address(imdPool.hooks));
        console.log("GLOBAL_DISTRIBUTOR_COUNT", config.distributors.length);
        for (uint256 i; i < config.distributors.length; ++i) {
            console.log("GLOBAL_DISTRIBUTOR", config.distributors[i]);
        }
    }
}
