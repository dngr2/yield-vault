# FeeVault — a safe ERC-4626 fee vault

An [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) tokenized vault with a built-in fee layer,
meant as a base that vault operators and protocols can deploy for their LPs without re-solving the
sharp edges of 4626. Depositors put in an ERC-20 asset and receive vault shares; the operator earns a
bounded management fee on assets under management and a bounded performance fee on yield above a
high-water mark. Built on OpenZeppelin v5's audited `ERC4626`.

## Why this one

Most ERC-4626 pain is not the interface — it is the accounting around it. FeeVault's edge is that the
known failure modes are closed by construction, and that LPs keep the upper hand over the operator:

- **First-depositor inflation attack is defended.** `_decimalsOffset()` returns `6`, so the vault runs
  with `10^6` virtual shares and a virtual asset. An attacker who seeds an empty vault and donates
  assets to inflate the share price cannot round a later depositor's shares to zero — they would have
  to donate on the order of `10^6 ×` the value they hope to steal, and rounding still favors the vault.
- **The high-water performance fee never double-charges a recovery.** The mark is a per-share price
  that only ratchets up. After a drawdown, yield that merely climbs back to the prior peak pays no
  performance fee; only genuinely new highs are charged.
- **Fees are share dilution only — there is no admin path to principal.** Fees are realized by minting
  vault shares to the fee recipient, which redeem pro-rata like anyone else's. No function lets the
  owner pull user assets out of the vault.
- **Fee increases are rate-limited and LPs can always exit.** An increase is capped at 1% (100 bps)
  per step with a 7-day cooldown, so a fee can never jump to its hard cap without warning. Deposits can
  be paused, but the withdraw/redeem path is never gated — holders can leave at any time.

These properties are backed by a stateful solvency invariant and a mutation-testing pass over the fee
and safety logic (below), not just example-based tests.

## Fees

Fee accrual runs at the start of every `deposit`/`mint`/`withdraw`/`redeem` — before shares are priced,
so previews and execution observe the same post-fee state — and can also be triggered on its own with
`harvest()`.

- **Management fee** — linear in time and AUM: `totalAssets * mgmtFeeBps/10_000 * elapsed/365 days`.
  Hard-capped at `MAX_MGMT_FEE_BPS = 500` (5% annual).
- **Performance fee** — `perfFeeBps` of the profit represented by the per-share price rising above the
  high-water mark, times supply. Hard-capped at `MAX_PERF_FEE_BPS = 2000` (20%). The mark is seeded at
  the fresh-vault price and only ever ratchets up.

Yield reaches the vault as assets flowing in (a strategy returning profit; in tests, a direct transfer
via `MockYieldSource`). Because `totalAssets()` reads the vault's asset balance, inflows raise the
per-share price and the next accrual charges the performance fee on the new high.

### LP-safety controls

- **Deposit cap** — `setDepositCap(uint256)` bounds AUM (0 == uncapped, the default). `maxDeposit` /
  `maxMint` honor it, so over-cap deposits revert per ERC-4626. Lowering it never blocks withdrawals.
- **Deposit-only pause** — `setDepositsPaused(bool)` blocks new deposits and mints while leaving
  withdrawals and redemptions fully available.
- **Fee-increase rate limit** — an increase to either fee may not exceed `MAX_FEE_INCREASE_STEP_BPS`
  (1%) per change and must wait `FEE_INCREASE_COOLDOWN` (7 days) since the previous increase of that
  fee. Decreases are always instant.

All owner controls are `onlyOwner` and bounded by the on-chain hard caps above.

## Security & testing

`forge test` runs **41 tests** across five suites — unit, factory, LP-safety, a stateful invariant
suite, and a catastrophic-loss triage — all passing.

- **Solvency invariants.** `test/FeeVaultInvariant.t.sol` drives a bounded handler over the full
  lifecycle (deposit / mint / withdraw / redeem / external yield / loss / time passage) and asserts:
  - `invariant_solvent` — the assets owed to every shareholder at the current price never exceed the
    assets the vault holds.
  - `invariant_shareAccountingComplete` — the sum of all share balances (actors + fee recipient)
    equals `totalSupply()`; shares are never minted anywhere else.
  - `invariant_totalClaimBounded` — `convertToAssets(totalSupply())` never exceeds `totalAssets()`.
