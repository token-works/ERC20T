// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20T_TICK_SPACING} from "../../src/ERC20T/ERC20TInterfaces.sol";
import {TokenPosmHelper} from "../support/TokenPosmHelper.sol";

interface IERC20TPositionOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract ERC20TDistributor {
    function send(ERC20T token, address recipient, uint256 amount) external {
        token.transfer(recipient, amount);
    }

    function pull(ERC20T token, address from, address recipient, uint256 amount) external {
        token.transferFrom(from, recipient, amount);
    }
}

contract ERC20TConstructorSender {
    uint256 public codeLengthDuringConstruction;
    address public transactionOrigin;
    bool public succeeded;
    bytes32 public failureHash;

    constructor(ERC20T token, address recipient, uint256 amount) {
        codeLengthDuringConstruction = address(this).code.length;
        transactionOrigin = tx.origin;
        bytes memory reason;
        (succeeded, reason) = address(token).call(abi.encodeCall(ERC20.transfer, (recipient, amount)));
        failureHash = keccak256(reason);
    }
}

contract ERC20TRejectingFeeRecipient {
    receive() external payable {
        revert("reject native callback");
    }
}

contract ERC20TCountingFeeRecipient {
    uint256 public calls;

    receive() external payable {
        ++calls;
    }
}

/// @dev Mutates all destinations from the first ETH payout while also owning the token
/// and hook. The in-flight fee must retain its original destination snapshot.
contract ERC20TMutatingFeeRecipient {
    ERC20T public token;
    ERC20THook public hook;
    address public immutable nextRecipient;
    bool public changed;

    constructor(address nextRecipient_) {
        nextRecipient = nextRecipient_;
    }

    function configure(ERC20T token_, ERC20THook hook_) external {
        token = token_;
        hook = hook_;
    }

    receive() external payable {
        if (!changed) {
            changed = true;
            token.setFeeRecipient(nextRecipient);
            token.setFeeDecayRecipient(nextRecipient);
            hook.setProtocolFeeRecipient(nextRecipient);
        }
    }
}

contract ERC20TReentrantFeeRecipient {
    IPoolManager immutable manager;
    PoolKey private poolKey;
    bool public attempted;
    bool public succeeded;
    bytes32 public failureHash;

    constructor(IPoolManager manager_, PoolKey memory key_) {
        manager = manager_;
        poolKey = key_;
    }

    receive() external payable {
        attempted = true;
        // The manager is already unlocked while taxes are delivered. A direct nested
        // swap must fail at the hook and roll back its pool/delta changes.
        bytes memory reason;
        (succeeded, reason) = address(manager).call{gas: 60_000}(
            abi.encodeCall(
                IPoolManager.swap,
                (
                    poolKey,
                    SwapParams({
                        zeroForOne: true,
                        amountSpecified: -int256(msg.value),
                        sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                    }),
                    bytes("")
                )
            )
        );
        failureHash = keccak256(reason);
    }
}

