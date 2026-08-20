// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {FeeVault} from "../../src/FeeVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Bounded actor-driven handler for the vault invariant suite. Exercises the full lifecycle —
///      deposit / mint / withdraw / redeem / external yield / time passage — while keeping every
///      share holder inside a known set (the actors plus the fee recipient) so accounting can be
///      checked exactly.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    FeeVault public immutable vault;
    MockERC20 public immutable asset;
    address public immutable feeRecipient;

    address[] public actors;
    uint256 internal constant N_ACTORS = 3;

    // Time base kept absolute so fee math stays deterministic.
    uint256 public constant T0 = 1_700_000_000;

    constructor(FeeVault vault_, MockERC20 asset_, address feeRecipient_) {
        vault = vault_;
        asset = asset_;
        feeRecipient = feeRecipient_;
        for (uint256 i; i < N_ACTORS; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(a);
            vm.prank(a);
            asset.approve(address(vault_), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function allActors() external view returns (address[] memory) {
        return actors;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, 1e30);
        if (amount == 0) return;
        asset.mint(actor, amount);
        vm.prank(actor);
        vault.deposit(amount, actor);
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        shares = bound(shares, 0, 1e30);
        if (shares == 0) return;
        uint256 assets = vault.previewMint(shares);
        if (assets == 0 || assets > 1e36) return;
        asset.mint(actor, assets);
        vm.prank(actor);
        vault.mint(shares, actor);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxWithdraw(actor);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(actor);
        vault.withdraw(amount, actor, actor);
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 max = vault.maxRedeem(actor);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(actor);
        vault.redeem(shares, actor, actor);
    }

    /// @dev External yield: push asset straight into the vault, raising the per-share price.
    function addYield(uint256 amount) external {
        amount = bound(amount, 0, 1e28);
        if (amount == 0) return;
        asset.mint(address(vault), amount);
        vault.harvest();
    }

    /// @dev Simulate a strategy loss by removing some asset from the vault (never below 1 wei).
    function removeYield(uint256 amount) external {
        uint256 bal = asset.balanceOf(address(vault));
        if (bal <= 1) return;
        amount = bound(amount, 1, bal - 1);
        asset.burn(address(vault), amount);
        vault.harvest();
    }

    /// @dev Advance time (bounded per call) so management fees accrue.
    function warpTime(uint256 dt) external {
        dt = bound(dt, 0, 60 days);
        vm.warp(block.timestamp + dt);
        vault.harvest();
    }
}
