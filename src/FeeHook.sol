// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FeeVault} from "./FeeVault.sol";
import {Token} from "./Token.sol";

/// @notice Takes a fee on every swap in the graduated pool. The reserve side accumulates in the
///         FeeVault; the token side is burned.
/// @dev Only afterSwap and afterSwapReturnDelta are enabled. beforeSwapReturnDelta is
///      deliberately off: it is the NoOp rug-pull vector and this hook has no need for it.
///      The fee is charged on the unspecified currency, which covers exact-input and
///      exact-output swaps alike, so it cannot be avoided by choosing a swap direction.
///
///      Which currency that is falls out of the trade direction: a buy pays out the token, a
///      sell pays out the reserve. So "burn the token, bank the reserve" needs no routing beyond
///      comparing the fee currency against the reserve, which is known at deployment. The token
///      address is not -- it does not exist when this hook is mined -- so it is never stored;
///      whatever is not the reserve is the token.
///
///      The rate can be lowered but never raised. The current value is therefore a permanent
///      ceiling, and the worst an owner key can do is give revenue away. It cannot reach anyone's
///      funds: this contract holds nothing between transactions and has no withdrawal path.
contract FeeHook is IHooks, Ownable2Step {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000;
    /// @notice The rate can never be ratcheted below this.
    uint256 public constant MIN_FEE_BPS = 100;

    IPoolManager public immutable poolManager;
    address public immutable feeVault;
    /// @notice The pool's reserve currency. Fees in it are banked; fees in anything else are burned.
    address public immutable reserve;

    uint256 public feeBps;

    event SwapFeeTaken(Currency indexed currency, uint256 amount);
    event SwapFeeBurned(Currency indexed currency, uint256 amount);
    event FeeReduced(uint256 previousBps, uint256 newBps);

    error NotPoolManager();
    error FeeTooHigh(uint256 feeBps);
    error FeeNotLower(uint256 currentBps, uint256 newBps);
    error FeeTooLow(uint256 feeBps);
    error InvalidParams();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address feeVault_, address reserve_, uint256 feeBps_, address owner_)
        Ownable(owner_)
    {
        if (address(poolManager_) == address(0) || feeVault_ == address(0) || reserve_ == address(0)) {
            revert InvalidParams();
        }
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (feeBps_ < MIN_FEE_BPS) revert FeeTooLow(feeBps_);

        poolManager = poolManager_;
        feeVault = feeVault_;
        reserve = reserve_;
        feeBps = feeBps_;

        // Reverts unless this address was CREATE2-mined with exactly the permission bits below.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Lower the swap fee. One-way by construction: the new rate must be strictly below
    ///         the current one, so today's value is a ceiling that can only ever fall.
    function reduceFee(uint256 newBps) external onlyOwner {
        uint256 current = feeBps;
        if (newBps >= current) revert FeeNotLower(current, newBps);
        if (newBps < MIN_FEE_BPS) revert FeeTooLow(newBps);

        feeBps = newBps;
        emit FeeReduced(current, newBps);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool unspecifiedIsCurrency1 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency unspecified = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        int128 unspecifiedAmount = unspecifiedIsCurrency1 ? delta.amount1() : delta.amount0();

        uint256 magnitude =
            unspecifiedAmount < 0 ? uint256(uint128(-unspecifiedAmount)) : uint256(uint128(unspecifiedAmount));
        uint256 fee = (magnitude * feeBps) / BPS;
        if (fee == 0) return (IHooks.afterSwap.selector, int128(0));

        address currency = Currency.unwrap(unspecified);

        if (currency == reserve) {
            poolManager.take(unspecified, feeVault, fee);

            // take() transfers directly and calls nothing, so the vault would otherwise never
            // account for a single post-graduation fee.
            FeeVault(feeVault).sync(currency);

            emit SwapFeeTaken(unspecified, fee);
        } else {
            // Pull the token side here first: burn() destroys the caller's own balance, so the
            // fee has to land on this contract before it can be destroyed. Nothing accumulates,
            // the balance is burned in the same call.
            poolManager.take(unspecified, address(this), fee);
            Token(currency).burn(fee);

            emit SwapFeeBurned(unspecified, fee);
        }

        // The one seam through which behaviour chosen after launch can run automatically on every
        // swap. This contract cannot be changed or replaced -- the hook is part of the PoolKey, so
        // it is fixed for the life of the pool -- and the vault's address is immutable here, so
        // this call has a fixed destination. What the vault forwards it to does not.
        //
        // Contained on the vault's side: failure swallowed, gas capped. Nothing a strategy does
        // can revert this swap or make trading expensive.
        FeeVault(feeVault).onFeeReceived(currency);

        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