/// @notice Real v4 integration tests, including the documented ERC-6909 limitation.
contract ERC20TTest is Deployers, TokenPosmHelper {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LP_SUPPLY = 800_000_000 ether;
    bytes32 constant FEE_EVENT = keccak256("HookFee(address,address,address,uint256,uint256)");
    bytes32 constant PROTOCOL_FEE_EVENT = keccak256("ProtocolFee(address,address,address,uint256)");
    bytes32 constant DECAY_FEE_EVENT = keccak256("FeeDecay(address,address,address,uint256)");

    struct FeeSplit {
        uint256 tokenFee;
        uint256 regularEth;
        uint256 protocolEth;
        uint256 decayEth;
        address regularRecipient;
        address protocolRecipient;
        address decayRecipient;
    }

    ERC20T token;
    ERC20THook hook;
    ERC20TFactory factory;
    ERC20TDistributor distributor;
    ERC20TDistributor otherDistributor;
    address feeWallet = makeAddr("feeWallet");
    address protocolWallet = makeAddr("protocolWallet");
    address decayWallet = makeAddr("decayWallet");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        _deployPosm(manager);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ERC20THook).creationCode,
            abi.encode(manager, address(this), protocolWallet, new ERC20THook.ExternalBaseConfig[](0), address(0))
        );
        vm.prank(CREATE2_DEPLOYER);
        hook = new ERC20THook{salt: salt}(
            manager, address(this), protocolWallet, new ERC20THook.ExternalBaseConfig[](0), address(0)
        );
        assertEq(address(hook), expected);
        distributor = new ERC20TDistributor();
        otherDistributor = new ERC20TDistributor();
        factory = new ERC20TFactory();
        token = factory.create(_config(address(this), 100, feeWallet));
        key = token.poolKey();
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 1_000 ether);
        // Match the native balance shared by all pools on the production singleton.
        vm.deal(address(manager), 100 ether);
        _launch(token);
    }

    function _config(address owner, uint16 tax, address recipient) internal view returns (ERC20T.Config memory) {
        return ERC20T.Config({
            name: "Taxed Token",
            symbol: "TAX",
            supply: SUPPLY,
            lpSupply: LP_SUPPLY,
            owner: owner,
            hook: address(hook),
            quoteToken: address(0),
            positionManager: posm,
            permit2: IAllowanceTransfer(PERMIT2_ADDR),
            taxBps: tax,
            feeRecipient: recipient,
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0,
            feeDecayRecipient: address(0)
        });
    }

    function _launch(ERC20T target) internal {
        target.launch{value: 2}(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
    }

    function _decayConfig(uint16 resting, uint16 starting, uint32 interval)
        internal
        view
        returns (ERC20T.Config memory config)
    {
        config = _config(address(this), resting, feeWallet);
        config.launchTaxBps = starting;
        config.taxDecayIntervalSeconds = interval;
        config.feeDecayRecipient = decayWallet;
    }

    function test_flatTaxRemainsManuallyAdjustableWithoutDecay() public {
        assertEq(token.restingTaxBps(), 100);
        assertEq(token.launchTaxBps(), 0);
        assertEq(token.taxDecayIntervalSeconds(), 0);
        assertFalse(token.taxDecayActive());
        token.setTaxBps(30);
        vm.warp(vm.getBlockTimestamp() + 100 * 365 days);
        assertEq(token.taxBps(), 30);
        token.setTaxBps(500);
        assertEq(token.restingTaxBps(), 500);
        assertEq(token.taxBps(), 500);
        assertFalse(token.taxDecayActive());
    }

    function test_launchTaxClockStartsAtLaunchAndDropsOnlyAtCompletedIntervals() public {
        ERC20T fresh = factory.create(_decayConfig(30, 9_900, 60));
        assertEq(fresh.TAX_DECAY_STEP_BPS(), 100);
        assertEq(fresh.LAUNCH_TAX_BPS(), 9_900);
        assertEq(fresh.launchedAt(), 0);
        assertFalse(fresh.taxDecayActive());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(fresh.taxBps(), 9_900);
        uint256 start = vm.getBlockTimestamp();
        _launch(fresh);
        assertEq(fresh.launchedAt(), start);
        assertEq(fresh.restingTaxBps(), 30);
        assertEq(fresh.launchTaxBps(), 9_900);
        assertEq(fresh.taxDecayIntervalSeconds(), 60);
        for (uint256 i; i <= 99; ++i) {
            uint256 expected = i == 99 ? 30 : 9_900 - i * 100;
            vm.warp(start + i * 60);
            assertEq(fresh.taxBps(), expected);
            assertEq(fresh.taxDecayActive(), i < 99);
            vm.warp(start + (i + 1) * 60 - 1);
            assertEq(fresh.taxBps(), expected);
        }
        vm.warp(type(uint256).max);
        assertEq(fresh.taxBps(), 30);
        assertFalse(fresh.taxDecayActive());
    }

    function test_launchTaxClampsOddRestingRatesAndMaximumRestingRateExactly() public {
        ERC20T fresh = factory.create(_decayConfig(65, 9_900, 7));
        _launch(fresh);
        uint256 start = vm.getBlockTimestamp();
        uint16[4] memory expected = [uint16(300), 200, 100, 65];
        for (uint256 i; i < expected.length; ++i) {
            vm.warp(start + (96 + i) * 7);
            assertEq(fresh.taxBps(), expected[i]);
            assertEq(fresh.taxDecayActive(), i < 3);
        }
        assertFalse(fresh.taxDecayActive());

        ERC20T maximumFloor = factory.create(_decayConfig(500, 9_900, 60));
        _launch(maximumFloor);
        start = vm.getBlockTimestamp();
        vm.warp(start + 94 * 60 - 1);
        assertEq(maximumFloor.taxBps(), 600);
        assertTrue(maximumFloor.taxDecayActive());
        vm.warp(start + 94 * 60);
        assertEq(maximumFloor.taxBps(), 500);
        assertFalse(maximumFloor.taxDecayActive());
    }

    function test_launchTaxLocksOnlyActiveScheduleAndCompletedChangesDoNotRestartIt() public {
        ERC20T fresh = factory.create(_decayConfig(30, 9_900, 60));
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        fresh.setTaxBps(500);
        fresh.setTaxBps(500);
        fresh.setTaxBps(150);
        assertEq(fresh.restingTaxBps(), 150);
        assertEq(fresh.taxBps(), 9_900);
        vm.expectRevert(ERC20T.InvalidTax.selector);
        fresh.setTaxBps(501);
        _launch(fresh);
        uint256 start = vm.getBlockTimestamp();
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        fresh.setTaxBps(200);
        vm.warp(start + 98 * 60 - 1);
        assertEq(fresh.taxBps(), 200);
        vm.expectRevert(ERC20T.TaxDecayActive.selector);
        fresh.setTaxBps(200);
        assertEq(fresh.restingTaxBps(), 150);
        vm.warp(start + 98 * 60);
        assertFalse(fresh.taxDecayActive());
        assertEq(fresh.taxBps(), 150);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        fresh.setTaxBps(500);
        fresh.setTaxBps(500);
        assertEq(fresh.taxBps(), 500);
        // A subsequent decrease cannot extend the original 98-step completion threshold.
        fresh.setTaxBps(30);
        assertEq(fresh.taxBps(), 30);
        assertFalse(fresh.taxDecayActive());
        assertEq(fresh.launchTaxBps(), 9_900);
        assertEq(fresh.taxDecayIntervalSeconds(), 60);
        assertEq(fresh.launchedAt(), start);
        vm.warp(start + 10 days);
        assertEq(fresh.taxBps(), 30);
    }

    function _expectInvalidDecay(uint16 resting, uint16 starting, uint32 interval, bytes4 reason) internal {
        ERC20T.Config memory config = _decayConfig(resting, starting, interval);
        vm.expectRevert(reason);
        factory.create(config);
    }

    function test_launchTaxRejectsMalformedSchedulesAndInvalidRates() public {
        _expectInvalidDecay(30, 0, 60, ERC20T.InvalidTaxDecayConfiguration.selector);
        _expectInvalidDecay(30, 9_900, 0, ERC20T.InvalidTaxDecayConfiguration.selector);
        _expectInvalidDecay(300, 200, 60, ERC20T.InvalidTaxDecayConfiguration.selector);
        _expectInvalidDecay(30, 29, 60, ERC20T.InvalidTaxDecayConfiguration.selector);
        _expectInvalidDecay(120, 120, 60, ERC20T.InvalidTaxDecayConfiguration.selector);
        uint16[6] memory invalidStarts = [uint16(500), 501, 9_899, 9_901, 10_000, type(uint16).max];
        for (uint256 i; i < invalidStarts.length; ++i) {
            _expectInvalidDecay(30, invalidStarts[i], 60, ERC20T.InvalidTaxDecayConfiguration.selector);
        }
        _expectInvalidDecay(29, 9_900, 60, ERC20T.InvalidTax.selector);
        _expectInvalidDecay(501, 9_900, 60, ERC20T.InvalidTax.selector);
    }

    function test_failedPoolSeedingRollsBackLaunchTaxClockAndCanBeRetried() public {
        ERC20T fresh = factory.create(_decayConfig(30, 9_900, 60));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bytes4 seedFailure = bytes4(keccak256("SeedFailed()"));
        vm.mockCallRevert(
            address(posm), abi.encodeWithSignature("multicall(bytes[])"), abi.encodeWithSelector(seedFailure)
        );
        vm.expectRevert(seedFailure);
        _launch(fresh);
        assertFalse(fresh.launched());
        assertFalse(fresh.launching());
        assertFalse(fresh.taxDecayActive());
        assertEq(fresh.launchedAt(), 0);
        assertEq(fresh.taxBps(), 9_900);
        assertEq(fresh.balanceOf(address(fresh)), LP_SUPPLY);
        assertEq(fresh.allowance(address(fresh), PERMIT2_ADDR), 0);
        vm.clearMockedCalls();
        vm.warp(vm.getBlockTimestamp() + 600);
        _launch(fresh);
        assertEq(fresh.launchedAt(), vm.getBlockTimestamp());
        assertEq(fresh.taxBps(), 9_900);
        assertTrue(fresh.taxDecayActive());
    }

    function testFuzz_launchTaxClampsSafelyForAnyElapsedTime(uint16 rawResting, uint32 rawInterval, uint256 rawElapsed)
        public
    {
        uint16 starting = 9_900;
        uint16 resting = uint16(bound(rawResting, 30, 500));
        uint32 interval = uint32(bound(rawInterval, 1, type(uint32).max));
        ERC20T fresh = factory.create(_decayConfig(resting, starting, interval));
        vm.warp(1_000);
        _launch(fresh);
        uint256 elapsed = rawElapsed % 2 == 0
            ? bound(rawElapsed, 0, uint256(interval) * 100)
            : bound(rawElapsed, 0, type(uint256).max - 1_000);
        vm.warp(1_000 + elapsed);
        uint256 steps = elapsed / interval;
        uint256 requiredSteps = (uint256(starting) - resting + 99) / 100;
        assertGe(requiredSteps, 94);
        assertLe(requiredSteps, 99);
        uint256 expected = steps >= requiredSteps ? resting : uint256(starting) - steps * 100;
        assertEq(fresh.taxBps(), expected);
        assertEq(fresh.taxDecayActive(), steps < requiredSteps);
        assertGe(fresh.taxBps(), resting);
        assertLe(fresh.taxBps(), starting);
    }

    function _assertDecayBuyGiftSell(uint16 expectedRate) internal returns (FeeSplit memory fees) {
        assertEq(token.taxBps(), expectedRate);
        uint256 creatorBefore = feeWallet.balance;
        uint256 protocolBefore = protocolWallet.balance;
        uint256 decayBefore = decayWallet.balance;
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        fees = _splitFeeEvents();
        _assertSplit(fees, expectedRate, token.restingTaxBps());
        assertEq(fees.regularRecipient, feeWallet);
        assertEq(fees.protocolRecipient, protocolWallet);
        if (fees.decayEth != 0) assertEq(fees.decayRecipient, decayWallet);
        uint256 bought = token.balanceOf(alice);
        assertEq(fees.tokenFee, (bought + fees.tokenFee) * expectedRate / 10_000);
        assertEq(feeWallet.balance, creatorBefore + fees.regularEth);
        assertEq(protocolWallet.balance, protocolBefore + fees.protocolEth);
        assertEq(decayWallet.balance, decayBefore + fees.decayEth);
        creatorBefore = feeWallet.balance;
        protocolBefore = protocolWallet.balance;
        decayBefore = decayWallet.balance;
        vm.prank(alice, alice);
        token.transfer(bob, bought);
        assertEq(token.balanceOf(bob), bought);
        assertEq(feeWallet.balance, creatorBefore);
        assertEq(protocolWallet.balance, protocolBefore);
        assertEq(decayWallet.balance, decayBefore);
        vm.prank(bob);
        token.approve(address(swapRouter), bought);
        uint256 before = bob.balance;
        vm.recordLogs();
        _sell(bob, bought);
        fees = _splitFeeEvents();
        _assertSplit(fees, expectedRate, token.restingTaxBps());
        uint256 received = bob.balance - before;
        uint256 combinedFee = fees.regularEth + fees.protocolEth + fees.decayEth;
        assertEq(combinedFee, (received + combinedFee) * expectedRate / 10_000);
        assertEq(feeWallet.balance, creatorBefore + fees.regularEth);
        assertEq(protocolWallet.balance, protocolBefore + fees.protocolEth);
        assertEq(decayWallet.balance, decayBefore + fees.decayEth);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.getNetTransferAllowance(), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getTransferAllowance(false), 0);
    }

    function test_realBuysAndSellsUseCurrentLaunchTaxWhileWalletGiftsStayUntaxed() public {
        token = factory.create(_decayConfig(30, 9_900, 60));
        key = token.poolKey();
        _launch(token);
        uint256 start = vm.getBlockTimestamp();
        _assertDecayBuyGiftSell(9_900);
        vm.warp(start + 60);
        _assertDecayBuyGiftSell(9_800);
        vm.warp(start + 96 * 60);
        _assertDecayBuyGiftSell(300);
        vm.warp(start + 99 * 60);
        _assertDecayBuyGiftSell(30);
    }

    function _launchDecayToken(uint16 resting) private {
        token = factory.create(_decayConfig(resting, 9_900, 60));
        key = token.poolKey();
        _launch(token);
    }

    function test_decayFeeAtNinetyNinePercentSeparatesNinetyFourPercentFromFivePercentRestingTax() public {
        _launchDecayToken(500);
        FeeSplit memory fees = _assertDecayBuyGiftSell(9_900);
        uint256 total = fees.regularEth + fees.protocolEth + fees.decayEth;
        assertEq(fees.decayEth, total * 9_400 / 9_900);
        assertEq(fees.protocolEth, total * 15 / 9_900);
        // The regular recipient keeps 4.85% plus the remainder from integer division.
        assertGe(fees.regularEth, total * 485 / 9_900);
        assertLe(fees.regularEth - total * 485 / 9_900, 2);
        vm.warp(uint256(token.launchedAt()) + 94 * 60);
        uint256 decayBefore = decayWallet.balance;
        fees = _assertDecayBuyGiftSell(500);
        assertEq(fees.decayEth, 0);
        assertEq(decayWallet.balance, decayBefore);
    }

    function test_decayFeeUsesOddRestingFloorUntilFinalClamp() public {
        _launchDecayToken(65);
        uint256 start = token.launchedAt();
        vm.warp(start + 98 * 60);
        FeeSplit memory fees = _assertDecayBuyGiftSell(100);
        uint256 total = fees.regularEth + fees.protocolEth + fees.decayEth;
        assertEq(fees.decayEth, total * 35 / 100);
        vm.warp(start + 99 * 60);
        uint256 decayBefore = decayWallet.balance;
        fees = _assertDecayBuyGiftSell(65);
        assertEq(fees.decayEth, 0);
        assertEq(decayWallet.balance, decayBefore);
    }

    function test_decayRecipientDefaultsToInitialRegularRecipientAndHasIndependentOwnerControl() public {
        assertEq(token.feeDecayRecipient(), feeWallet);
        token.setFeeRecipient(bob);
        assertEq(token.feeDecayRecipient(), feeWallet);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setFeeDecayRecipient(alice);
        address[4] memory invalid = [address(0), address(token), address(hook), address(manager)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ERC20T.InvalidAddress.selector);
            token.setFeeDecayRecipient(invalid[i]);
        }
        vm.recordLogs();
        token.setFeeDecayRecipient(decayWallet);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("FeeDecayRecipientSet(address)"));
        assertEq(token.feeDecayRecipient(), decayWallet);
        // The configured destination earns nothing while the token has a static tax.
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        _feeEvents();
        assertEq(decayWallet.balance, 0);
    }

    function test_decayRecipientInitializerRejectsTokenHookAndManagerDestinations() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        address[3] memory invalid = [predicted, address(hook), address(manager)];
        for (uint256 i; i < invalid.length; ++i) {
            ERC20T.Config memory config = _decayConfig(500, 9_900, 60);
            config.feeDecayRecipient = invalid[i];
            vm.expectRevert(ERC20T.InvalidAddress.selector);
            factory.create(config);
            assertEq(predicted.code.length, 0);
        }
    }

    function _assertCombinedDecayPayouts(uint256 combination) private {
        _launchDecayToken(500);
        ERC20TCountingFeeRecipient first = new ERC20TCountingFeeRecipient();
        ERC20TCountingFeeRecipient second = new ERC20TCountingFeeRecipient();
        address regular = address(first);
        address protocol = combination == 1 ? address(second) : address(first);
        address decay = combination == 0 ? address(second) : address(first);
        if (combination == 2) regular = address(second);
        token.setFeeRecipient(regular);
        hook.setProtocolFeeRecipient(protocol);
        token.setFeeDecayRecipient(decay);
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        FeeSplit memory fees = _splitFeeEvents();
        _assertSplit(fees, 9_900, 500);
        uint256 firstExpected = (regular == address(first) ? fees.regularEth : 0)
            + (protocol == address(first) ? fees.protocolEth : 0) + (decay == address(first) ? fees.decayEth : 0);
        uint256 secondExpected = fees.regularEth + fees.protocolEth + fees.decayEth - firstExpected;
        assertEq(address(first).balance, firstExpected);
        assertEq(address(second).balance, secondExpected);
        assertEq(first.calls(), firstExpected == 0 ? 0 : 1);
        assertEq(second.calls(), secondExpected == 0 ? 0 : 1);
        assertEq(fees.regularRecipient, regular);
        assertEq(fees.protocolRecipient, protocol);
        assertEq(fees.decayRecipient, decay);
        assertEq(address(hook).balance, 0);
    }

    function test_decayPayoutCombinesEveryPairOfIdenticalRecipientsAndAllThree() public {
        // Normal+protocol, normal+decay, protocol+decay, then all three destinations.
        for (uint256 i; i < 4; ++i) {
            _assertCombinedDecayPayouts(i);
        }
    }

    function test_rejectingDecayRecipientStillReceivesBuyAndSellEth() public {
        _launchDecayToken(500);
        ERC20TRejectingFeeRecipient recipient = new ERC20TRejectingFeeRecipient();
        token.setFeeDecayRecipient(address(recipient));
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        FeeSplit memory fees = _splitFeeEvents();
        _assertSplit(fees, 9_900, 500);
        assertEq(address(recipient).balance, fees.decayEth);
        assertGt(fees.decayEth, 0);
        uint256 decayBefore = address(recipient).balance;
        uint256 bought = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(swapRouter), bought);
        vm.recordLogs();
        _sell(alice, bought);
        fees = _splitFeeEvents();
        _assertSplit(fees, 9_900, 500);
        assertEq(address(recipient).balance, decayBefore + fees.decayEth);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_recipientChangesDuringPayoutApplyOnlyToSubsequentSwaps() public {
        _launchDecayToken(500);
        ERC20TMutatingFeeRecipient mutator = new ERC20TMutatingFeeRecipient(bob);
        mutator.configure(token, hook);
        hook.setProtocolFeeRecipient(address(mutator));
        token.transferOwnership(address(mutator));
        hook.transferOwnership(address(mutator));
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        FeeSplit memory fees = _splitFeeEvents();
        _assertSplit(fees, 9_900, 500);
        assertTrue(mutator.changed());
        assertEq(fees.regularRecipient, feeWallet);
        assertEq(fees.decayRecipient, decayWallet);
        assertEq(fees.protocolRecipient, address(mutator));
        assertEq(feeWallet.balance, fees.regularEth);
        assertEq(decayWallet.balance, fees.decayEth);
        assertEq(address(mutator).balance, fees.protocolEth);
        assertEq(bob.balance, 0);
        assertEq(token.feeRecipient(), bob);
        assertEq(token.feeDecayRecipient(), bob);
        assertEq(hook.protocolFeeRecipient(), bob);
        uint256 previousProtocol = address(mutator).balance;
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        fees = _splitFeeEvents();
        _assertSplit(fees, 9_900, 500);
        assertEq(fees.regularRecipient, bob);
        assertEq(fees.decayRecipient, bob);
        assertEq(fees.protocolRecipient, bob);
        assertEq(bob.balance, fees.regularEth + fees.protocolEth + fees.decayEth);
        assertEq(address(mutator).balance, previousProtocol);
    }

    function testFuzz_decayFeeSplitConservesConvertedEthAcrossRatesAndRounding(
        uint16 rawResting,
        uint8 rawSteps,
        uint96 rawEthIn
    ) public {
        uint16 resting = uint16(bound(rawResting, 30, 500));
        _launchDecayToken(resting);
        uint256 steps = bound(rawSteps, 0, 99);
        vm.warp(uint256(token.launchedAt()) + steps * 60);
        uint256 amount = bound(rawEthIn, 1_000, 10 ether);
        uint256 current = token.taxBps();
        vm.recordLogs();
        _buy(token, alice, amount);
        FeeSplit memory fees = _splitFeeEvents();
        _assertSplit(fees, current, resting);
        assertEq(feeWallet.balance, fees.regularEth);
        assertEq(protocolWallet.balance, fees.protocolEth);
        assertEq(decayWallet.balance, fees.decayEth);
        assertEq(fees.tokenFee, (token.balanceOf(alice) + fees.tokenFee) * current / 10_000);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function _accounts(address first) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = first;
    }

    function _buy(ERC20T target, address buyer, uint256 ethIn) internal returns (BalanceDelta delta) {
        vm.deal(buyer, ethIn);
        PoolKey memory targetKey = target.poolKey();
        vm.prank(buyer);
        delta = swapRouter.swap{value: ethIn}(
            targetKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _sell(address seller, uint256 tokenIn) internal returns (BalanceDelta delta) {
        vm.prank(seller);
        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _splitFeeEvents() internal returns (FeeSplit memory fees) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 creatorEvents;
        uint256 protocolEvents;
        uint256 decayEvents;
        bytes32 creatorSender;
        bytes32 protocolSender;
        bytes32 decaySender;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == FEE_EVENT) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
                fees.regularRecipient = address(uint160(uint256(logs[i].topics[3])));
                (fees.tokenFee, fees.regularEth) = abi.decode(logs[i].data, (uint256, uint256));
                creatorSender = logs[i].topics[2];
                ++creatorEvents;
            } else if (logs[i].topics[0] == PROTOCOL_FEE_EVENT) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
                fees.protocolRecipient = address(uint160(uint256(logs[i].topics[3])));
                fees.protocolEth = abi.decode(logs[i].data, (uint256));
                protocolSender = logs[i].topics[2];
                ++protocolEvents;
            } else if (logs[i].topics[0] == DECAY_FEE_EVENT) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(token));
                fees.decayRecipient = address(uint160(uint256(logs[i].topics[3])));
                fees.decayEth = abi.decode(logs[i].data, (uint256));
                decaySender = logs[i].topics[2];
                ++decayEvents;
            }
        }
        assertEq(creatorEvents, 1);
        assertEq(protocolEvents, 1);
        assertEq(creatorSender, protocolSender);
        assertEq(decayEvents, fees.decayEth == 0 ? 0 : 1);
        if (decayEvents != 0) assertEq(creatorSender, decaySender);
        assertEq(hook.PROTOCOL_FEE_BPS(), 15);
    }

    function _assertSplit(FeeSplit memory fees, uint256 current, uint256 resting) internal pure {
        uint256 total = fees.regularEth + fees.protocolEth + fees.decayEth;
        assertEq(fees.protocolEth, total * 15 / current);
        assertEq(fees.decayEth, total * (current - resting) / current);
        assertEq(fees.regularEth, total - fees.protocolEth - fees.decayEth);
    }

    function _feeEvents() internal returns (uint256 tokenFee, uint256 creatorEth, uint256 protocolEth) {
        FeeSplit memory fees = _splitFeeEvents();
        assertEq(fees.regularRecipient, token.feeRecipient());
        assertEq(fees.protocolRecipient, hook.protocolFeeRecipient());
        _assertSplit(fees, token.taxBps(), token.restingTaxBps());
        assertEq(fees.decayEth, 0);
        return (fees.tokenFee, fees.regularEth, fees.protocolEth);
    }

    function _cloneArgs(ERC20T.Config memory config) internal view returns (bytes memory) {
        return abi.encodePacked(
            config.hook, config.quoteToken, address(manager), address(config.positionManager), address(config.permit2)
        );
    }

    function test_cloneImplementationIsLockedAndInitializationCannotRepeatAfterRenounce() public {
        ERC20T implementation = ERC20T(factory.implementation());
        ERC20T.Config memory config = _config(address(this), 100, feeWallet);
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        implementation.initialize(config);
        assertEq(implementation.owner(), address(0));
        assertEq(implementation.totalSupply(), 0);

        ERC20T fresh = factory.create(config);
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        fresh.initialize(config);
        fresh.renounceOwnership();
        config.owner = alice;
        vm.prank(alice);
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        fresh.initialize(config);
        assertEq(fresh.owner(), address(0));
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(alice), 0);
        assertEq(fresh.balanceOf(address(this)), SUPPLY - LP_SUPPLY);
    }

    function test_cloneRejectsMissingExtraAndMismatchedImmutableArguments() public {
        address implementation = factory.implementation();
        ERC20T.Config memory config = _config(address(this), 100, feeWallet);
        uint256[3] memory invalidLengths = [uint256(0), 99, 101];
        for (uint256 i; i < invalidLengths.length; ++i) {
            ERC20T malformed = ERC20T(LibClone.clone(implementation, new bytes(invalidLengths[i])));
            vm.expectRevert(ERC20T.InvalidClone.selector);
            malformed.initialize(config);
        }

        for (uint256 i; i < 5; ++i) {
            address[5] memory args = [address(hook), address(0), address(manager), address(posm), PERMIT2_ADDR];
            args[i] = alice;
            ERC20T mismatched =
                ERC20T(LibClone.clone(implementation, abi.encodePacked(args[0], args[1], args[2], args[3], args[4])));
            vm.expectRevert(ERC20T.InvalidClone.selector);
            mismatched.initialize(config);
            assertEq(mismatched.owner(), address(0));
            assertEq(mismatched.totalSupply(), 0);
        }
    }

    function test_cloneFailedInitializationRollsBackAndCanBeRetried() public {
        ERC20T.Config memory config = _config(address(this), 501, feeWallet);
        ERC20T fresh = ERC20T(LibClone.clone(factory.implementation(), _cloneArgs(config)));
        vm.expectRevert(ERC20T.InvalidTax.selector);
        fresh.initialize(config);
        assertEq(fresh.totalSupply(), 0);
        assertEq(fresh.owner(), address(0));
        config.taxBps = 30;
        fresh.initialize(config);
        assertEq(fresh.taxBps(), 30);
        assertEq(fresh.owner(), address(this));
        assertEq(fresh.totalSupply(), SUPPLY);
        assertTrue(fresh.useGlobalDistributors());
    }

    function test_cloneBalancesAllowancesAndPoliciesAreIndependent() public {
        ERC20T.Config memory secondConfig = _config(bob, 500, bob);
        secondConfig.name = "Second Clone";
        secondConfig.symbol = "SECOND";
        ERC20T second = factory.create(secondConfig);
        token.transfer(alice, 3 ether);
        token.approve(alice, 7 ether);
        token.setDistributors(_accounts(address(distributor)), true);
        token.setUseGlobalDistributors(false);
        token.setExternalLiquidityEnabled(true);
        token.setPairingEnabled(true);
        token.setTaxBps(30);
        token.setFeeRecipient(alice);
        vm.prank(bob);
        second.approve(alice, 11 ether);

        assertEq(second.name(), "Second Clone");
        assertEq(second.symbol(), "SECOND");
        assertEq(token.name(), "Taxed Token");
        assertEq(second.owner(), bob);
        assertEq(token.owner(), address(this));
        assertEq(second.balanceOf(alice), 0);
        assertEq(second.balanceOf(address(this)), 0);
        assertEq(second.balanceOf(bob), SUPPLY - LP_SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.allowance(address(this), alice), 7 ether);
        assertEq(second.allowance(address(this), alice), 0);
        assertEq(second.allowance(bob, alice), 11 ether);
        assertEq(token.allowance(bob, alice), 0);
        assertTrue(second.useGlobalDistributors());
        assertFalse(second.externalLiquidityEnabled());
        assertFalse(second.pairingEnabled());
        assertFalse(second.isLocalDistributor(address(distributor)));
        assertFalse(second.launched());
        assertTrue(token.launched());
        assertEq(second.taxBps(), 500);
        assertEq(second.feeRecipient(), bob);
        vm.prank(bob);
        second.burn(1 ether);
        assertEq(second.totalSupply(), SUPPLY - 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_cloneTransientTransferPermissionsAreIndependent() public {
        ERC20T second = factory.create(_config(address(this), 100, feeWallet));
        _launch(second);
        vm.startPrank(address(hook));
        token.increaseTransferAllowance(1 ether, true);
        token.accountTransferDelta(int128(2 ether));
        second.increaseTransferAllowance(4 ether, false);
        second.accountTransferDelta(-int128(3 ether));
        vm.stopPrank();
        assertEq(token.getTransferAllowance(true), 3 ether);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getNetTransferAllowance(), 2 ether);
        assertEq(second.getTransferAllowance(true), 0);
        assertEq(second.getTransferAllowance(false), 7 ether);
        assertEq(second.getNetTransferAllowance(), -int256(3 ether));
        vm.prank(address(manager));
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        second.transfer(alice, 1 ether);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(manager), 1 ether);
        vm.prank(address(manager));
        token.transfer(alice, 3 ether);
        second.transfer(address(manager), 7 ether);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getNetTransferAllowance(), 0);
        assertEq(second.getTransferAllowance(true), 0);
        assertEq(second.getTransferAllowance(false), 0);
        assertEq(second.getNetTransferAllowance(), 0);
    }

    function _signPermit(ERC20T target, uint256 privateKey, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address signer = vm.addr(privateKey);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                alice,
                value,
                target.nonces(signer),
                deadline
            )
        );
        return vm.sign(privateKey, keccak256(abi.encodePacked(hex"1901", target.DOMAIN_SEPARATOR(), structHash)));
    }

    function test_clonePermitDomainsAndNoncesPreventSignatureReplayAcrossClones() public {
        ERC20T second = factory.create(_config(address(this), 100, feeWallet));
        assertEq(token.name(), second.name());
        assertNotEq(token.DOMAIN_SEPARATOR(), second.DOMAIN_SEPARATOR());
        uint256 signerKey = 0xC10AE;
        address signer = vm.addr(signerKey);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(token, signerKey, 7 ether, deadline);
        vm.expectRevert(ERC20.InvalidPermit.selector);
        second.permit(signer, alice, 7 ether, deadline, v, r, s);
        assertEq(second.nonces(signer), 0);
        assertEq(second.allowance(signer, alice), 0);
        token.permit(signer, alice, 7 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 1);
        assertEq(token.allowance(signer, alice), 7 ether);
        assertEq(second.nonces(signer), 0);
        vm.expectRevert(ERC20.InvalidPermit.selector);
        token.permit(signer, alice, 7 ether, deadline, v, r, s);
        (v, r, s) = _signPermit(second, signerKey, 9 ether, deadline);
        second.permit(signer, alice, 9 ether, deadline, v, r, s);
        assertEq(second.nonces(signer), 1);
        assertEq(second.allowance(signer, alice), 9 ether);
        assertEq(token.nonces(signer), 1);
        assertEq(token.allowance(signer, alice), 7 ether);
    }

    function test_launchLocksReserveAndClosesPermissions() public view {
        assertTrue(token.launched());
        assertTrue(hook.poolInitialized(address(token)));
        assertFalse(token.launching());
        assertTrue(token.useGlobalDistributors());
        assertFalse(token.externalLiquidityEnabled());
        assertFalse(token.pairingEnabled());
        assertEq(token.quoteToken(), address(0));
        assertEq(token.name(), "Taxed Token");
        assertEq(token.symbol(), "TAX");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertLe(token.balanceOf(address(token)), 1);
        assertApproxEqAbs(token.balanceOf(address(manager)), LP_SUPPLY, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - LP_SUPPLY);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager)) + token.balanceOf(address(token)), SUPPLY
        );
        assertEq(IERC20TPositionOwner(address(posm)).ownerOf(1), 0x000000000000000000000000000000000000dEaD);
        assertEq(token.allowance(address(token), PERMIT2_ADDR), 0);
        (uint160 amount,,) = IAllowanceTransfer(PERMIT2_ADDR).allowance(address(token), address(token), address(posm));
        assertEq(amount, 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(key.fee, 0);
        assertEq(key.tickSpacing, ERC20T_TICK_SPACING);
    }

    function test_launchCannotRepeat() public {
        vm.expectRevert(ERC20T.AlreadyLaunched.selector);
        _launch(token);
    }

    function test_creatorAllocationAboveTwentyPercentRejected() public {
        ERC20T.Config memory config = _config(address(this), 100, feeWallet);
        config.lpSupply = LP_SUPPLY - 1;
        vm.expectRevert(ERC20T.InvalidCreatorAllocation.selector);
        factory.create(config);
        config.lpSupply = 0;
        vm.expectRevert(ERC20T.InvalidCreatorAllocation.selector);
        factory.create(config);
    }

    function test_creatorAllocationRoundsCapDownForSmallSupply() public {
        ERC20T.Config memory config = _config(address(this), 100, feeWallet);
        config.supply = 9;
        config.lpSupply = 7;
        vm.expectRevert(ERC20T.InvalidCreatorAllocation.selector);
        factory.create(config);
        config.lpSupply = 8;
        ERC20T fresh = factory.create(config);
        assertEq(fresh.balanceOf(address(this)), 1);
        assertEq(fresh.balanceOf(address(fresh)), 8);
    }

    function test_launchDustStaysLockedAtZeroAndTwentyPercentCreatorAllocation() public {
        for (uint256 creatorSupply; creatorSupply <= 200; creatorSupply += 200) {
            ERC20T.Config memory config = _config(address(this), 100, feeWallet);
            config.supply = 1_000;
            config.lpSupply = config.supply - creatorSupply;
            ERC20T fresh = factory.create(config);
            // A high token/ETH ratio makes the liquidity rounding dust observable.
            fresh.launch(TickMath.getSqrtPriceAtTick(120_000), TickMath.minUsableTick(ERC20T_TICK_SPACING), 120_000);
            assertEq(fresh.balanceOf(address(this)), creatorSupply);
            uint256 dust = fresh.balanceOf(address(fresh));
            assertGt(dust, 0);
            assertEq(fresh.balanceOf(address(manager)) + dust + creatorSupply, config.supply);
            assertEq(fresh.allowance(address(fresh), PERMIT2_ADDR), 0);
        }
    }

    function testFuzz_creatorAllocationMintsExactReserveWithinCap(uint96 rawSupply, uint16 rawBps) public {
        uint256 supply = bound(rawSupply, 1, 1e28);
        uint256 creatorBps = bound(rawBps, 0, 2_000);
        uint256 creatorSupply = supply * creatorBps / 10_000;
        ERC20T.Config memory config = _config(address(this), 100, feeWallet);
        config.supply = supply;
        config.lpSupply = supply - creatorSupply;
        ERC20T fresh = factory.create(config);
        assertEq(fresh.balanceOf(address(this)), creatorSupply);
        assertEq(fresh.balanceOf(address(fresh)), config.lpSupply);
        assertLe(fresh.balanceOf(address(this)), fresh.totalSupply() / 5);
    }

    function test_launchAcceptsZeroEthAndRevokesApprovals() public {
        ERC20T fresh = factory.create(_config(address(this), 100, feeWallet));
        uint256 ownerEthBefore = address(this).balance;
        fresh.launch(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
        assertTrue(fresh.launched());
        assertEq(address(this).balance, ownerEthBefore);
        assertLe(fresh.balanceOf(address(fresh)), 1);
        assertEq(fresh.allowance(address(fresh), PERMIT2_ADDR), 0);
        (uint160 amount,,) = IAllowanceTransfer(PERMIT2_ADDR).allowance(address(fresh), address(fresh), address(posm));
        assertEq(amount, 0);
        assertEq(fresh.getTransferAllowance(false), 0);
        assertEq(fresh.getTransferAllowance(true), 0);
    }

    function test_launchRefundsUnusedNativeBuffer() public {
        ERC20T fresh = factory.create(_config(address(this), 100, feeWallet));
        uint256 ownerEthBefore = address(this).balance;
        fresh.launch{value: 1 ether}(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
        assertEq(address(this).balance, ownerEthBefore);
        assertEq(address(posm).balance, 0);
        assertEq(address(fresh).balance, 0);
    }

    function test_twoTokensShareHookWithIndependentOwnersAndPolicies() public {
        ERC20T second = factory.create(_config(bob, 500, bob));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        second.launch{value: 2}(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
        assertTrue(hook.poolInitialized(address(second)));
        assertEq(second.hook(), token.hook());
        assertEq(second.owner(), bob);
        vm.prank(bob);
        second.setUseGlobalDistributors(false);
        vm.prank(bob);
        second.setExternalLiquidityEnabled(true);
        hook.setDistributors(_accounts(address(distributor)), true);
        token.setTaxBps(200);
        assertEq(second.taxBps(), 500);
        assertEq(token.taxBps(), 200);
        assertTrue(token.isDistributor(address(distributor)));
        assertFalse(second.isDistributor(address(distributor)));
        assertFalse(token.externalLiquidityEnabled());
        assertTrue(second.externalLiquidityEnabled());
        uint256 firstFees = feeWallet.balance;
        _buy(second, alice, 1 ether);
        assertGt(second.balanceOf(alice), 0);
        assertGt(bob.balance, 1 ether);
        assertEq(feeWallet.balance, firstFees);
        _buy(token, alice, 1 ether);
        assertGt(feeWallet.balance, firstFees);
        vm.expectRevert(Ownable.Unauthorized.selector);
        second.setTaxBps(300);
    }

    function test_buyChargesConfiguredOutputTaxAndConvertsToEth() public {
        uint16[6] memory rates = [uint16(30), 100, 200, 300, 400, 500];
        for (uint256 i; i < rates.length; ++i) {
            uint16 rate = rates[i];
            token.setTaxBps(rate);
            uint256 tokensBefore = token.balanceOf(alice);
            uint256 creatorBefore = feeWallet.balance;
            uint256 protocolBefore = protocolWallet.balance;
            vm.recordLogs();
            _buy(token, alice, 1 ether);
            (uint256 tokenFee, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
            uint256 received = token.balanceOf(alice) - tokensBefore;
            assertEq(tokenFee, (received + tokenFee) * rate / 10_000);
            assertGt(creatorEth, 0);
            assertGt(protocolEth, 0);
            assertEq(feeWallet.balance - creatorBefore, creatorEth);
            assertEq(protocolWallet.balance - protocolBefore, protocolEth);
            assertEq(token.balanceOf(address(hook)), 0);
            assertEq(address(hook).balance, 0);
            assertEq(token.getTransferAllowance(false), 0);
            assertEq(token.getTransferAllowance(true), 0);
        }
    }

    function test_sellChargesConfiguredEthOutputTax() public {
        _buy(token, bob, 10 ether);
        token.transfer(alice, 6 ether);
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        uint16[6] memory rates = [uint16(30), 100, 200, 300, 400, 500];
        for (uint256 i; i < rates.length; ++i) {
            uint16 rate = rates[i];
            token.setTaxBps(rate);
            uint256 creatorBefore = feeWallet.balance;
            uint256 protocolBefore = protocolWallet.balance;
            uint256 ethBefore = alice.balance;
            vm.recordLogs();
            _sell(alice, 1 ether);
            (uint256 tokenFee, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
            uint256 received = alice.balance - ethBefore;
            uint256 totalEth = creatorEth + protocolEth;
            assertEq(tokenFee, 0);
            assertGt(received, 0);
            assertEq(totalEth, (received + totalEth) * rate / 10_000);
            assertEq(feeWallet.balance - creatorBefore, creatorEth);
            assertEq(protocolWallet.balance - protocolBefore, protocolEth);
            assertEq(token.getTransferAllowance(false), 0);
            assertEq(token.getTransferAllowance(true), 0);
        }
        assertEq(token.balanceOf(alice), 0);
    }

    function test_feeRecipientCanChangeForBothTradeDirections() public {
        _buy(token, alice, 1 ether);
        uint256 oldFees = feeWallet.balance;
        token.setFeeRecipient(bob);
        _buy(token, alice, 2 ether);
        assertGt(bob.balance, 0);
        uint256 buyFees = bob.balance;
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        _sell(alice, token.balanceOf(alice));
        assertGt(bob.balance, buyFees);
        assertEq(feeWallet.balance, oldFees);
    }

    function test_protocolRecipientRotationAppliesToBuyAndSell() public {
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        (, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
        assertEq(feeWallet.balance, creatorEth);
        assertEq(protocolWallet.balance, protocolEth);
        uint256 oldProtocolFees = protocolWallet.balance;
        hook.setProtocolFeeRecipient(bob);
        uint256 creatorBefore = feeWallet.balance;
        vm.recordLogs();
        _buy(token, alice, 2 ether);
        (, creatorEth, protocolEth) = _feeEvents();
        assertEq(bob.balance, protocolEth);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        uint256 protocolBefore = bob.balance;
        creatorBefore = feeWallet.balance;
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        vm.recordLogs();
        _sell(alice, token.balanceOf(alice));
        (, creatorEth, protocolEth) = _feeEvents();
        assertEq(bob.balance, protocolBefore + protocolEth);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        assertEq(protocolWallet.balance, oldProtocolFees);
        assertEq(address(hook).balance, 0);
    }

    function test_sameProtocolAndCreatorRecipientReceivesOneCombinedPayment() public {
        ERC20TCountingFeeRecipient recipient = new ERC20TCountingFeeRecipient();
        token.setFeeRecipient(address(recipient));
        hook.setProtocolFeeRecipient(address(recipient));
        vm.recordLogs();
        _buy(token, alice, 2 ether);
        (, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
        assertEq(address(recipient).balance, creatorEth + protocolEth);
        assertEq(recipient.calls(), 1);
        uint256 before = address(recipient).balance;
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        vm.recordLogs();
        _sell(alice, token.balanceOf(alice));
        (, creatorEth, protocolEth) = _feeEvents();
        assertEq(address(recipient).balance, before + creatorEth + protocolEth);
        assertEq(recipient.calls(), 2);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_rejectingProtocolRecipientStillReceivesBuyAndSellFees() public {
        ERC20TRejectingFeeRecipient recipient = new ERC20TRejectingFeeRecipient();
        hook.setProtocolFeeRecipient(address(recipient));
        vm.recordLogs();
        _buy(token, alice, 2 ether);
        (, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
        assertGt(protocolEth, 0);
        assertEq(address(recipient).balance, protocolEth);
        assertEq(feeWallet.balance, creatorEth);
        uint256 protocolBefore = address(recipient).balance;
        uint256 creatorBefore = feeWallet.balance;
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        vm.recordLogs();
        _sell(alice, token.balanceOf(alice));
        (, creatorEth, protocolEth) = _feeEvents();
        assertGt(protocolEth, 0);
        assertEq(address(recipient).balance, protocolBefore + protocolEth);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_protocolShareCanRoundToZeroWithoutLosingCollectedEth() public {
        token.setTaxBps(30);
        vm.recordLogs();
        _buy(token, alice, 1_000);
        (uint256 tokenFee, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
        assertGt(tokenFee, 0);
        assertGt(creatorEth, 0);
        assertEq(protocolEth, 0);
        assertEq(feeWallet.balance, creatorEth);
        assertEq(protocolWallet.balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_roundedZeroTaxSkipsBothFeeEventsAndPayouts() public {
        ERC20TCountingFeeRecipient recipient = new ERC20TCountingFeeRecipient();
        token.setFeeRecipient(address(recipient));
        hook.setProtocolFeeRecipient(address(recipient));
        token.setTaxBps(30);
        vm.recordLogs();
        _buy(token, alice, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook)) {
                assertNotEq(logs[i].topics[0], FEE_EVENT);
                assertNotEq(logs[i].topics[0], PROTOCOL_FEE_EVENT);
                assertNotEq(logs[i].topics[0], DECAY_FEE_EVENT);
            }
        }
        assertGt(token.balanceOf(alice), 0);
        assertEq(address(recipient).balance, 0);
        assertEq(recipient.calls(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_rejectingFeeRecipientStillReceivesBuyAndSellFees() public {
        ERC20TRejectingFeeRecipient recipient = new ERC20TRejectingFeeRecipient();
        token.setFeeRecipient(address(recipient));
        _buy(token, alice, 2 ether);
        uint256 buyFees = address(recipient).balance;
        assertGt(buyFees, 0);
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        _sell(alice, token.balanceOf(alice));
        assertGt(address(recipient).balance, buyFees);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_feeRecipientCannotReenterTaxedSwap() public {
        ERC20TReentrantFeeRecipient recipient = new ERC20TReentrantFeeRecipient(manager, key);
        token.setFeeRecipient(address(recipient));
        _buy(token, alice, 2 ether);
        assertTrue(recipient.attempted());
        assertFalse(recipient.succeeded());
        assertEq(
            recipient.failureHash(),
            keccak256(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            )
        );
        assertGt(address(recipient).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
    }

    function testFuzz_validTaxSettlesBuyAndSellWithoutStrandedBalances(uint16 rawRate, uint96 rawEthIn) public {
        uint16 rate = uint16(bound(rawRate, 30, 500));
        uint256 ethIn = bound(rawEthIn, 0.01 ether, 10 ether);
        token.setTaxBps(rate);
        uint256 creatorBefore = feeWallet.balance;
        uint256 protocolBefore = protocolWallet.balance;
        vm.recordLogs();
        _buy(token, alice, ethIn);
        (uint256 tokenFee, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
        assertGt(creatorEth, 0);
        assertGt(protocolEth, 0);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        assertEq(protocolWallet.balance, protocolBefore + protocolEth);
        uint256 bought = token.balanceOf(alice);
        assertEq(tokenFee, (bought + tokenFee) * rate / 10_000);
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        uint256 ethBefore = alice.balance;
        creatorBefore = feeWallet.balance;
        protocolBefore = protocolWallet.balance;
        vm.recordLogs();
        _sell(alice, bought);
        (, creatorEth, protocolEth) = _feeEvents();
        assertGt(creatorEth, 0);
        assertGt(protocolEth, 0);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        assertEq(protocolWallet.balance, protocolBefore + protocolEth);
        uint256 received = alice.balance - ethBefore;
        uint256 totalEth = creatorEth + protocolEth;
        assertEq(totalEth, (received + totalEth) * rate / 10_000);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_minimumTaxSplitsEquallyOnBuyAndSellAndCanBeRaised() public {
        token.setTaxBps(30);
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        (, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
        assertGt(creatorEth, 0);
        assertApproxEqAbs(creatorEth, protocolEth, 1);
        assertEq(feeWallet.balance, creatorEth);
        assertEq(protocolWallet.balance, protocolEth);
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        uint256 creatorBefore = feeWallet.balance;
        uint256 protocolBefore = protocolWallet.balance;
        vm.recordLogs();
        _sell(alice, token.balanceOf(alice));
        (, creatorEth, protocolEth) = _feeEvents();
        assertGt(creatorEth, 0);
        assertApproxEqAbs(creatorEth, protocolEth, 1);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        assertEq(protocolWallet.balance, protocolBefore + protocolEth);
        assertEq(token.balanceOf(alice), 0);

        token.setTaxBps(500);
        creatorBefore = feeWallet.balance;
        protocolBefore = protocolWallet.balance;
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        (, creatorEth, protocolEth) = _feeEvents();
        assertGt(creatorEth, protocolEth);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        assertEq(protocolWallet.balance, protocolBefore + protocolEth);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_initializerAndSetterAcceptThirtyThroughFiveHundredBasisPoints() public {
        uint16[6] memory valid = [uint16(30), 31, 99, 100, 123, 500];
        for (uint256 i; i < valid.length; ++i) {
            ERC20T deployed = factory.create(_config(address(this), valid[i], feeWallet));
            assertEq(deployed.taxBps(), valid[i]);
            token.setTaxBps(valid[i]);
            assertEq(token.taxBps(), valid[i]);
        }
    }

    function test_taxBoundsRejectBelowThirtyAndAboveFiveHundredBasisPoints() public {
        uint16[5] memory invalid = [uint16(0), 1, 29, 501, type(uint16).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ERC20T.InvalidTax.selector);
            token.setTaxBps(invalid[i]);
            ERC20T.Config memory config = _config(address(this), invalid[i], feeWallet);
            vm.expectRevert(ERC20T.InvalidTax.selector);
            factory.create(config);
        }
        token.setTaxBps(123);
        assertEq(token.taxBps(), 123);
    }

    function test_allTokenConfigurationIsOwnerOnly() public {
        address[] memory accounts = _accounts(address(distributor));
        vm.startPrank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setTaxBps(500);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setTaxBps(30);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setFeeRecipient(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setExternalLiquidityEnabled(true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setPairingEnabled(true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setUseGlobalDistributors(false);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setDistributors(accounts, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setDistributors(accounts, true);
        vm.stopPrank();
    }

    function test_invalidFeeDestinationsRejected() public {
        address[4] memory invalid = [address(0), address(token), address(hook), address(manager)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ERC20T.InvalidAddress.selector);
            token.setFeeRecipient(invalid[i]);
        }
    }

    function test_protocolFeeRecipientIsControlledOnlyByHookOwner() public {
        assertEq(hook.protocolFeeRecipient(), protocolWallet);
        address[3] memory invalid = [address(0), address(hook), address(manager)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ERC20THook.InvalidAddress.selector);
            hook.setProtocolFeeRecipient(invalid[i]);
        }
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setProtocolFeeRecipient(alice);
        hook.transferOwnership(bob);
        // Owning the token does not retain control of the hook's shared destination.
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setProtocolFeeRecipient(alice);
        vm.prank(bob);
        hook.setProtocolFeeRecipient(alice);
        assertEq(hook.protocolFeeRecipient(), alice);
        assertEq(token.feeRecipient(), feeWallet);
        assertEq(token.owner(), address(this));
    }

    function test_batchLocalDistributorsCanReceiveAndDistributeThenBeRevoked() public {
        address[] memory accounts = new address[](2);
        accounts[0] = address(distributor);
        accounts[1] = address(otherDistributor);
        token.setDistributors(accounts, true);
        token.transfer(alice, 3 ether);
        vm.prank(alice);
        token.transfer(address(distributor), 1 ether);
        distributor.send(token, bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
        assertTrue(token.isLocalDistributor(address(otherDistributor)));
        token.setDistributors(accounts, false);
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(distributor), 1 ether);
    }

    function test_sharedDistributorsDefaultOnOptOutAndLocalOverride() public {
        hook.setDistributors(_accounts(address(distributor)), true);
        token.transfer(alice, 3 ether);
        vm.prank(alice);
        token.transfer(address(distributor), 1 ether);
        distributor.send(token, bob, 1 ether);
        token.setUseGlobalDistributors(false);
        assertFalse(token.isDistributor(address(distributor)));
        vm.prank(alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(distributor), 1 ether);
        token.setDistributors(_accounts(address(distributor)), true);
        assertTrue(token.isDistributor(address(distributor)));
        vm.prank(alice);
        token.transfer(address(distributor), 1 ether);
        token.setDistributors(_accounts(address(distributor)), false);
        token.setUseGlobalDistributors(true);
        assertTrue(token.isDistributor(address(distributor)));
        hook.setDistributors(_accounts(address(distributor)), false);
        assertFalse(token.isDistributor(address(distributor)));
    }

    function test_distributorListsRejectEoasAndReservedEndpointsAtomically() public {
        address[5] memory invalid = [alice, address(0), address(token), address(hook), address(manager)];
        for (uint256 i; i < invalid.length; ++i) {
            address[] memory local = _accounts(invalid[i]);
            vm.expectRevert(ERC20T.InvalidAddress.selector);
            token.setDistributors(local, true);
        }
        address[4] memory globalInvalid = [alice, address(0), address(hook), address(manager)];
        for (uint256 i; i < globalInvalid.length; ++i) {
            address[] memory global = _accounts(globalInvalid[i]);
            vm.expectRevert(ERC20THook.InvalidAddress.selector);
            hook.setDistributors(global, true);
        }
        address[] memory mixed = new address[](2);
        mixed[0] = address(distributor);
        mixed[1] = alice;
        vm.expectRevert(ERC20T.InvalidAddress.selector);
        token.setDistributors(mixed, true);
        assertFalse(token.isLocalDistributor(address(distributor)));
        vm.expectRevert(ERC20THook.InvalidAddress.selector);
        hook.setDistributors(mixed, true);
        assertFalse(hook.isDistributor(address(distributor)));
    }

    function test_directEoaWalletTransfersAreUntaxed() public {
        token.transfer(alice, 3 ether);
        token.setTaxBps(500);
        uint256 creatorBefore = feeWallet.balance;
        uint256 protocolBefore = protocolWallet.balance;
        uint256 managerBefore = token.balanceOf(address(manager));
        vm.recordLogs();
        vm.prank(alice, alice);
        token.transfer(bob, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(hook));
        }
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(feeWallet.balance, creatorBefore);
        assertEq(protocolWallet.balance, protocolBefore);
        assertEq(token.balanceOf(address(manager)), managerBefore);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_buyerCanGiftFullTokensToWalletThatThenSellsWithTax() public {
        vm.recordLogs();
        _buy(token, alice, 1 ether);
        (, uint256 creatorEth, uint256 protocolEth) = _feeEvents();
        assertGt(creatorEth, 0);
        assertGt(protocolEth, 0);
        uint256 bought = token.balanceOf(alice);
        uint256 creatorBefore = feeWallet.balance;
        uint256 protocolBefore = protocolWallet.balance;
        vm.recordLogs();
        vm.prank(alice, alice);
        token.transfer(bob, bought);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(hook));
        }
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), bought);
        assertEq(feeWallet.balance, creatorBefore);
        assertEq(protocolWallet.balance, protocolBefore);

        vm.prank(bob, bob);
        token.approve(address(swapRouter), bought);
        uint256 bobEthBefore = bob.balance;
        vm.recordLogs();
        _sell(bob, bought);
        (, creatorEth, protocolEth) = _feeEvents();
        assertGt(bob.balance, bobEthBefore);
        assertGt(creatorEth, 0);
        assertGt(protocolEth, 0);
        assertEq(feeWallet.balance, creatorBefore + creatorEth);
        assertEq(protocolWallet.balance, protocolBefore + protocolEth);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(bob, address(swapRouter)), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_thirdPartyTransferFromNeedsExemptEndpointEvenForDistributorCaller() public {
        token.transfer(alice, 3 ether);
        address spender = makeAddr("thirdPartySpender");
        vm.startPrank(alice, alice);
        token.approve(spender, 1 ether);
        token.approve(address(distributor), type(uint256).max);
        vm.stopPrank();
        vm.prank(spender, spender);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, spender), 1 ether);
        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 0);
        // Approving the spender as a distributor does not make arbitrary wallet endpoints valid.
        token.setDistributors(_accounts(address(distributor)), true);
        vm.prank(alice, alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        distributor.pull(token, alice, bob, 1 ether);
        distributor.pull(token, alice, address(distributor), 1 ether);
        distributor.send(token, bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
        vm.prank(alice, alice);
        token.transfer(address(this), 1 ether);
    }

    function test_directWalletExceptionRejectsUnapprovedContractEndpoints() public {
        token.transfer(alice, 1 ether);
        token.transfer(address(otherDistributor), 1 ether);
        assertFalse(token.isDistributor(address(otherDistributor)));
        vm.prank(alice, alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(otherDistributor), 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        otherDistributor.send(token, bob, 1 ether);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(otherDistributor)), 1 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_constructorSenderCannotUseDirectWalletExceptionWhileCodeIsEmpty() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        token.transfer(predicted, 1 ether);
        vm.prank(address(this), alice);
        ERC20TConstructorSender sender = new ERC20TConstructorSender(token, bob, 1 ether);
        assertEq(address(sender), predicted);
        assertEq(sender.codeLengthDuringConstruction(), 0);
        assertEq(sender.transactionOrigin(), alice);
        assertFalse(sender.succeeded());
        assertEq(sender.failureHash(), keccak256(abi.encodeWithSelector(ERC20T.InvalidTransfer.selector)));
        assertGt(address(sender).code.length, 0);
        assertEq(token.balanceOf(address(sender)), 1 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_eip7702DelegationCodeStateRejectsEitherWalletEndpoint() public {
        token.transfer(alice, 1 ether);
        // Code-state regression only: installing the designation does not simulate authorization processing.
        bytes memory designation = abi.encodePacked(hex"ef0100", address(otherDistributor));
        vm.etch(alice, designation);
        assertEq(alice.code.length, 23);
        vm.prank(alice, alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(bob, 1 ether);
        vm.etch(alice, "");
        vm.etch(bob, designation);
        assertEq(bob.code.length, 23);
        vm.prank(alice, alice);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(bob, 1 ether);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_managerCapTakesPriorityOverOwnerAndDistributorExemptions() public {
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(manager), 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(this), 1 ether);
        token.setDistributors(_accounts(address(distributor)), true);
        token.transfer(address(distributor), 1 ether);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        distributor.send(token, address(manager), 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(distributor), 1 ether);
    }

    function test_onlyHookCanGrantDirectionalExactTransferAllowances() public {
        vm.expectRevert(ERC20T.OnlyHook.selector);
        token.increaseTransferAllowance(2 ether, true);
        vm.prank(address(hook));
        token.increaseTransferAllowance(2 ether, true);
        assertEq(token.getTransferAllowance(true), 2 ether);
        assertEq(token.getTransferAllowance(false), 0);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(manager), 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(alice, 2 ether + 1);
        vm.prank(address(manager));
        token.transfer(alice, 2 ether);
        assertEq(token.getTransferAllowance(true), 0);
        vm.prank(address(hook));
        token.increaseTransferAllowance(1 ether, false);
        vm.prank(address(manager));
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(alice, 1 ether);
        token.transfer(address(manager), 1 ether);
        assertEq(token.getTransferAllowance(false), 0);
    }

    function test_onlyHookCanAccountAndNetSettlementDeltas() public {
        vm.expectRevert(ERC20T.OnlyHook.selector);
        token.accountTransferDelta(int128(2 ether));
        vm.prank(address(hook));
        token.accountTransferDelta(int128(2 ether));
        assertEq(token.getNetTransferAllowance(), 2 ether);
        assertEq(token.getTransferAllowance(true), 2 ether);
        assertEq(token.getTransferAllowance(false), 0);

        vm.prank(address(hook));
        token.increaseTransferAllowance(1 ether, true);
        vm.prank(address(manager));
        token.transfer(alice, 2 ether);
        // Immediate fee authorizations are spent before net user settlement permissions.
        assertEq(token.getNetTransferAllowance(), 1 ether);
        assertEq(token.getTransferAllowance(true), 1 ether);

        vm.prank(address(hook));
        token.accountTransferDelta(-int128(2 ether));
        assertEq(token.getNetTransferAllowance(), -int256(1 ether));
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getTransferAllowance(false), 1 ether);
        token.transfer(address(manager), 1 ether);
        assertEq(token.getNetTransferAllowance(), 0);
        assertEq(token.getTransferAllowance(false), 0);
    }

    function test_externalLiquidityDisabledEnabledThenWithdrawableAfterDisabled() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        token.setExternalLiquidityEnabled(true);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(token.getTransferAllowance(false), 0);
        token.setExternalLiquidityEnabled(false);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        uint256 before = token.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertGt(token.balanceOf(address(this)), before);
        assertEq(token.getTransferAllowance(true), 0);
    }

    function test_exactOutputBuyAndSellRevert() public {
        _buy(token, alice, 5 ether);
        uint256 creatorBefore = feeWallet.balance;
        uint256 protocolBefore = protocolWallet.balance;
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 0.1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: 0.1 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertEq(feeWallet.balance, creatorBefore);
        assertEq(protocolWallet.balance, protocolBefore);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_launchCannotBeSquattedAndRejectsWrongKeys() public {
        ERC20T fresh = factory.create(_config(address(this), 100, feeWallet));
        PoolKey memory freshKey = fresh.poolKey();
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(freshKey, SQRT_PRICE_1_1);
        assertFalse(hook.poolInitialized(address(fresh)));
        freshKey.fee = 3000;
        vm.expectRevert();
        manager.initialize(freshKey, SQRT_PRICE_1_1);
        freshKey.fee = 0;
        freshKey.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(freshKey, SQRT_PRICE_1_1);
        _launch(fresh);
        assertTrue(hook.poolInitialized(address(fresh)));
    }

    function test_sidePoolCannotBeFundedWithDirectTokenTransfers() public {
        PoolKey memory sideKey = key;
        sideKey.hooks = IHooks(address(0));
        manager.initialize(sideKey, SQRT_PRICE_1_1);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(sideKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    /// @dev Deliberately records the limitation of the FWA-compatible transfer-guard design:
    /// ERC-6909 claims move and settle inside v4 without calling ERC20 transfer guards.
    function test_documentedLimitation_claimsCanFundAndTradeAnUnhookedPool() public {
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint256 tokenId = uint256(uint160(address(token)));
        assertGt(manager.balanceOf(alice, tokenId), 0);
        assertEq(token.balanceOf(alice), 0);
        uint256 feesAfterCanonicalBuy = feeWallet.balance;

        vm.prank(alice);
        manager.transfer(bob, tokenId, 1);
        assertEq(manager.balanceOf(bob, tokenId), 1);
        vm.prank(alice);
        claimsRouter.deposit{value: 1 ether}(Currency.wrap(address(0)), alice, 1 ether);
        vm.startPrank(alice);
        manager.setOperator(address(modifyLiquidityRouter), true);
        manager.setOperator(address(swapRouter), true);
        vm.stopPrank();

        PoolKey memory sideKey = key;
        sideKey.hooks = IHooks(address(0));
        manager.initialize(sideKey, SQRT_PRICE_1_1);
        vm.prank(alice);
        modifyLiquidityRouter.modifyLiquidity(sideKey, LIQUIDITY_PARAMS, ZERO_BYTES, true, true);
        uint256 claimsBefore = manager.balanceOf(alice, tokenId);
        vm.prank(alice);
        swapRouter.swap(
            sideKey,
            SwapParams({zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: true}),
            ZERO_BYTES
        );
        assertGt(manager.balanceOf(alice, tokenId), claimsBefore);
        assertEq(feeWallet.balance, feesAfterCanonicalBuy);
        assertEq(token.balanceOf(alice), 0);
    }
}
