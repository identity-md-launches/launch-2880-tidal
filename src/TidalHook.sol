// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TidalToken} from "./TidalToken.sol";

/// @notice ETH/TIDAL hook with immutable fee rules and segregated treasury / buyback accounting.
/// @dev Single pool. The hook's fee is additional to the launch policy's static LP fee.
///      Native-specified swaps must fill their adjusted specified amount; see README for routing.
contract TidalHook is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    uint24 public constant FEE_DENOMINATOR = 1_000_000;
    uint24 public constant BASE_FEE = 3_000;
    uint24 public constant MAX_DYNAMIC_FEE = 20_000;
    uint24 public constant INITIAL_LAUNCH_FEE = 200_000;
    uint256 public constant LAUNCH_BLOCKS = 20;
    uint256 public constant VOLATILITY_BLOCKS = 8;
    uint256 public constant PIPS_PER_TICK = 50;
    uint256 public constant MAX_BUCKET_TICKS = (MAX_DYNAMIC_FEE - BASE_FEE) / PIPS_PER_TICK;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant MAX_BUYBACK_DEADLINE = 30 minutes;

    IPoolManager public immutable poolManager;
    TidalToken public immutable token;
    address public immutable factory;
    PoolId public immutable poolId;
    address public treasury;
    bool public initialized;
    uint256 public launchBlock;
    int24 public lastTick;

    struct Observation {
        uint64 blockNumber;
        uint64 tickMovement;
    }

    Observation[8] public observations;

    uint256 public treasuryAccrued;
    uint256 public buybackAccrued;
    uint256 public claimsOutstanding;
    uint256 public totalFeesCollected;
    uint256 public totalTreasuryPaid;
    uint256 public totalBuybackSpent;
    uint256 public totalTokensBurned;

    enum Action {
        None,
        Redeem,
        Buyback
    }
    Action private activeAction;

    error ZeroAddress();
    error OnlyPoolManager();
    error OnlyFactory();
    error WrongPool();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidAmount();
    error NoTrade();
    error NativeSpecifiedNotFilled();
    error InvalidTreasury();
    error NothingToClaim();
    error NativeTransferFailed();
    error InvalidUnlock();
    error InvalidBuybackBounds();
    error TooLittleReceived();
    error SettlementMismatch();
    error RenounceDisabled();

    event PoolOpened(PoolId indexed id, uint256 indexed blockNumber, int24 tick);
    event FeeCollected(
        uint24 rate, uint256 amount, uint256 treasuryShare, uint256 buybackShare, bool asClaim
    );
    event PriceObserved(uint256 indexed blockNumber, int24 tick, uint256 blockMovement);
    event TreasuryChanged(address indexed previous, address indexed next);
    event TreasuryPaid(address indexed recipient, uint256 amount);
    event ClaimsRedeemed(uint256 amount);
    event BuybackBurned(uint256 ethSpent, uint256 tokensBurned);

    /// @param manager_ Manifest: $poolManager. No external calls are made in construction.
    /// @param token_ Manifest: $token, the TidalToken deployed immediately before this hook.
    /// @param initialOwner Manifest: $owner, also the initial treasury recipient.
    /// @param factory_ Manifest: $factory, the only permitted pool initializer.
    constructor(IPoolManager manager_, TidalToken token_, address initialOwner, address factory_)
        Ownable(initialOwner)
    {
        if (address(manager_) == address(0) || address(token_) == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = manager_;
        token = token_;
        factory = factory_;
        treasury = initialOwner;
        poolId = getPoolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    /// @notice Required low address bits: 0x10cc. All liquidity callbacks are disabled.
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function getPoolKey() public view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            LP_FEE,
            TICK_SPACING,
            IHooks(address(this))
        );
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        _checkPool(key);
        initialized = true;
        launchBlock = block.number;
        lastTick = tick;
        emit PoolOpened(poolId, block.number, tick);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Linear 20%, 19%, ... 1%, 0% launch surcharge, in fee-pips.
    function launchFeePips() public view returns (uint24) {
        _requireInitialized();
        uint256 age = block.number - launchBlock;
        if (age >= LAUNCH_BLOCKS) return 0;
        return uint24(INITIAL_LAUNCH_FEE * (LAUNCH_BLOCKS - age) / LAUNCH_BLOCKS);
    }

    /// @notice Recent absolute log-price movement, with each block's contribution fading over 8 blocks.
    /// @dev This is a fee signal, not a fair-value oracle. Each block's movement is saturated at 340 ticks.
    function dynamicFeePips() public view returns (uint24) {
        _requireInitialized();
        uint256 weightedMovement = 0;
        for (uint256 i; i < VOLATILITY_BLOCKS; ++i) {
            Observation memory o = observations[i];
            uint256 age = block.number - o.blockNumber;
            if (age < VOLATILITY_BLOCKS) {
                weightedMovement += uint256(o.tickMovement) * (VOLATILITY_BLOCKS - age);
            }
        }
        uint256 premium = weightedMovement * PIPS_PER_TICK / VOLATILITY_BLOCKS;
        uint256 maxPremium = MAX_DYNAMIC_FEE - BASE_FEE;
        if (premium > maxPremium) premium = maxPremium;
        return uint24(BASE_FEE + premium);
    }

    function quoteFeePips() public view returns (uint24) {
        return dynamicFeePips() + launchFeePips();
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 amount = _specifiedAmount(params.amountSpecified);
        uint24 rate = quoteFeePips();
        int128 fee = 0;
        if (_nativeIsSpecified(params)) {
            uint256 charged = params.zeroForOne ? amount * rate / FEE_DENOMINATOR : _grossUpFee(amount, rate);
            // A sell requests net ETH output: its underlying swap must produce output plus the fee.
            if (!params.zeroForOne && amount + charged > uint256(uint128(type(int128).max))) {
                revert InvalidAmount();
            }
            fee = charged.toInt128();
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        uint256 amount = _specifiedAmount(params.amountSpecified);
        uint24 rate = quoteFeePips();
        int128 nativeDelta = delta.amount0();
        // Never collect a charge for a trade that delivers no output.
        if (params.zeroForOne) {
            if (nativeDelta >= 0 || delta.amount1() <= 0) revert NoTrade();
        } else if (nativeDelta <= 0 || delta.amount1() >= 0) {
            revert NoTrade();
        }
        uint256 nativeAmount =
            params.zeroForOne ? uint256(-int256(nativeDelta)) : uint256(uint128(nativeDelta));
        uint256 fee;
        int128 afterDelta = 0;
        if (_nativeIsSpecified(params)) {
            fee = params.zeroForOne ? amount * rate / FEE_DENOMINATOR : _grossUpFee(amount, rate);
            uint256 expected = params.zeroForOne ? amount - fee : amount + fee;
            // v4 can only adjust the unspecified side in afterSwap. Revert partial native-specified
            // fills instead of taxing an unfilled amount or breaking an exact-output guarantee.
            if (nativeAmount != expected) revert NativeSpecifiedNotFilled();
        } else {
            fee = params.zeroForOne ? _grossUpFee(nativeAmount, rate) : nativeAmount * rate / FEE_DENOMINATOR;
            if (params.zeroForOne && nativeAmount + fee > uint256(uint128(type(int128).max))) {
                revert InvalidAmount();
            }
            afterDelta = fee.toInt128();
        }
        _collectFee(fee, rate);
        _observe();
        return (IHooks.afterSwap.selector, afterDelta);
    }

    /// @notice Update the recipient of accrued and future treasury fees. Does not alter the 50/50 split.
    function setTreasury(address next) external nonReentrant onlyOwner {
        if (
            next == address(0) || next == address(this) || next == address(poolManager)
                || next == address(token)
        ) {
            revert InvalidTreasury();
        }
        emit TreasuryChanged(treasury, next);
        treasury = next;
    }

    /// @notice Anyone may deliver the treasury balance to the configured treasury, never to themselves.
    /// @dev A rejecting recipient only reverts this claim. Swaps and buybacks remain live.
    function claimTreasury() external nonReentrant returns (uint256 amount) {
        amount = treasuryAccrued;
        if (amount == 0) revert NothingToClaim();
        treasuryAccrued = 0;
        totalTreasuryPaid += amount;
        address recipient = treasury;
        if (address(this).balance < amount) _redeem(amount - address(this).balance);
        emit TreasuryPaid(recipient, amount);
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }

    /// @notice Convert this hook's ETH ERC-6909 claims to ETH held by the hook. Permissionless, no payout.
    function redeemClaims(uint256 amount) external nonReentrant {
        _redeem(amount);
    }

    /// @notice Spend only the buyback allocation, buy TIDAL in this pool, and destroy the acquired tokens.
    /// @dev The owner supplies an independently chosen minimum output and a nonzero price limit.
    ///      Partial fills retain unspent ETH in buybackAccrued. No caller receives tokens or refunds.
    function executeBuyback(
        uint256 maxEthIn,
        uint256 minTokensOut,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external nonReentrant onlyOwner returns (uint256 spent, uint256 burned) {
        _requireInitialized();
        if (maxEthIn == 0 || maxEthIn > buybackAccrued || maxEthIn > uint256(uint128(type(int128).max))) {
            revert InvalidAmount();
        }
        if (
            minTokensOut == 0 || deadline < block.timestamp
                || deadline - block.timestamp > MAX_BUYBACK_DEADLINE
        ) {
            revert InvalidBuybackBounds();
        }
        (uint160 currentPrice,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceLimitX96 >= currentPrice) {
            revert InvalidBuybackBounds();
        }
        buybackAccrued -= maxEthIn;
        activeAction = Action.Buyback;
        (spent, burned) = abi.decode(
            poolManager.unlock(abi.encode(maxEthIn, minTokensOut, sqrtPriceLimitX96)), (uint256, uint256)
        );
        activeAction = Action.None;
        buybackAccrued += maxEthIn - spent;
        // Totals are updated in the callback before the token's burn call.
        emit BuybackBurned(spent, burned);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        Action action = activeAction;
        // Consume the authorization before making any interaction.
        activeAction = Action.None;
        if (action == Action.Redeem) {
            uint256 amount = abi.decode(data, (uint256));
            _burnClaims(amount);
            poolManager.take(Currency.wrap(address(0)), address(this), amount);
            return abi.encode(amount);
        }
        if (action != Action.Buyback) revert InvalidUnlock();
        (uint256 budget, uint256 minTokens, uint160 limit) = abi.decode(data, (uint256, uint256, uint160));
        BalanceDelta delta = poolManager.swap(getPoolKey(), SwapParams(true, -int256(budget), limit), "");
        if (delta.amount0() >= 0 || delta.amount1() <= 0) revert NoTrade();
        uint256 spent = uint256(-int256(delta.amount0()));
        uint256 bought = uint256(uint128(delta.amount1()));
        if (spent > budget) revert InvalidAmount();
        if (bought < minTokens) revert TooLittleReceived();
        totalBuybackSpent += spent;
        totalTokensBurned += bought;
        _payNative(spent);
        poolManager.take(Currency.wrap(address(token)), address(this), bought);
        token.burn(bought);
        // PoolManager intentionally skips a hook's callbacks on its own swaps; observe explicitly.
        _observe();
        return abi.encode(spent, bought);
    }

    /// @dev Prevent permanently disabling the only role able to operate price-bounded buybacks.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    receive() external payable onlyPoolManager {}

    function _collectFee(uint256 fee, uint24 rate) private {
        if (fee == 0) return;
        // Carry odd wei across swaps: cumulative treasury = floor(totalFees / 2), buyback = ceil(...).
        uint256 oldTotal = totalFeesCollected;
        uint256 treasuryPart = (oldTotal + fee) / 2 - oldTotal / 2;
        totalFeesCollected = oldTotal + fee;
        treasuryAccrued += treasuryPart;
        buybackAccrued += fee - treasuryPart;
        bool asClaim = address(poolManager).balance < fee;
        if (asClaim) {
            claimsOutstanding += fee;
            poolManager.mint(address(this), 0, fee);
        } else {
            poolManager.take(Currency.wrap(address(0)), address(this), fee);
        }
        emit FeeCollected(rate, fee, treasuryPart, fee - treasuryPart, asClaim);
    }

    function _observe() private {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int256 difference = int256(tick) - lastTick;
        uint256 movement = uint256(difference < 0 ? -difference : difference);
        lastTick = tick;
        Observation storage o = observations[block.number % VOLATILITY_BLOCKS];
        if (o.blockNumber != block.number) {
            // Real chain block numbers fit uint64. Refuse to truncate a future unsupported chain.
            if (block.number > type(uint64).max) revert InvalidAmount();
            o.blockNumber = uint64(block.number);
            o.tickMovement = 0;
        }
        movement += o.tickMovement;
        if (movement > MAX_BUCKET_TICKS) movement = MAX_BUCKET_TICKS;
        o.tickMovement = uint64(movement);
        emit PriceObserved(block.number, tick, movement);
    }

    function _redeem(uint256 amount) private {
        if (amount == 0 || amount > claimsOutstanding) revert InvalidAmount();
        activeAction = Action.Redeem;
        uint256 redeemed = abi.decode(poolManager.unlock(abi.encode(amount)), (uint256));
        if (redeemed != amount) revert SettlementMismatch();
        activeAction = Action.None;
        emit ClaimsRedeemed(amount);
    }

    function _burnClaims(uint256 amount) private {
        claimsOutstanding -= amount;
        poolManager.burn(address(this), 0, amount);
    }

    function _payNative(uint256 amount) private {
        uint256 fromClaims = amount < claimsOutstanding ? amount : claimsOutstanding;
        if (fromClaims > 0) _burnClaims(fromClaims);
        uint256 remainder = amount - fromClaims;
        if (remainder > 0) {
            // Clear any prior ERC-20 sync before native settlement.
            poolManager.sync(Currency.wrap(address(0)));
            if (poolManager.settle{value: remainder}() != remainder) revert SettlementMismatch();
        }
    }

    function _specifiedAmount(int256 specified) private pure returns (uint256) {
        if (specified == 0 || specified > int256(type(int128).max) || specified < -int256(type(int128).max)) {
            revert InvalidAmount();
        }
        return uint256(specified < 0 ? -specified : specified);
    }

    function _nativeIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _grossUpFee(uint256 amount, uint24 rate) private pure returns (uint256) {
        uint256 denominator = FEE_DENOMINATOR - rate;
        return (amount * rate + denominator - 1) / denominator;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _requireInitialized() private view {
        if (!initialized) revert NotInitialized();
    }
}
