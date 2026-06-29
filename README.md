# Ractorized Rails Kernel — falsification experiment

R&D program testing whether Rails' stateful global dependency graph can be virtualized into
Ractor-executable capabilities **without destroying the performance economy**. Falsification-first:
the goal of these scripts is to try to KILL the thesis cheaply, not to admire an elegant layer.

See [`docs/decisions.md`](docs/decisions.md) for the locked spec, gates, and results.

> **Current verdict (2026-06-16): PIVOT / narrow R&D — not a product, runtime, or platform.**
> `economic_final_gate_passed=false`, `economic_survives_any_current_matrix=false`: **no current Linux matrix has a
> surviving alloc**. The `hash` +210/+314MB numbers in *"Legacy calibrated probe"* below are a single 2026-06-14
> `refork_gate` run — a legacy calibrated probe, **not** a passed final economic gate and **not** product-authorizing.
> `struct` is memory-favorable but **throughput-unconfirmed**; `blob` is an economic no-op. The transactional/outbox
> protocol is solid; the **economic thesis is unresolved**. Authoritative verdict:
> [`phase3_migration/FINDINGS.md`](phase3_migration/FINDINGS.md) (`# Current evidence verdict`). Next real experiment:
> a larger **Linux** process/refork gate (calibrated datasets, POOLS=1..N, REPS≥6, DURATION≥8, equivalent throughput,
> absolute PSS ≥100MB) — not the mini-app.

## Setup (facts)

- Ruby **4.0.5** (`.ruby-version`; local runs here used Homebrew at `/opt/homebrew/opt/ruby/bin/ruby`)
- Fast proof surfaces need a real PostgreSQL instance; `bin/check` defaults to local Unix-socket databases
  `capsule_railsapp_test` and `capsule_test`
- Linux memory gate still needs **Linux** plus Docker or an equivalent host for the expensive process/refork runs

## Repository contract

- This repo is an **R&D asset**, not a productized runtime. There is intentionally no deploy manifest, Procfile,
  or production rollout story.
- `bin/setup` installs the three Bundler contexts that matter here: the root smoke dependency, the booted Rails
  mini app, and the real ActiveRecord/Postgres Slice B.
- `bin/check` is the fast falsification contract:
  - `test/research_contract_test.rb`
  - `day1_smoke_test.rb`
  - `rails_capsule_mini_app` booted-Rails protocol tests
  - `rails_capsule_slice_b` real ActiveRecord/Postgres protocol tests
- `.github/workflows/ci.yml` runs that same contract on GitHub Actions with a PostgreSQL instance.
- `phase3_migration/discourse/` is treated as an **external local checkout of upstream Discourse**, not part of this
  outer repository history. The outer repo tracks the patch, scripts, raw logs, and findings that describe how that
  checkout was used.

## 5-minute evaluation

```sh
bin/setup
ruby -Itest test/research_contract_test.rb
bin/check
```

To use a non-default Postgres, override the database URLs instead of editing files:

```sh
MINI_APP_TEST_DATABASE_URL=postgres://user:pass@127.0.0.1:5432/capsule_railsapp_test \
SLICE_B_DATABASE_URL=postgres://user:pass@127.0.0.1:5432/capsule_test \
bin/check
```

`bin/check` is intentionally the reviewer path. The expensive Linux economic gates remain separate manual experiments,
with the current authoritative verdict frozen in [`phase3_migration/FINDINGS.md`](phase3_migration/FINDINGS.md).

## Deep research audit

When you have the external local Discourse checkout at `phase3_migration/discourse/`, run:

```sh
bin/research-check
```

That script reruns the machine audit behind the frozen findings in
[`phase3_migration/FINDINGS.md`](phase3_migration/FINDINGS.md). It is deliberately
**not** part of GitHub Actions because the Discourse checkout is a local research
fixture, not vendored repository content.

## Scripts

