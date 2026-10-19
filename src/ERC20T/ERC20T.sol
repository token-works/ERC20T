// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20THook, ERC20T_POOL_FEE, ERC20T_TICK_SPACING} from "./ERC20TInterfaces.sol";

/// @dev PositionManager exposes this getter through Permit2Forwarder, but IPositionManager omits it.
interface IERC20TPositionManagerPermit2 {
    function permit2() external view returns (address);
}

/// @title ERC20T
/// @notice Fixed-supply token with one taxed quote pool and owner-approved distribution contracts.
/// @dev Fixed clone arguments bind the hook and infrastructure to each token. Direct transfers
///      between wallets without code are untaxed; the initial liquidity position is locked forever.
contract ERC20T is ERC20, Ownable, ReentrancyGuard {
    struct Config {
        string name;
        string symbol;
        uint256 supply;
        uint256 lpSupply;
        address owner;
        address hook;
        address quoteToken;
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
        // Resting tax, or the fixed tax when the optional launch schedule is disabled.
        uint16 taxBps;
        address feeRecipient;
        // Zero disables launch decay; enabled schedules always begin at LAUNCH_TAX_BPS.
        uint16 launchTaxBps;
        uint32 taxDecayIntervalSeconds;
        // Zero uses the initial feeRecipient; later recipient changes are independent.
        address feeDecayRecipient;
    }

    uint16 public constant MIN_TAX_BPS = 30;
    uint16 public constant MAX_TAX_BPS = 500;
    uint16 public constant LAUNCH_TAX_BPS = 9_900;
    uint16 public constant TAX_DECAY_STEP_BPS = 100;
    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Separate gross allowances for immediately settled fee transfers, plus signed user deltas.
    // These low transient slots do not overlap Solady's persistent reentrancy guard.
    uint256 private constant FROM_POOL_MANAGER_SLOT = 0;
    uint256 private constant TO_POOL_MANAGER_SLOT = 1;
    uint256 private constant LAUNCHING_SLOT = 2;
    uint256 private constant NET_TRANSFER_SLOT = 3;

    bool private _initialized;
    bool public launched;
    bool public useGlobalDistributors;
    bool public externalLiquidityEnabled;
    bool public pairingEnabled;
    uint16 public restingTaxBps;
    address public feeRecipient;
    uint16 public launchTaxBps;
    // Keep the original completion threshold when the owner changes the tax after decay ends.
    uint8 private _taxDecaySteps;
    uint32 public taxDecayIntervalSeconds;
    uint64 public launchedAt;
    mapping(address => bool) public isLocalDistributor;

    string private _name;
    string private _symbol;
    address public feeDecayRecipient;

    event DistributorSet(address indexed account, bool allowed);
    event TaxBpsSet(uint16 taxBps);
    event LaunchTaxConfigured(uint16 launchTaxBps, uint16 restingTaxBps, uint32 intervalSeconds);
    event TaxDecayStarted(uint64 timestamp);
    event FeeRecipientSet(address indexed feeRecipient);
    event FeeDecayRecipientSet(address indexed feeDecayRecipient);
    event UseGlobalDistributorsSet(bool enabled);
    event ExternalLiquidityEnabledSet(bool enabled);
    event PairingEnabledSet(bool enabled);
    event AllowanceIncreased(uint256 amount, bool fromPoolManager);
    event AllowanceSpent(address indexed from, address indexed to, uint256 amount);
    event TransferDeltaAccounted(int128 delta, int256 net);
    event Launched(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenSeeded);

    error InvalidAddress();
    error EmptyString();
    error InvalidSupply();
    error InvalidCreatorAllocation();
    error InvalidTax();
    error InvalidTaxDecayConfiguration();
    error TaxDecayActive();
    error InvalidTransfer();
    error OnlyHook();
    error AlreadyLaunched();
    error NoLpSupply();
    error InvalidRange();
    error InvalidLiquidity();
    error AmountTooLarge();
    error InvalidQuoteToken();
    error NativeValueNotAllowed();
    error InvalidClone();

    /// @dev Lock the implementation. Clones start with their own uninitialized storage.
    constructor() {
        _initialized = true;
    }

    /// @notice Initialize a fixed-argument clone once. Supply uses base units; the owner may keep up to 20%.
    /// @param config Token metadata, allocations, owner, infrastructure, tax and fee destination.
    function initialize(Config calldata config) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        // Solady's standard 45-byte delegate runtime followed by five packed addresses.
        if (address(this).code.length != 145) revert InvalidClone();
        _initializeToken(config);
    }

    function _initializeToken(Config memory config) private {
        if (bytes(config.name).length == 0 || bytes(config.symbol).length == 0) revert EmptyString();
        if (config.supply == 0 || config.lpSupply > config.supply) revert InvalidSupply();
        if (config.supply - config.lpSupply > config.supply / 5) revert InvalidCreatorAllocation();
        if (
            config.owner == address(0) || config.hook.code.length == 0
                || address(config.positionManager).code.length == 0 || address(config.permit2).code.length == 0
        ) revert InvalidAddress();

        IPoolManager manager = IERC20THook(config.hook).poolManager();
        if (
            address(manager).code.length == 0 || address(config.positionManager.poolManager()) != address(manager)
                || IERC20TPositionManagerPermit2(address(config.positionManager)).permit2() != address(config.permit2)
        ) revert InvalidAddress();
        if (config.feeDecayRecipient == address(0)) config.feeDecayRecipient = config.feeRecipient;
        if (
            config.feeRecipient == address(0) || config.feeRecipient == address(this)
                || config.feeRecipient == address(manager) || config.feeRecipient == config.hook
        ) revert InvalidAddress();
        if (
            config.feeDecayRecipient == address(0) || config.feeDecayRecipient == address(this)
                || config.feeDecayRecipient == address(manager) || config.feeDecayRecipient == config.hook
        ) revert InvalidAddress();
        if (
            config.quoteToken != address(0)
                && (config.quoteToken == address(this) || config.quoteToken.code.length == 0)
        ) revert InvalidQuoteToken();
        _validateTax(config.taxBps);
        if (
            hook() != config.hook || quoteToken() != config.quoteToken || poolManager() != manager
                || positionManager() != config.positionManager || permit2() != config.permit2
        ) revert InvalidClone();

        _name = config.name;
        _symbol = config.symbol;
        useGlobalDistributors = true;
        restingTaxBps = config.taxBps;
        feeRecipient = config.feeRecipient;
        feeDecayRecipient = config.feeDecayRecipient;
        _initializeOwner(config.owner);
        _configureLaunchTax(config.launchTaxBps, config.taxDecayIntervalSeconds);

        if (config.lpSupply != 0) _mint(address(this), config.lpSupply);
        if (config.supply > config.lpSupply) _mint(config.owner, config.supply - config.lpSupply);
        emit TaxBpsSet(config.taxBps);
        emit FeeRecipientSet(config.feeRecipient);
        emit FeeDecayRecipientSet(config.feeDecayRecipient);
    }

    /// @notice The shared hook bound permanently in this clone's runtime code.
    function hook() public view returns (address) {
        return _cloneAddress(0);
    }

    /// @notice Zero for native ETH, an eligible native-paired ERC20T, or a hook-approved external base.
    function quoteToken() public view returns (address) {
        return _cloneAddress(20);
    }

    function poolManager() public view returns (IPoolManager) {
        return IPoolManager(_cloneAddress(40));
    }

    function positionManager() public view returns (IPositionManager) {
        return IPositionManager(_cloneAddress(60));
    }

    function permit2() public view returns (IAllowanceTransfer) {
        return IAllowanceTransfer(_cloneAddress(80));
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Whether a contract is approved locally or through the optional shared registry.
    function isDistributor(address account) public view returns (bool) {
        return isLocalDistributor[account] || (useGlobalDistributors && IERC20THook(hook()).isDistributor(account));
    }

    /// @notice Add or remove distribution contracts in a single transaction.
    /// @dev An approved contract can transfer to or from any wallet, so only approve trusted code.
    function setDistributors(address[] calldata accounts, bool allowed) external onlyOwner {
        address manager = address(poolManager());
        address tokenHook = hook();
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (
                account == address(0) || account == address(this) || account == manager || account == tokenHook
                    || (allowed && account.code.length == 0)
            ) revert InvalidAddress();
            isLocalDistributor[account] = allowed;
            emit DistributorSet(account, allowed);
        }
    }

    /// @notice Current buy and sell tax, including the protocol share, in basis points.
    /// @dev An enabled launch rate starts at 99%, drops by 100 bps per completed interval,
    ///      and clamps to the resting rate.
    ///      Before launch, a configured schedule reports its starting rate without advancing time.
    function taxBps() public view returns (uint16) {
        uint16 startingRate = launchTaxBps;
        if (startingRate == 0) return restingTaxBps;
        if (!launched) return startingRate;
        uint256 steps = (block.timestamp - launchedAt) / taxDecayIntervalSeconds;
        if (steps >= _taxDecaySteps) return restingTaxBps;
        return uint16(uint256(startingRate) - steps * TAX_DECAY_STEP_BPS);
    }

    /// @notice Whether an already-launched token is still in its automatic tax decline.
    function taxDecayActive() public view returns (bool) {
        return
            launched && launchTaxBps != 0 && (block.timestamp - launchedAt) / taxDecayIntervalSeconds < _taxDecaySteps;
    }

    /// @notice Set the resting/fixed tax from 30 to 500 bps, except during an active launch decline.
    /// @dev Before launch, the resting rate cannot exceed the configured starting rate.
    ///      After the schedule finishes, manual tax changes do not restart it.
    function setTaxBps(uint16 newTaxBps) external onlyOwner {
        _validateTax(newTaxBps);
        if (taxDecayActive()) revert TaxDecayActive();
        if (!launched && launchTaxBps != 0) {
            if (newTaxBps > launchTaxBps) revert InvalidTaxDecayConfiguration();
            _taxDecaySteps = _stepsToRest(launchTaxBps, newTaxBps);
            emit LaunchTaxConfigured(launchTaxBps, newTaxBps, taxDecayIntervalSeconds);
        }
        restingTaxBps = newTaxBps;
        emit TaxBpsSet(newTaxBps);
    }

    /// @notice Set the recipient of the resting tax's ETH share after the included protocol fee.
    /// @dev Does not change the independently configured launch-decay recipient.
    function setFeeRecipient(address recipient) external onlyOwner {
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(poolManager())
                || recipient == hook()
        ) revert InvalidAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Set the ETH recipient for the temporary tax above the resting rate.
    function setFeeDecayRecipient(address recipient) external onlyOwner {
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(poolManager())
                || recipient == hook()
        ) revert InvalidAddress();
        feeDecayRecipient = recipient;
        emit FeeDecayRecipientSet(recipient);
    }

    /// @notice Opt into or out of all distribution contracts approved by the hook owner.
    function setUseGlobalDistributors(bool enabled) external onlyOwner {
        useGlobalDistributors = enabled;
        emit UseGlobalDistributorsSet(enabled);
    }

    /// @notice Allow anyone to add liquidity to this token's canonical pool.
    function setExternalLiquidityEnabled(bool enabled) external onlyOwner {
        externalLiquidityEnabled = enabled;
        emit ExternalLiquidityEnabledSet(enabled);
    }

    /// @notice Allow this native-paired token to serve as the quote currency for new ERC20T pools.
    /// @dev ERC20T-quoted tokens cannot enable pairing. Disabling prevents new pairs; existing pairs remain usable.
    function setPairingEnabled(bool enabled) external onlyOwner {
        if (enabled && quoteToken() != address(0)) revert InvalidQuoteToken();
        pairingEnabled = enabled;
        emit PairingEnabledSet(enabled);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Initialize the quote/token pool and lock the token reserve in a single-sided position.
    /// @dev Start at/below the lower sqrt price for token0, or at/above the upper for token1.
    ///      Unused native currency is returned to the owner; token rounding dust stays locked here.
    function launch(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) external payable onlyOwner nonReentrant {
        if (launched) revert AlreadyLaunched();
        address quote = quoteToken();
        if (quote != address(0) && msg.value != 0) revert NativeValueNotAllowed();
        uint256 tokenAmount = balanceOf(address(this));
        if (tokenAmount == 0) revert NoLpSupply();
        if (tokenAmount > type(uint128).max || msg.value > type(uint128).max) revert AmountTooLarge();
        if (
            tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK || tickLower >= tickUpper
                || tickLower % ERC20T_TICK_SPACING != 0 || tickUpper % ERC20T_TICK_SPACING != 0
                || sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
        ) revert InvalidRange();
        bool tokenIsCurrency0 = address(this) < quote;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tokenIsCurrency0 ? sqrtPriceX96 > sqrtLower : sqrtPriceX96 < sqrtUpper) revert InvalidRange();
        uint128 liquidity = tokenIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, tokenAmount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, tokenAmount);
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidLiquidity();

        launched = true;
        launchedAt = uint64(block.timestamp);
        if (launchTaxBps != 0) emit TaxDecayStarted(launchedAt);
        assembly ("memory-safe") {
            tstore(LAUNCHING_SLOT, 1)
        }
        _seedPool(sqrtPriceX96, tickLower, tickUpper, liquidity, tokenAmount);

        uint256 dust = balanceOf(address(this));
        emit Launched(sqrtPriceX96, tickLower, tickUpper, liquidity, tokenAmount - dust);
    }

    function _seedPool(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenAmount)
        private
    {
        IAllowanceTransfer tokenPermit2 = permit2();
        IPositionManager tokenPositionManager = positionManager();
        _approve(address(this), address(tokenPermit2), tokenAmount);
        tokenPermit2.approve(
            address(this), address(tokenPositionManager), uint160(tokenAmount), uint48(block.timestamp)
        );

        PoolKey memory key = poolKey();
        bool nativeQuote = Currency.unwrap(key.currency0) == address(0);
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == address(this);
        bytes memory actions = nativeQuote
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory mintParams = new bytes[](nativeQuote ? 3 : 2);
        uint128 amount0Max = tokenIsCurrency0 ? uint128(tokenAmount) : uint128(msg.value);
        uint128 amount1Max = tokenIsCurrency0 ? 0 : uint128(tokenAmount);
        mintParams[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, DEAD_ADDRESS, bytes(""));
        mintParams[1] = abi.encode(key.currency0, key.currency1);
        if (nativeQuote) mintParams[2] = abi.encode(key.currency0, owner());

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, sqrtPriceX96);
        params[1] = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp
        );
        tokenPositionManager.multicall{value: msg.value}(params);

        assembly ("memory-safe") {
            tstore(LAUNCHING_SLOT, 0)
        }
        tokenPermit2.approve(address(this), address(tokenPositionManager), 0, 0);
        _approve(address(this), address(tokenPermit2), 0);
    }

    /// @notice True only during launch, allowing the hook to authorize initialization and seeding.
    function launching() external view returns (bool isLaunching) {
        assembly ("memory-safe") {
            isLaunching := tload(LAUNCHING_SLOT)
        }
    }

    function poolKey() public view returns (PoolKey memory) {
        address quote = quoteToken();
        bool tokenIsCurrency0 = address(this) < quote;
        return PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? address(this) : quote),
            currency1: Currency.wrap(tokenIsCurrency0 ? quote : address(this)),
            fee: ERC20T_POOL_FEE,
            tickSpacing: ERC20T_TICK_SPACING,
            hooks: IHooks(hook())
        });
    }

    /// @notice Authorize a fee transfer independently of net user settlement.
    /// @dev The hook grants and consumes this allowance within the same callback.
    /// @param fromPoolManager True for withdrawals, false for deposits.
    function increaseTransferAllowance(uint256 amount, bool fromPoolManager) external {
        if (msg.sender != hook()) revert OnlyHook();
        uint256 slot = fromPoolManager ? FROM_POOL_MANAGER_SLOT : TO_POOL_MANAGER_SLOT;
        uint256 gross;
        assembly ("memory-safe") {
            gross := tload(slot)
        }
        uint256 increased = gross + amount;
        assembly ("memory-safe") {
            tstore(slot, increased)
        }
        emit AllowanceIncreased(amount, fromPoolManager);
    }

    function getTransferAllowance(bool fromPoolManager) public view returns (uint256 amount) {
        uint256 slot = fromPoolManager ? FROM_POOL_MANAGER_SLOT : TO_POOL_MANAGER_SLOT;
        assembly ("memory-safe") {
            amount := tload(slot)
        }
        int256 net = getNetTransferAllowance();
        if (fromPoolManager && net > 0) amount += uint256(net);
        else if (!fromPoolManager && net < 0) amount += uint256(-net);
    }

    /// @notice Net user settlement across canonical pools; intermediate route tokens cancel out.
    /// @dev Positive deltas allow withdrawals from PoolManager; negative deltas allow deposits.
    function accountTransferDelta(int128 delta) external {
        if (msg.sender != hook()) revert OnlyHook();
        int256 net = getNetTransferAllowance() + int256(delta);
        assembly ("memory-safe") {
            tstore(NET_TRANSFER_SLOT, net)
        }
        emit TransferDeltaAccounted(delta, net);
    }

    function getNetTransferAllowance() public view returns (int256 net) {
        assembly ("memory-safe") {
            net := tload(NET_TRANSFER_SLOT)
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) return;

        // PoolManager is checked before owner/distributor exemptions to protect other v4 pools.
        address manager = address(poolManager());
        if (from == manager || to == manager) {
            bool fromManager = from == manager;
            uint256 slot = fromManager ? FROM_POOL_MANAGER_SLOT : TO_POOL_MANAGER_SLOT;
            uint256 gross;
            assembly ("memory-safe") {
                gross := tload(slot)
            }
            uint256 grossSpent = amount < gross ? amount : gross;
            assembly ("memory-safe") {
                tstore(slot, sub(gross, grossSpent))
            }
            if (amount > grossSpent) _spendNetAllowance(amount - grossSpent, fromManager);
            emit AllowanceSpent(from, to, amount);
            return;
        }

        address tokenOwner = owner();
        if (from == tokenOwner || to == tokenOwner || isDistributor(from) || isDistributor(to)) return;

        // Only direct wallet calls qualify: no contract callers, constructors or delegated accounts.
        if (msg.sender == from && msg.sender == tx.origin && from.code.length == 0 && to.code.length == 0) return;
        revert InvalidTransfer();
    }

    function _validateTax(uint16 bps) private pure {
        if (bps < MIN_TAX_BPS || bps > MAX_TAX_BPS) revert InvalidTax();
    }

    function _configureLaunchTax(uint16 startingRate, uint32 intervalSeconds) private {
        if (startingRate == 0 && intervalSeconds == 0) return;
        if (startingRate != LAUNCH_TAX_BPS || intervalSeconds == 0) {
            revert InvalidTaxDecayConfiguration();
        }
        launchTaxBps = startingRate;
        taxDecayIntervalSeconds = intervalSeconds;
        _taxDecaySteps = _stepsToRest(startingRate, restingTaxBps);
        emit LaunchTaxConfigured(startingRate, restingTaxBps, intervalSeconds);
    }

    function _stepsToRest(uint16 startingRate, uint16 restingRate) private pure returns (uint8) {
        // 9,900 -> 30 bps takes at most 99 intervals; the uint16 sum and uint8 result both fit.
        return uint8((startingRate - restingRate + TAX_DECAY_STEP_BPS - 1) / TAX_DECAY_STEP_BPS);
    }

    function _spendNetAllowance(uint256 amount, bool fromManager) private {
        int256 net = getNetTransferAllowance();
        if (fromManager) {
            if (net <= 0 || amount > uint256(net)) revert InvalidTransfer();
            net -= int256(amount);
        } else {
            if (net >= 0 || amount > uint256(-net)) revert InvalidTransfer();
            net += int256(amount);
        }
        assembly ("memory-safe") {
            tstore(NET_TRANSFER_SLOT, net)
        }
    }

    /// @dev Use explicit, revocable ERC20 approvals, including for canonical Permit2.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @dev Each argument is a packed 20-byte address after the 45-byte delegate runtime.
    ///      Read the clone's code, so delegatecalls use the calling token's immutable arguments.
    function _cloneAddress(uint256 offset) private view returns (address result) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0x00, add(45, offset), 20)
            result := shr(96, mload(0x00))
        }
    }
}
