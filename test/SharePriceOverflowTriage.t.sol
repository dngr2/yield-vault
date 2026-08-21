// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Triage of the audit's "share-math overflow" finding. Reproduces the catastrophic-loss
///         state (supply huge, totalAssets == 1) and checks what actually happens on deposit.
contract SharePriceOverflowTriageTest is Test {
    MockERC20 asset;
    FeeVault vault;
    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 18);
        // zero fees so accrual can't interfere with the pure share-math observation
        vault = new FeeVault(IERC20(address(asset)), "Vault", "V", 0, 0, feeRecipient, owner);
    }

    /// Drive the vault into supply ~ 1e36, totalAssets == 1 (the audit PoC's exact precondition),
    /// then observe deposits. Offset is 6, so a ~1e30-wei seed mints ~1e36 shares.
    function _collapse() internal {
        uint256 seed = 1e30;
        asset.mint(alice, seed);
        vm.startPrank(alice);
        asset.approve(address(vault), seed);
        vault.deposit(seed, alice);
        vm.stopPrank();
        // Simulate a near-total loss: drain the vault's asset balance down to 1 wei.
        uint256 bal = asset.balanceOf(address(vault));
        asset.burn(address(vault), bal - 1);
        assertEq(vault.totalAssets(), 1, "precondition: totalAssets == 1");
        assertGt(vault.totalSupply(), 1e35, "precondition: supply ~1e36");
    }

    function test_collapsedState_realisticDepositStillSucceeds() public {
        _collapse();
        // A normal-sized deposit into the collapsed vault: does it still work?
        uint256 amt = 1_000e18;
        asset.mint(bob, amt);
        vm.startPrank(bob);
        asset.approve(address(vault), amt);
        uint256 shares = vault.deposit(amt, bob);
        vm.stopPrank();
        assertGt(shares, 0, "realistic deposit should mint shares, not revert");
        // Bob can redeem back approximately his deposit (he now owns ~all the assets).
        assertGe(vault.maxWithdraw(bob), amt - 2, "bob should be able to withdraw ~his deposit");
    }

    function test_collapsedState_absurdDepositRevertsSafely() public {
        _collapse();
        // An absurd deposit (1e48 wei) would require minting > 2^256 shares given the collapsed
        // price. OZ mulDiv correctly reverts rather than mis-minting. This is safe refusal of an
        // impossible mint, NOT a fund-loss: no state changes, nothing is stolen.
        uint256 absurd = 1e48;
        asset.mint(bob, absurd);
        vm.startPrank(bob);
        asset.approve(address(vault), absurd);
        vm.expectRevert(); // MathOverflowedMulDiv
        vault.deposit(absurd, bob);
        vm.stopPrank();
        // Vault state untouched by the reverted call.
        assertEq(vault.totalAssets(), 1, "no assets moved on revert");
    }

    /// Find roughly where the boundary is: deposits stay fine until the resulting share count
    /// approaches 2^256. Demonstrates the revert is purely a numeric ceiling, not a low threshold.
    function test_collapsedState_boundaryIsAstronomical() public {
        _collapse();
        // 1e30 tokens (1e48 wei is 1e30 * 1e18) is the absurd case; 1e24 wei (~1e6 tokens) is huge
        // but fine — proving realistic and even very large deposits are unaffected.
        uint256 large = 1e24;
        asset.mint(bob, large);
        vm.startPrank(bob);
        asset.approve(address(vault), large);
        uint256 shares = vault.deposit(large, bob);
        vm.stopPrank();
        assertGt(shares, 0, "even a very large (1e6-token) deposit succeeds");
    }
}