| file | what it answers | where it runs |
|---|---|---|
| `day1_smoke_test.rb` | Do the Ruby 4.0 Ractor mechanics work as assumed? (Port, move, make_shareable, native-ext failure class, boundary copy tax). Exits non-zero on unexpected outcome. | macOS or Linux |
| `refork_gate.rb` | **Canonical economic gate** — Ractor vs warmup-process vs **refork** (Pitchfork-style); frontier / iso-throughput; GC.stat; shape matrix (`hash/struct/blob`) | **Linux only** |
| `frontier_harness.rb` | Shape matrix (hash/struct/blob) throughput+PSS frontier (own kernel — not yet on `bench_kernel`) | **Linux only** |
| `a2_gateway.rb` | A2.1 async-logger gateway tax (producer-side; backlog 0) | **Linux only** |
| `a2_cache_sync.rb` | A2.3 bounded-**SYNC** cache read — round-trip latency p50/95/99, timeouts, the chatty-sync killer | **Linux only** |
| `slice_b_rails_adversarial.rb` | Slice B — Rails resistance (Current/callback/native-ext) + outbox protocol; T1-T6 incl. crash recovery + concurrent committers/dispatchers (flock). Claim: exactly-once **enqueue** + idempotent **at-least-once** dispatch (NOT exactly-once external effect) | any (logic+fork+files) |
| `bench_kernel.rb` | shared **hash/A2** kernel (hash-shape dataset/compute/work + smaps/isolated/GC.stat/make_items/shard/median). The decisive `refork_gate.rb` defines its **own** shape-aware `build_dataset`/`compute`/`work` for `hash/struct/blob` and consumes this only for infra helpers — so the economic gate is not literally the shared kernel. | lib |
| `a1_compute_baseline.rb` | (early) throughput-only Ractor vs process vs thread control | macOS |
| `mem_gate.rb` | **SUPERSEDED** by `frontier_harness.rb` (single 4-vs-N point; deprecated, aborts without `RUN_DEPRECATED=1`) | Linux (deprecated) |

## Run

```sh
RUBY=/opt/homebrew/opt/ruby/bin/ruby

# mechanics (exits non-zero on unexpected probe outcome)
bundle exec $RUBY day1_smoke_test.rb

# booted Rails protocol proof (real Rails app, real Postgres)
(
  cd rails_capsule_mini_app
  RAILS_ENV=test TEST_DATABASE_URL=postgres:///capsule_railsapp_test bundle exec bin/rails db:prepare
  RAILS_ENV=test TEST_DATABASE_URL=postgres:///capsule_railsapp_test bundle exec ruby test/capsule_rails_test.rb
)

# real ActiveRecord/Postgres protocol proof (Docker bootstrap only when DATABASE_URL is unset)
(cd rails_capsule_slice_b && DATABASE_URL=postgres:///capsule_test ./run.sh)

# decisive gate (Linux, dedicated cores — run docker runs SERIALLY, never in parallel:
# parallel containers oversubscribe the VM and corrupt throughput numbers)
colima start --cpu 8 --memory 6
docker run --rm -v "$PWD":/app -w /app -e POOLS=1,2,3,4 -e SHAPES=hash \
  -e N_RULES=1000000 -e ALLOC=100 -e REPS=4 ruby:4.0-slim ruby frontier_harness.rb

# A2.1 gateway tax (sweep CAP_EVERY for the frequency envelope)
docker run --rm -v "$PWD":/app -w /app -e ALLOC=100 -e CAP_EVERY=10 ruby:4.0-slim ruby a2_gateway.rb
```

## Legacy calibrated probe (2026-06-14) — a single `refork_gate` run, NOT the current final gate

Gate #1 (`refork_gate.rb`) ran at **calibrated ~400MB resident datasets** (hash N=2.3M / struct N=5M / blob N=26M,
sized by `size_probe.rb`), wall-clock refork cadence, against the **strong Pitchfork-style refork** baseline.
Throughput is net of the smaps-snapshot measurement artifact (excluded ≤2.3% of wall at 1s cadence; the *fork* cost
stays — it is a real refork penalty). Gate = PSS ratio ≤80% **AND** absolute saving ≥100MB **AND** throughput reach
≥75% **AND** spread doesn't straddle.

