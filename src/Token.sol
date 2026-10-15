// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Checkpoints} from "./ERC20Checkpoints.sol";

/// @notice ERC20 minted once, in full, to the bonding curve. No owner, no mint, no transfer fee.
///         Supply can only ever fall: {burn} destroys the caller's own tokens and nothing else.
/// @dev A transfer fee here would break Uniswap v3 and v4 settlement, so buy/sell fees live in
///      the bonding curve before graduation and in the v4 hook after it.
contract Token is ERC20Checkpoints, ERC20Permit {
    error InvalidSupply(uint256 supply);
    error InvalidRecipient();

    constructor(string memory name_, string memory symbol_, uint256 supply, address recipient)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (supply == 0 || supply > type(uint208).max) {
            revert InvalidSupply(supply);
        }
        if (recipient == address(0)) revert InvalidRecipient();
        _mint(recipient, supply);
    }

    /// @notice Destroy `value` tokens held by the caller, lowering total supply permanently.
    /// @dev Deliberately has no allowance-spending variant and no privileged burner: an address
    ///      can only ever burn what it holds itself, so no role can reach a holder's balance.
    ///      The v4 hook uses this to burn the token side of its fee. Balance and supply history
    ///      already record burns, since _update checkpoints whenever `to` is the zero address.
    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20Checkpoints, ERC20) {
        super._update(from, to, value);
    }
}
