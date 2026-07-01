# Ractorized Rails Kernel Architecture

## Purpose

`ractorized-rails-kernel` is a research repository. It is not a deploy target, framework, or product
runtime. The point of the repository is to preserve falsification-grade evidence for one narrow question:
can a Rails-adjacent compute slice be transformed into Ractor-executable work without erasing the memory
economics that motivated the experiment?

The repository is therefore organized around evidence layers, not around a runnable product shell.

## Evidence Layers

### Phase 1: Economic Gates

Root scripts such as `refork_gate.rb`, `frontier_harness.rb`, `a2_gateway.rb`, and `a2_cache_sync.rb`
measure where the thesis survives and where it dies. These are synthetic but adversarial probes. The
current authoritative verdict is still frozen in [`phase3_migration/FINDINGS.md`](../phase3_migration/FINDINGS.md):
the protocol work is strong, but the final Linux economic gate is not yet fully cleared.

### Phase 2: Owner-Side Rails Protocol

[`rails_capsule_slice_b/`](../rails_capsule_slice_b/) proves the transactional protocol against real
ActiveRecord and PostgreSQL. This is where the repository demonstrates optimistic locking, outbox enqueue,
dispatcher recovery, and idempotent at-least-once delivery in a shape that matches the thesis.

### Phase 2b: Booted Rails Capsule Proof

[`rails_capsule_mini_app/`](../rails_capsule_mini_app/) boots a real Rails app and proves the smaller but
more important claim: Rails globals fail inside a Ractor, while a bounded capsule compute path can still
run with shareable inputs and owner-side commit coordination.

### Phase 3: Promotion Audit

[`phase3_migration/FINDINGS.md`](../phase3_migration/FINDINGS.md) and the linked raw logs are the promotion
gate. They decide whether the thesis can move from "interesting protocol" to "economically justified
architecture". At the time of writing, that answer is still "not yet".

## Reviewer Path

For a fast review, use the repository surfaces in this order:

1. `bin/setup`
2. `ruby -Itest test/research_contract_test.rb`
3. `bin/check`
4. `bin/research-check` when the external `phase3_migration/discourse/` checkout is available, or with
   `DISCOURSE_DIR=/absolute/path/to/discourse` when the checkout lives elsewhere

The root test file is intentionally small. It proves that the repository still exposes the architecture
document, the root verification path, and the two real proof slices.

## Boundaries

- No deploy manifest is provided because this repository is not a product runtime.
- No claim is made that an entire Rails web request runs inside a Ractor.
- No claim is made that the final Linux host gate has passed.
- No gem, engine, or public DSL is implied by the current evidence.
- The deepest evidence audit depends on a local external Discourse checkout and therefore stays outside public CI.