- **Inflation attack.** `test_InflationAttack_VictimNotRobbed` runs the full first-depositor donation
  attack and asserts the victim recovers essentially all of their deposit while the attacker cannot
  profit.
- **Mutation-tested.** The fee and safety logic was checked by deliberately corrupting it and
  confirming the suite fails. Caught mutants include: forcing the high-water comparison to always
  charge, zeroing the decimals offset, dropping `SECONDS_PER_YEAR` from the management-fee denominator,
  dropping the supply factor from the performance fee, having the pause return "unlimited" instead of
  zero, and disabling the fee-increase step guard. Two mutants survive and are noted honestly: flipping
  the fee-share mint from floor to ceil rounding (it shifts one unit toward the fee recipient but does
  not break the solvency invariant), and tightening the management-fee cap check from `>` to `>=` (a
  boundary case — no test sets a fee exactly at the hard cap).

- **Catastrophic-loss share math (triaged).** `test/SharePriceOverflowTriage.t.sol` reproduces the
  degenerate state where the vault loses nearly all assets (`totalAssets == 1`) while `totalSupply`
  stays ~1e36. In that state a realistic deposit still mints shares and remains redeemable, and even a
  ~1e6-token deposit succeeds. Only an astronomically large single deposit (~1e30 tokens) reverts, and
  that revert is OpenZeppelin `mulDiv` correctly refusing to mint more shares than a `uint256` can
  represent — it changes no state and moves no funds. This is safe refusal of an impossible mint, not a
  loss of funds; the precondition is a near-total loss that is not expected to be reachable in normal
  operation. Documented rather than "fixed" because the behavior is correct.

Gas, from this repo's own `forge test --gas-report` (fuzz medians): `harvest` ≈ 35.9k,
`deposit` ≈ 66.3k, `redeem` ≈ 63.0k.

## Contracts

- **`src/FeeVault.sol`** — the vault: standard 4626 `deposit`/`mint`/`withdraw`/`redeem`, fee accrual,
  high-water tracking, and the bounded owner controls.
- **`src/VaultFactory.sol`** — deploys and indexes `FeeVault` instances, with an optional bounded flat
  creation fee (in the vault's asset) paid to the factory's own recipient. The deployed vault is owned
  by its creator.

## Usage

Deploy a vault through the factory, then deposit and withdraw with the standard 4626 API:

```solidity
// Factory: owner, recipient of creation fees, flat creation fee (0 == none).
VaultFactory factory = new VaultFactory(owner, factoryFeeRecipient, 0);

// Create a vault: asset, name, symbol, mgmt bps, perf bps, this vault's fee recipient.
// Caller becomes the vault owner. Here: 2% mgmt, 10% perf.
address vault = factory.createVault(
    IERC20(asset), "Yield USDC", "yUSDC", 200, 1000, operatorFeeRecipient
);
FeeVault v = FeeVault(vault);

// Deposit assets, receive shares.
IERC20(asset).approve(vault, amount);
uint256 shares = v.deposit(amount, msg.sender);

// Withdraw assets (or redeem shares) back out — never gated.
uint256 assetsOut = v.redeem(shares, msg.sender, msg.sender);

// Optional: checkpoint fees without otherwise interacting.
v.harvest();
```

Direct deployment without the factory uses the same constructor the factory calls:

```solidity
FeeVault v = new FeeVault(
    IERC20(asset), "Yield USDC", "yUSDC", 200, 1000, operatorFeeRecipient, owner
);
```

Run the suite with `forge test` (Foundry, solc 0.8.26).

## License

MIT — see [LICENSE](LICENSE).

FeeVault is fee infrastructure, not a yield source. It earns nothing on its own: revenue only exists
once real assets are deposited and a real strategy produces yield for the performance fee to apply to.
There are no promised or projected returns here — the numbers above are gas and test results, not
yield.
</content>
