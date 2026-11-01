# Audit scope: Troves Ekubo CL Vault v2

Branch `claude/ekubo-cl-vaults-v2-hardening-6rm2iz` (base `main` @ `aa77b9d`). Build with the pinned toolchain
(`.tool-versions`: Scarb 2.18.0, Starknet Foundry 0.63.0); class hashes of the release build are in
`deployments/class-hashes.json` and checked by CI.

## In scope

| File | What |
|---|---|
| `src/cl_vault/cl_vault.cairo` | The vault (ERC-20 shares over N Ekubo ranges of one token pair) |
| `src/cl_vault/interface.cairo` | ABI, structs, events |
| `src/cl_vault/migrations/v1_v2.cairo` | One-shot v1 -> v2 upgrade + role handover |
| `src/components/swap.cairo` | AVNU multi-route swap wrapper (output measured by balance delta) |
| `src/ekubo.cairo`, `src/interfaces/*` | Own minimal Ekubo / Vesu-oracle ABIs (must match deployed contracts) |
| `src/helpers/*` | ERC-20 helper, pow10, constants |

Out of scope (unmodified third-party code, pinned): OZ 3.0.0 components and `TimelockController` component
(`src/governance/timelock.cairo` only embeds it), `starkware-starknet-utils` @ `3e2fd53` (roles, pausable,
replaceability, `MultiExecutor`), Vesu v2 oracle class (deployed as a Troves-owned instance), Ekubo, AVNU.

## Trust model

| Actor | Can | Cannot |
|---|---|---|
| Users | deposit (paused: no), withdraw (always, incl. paused), `*_with_min` slippage bounds | - |
| OPERATOR (relayer key) | rebalance / harvest within guard-rails | swap to non-vault tokens; swap with oracle-checked loss > `max_slippage_bps`; swap more than `max_swap_amount*`; rebalance more often than `min_rebalance_interval`; mint when the pool is > `max_pool_tick_deviation` from the oracle; move bounds of a non-empty range, or outside `max_bounds_distance` of the oracle |
| APP_GOVERNOR | fees (<= 100%), guard-rails, oracle, pools, timelock allowlist / min delay | act unless the caller is an allowlisted timelock class with delay >= `min_timelock_delay`; remove its own timelock class |
| UPGRADE_GOVERNOR | upgrade via Replaceability | upgrade before `upgrade_delay` (= `min_timelock_delay` at deploy) |
| SECURITY_AGENT / SECURITY_GOVERNOR | pause / unpause | - |
| Oracle (Troves Vesu v2 instance) | prices; stale / low-source prices are rejected (`is_valid`) | - |

## Key invariants (tested on a mainnet fork, incl. fuzz / stateful)

1. `total_supply == Σ user shares + 1000 dead shares` (dead shares minted to the vault on first deposit).
2. Shares are a pro-rata claim on every range's liquidity **and** idle balances; deposit pulls at most the offered
   amounts; deposit -> withdraw is never profitable and loses at most the Ekubo withdrawal fee.
3. Σ user claims <= vault holdings (positions + idle), per token.
4. Value per share does not drop by more than the Ekubo withdrawal fee per operation (relayer swaps bounded by
   `max_slippage_bps`).
5. Every user can always exit (withdraw is not pausable; empty ranges are skipped).

Tests: `src/cl_vault/test_audit.cairo` (finding regressions + guard-rails + governance),
`src/cl_vault/test_invariants.cairo` (fuzz, stateful invariants, sandwich), `src/cl_vault/test.cairo` (legacy
functional), `src/cl_vault/migrations/test_v1_v2_migration.cairo` (live v1 vault).

## Areas we want reviewed most

- Share math: `_convert_to_shares` / `_user_amounts_for_shares` (rounding direction, the down-scaling loop for the
  dust state), `_withdraw` idle share, dead shares.
- Oracle tick derivation (`_oracle_tick`: 512-bit ratio, sqrt, `sqrt_ratio_to_tick`) and its use as a manipulation
  bound; tick-distance arithmetic on `i129`.
- Rebalance flow ordering (fee collection before burn, bounds change only for empty ranges, NFT reuse).
- Timelock caller check (`get_class_hash_at` + per-class delay selector via `call_contract_syscall`) and the
  self-lockout rule.
- v1 -> v2 migration: `initialize_roles_from_v1` gating (v1 DEFAULT_ADMIN), role handover, storage-slot reuse of
  the legacy `access_control` address, guard-rail initialisation.
- Own Ekubo ABIs: Serde / `i129` storage packing equivalence with Ekubo.

## Known limitations / accepted risks

- The timelock check trusts allowlisted classes to report their real delay (OZ `get_min_delay`, StarkWare
  `get_execution_delay`); instances with a shorter delay are rejected. Any instance still needs APP_GOVERNOR,
  which only APP_ROLE_ADMIN (itself behind GOVERNANCE_ADMIN = timelock) can grant.
- After the v1 migration the migration contract still holds GOVERNANCE_ADMIN / SECURITY_ADMIN until the new admin
  calls `remove_governance_admin` / `remove_security_admin` (StarkWare roles forbid self-renounce).
- `harvest` takes an arbitrary `rewardsContract` (distributor allowlist deferred); output swaps are oracle-checked.
- Harvest sniping (deferred with harvest): rewards are added to idle balances in one step, so a large
  deposit right before a known `harvest` and a withdraw right after captures most of the rewards.
  Options: stream harvested value over time, a minimum holding period / exit fee, or private harvest txs.
- Guard-rails are explicit deploy / migration arguments (no contract defaults); `min_rebalance_interval = 0` or
  unlimited swap caps are allowed but let a leaked OPERATOR key compound losses within one block.
- Fees are re-deposited only within `max_pool_tick_deviation` of the oracle; otherwise they stay idle (counted in
  the share price) until the next rebalance. `withdraw` only collects fees, never adds liquidity.
- Within its guard-rails the OPERATOR can still lose up to `max_slippage_bps` per rebalance.
- Constructor `min_timelock_delay > 0` is enforced but not unit-tested (snforge aborts on constructor reverts).
