// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Simulates external yield by transferring the underlying asset directly into a vault.
///      A real strategy would deploy capital and return profit; here we just push tokens in
///      (profit) or, for loss scenarios, the test pulls tokens back out.
contract MockYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    /// @notice Push `amount` of asset into `vault`, raising its per-share price (yield).
    function distribute(address vault, uint256 amount) external {
        asset.safeTransfer(vault, amount);
    }
}
