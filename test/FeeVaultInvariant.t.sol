// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @notice Solvency and accounting invariants over a bounded, randomized action stream.
contract FeeVaultInvariantTest is Test {
    MockERC20 internal asset;
    FeeVault internal vault;
    VaultHandler internal handler;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_700_000_000);
        asset = new MockERC20("USD Coin", "USDC", 18);
        // Nonzero mgmt + perf fees so accrual is continuously exercised.
        vault = new FeeVault(IERC20(address(asset)), "Vault", "V", 200, 1000, feeRecipient, owner);
        handler = new VaultHandler(vault, asset, feeRecipient);

        targetContract(address(handler));
    }

    /// @dev All shares are held by known parties: the vault never mints shares anywhere except to
    ///      depositors (the actors) and the fee recipient. Sum of those balances == totalSupply.
    function invariant_shareAccountingComplete() public view {
        address[] memory actors = handler.allActors();
        uint256 sum;
        for (uint256 i; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }
        sum += vault.balanceOf(feeRecipient);
        assertEq(sum, vault.totalSupply(), "unaccounted shares exist");
    }

    /// @dev The vault is always solvent: the assets owed to every shareholder at the current share
    ///      price never exceed the assets the vault actually holds.
    function invariant_solvent() public view {
        address[] memory actors = handler.allActors();
        uint256 owed;
        for (uint256 i; i < actors.length; i++) {
            owed += vault.convertToAssets(vault.balanceOf(actors[i]));
        }
        owed += vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertLe(owed, vault.totalAssets(), "vault owes more than it holds");
    }

    /// @dev Total claim on the vault (convertToAssets of all shares) never exceeds assets held.
    function invariant_totalClaimBounded() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets(), "over-issued shares");
    }
}
