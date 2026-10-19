// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20T} from "../../src/ERC20T/ERC20T.sol";
import {ERC20THook} from "../../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../../src/ERC20T/ERC20TFactory.sol";
import {ERC20T_TICK_SPACING} from "../../src/ERC20T/ERC20TInterfaces.sol";
import {TokenPosmHelper} from "../support/TokenPosmHelper.sol";

interface IERC20TQuotedFactoryPositionOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Exercise the factory at real v4 prices in both address orderings, including rollback.
contract ERC20TQuotedFactoryTest is Deployers, TokenPosmHelper {
    using StateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    ERC20THook hook;
    ERC20TFactory factory;
    address tokenOwner = makeAddr("quotedFactoryOwner");
    address creator = makeAddr("quotedFactoryCreator");
    address feeWallet = makeAddr("quotedFactoryFees");
    address protocolFees = makeAddr("quotedFactoryProtocolFees");

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
            abi.encode(manager, address(this), protocolFees, new ERC20THook.ExternalBaseConfig[](0), address(0))
        );
        vm.prank(CREATE2_DEPLOYER);
        hook = new ERC20THook{salt: salt}(
            manager, address(this), protocolFees, new ERC20THook.ExternalBaseConfig[](0), address(0)
        );
        assertEq(address(hook), expected);
        factory = new ERC20TFactory();
        vm.deal(creator, 10 ether);
        vm.deal(address(this), 10 ether);
        vm.deal(address(manager), 100 ether);
    }

    function _config(address quote) private view returns (ERC20T.Config memory) {
        return ERC20T.Config({
            name: "Quoted Factory Token",
            symbol: "QFACT",
            supply: SUPPLY,
            lpSupply: SUPPLY * 4 / 5,
            owner: tokenOwner,
            hook: address(hook),
            quoteToken: quote,
            positionManager: posm,
            permit2: IAllowanceTransfer(PERMIT2_ADDR),
            taxBps: 300,
            feeRecipient: feeWallet,
            feeDecayRecipient: address(0),
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0
        });
    }

    function _nextToken() private view returns (address) {
        return vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
    }

    /// @dev Choose the quote address around the factory's actual next CREATE address.
    /// This guarantees both token orderings without altering the factory or faking a deployment.
    function _quoteForOrdering(bool childIsCurrency0) private returns (ERC20T quote) {
        address nextChild = _nextToken();
        ERC20T.Config memory config = _config(address(0));
        config.owner = address(this);
        address implementation = factory.implementation();
        bytes memory args = abi.encodePacked(
            config.hook,
            config.quoteToken,
            address(config.positionManager.poolManager()),
            address(config.positionManager),
            address(config.permit2)
        );
        bytes32 initCodeHash = LibClone.initCodeHash(implementation, args);
        for (uint256 i; i < 10_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = LibClone.predictDeterministicAddress(initCodeHash, salt, address(this));
            if ((nextChild < predicted) == childIsCurrency0 && predicted != nextChild) {
                quote = ERC20T(LibClone.cloneDeterministic(implementation, args, salt));
                quote.initialize(config);
                assertEq(address(quote), predicted);
                quote.launch(SQRT_PRICE_1_1, TickMath.minUsableTick(ERC20T_TICK_SPACING), 0);
                quote.setPairingEnabled(true);
                return quote;
            }
        }
        revert("could not select quote ordering");
    }

    function _assertCreated(ERC20T token, ERC20TFactory.LaunchPreview memory preview, uint256 positionId) private view {
        assertEq(token.owner(), tokenOwner);
        assertTrue(token.launched());
        assertFalse(token.launching());
        assertTrue(hook.poolInitialized(address(token)));
        assertEq(token.balanceOf(tokenOwner), preview.creatorSupply);
        assertEq(token.balanceOf(creator), 0);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(token)), preview.lpSupply);
        assertEq(token.totalSupply(), preview.creatorSupply + preview.lpSupply);
        assertEq(token.allowance(address(token), PERMIT2_ADDR), 0);
        (uint160 approval,,) = IAllowanceTransfer(PERMIT2_ADDR).allowance(address(token), address(token), address(posm));
        assertEq(approval, 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getNetTransferAllowance(), 0);
        PoolKey memory poolKey = token.poolKey();
        (uint160 sqrtPrice,,,) = manager.getSlot0(poolKey.toId());
        assertEq(sqrtPrice, preview.sqrtPriceX96);
        assertEq(
            IERC20TQuotedFactoryPositionOwner(address(posm)).ownerOf(positionId),
            0x000000000000000000000000000000000000dEaD
        );
    }

    function _quotedAtPrice(bool childIsCurrency0, uint16 creatorBps) private {
        ERC20T quote = _quoteForOrdering(childIsCurrency0);
        ERC20T.Config memory config = _config(address(quote));
        // The price-based entrypoint derives lpSupply instead of accepting this stale UI value.
        config.lpSupply = type(uint256).max;
        address predicted = _nextToken();
        uint256 positionId = posm.nextTokenId();
        uint256 quoteBalanceBefore = quote.balanceOf(address(manager));
        ERC20TFactory.LaunchPreview memory preview =
            factory.previewQuotedLaunch(SUPPLY, creatorBps, 2 ether, childIsCurrency0);
        vm.prank(creator);
        ERC20T token = factory.createAndLaunchAtPrice(config, creatorBps, 2 ether);

        assertEq(address(token), predicted);
        assertEq(address(token) < address(quote), childIsCurrency0);
        assertEq(token.quoteToken(), address(quote));
        _assertCreated(token, preview, positionId);
        assertEq(quote.balanceOf(address(manager)), quoteBalanceBefore);
        assertEq(quote.balanceOf(address(factory)), 0);
        assertEq(quote.balanceOf(feeWallet), 0);
        assertEq(address(factory).balance, 0);
        assertEq(creator.balance, 10 ether);
        PoolKey memory poolKey = token.poolKey();
        assertEq(Currency.unwrap(childIsCurrency0 ? poolKey.currency0 : poolKey.currency1), address(token));
        assertEq(
            preview.sqrtPriceX96, TickMath.getSqrtPriceAtTick(childIsCurrency0 ? preview.tickLower : preview.tickUpper)
        );
    }

    function test_quotedFactoryAtPriceCurrency0WithZeroCreatorAllocation() public {
        _quotedAtPrice(true, 0);
    }

    function test_quotedFactoryAtPriceCurrency0WithTwentyPercentCreatorAllocation() public {
        _quotedAtPrice(true, 2_000);
    }

    function test_quotedFactoryAtPriceCurrency1WithZeroCreatorAllocation() public {
        _quotedAtPrice(false, 0);
    }

    function test_quotedFactoryAtPriceCurrency1WithTwentyPercentCreatorAllocation() public {
        _quotedAtPrice(false, 2_000);
    }

    function _quotedLaunchTaxSchedule(bool childIsCurrency0) private {
        ERC20T quote = _quoteForOrdering(childIsCurrency0);
        ERC20T.Config memory config = _config(address(quote));
        config.taxBps = 130;
        config.launchTaxBps = 9_900;
        config.feeDecayRecipient = makeAddr("quotedFactoryDecayFees");
        config.taxDecayIntervalSeconds = 60;
        vm.warp(1_000);
        vm.prank(creator);
        ERC20T token = factory.createAndLaunchAtPrice(config, 2_000, 2 ether);
        assertEq(address(token) < address(quote), childIsCurrency0);
        assertEq(token.owner(), tokenOwner);
        assertEq(token.restingTaxBps(), 130);
        assertEq(token.launchTaxBps(), 9_900);
        assertEq(token.feeDecayRecipient(), config.feeDecayRecipient);
        assertEq(token.taxDecayIntervalSeconds(), 60);
        assertEq(token.launchedAt(), 1_000);
        assertEq(token.taxBps(), 9_900);
        vm.warp(1_059);
        assertEq(token.taxBps(), 9_900);
        vm.warp(1_060);
        assertEq(token.taxBps(), 9_800);
        vm.warp(6_820);
        assertEq(token.taxBps(), 200);
        vm.warp(6_880);
        assertEq(token.taxBps(), 130);
    }

    function test_quotedFactoryForwardsLaunchTaxScheduleWithTokenAsCurrency0() public {
        _quotedLaunchTaxSchedule(true);
    }

    function test_quotedFactoryForwardsLaunchTaxScheduleWithTokenAsCurrency1() public {
        _quotedLaunchTaxSchedule(false);
    }

    function test_nativeFactoryAtPriceStillLaunchesRefundsAndAllowsImmediateBuy() public {
        for (uint256 i; i < 2; ++i) {
            uint16 creatorBps = i == 0 ? 0 : 2_000;
            ERC20T.Config memory config = _config(address(0));
            config.lpSupply = 0;
            ERC20TFactory.LaunchPreview memory preview = factory.previewLaunch(SUPPLY, creatorBps, 1e12);
            uint256 positionId = posm.nextTokenId();
            vm.prank(creator);
            ERC20T token = factory.createAndLaunchAtPrice{value: 1 ether}(config, creatorBps, 1e12);
            _assertCreated(token, preview, positionId);
            assertEq(token.quoteToken(), address(0));
            assertEq(creator.balance, 10 ether);
            assertEq(address(factory).balance, 0);
            assertEq(address(posm).balance, 0);
            PoolKey memory swapKey = token.poolKey();
            uint256 tokenFeesBefore = feeWallet.balance;
            uint256 protocolFeesBefore = protocolFees.balance;
            vm.prank(creator);
            swapRouter.swap{value: 0.1 ether}(
                swapKey,
                SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ZERO_BYTES
            );
            assertGt(token.balanceOf(creator), 0);
            uint256 tokenPaid = feeWallet.balance - tokenFeesBefore;
            uint256 protocolPaid = protocolFees.balance - protocolFeesBefore;
            assertGt(tokenPaid, 0);
            assertGt(protocolPaid, 0);
            assertEq(protocolPaid, (tokenPaid + protocolPaid) * 15 / config.taxBps);
            vm.deal(creator, 10 ether);
        }
    }

    function test_quotedFactorySupportsPriceWhoseToken0SquareExceedsUint256() public {
        ERC20T quote = _quoteForOrdering(true);
        ERC20T.Config memory config = _config(address(quote));
        config.supply = 1 ether;
        config.lpSupply = 0;
        ERC20TFactory.LaunchPreview memory preview = factory.previewQuotedLaunch(1 ether, 0, 1e40, true);
        assertGt(uint256(preview.sqrtPriceX96), type(uint128).max);
        uint256 exactPrice =
            FullMath.mulDiv(preview.sqrtPriceX96, uint256(preview.sqrtPriceX96) * 1e18, uint256(1) << 192);
        assertEq(preview.effectivePriceWei, exactPrice);
        assertGe(preview.effectivePriceWei, 1e40);
        assertLe(preview.effectivePriceWei, 1e40 * 10_070 / 10_000);
        uint256 positionId = posm.nextTokenId();
        vm.prank(creator);
        ERC20T token = factory.createAndLaunchAtPrice(config, 0, 1e40);
        assertLt(uint160(address(token)), uint160(address(quote)));
        _assertCreated(token, preview, positionId);
    }

    function test_quotedFactoryPreviewRejectsZeroAndUnrepresentablePricesInBothOrderings() public {
        for (uint256 i; i < 2; ++i) {
            bool token0 = i == 0;
            vm.expectRevert(ERC20TFactory.InvalidStartingPrice.selector);
            factory.previewQuotedLaunch(SUPPLY, 0, 0, token0);
            vm.expectRevert(ERC20TFactory.InvalidStartingPrice.selector);
            factory.previewQuotedLaunch(SUPPLY, 0, type(uint256).max, token0);
            vm.expectRevert(ERC20TFactory.InvalidCreatorAllocation.selector);
            factory.previewQuotedLaunch(SUPPLY, 2_001, 1 ether, token0);
            vm.expectRevert(ERC20TFactory.InvalidLaunchPreview.selector);
            factory.previewQuotedLaunch(0, 0, 1 ether, token0);
        }
    }

    function _assertFailedCreation(address predicted, uint64 nonceBefore, uint256 positionIdBefore) private view {
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(address(factory)), nonceBefore);
        assertEq(posm.nextTokenId(), positionIdBefore);
        assertFalse(hook.poolInitialized(predicted));
    }

    function _wrongSideRollsBack(bool childIsCurrency0) private {
        ERC20T quote = _quoteForOrdering(childIsCurrency0);
        ERC20T.Config memory config = _config(address(quote));
        address predicted = _nextToken();
        uint64 nonceBefore = vm.getNonce(address(factory));
        uint256 positionIdBefore = posm.nextTokenId();
        int24 lower = childIsCurrency0 ? int24(0) : TickMath.minUsableTick(ERC20T_TICK_SPACING);
        int24 upper = childIsCurrency0 ? TickMath.maxUsableTick(ERC20T_TICK_SPACING) : int24(0);
        uint160 wrongSqrt = childIsCurrency0 ? SQRT_PRICE_1_1 + 1 : SQRT_PRICE_1_1 - 1;
        vm.prank(creator);
        vm.expectRevert(ERC20T.InvalidRange.selector);
        factory.createAndLaunch(config, wrongSqrt, lower, upper);
        _assertFailedCreation(predicted, nonceBefore, positionIdBefore);
        vm.prank(creator);
        ERC20T token = factory.createAndLaunchAtPrice(config, 2_000, 1 ether);
        assertEq(address(token), predicted);
        assertTrue(token.launched());
    }

    function test_quotedFactoryCurrency0RejectsOneSqrtUnitAboveTokenOnlyBoundary() public {
        _wrongSideRollsBack(true);
    }

    function test_quotedFactoryCurrency1RejectsOneSqrtUnitBelowTokenOnlyBoundary() public {
        _wrongSideRollsBack(false);
    }

    function test_quotedFactoryRejectsEthAndRollsBackDeploymentWithoutTouchingBalances() public {
        ERC20T quote = _quoteForOrdering(true);
        ERC20T.Config memory config = _config(address(quote));
        address predicted = _nextToken();
        uint64 nonceBefore = vm.getNonce(address(factory));
        uint256 positionIdBefore = posm.nextTokenId();
        uint256 quoteBalanceBefore = quote.balanceOf(address(manager));
        vm.deal(address(factory), 7 ether);
        vm.prank(creator);
        vm.expectRevert(ERC20T.NativeValueNotAllowed.selector);
        factory.createAndLaunchAtPrice{value: 1 ether}(config, 0, 1 ether);
        _assertFailedCreation(predicted, nonceBefore, positionIdBefore);
        assertEq(creator.balance, 10 ether);
        assertEq(address(factory).balance, 7 ether);
        assertEq(quote.balanceOf(address(manager)), quoteBalanceBefore);
    }
}
