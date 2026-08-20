# FeeVault — ERC-4626 tokenized vault with management + performance fees

A production-oriented [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) tokenized vault built on
OpenZeppelin's audited `ERC4626`. Users deposit an underlying ERC-20 asset and receive vault shares
(themselves an ERC-20). The vault earns a **bounded management fee** on assets under management and a
**bounded performance fee** on yield above a **per-share high-water mark**. Fees are the revenue layer.

## Contracts

- **`src/FeeVault.sol`** — the vault. Standard 4626 `deposit`/`mint`/`withdraw`/`redeem`, plus fee
  accrual, high-water tracking, and bounded owner controls.
- **`src/VaultFactory.sol`** — deploys and indexes `FeeVault` instances, with an optional bounded
  flat creation fee paid to the factory's own fee recipient.

## Inflation-attack defense

The classic first-depositor / donation ("inflation") attack seeds an empty vault with 1 wei, donates
a large amount of the asset directly into the vault to inflate the share price, and thereby rounds a
later victim's minted shares down toward zero — capturing the victim's deposit.

`FeeVault` uses OpenZeppelin v5's built-in **virtual shares / decimals-offset** defense:
`_decimalsOffset()` returns `6`. The conversion math becomes
`shares = assets * (totalSupply + 10^6) / (totalAssets + 1)`, so the virtual `10^6` shares and `+1`
virtual asset mean an attacker must donate on the order of `10^6 ×` the value they hope to steal, and
even then rounding favors the vault rather than the attacker. The test
`test_InflationAttack_VictimNotRobbed` drives the full attack and asserts the victim recovers
essentially all of their deposit while the attacker cannot profit.

## Fee model

Fees are realized by **minting vault shares to `feeRecipient`** (dilution) — never by pulling raw
assets out of the vault. There is no owner code path that moves user principal; the owner's only
economic claim is the accounted fee shares, which redeem pro-rata like any other shares.

Accrual happens at the start of every `deposit`/`mint`/`withdraw`/`redeem` (before pricing, so
previews and execution agree) and can also be triggered directly via `harvest()`.

### Management fee — bounded, time-based on AUM

```
mgmtFeeAssets = totalAssets * mgmtFeeBps / 10_000 * elapsed / 365 days
```

Linear in time and in AUM. Capped at `MAX_MGMT_FEE_BPS = 500` (5% annual).

### Performance fee — bounded, on yield above a high-water mark

The high-water mark (`highWaterMark`) is a **per-share price** (scaled by 1e18), seeded at the
fresh-vault price and ratcheted **up only**. On accrual:

```
if currentPricePerShare > highWaterMark:
    profitAssets    = (currentPricePerShare - highWaterMark) * totalSupply / 1e18
    perfFeeAssets   = profitAssets * perfFeeBps / 10_000
    highWaterMark   = currentPricePerShare   // ratchet up
```

Because the mark only ever rises, a **loss followed by a recovery pays no performance fee** until the
prior peak price is exceeded again — profit is never charged twice. Capped at
`MAX_PERF_FEE_BPS = 2000` (20%).

Yield itself arrives as asset flowing into the vault (a real strategy returning profit; in tests, a
direct transfer via `MockYieldSource`). Since 4626 `totalAssets()` reads the vault's asset balance,
inflows raise the per-share price automatically, and the next accrual charges the performance fee.

## Solvency invariant

`test/FeeVaultInvariant.t.sol` drives a bounded handler over the full lifecycle
(deposit / mint / withdraw / redeem / external yield / loss / time passage) and asserts:

- **Accounting completeness** — the sum of all share balances (actors + fee recipient) equals
  `totalSupply()`; the vault never mints shares anywhere else.
- **Solvency** — the assets owed to every shareholder at the current share price never exceed the
  assets the vault actually holds.

## Test

```
forge test
```

24 tests across unit, factory, and invariant suites: 4626 round-trips and proportionality, the
inflation attack, management-fee accrual and caps, performance-fee high-water behavior (including
no double-charge on recovery), owner-cannot-seize-funds, and the solvency invariants.

## License

MIT.
