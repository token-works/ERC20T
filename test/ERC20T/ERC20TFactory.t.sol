// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20T_TICK_SPACING} from "../../src/ERC20T/ERC20TInterfaces.sol";
import {TokenPosmHelper} from "../support/TokenPosmHelper.sol";

interface IERC20TFactoryPositionOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract ERC20TFactoryRejectingPayer {
    function create(ERC20TFactory factory, ERC20T.Config calldata config, uint160 sqrtPriceX96, int24 tickLower)
        external
        payable
        returns (ERC20T token)
    {
        return factory.createAndLaunch{value: msg.value}(config, sqrtPriceX96, tickLower, 0);
    }

    receive() external payable {
        revert("refund callback rejected");
    }
}

/// @notice A real v4 launch, token distribution and ownership handover in one factory call.
contract ERC20TFactoryTest is Deployers, TokenPosmHelper {
    using StateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LP_SUPPLY = 800_000_000 ether;

    ERC20TFactory factory;
    ERC20THook hook;
    address tokenOwner = makeAddr("tokenOwner");
    address creator = makeAddr("creator");
    address feeWallet = makeAddr("feeWallet");
    address decayWallet = makeAddr("decayWallet");
    address protocolWallet = makeAddr("protocolWallet");

    event TokenLaunched(address indexed token, address indexed owner, address indexed creator, address hook);

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
        factory = new ERC20TFactory();
        vm.deal(creator, 10 ether);
        vm.deal(address(this), 10 ether);
    }

    function _config(address owner) internal view returns (ERC20T.Config memory) {
        return ERC20T.Config({
            name: "Factory Token",
            symbol: "FACT",
            supply: SUPPLY,
            lpSupply: LP_SUPPLY,
            owner: owner,
            hook: address(hook),
            quoteToken: address(0),
            positionManager: posm,
            permit2: IAllowanceTransfer(PERMIT2_ADDR),
            taxBps: 321,
            feeRecipient: feeWallet,
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0,
            feeDecayRecipient: address(0)
        });
    }

    function _create(ERC20T.Config memory config, uint256 value) internal returns (ERC20T token) {
        return
            factory.createAndLaunch{value: value}(
                config, SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0
            );
    }

    function _assertCompleted(ERC20T token, address intendedOwner) internal view {
        assertTrue(token.launched());
        assertFalse(token.launching());
        assertTrue(hook.poolInitialized(address(token)));
        assertEq(token.owner(), intendedOwner);
        assertEq(token.totalSupply(), SUPPLY);
        assertApproxEqAbs(token.balanceOf(address(manager)), LP_SUPPLY, 1);
        assertEq(token.balanceOf(intendedOwner), SUPPLY - LP_SUPPLY);
        assertEq(
            token.balanceOf(intendedOwner) + token.balanceOf(address(manager)) + token.balanceOf(address(token)), SUPPLY
        );
        assertEq(token.balanceOf(address(factory)), 0);
        assertLe(token.balanceOf(address(token)), 1);
        assertEq(address(token).balance, 0);
        assertEq(address(posm).balance, 0);
        assertEq(token.allowance(address(token), PERMIT2_ADDR), 0);
        (uint160 approval,,) = IAllowanceTransfer(PERMIT2_ADDR).allowance(address(token), address(token), address(posm));
        assertEq(approval, 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
    }

    function test_factoryCreatesInitializedUnlaunchedCloneWithFixedArguments() public {
        ERC20T.Config memory config = _config(tokenOwner);
        address implementation = factory.implementation();
        assertGt(implementation.code.length, 145);
        address predicted = vm.computeCreateAddress(address(factory), 2);
        vm.prank(creator);
        ERC20T token = factory.create(config);
        bytes memory args = abi.encodePacked(address(hook), address(0), address(manager), address(posm), PERMIT2_ADDR);
        bytes memory expectedCode =
            abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3", args);
        assertEq(address(token), predicted);
        assertEq(address(token).code.length, 145);
        assertEq(address(token).code, expectedCode);
        assertEq(token.hook(), address(hook));
        assertEq(token.quoteToken(), address(0));
        assertEq(address(token.poolManager()), address(manager));
        assertEq(address(token.positionManager()), address(posm));
        assertEq(address(token.permit2()), PERMIT2_ADDR);
        assertEq(token.owner(), tokenOwner);
        assertEq(token.name(), config.name);
        assertEq(token.symbol(), config.symbol);
        assertEq(token.taxBps(), config.taxBps);
        assertEq(token.feeRecipient(), feeWallet);
        assertEq(token.feeDecayRecipient(), feeWallet);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(token)), LP_SUPPLY);
        assertEq(token.balanceOf(tokenOwner), SUPPLY - LP_SUPPLY);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(creator), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.allowance(address(token), PERMIT2_ADDR), 0);
        assertTrue(token.useGlobalDistributors());
        assertFalse(token.externalLiquidityEnabled());
        assertFalse(token.pairingEnabled());
        assertFalse(token.launched());
        assertFalse(token.launching());
        assertFalse(hook.poolInitialized(address(token)));
        assertEq(posm.nextTokenId(), 1);

        config.quoteToken = address(token);
        ERC20T quoted = factory.create(config);
        assertEq(factory.implementation(), implementation);
        assertEq(address(quoted).code.length, 145);
        assertEq(quoted.quoteToken(), address(token));
        assertEq(token.quoteToken(), address(0));
        assertEq(ERC20T(implementation).totalSupply(), 0);
    }

    function test_factoryDeploysLaunchesAndHandsOverToIndependentOwner() public {
        ERC20T.Config memory config = _config(tokenOwner);
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, true, true, address(factory));
        emit TokenLaunched(predicted, tokenOwner, creator, address(hook));
        vm.prank(creator);
        ERC20T token = _create(config, 0);

        assertEq(address(token), predicted);
        _assertCompleted(token, tokenOwner);
        assertEq(token.balanceOf(creator), 0);
        assertEq(address(factory).balance, 0);
        assertEq(IERC20TFactoryPositionOwner(address(posm)).ownerOf(1), 0x000000000000000000000000000000000000dEaD);
        // No registry or special hook approval is necessary for the factory.
        assertFalse(hook.isDistributor(address(factory)));
        assertEq(token.hook(), address(hook));
        assertEq(address(token.poolManager()), address(manager));
        assertEq(address(token.positionManager()), address(posm));
        assertEq(token.name(), config.name);
        assertEq(token.symbol(), config.symbol);
        assertEq(token.taxBps(), config.taxBps);
        assertEq(token.feeRecipient(), config.feeRecipient);
        assertEq(token.feeDecayRecipient(), config.feeRecipient);
        assertTrue(token.useGlobalDistributors());
        assertFalse(token.externalLiquidityEnabled());
        assertFalse(token.isLocalDistributor(address(factory)));

        vm.prank(address(factory));
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setTaxBps(100);
        vm.prank(creator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.setFeeRecipient(creator);
        vm.prank(tokenOwner);
        token.setTaxBps(500);
        vm.prank(tokenOwner);
        token.setFeeRecipient(tokenOwner);
        assertEq(token.taxBps(), 500);
        assertEq(token.feeRecipient(), tokenOwner);
        assertEq(token.feeDecayRecipient(), feeWallet);
    }

    function test_factorySupportsCallerAsFinalOwner() public {
        ERC20T.Config memory config = _config(creator);
        vm.prank(creator);
        ERC20T token = _create(config, 0);
        _assertCompleted(token, creator);
        assertEq(creator.balance, 10 ether);
        assertEq(address(factory).balance, 0);
    }

    function test_factoryLaunchPreservesTaxDecayAndStartsClockAtLaunch() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.taxBps = 30;
        config.feeDecayRecipient = decayWallet;
        config.launchTaxBps = 9_900;
        config.taxDecayIntervalSeconds = 60;
        vm.warp(10_000);
        vm.prank(creator);
        ERC20T token = _create(config, 0);

        _assertCompleted(token, tokenOwner);
        assertEq(token.feeRecipient(), feeWallet);
        assertEq(token.feeDecayRecipient(), decayWallet);
        assertEq(token.restingTaxBps(), 30);
        assertEq(token.launchTaxBps(), 9_900);
        assertEq(token.taxDecayIntervalSeconds(), 60);
        assertEq(token.launchedAt(), 10_000);
        assertEq(token.taxBps(), 9_900);
        vm.warp(10_059);
        assertEq(token.taxBps(), 9_900);
        vm.warp(10_060);
        assertEq(token.taxBps(), 9_800);
        vm.warp(15_939);
        assertEq(token.taxBps(), 100);
        vm.warp(15_940);
        assertEq(token.taxBps(), 30);
        vm.warp(20_000);
        assertEq(token.taxBps(), 30);
        assertEq(token.launchedAt(), 10_000);
    }

    function test_factoryCreateThenOwnerLaunchStartsTradingAndTaxClockLater() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.taxBps = 30;
        config.feeDecayRecipient = decayWallet;
        config.launchTaxBps = 9_900;
        config.taxDecayIntervalSeconds = 60;
        vm.prank(creator);
        ERC20T token = factory.create(config);
        assertEq(token.owner(), tokenOwner);
        assertEq(token.feeRecipient(), feeWallet);
        assertEq(token.feeDecayRecipient(), decayWallet);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(tokenOwner), SUPPLY - LP_SUPPLY);
        assertEq(token.balanceOf(address(token)), LP_SUPPLY);
        assertEq(token.balanceOf(address(factory)), 0);
        assertFalse(token.launched());
        assertFalse(hook.poolInitialized(address(token)));
        assertEq(token.launchedAt(), 0);
        assertEq(posm.nextTokenId(), 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(token.taxBps(), 9_900);
        assertFalse(token.taxDecayActive());
        int24 lower = TickMath.minUsableTick(ERC20T_TICK_SPACING);
        vm.prank(creator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.launch(SQRT_PRICE_1_1, lower, 0);
        assertEq(token.launchedAt(), 0);
        vm.prank(tokenOwner);
        token.launch(SQRT_PRICE_1_1, lower, 0);
        _assertCompleted(token, tokenOwner);
        uint256 launchTime = token.launchedAt();
        assertEq(launchTime, vm.getBlockTimestamp());
        assertEq(token.taxBps(), 9_900);
        assertTrue(token.taxDecayActive());

        PoolKey memory poolKey = token.poolKey();
        vm.deal(address(manager), 100 ether);
        vm.prank(creator);
        swapRouter.swap{value: 1 ether}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertGt(token.balanceOf(creator), 0);
        assertLt(token.balanceOf(creator), 0.011 ether);
        assertGt(feeWallet.balance, 0);
        assertGt(decayWallet.balance, 0);
        assertGt(protocolWallet.balance, 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
        vm.warp(launchTime + 59);
        assertEq(token.taxBps(), 9_900);
        vm.warp(launchTime + 60);
        assertEq(token.taxBps(), 9_800);
        vm.warp(launchTime + 99 * 60 - 1);
        assertEq(token.taxBps(), 100);
        vm.warp(launchTime + 99 * 60);
        assertEq(token.taxBps(), 30);
        assertFalse(token.taxDecayActive());
    }

    function test_factoryPriceLaunchPreservesTaxDecayConfiguration() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.taxBps = 75;
        config.feeDecayRecipient = decayWallet;
        config.launchTaxBps = 9_900;
        config.taxDecayIntervalSeconds = 7;
        vm.warp(30_000);
        vm.prank(creator);
        ERC20T token = factory.createAndLaunchAtPrice(config, 2_000, 1 ether);

        _assertCompleted(token, tokenOwner);
        assertEq(token.feeRecipient(), feeWallet);
        assertEq(token.feeDecayRecipient(), decayWallet);
        assertEq(token.restingTaxBps(), 75);
        assertEq(token.launchTaxBps(), 9_900);
        assertEq(token.taxDecayIntervalSeconds(), 7);
        assertEq(token.launchedAt(), 30_000);
        assertEq(token.taxBps(), 9_900);
        vm.warp(30_006);
        assertEq(token.taxBps(), 9_900);
        vm.warp(30_007);
        assertEq(token.taxBps(), 9_800);
        vm.warp(30_014);
        assertEq(token.taxBps(), 9_700);
        vm.warp(30_692);
        assertEq(token.taxBps(), 100);
        vm.warp(30_693);
        assertEq(token.taxBps(), 75);
    }

    function test_factoryRefundsExtraEthToCallerRatherThanTokenOwner() public {
        ERC20T.Config memory config = _config(tokenOwner);
        uint256 ownerEthBefore = tokenOwner.balance;
        vm.prank(creator);
        ERC20T token = _create(config, 2 ether);
        _assertCompleted(token, tokenOwner);
        assertEq(creator.balance, 10 ether);
        assertEq(tokenOwner.balance, ownerEthBefore);
        assertEq(address(factory).balance, 0);
    }

    function test_factoryForcesRefundWhenPayerRejectsEthCallbacks() public {
        ERC20TFactoryRejectingPayer payer = new ERC20TFactoryRejectingPayer();
        ERC20T token = payer.create{value: 2 ether}(
            factory, _config(tokenOwner), SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING)
        );
        _assertCompleted(token, tokenOwner);
        assertEq(address(payer).balance, 2 ether);
        assertEq(address(factory).balance, 0);
        assertEq(tokenOwner.balance, 0);
    }

    function test_factoryRefundDoesNotSweepPreexistingBalance() public {
        vm.deal(address(factory), 7 ether);
        ERC20T.Config memory config = _config(tokenOwner);
        vm.prank(creator);
        ERC20T token = _create(config, 2 ether);
        _assertCompleted(token, tokenOwner);
        assertEq(creator.balance, 10 ether);
        assertEq(address(factory).balance, 7 ether);
        vm.prank(creator);
        _create(config, 0);
        assertEq(creator.balance, 10 ether);
        assertEq(address(factory).balance, 7 ether);
    }

    function test_factoryInvalidLaunchRevertsDeploymentDistributionAndPaymentAtomically() public {
        ERC20T.Config memory config = _config(tokenOwner);
        uint64 nonceBefore = vm.getNonce(address(factory));
        address predicted = vm.computeCreateAddress(address(factory), nonceBefore);
        vm.deal(address(factory), 7 ether);
        vm.prank(creator);
        vm.expectRevert(ERC20T.InvalidRange.selector);
        factory.createAndLaunch{value: 1 ether}(config, SQRT_PRICE_1_1, 0, ERC20T_TICK_SPACING);
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertFalse(hook.poolInitialized(predicted));
        assertEq(posm.nextTokenId(), 1);
        assertEq(address(factory).balance, 7 ether);
        assertEq(creator.balance, 10 ether);
        assertEq(tokenOwner.balance, 0);
        vm.prank(creator);
        ERC20T token = _create(config, 0);
        assertEq(address(token), predicted);
        _assertCompleted(token, tokenOwner);
    }

    function test_factoryRejectsZeroAndFactoryFinalOwners() public {
        ERC20T.Config memory config = _config(address(0));
        vm.expectRevert(ERC20TFactory.InvalidOwner.selector);
        _create(config, 0);
        config.owner = address(factory);
        vm.expectRevert(ERC20TFactory.InvalidOwner.selector);
        _create(config, 0);
        assertEq(vm.getNonce(address(factory)), 2);
        assertEq(posm.nextTokenId(), 1);
    }

    function test_factoryRejectsInvalidTaxWithoutKeepingFundsOrDeployment() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.taxBps = 501;
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.prank(creator);
        vm.expectRevert(ERC20T.InvalidTax.selector);
        _create(config, 1 ether);
        assertEq(predicted.code.length, 0);
        assertEq(address(factory).balance, 0);
        assertEq(creator.balance, 10 ether);
        assertEq(posm.nextTokenId(), 1);

        config.taxBps = 321;
        config.launchTaxBps = 500;
        config.taxDecayIntervalSeconds = 60;
        vm.prank(creator);
        vm.expectRevert(ERC20T.InvalidTaxDecayConfiguration.selector);
        _create(config, 1 ether);
        assertEq(predicted.code.length, 0);
        assertEq(address(factory).balance, 0);
        assertEq(creator.balance, 10 ether);
        assertEq(posm.nextTokenId(), 1);
    }

    function test_factoryAcceptsMinimumTax() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.taxBps = 30;
        vm.prank(creator);
        ERC20T token = _create(config, 0);
        _assertCompleted(token, tokenOwner);
        assertEq(token.taxBps(), 30);
        vm.prank(tokenOwner);
        token.setTaxBps(500);
        assertEq(token.taxBps(), 500);
    }

    function test_factoryRejectsFeesDirectedToFactory() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.feeRecipient = address(factory);
        vm.expectRevert(ERC20TFactory.InvalidFeeRecipient.selector);
        _create(config, 0);

        config.feeRecipient = feeWallet;
        config.feeDecayRecipient = address(factory);
        vm.expectRevert(ERC20TFactory.InvalidFeeRecipient.selector);
        _create(config, 0);
        vm.expectRevert(ERC20TFactory.InvalidFeeRecipient.selector);
        factory.create(config);
        vm.expectRevert(ERC20TFactory.InvalidFeeRecipient.selector);
        factory.createAndLaunchAtPrice(config, 2_000, 1 ether);
        assertEq(vm.getNonce(address(factory)), 2);
        assertEq(posm.nextTokenId(), 1);
    }

    function test_factoryRejectsKeepingEntireSupply() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.lpSupply = 0;
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectRevert(ERC20T.InvalidCreatorAllocation.selector);
        _create(config, 0);
        assertEq(predicted.code.length, 0);
        assertEq(address(factory).balance, 0);
        assertEq(posm.nextTokenId(), 1);
    }

    function test_factorySupportsAllocatingEntireSupplyToLockedLiquidity() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.lpSupply = SUPPLY;
        ERC20T token = _create(config, 0);
        assertEq(token.owner(), tokenOwner);
        assertApproxEqAbs(token.balanceOf(address(manager)), SUPPLY, 1);
        assertEq(token.balanceOf(tokenOwner), 0);
        assertEq(
            token.balanceOf(tokenOwner) + token.balanceOf(address(manager)) + token.balanceOf(address(token)), SUPPLY
        );
        assertEq(token.balanceOf(address(factory)), 0);
        assertLe(token.balanceOf(address(token)), 1);
        assertEq(address(factory).balance, 0);
    }

    function test_factoryRejectsCreatorReserveAboveTwentyPercent() public {
        ERC20T.Config memory config = _config(tokenOwner);
        config.lpSupply = LP_SUPPLY - 1;
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectRevert(ERC20T.InvalidCreatorAllocation.selector);
        _create(config, 0);
        assertEq(predicted.code.length, 0);
        assertEq(posm.nextTokenId(), 1);
    }

    function test_factoryDustDoesNotIncreaseZeroOrTwentyPercentOwnerReserve() public {
        for (uint256 creatorSupply; creatorSupply <= 200; creatorSupply += 200) {
            ERC20T.Config memory config = _config(tokenOwner);
            config.supply = 1_000;
            config.lpSupply = config.supply - creatorSupply;
            ERC20T token = factory.createAndLaunch(
                config, TickMath.getSqrtPriceAtTick(120_000), TickMath.minUsableTick(ERC20T_TICK_SPACING), 120_000
            );
            assertEq(token.balanceOf(tokenOwner), creatorSupply);
            assertGt(token.balanceOf(address(token)), 0);
            assertEq(
                token.balanceOf(tokenOwner) + token.balanceOf(address(manager)) + token.balanceOf(address(token)),
                config.supply
            );
            assertEq(token.balanceOf(address(factory)), 0);
            assertEq(token.owner(), tokenOwner);
        }
    }

    function test_factoryPreviewPricesAndTicksUseNativeEthPerWholeToken() public view {
        uint256[5] memory prices = [uint256(1), 1e12, 1 ether, 2 ether, 1_000 ether];
        for (uint256 i; i < prices.length; ++i) {
            ERC20TFactory.LaunchPreview memory preview = factory.previewLaunch(SUPPLY, 2_000, prices[i]);
            assertEq(preview.creatorSupply, SUPPLY / 5);
            assertEq(preview.lpSupply, LP_SUPPLY);
            assertEq(preview.tickLower, TickMath.minUsableTick(ERC20T_TICK_SPACING));
            assertEq(preview.tickUpper % ERC20T_TICK_SPACING, 0);
            assertEq(preview.sqrtPriceX96, TickMath.getSqrtPriceAtTick(preview.tickUpper));
            assertGe(preview.effectivePriceWei, prices[i]);
            // Rounding to spacing 60 changes a price by less than 0.7% (one tick interval).
            assertLe(preview.effectivePriceWei, prices[i] * 10_070 / 10_000 + 1);
        }
        ERC20TFactory.LaunchPreview memory oneEth = factory.previewLaunch(SUPPLY, 0, 1 ether);
        assertEq(oneEth.creatorSupply, 0);
        assertEq(oneEth.lpSupply, SUPPLY);
        assertEq(oneEth.sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(oneEth.tickUpper, 0);
        assertEq(oneEth.effectivePriceWei, 1 ether);
        ERC20TFactory.LaunchPreview memory negativeTick = factory.previewLaunch(SUPPLY, 0, 2 ether);
        assertLt(negativeTick.tickUpper, 0);
        assertGe(negativeTick.effectivePriceWei, 2 ether);
    }

    function test_factoryPreviewLaunchesAndAcceptsImmediateBuyWithoutPriceGap() public {
        ERC20TFactory.LaunchPreview memory preview = factory.previewLaunch(SUPPLY, 1_250, 1e12);
        ERC20T.Config memory config = _config(tokenOwner);
        config.lpSupply = preview.lpSupply;
        vm.prank(creator);
        ERC20T token = factory.createAndLaunch(config, preview.sqrtPriceX96, preview.tickLower, preview.tickUpper);
        assertEq(token.owner(), tokenOwner);
        assertEq(token.balanceOf(tokenOwner), preview.creatorSupply);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(token)), preview.lpSupply);
        assertEq(token.balanceOf(address(factory)), 0);
        PoolKey memory poolKey = token.poolKey();
        (uint160 actualPrice, int24 actualTick,,) = manager.getSlot0(poolKey.toId());
        assertEq(actualPrice, preview.sqrtPriceX96);
        assertEq(actualTick, preview.tickUpper);

        vm.deal(address(manager), 100 ether);
        vm.prank(creator);
        swapRouter.swap{value: 1 ether}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertGt(token.balanceOf(creator), 0);
        assertGt(feeWallet.balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_factoryPreviewRejectsInvalidPriceSupplyAndAllocation() public {
        vm.expectRevert(ERC20TFactory.InvalidCreatorAllocation.selector);
        factory.previewLaunch(SUPPLY, 2_001, 1 ether);
        vm.expectRevert(ERC20TFactory.InvalidLaunchPreview.selector);
        factory.previewLaunch(0, 0, 1 ether);
        vm.expectRevert(ERC20TFactory.InvalidLaunchPreview.selector);
        factory.previewLaunch(uint256(type(uint128).max) + 1, 0, 1 ether);
        vm.expectRevert(ERC20TFactory.InvalidLaunchPreview.selector);
        factory.previewLaunch(type(uint128).max, 0, 1 ether);
        vm.expectRevert(ERC20TFactory.InvalidLaunchPreview.selector);
        factory.previewLaunch(1, 0, 1);
        vm.expectRevert(ERC20TFactory.InvalidStartingPrice.selector);
        factory.previewLaunch(SUPPLY, 0, 0);
        vm.expectRevert(ERC20TFactory.InvalidStartingPrice.selector);
        factory.previewLaunch(SUPPLY, 0, type(uint256).max);
    }

    function testFuzz_factoryPreviewRoundsPriceAndCreatorAllocationSafely(
        uint96 rawSupply,
        uint16 rawCreatorBps,
        uint80 rawPrice
    ) public view {
        uint256 supply = bound(rawSupply, 1 ether, 1e27);
        uint16 creatorBps = uint16(bound(rawCreatorBps, 0, 2_000));
        uint256 price = bound(rawPrice, 1, 1e24);
        ERC20TFactory.LaunchPreview memory preview = factory.previewLaunch(supply, creatorBps, price);
        assertEq(preview.creatorSupply, supply * creatorBps / 10_000);
        assertLe(preview.creatorSupply, supply / 5);
        assertEq(preview.creatorSupply + preview.lpSupply, supply);
        assertEq(preview.tickUpper % ERC20T_TICK_SPACING, 0);
        assertEq(preview.sqrtPriceX96, TickMath.getSqrtPriceAtTick(preview.tickUpper));
        assertGe(preview.effectivePriceWei, price);
        assertLe(preview.effectivePriceWei, price * 10_070 / 10_000 + 1);
    }
}
