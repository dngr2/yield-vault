// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

/// @notice Deploys the {VaultFactory}. Individual {FeeVault} instances are created afterwards by
///         calling `factory.createVault(...)` (see DEPLOY.md).
/// @dev Configuration is read from the environment:
///      - FACTORY_OWNER          (address) owner of the factory; defaults to the broadcaster.
///      - FACTORY_FEE_RECIPIENT  (address) recipient of creation fees; defaults to the broadcaster.
///      - FACTORY_CREATION_FEE   (uint256, asset units) flat vault-creation fee; defaults to 0.
contract Deploy is Script {
    function run() external returns (VaultFactory factory) {
        address deployer = msg.sender;

        address owner = vm.envOr("FACTORY_OWNER", deployer);
        address feeRecipient = vm.envOr("FACTORY_FEE_RECIPIENT", deployer);
        uint256 creationFee = vm.envOr("FACTORY_CREATION_FEE", uint256(0));

        vm.startBroadcast();
        factory = new VaultFactory(owner, feeRecipient, creationFee);
        vm.stopBroadcast();

        console2.log("VaultFactory deployed at:", address(factory));
        console2.log("  owner:              ", owner);
        console2.log("  factoryFeeRecipient:", feeRecipient);
        console2.log("  creationFee:        ", creationFee);
    }
}
