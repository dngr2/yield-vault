# FeeVault — pitch

**What it is.** A drop-in ERC-4626 tokenized vault with a built-in fee layer — a bounded management fee
on AUM plus a bounded performance fee on yield above a high-water mark — meant as a safe base for vault
operators and protocols to deploy for their LPs.

**Why it matters.** ERC-4626 is the standard interface for yield vaults, so a compliant vault plugs
straight into aggregators, lending markets, and front-ends. But the interface is the easy part; the
accounting around it is where implementations fail. FeeVault closes the two that sink most of them —
the first-depositor inflation attack and fee logic that either double-charges LPs or lets operators
reach principal — and keeps LPs able to exit at all times.

**The edge.**
- **Inflation-attack safe by construction** — OpenZeppelin v5 virtual-shares defense, decimals offset
  6. Seeding-and-donating to round a later depositor's shares to zero would cost ~1e6× the value hoped
  for, and rounding still favors the vault. Covered by a full attack test.
- **Fair performance fee** — a per-share high-water mark that only ratchets up, so a drawdown followed
  by a recovery pays no performance fee until a genuinely new high is reached. Profit is never charged
  twice.
- **No path to principal** — fees are minted as shares to the fee recipient and redeem pro-rata; no
  function moves user assets. Fees are hard-capped on-chain (5% mgmt, 20% perf).
- **LPs keep the upper hand** — fee increases are capped at 1% per step with a 7-day cooldown, and
  while deposits can be paused, withdrawals and redemptions are never gated.

**Correctness.** Built on OpenZeppelin's audited base. `forge test` runs 38 passing tests, including a
bounded stateful invariant suite proving the vault stays solvent and fully share-accounted across
arbitrary deposit / withdraw / yield / loss / time sequences, plus a hand-mutation pass over the fee
and safety logic (two surviving mutants disclosed honestly in the README).

**Monetization.** Operators set their own fee split per vault. A `VaultFactory` spins up vaults on
demand and can levy a bounded flat creation fee — a second revenue stream at the platform layer. Note
the vault is fee infrastructure, not a yield source: it earns nothing until real assets are deposited
and a real strategy produces yield. No returns are promised or projected.

**Status.** Clean-room Solidity on OZ v5, Foundry-tested (solc 0.8.26), MIT-licensed, ready to audit.
</content>
