# Phase 2 — Rails Real Integration Slice

Does the **Proposal + Outbox + CapsuleContext** protocol stay sound when it leaves the synthetic files+flock model
and runs on **real ActiveRecord + a real Postgres**? Target is correctness, not performance.

Real stack (all run/measured): **ActiveRecord 8.1.3 + ActiveSupport 8.1.3 + pg 1.6.3 on Ruby 4.0.5**, against
**Postgres 16** in a disposable Docker container (PG ≥ 9.5 works; local PG14 is a drop-in fallback).

> **Scope note (deliberate):** this is the real AR + AS persistence stack, *not* a full `rails new`. Every gate is
> a DB/AR-layer property (transaction, `lock_version`, unique index, `after_commit`, concurrent connections); none
> touch HTTP. The unused web tier would only add Ruby-4.0 boot risk. See `../docs/decisions.md` (Phase 2).

## Run

```sh
colima start --cpu 8 --memory 6      # if the Docker VM isn't up
./run.sh                              # boots/reuses the capsule_pg container, loads schema, runs the 10 gates
```

`run.sh` sets `DATABASE_URL=postgres://capsule:capsule@127.0.0.1:65432/capsule_test`. Override `DATABASE_URL` to
point at any Postgres (e.g. the local PG14). `AR_LOG=1` prints the real SQL the protocol emits.

## Files

| file | role |
|---|---|
| `boot.rb` | requires + real AR connection from `DATABASE_URL` |
| `schema.rb` | force-recreates the real tables: `orders.lock_version`, unique `outbox_events.idempotency_key`, `external_charges` (the idempotent external consumer's dedup store) |
| `domain.rb` | `User`, `Order`, `OutboxEvent`, `ExternalCharge`, `Current` (ActiveSupport::CurrentAttributes) |
| `capsule.rb` | `CapsuleContext`, `EffectIntent`, `Proposal`, `CommitCoordinator` (one tx: optimistic update + outbox insert), `OutboxDispatcher` (FOR UPDATE SKIP LOCKED; deliver and publish-mark in **separate** commits → honest at-least-once), `ExternalConsumer` (idempotent) |
| `adversarial_service.rb` | resistant Rails code (Current / captured-callback / native-ext / pre-commit side effect) + each transform |
| `worker_dispatch.rb` | one spawned dispatcher process (never forked — libpq is not fork-safe on macOS) |
| `worker_commit.rb` | one spawned committer process racing on `lock_version` (exactly one wins) |
| `test/slice_b_test.rb` | the 10 gate tests |

## Gates (all green, stable across 15+ runs)

`test_commit_conflict_drops_outbox` · `test_commit_and_outbox_are_atomic` · `test_idempotency_key_is_unique` ·
`test_concurrent_dispatchers_dedupe` · `test_crash_after_commit_before_dispatch_recovers` ·
`test_current_requires_capsule_context` · `test_callback_requires_descriptor` ·
`test_native_extension_uses_owner_fallback` · `test_concurrent_committers_one_wins` (reinforce gate 1) ·
`test_raw_path_charges_precommit_capsule_defers` (reinforce gate 6).

**Claim:** exactly-once outbox **enqueue** (real unique index) + idempotent **at-least-once** dispatch (the consumer
dedups by `idempotency_key`). NOT exactly-once external side effect.

## Teardown

```sh
docker rm -f capsule_pg        # the container is disposable
colima stop                    # if you're done running
```
