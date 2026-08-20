// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Tests for the v2 LP-safety features: deposit cap, deposit pause, and the fee-increase
///         rate-limit. Withdrawals must remain available under every guard.
contract FeeVaultV2Test is Test {
    uint256 internal constant T0 = 1_700_000_000;

    MockERC20 internal asset;
    FeeVault internal vault;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint16 internal constant MGMT_BPS = 200; // 2%
    uint16 internal constant PERF_BPS = 1000; // 10%

    function setUp() public {
        vm.warp(T0);
        asset = new MockERC20("USD Coin", "USDC", 18);
        vault = new FeeVault(IERC20(address(asset)), "Vault USDC", "vUSDC", MGMT_BPS, PERF_BPS, feeRecipient, owner);
        _fund(alice, 10_000_000 ether);
        _fund(bob, 10_000_000 ether);
    }

    function _fund(address who, uint256 amt) internal {
        asset.mint(who, amt);
        vm.prank(who);
        asset.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(amt, who);
    }

    // --- Deposit cap ---------------------------------------------------------

    function test_DepositCap_DefaultUnlimited() public view {
        assertEq(vault.depositCap(), 0, "uncapped by default");
        assertEq(vault.maxDeposit(alice), type(uint256).max, "unlimited maxDeposit");
        assertEq(vault.maxMint(alice), type(uint256).max, "unlimited maxMint");
    }

    function test_DepositCap_LimitsRoomAndReverts() public {
        _deposit(alice, 600 ether);

        vm.expectEmit(false, false, false, true, address(vault));
        emit FeeVault.DepositCapUpdated(0, 1_000 ether);
        vm.prank(owner);
        vault.setDepositCap(1_000 ether);

        // Room = cap - current AUM.
        assertEq(vault.maxDeposit(bob), 400 ether, "remaining room under cap");

        // Depositing beyond the room reverts with the ERC4626 max error.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 400 ether + 1, 400 ether)
        );
        vault.deposit(400 ether + 1, bob);

        // Depositing exactly up to the cap is fine, then no room remains.
        _deposit(bob, 400 ether);
        assertEq(vault.maxDeposit(bob), 0, "cap reached");
        assertEq(vault.maxMint(bob), 0, "no shares mintable at cap");
    }

    function test_DepositCap_MaxMintTracksCap() public {
        _deposit(alice, 100 ether);
        vm.prank(owner);
        vault.setDepositCap(1_000 ether);
        uint256 room = vault.maxDeposit(bob); // 900 ether
        assertEq(vault.maxMint(bob), vault.previewDeposit(room), "maxMint == previewDeposit(room)");

        // Minting one wei-share more than allowed reverts.
        uint256 mm = vault.maxMint(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, bob, mm + 1, mm));
        vault.mint(mm + 1, bob);
    }

    function test_DepositCap_DoesNotBlockWithdrawals() public {
        uint256 shares = _deposit(alice, 1_000 ether);
        // Lower the cap below current AUM.
        vm.prank(owner);
        vault.setDepositCap(100 ether);
        assertEq(vault.maxDeposit(alice), 0, "no new deposits over cap");
        // Alice can still exit fully.
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(got, 1_000 ether, 1, "withdrawal unaffected by cap");
    }

    function test_DepositCap_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositCap(1);
    }

    // --- Pause ---------------------------------------------------------------

    function test_Pause_BlocksDepositsAndMints() public {
        _deposit(alice, 100 ether);

        vm.expectEmit(false, false, false, true, address(vault));
        emit FeeVault.DepositsPausedSet(true);
        vm.prank(owner);
        vault.setDepositsPaused(true);

        assertEq(vault.maxDeposit(alice), 0, "paused => zero maxDeposit");
        assertEq(vault.maxMint(alice), 0, "paused => zero maxMint");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1 ether, 0));
        vault.deposit(1 ether, bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, bob, 1, 0));
        vault.mint(1, bob);
    }

    function test_Pause_NeverBlocksWithdrawals() public {
        uint256 shares = _deposit(alice, 1_000 ether);
        vm.prank(owner);
        vault.setDepositsPaused(true);

        // Users can always exit while paused.
        vm.prank(alice);
        uint256 half = vault.redeem(shares / 2, alice, alice);
        assertGt(half, 0, "redeem works while paused");
        vm.prank(alice);
        vault.withdraw(100 ether, alice, alice);
    }

    function test_Pause_Unpause() public {
        vm.startPrank(owner);
        vault.setDepositsPaused(true);
        vault.setDepositsPaused(false);
        vm.stopPrank();
        assertEq(vault.maxDeposit(alice), type(uint256).max, "unpaused restores deposits");
        _deposit(bob, 5 ether); // succeeds
        assertGt(vault.balanceOf(bob), 0);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositsPaused(true);
    }

    // --- Fee-increase rate limit --------------------------------------------

    function test_FeeIncrease_StepBounded() public {
        // Jump larger than MAX_FEE_INCREASE_STEP_BPS (100) reverts.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeIncreaseTooLarge.selector, uint16(300), uint16(100)));
        vault.setMgmtFeeBps(500); // 200 -> 500 is +300
    }

    function test_FeeIncrease_WithinStepAllowed_ThenCooldown() public {
        vm.prank(owner);
        vault.setMgmtFeeBps(300); // +100, first increase (no prior timer) => allowed
        assertEq(vault.mgmtFeeBps(), 300);

        // A second increase before the cooldown elapses reverts.
        uint256 nextAllowed = block.timestamp + vault.FEE_INCREASE_COOLDOWN();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeIncreaseTooSoon.selector, nextAllowed));
        vault.setMgmtFeeBps(350);

        // After the cooldown, another bounded increase is allowed.
        vm.warp(block.timestamp + vault.FEE_INCREASE_COOLDOWN());
        vm.prank(owner);
        vault.setMgmtFeeBps(400); // +100
        assertEq(vault.mgmtFeeBps(), 400);
    }

    function test_FeeDecrease_AlwaysInstant() public {
        vm.startPrank(owner);
        vault.setMgmtFeeBps(300); // increase sets the timer
        vault.setMgmtFeeBps(100); // decrease within cooldown: allowed
        vault.setMgmtFeeBps(50); // another decrease: allowed
        vm.stopPrank();
        assertEq(vault.mgmtFeeBps(), 50);
    }

    function test_FeeIncrease_PerfFeeGuarded() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeIncreaseTooLarge.selector, uint16(200), uint16(100)));
        vault.setPerfFeeBps(1200); // 1000 -> 1200 is +200

        vm.prank(owner);
        vault.setPerfFeeBps(1100); // +100 allowed
        assertEq(vault.perfFeeBps(), 1100);

        uint256 nextAllowed = block.timestamp + vault.FEE_INCREASE_COOLDOWN();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeIncreaseTooSoon.selector, nextAllowed));
        vault.setPerfFeeBps(1150);
    }

    function test_FeeIncrease_StillRespectsHardCap() public {
        // Even a bounded step cannot exceed the hard cap.
        vm.startPrank(owner);
        // Walk mgmt up to the cap in bounded steps.
        vault.setMgmtFeeBps(300);
        vm.warp(block.timestamp + vault.FEE_INCREASE_COOLDOWN());
        vault.setMgmtFeeBps(400);
        vm.warp(block.timestamp + vault.FEE_INCREASE_COOLDOWN());
        vault.setMgmtFeeBps(500); // at cap
        vm.warp(block.timestamp + vault.FEE_INCREASE_COOLDOWN());
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeTooHigh.selector, uint16(550), uint16(500)));
        vault.setMgmtFeeBps(550);
        vm.stopPrank();
    }
}
