// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {ERC20T} from "./ERC20T.sol";
import {IERC20THook, ERC20T_TICK_SPACING} from "./ERC20TInterfaces.sol";

/// @title ERC20TFactory
/// @notice Clone an ERC20T and launch its canonical pool in one transaction.
/// @dev The factory owns the token only during creation. It keeps no admin privileges,
///      token allocation or fee. Supply and ownership go to config.owner; unused ETH
///      goes to the caller who paid for this transaction.
contract ERC20TFactory is ReentrancyGuard {
    /// @notice Shared, initialization-locked implementation. Its address cannot be changed.
    address public immutable implementation;

    struct LaunchPreview {
        uint256 creatorSupply;
        uint256 lpSupply;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint256 effectivePriceWei;
    }

    // Quote prices are quote base units per whole 18-decimal token, regardless of quote decimals.
    uint256 private constant PRICE_NUMERATOR = uint256(1e18) << 192;

    event TokenLaunched(address indexed token, address indexed owner, address indexed creator, address hook);
    /// @dev owner is the initial owner; atomic launches temporarily use the factory before TokenLaunched.
    event TokenCreated(address indexed token, address indexed owner, address indexed creator, address hook);

    error InvalidOwner();
    error InvalidFeeRecipient();
    error InvalidCreatorAllocation();
    error InvalidStartingPrice();
    error InvalidLaunchPreview();

    constructor() {
        implementation = address(new ERC20T());
    }

    /// @notice Create and initialize a token, leaving its owner to launch the pool separately.
    /// @dev Clone creation and initialization are atomic; supply goes directly to config.owner and the token.
    function create(ERC20T.Config calldata config) external nonReentrant returns (ERC20T token) {
        _validateOwner(config);
        token = _create(config);
    }

    /// @notice Derive a token-only launch from supply, creator allocation and an ETH price per token.
    /// @param supply Total supply in token base units (18 decimals).
    /// @param creatorAllocationBps Supply kept by the creator, from 0 to 2,000 basis points (20%).
    /// @param startingPriceWei Desired native ETH price in wei per whole token; must be at least 1.
    /// @dev Creator supply rounds down. The upper tick rounds down to spacing 60, making the
    ///      effective ETH price at least the requested price. Initialization uses that exact tick,
    ///      so the first buy reaches the token-only position without an inactive price gap.
    function previewLaunch(uint256 supply, uint16 creatorAllocationBps, uint256 startingPriceWei)
        external
        pure
        returns (LaunchPreview memory preview)
    {
        return _previewLaunch(supply, creatorAllocationBps, startingPriceWei, false);
    }

    /// @notice Preview a launch using a quote currency and explicit address ordering.
    /// @param startingPriceQuote Quote base units per whole new token, using the quote's own decimals.
    /// @param tokenIsCurrency0 True when the new token's address sorts below the quote token.
    /// @dev effectivePriceWei contains quote base units per whole token, even when the quote is ERC20T.
    function previewQuotedLaunch(
        uint256 supply,
        uint16 creatorAllocationBps,
        uint256 startingPriceQuote,
        bool tokenIsCurrency0
    ) external pure returns (LaunchPreview memory preview) {
        return _previewLaunch(supply, creatorAllocationBps, startingPriceQuote, tokenIsCurrency0);
    }

    /// @param config Token configuration, including the final owner and existing shared hook.
    /// @param sqrtPriceX96 Initial pool price, using the same convention as ERC20T.launch.
    /// @param tickLower Lower tick of the permanently locked launch position.
    /// @param tickUpper Upper tick. Start at/below tickLower for token0, at/above tickUpper for token1.
    function createAndLaunch(ERC20T.Config calldata config, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        external
        payable
        nonReentrant
        returns (ERC20T token)
    {
        _validateOwner(config);
        uint256 balanceBefore = address(this).balance - msg.value;

        // launch is owner-only. Use temporary ownership without requiring any later
        // approval or handoff transaction from the creator.
        ERC20T.Config memory deploymentConfig = config;
        deploymentConfig.owner = address(this);
        token = _create(deploymentConfig);
        token.launch{value: msg.value}(sqrtPriceX96, tickLower, tickUpper);

        _finishLaunch(token, config.owner, config.hook, balanceBefore);
    }

    /// @notice Deploy and launch at a quote/token price, deriving address ordering within this transaction.
    /// @dev config.lpSupply is replaced by the allocation derived from creatorAllocationBps.
    ///      ERC20-quoted launches require no native currency; all initial liquidity is the new token.
    function createAndLaunchAtPrice(
        ERC20T.Config calldata config,
        uint16 creatorAllocationBps,
        uint256 startingPriceQuote
    ) external payable nonReentrant returns (ERC20T token) {
        _validateOwner(config);
        uint256 balanceBefore = address(this).balance - msg.value;
        ERC20T.Config memory deploymentConfig = config;
        (, deploymentConfig.lpSupply) = _allocation(config.supply, creatorAllocationBps);
        deploymentConfig.owner = address(this);
        token = _create(deploymentConfig);

        LaunchPreview memory preview =
            _previewLaunch(config.supply, creatorAllocationBps, startingPriceQuote, address(token) < config.quoteToken);
        token.launch{value: msg.value}(preview.sqrtPriceX96, preview.tickLower, preview.tickUpper);
        _finishLaunch(token, config.owner, config.hook, balanceBefore);
    }

    function _create(ERC20T.Config memory config) private returns (ERC20T token) {
        if (config.hook.code.length == 0) revert ERC20T.InvalidAddress();
        bytes memory args = abi.encodePacked(
            config.hook,
            config.quoteToken,
            address(IERC20THook(config.hook).poolManager()),
            address(config.positionManager),
            address(config.permit2)
        );
        token = ERC20T(LibClone.clone(implementation, args));
        token.initialize(config);
        emit TokenCreated(address(token), config.owner, msg.sender, config.hook);
    }

    function _allocation(uint256 supply, uint16 creatorAllocationBps)
        private
        pure
        returns (uint256 creatorSupply, uint256 lpSupply)
    {
        if (creatorAllocationBps > 2_000) revert InvalidCreatorAllocation();
        if (supply == 0) revert InvalidLaunchPreview();
        creatorSupply = FullMath.mulDiv(supply, creatorAllocationBps, 10_000);
        lpSupply = supply - creatorSupply;
        if (lpSupply > type(uint128).max) revert InvalidLaunchPreview();
    }

    function _previewLaunch(uint256 supply, uint16 creatorAllocationBps, uint256 price, bool tokenIsCurrency0)
        private
        pure
        returns (LaunchPreview memory preview)
    {
        (preview.creatorSupply, preview.lpSupply) = _allocation(supply, creatorAllocationBps);
        if (price == 0) revert InvalidStartingPrice();
        if (tokenIsCurrency0) {
            preview.tickLower = _token0StartingTick(price);
            preview.tickUpper = TickMath.maxUsableTick(ERC20T_TICK_SPACING);
            preview.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(preview.tickLower);
            preview.effectivePriceWei = _token0Price(preview.sqrtPriceX96);
        } else {
            uint256 rawSqrt = FixedPointMathLib.sqrt(PRICE_NUMERATOR / price);
            if (rawSqrt < TickMath.MIN_SQRT_PRICE || rawSqrt >= TickMath.MAX_SQRT_PRICE) {
                revert InvalidStartingPrice();
            }
            int24 rawTick = TickMath.getTickAtSqrtPrice(uint160(rawSqrt));
            preview.tickUpper = (rawTick / ERC20T_TICK_SPACING) * ERC20T_TICK_SPACING;
            // Signed division truncates toward zero, so negative ticks need a floor correction.
            if (rawTick < 0 && rawTick % ERC20T_TICK_SPACING != 0) preview.tickUpper -= ERC20T_TICK_SPACING;
            preview.tickLower = TickMath.minUsableTick(ERC20T_TICK_SPACING);
            if (preview.tickUpper <= preview.tickLower) revert InvalidStartingPrice();
            preview.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(preview.tickUpper);
            // price >= 1 bounds sqrt below 2**126; rounding down preserves a safe uint256 square.
            preview.effectivePriceWei =
                PRICE_NUMERATOR / (uint256(preview.sqrtPriceX96) * uint256(preview.sqrtPriceX96));
        }

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(preview.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(preview.tickUpper);
        uint256 factor = tokenIsCurrency0 ? FullMath.mulDiv(sqrtLower, sqrtUpper, uint256(1) << 96) : uint256(1) << 96;
        uint256 liquidity = FullMath.mulDiv(preview.lpSupply, factor, uint256(sqrtUpper) - sqrtLower);
        if (liquidity == 0 || liquidity > Pool.tickSpacingToMaxLiquidityPerTick(ERC20T_TICK_SPACING)) {
            revert InvalidLaunchPreview();
        }
    }

    /// @dev Find the first aligned tick whose quote/token price meets the requested price.
    ///      FullMath handles squares above 256 bits; at most 15 steps cover every usable tick.
    function _token0StartingTick(uint256 price) private pure returns (int24) {
        int24 low = TickMath.minUsableTick(ERC20T_TICK_SPACING) / ERC20T_TICK_SPACING;
        int24 high = TickMath.maxUsableTick(ERC20T_TICK_SPACING) / ERC20T_TICK_SPACING - 1;
        if (_token0Price(TickMath.getSqrtPriceAtTick(high * ERC20T_TICK_SPACING)) < price) {
            revert InvalidStartingPrice();
        }
        while (low < high) {
            int24 mid = low + (high - low) / 2;
            if (_token0Price(TickMath.getSqrtPriceAtTick(mid * ERC20T_TICK_SPACING)) < price) low = mid + 1;
            else high = mid;
        }
        return low * ERC20T_TICK_SPACING;
    }

    function _token0Price(uint160 sqrtPriceX96) private pure returns (uint256) {
        // Multiplying a uint160 by 1e18 fits uint256; FullMath performs the remaining product in 512 bits.
        return FullMath.mulDiv(sqrtPriceX96, uint256(sqrtPriceX96) * 1e18, uint256(1) << 192);
    }

    function _validateOwner(ERC20T.Config calldata config) private view {
        if (config.owner == address(0) || config.owner == address(this)) revert InvalidOwner();
        if (config.feeRecipient == address(this) || config.feeDecayRecipient == address(this)) {
            revert InvalidFeeRecipient();
        }
    }

    function _finishLaunch(ERC20T token, address finalOwner, address tokenHook, uint256 balanceBefore) private {
        uint256 remainingSupply = token.balanceOf(address(this));
        if (remainingSupply != 0) token.transfer(finalOwner, remainingSupply);
        token.transferOwnership(finalOwner);
        emit TokenLaunched(address(token), finalOwner, msg.sender, tokenHook);
        // Keep any pre-existing ETH separate from this caller's launch refund.
        uint256 refund = address(this).balance - balanceBefore;
        if (refund != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, refund);
    }

    /// @dev PositionManager refunds unused native currency here while launch is executing.
    receive() external payable {}
}
