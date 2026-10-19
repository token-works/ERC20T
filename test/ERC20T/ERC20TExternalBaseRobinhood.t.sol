// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20TGlobalDistributorRegistry} from "../../src/ERC20T/ERC20TGlobalDistributorRegistry.sol";
import {DeployERC20TRobinhood} from "../../script/ERC20T/DeployERC20TRobinhood.s.sol";
import {
    ERC20TExternalBaseForkRouter,
    ERC20TExternalBaseRestrictedReceiver,
    IERC20TMainnetBase
} from "./ERC20TExternalBaseMainnet.t.sol";

/// @dev Fix only optional script inputs so local environment variables cannot alter fork assertions.
contract ERC20TRobinhoodForkDeployment is DeployERC20TRobinhood {
    address private immutable initialDistributor;
    bool private reviewedDefaults;

    constructor(address distributor) {
        initialDistributor = distributor;
    }

    function useReviewedDefaults() external {
        reviewedDefaults = true;
    }

    function _readHookOwner() internal pure override returns (address) {
        return DEFAULT_HOOK_OWNER;
    }

    function _readGlobalDistributors() internal view override returns (address[] memory accounts) {
        if (reviewedDefaults) return defaultGlobalDistributors();
        accounts = new address[](initialDistributor == address(0) ? 0 : 1);
        if (accounts.length != 0) accounts[0] = initialDistributor;
    }
}

