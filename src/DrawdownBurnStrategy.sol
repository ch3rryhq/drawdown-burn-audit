// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {FeeVault} from "./FeeVault.sol";
import {Token} from "./Token.sol";
import {IFeeStrategy} from "./interfaces/IFeeStrategy.sol";

/// @notice The vault's strategy: the further the token's circulating market cap trades below its
///         all-time high, the larger the share of every new reserve fee that buys the token back and
///         burns it. The rest is kept, and laid as a wall of reserve-only liquidity at the price where
///         the circulating market cap would be 60% under its all-time high; only the owner can take it back.
///
///         | below the ATH | burned | to the wall |
///         |---------------|--------|-------------|
///         | at or over it |   0%   |    100%     |
///         | 0 to 20%      |  25%   |     75%     |
///         | 20 to 40%     |  50%   |     50%     |
///         | 40 to 60%     |  75%   |     25%     |
///         | 60% or more   | 100%   |      0%     |
///
/// @dev **The market cap.** In the reserve, with no oracle: the circulating supply -- total supply
///      less the balances of the {excluded} addresses and what this contract holds for burning --
///      times the pool's price at the block's anchor. The block's first call anchors the block at the
///      pool's tick, moved at most {MAX_ANCHOR_STEP} (~2%) from the last anchor; the market cap and the
///      tier are read there, once a block. The ATH ({athMcap}) is the highest hourly close -- the last
///      reading of a clock hour, taken when the next hour's first reading comes -- or the one given at
///      deploy if higher: a wick inside an hour is never an ATH. So a pump cannot buy high or flip a
///      tier within a block. Held to an hour's close, paid for every block -- a round trip through the
///      pool's fee each time -- it can lift the ATH, which lowers the tiers and places a later wall
///      higher; the owner can always take the wall back. Burns and transfers to an excluded address lower the
///      circulating supply, and with it the market cap, as they would on any tracker.
///
///      **Where a fee goes.** Split when it arrives, by its block's tier: the burned share into the
///      {pot}, the rest into {pendingWall}. The pot is spent whatever the tier later reads.
///
///      **Buying.** The whole pot, at most {maxPerBuy}, at most once a block, never more than ~2%
///      above the block's anchor. What it buys is burned by the next call -- the next trade -- or by
///      anyone through {burnHeld}: a buyback and its burn together do not fit in the vault's gas cap,
///      because the token checkpoints every balance, so the two take turns. It runs inside the swap
///      that brought the fee, on the trader's gas, within the vault's 400k cap; anyone may also
///      call {buyback} on their own gas.
///
///      **The wall.** One position, reserve only, {wallWidth} ticks deep, its upper edge at the price
///      where the circulating market cap is {WALL_BPS} of the ATH (60% under it), rounded down to the pool's spacing -- the ATH
///      of when it was laid: it does not follow a later high. Anyone may call {buildWall}, outside a
///      swap and on their own gas, to add what is pending to it; nothing is added while the price is at
///      or inside its top, where a reserve-only position cannot grow. Once the price has crossed it all
///      the way it holds only the token it bought: {buildWall} then takes it out and burns that token,
///      and the next call lays a new wall under the ATH of the day. Token the wall earns as fees is
///      burned too. Only the owner takes the wall out: {withdrawWall} sends both currencies to an
///      address of their choosing, {burnWall} sends its reserve to be bought back and burned, and
///      {moveWall} lays it again under the current ATH.
///
///      **The money.** It owns the vault, as {LiquidityStrategy} did, because the vault can only hand
///      a strategy its whole balance and the bank must stay put. Reserve stays in the vault until a
///      buyback or the wall spends it; {pot} and {pendingWall} only count it. Fees received before it
///      was installed -- the bank -- are never counted. It keeps {LiquidityStrategy}'s owner surface
///      (`reserve`, `vault`, `withdrawFromVault`, `releaseVault`).
// The loop reads at most MAX_EXCLUDED balances of our own token. The timestamp only buckets hours.
// Strict equalities here compare blocks, ticks and zero, never balances an attacker can nudge.
// The buyback's external calls re-enter only through the vault's notification, which returns at
// once while the guard is held: writes after them are not reachable mid-call.
// Unused returns are slot0 fields not needed, unlock's bytes, settle's echo and fee deltas the
// caller delta already includes. Rounding a tick down to the spacing divides then multiplies on purpose.
// slither-disable-start incorrect-equality,reentrancy-no-eth,reentrancy-benign,reentrancy-events,unused-return,divide-before-multiply,calls-loop,timestamp
contract DrawdownBurnStrategy is IFeeStrategy, IUnlockCallback, Ownable2Step, ReentrancyGuardTransient {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BPS = 10_000;
    /// @notice The wall's top: the circulating market cap at 40% of the ATH, 60% under it.
    uint256 public constant WALL_BPS = 4_000;
    /// @notice How far above the block's anchored price a buyback may go: ~2% at 200 ticks.
    int24 public constant MAX_SLIP_TICKS = 200;
    /// @notice How far the anchor may move in one block.
    int24 public constant MAX_ANCHOR_STEP = 200;
    /// @notice Most addresses left out of the circulating supply: each costs a read per block.
    uint256 public constant MAX_EXCLUDED = 8;
    /// @notice Gas a burn needs, checkpoints included, before one is tried inside a swap.
    uint256 internal constant BURN_GAS = 90_000;

    uint8 internal constant BUY = 0;
    uint8 internal constant BUILD = 1;
    uint8 internal constant WITHDRAW = 2;
    uint8 internal constant BURN_WALL = 3;
    uint8 internal constant MOVE_WALL = 4;

    IPoolManager public immutable poolManager;
    FeeVault public immutable vault;
    Token public immutable token;
    address public immutable reserve;
    PoolId public immutable poolId;
    IHooks public immutable hook;

    Currency internal immutable currency0;
    Currency internal immutable currency1;
    uint24 internal immutable lpFee;
    int24 public immutable tickSpacing;

    /// @notice Most reserve a single buyback may spend.
    uint256 public maxPerBuy;
    /// @notice How deep the wall is, in ticks, a multiple of the pool's spacing.
    int24 public wallWidth;
    /// @notice The vault's totalReceived for the reserve already split.
    uint256 public accounted;
    /// @notice Reserve waiting to be spent on buybacks. Held by the vault. Starts at 1 wei, never spent.
    uint256 internal _pot;
    /// @notice Reserve waiting to join the wall. Held by the vault. Starts at 1 wei, never spent.
    uint256 internal _pendingWall;

    /// @notice The highest circulating market cap read, in the reserve.
    uint256 public athMcap;

    address[] internal _excluded;

    struct Anchor {
        uint64 block_;
        int24 tick;
        uint64 lastBuy;
        uint16 burnBps; // the block's tier
        uint32 hour; // the clock hour of the block
    }

    /// @notice The circulating market cap at the last anchor: the running close of its hour.
    uint256 public lastMcap;

    /// @dev One slot, so a trade's first call rewrites it once.
    Anchor public anchor;

    struct Wall {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    Wall public wall;

    /// @dev Packed: the two counters share a slot, so a buyback writes one.
    struct Totals {
        uint128 spent; // reserve
        uint128 burned; // tokens
    }

    Totals internal _totals;

    event NewHigh(uint256 mcap);
    event Split(uint256 burnBps, uint256 toPot, uint256 toWall);
    event BoughtBack(uint256 reserveSpent, uint256 tokensBought);
    event Burned(uint256 tokens);
    event WallBuilt(int24 lower, int24 upper, uint128 liquidity, uint256 reserveAdded);
    event WallBurned(uint256 tokens);
    event WallWithdrawn(address indexed to, uint256 reserve, uint256 tokens);
    event WallSentToBurn(uint256 reserve, uint256 tokens);
    event WallTakenDown(uint256 reserve, uint256 tokens);
    event MaxPerBuySet(uint256 amount);
    event WallWidthSet(int24 ticks);
    event ExcludedSet(address[] excluded);

    error NotVault();
    error NotPoolManager();
    error NotSelf();
    error InvalidMaxPerBuy();
    error InvalidWallWidth();
    error TooManyExcluded();
    error InvalidRecipient();
    error PoolMismatch();
    error Unsettled();
    error PoolLocked();
    error DistributeUnsupported();
    error RenounceDisabled();

    constructor(
        IPoolManager poolManager_,
        FeeVault vault_,
        PoolKey memory key,
        Token token_,
        address reserve_,
        uint256 athMcap_,
        address[] memory excluded_,
        uint256 maxPerBuy_,
        int24 wallWidth_,
        address owner_
    ) Ownable(owner_) {
        // The tiers and the wall are written for the token as currency0: its price is the tick's.
        if (Currency.unwrap(key.currency0) != address(token_) || Currency.unwrap(key.currency1) != reserve_) {
            revert PoolMismatch();
        }

        poolManager = poolManager_;
        vault = vault_;
        token = token_;
        reserve = reserve_;
        hook = key.hooks;
        poolId = key.toId();
        currency0 = key.currency0;
        currency1 = key.currency1;
        lpFee = key.fee;
        tickSpacing = key.tickSpacing;

        _setMaxPerBuy(maxPerBuy_);
        _setWallWidth(wallWidth_);
        accounted = vault_.totalReceived(reserve_);
        _setExcluded(excluded_);
        (, int24 tick,,) = poolManager_.getSlot0(key.toId());
        uint256 mcap = marketCapAt(tick);
        uint256 ath = athMcap_ > mcap ? athMcap_ : mcap;
        athMcap = ath;
        lastMcap = mcap;
        // Every slot a trade writes is written once here, so a trade only ever rewrites it: a first
        // write costs ~20k more, enough to push a buyback inside a swap past the vault's gas cap. The
        // wei of each is never spendable.
        anchor = Anchor(0, tick, 1, uint16(_tierBps(mcap, ath)), uint32(block.timestamp / 1 hours));
        _pot = 1;
        _pendingWall = 1;
        _totals = Totals(1, 1);
    }

    /* ---------------------------------------------------------------- the seam */

    /// @dev Called by the vault inside the hook's afterSwap, gas-capped and failure-swallowed. The
    ///      buyback's own swap calls back here too; that call is ignored.
    function onFeeReceived(address) external {
        if (msg.sender != address(vault)) revert NotVault();
        if (_reentrancyGuardEntered()) return;
        _observe();
        if (!poolManager.isUnlocked()) return;
        // Someone mid-payment has synced a currency; a sync of ours would clobber it.
        if (Currency.unwrap(poolManager.getSyncedCurrency()) != address(0)) return;
        // A buyback and its burn do not both fit in the vault's cap, so they take turns.
        if (token.balanceOf(address(this)) != 0) {
            if (gasleft() > BURN_GAS) _burnHeld();
            return;
        }
        uint256 amount = _due();
        // Kept apart, so a buyback that fails cannot roll back what was just split.
        if (amount != 0) {
            try this.buyInside(amount) {} catch {}
        }
    }

    /// @notice Only this contract, from {onFeeReceived}.
    function buyInside(uint256 amount) external nonReentrant {
        if (msg.sender != address(this)) revert NotSelf();
        _buy(amount);
    }

    /// @notice Run the buyback outside a swap, on the caller's gas. Same rules as inside one.
    function buyback() external nonReentrant {
        if (poolManager.isUnlocked()) revert PoolLocked();
        poolManager.unlock(abi.encode(BUY, address(0)));
    }

    /// @notice Add what is pending to the wall, laying it under the current ATH if there is none; or
    ///         burn it if the price has crossed it all the way. Anyone may.
    function buildWall() external nonReentrant {
        if (poolManager.isUnlocked()) revert PoolLocked();
        poolManager.unlock(abi.encode(BUILD, address(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint8 action, address to) = abi.decode(data, (uint8, address));
        _observe();
        if (action == BUY) {
            uint256 amount = _due();
            if (amount != 0) _buy(amount);
        } else if (action == BUILD) {
            _build();
        } else if (action == BURN_WALL) {
            _burnWall();
        } else if (action == MOVE_WALL) {
            _takeDownWall();
            _build();
        } else {
            _withdrawWall(to);
        }
        _burnHeld();
        return "";
    }

    /// @notice The vault's distribute would hand over the banked balance, so it is refused.
    function onFees(address, uint256) external pure {
        revert DistributeUnsupported();
    }

    /* ---------------------------------------------------------------- the tiers */

    /// @notice The share of a fee burned at market cap `mcap` with the ATH at `ath`, in basis points.
    function tierBps(uint256 mcap, uint256 ath) external pure returns (uint256) {
        return _tierBps(mcap, ath);
    }

    function _tierBps(uint256 mcap, uint256 ath) internal pure returns (uint256) {
        if (mcap >= ath) return 0;
        // Over 80% of the ATH: less than 20% down. Exactly 20% down is the next tier.
        if (mcap * 10 > ath * 8) return 2_500;
        if (mcap * 10 > ath * 6) return 5_000;
        if (mcap * 10 > ath * 4) return 7_500;
        return BPS;
    }

    /// @notice The circulating supply: total supply less the excluded balances and what this
    ///         contract holds for burning.
    function circulatingSupply() public view returns (uint256 supply) {
        supply = token.totalSupply();
        uint256 out = token.balanceOf(address(this));
        address[] memory ex = _excluded;
        for (uint256 i = 0; i < ex.length; i++) {
            out += token.balanceOf(ex[i]);
        }
        supply = supply > out ? supply - out : 0;
    }

    /// @notice The circulating market cap at `tick`'s price, in the reserve.
    function marketCapAt(int24 tick) public view returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(FullMath.mulDiv(circulatingSupply(), sqrtP, 1 << 96), sqrtP, 1 << 96);
    }

    /// @notice The circulating market cap at the pool's price now, in the reserve.
    function marketCap() external view returns (uint256) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return marketCapAt(tick);
    }

    /// @notice The share of this block's fees that is burned, in basis points.
    function currentBurnBps() external view returns (uint256) {
        (Anchor memory a,,) = _anchorNow();
        return a.burnBps;
    }

    /// @notice Where the wall is, or, with none laid, where it would go under the current ATH: its
    ///         top at the price where today's circulating supply is worth {WALL_BPS} of the ATH.
    function wallTarget() public view returns (int24 lower, int24 upper) {
        Wall memory w = wall;
        if (w.liquidity != 0) return (w.lower, w.upper);
        (, uint256 ath,) = _anchorNow();
        uint256 circ = circulatingSupply();
        // price x 2^192 = (ath x WALL_BPS) / circ x 2^192; its square root is the sqrt price, X96.
        uint256 level = ath * WALL_BPS / BPS;
        uint256 sqrtP = circ == 0 ? TickMath.MAX_SQRT_PRICE - 1 : Math.sqrt(FullMath.mulDiv(level, 1 << 192, circ));
        if (sqrtP >= TickMath.MAX_SQRT_PRICE) sqrtP = TickMath.MAX_SQRT_PRICE - 1;
        if (sqrtP < TickMath.MIN_SQRT_PRICE) sqrtP = TickMath.MIN_SQRT_PRICE;
        upper = _floor(TickMath.getTickAtSqrtPrice(uint160(sqrtP)));
        lower = upper - wallWidth;
    }

    function excluded() external view returns (address[] memory) {
        return _excluded;
    }

    /* ---------------------------------------------------------------- splitting */

    /// @dev This block's anchor and the ATH with it, read fresh if the block has none yet.
    function _anchorNow() internal view returns (Anchor memory a, uint256 ath, uint256 mcap) {
        a = anchor;
        ath = athMcap;
        mcap = lastMcap;
        if (a.block_ == block.number) return (a, ath, mcap);
        uint32 hour = uint32(block.timestamp / 1 hours);
        // The first reading of a new hour closes the last one: its last reading is its close.
        if (hour != a.hour && mcap > ath) ath = mcap;
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        tick = _stepped(a, tick);
        mcap = marketCapAt(tick);
        a = Anchor(uint64(block.number), tick, a.lastBuy, uint16(_tierBps(mcap, ath)), hour);
    }

    /// @dev Anchor the block, lift the ATH, read the tier once for it, and split what arrived.
    function _observe() internal {
        Anchor memory a = anchor;
        if (a.block_ != block.number) {
            uint256 ath;
            uint256 mcap;
            (a, ath, mcap) = _anchorNow();
            anchor = a;
            lastMcap = mcap;
            if (ath != athMcap) {
                athMcap = ath;
                emit NewHigh(ath);
            }
        }

        uint256 total = vault.totalReceived(reserve);
        uint256 fresh = total - accounted;
        if (fresh == 0) return;
        accounted = total;
        uint256 toPot = fresh * a.burnBps / BPS;
        _pot += toPot;
        _pendingWall += fresh - toPot;
        emit Split(a.burnBps, toPot, fresh - toPot);
    }

    /// @dev The tick moved at most MAX_ANCHOR_STEP from the last anchor.
    function _stepped(Anchor memory a, int24 tick) internal pure returns (int24) {
        if (a.block_ == 0) return tick;
        if (tick > a.tick + MAX_ANCHOR_STEP) return a.tick + MAX_ANCHOR_STEP;
        if (tick < a.tick - MAX_ANCHOR_STEP) return a.tick - MAX_ANCHOR_STEP;
        return tick;
    }

    /* ---------------------------------------------------------------- buying */

    /// @dev What may be spent now: the whole pot, at most {maxPerBuy}.
    function _due() internal view returns (uint256 amount) {
        if (anchor.lastBuy == block.number) return 0;
        amount = _pot - 1;
        if (amount > maxPerBuy) amount = maxPerBuy;
        uint256 held = IERC20(reserve).balanceOf(address(vault));
        if (amount > held) amount = held;
    }

    function _buy(uint256 amount) internal {
        // Buying the token, currency0, raises the tick.
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int24 at = anchor.tick;
        int24 limit = (tick < at ? tick : at) + MAX_SLIP_TICKS;
        if (limit > TickMath.MAX_TICK - 1) limit = TickMath.MAX_TICK - 1;
        // Already at or past it: nothing this block. v4 would refuse a limit already crossed.
        if (tick >= limit) return;

        BalanceDelta delta = poolManager.swap(
            _key(),
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limit)
            }),
            ""
        );
        uint256 paid = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
        uint256 got = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
        if (paid == 0) return;

        _payFromVault(paid);
        // Held here until a later call burns it: see {onFeeReceived}.
        poolManager.take(currency0, address(this), got);
        _requireSettled();

        _pot -= paid;
        anchor.lastBuy = uint64(block.number);
        _totals.spent += uint128(paid);
        emit BoughtBack(paid, got);
    }

    /// @dev Burn every token this contract holds: what buybacks bought, what the wall gave back,
    ///      and anything sent to it.
    function _burnHeld() internal {
        uint256 held = token.balanceOf(address(this));
        if (held == 0) return;
        token.burn(held);
        _totals.burned += uint128(held);
        emit Burned(held);
    }

    /// @notice Burn what buybacks bought and still hold. Anyone may.
    function burnHeld() external nonReentrant {
        _burnHeld();
    }

    /* ---------------------------------------------------------------- the wall */

    function _build() internal {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        Wall memory w = wall;
        if (w.liquidity != 0 && tick < w.lower) {
            // Crossed all the way: the wall is all token now. Burn it; the wall is laid anew later.
            _modify(w.lower, w.upper, -int256(uint256(w.liquidity)));
            wall = Wall(0, 0, 0);
            int256 fees = poolManager.currencyDelta(address(this), currency1);
            if (fees > 0) {
                _toVault(uint256(fees));
                _pendingWall += uint256(fees);
            }
            uint256 tokens = _takeToken(address(this));
            _requireSettled();
            emit WallBurned(tokens);
            return;
        }
        (int24 lower, int24 upper) = wallTarget();
        // At or inside the wall's top a reserve-only position cannot be added to.
        if (tick < upper) return;
        uint256 pending = _pendingWall - 1;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), pending
        );
        if (liquidity == 0) return;
        // Adding to the position also collects its fees, netted into the same deltas.
        _modify(lower, upper, int256(uint256(liquidity)));
        wall = Wall(lower, upper, w.liquidity + liquidity);

        int256 owed = poolManager.currencyDelta(address(this), currency1);
        uint256 added;
        if (owed < 0) {
            added = uint256(-owed);
            _payFromVault(added);
            _pendingWall -= added;
        } else if (owed > 0) {
            // The fees paid for it all and left some over: back to the vault, as pending.
            _toVault(uint256(owed));
            _pendingWall += uint256(owed);
        }
        _takeToken(address(this));
        _requireSettled();
        emit WallBuilt(lower, upper, liquidity, added);
    }

    /// @dev The whole wall out: its reserve to the pot, to be bought back and burned whatever the
    ///      tier; its token burned at the end of the call.
    function _burnWall() internal {
        Wall memory w = wall;
        if (w.liquidity == 0) return;
        _modify(w.lower, w.upper, -int256(uint256(w.liquidity)));
        wall = Wall(0, 0, 0);
        int256 r = poolManager.currencyDelta(address(this), currency1);
        uint256 reserveOut = r > 0 ? uint256(r) : 0;
        if (reserveOut != 0) {
            _toVault(reserveOut);
            _pot += reserveOut;
        }
        uint256 tokens = _takeToken(address(this));
        _requireSettled();
        emit WallSentToBurn(reserveOut, tokens);
    }

    /// @dev The whole wall out: its reserve back to pending, to be laid again; its token burned at
    ///      the end of the call.
    function _takeDownWall() internal {
        Wall memory w = wall;
        if (w.liquidity == 0) return;
        _modify(w.lower, w.upper, -int256(uint256(w.liquidity)));
        wall = Wall(0, 0, 0);
        int256 r = poolManager.currencyDelta(address(this), currency1);
        uint256 reserveOut = r > 0 ? uint256(r) : 0;
        if (reserveOut != 0) {
            _toVault(reserveOut);
            _pendingWall += reserveOut;
        }
        uint256 tokens = _takeToken(address(this));
        _requireSettled();
        emit WallTakenDown(reserveOut, tokens);
    }

    function _withdrawWall(address to) internal {
        Wall memory w = wall;
        if (w.liquidity != 0) _modify(w.lower, w.upper, -int256(uint256(w.liquidity)));
        wall = Wall(0, 0, 0);
        int256 r = poolManager.currencyDelta(address(this), currency1);
        uint256 reserveOut = r > 0 ? uint256(r) : 0;
        if (reserveOut != 0) poolManager.take(currency1, to, reserveOut);
        uint256 tokensOut = _takeToken(to);
        _requireSettled();
        emit WallWithdrawn(to, reserveOut, tokensOut);
    }

    /// @notice What the wall holds now, in the reserve and in the token, fees not included.
    function wallAmounts() external view returns (uint256 reserveAmount, uint256 tokenAmount) {
        Wall memory w = wall;
        if (w.liquidity == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        uint160 lo = TickMath.getSqrtPriceAtTick(w.lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(w.upper);
        uint160 p = sqrtP < lo ? lo : (sqrtP > hi ? hi : sqrtP);
        tokenAmount = SqrtPriceMath.getAmount0Delta(p, hi, w.liquidity, false);
        reserveAmount = SqrtPriceMath.getAmount1Delta(lo, p, w.liquidity, false);
    }

    function _modify(int24 lower, int24 upper, int256 liquidityDelta) internal {
        poolManager.modifyLiquidity(
            _key(),
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: 0}),
            ""
        );
    }

    /* ---------------------------------------------------------------- reading */

    /// @notice Reserve waiting to be spent on buybacks.
    function pot() external view returns (uint256) {
        return _pot - 1;
    }

    /// @notice Reserve waiting to join the wall.
    function pendingWall() external view returns (uint256) {
        return _pendingWall - 1;
    }

    function totalSpent() external view returns (uint256) {
        return _totals.spent - 1;
    }

    function totalBurned() external view returns (uint256) {
        return _totals.burned - 1;
    }

    /* ---------------------------------------------------------------- the owner */

    function setMaxPerBuy(uint256 amount) external onlyOwner {
        _setMaxPerBuy(amount);
    }

    /// @notice Takes effect the next time the wall is built.
    function setWallWidth(int24 ticks) external onlyOwner {
        _setWallWidth(ticks);
    }

    /// @notice Who is left out of the circulating supply. Changes the market cap from the next block.
    function setExcluded(address[] calldata excluded_) external onlyOwner {
        _setExcluded(excluded_);
    }

    /// @notice Take the whole wall out, both currencies to `to`. What is pending stays pending.
    /// @notice Take the whole wall out and send its reserve to be bought back and burned, whatever
    ///         the tier, at the buyback's usual pace and limits. Token it holds is burned at once.
    function burnWall() external onlyOwner nonReentrant {
        if (poolManager.isUnlocked()) revert PoolLocked();
        poolManager.unlock(abi.encode(BURN_WALL, address(0)));
    }

    /// @notice Take the whole wall out and lay it again, with what is pending, 60% under the current
    ///         ATH. Token it holds is burned. If the price is under the new wall's top, the reserve
    ///         waits as pending for the next {buildWall}.
    function moveWall() external onlyOwner nonReentrant {
        if (poolManager.isUnlocked()) revert PoolLocked();
        poolManager.unlock(abi.encode(MOVE_WALL, address(0)));
    }

    function withdrawWall(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        if (poolManager.isUnlocked()) revert PoolLocked();
        poolManager.unlock(abi.encode(WITHDRAW, to));
    }

    /// @notice Withdraw from the vault. What it takes from the reserve comes out of {pendingWall}
    ///         first, then the pot, as far as the vault no longer covers them.
    function withdrawFromVault(address token_, address to, uint256 amount) external onlyOwner {
        vault.withdraw(token_, to, amount);
        if (token_ != reserve) return;
        uint256 held = IERC20(reserve).balanceOf(address(vault));
        uint256 both = _pot + _pendingWall - 2;
        if (both <= held) return;
        uint256 short = both - held;
        uint256 fromWall = short < _pendingWall - 1 ? short : _pendingWall - 1;
        _pendingWall -= fromWall;
        _pot -= short - fromWall;
    }

    /// @notice Hand the vault back to this contract's owner, to install another strategy. The wall
    ///         stays with this contract until {withdrawWall}.
    function releaseVault() external onlyOwner {
        vault.transferOwnership(owner());
    }

    /// @dev Renouncing would strand the vault and the wall.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /* ---------------------------------------------------------------- plumbing */

    function _setMaxPerBuy(uint256 amount) private {
        if (amount == 0) revert InvalidMaxPerBuy();
        maxPerBuy = amount;
        emit MaxPerBuySet(amount);
    }

    function _setWallWidth(int24 ticks) private {
        if (ticks <= 0 || ticks % tickSpacing != 0 || ticks > 100 * tickSpacing) revert InvalidWallWidth();
        wallWidth = ticks;
        emit WallWidthSet(ticks);
    }

    function _setExcluded(address[] memory excluded_) private {
        if (excluded_.length > MAX_EXCLUDED) revert TooManyExcluded();
        _excluded = excluded_;
        emit ExcludedSet(excluded_);
    }

    /// @dev Pay the pool manager `amount` of the reserve straight from the vault.
    function _payFromVault(uint256 amount) private {
        poolManager.sync(currency1);
        vault.withdraw(reserve, address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev Return reserve to the vault without it reading as a fee.
    function _toVault(uint256 amount) private {
        vault.sync(reserve);
        poolManager.take(currency1, address(vault), amount);
        accounted += vault.sync(reserve);
    }

    /// @dev Take whatever token the pool owes this contract, to `to`.
    function _takeToken(address to) private returns (uint256 amount) {
        int256 d = poolManager.currencyDelta(address(this), currency0);
        if (d <= 0) return 0;
        amount = uint256(d);
        poolManager.take(currency0, to, amount);
    }

    function _requireSettled() private view {
        if (poolManager.currencyDelta(address(this), currency0) != 0) revert Unsettled();
        if (poolManager.currencyDelta(address(this), currency1) != 0) revert Unsettled();
    }

    /// @dev Round down to the pool's spacing, toward minus infinity.
    function _floor(int24 tick) private view returns (int24) {
        int24 s = tickSpacing;
        int24 q = tick / s;
        if (tick < 0 && tick % s != 0) q--;
        return q * s;
    }

    function _key() private view returns (PoolKey memory) {
        return PoolKey({currency0: currency0, currency1: currency1, fee: lpFee, tickSpacing: tickSpacing, hooks: hook});
    }
}
// slither-disable-end incorrect-equality,reentrancy-no-eth,reentrancy-benign,reentrancy-events,unused-return,divide-before-multiply,calls-loop,timestamp
