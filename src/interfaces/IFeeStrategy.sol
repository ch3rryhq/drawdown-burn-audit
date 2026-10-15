// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A destination the FeeVault can hand fees to.
/// @dev Implementations decide what happens to them -- redistribution to holders, buybacks,
///      anything later. The vault only ever transfers and then calls {onFees}; it never
///      delegatecalls, so a strategy cannot reach the vault's storage or its accounting.
interface IFeeStrategy {
    /// @param token  The token that was transferred, already in this contract's balance.
    /// @param amount How much arrived.
    function onFees(address token, uint256 amount) external;

    /// @notice Called on every swap, from inside the hook, with the fee already banked or burned.
    /// @dev Runs under a gas cap and inside a try/catch, so it may be cut short at any point and
    ///      must never assume it completed. Anything that must not be lost belongs in {onFees},
    ///      which is called deliberately rather than opportunistically.
    function onFeeReceived(address token) external;
}
