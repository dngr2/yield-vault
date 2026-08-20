// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FeeVault} from "./FeeVault.sol";

/// @title VaultFactory
/// @notice Deploys and indexes {FeeVault} instances. Optionally charges a bounded flat creation
///         fee (denominated in the new vault's asset) to the factory's own fee recipient.
contract VaultFactory is Ownable {
    using SafeERC20 for IERC20;

    /// @dev Hard cap on the flat creation fee (in asset units). Bounds the owner's reach.
    uint256 public constant MAX_CREATION_FEE = 1_000_000 ether;

    /// @notice Flat fee charged (in the vault's asset) when creating a vault.
    uint256 public creationFee;

    /// @notice Recipient of creation fees.
    address public factoryFeeRecipient;

    /// @notice All vaults deployed by this factory, in creation order.
    address[] public allVaults;

    /// @notice True for any address deployed by this factory.
    mapping(address => bool) public isVault;

    event VaultCreated(
        address indexed vault,
        address indexed asset,
        address indexed creator,
        address feeRecipient,
        uint16 mgmtFeeBps,
        uint16 perfFeeBps
    );
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event FactoryFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    error FeeTooHigh(uint256 provided, uint256 max);
    error ZeroAddress();

    constructor(address owner_, address factoryFeeRecipient_, uint256 creationFee_) Ownable(owner_) {
        if (factoryFeeRecipient_ == address(0)) revert ZeroAddress();
        if (creationFee_ > MAX_CREATION_FEE) revert FeeTooHigh(creationFee_, MAX_CREATION_FEE);
        factoryFeeRecipient = factoryFeeRecipient_;
        creationFee = creationFee_;
    }

    /// @notice Deploy a new {FeeVault}. If a creation fee is set, the caller must have approved the
    ///         factory to pull `creationFee` of `asset`, which is forwarded to the fee recipient.
    /// @dev The deployed vault is owned by the caller, so vault creators control their own fees.
    function createVault(
        IERC20 asset,
        string calldata name,
        string calldata symbol,
        uint16 mgmtFeeBps,
        uint16 perfFeeBps,
        address vaultFeeRecipient
    ) external returns (address vault) {
        if (creationFee != 0) {
            asset.safeTransferFrom(msg.sender, factoryFeeRecipient, creationFee);
        }

        FeeVault v = new FeeVault(asset, name, symbol, mgmtFeeBps, perfFeeBps, vaultFeeRecipient, msg.sender);
        vault = address(v);

        allVaults.push(vault);
        isVault[vault] = true;

        emit VaultCreated(vault, address(asset), msg.sender, vaultFeeRecipient, mgmtFeeBps, perfFeeBps);
    }

    /// @notice Number of vaults deployed by this factory.
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    // --- Owner controls (bounded) --------------------------------------------

    function setCreationFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_CREATION_FEE) revert FeeTooHigh(newFee, MAX_CREATION_FEE);
        emit CreationFeeUpdated(creationFee, newFee);
        creationFee = newFee;
    }

    function setFactoryFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FactoryFeeRecipientUpdated(factoryFeeRecipient, newRecipient);
        factoryFeeRecipient = newRecipient;
    }
}
