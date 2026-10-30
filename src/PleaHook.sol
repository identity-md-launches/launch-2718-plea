// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PleaCourt} from "./PleaCourt.sol";
import {Letterbox} from "./Letterbox.sol";
import {IPleaCourt} from "./interfaces/IPleaCourt.sol";

/// @title PleaHook
/// @notice The Uniswap v4 hook of the PLEA / IMD pool. Buying PLEA is always open. Selling PLEA into the
/// pool is only possible through `sell`, which spends an approved plea's 7-minute sale window, until the
/// dead-man switch frees trading forever. The court it creates holds every plea, verdict, objection,
/// season and the IMD prize pot; the letterbox the court creates takes pleas on a seller's behalf.
/// @dev Callbacks: beforeInitialize (bind the launch pool, from the factory only), beforeAddLiquidity
/// (the factory and allowlisted providers only, so single-sided PLEA liquidity cannot bypass the gate),
/// beforeSwap (the gate). No remove-liquidity callbacks, so the factory's fee collect is untouched.
contract PleaHook is IUnlockCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Largest pot fee the owner may set on sell proceeds: 10%.
    uint16 public constant MAX_POT_FEE_BPS = 1000;
    uint16 public constant BPS = 10_000;

    error NotPoolManager();
    error NotFactory();
    error AlreadyBound();
    error NotBound();
    error WrongPool();
    error SellRequiresPlea();
    error LiquidityRestricted();
    error FeeTooHigh();
    error ZeroAmount();
    error InsufficientOutput(uint256 received, uint256 minimum);
    error HookAddressMismatch();

    event PoolBound(PoolKey key, address indexed paired, bool tokenIsCurrency0);
    event PotFeeSet(uint16 bps);
    event LiquidityProviderSet(address indexed provider, bool allowed);
    event SellExecuted(
        uint256 indexed saleId, address indexed seller, uint256 amountIn, uint256 amountOut, uint256 fee, bool free
    );

    IPoolManager public immutable poolManager;
    /// @notice The launch token, PLEA.
    address public immutable token;
    /// @notice The launch factory: the only sender that may initialize the pool, and an LP by right.
    address public immutable factory;
    /// @notice The court created by this hook: pleas, verdicts, seasons, pot.
    PleaCourt public immutable court;

    PoolKey private _poolKey;
    bool public bound;
    bool public tokenIsCurrency0;
    /// @notice The pair currency, IMD, read from the pool key when the pool is initialized.
    Currency public paired;
    /// @notice Share of every gated sale's IMD proceeds sent to the court's prize pot, in basis points.
    uint16 public potFeeBps;
    /// @notice Addresses besides the factory that may add liquidity.
    mapping(address => bool) public liquidityProviders;

    /// @dev Transient-storage slot set while `sell` drives a swap, so beforeSwap knows the hook itself is the sender.
    bytes32 private constant SELLING_SLOT = keccak256("plea.hook.selling");

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address token_, address owner_, address factory_) Ownable(owner_) {
        poolManager = poolManager_;
        token = token_;
        factory = factory_;
        court = new PleaCourt(address(this));
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ------------------------------------------------------------------ permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ callbacks

    /// @notice Binds the launch pool: PLEA against the pair currency, opened by the factory. Once.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert NotFactory();
        if (bound) revert AlreadyBound();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != token && c1 != token) revert WrongPool();
        bound = true;
        tokenIsCurrency0 = c0 == token;
        paired = tokenIsCurrency0 ? key.currency1 : key.currency0;
        _poolKey = key;
        court.bind(Currency.unwrap(paired));
        emit PoolBound(key, Currency.unwrap(paired), tokenIsCurrency0);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Only the factory and allowlisted providers add liquidity, until trading is free.
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory && !liquidityProviders[sender] && !court.tradesFreely()) revert LiquidityRestricted();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Buys always pass. Sells pass only from this hook's own `sell`, or once trading is free.
    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isSell = params.zeroForOne == tokenIsCurrency0;
        if (isSell && !(sender == address(this) && _isSelling()) && !court.tradesFreely()) revert SellRequiresPlea();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ------------------------------------------------------------------ selling

    /// @notice Sells `amountIn` PLEA for IMD through the pool, inside the caller's approved sale window.
    /// The pot fee comes off the IMD proceeds; the rest goes to the caller, who must receive `minOut`.
    /// Once the dead-man switch has fired, no plea is needed (any router works then too).
    function sell(uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 saleId, uint256 amountOut) {
        if (!bound) revert NotBound();
        if (amountIn == 0) revert ZeroAmount();
        bool free = court.tradesFreely();
        if (!free) saleId = court.authorizeSale(msg.sender, amountIn);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        _setSelling(true);
        bytes memory result = poolManager.unlock(abi.encode(msg.sender, amountIn, minOut));
        _setSelling(false);
        (uint256 consumed, uint256 out, uint256 fee) = abi.decode(result, (uint256, uint256, uint256));
        if (consumed < amountIn) IERC20(token).safeTransfer(msg.sender, amountIn - consumed);
        amountOut = out - fee;
        emit SellExecuted(saleId, msg.sender, consumed, amountOut, fee, free);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address seller, uint256 amountIn, uint256 minOut) = abi.decode(data, (address, uint256, uint256));
        bool zeroForOne = tokenIsCurrency0;
        BalanceDelta delta = poolManager.swap(
            _poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 tokenDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 pairedDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 consumed = uint256(uint128(-tokenDelta));
        uint256 out = uint256(uint128(pairedDelta));
        uint256 fee = out * potFeeBps / BPS;
        if (out - fee < minOut) revert InsufficientOutput(out - fee, minOut);

        Currency tokenCurrency = Currency.wrap(token);
        poolManager.sync(tokenCurrency);
        IERC20(token).safeTransfer(address(poolManager), consumed);
        poolManager.settle();
        if (fee > 0) poolManager.take(paired, address(court), fee);
        if (out - fee > 0) poolManager.take(paired, seller, out - fee);
        return abi.encode(consumed, out, fee);
    }

    function _setSelling(bool on) private {
        bytes32 slot = SELLING_SLOT;
        assembly ("memory-safe") {
            tstore(slot, on)
        }
    }

    function _isSelling() private view returns (bool on) {
        bytes32 slot = SELLING_SLOT;
        assembly ("memory-safe") {
            on := tload(slot)
        }
    }

    // ------------------------------------------------------------------ owner

    /// @notice Sets the share of gated sale proceeds that funds the season prize pot (max 10%).
    function setPotFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_POT_FEE_BPS) revert FeeTooHigh();
        potFeeBps = bps;
        emit PotFeeSet(bps);
    }

    /// @notice Allows or disallows an address (a position manager, say) to add liquidity.
    function setLiquidityProvider(address provider, bool allowed) external onlyOwner {
        liquidityProviders[provider] = allowed;
        emit LiquidityProviderSet(provider, allowed);
    }

    // ------------------------------------------------------------------ views for the frontend

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function letterbox() external view returns (Letterbox) {
        return court.letterbox();
    }

    function pleaStatus(uint256 pleaId) external view returns (IPleaCourt.Status) {
        return court.pleaStatus(pleaId);
    }

    function saleWindowExpiry(address seller) external view returns (uint64 expiry, uint256 remaining) {
        return court.saleWindow(seller);
    }

    function currentSeason() external view returns (uint256 id, uint64 startedAt, uint64 endsAt) {
        return court.currentSeason();
    }

    function leaderboard() external view returns (IPleaCourt.Entry[] memory) {
        return court.leaderboard();
    }

    function deadManTimer() external view returns (uint64 deadline, uint256 secondsLeft, bool triggered) {
        return court.deadManTimer();
    }

    function tradesFreely() external view returns (bool) {
        return court.tradesFreely();
    }
}
