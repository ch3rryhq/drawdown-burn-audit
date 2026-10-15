// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IFeeStrategy} from "./interfaces/IFeeStrategy.sol";

/// @notice Accumulates protocol fees from the bonding curve and the v4 hook, and forwards them
///         to a strategy when one is set.
/// @dev Holds revenue, not user principal, so unlike the curve it has an owner.
///
///      Accounting is measured from the vault's own balance rather than reported by the caller.
///      A caller-supplied amount would let anyone inflate the totals without sending anything,
///      and it would miss fees the v4 hook delivers with poolManager.take, which transfers
///      directly and calls nothing.
///
///      This contract is deliberately not upgradeable. What happens to fees is expected to
///      change; the rules for counting and holding them are not. So the changeable part is a
///      separate address rather than a proxy: {setStrategy} points at a contract deployed later,
///      and swapping it needs no delegatecall, no storage layout to preserve, and no admin able
///      to rewrite the logic guarding the balance.
///
///      {distribute} is deliberately not called from {sync}. sync runs inside the v4 hook's
///      afterSwap, within the PoolManager's lock, so calling an arbitrary strategy from there
///      would hand attacker-controlled code execution in the middle of somebody's swap and let a
///      broken strategy revert trades.
contract FeeVault is Ownable {
    using SafeERC20 for IERC20;

    mapping(address token => uint256 total) public totalReceived;
    mapping(address token => uint256 balance) public lastBalance;

    /// @notice Where fees are forwarded by {distribute}. Zero means they stay here.
    IFeeStrategy public strategy;

    event FeesRecorded(address indexed token, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event StrategySet(address indexed previous, address indexed next);
    event FeesDistributed(address indexed token, address indexed strategy, uint256 amount);
    event StrategyCallFailed(address indexed token, address indexed strategy);

    /// @notice Gas handed to a strategy when the hook notifies it. Enough for real work, capped
    ///         so a hostile or looping strategy cannot make swaps expensive for everyone.
    uint256 public constant STRATEGY_GAS_LIMIT = 400_000;

    error InvalidRecipient();
    error NoStrategy();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Point at the contract that decides what happens to fees. Zero unsets it, which
    ///         leaves fees accumulating here exactly as before.
    function setStrategy(IFeeStrategy next) external onlyOwner {
        emit StrategySet(address(strategy), address(next));
        strategy = next;
    }

    /// @notice Called by the fee hook on every swap, immediately after {sync}.
    /// @dev The point of this function is that the hook's address list is immutable but this
    ///      contract's strategy is not: it is the only seam through which behaviour decided after
    ///      launch can run automatically inside a swap.
    ///
    ///      Everything about the call is contained. Failure is swallowed, so a broken strategy
    ///      cannot revert somebody else's trade; gas is capped, so it cannot make trading
    ///      expensive; and it runs after the fee is already recorded, so reverting changes no
    ///      accounting. A strategy that misbehaves costs its own gas and nothing else.
    function onFeeReceived(address token) external {
        IFeeStrategy s = strategy;
        if (address(s) == address(0)) return;

        try s.onFeeReceived{gas: STRATEGY_GAS_LIMIT}(token) {}
        catch {
            emit StrategyCallFailed(token, address(s));
        }
    }

    /// @notice Hand everything held in `token` to the strategy.
    /// @dev Permissionless, because it can only ever move funds to the address the owner chose,
    ///      and it is expected to be driven by a keeper the team runs rather than by goodwill.
    ///      Transfer first, then notify: the strategy sees the balance already credited, so it
    ///      never has to trust the amount it is told about -- the same reason sync measures a
    ///      balance delta instead of believing its caller.
    function distribute(address token) external returns (uint256 amount) {
        IFeeStrategy s = strategy;
        if (address(s) == address(0)) revert NoStrategy();

        sync(token);
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return 0;

        IERC20(token).safeTransfer(address(s), amount);
        lastBalance[token] = IERC20(token).balanceOf(address(this));
        s.onFees(token, amount);

        emit FeesDistributed(token, address(s), amount);
    }

    /// @notice Credit whatever arrived since the last call. Permissionless: it can only ever
    ///         record tokens the vault actually holds.
    function sync(address token) public returns (uint256 received) {
        uint256 balance_ = IERC20(token).balanceOf(address(this));
        uint256 last = lastBalance[token];
        if (balance_ <= last) return 0;

        received = balance_ - last;
        lastBalance[token] = balance_;
        totalReceived[token] += received;
        emit FeesRecorded(token, received);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();

        sync(token);
        IERC20(token).safeTransfer(to, amount);
        lastBalance[token] = IERC20(token).balanceOf(address(this));

        emit FeesWithdrawn(token, to, amount);
    }

    /// @notice Fees that have arrived but not yet been credited by {sync}.
    function pending(address token) external view returns (uint256) {
        uint256 balance_ = IERC20(token).balanceOf(address(this));
        uint256 last = lastBalance[token];
        return balance_ > last ? balance_ - last : 0;
    }

    function balance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
