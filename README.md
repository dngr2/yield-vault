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

38 tests across unit, factory, v2-feature, and invariant suites: 4626 round-trips and
proportionality, the inflation attack, management-fee accrual and caps, performance-fee high-water
behavior (including no double-charge on recovery), owner-cannot-seize-funds, the solvency
invariants, plus the v2 deposit-cap / pause / fee-increase guards below.

## Improvements (v2)

A hardening + optimization + feature pass over the shipped v1. All v1 tests remain green; the public
interface is backward-compatible (only additive functions/events/errors were introduced). The
withdrawal path is untouched by every new guard, so users can always exit.

### Security review

A line-by-line review found **no exploitable bug**. The v1 design is sound: rounding consistently
favors the vault (fee-share mint floors; `convertTo*` inherit OZ's virtual-share rounding), the
`_decimalsOffset()` virtual shares defuse the inflation/donation attack, and — crucially —
`_accrueFees()` runs at the *start* of every deposit/mint/withdraw/redeem. That accrue-before-pricing
ordering is what closes the timing games the review probed for:

- A depositor cannot front-run a harvest to capture pending yield or dodge dilution — pending fees
  are charged and the price is re-based *before* their shares are priced.
- A new depositor entering above the high-water mark is **not** over-charged performance fee on gains
  they didn't earn, because the HWM is ratcheted to the current price at their entry.
- A withdrawer cannot skip their share of a pending performance fee — accrual happens before the burn.
- Enabling/raising the performance fee never retroactively charges past gains: the setter accrues
  first (re-baselining the HWM), so only future new highs are charged.

Known, accepted limitation (not a bug, unchanged from v1): `previewX`/`maxWithdraw` are computed from
pre-accrual state, so they can be marginally optimistic between interactions; execution accrues first
and re-checks limits, so no funds are ever lost — a request simply reverts or returns slightly less.

### Gas (behavior-preserving)

Micro-opts on the accrual path, all provably identical in behavior: fold `10 ** _decimalsOffset()`
into a compile-time `VIRTUAL_SHARES` constant (drops a runtime `CALL` + `EXP` on funded accruals),
single-SLOAD the two fee rates, and skip the `highWaterMark` / `lastAccrualTime` SSTOREs when they
would rewrite the same value.

| Path (fuzz median) | before | after |
| --- | --- | --- |
| `harvest` (pure accrual) | 36133 | 35943 |

The deposit/mint paths cost ~2.1k more gas than v1 — an honest, unavoidable cost of the deposit-cap /
pause feature, which reads the `depositCap` slot inside the now-honored `maxDeposit` check. Storage is
packed so the pause flag and fee rates share one warm slot; the cap is the only added cold read.

### New features (LP-safety)

1. **Bounded deposit cap** — `setDepositCap(uint256)` (0 == uncapped, the default). `maxDeposit` /
   `maxMint` are overridden to honor it, so over-cap deposits/mints revert per ERC-4626.
2. **Deposit-only pause** — `setDepositsPaused(bool)` blocks new deposits/mints (`maxDeposit`/
   `maxMint` return 0) while leaving withdrawals and redemptions fully available.
3. **Fee-increase rate limit** — a fee *increase* may not exceed `MAX_FEE_INCREASE_STEP_BPS` (1%) per
   change and must wait `FEE_INCREASE_COOLDOWN` (7 days) since the previous increase of that fee.
   Decreases stay instant. This gives LPs time to exit before a fee ever ramps toward its hard cap.

## License

MIT.
