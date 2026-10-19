// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {IERC20T, IERC20TGlobalDistributorRegistry, ERC20T_POOL_FEE, ERC20T_TICK_SPACING} from "./ERC20TInterfaces.sol";

/// @title ERC20THook
/// @notice Shared ERC20T hook. Each token owns its tax, recipient and liquidity policy.
/// @dev A token has one canonical pool against ETH, an opted-in native ERC20T, or a registered base.
///      Buy fees first convert to the quote currency, then through its direct ETH pool.
///      All fee recipients receive native ETH; registered external pools retain their own fees.
///      The total tax includes a fixed 0.15% of swap output for the shared protocol.
///      Distributor approval never exempts swap taxes. This hook does not tax its own fee conversions.
contract ERC20THook is BaseHook, Ownable, ReentrancyGuard {
    struct ExternalBaseConfig {
        address token;
        PoolKey ethPool;
    }

    struct ExternalBaseStatus {
        bool registered;
        bool enabled;
    }

    struct FeeSnapshot {
        uint256 rate;
        uint256 restingRate;
        address recipient;
        address decayRecipient;
        address protocolRecipient;
    }

    struct FeeAmounts {
        uint256 regular;
        uint256 protocol;
        uint256 decay;
    }

    uint256 private constant BPS = 10_000;
    uint16 private constant MAX_CURRENT_TAX_BPS = 9_900;
    uint16 public constant PROTOCOL_FEE_BPS = 15;

    /// @notice Recipient of the shared protocol's native ETH fee, controlled by the hook owner.
    address public protocolFeeRecipient;

    /// @notice Immutable external distributor list; zero disables external approvals.
    address public immutable globalDistributorRegistry;

    mapping(address token => bool initialized) public poolInitialized;
    mapping(PoolId id => address token) public poolToken;
    mapping(address account => bool allowed) public isHookDistributor;
    mapping(address token => ExternalBaseStatus status) public externalBases;
    mapping(address token => PoolKey ethPool) private _externalBasePools;

    event DistributorSet(address indexed account, bool allowed);
    event ProtocolFeeRecipientSet(address indexed recipient);
    event PoolLaunched(address indexed token, bytes32 indexed poolId);
    event ExternalBaseRegistered(address indexed token, bytes32 indexed ethPoolId);
    event ExternalBaseEnabledSet(address indexed token, bool enabled);
    /// @param tokenFee Total token-output tax collected on buys, before splitting the ETH proceeds.
    /// @param ethFee Native ETH allocated to the regular recipient after protocol and decay shares.
    event HookFee(
        address indexed token, address indexed sender, address indexed recipient, uint256 tokenFee, uint256 ethFee
    );
    event ProtocolFee(address indexed token, address indexed sender, address indexed recipient, uint256 ethFee);
    event FeeDecay(address indexed token, address indexed sender, address indexed recipient, uint256 ethFee);

    error InvalidAddress();
    error InvalidGlobalDistributorRegistry();
    error InvalidPool();
    error PairingDisabled();
    error NotLaunching();
    error PoolAlreadyInitialized();
    error ExternalLiquidityDisabled();
    error ExactOutputNotAllowed();
    error InvalidTax();
    error PartialFeeSwap();
    error InvalidSwapDelta();
    error InvalidExternalBase();
    error ExternalBaseAlreadyRegistered();
    error ExternalBaseNotRegistered();
    error ExternalBaseDisabled();

    constructor(
        IPoolManager manager,
        address initialOwner,
        address initialProtocolFeeRecipient,
        ExternalBaseConfig[] memory initialBases,
        address registry
    ) BaseHook(manager) {
        if (address(manager).code.length == 0 || initialOwner == address(0) || initialOwner == registry) {
            revert InvalidAddress();
        }
        globalDistributorRegistry = registry;
        if (registry != address(0)) {
            if (registry.code.length == 0) revert InvalidGlobalDistributorRegistry();
            (bool valid,) = _readGlobalDistributor(registry, address(0));
            if (!valid) revert InvalidGlobalDistributorRegistry();
        }
        _initializeOwner(initialOwner);
        _setProtocolFeeRecipient(initialProtocolFeeRecipient);
        for (uint256 i; i < initialBases.length; ++i) {
            _registerExternalBase(initialBases[i].token, initialBases[i].ethPool);
        }
    }

    /// @notice Register an external quote token and its permanent, initialized ETH conversion pool.
    /// @dev The owner must select a compatible token and pool on this PoolManager. Registration
    ///      does not override the external token's transfer rules or its pool's fees and hook behavior.
    function registerExternalBase(address base, PoolKey calldata ethPool) external onlyOwner {
        _registerExternalBase(base, ethPool);
    }

    /// @notice Enable or disable new child launches. Existing pools keep using their registered route.
    function setExternalBaseEnabled(address base, bool enabled) external onlyOwner {
        if (!externalBases[base].registered) revert ExternalBaseNotRegistered();
        externalBases[base].enabled = enabled;
        emit ExternalBaseEnabledSet(base, enabled);
    }

    function externalBasePool(address base) external view returns (PoolKey memory) {
        if (!externalBases[base].registered) revert ExternalBaseNotRegistered();
        return _externalBasePools[base];
    }

    function _registerExternalBase(address base, PoolKey memory ethPool) private {
        if (externalBases[base].registered) revert ExternalBaseAlreadyRegistered();
        address routeHook = address(ethPool.hooks);
        if (
            base == address(0) || base == address(this) || base == address(poolManager) || base.code.length == 0
                || poolInitialized[base] || !ethPool.currency0.isAddressZero()
                || Currency.unwrap(ethPool.currency1) != base || routeHook == address(this)
                || (routeHook != address(0) && routeHook.code.length == 0)
                || ethPool.tickSpacing < TickMath.MIN_TICK_SPACING || ethPool.tickSpacing > TickMath.MAX_TICK_SPACING
                || (!LPFeeLibrary.isValid(ethPool.fee) && !LPFeeLibrary.isDynamicFee(ethPool.fee))
                || !Hooks.isValidHookAddress(ethPool.hooks, ethPool.fee)
        ) revert InvalidExternalBase();

        // Also reject this hook's unlaunched tokens. Ordinary ERC20s need not implement hook().
        (bool success, bytes memory result) = base.staticcall(abi.encodeCall(IERC20T.hook, ()));
        if (success && result.length >= 32) {
            uint256 reportedHook;
            assembly ("memory-safe") {
                reportedHook := mload(add(result, 32))
            }
            if (reportedHook == uint256(uint160(address(this)))) revert InvalidExternalBase();
        }

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, ethPool.toId());
        if (sqrtPriceX96 == 0) revert InvalidExternalBase();
        externalBases[base] = ExternalBaseStatus({registered: true, enabled: true});
        _externalBasePools[base] = ethPool;
        emit ExternalBaseRegistered(base, PoolId.unwrap(ethPool.toId()));
        emit ExternalBaseEnabledSet(base, true);
    }

    /// @notice Set the destination of protocol fees for every token using this hook.
    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        _setProtocolFeeRecipient(recipient);
    }

    function _setProtocolFeeRecipient(address recipient) private {
        if (recipient == address(0) || recipient == address(this) || recipient == address(poolManager)) {
            revert InvalidAddress();
        }
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(recipient);
    }

    /// @notice Combine hook-owner approvals with the immutable external distributor registry.
    /// @dev A token's shared-list opt-out covers both sources. Unavailable registry entries are false.
    function isDistributor(address account) public view returns (bool) {
        if (account == address(0) || account == address(poolManager) || account == address(this)) return false;
        if (isHookDistributor[account]) return true;
        address registry = globalDistributorRegistry;
        if (registry == address(0) || account.code.length == 0) return false;
        (, bool approved) = _readGlobalDistributor(registry, account);
        return approved;
    }

    /// @notice Update supplemental shared approvals without changing the external registry.
    /// @dev Approved contracts are trusted transfer endpoints, not approved swap routers.
    function setDistributors(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == address(0) || account == address(poolManager) || account == address(this)) {
                revert InvalidAddress();
            }
            if (allowed && account.code.length == 0) revert InvalidAddress();
            isHookDistributor[account] = allowed;
            emit DistributorSet(account, allowed);
        }
    }

    function _readGlobalDistributor(address registry, address account)
        private
        view
        returns (bool valid, bool approved)
    {
        bytes memory query = abi.encodeCall(IERC20TGlobalDistributorRegistry.isGlobalDistributor, (account));
        // Copy only one word, and never ABI-decode a failed, short or noncanonical response.
        assembly ("memory-safe") {
            let success := staticcall(gas(), registry, add(query, 0x20), mload(query), 0x00, 0x20)
            let response := mload(0x00)
            valid := and(and(success, eq(returndatasize(), 0x20)), lt(response, 2))
            approved := and(valid, eq(response, 1))
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.afterAddLiquidity = true;
        permissions.afterRemoveLiquidity = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (key.fee != ERC20T_POOL_FEE || key.tickSpacing != ERC20T_TICK_SPACING || address(key.hooks) != address(this))
        {
            revert InvalidPool();
        }
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        address token;
        address quote;
        if (currency0 == address(0)) {
            token = currency1;
        } else if (externalBases[currency0].registered || poolInitialized[currency0]) {
            token = currency1;
            quote = currency0;
        } else if (externalBases[currency1].registered || poolInitialized[currency1]) {
            token = currency0;
            quote = currency1;
        } else {
            revert InvalidPool();
        }
        // Known external bases are never treated as ERC20T children or queried for ERC20T getters.
        if (externalBases[token].registered) revert InvalidPool();

        IERC20T configuredToken = IERC20T(token);
        if (
            configuredToken.hook() != address(this) || configuredToken.poolManager() != poolManager
                || configuredToken.quoteToken() != quote
        ) revert InvalidPool();
        if (externalBases[quote].registered) {
            if (!externalBases[quote].enabled) revert ExternalBaseDisabled();
        } else if (quote != address(0)) {
            // Keep quote chains one level deep: X must already have its own ETH/X pool here.
            IERC20T quoteToken = IERC20T(quote);
            if (
                !poolInitialized[quote] || quoteToken.quoteToken() != address(0) || quoteToken.hook() != address(this)
                    || quoteToken.poolManager() != poolManager
            ) revert InvalidPool();
            // This controls new launches only. Existing swaps and LP withdrawals stay available.
            if (!quoteToken.pairingEnabled()) revert PairingDisabled();
        }
        if (!configuredToken.launching()) revert NotLaunching();
        if (poolInitialized[token]) revert PoolAlreadyInitialized();
        poolInitialized[token] = true;
        poolToken[key.toId()] = token;
        emit PoolLaunched(token, PoolId.unwrap(key.toId()));
        return BaseHook.beforeInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        IERC20T token = _configuredToken(key);
        if (!token.launching() && !token.externalLiquidityEnabled()) revert ExternalLiquidityDisabled();
        _accountSettlement(key, delta.amount0(), delta.amount1());
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Existing LPs can always withdraw, including after new deposits or pair launches are disabled.
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _configuredToken(key);
        _accountSettlement(key, delta.amount0(), delta.amount1());
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        // PoolManager skips hooks on the hook's own fee-conversion swap.
        if (params.amountSpecified >= 0) revert ExactOutputNotAllowed();
        IERC20T token = _configuredToken(key);
        // Freeze rates and every destination before conversions or callbacks can change owner settings.
        FeeSnapshot memory fees = _snapshotFees(token);

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        int128 outputDelta = params.zeroForOne ? amount1 : amount0;
        if (outputDelta < 0) revert InvalidSwapDelta();
        uint256 output = uint256(int256(outputDelta));
        uint256 fee = output * fees.rate / BPS;
        // Only the caller's post-tax deltas contribute to net settlement permissions.
        // Intermediate X credit and debt cancel even though no ERC20 transfer takes place.
        if (params.zeroForOne) amount1 -= int128(int256(fee));
        else amount0 -= int128(int256(fee));
        _accountSettlement(key, amount0, amount1);

        if (fee != 0) _collectFee(sender, key, token, params.zeroForOne, fee, fees);
        return (BaseHook.afterSwap.selector, int128(int256(fee)));
    }

    function _collectFee(
        address sender,
        PoolKey calldata key,
        IERC20T token,
        bool zeroForOne,
        uint256 fee,
        FeeSnapshot memory fees
    ) private {
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == address(token);
        bool buying = zeroForOne != tokenIsCurrency0;
        Currency quote = tokenIsCurrency0 ? key.currency1 : key.currency0;
        uint256 quoteFee;
        if (buying) {
            token.increaseTransferAllowance(fee, true);
            poolManager.take(Currency.wrap(address(token)), address(this), fee);
            quoteFee = _swapTokenForQuote(key, token, tokenIsCurrency0, fee);
        } else {
            quoteFee = fee;
        }
        FeeAmounts memory amounts = _payEth(quote, quoteFee, fees);
        emit HookFee(address(token), sender, fees.recipient, buying ? fee : 0, amounts.regular);
        emit ProtocolFee(address(token), sender, fees.protocolRecipient, amounts.protocol);
        if (amounts.decay != 0) emit FeeDecay(address(token), sender, fees.decayRecipient, amounts.decay);
    }

    function _snapshotFees(IERC20T token) private view returns (FeeSnapshot memory fees) {
        fees = FeeSnapshot({
            rate: token.taxBps(),
            restingRate: token.restingTaxBps(),
            recipient: token.feeRecipient(),
            decayRecipient: token.feeDecayRecipient(),
            protocolRecipient: protocolFeeRecipient
        });
        if (
            fees.restingRate < 30 || fees.restingRate > 500 || fees.rate < fees.restingRate
                || fees.rate > MAX_CURRENT_TAX_BPS
        ) revert InvalidTax();
        _validateFeeRecipient(fees.recipient);
        _validateFeeRecipient(fees.decayRecipient);
        _validateFeeRecipient(fees.protocolRecipient);
    }

    function _validateFeeRecipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this) || recipient == address(poolManager)) {
            revert InvalidAddress();
        }
    }

    function _configuredToken(PoolKey calldata key) private view returns (IERC20T token) {
        address configured = poolToken[key.toId()];
        if (configured == address(0)) revert InvalidPool();
        token = IERC20T(configured);
    }

    function _accountSettlement(PoolKey calldata key, int128 amount0, int128 amount1) private {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (poolInitialized[currency0] && amount0 != 0) {
            IERC20T(currency0).accountTransferDelta(amount0);
        }
        if (poolInitialized[currency1] && amount1 != 0) IERC20T(currency1).accountTransferDelta(amount1);
    }

    function _swapTokenForQuote(PoolKey calldata key, IERC20T token, bool tokenIsCurrency0, uint256 amount)
        private
        returns (uint256 quoteAmount)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: tokenIsCurrency0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // The conversion must consume the full fee rather than retain another token's balance.
        int128 tokenDelta = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        if (tokenDelta > 0 || uint256(-int256(tokenDelta)) != amount) revert PartialFeeSwap();
        int128 quoteDelta = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        if (quoteDelta < 0) revert InvalidSwapDelta();
        // Fee transfers have their own immediately consumed allowances. They must not cancel
        // user settlement permissions: fee withdrawals can precede a user's quote deposit.
        token.increaseTransferAllowance(amount, false);
        poolManager.sync(Currency.wrap(address(token)));
        SafeTransferLib.safeTransfer(address(token), address(poolManager), amount);
        poolManager.settle();
        quoteAmount = uint256(int256(quoteDelta));
    }

    /// @dev Convert once, floor the protocol and excess-rate shares, and allocate all rounding
    ///      remainder to the regular recipient. No fee dust remains in the hook.
    function _payEth(Currency quote, uint256 amount, FeeSnapshot memory fees)
        private
        returns (FeeAmounts memory amounts)
    {
        if (amount == 0) return amounts;
        uint256 ethAmount = quote.isAddressZero() ? amount : _swapQuoteForEth(quote, amount);
        if (ethAmount != 0) {
            amounts.protocol = ethAmount * PROTOCOL_FEE_BPS / fees.rate;
            amounts.decay = ethAmount * (fees.rate - fees.restingRate) / fees.rate;
            amounts.regular = ethAmount - amounts.protocol - amounts.decay;
            poolManager.take(Currency.wrap(address(0)), address(this), ethAmount);
            _distributeEth(fees, amounts);
        }
    }

    /// @dev Merge identical destinations before making any payments. Events retain separate shares.
    function _distributeEth(FeeSnapshot memory fees, FeeAmounts memory amounts) private {
        uint256 tokenAmount = amounts.regular;
        uint256 protocolAmount = amounts.protocol;
        uint256 decayAmount = amounts.decay;
        if (fees.decayRecipient == fees.recipient) {
            tokenAmount += decayAmount;
            decayAmount = 0;
        }
        if (fees.protocolRecipient == fees.recipient) {
            tokenAmount += protocolAmount;
            protocolAmount = 0;
        } else if (fees.protocolRecipient == fees.decayRecipient) {
            decayAmount += protocolAmount;
            protocolAmount = 0;
        }
        if (protocolAmount != 0) SafeTransferLib.forceSafeTransferETH(fees.protocolRecipient, protocolAmount);
        if (decayAmount != 0) SafeTransferLib.forceSafeTransferETH(fees.decayRecipient, decayAmount);
        if (tokenAmount != 0) SafeTransferLib.forceSafeTransferETH(fees.recipient, tokenAmount);
    }

    /// @dev Pair validation guarantees a canonical or registered direct ETH pool exists.
    ///      Its quote input nets against the hook's fee credit in PoolManager. No physical quote
    ///      transfer or user-settlement permission is needed. For sells, core credits the
    ///      fee after afterSwap returns; PoolManager permits this temporary debt while unlocked.
    function _swapQuoteForEth(Currency quote, uint256 amount) private returns (uint256 ethAmount) {
        address quoteAddress = Currency.unwrap(quote);
        PoolKey memory nativeKey;
        if (externalBases[quoteAddress].registered) {
            // Deliberately preserve the external hook and fee. Its net ETH output is the payout basis.
            nativeKey = _externalBasePools[quoteAddress];
        } else {
            nativeKey = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: quote,
                fee: ERC20T_POOL_FEE,
                tickSpacing: ERC20T_TICK_SPACING,
                hooks: IHooks(address(this))
            });
        }
        BalanceDelta delta = poolManager.swap(
            nativeKey,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        // Insufficient ETH/X liquidity reverts the entire user trade, including all fees.
        int128 quoteDelta = delta.amount1();
        if (quoteDelta > 0 || uint256(-int256(quoteDelta)) != amount) revert PartialFeeSwap();
        int128 ethDelta = delta.amount0();
        if (ethDelta < 0) revert InvalidSwapDelta();
        ethAmount = uint256(int256(ethDelta));
    }

    receive() external payable {}
}