**Single-probe result — one narrow, conditional win; falsified on every other axis. This is a legacy calibrated probe, NOT a passed final economic gate; the current verdict is PIVOT (see banner above and FINDINGS.md):**
- **`hash` @ ALLOC=100 (Rails-like) → SURVIVES:** 71% PSS, **+210MB absolute**, 97.7% throughput reach.
- **`hash` @ ALLOC=500 (heavy) → SURVIVES** (REPS=6/DUR=8): 62% PSS, **+314MB absolute**, 90.2% reach (`reach_lo` 76.2%).
  Was INCONCLUSIVE at REPS=4 — the spread guard correctly refused it until a longer run tightened it.
- **`blob` (compact/packed) anywhere → ECONOMIC NO-OP:** saving always ~5–20MB (<100MB). A packed string barely breaks
  CoW, so there is nothing to save. Confirms "fails for compact/packed state" with hard numbers.
- **ALLOC=0 → process wins** (CoW intact, no allocation pressure). Negative control: the harness kills its own thesis.
- **`struct` @ ALLOC=100 → ractor uses MORE memory** (115% ratio); Data-structs only show a memory win under heavy load…
- **`struct` @ ALLOC=500 → memory win ROBUST (~528–578MB, ~48–55% ratio) BUT throughput-UNCONFIRMED.** A decisive re-run
  (N=5M, REPS=6, DUR=8) gave reach **110% (survives)**; an identical-config earlier run gave **71% (inconclusive)** — a
  40-pt swing from the refork baseline's heavy-allocation throughput variance (44–50% per-cell spread). So the memory win is
  real and large but the throughput gate can't be confirmed → NOT a clean pass. (`struct` @ ALLOC=100 fails outright: 54MB
  saving < floor.) Cause: one shared GC across all Ractors vs N process GCs under heavy Data-struct churn.
- **Aggressive 0.3s refork claws the hash win 210MB → 50MB** (economic no-op). The edge needs a non-aggressive cadence.
- **GC mechanism MEASURED:** ALLOC=0 → ~0 allocs, CoW intact, process wins; ALLOC≥100 → CoW broken, process/refork PSS balloons.
- **A2 bounded-SYNC cache read — 3D `SCAN×ALLOC×CAP_EVERY` matrix MEASURED** (72 cells, the `gateway_calls/compute_ms`
  axis): **12 tolerable, 53 fail, 7 inconclusive**; the aggressive-timeout negative control fails all 36. **Chatty sync
  (read every item) fails at every SCAN/ALLOC** (tax 32–92%); **infrequent sync (≈1 read per ≥100 items, or ≥10 under heavy
  compute) at ALLOC≤100 is tolerable** — never under heavy allocation. So sync deps in capsules must be rare or forbidden,
  now measured, not asserted. (Async-logger tax was separately frozen: NOT "≤3.5% at any frequency".)

