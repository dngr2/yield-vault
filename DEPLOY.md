# Deploying VaultFactory

This deploys the `VaultFactory` contract. Individual `FeeVault` instances are **not**
deployed by this script — they are created after deployment by calling
`factory.createVault(...)` (see [Creating vaults](#creating-vaults-after-deploy) below).

> **Unaudited.** This code has not been audited. Deploy to a **testnet first**, and use a
> **dedicated deployer key** that holds only what it needs for gas — never a key that guards
> real funds. You are responsible for what you deploy.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed (`forge`).
- An RPC endpoint for the target network.
- A funded deployer account.

## Environment variables

The deploy script (`script/Deploy.s.sol`) reads its configuration from the environment. All
factory settings are optional and default to the broadcasting account / zero fee.

| Variable                 | Type              | Required | Default        | Meaning                                              |
| ------------------------ | ----------------- | -------- | -------------- | ---------------------------------------------------- |
| `FACTORY_OWNER`          | address           | no       | broadcaster    | Owner of the factory (can set creation fee/recipient).|
| `FACTORY_FEE_RECIPIENT`  | address           | no       | broadcaster    | Recipient of vault-creation fees. Must be non-zero.  |
| `FACTORY_CREATION_FEE`   | uint256 (wei)     | no       | `0`            | Flat fee (in each vault's asset units) to create a vault. Capped at `MAX_CREATION_FEE`. |

Deployment itself is driven by standard Foundry flags/vars:

- `--rpc-url` — the target network RPC.
- A signer — e.g. `--account <keystore>` (recommended), `--ledger`, or `PRIVATE_KEY` via
  `--private-key $PRIVATE_KEY`. Prefer a keystore or hardware wallet over a raw private key.

Example `.env` (never commit this file — `.env` is gitignored):

```bash
export FACTORY_OWNER=0xYourOwnerAddress
export FACTORY_FEE_RECIPIENT=0xYourFeeRecipient
export FACTORY_CREATION_FEE=0
```

## Deploy

Testnet first. Example against Sepolia using an encrypted keystore account:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account deployer \
  --sender 0xYourDeployerAddress \
  --broadcast
```

The script logs the deployed `VaultFactory` address on success.

### Verification

Contract verification is optional and depends on the target explorer. To verify during the
run, add your explorer API key and the verify flags, for example:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account deployer \
  --sender 0xYourDeployerAddress \
  --broadcast \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Verification is best-effort and not required for the deployment to succeed; if it fails you
can re-run `forge verify-contract` separately. Explorer support varies by network.

## Creating vaults after deploy

The factory only indexes and deploys vaults; it does not create one on deploy. After the
factory is live, create individual `FeeVault`s by calling `createVault` on it:

```
factory.createVault(
    asset,             // IERC20 underlying asset
    name,              // vault share token name
    symbol,            // vault share token symbol
    mgmtFeeBps,        // management fee, basis points
    perfFeeBps,        // performance fee, basis points
    vaultFeeRecipient  // where this vault's fees go
)
```

If `FACTORY_CREATION_FEE` is non-zero, the caller must first `approve` the factory to pull
`creationFee` of `asset`; that fee is forwarded to `factoryFeeRecipient`. The newly created
vault is owned by the caller (the vault creator), so creators control their own vault's fees.
