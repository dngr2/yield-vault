# FeeVault — pitch

**What it is.** A drop-in ERC-4626 tokenized vault with a built-in revenue layer: a bounded
management fee on AUM plus a bounded performance fee on real yield, above a high-water mark.

**Why it matters.** ERC-4626 is the standard interface for yield vaults across DeFi — aggregators,
lending markets, and front-ends already speak it. Shipping a vault that is 4626-compliant means
instant integration surface. But two things sink most vault implementations: the first-depositor
inflation attack, and fee logic that either double-charges users or lets operators drain principal.
FeeVault closes both.

**Safety.**
- **Inflation-attack safe** by construction — OpenZeppelin v5 virtual-shares defense with a 6-decimal
  offset. An attacker would need to burn ~1e6× the value they hope to steal, and rounding still
  favors the vault. Demonstrated by a full attack test.
- **No principal seizure** — fees are minted as *shares* to the fee recipient, diluting pro-rata.
  There is no code path for the owner to move user assets. Owner controls are hard-capped (5% mgmt,
  20% perf) and enforced on-chain.
- **Fair performance fee** — a per-share high-water mark that only ratchets up, so users never pay a
  performance fee twice on the same profit after a drawdown and recovery.

**Correctness.** Built on OpenZeppelin's audited base, 24 passing tests including a bounded
stateful invariant suite proving the vault stays solvent and fully share-accounted across arbitrary
deposit / withdraw / yield / loss / time sequences.

**Monetization.** Operators set their fee split per vault. A `VaultFactory` spins up vaults on demand
and can levy a bounded flat creation fee — a second revenue stream at the platform layer.

**Status.** Clean-room Solidity on OZ v5, Foundry-tested, MIT-licensed, ready to audit.
