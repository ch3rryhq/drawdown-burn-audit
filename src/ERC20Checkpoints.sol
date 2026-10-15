// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice ERC20 that records every holder's balance history on-chain.
/// @dev Not ERC20Votes: that checkpoints delegated voting power, so a holder who never calls
///      delegate() reads back zero. Clock is block.timestamp, because on Arbitrum Solidity's
///      block.number is the L1 block number.
abstract contract ERC20Checkpoints is ERC20 {
    using Checkpoints for Checkpoints.Trace208;

    mapping(address account => Checkpoints.Trace208) private _balanceHistory;
    Checkpoints.Trace208 private _supplyHistory;

    error FutureLookup(uint48 requested, uint48 currentClock);

    function clock() public view virtual returns (uint48) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.timestamp);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function CLOCK_MODE() public view virtual returns (string memory) {
        return "mode=timestamp";
    }

    function getPastBalance(address account, uint256 timepoint) public view returns (uint256) {
        return _balanceHistory[account].upperLookupRecent(_pastKey(timepoint));
    }

    function getPastTotalSupply(uint256 timepoint) public view returns (uint256) {
        return _supplyHistory.upperLookupRecent(_pastKey(timepoint));
    }

    function numCheckpoints(address account) public view returns (uint32) {
        return SafeCast.toUint32(_balanceHistory[account].length());
    }

    function checkpointAt(address account, uint32 pos) public view returns (Checkpoints.Checkpoint208 memory) {
        return _balanceHistory[account].at(pos);
    }

    function numTotalSupplyCheckpoints() public view returns (uint32) {
        return SafeCast.toUint32(_supplyHistory.length());
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);

        uint48 key = clock();

        if (from == address(0) || to == address(0)) {
            _supplyHistory.push(key, SafeCast.toUint208(totalSupply()));
        }
        if (from != address(0)) {
            _balanceHistory[from].push(key, SafeCast.toUint208(balanceOf(from)));
        }
        if (to != address(0)) {
            _balanceHistory[to].push(key, SafeCast.toUint208(balanceOf(to)));
        }
    }

    /// @dev Rejects the current second, whose checkpoint a later transfer can still overwrite.
    function _pastKey(uint256 timepoint) private view returns (uint48) {
        uint48 currentClock = clock();
        uint48 key = SafeCast.toUint48(timepoint);
        if (key >= currentClock) revert FutureLookup(key, currentClock);
        return key;
    }
}
