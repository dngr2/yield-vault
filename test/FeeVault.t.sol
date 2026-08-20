// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYieldSource} from "./mocks/MockYieldSource.sol";

contract FeeVaultTest is Test {
    // Absolute time base so fee math is deterministic across warps.
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant YEAR = 365 days;

    MockERC20 internal asset;
    MockYieldSource internal yieldSource;
    FeeVault internal vault;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint16 internal constant MGMT_BPS = 200; // 2%
    uint16 internal constant PERF_BPS = 1000; // 10%

    function setUp() public {
        vm.warp(T0);
        asset = new MockERC20("USD Coin", "USDC", 18);
        yieldSource = new MockYieldSource(IERC20(address(asset)));
        vault = new FeeVault(IERC20(address(asset)), "Vault USDC", "vUSDC", MGMT_BPS, PERF_BPS, feeRecipient, owner);

        _fund(alice, 1_000_000 ether);
        _fund(bob, 1_000_000 ether);
        _fund(attacker, 1_000_000 ether);
        // Fund the yield source so it can push profit into the vault.
        asset.mint(address(yieldSource), 10_000_000 ether);
    }

    function _fund(address who, uint256 amt) internal {
        asset.mint(who, amt);
        vm.prank(who);
        asset.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(amt, who);
    }

    // --- ERC4626 round-trips -------------------------------------------------

    function test_DepositMintsShares_RedeemReturnsAssets() public {
        uint256 amt = 100 ether;
        uint256 shares = _deposit(alice, amt);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), amt);

        // With no fees accrued (bps>0 but no time/yield) redeem returns ~principal.
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(got, amt, 1, "round-trip should return principal");
    }

    function test_ConvertMonotonic() public {
        _deposit(alice, 500 ether);
        assertLe(vault.convertToShares(1 ether), vault.convertToShares(2 ether));
        assertLe(vault.convertToAssets(1 ether), vault.convertToAssets(2 ether));
        // shares -> assets -> shares never gains value (rounding favors the vault).
        uint256 s = vault.convertToShares(3 ether);
        assertLe(vault.convertToAssets(s), 3 ether);
    }

    function test_MultipleDepositorsProportional() public {
        uint256 aShares = _deposit(alice, 100 ether);
        uint256 bShares = _deposit(bob, 300 ether);
        // Bob deposited 3x -> ~3x shares (no fees/time in between).
        assertApproxEqRel(bShares, aShares * 3, 1e12, "shares proportional to deposit");
        // Their redeemable assets sum to <= totalAssets (solvent).
        assertLe(vault.convertToAssets(aShares) + vault.convertToAssets(bShares), vault.totalAssets());
    }

    // --- Inflation attack ----------------------------------------------------

    function test_InflationAttack_VictimNotRobbed() public {
        // Attacker seeds the vault with 1 wei then donates a huge amount, hoping the victim's
        // deposit rounds to (near) zero shares so the attacker's shares capture it.
        vm.prank(attacker);
        vault.deposit(1, attacker);

        uint256 donation = 100_000 ether;
        vm.prank(attacker);
        asset.transfer(address(vault), donation); // direct donation inflates price

        uint256 victimDeposit = 100_000 ether;
        uint256 victimShares = _deposit(alice, victimDeposit);

        // Virtual-shares defense: victim still receives a meaningful, well-priced position.
        assertGt(victimShares, 0, "victim must receive shares");

        uint256 victimRedeemable = vault.convertToAssets(victimShares);
        // Victim keeps essentially all of their deposit; loss is at most tiny rounding dust.
        // (Here the loss is ~0.025 out of 100_000, i.e. < 0.0001%.) Allow 0.01% slack.
        assertApproxEqRel(victimRedeemable, victimDeposit, 1e14, "victim materially preserved");

        // The attack must not be profitable: attacker's total claim <= what they put in
        // (1 wei deposit + donation). i.e. they cannot extract the victim's principal.
        uint256 attackerClaim = vault.convertToAssets(vault.balanceOf(attacker));
        assertLe(attackerClaim, donation + 1, "attacker cannot profit from the victim");
    }

    // --- Management fee ------------------------------------------------------

    function test_MgmtFee_AccruesOverTime() public {
        uint256 amt = 100_000 ether;
        _deposit(alice, amt);
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee at deposit t0");

        // One year later, trigger accrual via harvest.
        vm.warp(T0 + YEAR);
        vault.harvest();

        // Fee recipient's claim should be ~2% of AUM.
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqRel(feeAssets, amt * MGMT_BPS / 10_000, 1e15, "~2% annual mgmt fee");
    }

    function test_MgmtFee_HalfYearIsHalf() public {
        uint256 amt = 100_000 ether;
        _deposit(alice, amt);
        vm.warp(T0 + YEAR / 2);
        vault.harvest();
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqRel(feeAssets, amt * MGMT_BPS / 10_000 / 2, 1e15, "~1% for half a year");
    }

    function test_MgmtFee_ZeroWhenBpsZero() public {
        FeeVault v = new FeeVault(IERC20(address(asset)), "Z", "Z", 0, 0, feeRecipient, owner);
        vm.startPrank(alice);
        asset.approve(address(v), type(uint256).max);
        v.deposit(100_000 ether, alice);
        vm.stopPrank();
        vm.warp(T0 + YEAR);
        v.harvest();
        assertEq(v.balanceOf(feeRecipient), 0, "no fee shares when bps=0");
    }

    function test_FeeCapEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeTooHigh.selector, uint16(501), uint16(500)));
        new FeeVault(IERC20(address(asset)), "X", "X", 501, 0, feeRecipient, owner);

        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeTooHigh.selector, uint16(2001), uint16(2000)));
        new FeeVault(IERC20(address(asset)), "X", "X", 0, 2001, feeRecipient, owner);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeTooHigh.selector, uint16(600), uint16(500)));
        vault.setMgmtFeeBps(600);
    }

    // --- Performance fee + high-water ---------------------------------------

    function test_PerfFee_ChargedOnlyOnProfit() public {
        // Use a vault with no mgmt fee to isolate performance behavior.
        FeeVault v = _perfOnlyVault();
        _approveAndDeposit(v, alice, 100_000 ether);

        // No profit yet -> no perf fee.
        v.harvest();
        assertEq(v.balanceOf(feeRecipient), 0, "no perf fee without profit");

        // Simulate 10_000 yield landing in the vault.
        yieldSource.distribute(address(v), 10_000 ether);
        v.harvest();

        uint256 feeAssets = v.convertToAssets(v.balanceOf(feeRecipient));
        // 10% of 10_000 profit = ~1_000.
        assertApproxEqRel(feeAssets, 1_000 ether, 1e15, "10% perf fee on 10k profit");
    }

    function test_PerfFee_HighWaterNoDoubleCharge() public {
        FeeVault v = _perfOnlyVault();
        _approveAndDeposit(v, alice, 100_000 ether);

        // Gain 10k -> charge perf fee.
        yieldSource.distribute(address(v), 10_000 ether);
        v.harvest();
        uint256 feeAfterGain = v.balanceOf(feeRecipient);
        assertGt(feeAfterGain, 0, "fee charged on first gain");
        uint256 hwm1 = v.highWaterMark();

        // Loss: pull 5k back out of the vault (price drops below high-water).
        vm.prank(address(v));
        // vault can't move its own asset without a call; simulate loss via burn from vault.
        _simulateLoss(v, 5_000 ether);
        v.harvest();
        assertEq(v.balanceOf(feeRecipient), feeAfterGain, "no fee on loss");
        assertEq(v.highWaterMark(), hwm1, "high-water does not drop");

        // Partial recovery: assets go 105k -> 108k, still well BELOW the prior peak (110k, and
        // above dilution ~111k). No performance fee until that peak price is exceeded again.
        yieldSource.distribute(address(v), 3_000 ether);
        v.harvest();
        assertEq(v.balanceOf(feeRecipient), feeAfterGain, "no fee recovering below prior peak");

        // New high: push clearly above the previous peak. Only the incremental profit is charged.
        yieldSource.distribute(address(v), 12_000 ether);
        v.harvest();
        assertGt(v.balanceOf(feeRecipient), feeAfterGain, "fee resumes above prior peak");
        assertGt(v.highWaterMark(), hwm1, "high-water ratchets up");
    }

    function test_PerfFee_CapEnforcedAtConstruction() public {
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeTooHigh.selector, uint16(2001), uint16(2000)));
        new FeeVault(IERC20(address(asset)), "X", "X", 0, 2001, feeRecipient, owner);
    }

    // --- No user-fund seizure ------------------------------------------------

    function test_OwnerCannotSeizeUserAssets() public {
        _deposit(alice, 100_000 ether);
        uint256 vaultBal = asset.balanceOf(address(vault));

        // Owner has no function that moves raw assets; fee shares are the only owner value path.
        // Confirm owner holds nothing and cannot mint arbitrary shares to itself.
        assertEq(vault.balanceOf(owner), 0);

        // Owner changing fee recipient does not retroactively grab existing user assets.
        vm.prank(owner);
        vault.setFeeRecipient(owner);
        assertEq(asset.balanceOf(address(vault)), vaultBal, "vault assets untouched by owner action");

        // Only accounted shares exist: sum of balances == totalSupply.
        assertEq(
            vault.balanceOf(alice) + vault.balanceOf(feeRecipient) + vault.balanceOf(owner),
            vault.totalSupply(),
            "no unaccounted shares"
        );
    }

    function test_OnlyOwnerSetsFees() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setMgmtFeeBps(100);
    }

    function test_SetFeeRecipientZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(FeeVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_DecimalsOffsetApplied() public view {
        // 18-decimal asset + offset 6 => 24-decimal shares.
        assertEq(vault.decimals(), 24);
    }

    // --- helpers -------------------------------------------------------------

    function _perfOnlyVault() internal returns (FeeVault v) {
        v = new FeeVault(IERC20(address(asset)), "Perf", "P", 0, PERF_BPS, feeRecipient, owner);
    }

    function _approveAndDeposit(FeeVault v, address who, uint256 amt) internal {
        vm.startPrank(who);
        asset.approve(address(v), type(uint256).max);
        v.deposit(amt, who);
        vm.stopPrank();
    }

    /// @dev Simulate a strategy loss by removing asset from the vault's balance.
    function _simulateLoss(FeeVault v, uint256 amt) internal {
        asset.burn(address(v), amt);
    }
}