**Measured niche (bounded):** large frozen **hash-shaped** read models + **moderate-to-heavy Rails-like allocation** +
**non-aggressive (~1s) refork cadence** → definitive win (210–314MB absolute, ≤71% PSS, ≥90% throughput). Outside it —
compact/packed state, zero allocation, Data-structs (throughput-limited), or aggressive reforking — the strong baseline
ties or wins. **NOT a general "Ractors save memory" claim.** **Still future (not claimed):** real Rails workload perf,
migration at scale, Promotion amortization benchmark. See [`docs/decisions.md`](docs/decisions.md) (2026-06-14 Gate #1).

**Strong host-gate v2 (`strong_host_gate_v2.rb`, 2026-06-16) — REDUCED, NOT the final gate.** A bias-corrected runner
(7-model strong-baseline battery incl. `GC.compact` / `Process.warmup` / prefork-warmed / refork; full
PSS/Private_Dirty/Shared_Clean/Shared_Dirty breakdown; every fairness lever made symmetric after a 4-skeptic adversarial
review, with a per-REPS memory-variance band gate added on top). A REDUCED Linux pass (hash @ 200MB, REPS=3, DUR=3):
**ALLOC=0 → PIVOT** (95MB saving, 68% PSS — below the 100MB floor; negative control fires); **ALLOC=100 → Ractor 51% PSS / 263MB saving /
94% reach** vs the strongest *static* baseline (`process_gc_compact_plus_warmup`), but **only at the w4 operating point (single-point)**. A strong reduced signal that the win survives the STRONG baselines (not
just refork), mechanism measured (process Private_Dirty multiplies with workers; the Ractor's stays flat). **NOT a passed
full gate** — REPS≥6/DUR≥8/≥500MB/struct+blob/multi-point unrun; the verdict stays **PIVOT**. Full-host command + table in
[`phase3_migration/FINDINGS.md`](phase3_migration/FINDINGS.md) (Audit #55).

**Slice B (16/16):** resistant Rails patterns are locally transformable (CapsuleContext / descriptor / owner
fallback), and the proposal+outbox protocol is sound in a files+flock model under concurrent committers (T5) and
dispatchers (T6). **Precise claim:** exactly-once outbox *enqueue* + idempotent *at-least-once* dispatch — the
outbox does NOT make the external effect exactly-once; the consumer's idempotency_key dedup does.

**Dispatcher LEASE (ratified 2026-06-14):** the canonical `OutboxDispatcher` now claims with a flat **time-bounded lease**
(`claimed_at`/`locked_until`/`attempt_count`) on top of FOR UPDATE SKIP LOCKED; deliver and publish-mark stay **separate
commits** and the frozen claim is **unchanged**. Crash recovery is now lease-gated (a dead worker's row is reclaimable after
`locked_until`). Measured: leased 30s → **+0% duplicate attempts** vs non-leased **+197%→+487%** (zero-lease control +181%).
Verified green: slice_b 13/62, mini_app 20/109. (This deliberately lifted the earlier "no lease yet" deferral — see
[`docs/decisions.md`](docs/decisions.md) "Lease ratified".)

## Phase 2 — Rails Real Integration (`rails_capsule_slice_b/`, 2026-06-13) — 10/10 GREEN

The protocol leaves files+flock and runs on **real ActiveRecord 8.1.3 + pg 1.6.3 on Ruby 4.0.5 against a real
Postgres 16** (disposable Docker container; PG14 fallback). 10/10 gate tests, stable across 15+ runs:
real `transaction` atomicity, real optimistic `lock_version` → `StaleObjectError` (deterministic **and** under 6
genuinely-concurrent spawned committers — exactly one wins), a real unique index as the enqueue-once guarantee, and
a real **multi-process** (spawned, not forked — libpq is not fork-safe on macOS) dispatcher that strands nothing and
delivers each effect once at the consumer (stress: 500 events / 6 workers / 0 stranded). The 3 resistant Rails
patterns are transformed (Current→CapsuleContext, callback→descriptor, native-ext→owner fallback) or fail by a
named error. The dispatcher was corrected during the support-skill review to deliver and publish-mark in **separate
commits** so it does not fake exactly-once. Run: `rails_capsule_slice_b/run.sh` (or set `DATABASE_URL` to skip the
Docker bootstrap and use an existing Postgres). Details in
[`docs/decisions.md`](docs/decisions.md) (Phase 2).

### Phase 2 falsification battery (16 items, raw evidence) + REAL booted Rails app

A skeptical reviewer rejected "10/10" and demanded falsification with raw evidence + mutation tests. Result: **26
test methods green on macOS AND Linux** (`ruby:4.0-slim`, `aarch64-linux`), **5/5 mutation tests caught** (break the
unique index / `lock_version` / SKIP LOCKED / deterministic key / delivery → suite turns red), and a **fully booted
Rails 8.1.3 app** (`rails_capsule_mini_app/`, eager_load, real `Current`/`Rails.cache`/`Rails.logger`/`after_commit`)
where the same gates pass (15 runs / 75 assertions) and **touching a Rails global inside a Ractor raises**
(`Rails.cache`/`logger` → `Ractor::IsolationError`; `Current.user` → `RuntimeError` un-shareable Proc). Highlights:
3 real crash windows (incl. mark-before-deliver loses the effect forever), 10k-event/16-worker stress (0 stranded, 0
dups), real Nokogiri `Ractor::UnsafeError`, the `request_id` precondition shown (reused id silently drops an op). The
battery found **two real defects in my own work** (a test guarding a copy of the logic, caught by mutation testing; a
dispatcher that faked exactly-once, caught by the support-skill review) — both fixed. Full raw evidence in
[`docs/decisions.md`](docs/decisions.md) (Falsification battery + #16).

## STRICT CLAIM (FROZEN — corrected after the false-PASS review)

**Frozen Read-Model Capsules are validated in three dimensions:**
1. **Synthetic in-niche economy** — large frozen/shareable Ruby state + moderate allocation + small payload. NOTE: an
   economic PASS now requires an **absolute** saving (≥100MB AND ≤80% PSS); a high ratio on a small dataset is an
   "economic no-op", not a win. The A2 gateway "cheap at any frequency" claim was **withdrawn** (the real axis is
   gateway_calls/compute_ms; needs a SCAN×ALLOC×CAP_EVERY matrix).
2. **Transactional protocol** — proposal + optimistic commit + outbox + idempotent at-least-once dispatch. This is
   validated **owner-side** on real ActiveRecord/Postgres.
3. **Rails owner-side protocol + a Ractor-executable capsule** — booted Rails 8, real ActiveRecord/Postgres, Rails
   globals failing inside a Ractor, and the capsule compute path builds a deeply shareable `Proposal` + `EffectIntent`s
   **inside a non-main Ractor** over a shareable `CapsuleContext` + `OrderSnapshot` (no AR, no globals). The owner
   still commits, and the coordinator refuses mutable/non-shareable proposals.

**Validated:** owner-side proposal/outbox protocol in real Rails · Rails-globals isolation in a Ractor · the capsule
*compute* step running in a Ractor over a small shareable snapshot · deeply shareable proposal/effects ·
outbox/idempotency on real Postgres · native-extension fallback · named failures for Current/callbacks.
**NOT validated:** migration cost at scale in an existing app · performance with a real Rails workload · the full web
request lifecycle · broad gem/call-site coverage · production operation · a *whole* Rails request served from a Ractor.

Do **not** claim "Rails apps migrate easily", "ready for a gem", "solves Rails in Ractors", or "Rails capsule runtime
validated" (only the compute step is Ractor-proven; the protocol is owner-side). **Blocked:** product, gem, public DSL,
Rails engine, ActiveJob adapter, actor registry, CDC/deltas, request capsules, callback compiler.

**Next — economic re-confirmation BEFORE any more migration (2026-06-14 verdict).** Phase 3 (Promotion) proved
architectural *compatibility*, not an end-to-end perf win (owner snapshot build+decide = 0.21× inline; the 3.77×
parallel speedup is on the pure decide only). So do NOT migrate more Discourse subsystems yet. Gate order:
1. **`refork_gate` grande on Linux** — `hash`/`struct`/`blob`, large datasets, PASS only if PSS ratio ≤70–80% AND
   absolute saving ≥100MB AND throughput ≥75–80% of the process/refork baseline AND correct=yes AND the spread does
   not straddle the gate. No small smoke counts.
2. **Promotion amortization benchmark** — N ∈ {100, 1k, 10k} users vs the SAME frozen read model; (owner snapshot per
   user + capsule decide) vs (process/refork) vs (inline full); report snapshot/decide/boundary cost, throughput, PSS,
   payload bytes. Decides whether Promotion is a real case or only compatibility.
3. Only then decide whether to migrate another real subsystem.

If even a large `hash` cannot hold ≥100MB absolute saving, the economic thesis must pivot to "only large CoW-hostile
Ruby graphs". Blocked items (gem/DSL/engine/...) unchanged. See [`docs/decisions.md`](docs/decisions.md) (2026-06-14).
