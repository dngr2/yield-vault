// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract VaultFactoryTest is Test {
    MockERC20 internal asset;
    VaultFactory internal factory;

    address internal owner = makeAddr("owner");
    address internal factoryFeeRecipient = makeAddr("factoryFeeRecipient");
    address internal creator = makeAddr("creator");
    address internal vaultFeeRecipient = makeAddr("vaultFeeRecipient");

    function setUp() public {
        asset = new MockERC20("USD Coin", "USDC", 18);
        factory = new VaultFactory(owner, factoryFeeRecipient, 0);
    }

    function test_CreateVault_IndexesAndConfigures() public {
        vm.prank(creator);
        address vaultAddr = factory.createVault(IERC20(address(asset)), "Vault", "V", 100, 500, vaultFeeRecipient);

        assertTrue(factory.isVault(vaultAddr));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.allVaults(0), vaultAddr);

        FeeVault v = FeeVault(vaultAddr);
        assertEq(v.owner(), creator, "creator owns the vault");
        assertEq(v.feeRecipient(), vaultFeeRecipient);
        assertEq(v.mgmtFeeBps(), 100);
        assertEq(v.perfFeeBps(), 500);
        assertEq(address(v.asset()), address(asset));
    }

    function test_CreateVault_ChargesCreationFee() public {
        uint256 fee = 50 ether;
        vm.prank(owner);
        factory.setCreationFee(fee);

        asset.mint(creator, fee);
        vm.startPrank(creator);
        asset.approve(address(factory), fee);
        factory.createVault(IERC20(address(asset)), "Vault", "V", 0, 0, vaultFeeRecipient);
        vm.stopPrank();

        assertEq(asset.balanceOf(factoryFeeRecipient), fee, "creation fee forwarded");
        assertEq(asset.balanceOf(creator), 0);
    }

    function test_CreationFeeCapEnforced() public {
        uint256 max = factory.MAX_CREATION_FEE();
        uint256 tooHigh = max + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.FeeTooHigh.selector, tooHigh, max));
        factory.setCreationFee(tooHigh);
    }

    function test_OnlyOwnerControls() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factory.setCreationFee(1);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factory.setFactoryFeeRecipient(creator);
    }

    function test_ConstructorRejectsBadArgs() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(owner, address(0), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                VaultFactory.FeeTooHigh.selector, uint256(1_000_000 ether + 1), uint256(1_000_000 ether)
            )
        );
        new VaultFactory(owner, factoryFeeRecipient, 1_000_000 ether + 1);
    }

    function test_VaultRejectsBadFeeThroughFactory() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FeeVault.FeeTooHigh.selector, uint16(9999), uint16(500)));
        factory.createVault(IERC20(address(asset)), "Vault", "V", 9999, 0, vaultFeeRecipient);
    }
}