/// @notice Opt-in integration: forge test --offline --fork-url robinhood
///         --fork-block-number 91914836 --match-contract ERC20TExternalBaseRobinhoodTest.
/// @dev Every deployment, script broadcast cheatcode and swap runs only in Forge's local fork.
///      Real PoolManager/PositionManager/Permit2/IMD runtime and liquidity are preserved.
///      Only the trader's ETH is funded; PoolManager and IMD balances are never mocked.
contract ERC20TExternalBaseRobinhoodTest is Test {
    using TransientStateLibrary for IPoolManager;

    address constant MANAGER = address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951"));
    address constant POSM = address(bytes20(hex"58daec3116aae6d93017baaea7749052e8a04fa7"));
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant IMD = address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"));
    address constant PROTOCOL_RECIPIENT = 0x3b78975E598731aa04AF1388E4E3BE099a29dC71;
    bytes32 constant IMD_POOL_ID = 0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant LP_SUPPLY = 800_000 ether;
    uint256 constant ETH_INPUT = 0.01 ether;
    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant FEE_EVENT = keccak256("HookFee(address,address,address,uint256,uint256)");
    bytes32 constant PROTOCOL_EVENT = keccak256("ProtocolFee(address,address,address,uint256)");
    bytes32 constant DECAY_EVENT = keccak256("FeeDecay(address,address,address,uint256)");

    struct FeeBalances {
        uint256 regular;
        uint256 protocol;
        uint256 decay;
    }

    struct Fees {
        uint256 tokenFee;
        uint256 regular;
        uint256 protocol;
        uint256 decay;
        uint256 conversionEth;
        uint256 conversionBase;
        uint256 grossOutput;
        uint256 regularEvents;
        uint256 protocolEvents;
        uint256 decayEvents;
        uint256 conversions;
    }

    ERC20TRobinhoodForkDeployment script;
    IPoolManager manager;
    ERC20THook hook;
    ERC20TFactory factory;
    ERC20TExternalBaseForkRouter router;
    ERC20TExternalBaseRestrictedReceiver receiver;
    PoolKey imdPool;
    uint256 initialHookEth;
    uint256 initialRouterEth;
    address alice = makeAddr("robinhoodForkAlice");
    address regularRecipient = makeAddr("robinhoodForkRegularRecipient");
    address decayRecipient = makeAddr("robinhoodForkDecayRecipient");

    function setUp() public {
        if (block.chainid != 4663 || MANAGER.code.length == 0) {
            vm.skip(true);
            return;
        }
        manager = IPoolManager(MANAGER);
        assertGt(MANAGER.balance, ETH_INPUT, "live PoolManager needs ETH liquidity");
        script = new ERC20TRobinhoodForkDeployment(address(0));
        (hook, factory) = script.run();
        imdPool = script.initialBases()[0].ethPool;
        assertEq(PoolId.unwrap(imdPool.toId()), IMD_POOL_ID);
        assertEq(imdPool.fee, 10_000);
        assertEq(imdPool.tickSpacing, 100);
        assertEq(address(imdPool.hooks), address(0));
        assertGt(StateLibrary.getLiquidity(manager, imdPool.toId()), 0);
        assertEq(address(hook.poolManager()), MANAGER);
        assertEq(hook.owner(), script.DEFAULT_HOOK_OWNER());
        assertGt(hook.globalDistributorRegistry().code.length, 0);
        assertEq(ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry()).owner(), script.DEFAULT_HOOK_OWNER());
        assertEq(hook.protocolFeeRecipient(), PROTOCOL_RECIPIENT);
        assertGt(factory.implementation().code.length, 0);
        uint160 permissions = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, permissions);
        (bool registered, bool enabled) = hook.externalBases(IMD);
        assertTrue(registered && enabled);
        assertEq(abi.encode(hook.externalBasePool(IMD)), abi.encode(imdPool));
        router = new ERC20TExternalBaseForkRouter(manager);
        receiver = new ERC20TExternalBaseRestrictedReceiver();
        initialHookEth = address(hook).balance;
        initialRouterEth = address(router).balance;
        vm.deal(alice, 10 ether);
    }

    function _config(address quote, bool declining) private view returns (ERC20T.Config memory) {
        return ERC20T.Config({
            name: "Robinhood Fork Token",
            symbol: "RHFORK",
            supply: SUPPLY,
            lpSupply: LP_SUPPLY,
            owner: address(this),
            hook: address(hook),
            quoteToken: quote,
            positionManager: IPositionManager(POSM),
            permit2: IAllowanceTransfer(PERMIT2),
            taxBps: 300,
            feeRecipient: regularRecipient,
            launchTaxBps: declining ? 9_900 : 0,
            taxDecayIntervalSeconds: declining ? 60 : 0,
            feeDecayRecipient: decayRecipient
        });
    }

    function _launchImdChild(bool tokenIsCurrency0, bool declining) private returns (ERC20T token) {
        ERC20T.Config memory config = _config(IMD, declining);
        bytes memory args = abi.encodePacked(address(hook), IMD, MANAGER, POSM, PERMIT2);
        address implementation = factory.implementation();
        bytes32 initHash = LibClone.initCodeHash(implementation, args);
        for (uint256 i; i < 10_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = LibClone.predictDeterministicAddress(initHash, salt, address(this));
            if ((predicted < IMD) == tokenIsCurrency0 && predicted.code.length == 0) {
                token = ERC20T(LibClone.cloneDeterministic(implementation, args, salt));
                token.initialize(config);
                break;
            }
        }
        assertTrue(address(token) != address(0));
        uint256 imdBefore = IERC20TMainnetBase(IMD).balanceOf(MANAGER);
        token.launch(
            uint160(1 << 96),
            tokenIsCurrency0 ? int24(0) : TickMath.minUsableTick(60),
            tokenIsCurrency0 ? TickMath.maxUsableTick(60) : int24(0)
        );
        assertEq(address(token) < IMD, tokenIsCurrency0);
        assertEq(token.quoteToken(), IMD);
        assertEq(IERC20TMainnetBase(IMD).balanceOf(MANAGER), imdBefore, "launch spent IMD");
        assertEq(IERC20TMainnetBase(IMD).balanceOf(address(token)), 0);
        assertEq(token.balanceOf(MANAGER) + token.balanceOf(address(token)), LP_SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - LP_SUPPLY);
        assertEq(token.allowance(address(token), PERMIT2), 0);
    }

    function _path(PoolKey memory childPool, bool buy, bool multiHop) private view returns (PoolKey[] memory path) {
        path = new PoolKey[](multiHop ? 2 : 1);
        path[0] = multiHop && buy ? imdPool : childPool;
        if (multiHop) path[1] = buy ? childPool : imdPool;
    }

    function _feeBalances() private view returns (FeeBalances memory) {
        return FeeBalances(regularRecipient.balance, PROTOCOL_RECIPIENT.balance, decayRecipient.balance);
    }

    function _assertFees(ERC20T token, FeeBalances memory beforeFees, bool buy)
        private
        view
        returns (Fees memory fees)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 childId = PoolId.unwrap(token.poolKey().toId());
        bool quoted = token.quoteToken() != address(0);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == MANAGER && logs[i].topics[0] == SWAP_EVENT) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                address sender = address(uint160(uint256(logs[i].topics[2])));
                if (logs[i].topics[1] == childId && sender == address(router)) {
                    bool output0 = (address(token) < token.quoteToken()) == buy;
                    fees.grossOutput = uint256(int256(output0 ? amount0 : amount1));
                }
                if (sender == address(hook) && logs[i].topics[1] == (quoted ? IMD_POOL_ID : childId)) {
                    fees.conversionEth += uint256(int256(amount0));
                    fees.conversionBase += uint256(-int256(amount1));
                    ++fees.conversions;
                }
            }
            if (logs[i].emitter != address(hook)) continue;
            bytes32 signature = logs[i].topics[0];
            if (signature != FEE_EVENT && signature != PROTOCOL_EVENT && signature != DECAY_EVENT) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
            address recipient = address(uint160(uint256(logs[i].topics[3])));
            if (signature == FEE_EVENT) {
                assertEq(recipient, regularRecipient);
                (fees.tokenFee, fees.regular) = abi.decode(logs[i].data, (uint256, uint256));
                ++fees.regularEvents;
            } else if (signature == PROTOCOL_EVENT) {
                assertEq(recipient, PROTOCOL_RECIPIENT);
                fees.protocol = abi.decode(logs[i].data, (uint256));
                ++fees.protocolEvents;
            } else {
                assertEq(recipient, decayRecipient);
                fees.decay = abi.decode(logs[i].data, (uint256));
                ++fees.decayEvents;
            }
        }
        uint256 total = fees.regular + fees.protocol + fees.decay;
        uint256 outputTax = fees.grossOutput * token.taxBps() / 10_000;
        assertEq(fees.regularEvents, 1);
        assertEq(fees.protocolEvents, 1);
        assertEq(fees.decayEvents, fees.decay == 0 ? 0 : 1);
        assertEq(fees.conversions, quoted || buy ? 1 : 0);
        assertEq(total, quoted || buy ? fees.conversionEth : outputTax);
        assertEq(buy ? fees.tokenFee : quoted ? fees.conversionBase : total, outputTax);
        assertEq(fees.protocol, total * 15 / token.taxBps());
        assertEq(fees.decay, total * (token.taxBps() - token.restingTaxBps()) / token.taxBps());
        assertEq(fees.regular, total - fees.protocol - fees.decay);
        assertGt(fees.regular, 0);
        assertGt(fees.protocol, 0);
        assertEq(regularRecipient.balance - beforeFees.regular, fees.regular);
        assertEq(PROTOCOL_RECIPIENT.balance - beforeFees.protocol, fees.protocol);
        assertEq(decayRecipient.balance - beforeFees.decay, fees.decay);
    }

    function _assertSettled(ERC20T token) private view {
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getNetTransferAllowance(), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(IERC20TMainnetBase(IMD).balanceOf(address(hook)), 0);
        assertEq(IERC20TMainnetBase(IMD).balanceOf(address(router)), 0);
        assertEq(address(hook).balance, initialHookEth);
        assertEq(address(router).balance, initialRouterEth);
        address[2] memory callers = [address(hook), address(router)];
        for (uint256 i; i < callers.length; ++i) {
            assertEq(manager.currencyDelta(callers[i], Currency.wrap(address(0))), 0);
            assertEq(manager.currencyDelta(callers[i], Currency.wrap(IMD)), 0);
            assertEq(manager.currencyDelta(callers[i], Currency.wrap(address(token))), 0);
        }
    }

    function _roundTrip(ERC20T token, bool multiHop) private {
        PoolKey memory childPool = token.poolKey();
        bool nativeInput = token.quoteToken() == address(0) || multiHop;
        uint256 amountIn = ETH_INPUT;
        if (!nativeInput) {
            PoolKey[] memory fundingPath = new PoolKey[](1);
            fundingPath[0] = imdPool;
            vm.prank(alice);
            amountIn = router.swap{value: ETH_INPUT}(fundingPath, address(0), ETH_INPUT) / 2;
            vm.prank(alice);
            IERC20TMainnetBase(IMD).approve(address(router), type(uint256).max);
        }
        FeeBalances memory beforeFees = _feeBalances();
        vm.recordLogs();
        vm.prank(alice);
        uint256 bought = router.swap{value: nativeInput ? amountIn : 0}(
            _path(childPool, true, multiHop), nativeInput ? address(0) : IMD, amountIn
        );
        Fees memory buyFees = _assertFees(token, beforeFees, true);
        assertGt(bought, 0);
        assertEq(bought, buyFees.grossOutput - buyFees.tokenFee);
        assertEq(token.balanceOf(alice), bought);
        assertFalse(token.isDistributor(address(router)));
        _assertSettled(token);
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(receiver), 1);
        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
        beforeFees = _feeBalances();
        uint256 balanceBefore = nativeInput ? alice.balance : IERC20TMainnetBase(IMD).balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        uint256 sold = router.swap(_path(childPool, false, multiHop), address(token), bought);
        _assertFees(token, beforeFees, false);
        assertGt(sold, 0);
        assertLt(sold, amountIn);
        uint256 balanceAfter = nativeInput ? alice.balance : IERC20TMainnetBase(IMD).balanceOf(alice);
        assertEq(balanceAfter, balanceBefore + sold);
        assertEq(token.balanceOf(alice), 0);
        _assertSettled(token);
    }

    function _decliningRoundTrips(ERC20T token, bool multiHop) private {
        assertEq(token.taxBps(), 9_900);
        _roundTrip(token, multiHop);
        vm.warp(token.launchedAt() + 96 * 60);
        assertEq(token.taxBps(), 300);
        assertFalse(token.taxDecayActive());
        _roundTrip(token, multiHop);
    }

    function testFork_robinhoodScriptDeploysAndSeedsTheSharedDistributorRegistry() public {
        assertFalse(hook.isDistributor(address(receiver)), "unseeded fixture must start empty");
        ERC20TRobinhoodForkDeployment seededScript = new ERC20TRobinhoodForkDeployment(address(receiver));
        (hook, factory) = seededScript.run();
        ERC20TGlobalDistributorRegistry registry = ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry());
        assertEq(hook.owner(), seededScript.DEFAULT_HOOK_OWNER());
        assertEq(registry.owner(), seededScript.DEFAULT_HOOK_OWNER());
        assertEq(hook.protocolFeeRecipient(), PROTOCOL_RECIPIENT);
        assertTrue(registry.isGlobalDistributor(address(receiver)));
        assertTrue(hook.isDistributor(address(receiver)));
        assertFalse(hook.isHookDistributor(address(receiver)), "approval must come from external registry");
        ERC20T token = factory.create(_config(address(0), false));
        assertTrue(token.useGlobalDistributors());
        assertTrue(token.isDistributor(address(receiver)));
        token.transfer(alice, 4 ether);
        vm.prank(alice);
        token.transfer(address(receiver), 1 ether);
        assertEq(token.balanceOf(address(receiver)), 1 ether);
        vm.prank(registry.owner());
        registry.setDistributor(address(receiver), false);
        assertFalse(token.isDistributor(address(receiver)), "registry revocation must apply live");
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(receiver), 1 ether);
        vm.prank(registry.owner());
        registry.setDistributor(address(receiver), true);
        address[] memory accounts = new address[](1);
        accounts[0] = address(router);
        vm.prank(hook.owner());
        hook.setDistributors(accounts, true);
        ERC20T second = factory.create(_config(address(0), false));
        token.setUseGlobalDistributors(false);
        assertFalse(token.isDistributor(address(receiver)));
        assertFalse(token.isDistributor(address(router)), "opt-out includes hook supplemental list");
        assertTrue(second.isDistributor(address(receiver)), "opt-out must be per token");
        assertTrue(second.isDistributor(address(router)));
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(receiver), 1 ether);
        accounts[0] = address(receiver);
        token.setDistributors(accounts, true);
        assertTrue(token.isLocalDistributor(address(receiver)));
        vm.prank(alice);
        token.transfer(address(receiver), 1 ether);
        assertEq(token.balanceOf(address(receiver)), 2 ether, "local approval must work while opted out");
        token.setDistributors(accounts, false);
        assertFalse(token.isDistributor(address(receiver)));
    }

    function testFork_robinhoodNativeLaunchBuyAndSellAtFixedTax() public {
        ERC20T token = factory.createAndLaunchAtPrice(_config(address(0), false), 2_000, 1 ether);
        _roundTrip(token, false);
    }

    /// @dev Reproduces observed token-transfer endpoints, without calling third-party routing code.
    function testFork_robinhoodDefaultRegistryPermitsObservedFomoTransferPathAndPreservesManagerGuard() public {
        address relay = 0xb92fe925DC43a0ECdE6c8b1a2709c170Ec4fFf4f;
        address coordinator = 0x0da5899dbB36Bd741885D4228f04cD9c6304FC56;
        address executor = address(bytes20(hex"0005ea38eb0a69d1253508ebdbdb9ea8cb26b5ef"));
        assertGt(executor.code.length, 0, "fork must include observed Fomo execution contracts");
        ERC20TRobinhoodForkDeployment defaultsScript = new ERC20TRobinhoodForkDeployment(address(0));
        defaultsScript.useReviewedDefaults();
        address[] memory accounts = defaultsScript.defaultGlobalDistributors();
        for (uint256 i; i < accounts.length; ++i) {
            assertGt(accounts[i].code.length, 0, "default distributor must exist on Robinhood");
        }
        (hook, factory) = defaultsScript.run();
        ERC20TGlobalDistributorRegistry registry = ERC20TGlobalDistributorRegistry(hook.globalDistributorRegistry());
        assertEq(registry.owner(), defaultsScript.DEFAULT_HOOK_OWNER());
        assertEq(hook.owner(), defaultsScript.DEFAULT_HOOK_OWNER());
        ERC20T token = factory.createAndLaunchAtPrice(_config(address(0), false), 2_000, 1 ether);
        assertTrue(token.launched());
        for (uint256 i; i < accounts.length; ++i) {
            assertTrue(registry.isGlobalDistributor(accounts[i]));
            assertTrue(hook.isDistributor(accounts[i]));
            assertTrue(token.isDistributor(accounts[i]));
            assertFalse(hook.isHookDistributor(accounts[i]));
        }
        assertTrue(token.isDistributor(relay));
        assertTrue(token.isDistributor(coordinator));
        assertFalse(token.isDistributor(alice));
        assertFalse(token.isDistributor(executor));
        assertFalse(registry.isGlobalDistributor(executor));
        uint256 amount = 1 ether;
        token.transfer(alice, amount);
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(executor, amount);
        address[4] memory path = [alice, relay, coordinator, executor];
        for (uint256 i; i < path.length - 1; ++i) {
            vm.prank(path[i]);
            token.transfer(path[i + 1], amount);
            assertEq(token.balanceOf(path[i]), 0);
            assertEq(token.balanceOf(path[i + 1]), amount);
        }
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getNetTransferAllowance(), 0);
        uint256 poolBalance = token.balanceOf(MANAGER);
        vm.prank(executor);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(MANAGER, amount);
        assertEq(token.balanceOf(MANAGER), poolBalance);
        assertEq(token.balanceOf(executor), amount);
        for (uint256 i = path.length - 1; i != 0; --i) {
            vm.prank(path[i]);
            token.transfer(path[i - 1], amount);
            assertEq(token.balanceOf(path[i]), 0);
            assertEq(token.balanceOf(path[i - 1]), amount);
        }
        assertEq(token.balanceOf(alice), amount);
    }

    function testFork_robinhoodNativeLaunchBuyAndSellAt99PercentAndRestingTax() public {
        ERC20T token = factory.createAndLaunchAtPrice(_config(address(0), true), 2_000, 1 ether);
        _decliningRoundTrips(token, false);
    }

    function testFork_robinhoodImdDirectBuyAndSellBothOrderingsAtFixedAndDecliningTax() public {
        for (uint256 i; i < 2; ++i) {
            _roundTrip(_launchImdChild(i == 0, false), false);
            _decliningRoundTrips(_launchImdChild(i == 0, true), false);
        }
    }

    function testFork_robinhoodFactoryLaunchesImdPoolAtPriceAndSupportsFixedAndDecliningTax() public {
        for (uint256 i; i < 2; ++i) {
            uint256 imdBefore = IERC20TMainnetBase(IMD).balanceOf(MANAGER);
            ERC20T token = factory.createAndLaunchAtPrice(_config(IMD, i == 1), 2_000, 1 ether);
            assertTrue(token.launched());
            assertTrue(hook.poolInitialized(address(token)));
            assertEq(token.owner(), address(this));
            assertEq(token.quoteToken(), IMD);
            assertEq(token.balanceOf(address(this)), SUPPLY - LP_SUPPLY);
            assertEq(token.balanceOf(MANAGER) + token.balanceOf(address(token)), LP_SUPPLY);
            assertEq(IERC20TMainnetBase(IMD).balanceOf(MANAGER), imdBefore, "factory launch spent IMD");
            if (i == 0) _roundTrip(token, true);
            else _decliningRoundTrips(token, true);
        }
    }

    function testFork_robinhoodEthImdMultihopBothOrderingsAtFixedAndDecliningTax() public {
        for (uint256 i; i < 2; ++i) {
            _roundTrip(_launchImdChild(i == 0, false), true);
            _decliningRoundTrips(_launchImdChild(i == 0, true), true);
        }
    }
}
