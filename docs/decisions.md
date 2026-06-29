# Decisions — Ractorized Rails Kernel

Append-only technical decision log. Newest at bottom.

---

## 2026-06-13 — Thesis framing locked

**Decision.** The project is NOT "Ractor accelerates Rails". It is a falsification-first
R&D program for a *Ractorized Rails Kernel*: transform Rails' implicit shared-mutable-global
dependency graph into Ractor-executable capabilities (frozen application image, explicit
CapsuleContext, message-passing gateways, read-model replicas, versioned proposals + commit
coordinator, EffectIntent→outbox for side effects, Ractor-safe Rails subset).

**Success metric (corrected).** Not "Ractor ≥2× faster". The honest bar is:
> equivalent throughput vs a **process pool** at materially lower memory, without duplicating
> side effects.

Thread pool is only a *negative control* (GVL serializes CPU-bound Ruby).

**Gates (locked).** Baseline = process pool. Memory measured as PSS / Private_Dirty on Linux
(`/proc/smaps_rollup`), NOT RSS (RSS double-counts CoW) and NOT macOS (CoW differs; prod is Linux).
- throughput ≥ 85–90% of process pool
- Ractor PSS ≤ 70–80% of the **warmup-protected** process pool
- copy tax ≤ 20–30% of compute
- gateway overhead ≤ 10–15% (A2)

**Death conditions:** throughput <85% best case; PSS not ≤~80%; copy tax >30% on common
payloads; gateway >15%; Slice B requires rewriting the whole service; effects can't be deferred
to outbox; per-Ractor DB connections cancel the memory win.

**Slice A = best case for Ractor:** CPU-bound compute over a LARGE FROZEN SHARED dataset
(pricing/catalog/risk), entering as `Ractor.make_shareable` snapshot — NOT a live replica.
Replicas/CDC deferred to a later milestone to avoid contaminating the economic measurement.

---

## 2026-06-13 — Environment (facts, not assumptions)

- Ruby pinned to **4.0.5** (Homebrew, keg-only) at `/opt/homebrew/opt/ruby/bin/ruby`.
  Confirmed `+PRISM`, `Ractor::Port`, `make_shareable`, `#value`/`#join`, `shareable?`. Ractor
  still **experimental** in 4.0.5 (warns on STDERR).
- Linux memory gate runs in **colima** (Linux VM, 4 cpu / 4GB) via Docker, image `ruby:4.0-slim`
  (= Ruby 4.0.5 aarch64-linux). macOS has no `/proc`; `footprint`/`vmmap` are proxies only.

---

## 2026-06-13 — Day-1 smoke test (`day1_smoke_test.rb`) PASSED

All Ractor 4.0 mechanics confirmed by execution on 4.0.5:
- `Ractor::Port` request/reply works; Port is shareable & passable inside a message (gateway pattern).
- Gateway must be drained on a **dedicated thread** in main (deadlock check passes).
- `make_shareable` on nested config → shareable; zero-copy read in worker.
- `move: true` transfers ownership; sender then raises `Ractor::MovedError`.
- **Native-ext failure PROVEN, not assumed:** `Nokogiri::HTML4` from a non-main Ractor raises
  `Ractor::UnsafeError` (surfaced as `Ractor::RemoteError <- Ractor::UnsafeError`),
  deterministically (nokogiri 1.19.3). → Slice B tests fallback COST, not the safety bit.
- **Boundary copy tax (the economic crux):** deep-copy send is linear & brutal —
  500k-element payload = **534 ms**; frozen-share send = **~0.08 ms** regardless of size
  (shareable passes by reference). `make_shareable` freeze ≈ 40% of copy, paid once.
  ⇒ thesis lives only if hot data stays shareable (frozen) and I/O payloads stay small.

---

## 2026-06-13 — Slice A1 first result

**Throughput** (`a1_compute_baseline.rb`, macOS, 10 cores, 40M inner ops, best-of-3):
sequential 1.00×; threads(control) 1.02×; **processes(CoW) 4.80×; ractors(frozen) 3.85×**
→ Ractor = **80% of process-pool throughput** (steady state; below the 85% gate).
Threads ≈ 1× confirms GVL → thread pool is a strawman baseline.

**Memory gate** (`mem_gate.rb`, Linux/colima, 4 cores, 1M-rule dataset ≈179MB, isolated procs):
- process pool (naive fork): 394.9MB PSS (private_dirty 215MB; CoW broken by GC age-bit dirtying;
  shared_clean only 14.8MB).
- process pool (**Process.warmup** = prod CoW protection): 283.8MB PSS (private_dirty 50MB).
- ractor pool (1 proc): 180.0MB PSS.
→ Ractor = 45.6% of naive fork, **63.4% of warmup-protected fork** (the honest number). PASSES the
  ≤80% memory gate even against the strong baseline.

**Verdict:** thesis SURVIVES first falsification *in its best-case niche*, reframed as a **trade:
~20% less throughput for ~37% less memory**. Net-positive for RAM-bound deployments; negative for
CPU-bound. NOT a general Rails result.

**Open / not yet measured (do not claim):** Linux throughput; root-cause of the 20% throughput gap;
A2 gateway tax (likely worsens throughput); A3 payload-size envelope; Slice B (adversarial:
Current-in-callback, native-ext fallback cost, pre-commit side effect → outbox, version-conflict
no-duplicate); reforking (Pitchfork) effect on the process baseline over time.

---

## 2026-06-13 — Consolidated `frontier_harness.rb` + A1 verdict (PROVISIONAL — strong baseline incomplete)

Built `frontier_harness.rb` to fix every review finding in one Linux harness: throughput+PSS in the
same run; pool swept 1..N (frontier); barrier snapshot symmetric for both models (parent reads
`/proc/<pid>` of all children while they block on a hold-pipe); sustained load (workers loop for
DURATION); strong baseline `Process.warmup`; dataset-shape matrix (Array<Hash>|Data|packed blob);
pools spun up OUTSIDE the timed region; checksums not payloads; smaps FAILS LOUD; forks/pipes cleaned
in `ensure`. Reviewed twice (thermo + sk-ruby); applied all findings: **REPS + median + min/max spread
with an INCONCLUSIVE guard when the spread straddles a gate** (H-A); **iso-throughput memory comparison
via interpolation, throughput-reach vs process max** (H-B); churn separated from the pure kernel; lean
allocation-light hot path. Run on colima Linux VM (8 vCPU / 6GB), `ruby:4.0-slim` (4.0.5), REPS=4,
N_RULES=1M, DURATION=4s. Correctness oracle = `yes` on all 32 measurements per locked run.

**THE key finding — the dominant axis is ALLOCATION RATE (CoW breakage), not dataset shape.** Process
`Process.warmup` preserves CoW only while workers barely allocate; realistic Rails-style object churn
drives GC → dirties the shared dataset pages → the dataset is effectively duplicated per worker, while
the Ractor pool keeps ONE copy in one process.

Trustworthy numbers (hash, 1M-rule ~180MB dataset, pool 4):
- **ALLOC=0 (lean kernel): FAIL.** Process CoW intact (private_dirty ~5MB), process PSS **187MB** <
  ractor **213MB** → ractor memory = 114%. Lean numeric kernels belong to processes.
- **ALLOC=100 (realistic churn): PASS.** Process CoW broken → process PSS **437MB**; ractor **266MB**
  → **Ractor PSS = 60.8% at 102.5% throughput, correct.** ~171MB saved. Meets both agreed gates.
- **ALLOC=2000 (extreme churn): FAIL on throughput.** Memory still ~59%, but Ractor throughput drops to
  ~48% of process — all Ractors share ONE GC, so a major GC stalls the whole pool (independent process
  GCs don't). Shared-GC contention is the Ractor throughput ceiling.
- blob (packed 16MB) @ ALLOC=100: PASS marginally (69.7%) but only ~11MB saved — shape sets the
  *magnitude* of the win, allocation sets *whether* there is one.

**A1 VERDICT — in-niche economics HOLD vs the strong (refork) baseline at realistic cadence (clean harness;
review round 3 COMPLETE — see the round-3 section at the bottom).** Canonical gate is now `refork_gate.rb`
(frontier / iso-throughput, payload-symmetric, on `bench_kernel`): its `norefork` column is the original A1
baseline (Ractor 247MB vs 470MB ≈ 52% PSS at parity throughput) and its `refork` column is the strong
baseline (Ractor dominates/passes at every realistic cadence). Scope: SYNTHETIC workload; chatty SYNC
capabilities are FORBIDDEN (A2.3); real Rails / Slice B / outbox are future. Ractor wins (materially
less memory at equal-or-better throughput) for **large CoW-hostile Ruby object state under moderate
Rails-like allocation** — plausibly where real Rails request/job work sits. It LOSES for near-zero
allocation (process CoW wins) and for extreme allocation (Ractor shared-GC throttles throughput). The
agreed gates (PSS ≤70-80%, throughput ≥75-80%, correctness) are MET in that niche with a hardened,
twice-reviewed harness. This validates proceeding to A2 (capability/gateway tax) — the next place the
thesis can die, since a synchronous gateway would erode the throughput parity shown here.

---

## 2026-06-13 — Review round 2: honesty fixes + refork strong baseline + A2.1 gateway

An external review (correct on most points) flagged: (P1) "FINAL A1" overclaimed — `Process.warmup` is not
the strong baseline; refork/mold-worker untested. (P1) A2 measured the producer, not end-to-end. (P1) day1
probes classified unexpected success as PASS. (P2) GC mechanism inferred, not measured. (P2) `mem_gate.rb`
fails open and was still called "decisive". (P2) kernel duplication had drifted. Actions taken:

- **Honesty fixes:** decisions/README downgraded to PROVISIONAL; `day1` probes now flag unexpected success as
  ERROR and the script `exit(1)`s on any ERROR (re-verified: probe 6 OK(fail) `Ractor::RemoteError <- UnsafeError`,
  probe 8 confirms `Ractor::MovedError`, exit 0); `mem_gate.rb` DEPRECATED (aborts) + smaps made fail-loud.
- **De-drift:** extracted `bench_kernel.rb` (shared dataset/compute/work/smaps/isolated/median + GC.stat
  capture). `refork_gate.rb` uses it. (frontier/a2 refactor onto the lib still pending.)

**STRONG-BASELINE REFORK TEST (`refork_gate.rb`, hash, 1M dataset, ALLOC=100, POOL=4, REPS=3, DURATION=8):**
read via **Pareto dominance** (a crude PSS ratio mislabels a model that is worse on BOTH axes). Process
`Process.warmup` + periodic refork from a warm mold, swept by refork interval:
- refork every **1.0s**: process 472MB @ 15927 vs ractor 242MB @ 15956 → **Ractor dominates** (51% PSS, 229MB saved, = throughput).
- refork every **0.25s**: process 271MB @ 14159 vs ractor 242MB @ 16509 → **Ractor dominates** (lower PSS AND +17% throughput — refork's fork overhead costs throughput faster than it recovers memory).
- refork every **0.1s**: process 227MB (< ractor) but `correct: NO` (generations too short for a full pass) → **INVALID**, and throughput already −36%.

**Provisional reading (NOT a claim — see review round 3).** At the tested POOL=4 cadences the Ractor pool
*appears* to Pareto-dominate the refork process pool (aggressive refork ⇒ fork overhead destroys throughput;
relaxed refork ⇒ CoW drifts and process PSS balloons). BUT this is not established: refork_gate is POOL=4-fixed
(not a frontier / iso-throughput comparison like A1), payload build is asymmetric, the PSS samples are
end-of-generation (not time-averaged), and GC stats are single-rep. Must be re-run clean before any claim that
refork does/doesn't kill the thesis.

**GC MECHANISM — now MEASURED (was inferred):** ALLOC=0 → alloc_objs ≈ 20, GC_count 0, CoW intact, process
187MB < ractor 211MB (process wins). ALLOC=100 → alloc_objs ≈ 25–30M, GC_count 40–60, GC_time ~900ms, CoW
broken, process 451MB ≫ ractor 242MB. The allocation→GC→CoW-breakage chain is confirmed empirically.

**A2.1 GATEWAY TAX (`a2_gateway.rb`, async logger, hash/ALLOC=100):** Ractor routes logger through a gateway
(port + dedicated drain thread); process logs directly. CAP_EVERY sweep at real scale: gateway tax vs no-gateway
is **≤3.5% at 1/1, 1/10, 1/100, 1/1000** call frequencies; drain backlog = 0 (keeps up). **CAVEAT (review P1):
this is PRODUCER-side throughput only.** End-to-end accounting (wall-time-until-drained, gateway latency
p50/p95/p99, drain-thread CPU, timeout/drop semantics) is NOT yet measured — the A2.1 PASS is provisional.

**Residual caveats / open:** refork PSS sampled at end-of-generation (max drift, favors Ractor — mid-gen would
be fairer, but refork still loses throughput); synthetic workload (no real Rails dataset); A2 end-to-end metrics;
A2.3 cache-read bounded-sync (the likely real killer — needs timeouts); Slice B adversarial; outbox soundness;
frontier/a2 not yet refactored onto `bench_kernel.rb`. Formal skill review of the new harnesses pending.

---

## 2026-06-13 — Review round 3 COMPLETE: clean harness, tasks 1–5 done, claims now warranted

Applied review round 3 in order: (1) payload symmetry — items/shards built once per cell in ALL harnesses;
(2) migrated `a2_gateway` onto `bench_kernel`; (3) added INCONCLUSIVE noise guards to A2; rebuilt
`refork_gate` as a **frontier / iso-throughput** comparison (sweeps POOL; refork via `work_passes` =
exactly-N-passes generations, always valid); fixed metrics (median GC across reps, relative-epsilon
correctness, "median end-of-generation PSS" honest label, fail-loud smaps); deprecated `mem_gate`;
`day1` fails `exit(1)` on ERROR + no stack-trace noise; docs made consistent. `refork_gate` is now the
CANONICAL economic gate (on `bench_kernel`, payload-symmetric).

**TASK 5 — refork strong baseline, CLEAN (hash, 1M dataset, ALLOC=100, pool 4, REPS=3), cadence curve:**
| refork interval | ractor | refork PSS | Ractor/refork PSS | tput reach | verdict |
| --- | --- | --- | --- | --- | --- |
| ~0.07s (every pass — absurd) | 247MB | 231MB | 107% | 126% | TRADEOFF, mem FAIL |
| ~0.3s (P=4) | 247MB | 294MB | 84% | 109% | Ractor Pareto-dominates |
| ~1.1s (P=16, realistic) | 247MB | 472MB | **52%** | 101% | Ractor Pareto-dominates |
| ~4.5s (P=64) | 247MB | 470MB | 52% | 96% | TRADEOFF, mem PASS |
Reading: at every **realistic** refork cadence (≥~0.3s) Ractor Pareto-dominates or passes the memory gate.
Refork only beats Ractor on memory by reforking ~14×/second (operationally absurd, −26% throughput). The
A1 in-niche memory advantage SURVIVES the strong baseline. (Correction of the earlier overclaim: it is
"dominates at realistic cadence", not "dominates always".) **A1 baseline (norefork) reconfirmed clean:
Ractor 247MB vs warmup-process 470MB ≈ 52% PSS at parity throughput.**

**GC mechanism — MEASURED:** ALLOC=0 → alloc_objs ≈ 20, GC_count 0, CoW intact (process wins); ALLOC=100 →
alloc_objs ≈ 13–25M, GC_count 25–40, CoW broken (process balloons). Allocation→GC→CoW-breakage confirmed.

**TASK 4 — A2.3 bounded-SYNC cache read (`a2_cache_sync.rb`), CLEAN frequency envelope (pool 4, ALLOC=100):**
| sync read every | ractor tput | tax vs no-cache | vs process | verdict |
| --- | --- | --- | --- | --- |
| 1 item (chatty) | 12247 | **+41%** | 56% | FAIL — gateway serializes the pool |
| 10 items | 18349 | +7.5% | 92% | INCONCLUSIVE (guard) |
| 100 items | 20040 | −4.3% | 94% | PASS |
| 1000 items | 18258 | +4.4% | 93% | INCONCLUSIVE (guard) |
Round-trip latency p50 0.09–0.20ms / p99 0.6–4ms; 0 timeouts. **DESIGN LAW (measured):** chatty synchronous
capabilities are FORBIDDEN inside capsules — a per-item sync cache read collapses throughput to 56% of the
process pool. Sync deps must be batched to ≤~1 per 100 items, or kept async (A2.1 logger: ≤3.5% any frequency).

**Net, honest, in scope:** the Ractorized capsule economics hold IN-NICHE (large frozen CoW-hostile Ruby state
+ moderate allocation) vs the STRONG (refork) baseline at realistic cadence, with async or infrequent-sync
capabilities. They FAIL for near-zero allocation (process CoW wins), extreme allocation (shared-GC throttle),
chatty sync deps, and compact/packed state. Still future (NOT claimed): real Rails workload, Slice B
(Current/callbacks/native-ext/outbox), A2.1 end-to-end refinement (max-backlog/drain-CPU; async backlog=0 so
producer-side is a fair proxy), frontier shape-matrix migration onto bench_kernel.

---

## 2026-06-13 — Slice B: Rails resistance + transactional soundness (`slice_b_rails_adversarial.rb`)

A1/A2 settled the economics in-niche; Slice B is the next risk: Rails resistance + write-path soundness.
No real Rails (can't boot Rails in a Ractor — rails#51543; AR Ractor-unsafe), so it models the resistant
PATTERNS faithfully and PROVES the protocol. **16/16 gates pass** (hardened in review round 4 — thermo +
sk-ruby skills run on the harness, findings APPLIED not just disclosed: atomic `flock` commit + concurrent-
committer test T5, `flock` dispatch + concurrent-dispatcher test T6, torn-trailing-line tolerance on recovery,
directory fsync; T1 relabeled a structural invariant).

**PART 1 — resistance is a LOCAL migration, not a rewrite (each pattern → transform OR named failure):**
- `Current.user` in a callback → implicit capture raises `ArgumentError` (a Ractor block can't see ambient
  thread-locals); transform = pass a shareable `CapsuleContext` explicitly. ✓
- callback/proc capturing mutable state → `Ractor.make_shareable(proc)` raises `Ractor::IsolationError`;
  transform = defunctionalize to a shareable `Data` descriptor. ✓
- Nokogiri/native-ext → `Ractor::RemoteError <- Ractor::UnsafeError` from a non-main Ractor; fallback = run in
  the owner (cost is the A2.3 gateway round-trip — must be batched). ✓

**PART 2 — transactional soundness PROVEN (Proposal + optimistic commit + durable outbox + idempotent
post-commit dispatch; capsule computes in a real Ractor, returns a small Proposal + EffectIntents, fires
NOTHING):**
- T1 no external effect before commit (capsule is pure; effects.log empty pre-dispatch). ✓
- T2 version conflict ⇒ the rejected proposal's effect is NEVER written to the outbox ⇒ no ghost charge. ✓
- T3 at-least-once dispatch (5×) ⇒ effect fires exactly once (idempotency key in effects.log). ✓
- T4 CRASH (SIGKILL) after a durable commit, before dispatch ⇒ commit survives, recovery dispatcher fires
  the effect EXACTLY once (and is safe to re-run). ✓

**STATUS after round-4 hardening (concurrency now PROVEN, not just disclosed):** T5 (two forked committers
racing on the same base version) and T6 (six forked dispatchers racing) both pass — atomic `flock` commit and
`flock` dispatch serialize the check-and-append, so no double-commit and no double-fire (production equivalent:
a DB unique index on (order_id,version) / idempotency_key). Torn trailing lines are tolerated on recovery (a
partial commit counts as NO commit); the directory is fsync'd. **Remaining honest gaps:** it models the outbox
pattern with files+flock, NOT a literal ActiveRecord `transaction do`; and the A2.3 bounded-SYNC **timeout is
UNTESTED** (gateway always responded, timeouts=0; `Timeout.timeout` may not even interrupt a blocked
`Ractor::Port#receive` — the "bounded" guarantee is unproven and is the next thing to test). The design law stands:
**capsule pure → Proposal + EffectIntent → owner commits state+outbox atomically → post-commit dispatcher
fires effects idempotently; DB writes NEVER happen inside the Ractor; sync deps batched (A2.3).**

**Thesis state:** Economic core (A1/A2) VALIDATED in-niche; transactional soundness PROVEN (single-dispatcher
model); Rails resistance shown LOCALLY transformable for the 3 archetypal patterns. **Still future (not
claimed):** a real Rails app (Order/User/OutboxEvent/Current) exercising AR + many resistant call sites at
scale; concurrent-dispatcher safety with a real unique constraint; A2.1 end-to-end. Renamed thesis (honest
scope): **"Frozen Read-Model Capsules for Rails"**, not "Ractorized Rails Kernel".

---

## 2026-06-13 — CLAIM CORRECTION (Codex): the outbox is not exactly-once external (supersedes earlier wording)

Earlier sections said "crash → recovery fires the effect EXACTLY once" and "transactional soundness PROVEN".
**Both are weakened here, and the relabeled `slice_b` (16/16) now says it correctly.** The transactional-outbox
pattern does NOT guarantee the external world receives an effect exactly once: the relay can deliver, then crash
before recording the delivery, and re-deliver. Exactly-once-*at-the-consumer* holds only because the **consumer
is idempotent** (dedups by `idempotency_key`). My `effects.log` MODELS that idempotent consumer; it does not prove
delivery happens once.

- **Don't say:** "exactly-once external side effect." **Say:** "exactly-once EffectIntent / outbox ENQUEUE
  (T2/T5) + idempotent AT-LEAST-ONCE dispatch (T3/T6); the external effect is idempotent at the consumer."
- **Don't say:** "crash → recovery exactly-once." **Say:** "crash → recovery does not lose the EffectIntent and
  does not duplicate the effect *because the consumer dedups by idempotency_key*."
- **Don't say:** "transactional soundness proven." **Say:** "protocol soundness proven in a files+flock model
  with concurrent committers (T5) and dispatchers (T6); PRODUCTION still requires a real DB unique constraint on
  (order_id,version)/idempotency_key, a real AR `transaction do`, and an idempotent external consumer."
- **Precondition made explicit:** `idempotency_key` must be a STABLE, deterministic per-logical-operation token
  supplied by the caller (a retry with a fresh id double-charges; a reused id drops a charge).

**Corrected thesis sentence (final for this phase):** *Frozen Read-Model Capsules are economically viable for
Rails-like allocation-heavy workloads over large frozen Ruby read models, provided dependencies are async/batched
and writes are emitted as versioned proposals plus idempotent outbox effects.*

**Phase status:** VALIDATED — in-niche economics, the gateway design law, the proposal/outbox protocol in a model.
NOT validated — real Rails integration, real DB durability/constraints, migration cost in an existing app,
commercial product. This closes the FALSIFICATION phase; next is the real-Rails INTEGRATION phase
(`rails_capsule_slice_b/` with AR, `lock_version`, a unique index on `outbox_events.idempotency_key`, a 2+-worker
concurrent dispatcher, and the A2.3 timeout finally exercised).

---

# Phase 2 — Rails Real Integration Slice (`rails_capsule_slice_b/`)

**Objective (not performance):** does the Proposal + Outbox + CapsuleContext protocol stay sound when it leaves
files+flock and runs on real ActiveRecord + a real transaction + real `lock_version` + a real unique index + a
concurrent dispatcher + resistant Rails code? **Verdict: yes — 10/10 gate tests green, stable across 15+ runs.**

## Stack (facts, all run/measured — not assumed)
- **ActiveRecord 8.1.3 + ActiveSupport 8.1.3 + pg 1.6.3** boot and connect on **Ruby 4.0.5** (verified).
- **Real Postgres 16.14** in a disposable Docker container (`capsule_pg`, host port 65432). PG14 (local Homebrew)
  confirmed as a drop-in fallback; every gate is PG ≥ 9.5 (jsonb, `FOR UPDATE SKIP LOCKED`, app-level optimistic lock).
- Minitest 5.27.0. Run with `./run.sh` (boots/reuses the container, loads schema, runs the 10 gates).

## Decision: standalone ActiveRecord, NOT a full `rails new`
Every Phase-2 gate is a DB/AR-layer property (transaction, `lock_version`→`StaleObjectError`, unique index→
`RecordNotUnique`, `after_commit` semantics, concurrent connections). None touch HTTP/controllers/routes. So the
slice is built on the **real AR + AS persistence stack against real Postgres**, with no actionpack/railties — that
web tier would add Ruby-4.0 boot risk and test nothing here. **This is the one deliberate deviation from the spec's
"mini app Rails real"; it is documented, not hidden.** The listed classes (User/Order/OutboxEvent/Current/
CapsuleContext/AdversarialService/Proposal/EffectIntent/OutboxDispatcher) are all implemented; only the unused HTTP
layer is omitted. A full `rails new` wrapper is a small future addition if a gate ever needs the request lifecycle.

## VERIFIED FACT — libpq is not fork-safe on macOS
First concurrent-dispatcher attempt used `Process.fork`: **every forked child SEGFAULTED in
`pg/connection.rb:944` (`connect_start`)** — libpq's inherited library/SSL/CoreFoundation state is corrupt after
`fork()` on Darwin. Fix is also the production-faithful model: run each dispatcher/committer as an **independent
`Process.spawn`** (fresh process image → libpq initializes cleanly), exactly how production runs N outbox workers.
`worker_dispatch.rb` / `worker_commit.rb` are those workers; they deliberately do NOT require `schema.rb` (it
force-recreates tables and would wipe the parent's seeded data).

## SOUNDNESS CORRECTION found by the support-skill review — the dispatcher must not fake exactly-once
First dispatcher delivered to the external table **inside the same transaction** that set `published_at`. Because
the "external system" is modeled as a local table, coupling them in one tx **silently fakes exactly-once** — the
exact overclaim the Codex correction retired. Fixed: `OutboxDispatcher` now **delivers and marks in SEPARATE
commits** (claim with `FOR UPDATE SKIP LOCKED` in a short tx that releases the lock *before* delivery). The early
release is the honest cost: duplicate delivery is possible and the `external_charges` unique index dedups it. This
makes the relay honestly **at-least-once**; the Gate-5 crash test proves the dedup deterministically.

## Gates (test → real DB property)
1. `test_commit_conflict_drops_outbox` — native `ActiveRecord::StaleObjectError` (two stale instances) **and**
   the protocol: a stale Proposal rolls back order + ALL its EffectIntents together; exactly one outbox row.
2. `test_commit_and_outbox_are_atomic` — order update + outbox insert in one `transaction`; success lands both
   with **zero external effect at commit time**; a colliding outbox key aborts the whole tx (order + version bump
   roll back, no partial row).
3. `test_idempotency_key_is_unique` — real unique index → `RecordNotUnique`; the consumer's `insert_all(unique_by:)`
   path is a NO-OP on duplicate, not a raise (never poisons the dispatcher tx).
4. `test_concurrent_dispatchers_dedupe` — 4 spawned dispatchers, 200 events: none stranded, exactly one external
   effect per `idempotency_key`. Stress-checked at 500 events / 6 workers → 0 stranded, exactly 500 effects.
5. `test_crash_after_commit_before_dispatch_recovers` — durable outbox survives the commit→dispatch crash; the
   at-least-once window (external committed, publish-mark lost) re-delivers and the unique key dedups to one effect;
   re-running is a clean no-op.
6a. `test_current_requires_capsule_context` — `Current.user` → `CapsuleContext` (Ractor-**shareable**, verified);
    a raw user/nil is refused with the named `CapsuleContextRequired`.
6b. `test_callback_requires_descriptor` — a proc capturing a live AR object raises `Ractor::IsolationError` →
    named `CallbackNotShareable`; the frozen `PricingDescriptor` is shareable and reproduces the computation.
6c. `test_native_extension_uses_owner_fallback` — owner-bound native work cannot be isolated into a Ractor
    (real `ArgumentError`) → owner fallback runs it; mirrors Slice A's verified Nokogiri `Ractor::UnsafeError`.
- Reinforcing (beyond the 8 named): `test_concurrent_committers_one_wins` (6 spawned committers all targeting v0 →
  **exactly one wins** the optimistic race, 5 conflict, one outbox row — the real-process analogue of synthetic
  T5) and `test_raw_path_charges_precommit_capsule_defers` (the raw service charges PRE-commit and bypasses the
  outbox; the capsule path performs zero external effect and enqueues an EffectIntent — gate 6 "side effect →
  EffectIntent").

## What Phase 2 VALIDATES (newly) vs still does NOT
- **NEW — validated:** the protocol is sound on real AR + real Postgres — real transaction atomicity, real
  optimistic `lock_version` (deterministic and under genuine concurrent committers), a real unique constraint as
  the enqueue-once guarantee, a real concurrent (spawned, multi-process) dispatcher that loses nothing and
  delivers each effect once at the consumer, and the 3 resistant Rails patterns transformed or named-failed.
- **STILL NOT validated:** migration cost in a *pre-existing* Rails app; broad call-site coverage (only the
  archetypal resistant patterns); the HTTP/request lifecycle; performance under a real Rails workload; the A2.3
  bounded-sync **timeout** (gateway always responded — still untested); running AR *inside* a Ractor (known
  impossible, rails#51543 — and explicitly out of scope: capsules emit Proposals, the OWNER commits).

**Claim unchanged (corrected wording holds):** exactly-once outbox **ENQUEUE** (unique index) + idempotent
**AT-LEAST-ONCE** dispatch (consumer dedups by `idempotency_key`). NOT exactly-once external side effect.

**Phase 2 verdict:** the protocol survives the move to real Rails/DB. Do NOT build yet (still blocked): gem, public
DSL, Rails engine, ActiveJob adapter, actor registry, CDC/deltas, request capsules, generic callback compiler.

---

## Phase 2 — Falsification battery (2026-06-13, reviewer demanded raw evidence, not "10/10")

A skeptical reviewer rejected "10/10 passed" and demanded falsification: raw evidence that breaks if anything is
assumed, plus mutation tests proving the suite has teeth. Built/ran 16 items. Orchestrated: 5 independent
correctness tests via a parallel workflow (each on its own isolated database, raw output returned); the subtle
concurrency + mutation + Linux evidence run by hand. **Net: 26 test methods green on macOS AND Linux; 5/5
mutations caught; 2 real defects found and fixed along the way.**

- **#1 environment proof (raw):** Ruby 4.0.5 · ActiveRecord 8.1.3 · libpq 18.0.1 · Nokogiri 1.19.3 · server
  `PostgreSQL 16.14 ... aarch64-linux` at `172.17.0.2:5432`, `current_database=capsule_test` — provably the PG16
  container, not the local macOS PG14. `orders.lock_version` present; UNIQUE indexes on `outbox_events.idempotency_key`
  and `external_charges.idempotency_key` confirmed via `\d`.
- **#2 AR optimistic locking is REAL:** two stale `Order` instances → second `update!` raises
  `ActiveRecord::StaleObjectError` (slice_b_test `test_commit_conflict_drops_outbox`, and 6 concurrent spawned
  committers → exactly one wins).
- **#3 atomic rollback:** order update + a colliding outbox insert → `RecordNotUnique` rolls back BOTH (order +
  version bump unchanged, no partial row).
- **#4 real `after_commit`:** fires only AFTER the real COMMIT, never on `ActiveRecord::Rollback`; `CommitProbe.fired`
  empty mid-transaction (2 runs, 12 assertions).
- **#5 SKIP LOCKED with a REALLY held lock:** a separate process holds `FOR UPDATE` on one row; the dispatcher's real
  `claim` (SKIP LOCKED) skips it and returns the other; a plain `FOR UPDATE` on it blocks until `statement_timeout`.
  Probe confirmed: plain `FOR UPDATE` blocks 4.95s then returns BOTH rows; SKIP LOCKED returns only the unlocked one.
- **#6 crash at THREE points (real SIGKILL, termsig 9):** A (after claim, before deliver) → recoverable, delivered
  once; B (after deliver, before mark) → re-delivery deduped to ONE effect, not two; C (after mark) → no reprocess.
  Plus a 4th: mark-BEFORE-deliver then crash → effect LOST forever (proves the deliver-before-mark order is load-bearing).
- **#7 high-volume stress:** N=10000, 16 spawned dispatchers, jitter 1ms, batch ∈ {1,5,10} × 2 runs → every run
  `unpublished=0, charges=10000, distinct=10000, dups=0`, all workers exit 0. The claim-release honest dispatcher
  strands nothing under heavy contention.
- **#8 request_id / idempotency_key contract (negative tests):** same id → 1 effect; different ids → 2; a wrongly
  REUSED id across two different operations (500 then 900) → only 1 effect survives, amount 500 — the second op is
  silently dropped. The dedup guarantee DEPENDS on the caller supplying a stable per-operation key.
- **#9 `Current` does not leak:** `CapsuleContext` is a frozen snapshot (stays at user_a after `Current.user` moves
  to b, and is `Ractor.shareable?`); inside a Ractor, touching `Current.user` RAISES ("defined with an un-shareable
  Proc in a different Ractor") — it does NOT cross, so a capsule must receive an explicit context.
- **#10 callback capturing AR state:** a proc holding a live `Order` → `Ractor.make_shareable` raises
  `Ractor::IsolationError` → named `CallbackNotShareable`; the frozen `PricingDescriptor` is shareable and reproduces
  the value.
- **#11 REAL Nokogiri (not a proxy):** off the main Ractor, `Nokogiri::XML` raises a genuine `Ractor::UnsafeError`
  ("ractor unsafe method called from not main ractor", from `Nokogiri::XML::Document.read_memory`), surfaced as
  `Ractor::RemoteError` whose `#cause` is the `UnsafeError`; on the owner it succeeds. The main gate
  (`test_native_extension_uses_owner_fallback`) was UPGRADED from an `ArgumentError` proxy to real Nokogiri.
- **#12 pre-commit side effect:** the raw service charges the external store BEFORE commit and bypasses the outbox;
  the capsule path performs ZERO external effect at commit and enqueues an `EffectIntent` instead.
- **#13 failing external consumer:** attempt 1 raises → row stays unpublished, no charge; attempt 2 delivers → 1
  charge, marked; attempt 3 reprocess → idempotency_key dedups → still 1 charge.
- **#14 MUTATION TESTS (the meta-falsification):** break each invariant, prove the suite turns RED. 5/5 caught:
  remove outbox unique index → `test_idempotency_key_is_unique` red; disable `lock_version` →
  `test_commit_conflict_drops_outbox` red; SKIP LOCKED → plain FOR UPDATE → `falsify_skip_locked` red; random
  idempotency_key per call → `falsify_request_id_contract` red; dispatcher skips delivery → crash-A recovery red.
  **The mutation suite earned its keep immediately: it caught that `falsify_skip_locked` was testing a COPY of the
  SKIP-LOCKED query inlined in the test instead of the dispatcher's real `claim`. Fixed to call the production code
  path; the mutation is now caught.**
- **#15 LINUX:** the full 26-test suite (gates + every falsification test) runs ALL GREEN inside `ruby:4.0-slim` on
  `aarch64-linux` against a Linux Postgres — identical to macOS. Incidental real-world finding: AR's URL config
  parses `DATABASE_URL` with `uri 1.1.1`, which REJECTS underscore hostnames (`capsule_pg` →
  `URI::InvalidURIError`); use a hostname without `_`. (The macOS libpq-fork segfault is Darwin-specific; we use
  `Process.spawn` everywhere, so it is moot on both.)

New artifacts: `test/falsify_after_commit.rb`, `test/falsify_request_id_contract.rb`, `test/falsify_current_leakage.rb`,
`test/falsify_nokogiri_ractor.rb`, `test/falsify_failing_consumer.rb`, `test/falsify_skip_locked.rb` (+ `worker_hold.rb`),
`test/falsify_crash_windows.rb` (+ `worker_crash.rb`, `worker_crash_markfirst.rb`), `stress_run.rb` (+ `worker_stress.rb`),
`mutation_test.rb`. Native gate upgraded to real Nokogiri (`adversarial_service.rb`).

**Two defects the battery found in my OWN work (the point of falsification):** (a) a test guarding a copy of the
logic instead of production code (caught by mutation testing); (b) the dispatcher originally faked exactly-once by
coupling delivery to the publish-mark in one transaction (caught earlier by the support-skill review). Both fixed.

**Honest scope after the battery:** the protocol is validated on **real ActiveRecord + real Postgres** (macOS and
Linux) against a teeth-having suite. Item **#16 (a fully BOOTED Rails app)** is below.

### #16 — REAL BOOTED Rails app (`rails_capsule_mini_app/`) — "Rails integration validated"

A genuine `rails new` app (Rails **8.1.3** on Ruby 4.0.5), fully booted (`Rails.application.initialize!`,
`config.eager_load = true`, real Postgres `capsule_railsapp` via real migrations), not standalone AR. **Re-run and
verified by hand: 15 runs, 75 assertions, 0 failures, stable across seeds.** Generated with
`rails new rails_capsule_mini_app --api -d postgresql --minimal --skip-git --skip-test --skip-bootsnap
--skip-action-cable --skip-active-storage --skip-active-job`.

- Real `ApplicationRecord` models (User/Order/OutboxEvent/ExternalCharge), real `Current < ActiveSupport::CurrentAttributes`,
  real `after_commit` (fires after commit, not on rollback), real `Rails.cache` (`:memory_store`) and `Rails.logger`
  (`BroadcastLogger`) used by the resistant service. The protocol code is byte-for-byte the slice's semantics.
- Same gates pass inside the booted app: optimistic-lock conflict drops outbox together; atomic order+outbox;
  unique idempotency_key → `RecordNotUnique` + consumer dedup; 4 spawned dispatcher processes (each boots the full
  Rails env, own libpq connection) lose nothing / one effect per key; SIGKILL in the at-least-once window → recovery
  dedups; 6 spawned committers → exactly one wins.
- **THE Rails-specific proof — a Rails global inside a Ractor FAILS** (empirically observed, asserted): `Rails.cache`
  and `Rails.logger` → `Ractor::IsolationError` ("can not get unshareable values from instance variables of
  classes/modules from non-main Ractors", `@cache`/`@logger` from Rails); `Current.user` → `RuntimeError` ("defined
  with an un-shareable Proc in a different Ractor", from `CurrentAttributes#defaults`). On the main Ractor
  `Ractor.shareable?(Rails.cache/logger)` is false, while the `CapsuleContext` snapshot IS shareable and crosses.
  This is the whole point: a capsule must take explicit frozen values and never reach a Rails global in a worker.
- **Honest Rails-specific caveats (found, not hidden):** (1) the generated `test.rb` keys `eager_load` off `ENV["CI"]`,
  so a default `bin/rails test` is NOT production-like — had to force `eager_load = true` to honestly call it
  "booted like production"; (2) the test cache defaults to `:null_store` (a no-op) — needed a real `:memory_store`
  for the cache path and the Ractor probe to mean anything; (3) `CurrentAttributes` fails in a Ractor with a
  *different* exception (`RuntimeError`) than cache/logger (`IsolationError`) — same conclusion, different mechanism.
  Support skills (sk-ruby + thermo) run on the app: no P1/P2; one P3 (the `after_commit` writes `Current` only as a
  test observable, flagged not-for-production).

**Claim upgraded:** from "ActiveRecord/Postgres outbox protocol validated" to **"Rails integration validated"** — the
protocol holds identically inside a real booted Rails 8 app, and the capsule discipline (explicit snapshot, no Rails
globals in workers) is exactly what makes it survive there. Corrected core claim unchanged: exactly-once outbox
ENQUEUE + idempotent at-least-once dispatch. Still NOT validated: migration cost in a PRE-EXISTING Rails app at scale,
broad call-site coverage, the HTTP request lifecycle, performance, the A2.3 timeout. Still blocked: gem/DSL/engine/
ActiveJob adapter/registry/CDC/request capsules/callback compiler.

---

# PHASE 2 CLOSED — STRICT CLAIM (locked 2026-06-13, reviewer-approved)

Reviewer accepted Phase 2 as **strong validation with correct scope** after the falsification battery + mutation
tests + real booted Rails app. This is the canonical claim. Use exactly this wording.

**Validado / Validated:**
- protocolo em Rails real (real booted Rails 8.1.3 app)
- isolamento de Rails globals em Ractor (Rails.cache/logger → Ractor::IsolationError; Current → RuntimeError)
- outbox/idempotency em Postgres real (unique index = enqueue-once; idempotent at-least-once dispatch)
- fallback de native extension (real Nokogiri → Ractor::UnsafeError off main, runs on owner)
- falhas nomeadas para Current/callbacks (CapsuleContextRequired / CallbackNotShareable)

**Não validado / NOT validated:**
- custo de migração em app existente
- performance com workload Rails real
- request lifecycle completo (HTTP)
- cobertura ampla de gems/call-sites
- operação em produção

**The three validated dimensions (the permitted claim — write THIS):**
> *Frozen Read-Model Capsules foram validadas em três dimensões:*
> 1. *Economia sintética in-niche:* grande estado Ruby frozen/shareable + alocação moderada + payload pequeno.
> 2. *Protocolo transacional:* proposal + optimistic commit + outbox + idempotent at-least-once dispatch.
> 3. *Integração Rails mínima real:* Rails 8 bootado, ActiveRecord/Postgres real, Rails globals falhando dentro do
>    Ractor, CapsuleContext shareable funcionando.

**Do NOT write:** "Rails apps podem migrar facilmente." · "pronto para gem." · "resolve Rails em Ractors."

**BLOCKED (do not build): product · gem · public DSL · Rails engine · ActiveJob adapter · actor registry · CDC/deltas
· request capsules · generic callback compiler.** Correct sequence: (1) close docs with strict claim [done];
(2) take an existing/dirty Rails app; (3) measure real migration cost; (4) ONLY THEN consider a public API.

## Phase 3 — Migration Cost Slice (NEXT, planned — not started)

**Objective:** take a pre-existing Rails app (or a sufficiently *dirty* mini-app) and measure how much must change for
capsule-compatibility. The protocol risk is now low; the open crux is: **does the niche exist but the migration costs
too much?** i.e. the architecture works, but too few real Rails services are capsule-friendly without significant rewrite.

**Test:** pick 3 real/dirty Rails services — (1) rules/pricing, (2) authorization/policy, (3) report/export. For each:
measure baseline (process/refork), migrate to CapsuleContext, run with a realistic frozen dataset, then record:
- call-sites changed
- globals removed (Rails.cache / Rails.logger / Current / I18n / etc.)
- callbacks/procs converted to descriptors
- native extensions needing a fallback
- synchronous dependencies per item
- payload size at the boundary
- diff in LOC
- migration time
- performance before/after (PSS + throughput)
- everything that did NOT fit (the residue list — name it, don't hide it)

**Verdict on the project:** moved from "maybe interesting" to "technically plausible and well-falsified at the core".
The remaining open question is whether the real world has enough services that fit this model without a rewrite.

---

## 2026-06-13 — FALSE-PASS REVIEW: claims frozen, gates corrected (before advancing)

A review caught places where the harness let a PASS stand for "economy/Ractor-executability validated" when only
the protocol or a tiny ratio was. All fixed and re-verified:

- **P1 Rails capsule not Ractor-executable** → added `Capsule::OrderSnapshot` (shareable Data) and a test that runs
  `capsule_propose` INSIDE a non-main Ractor over a shareable CapsuleContext + OrderSnapshot, returning a Proposal
  that then commits on the owner. Mini app now **16 runs / 82 assertions**. Claim corrected: only the capsule
  *compute* step is Ractor-proven; the protocol is **owner-side**.
- **P1 A2.3 timeout/checksum/stale** (`a2_cache_sync.rb`) → request_id-tagged replies with stale-drop; the cache
  value now folds into the checksum (+ an `oracle_cache` term). Verified: `TIMEOUT_S=1e-6` now yields
  `correct=NO` and `FAIL — 75309 timeouts` (was `correct=yes`). Gate hardened to
  `overhead ≤ .15 && vs_proc ≥ .75 && timeouts.zero? && correct`.
- **P1 economic materiality** (`frontier_harness.rb`, `refork_gate.rb`) → economic PASS now needs an **absolute**
  floor (≥100MB AND ≤80% PSS); a high ratio on a small dataset prints **ECONOMIC NO-OP**, and the refork
  Pareto-`SURVIVES` branch is gated on materiality too. Verified: small blob (9.1MB) → "ECONOMIC NO-OP", not PASS.
- **P1 README async-logger claim withdrawn** → "cheap at any frequency" was false (CAP_EVERY=1 measured +17.3% /
  74.3% of process). Real axis = gateway_calls/compute_ms; needs a SCAN×ALLOC×CAP_EVERY matrix.
- **P2 Phase-3 proof was copy-vs-copy** → added `drift_check.rb`: reads the REAL `lib/promotion.rb` from git HEAD and
  asserts the capsule gates on the SAME SiteSetting thresholds + same guard counts (tl1 3/4, tl2 7/8) → **DRIFT OK**.
- **P2 Guardian counts reconciled** to the reproducible `audit.rb`: **179 files / 668 calls** (was a narrower manual
  325); the larger count strengthens the non-fit conclusion.
- **P2 outbox attempt cost measured** → `delivery_attempts` log; stress (N=2000, 8 workers, jitter) shows
  charges=2000/dups=0 but **attempts=5891 (+194.6% duplicate external calls)** — the money/rate-limit cost the
  unique index hides.
- **P3 slice_b Nokogiri noise** silenced (report_on_exception around the intentional probe) → 0 stderr noise lines.

**Claim status: FROZEN.** Validated = owner-side proposal/outbox protocol on real Rails + the capsule compute step in
a Ractor over a small shareable snapshot. NOT validated = a whole Rails request from a Ractor, real-workload perf,
migration at scale. Still blocked: gem/DSL/engine/ActiveJob/registry.

---

## 2026-06-13 — Second false-confidence pass (boundary ENFORCED; metrics de-contaminated)

A follow-up review showed "ran in a Ractor" was a happy path, not a boundary, plus contaminated/over-claimed
metrics. All fixed and re-verified:

- **OrderSnapshot boundary ENFORCED** (mini app + slice_b). Added `Capsule::OrderSnapshotRequired`;
  `capsule_propose` now **raises** unless `order.is_a?(Capsule::OrderSnapshot)`. All tests pass
  `Capsule::OrderSnapshot.from(order)`; a negative test proves a live AR `Order` (`refute Ractor.shareable?`) is
  rejected. Verified: mini app **17 runs / 86 assertions**, slice_b **11 runs / 54 assertions**, 0 failures.
- **delivery_attempts de-contaminated.** `stress_run.rb` now truncates `delivery_attempts` with the rest. Controlled
  proof (WORKERS=1, JITTER=0, N=100, RUNS=2): **attempts=100 in BOTH runs** (was 100/200 = accumulation). Concurrent
  (8 workers, jitter): **+186.8% / +180.8% real duplicate attempts** across two clean runs.
- **drift_check is now SEMANTIC**, not name-matching: parses each guard into `(field, operator, threshold)` and
  compares the ordered list with an explicit `calc_topic_reply_count!`↔`topic_reply_count` residual mapping. Negative
  controls (operator `<`→`<=`; field `likes_given`→`likes_received`) correctly DRIFT. Wording downgraded to "static
  check only; runtime characterization vs booted Discourse is the stronger, deferred check".
- **bench.rb is apples-to-apples.** "before" inline now runs the FULL eligibility (all tl1+tl2 guards + the live
  `calc`). Honest split: owner snapshot build+decide = **0.21× inline** (the real per-call migration cost, UNDER-counted
  since `calc` is a real query); pure decide ×4 Ractors = 3.77× but **only** on the pure decide. Not an end-to-end win.
- **A2 observability + correctness precedence.** Counts **stale replies dropped**; added a `vs_proc` spread
  INCONCLUSIVE guard; and a correctness/timeout failure now reports **FAIL** definitively (trumps spread). Verified:
  tiny timeout → `FAIL — 19394 timeouts, 19388 stale dropped, correct=false`; clean run → INCONCLUSIVE on vs_proc spread.

**Still frozen / still blocked.** No gem/DSL/engine. The capsule compute step is now Ractor-boundary-ENFORCED; the
protocol is still owner-side; a whole Rails request from a Ractor, real-workload perf, and migration at scale remain
unvalidated.

---

## 2026-06-13 — Goal pass: immutable protocol objects + refork shape matrix

This pass closed two architecture issues that affected the thesis, not just the tests:

- **Proposal/EffectIntent are now deeply shareable.** `EffectIntent.charge` and `Proposal.build` return
  `Ractor.make_shareable(...)` values; nested `payload` hashes and `effects` arrays freeze with the object graph.
  `CommitCoordinator.commit!` refuses any proposal for which `Ractor.shareable?(proposal)` is false, with the named
  `Capsule::ProposalNotShareable` error. Negative tests prove a mutable hand-built proposal is rejected before any DB
  write. Verified: mini app **19 runs / 94 assertions**, slice_b **13 runs / 62 assertions**, 0 failures.
- **The mini-app regression from OrderSnapshot enforcement is fixed.** `test_current_requires_capsule_context` now passes
  `Capsule::OrderSnapshot.from(order)` on the valid path; raw AR orders remain rejected by the negative boundary test.
- **`refork_gate.rb` now has a dataset-shape matrix (`hash`, `struct`, `blob`).** The strong Pitchfork-style baseline is
  no longer tested only against `Array<Hash>`. A small Linux smoke (`hash,blob`, `POOLS=1,2`) passed and prints a verdict
  per shape; small absolute savings still correctly produce **ECONOMIC NO-OP**.

**Interpretation:** the protocol boundary is now materially stronger: the Ractor returns an immutable/shareable proposal,
not a mutable Ruby object graph that the owner can accidentally or maliciously alter before commit. The economic thesis is
still not validated by the smoke tests; the decisive run remains a large Linux refork/frontier run with realistic dataset
size and absolute savings ≥100MB.

---

## 2026-06-14 — Reviewer verdict ACCEPTED; claim language frozen; next gates named

The protocol boundary is accepted as serious. Recorded so the claims and the next gates do not drift.

**Updated verdict matrix:**

| Dimension                | Status                                              |
|--------------------------|-----------------------------------------------------|
| Protocol boundary        | OK (live AR rejected; immutable shareable proposal) |
| Outbox / idempotency     | OK, with correct claim semantics                    |
| Promotion migration      | NOT validated as a gain — architectural compatibility only |
| Broad economic thesis    | PENDING the large Linux refork run, per shape       |
| Product / gem / DSL      | BLOCKED                                             |

**Accepted as validated now:** (1) live AR never crosses the boundary; (2) `OrderSnapshot` is mandatory; (3)
`Proposal`/`EffectIntent` are deeply `Ractor.shareable?`; (4) `CommitCoordinator` refuses a mutable proposal
(`ProposalNotShareable`) before any write; (5) the side effect goes via outbox/idempotency, not a direct effect; (6)
mutation/negative tests prove the suite catches a real break.

**Outbox claim stays strict:** `exactly-once enqueue + at-least-once idempotent dispatch`. NOT "exactly-once external
effect" — the relay may deliver more than once, so the consumer must be idempotent.

**Claim language — ALLOWED now:**
> Frozen Read-Model Capsules têm boundary de protocolo validada e integração Rails mínima validada. A economia só está
> demonstrada em nichos sintéticos e precisa ser reconfirmada em Linux grande por shape e economia absoluta.

**Claim language — NOT allowed yet:** "migração real validada"; "produto validado"; "ganho real em Discourse";
"Rails apps podem adotar".

**Phase 3 finding (Promotion):** not an end-to-end perf case — it is architectural compatibility. Measured:
inline full 1,538,660/s; owner snapshot build+decide 316,214/s (0.21×); pure decide 2,353,085/s; pure decide ×4
Ractors 8,866,300/s (3.77× on the pure part only). Thesis narrows to: only worth it when the snapshot/pre-resolve cost
is amortized (many users vs one frozen read model; large reused ruleset; batch promotion/reports; mass pricing/ranking/policy).

**Next gates, in this order (do NOT migrate more Discourse before them; gem/DSL/engine still blocked):**
1. `refork_gate` grande on Linux — `hash`/`struct`/`blob`, large datasets, with the ABSOLUTE ≥100MB economy gate (no
   small smoke). PASS only if: PSS ratio ≤70–80% AND absolute saved ≥100MB AND throughput ≥75–80% of process/refork
   baseline AND correct=yes AND the spread does not straddle the gate.
2. Promotion amortization benchmark — N ∈ {100, 1_000, 10_000} users vs the SAME frozen settings/read model; compare
   (owner snapshot per user + capsule decide) vs (process/refork) vs (inline full); report snapshot cost, pure decide
   cost, boundary cost, total throughput, PSS, payload bytes. Answers whether Promotion is a real case or only compatibility.
3. Only then decide whether Phase 3 continues to another real service.

**Dispatcher residual risk (deferred — no lease/backoff yet; required before any product):** (1) slow external
consumer; (2) intermittently failing consumer; (3) worker dies after deliver, before `published_at`; (4) 16-worker
retry storm; (5) duplicate-attempt count measured; (6) simulated backoff without changing crash-test semantics. The
current dispatcher is correct as an at-least-once model but can amplify external calls — operational risk, not transactional.
> **SUPERSEDED 2026-06-14** — the lease deferral was lifted; the canonical dispatcher now carries a time-bounded lease.
> See "Lease ratified" below.

---

## 2026-06-14 — Gate #1 RAN: `refork_gate` grande (Linux, calibrated ~400MB datasets, wall-clock cadence)

> **Read in context (2026-06-16):** this entry's "thesis CONFIRMED but NARROW" was a *single calibrated-probe run*, not a
> passed final economic gate. The current authoritative verdict is **PIVOT** (`economic_final_gate_passed=false`,
> `economic_survives_any_current_matrix=false`); no current Linux matrix has a surviving alloc, and `hash` is the only
> clean win in that one legacy probe. Do not cite this header as a product-authorizing result. See the 2026-06-16 entry
> "Honesty-drift remediation".

Executed the decisive economic gate the verdict named. Result: **thesis CONFIRMED but NARROW and CONDITIONAL** — one
sharply-bounded win condition, falsified on every other axis.

**Harness work first (all measured, not assumed):**
- Added a **wall-clock refork cadence** (`REFORK_EVERY_S`, default 1s) so the Pitchfork-style strong baseline reforks on
  a real time cadence; `PASSES_PER_GEN` demoted to diagnostic. The **actual** refork interval is measured + reported
  p50/p95 (1.0s target → actual p50 ~1.1–1.2s / p95 ~1.3–1.6s; 0.3s target → p50 ~0.4s — overshoot = finishing the
  in-flight pass + fork/snapshot, surfaced not hidden).
- **Per-shape dataset sizes calibrated by measurement** (`size_probe.rb`, `/proc/smaps_rollup`): hash N=2.3M, struct
  N=5M, blob N=26M → ~410/400/405 MB resident — all clear the ≥100MB floor (a blob is 16 B/record vs hash ~190 B/record,
  so a single N can't hit a target size across shapes).
- **Support-skill review (thermo+sk-ruby) caught a real validity bug BEFORE trusting numbers:** refork paid the
  per-generation smaps-snapshot artifact `gens×` inside its throughput denominator while ractor/norefork paid it 1× —
  flattering the thesis. Fixed: throughput uses `compute_wall` = wall − measured smaps time, symmetrically (the *fork*
  cost stays — it is a real refork penalty). Excluded artifact measured + printed: ≤2.3% of wall at 1s, ≤4.1% at 0.3s
  (small, now removed and visible). Plus guards (`DURATION>0`, `N>SCAN`), `gens_median` relabel, gate thresholds as
  single-source constants (`PSS_RATIO_MAX/SAVING_MB_MIN/REACH_MIN`), size-probe dead-child guard.

**Sweep: 3 shapes × POOLS {1,2,4} × ALLOC {0,100,500} @ wall 1.0s/gen + 0.3s aggressive spot check, REPS=4 DURATION=5.**
Gate = PSS ratio ≤80% AND absolute saving ≥100MB AND throughput reach ≥75% AND spread doesn't straddle.

| config | shape | ract PSS | refork@iso | abs saved | ratio | reach | verdict |
|---|---|---|---|---|---|---|---|
| ALLOC=100 (1s) | **hash** | 515MB | 725MB | **+210MB** | 71% | 97.7% | **SURVIVES** ✅ |
| ALLOC=500 (1s, REPS=6/DUR=8) | **hash** | 515MB | 829MB | **+314MB** | 62% | 90.2% (lo 76.2) | **SURVIVES** ✅ |
| ALLOC=500 (1s) | struct | 527MB | 1105MB | +578MB | 48% | 71.4% | INCONCLUSIVE (throughput-limited) |
| ALLOC=100 (1s) | struct | 636MB | 551MB | −85MB | 115% | 69% | no win (ractor uses MORE) |
| ALLOC=0 (1s) | hash/struct | — | — | ≤0 | ≥120% | — | no win (CoW intact, process wins) |
| any | blob | ~406MB | ~420MB | +5–20MB | ~97% | — | economic no-op (<100MB) |
| 0.3s aggressive | hash | 515MB | 564MB | +50MB | 91% | 102% | economic no-op (refork claws memory back) |

**Definitive PASSes: `hash` at BOTH moderate (210MB) and heavy (314MB) allocation, realistic 1s cadence.** The heavy
case was INCONCLUSIVE at REPS=4 (reach spread 68–94% straddled 75%); a targeted re-run at REPS=6/DUR=8 tightened it to
`reach_lo`=76.2% → definitive SURVIVES. The INCONCLUSIVE guard worked — it refused to call the noisy run.

**Honest non-wins (the harness kills its own thesis — not rigged):**
- **`blob` (compact/packed) anywhere → economic no-op.** A packed string barely breaks CoW, so there is nothing to save
  (~5–20MB always <100MB). Confirms the long-standing "fails for compact/packed state" caveat with hard numbers.
- **ALLOC=0 → process wins.** No allocation, no CoW drift, no thesis. Negative control passes.
- **`struct` @ moderate ALLOC=100 → ractor uses MORE memory** (115% ratio); Data-structs only show a memory win at heavy
  allocation, and even then…
- **`struct` @ heavy ALLOC=500 → biggest memory win measured (578MB, 48% ratio) BUT throughput reach ~71%** (trended
  *down* with more samples, 92%→71%), below the 75% floor → a memory/throughput TRADEOFF, not a clean Pareto pass. The
  cause is real: one shared GC across all Ractors under heavy Data-struct churn vs N separate process GCs.
- **Aggressive 0.3s refork claws the hash win 210MB → 50MB** (economic no-op). The memory edge needs a non-aggressive
  (~1s) cadence; reforking 3×/sec restores refork's CoW often enough to erase the advantage.

**Niche, now MEASURED and bounded:** large frozen **HASH-shaped** read models + **moderate-to-heavy Rails-like
allocation** + **non-aggressive (~1s) refork cadence**. Definitive win there (210–314MB absolute, ≤71% PSS, ≥90%
throughput). Outside it — compact/packed state, zero allocation, Data-structs (throughput-limited), or aggressive
reforking — the strong baseline ties or wins. This is NOT a general "Ractors save memory" claim.

**Claim language update (allowed):** "Frozen Read-Model Capsules show a definitive, material memory win (210–314MB
absolute, ≤71% PSS at ≥90% throughput) vs a Pitchfork-style refork baseline, but ONLY in a measured niche: large frozen
hash-shaped read models under Rails-like allocation at a realistic refork cadence. Compact state, Data-structs, and
aggressive reforking fall outside it." Still NOT allowed: migração real validada / produto / ganho real em Discourse /
Rails apps podem adotar. Still blocked: gem/DSL/engine.

**Next gate (unchanged order):** (2) Promotion amortization benchmark (N∈{100,1k,10k} vs same frozen read model). Artifacts:
`refork_gate.rb`, `size_probe.rb`, `run_sweep.sh`, `sweep_alloc{0,100,500}.json`, `sweep_alloc500_hi.json`,
`sweep_aggressive.json`, `sweep.log`.

---

## 2026-06-14 — Validated Codex's parallel morning work; LEASE RATIFIED; struct re-run decisive

Codex worked in parallel this morning (no git, so isolated by mtime). Validated all of it against the files (5-stream
adversarial workflow + direct re-checks). **4 of 5 streams sound; 1 P1 directive conflict, now resolved by user decision.**

**Sound (verified):**
- **Codex's edit to `a2_cache_sync.rb` PRESERVED all 3 of Claude's invariants** — FAIL-on-timeout/correct=NO still trumps the
  vs_proc spread (proven live), stale replies still counted, INCONCLUSIVE guard still fires. The hard-won false-PASS fix is
  NOT regressed.
- **`economic_gate_matrix.rb`** is a sound wrapper that delegates to `refork_gate.rb` (zero independent gate math → can't
  desync); results honestly labeled "reduced ... final gate requires broader Linux runs"; does NOT contradict the calibrated
  hash-survives result (its "no survives" is just small-N below the 100MB floor).
- **Phase-3 proof productionization (8 scripts)** all run green + byte-reproducible vs committed `raw_logs`; classifications
  hold against real source (Guardian non-fit, Report partial, Promotion compatibility-not-perf); `bench` 0.26×/3.85× matches
  the ~0.21× canon (not inflated); new `promotion_write_side_gap.rb` actively prevents a "full migration" overclaim;
  `environment_proof` correctly FAILs with Colima down instead of fabricating a pass.

**P2 caveat (open):** Codex's `a2_sync_matrix.rb` sweeps only CAP_EVERY×TIMEOUT with SCAN=500/ALLOC=100 FIXED — NOT the
SCAN×ALLOC×CAP_EVERY 3D matrix the README named as the real `gateway_calls/compute_ms` axis. Conclusion is safe at this
compute point; the stated 3D requirement remains unmet → extend the matrix or amend the README. Deferred.

**LEASE — P1 directive conflict, RATIFIED by user decision (deferral lifted):** Codex made a time-bounded lease
(`claimed_at`/`locked_until`/`attempt_count`) the CANONICAL `OutboxDispatcher.claim` in both `rails_capsule_mini_app` and
`rails_capsule_slice_b`, and rewrote the existing crash tests to be lease-gated (recovery now waits for `locked_until` /
`expire_outbox_leases!`). This did the two things the earlier deferral forbade ("não implemente lease/backoff ainda";
test #6 "backoff simulado SEM mudar a semântica dos crash tests"). **User consciously LIFTED the deferral and ratified the
lease as canonical.** Accepted because it is soundly built and the trade is the one the user himself named (lease reduces
duplication, adds recovery latency, is a product decision):
- FOR UPDATE SKIP LOCKED is still the canonical lock; deliver! and mark_published remain **separate commits** (the hard-won
  deliver-before-mark fix is intact, NOT re-coupled to fake exactly-once); flat 30s lease, NO exponential backoff.
- **Frozen claim UNCHANGED and honored:** exactly-once ENQUEUE + at-least-once idempotent dispatch (NOT exactly-once external
  effect). No overclaim introduced.
- **Crash semantics now lease-gated** (deliberate): a crashed worker's row is reclaimable only after `locked_until`.
- **Measured residual-risk delta (tests #5/#6 satisfied):** leased 30s → **+0% duplicate attempts** vs non-leased
  **+197%→+487%**; zero-lease negative control **+181%**; `distinct_charges==N`, `duplicate_effect_keys==0` throughout.
- **Verified GREEN after ratification** (not on faith): slice_b **13 runs / 62 assertions / 0 failures** (incl. lease-gated
  `falsify_crash_windows`), mini_app **20 runs / 109 assertions / 0 failures** (incl. Gate 5a/5b lease tests).

**struct economic re-run — DECISIVE (resolves the floor-straddle Codex's REPS=2 cells left open):** at calibrated N=5M,
REPS=6, DURATION=8:
- struct @ ALLOC=100 → **tradeoff_fail** (saving 54MB < 100MB floor, ratio 92%). Clean NO at moderate allocation.
- struct @ ALLOC=500 → **memory win robust, throughput reach UNSTABLE.** Memory: ratio ~48–55%, saving ~528–578MB (consistent
  across runs). Throughput: two identical REPS=6/DUR=8 runs gave reach **71% (inconclusive)** vs **110% (survives)** — a
  40-pt swing driven by the refork baseline's heavy-allocation throughput variance (44–50% per-cell spread). So struct is
  **memory-favorable but throughput-unconfirmed**, NOT a clean PASS — the refork baseline is too volatile at heavy allocation
  to confirm the throughput gate. **`hash` remains the only clean, reproducible economic win** (ALLOC=100 +210MB, ALLOC=500
  +314MB). Artifacts: `struct_rerun_a100.json`, `struct_rerun_a500.json`, `struct_rerun.log`.

---

## 2026-06-14 — Executor pass: A2 3D matrix, Promotion amortization, write-side spec (verifier green)

Three real improvements attacking the next risks (not polishing closed evidence). Mandatory guard
(`ruby phase3_migration/verify_findings_evidence.rb`) **PASS, 14/14 checks**, under any locale. PIVOT verdict unchanged.

- **P1 — A2.3 is now the real 3D `SCAN×ALLOC×CAP_EVERY` matrix** the README promised (72 cells, vs the old `CAP_EVERY×TIMEOUT`
  slice with SCAN/ALLOC fixed). Measured: **12 tolerable, 53 fail, 7 inconclusive**; the aggressive-timeout negative control
  fails all 36; **chatty sync (CAP_EVERY=1) fails at every SCAN/ALLOC**; tolerable cells are infrequent reads (CAP_EVERY≥100,
  or ≥10 under heavy compute) at ALLOC≤100. So the old "all 15 cells fail" claim was **retired for an honest, more precise
  boundary** — `a2_all_cells_fail` is now `false`, but `a2_chatty_sync_is_killer=true`. This is a constraint on capsule shape,
  not an economic win; it does not move the verdict. The verifier's A2 guards were updated **in lockstep, not weakened**
  (scan/alloc are per-cell axes; aggregate rebuild; negative control asserted; runner re-pinned). Verifier hardened to force
  UTF-8 reads so the mandatory command runs under an empty locale.
- **P2 — Promotion amortization gate** (`promotion_amortization.rb`, `raw_logs/promotion_amortization_latest.json`):
  N∈{100,1k,10k}, inline×N vs capsule-seq vs capsule-par vs frozen-reuse. Result **`compatibility_only_no_amortization`** —
  the real variants never beat inline (≈0.2× at every N; the per-user owner build dominates). The frozen-reuse upper bound
  grows past 1× but is explicitly NOT a real Promotion scenario (users have distinct snapshots). No batch size flips the
  boundary. The negative result was reported, not rescued.
- **P3 — Promotion write-side migration SPEC** (`promotion_write_side_spec.rb`, `..._spec_latest.json`): maps each of the 16
  inline side-effect lines in the patched `lib/promotion.rb` to commit (7) / outbox EffectIntent (8 lines → **7 distinct
  intents**) / residue (1), with deterministic idempotency-key bases and the smallest realistic patch — WITHOUT implementing.
  Asserts `eligibility_only` / `write_side_implemented=false` (no Proposal/EffectIntent/Outbox tokens in Discourse). The
  blocker now stands as a machine-readable, actionable spec.
- **P4 — guardrails:** both new artifacts entered `verify_findings_evidence.rb` (`check_promotion_amortization`,
  `check_promotion_write_side_spec`) with SHA pins; FINDINGS Audits #6/#52/#53/#54 added/updated. Support skills (thermo +
  sk-ruby) reviewed the change: verifier confirmed NOT weakened (6 tamper tests all caught); applied their fixes (multi-fixture
  drift guard, lifted inline require, NS hardening, two FINDINGS accuracy nits). **Hard rules honored:** lease not reverted;
  struct kept throughput-unconfirmed (not promoted to clean pass); macOS-vs-Linux caveat preserved (amortization labeled
  macOS pure-compute); no gem/DSL/product; no "ran in a Ractor" as proof; verdict stays PIVOT.

---

## 2026-06-16 — Honesty-drift remediation: README front door + stale A2 "15 cells" sweep + audit caveat

**Context.** An adversarial review (sk-ruby/thermo posture) flagged that the *evidence files* (FINDINGS.md, the
verifier) had been kept honest at PIVOT, but the *front door* had not: README.md still opened with "Thesis CONFIRMED /
`hash` SURVIVES" and decisions.md's 2026-06-14 header read as a product-authorizing result. Risk: a future agent
cherry-picks the legacy calibrated probe and rebuilds product/gem/DSL on vencido evidence. Each of the 7 review findings
was first **verified against the actual files** (parallel per-finding adversarial check) before any edit; 2 were already
honest in FINDINGS (economic-not-resolved at FINDINGS.md:352 already says PIVOT; the Promotion-wedge direction already
stated at FINDINGS.md:21), so no edit was made for those — the gap was only that README/decisions did not surface them.

**Options considered.** (a) Rewrite the 2026-06-14 journal entry to delete "CONFIRMED" — rejected: erasing what was
concluded that day is itself dishonest. (b) Refactor `refork_gate.rb`'s shape-aware kernel into `BenchKernel`, and
rewrite `audit.rb`'s `candidate_for` as an adversarial score — rejected: both move SHA-pinned runner files and the audit
rewrite could flip verifier-asserted classifications, for no verdict-bearing gain. (c) **Chosen:** documentation-honesty
edits + one source caveat, each preserving (and where needed re-pointing) every verifier pin.

**Changes.**
- **README.md** — added a top-of-file **Current verdict: PIVOT** banner (economic_final_gate_passed=false; no current
  Linux matrix has a surviving alloc; the hash +210/+314MB numbers are a legacy 2026-06-14 probe, not product-authorizing;
  points to FINDINGS.md as authoritative). Relabeled "## Result so far — economic gate MEASURED" → "## Legacy calibrated
  probe …, NOT the current final gate" and the "Thesis CONFIRMED but NARROW" line → "Single-probe result … NOT a passed
  final economic gate". Clarified the `bench_kernel.rb` table cell: it is the hash/A2 kernel; `refork_gate.rb` defines its
  own shape-aware build/compute/work and uses bench_kernel only for infra (the conceptual-duplication the review noted; the
  code comment already said "Hash shape only"). All 5 verifier-pinned README fragments left byte-for-byte intact.
- **FINDINGS.md** — swept every stale present-tense "15 cells" claim now contradicted by the 72-cell 3D matrix: the
  verdict-text description (the verifier actually requires the 72-cell line, so "all 15" mis-described the check), the
  Audit #40 result claim, and the Audit runtime-cell counts (`15 → 72`, the value the verifier emits as
  `linux_ruby_cells_checked` for a2_sync_gateway). Standardized claim everywhere: CAP_EVERY=1 always fails; rare sync at
  ALLOC≤100 can be tolerable; nothing stronger. `a2_all_cells_fail=false` but `a2_chatty_sync_is_killer=true`.
- **audit.rb** — added a caveat at the risk site: `candidate_for` is a loose ORIENTATION label, NOT a fit verdict;
  `callbacks_or_procs.zero?` does not prove capsule-compatibility, so the `fit` bucket can over-count; authoritative
  fit/non-fit is the manual proofs. Re-pinned `CAPSULE_HOSTILITY_AUDIT_RUNNER_SHA256` to the new SHA (comment-only change;
  the asserted classifications are unaffected — pin preserved, just re-pointed at honest text).
- **docs/decisions.md** — added an in-context breadcrumb under the 2026-06-14 header (it was a single calibrated probe,
  read against the PIVOT verdict) without rewriting the historical record, plus this entry.

**Verification.** `ruby -c` clean; `verify_findings_evidence.rb` **PASS, 14/14, exit 0** under empty locale after the
re-pin. **Verdict unchanged: PIVOT.** No claim strengthened — claims were *weakened* toward honesty (the "all 15 A2 cells
fail" wording is retired in favor of the measured 72-cell boundary; "CONFIRMED" reframed as a legacy probe). Hard rules
honored: lease not reverted; struct still throughput-unconfirmed; macOS-vs-Linux caveats kept; no product/gem/DSL; verifier
not weakened (every pin preserved or re-pointed at honest text, no assertion deleted). Next blocker is unchanged: a real
Discourse write-side outbox patch, or a larger non-reduced Linux economic gate.

---

## 2026-06-16 — Strong Host-Linux Economic Gate v2: built, adversarially corrected, REDUCED run (PIVOT held)

**Context.** The next decisive question was economic, not documental: does the Ractor frozen image still beat a STRONG
process baseline at iso-throughput, or does a compacted / warmed / prefork-warmed / reforked process close the CoW gap?
Built `strong_host_gate_v2.rb` — a new standalone runner (does NOT touch the SHA-pinned `refork_gate.rb`/`bench_kernel.rb`;
self-checks its hash kernel against `bench_kernel` at startup) pitting the Ractor against an 7-model strong battery (6 process baselines + 1 Ractor) with the
full smaps breakdown (PSS/Private_Dirty/Shared_Clean/Shared_Dirty/RSS), startup, steady-state, across shape×target×alloc×workers,
decided at iso-throughput (PSS ≤75% AND saving ≥100MB AND reach ≥75%).

**Adversarial review before trusting numbers.** A 4-skeptic review found EVERY measured bias tilting toward the thesis; all
removed: symmetric GC-settle for all models (refork was the only one denied it); one throughput basis `sum(done)/max(elapsed)`
for all (was median-elapsed for static/ractor vs a fork-inclusive wall for refork); reach band anchored to the single
strongest-throughput process cell (the straddle guard was dead — it divided a w4-Ractor by a w1-process); unreachable
baselines excluded from "strongest" selection (`iso_mem` clamped them to their largest PSS); per-Ractor deadlines (was set
pre-spawn); per-worker ratio surfaced so a non-monotonic frontier can't hide a losing worker. smaps PSS-summing was confirmed
correct (the Ractor LOSES the w1 cell → no under-count). Removed a dead gateway model + an FD-leak-on-fork-failure.

**REDUCED Linux result (hash @ 200MB, REPS=3, DUR=3 — `run_class=reduced`, NOT the full gate).** ALLOC=0 → **PIVOT**
(95MB saving / 68% PSS, below the 100MB floor; negative control fires); ALLOC=100 → Ractor **51% PSS / 263MB saving / 94% reach** vs the strongest
static baseline (`process_gc_compact_plus_warmup`) but ONLY at the w4 operating point (single-point), and the per-REPS PSS band is near-zero
(memory is deterministic, so the win is not median-luck). Mechanism measured: process
Private_Dirty multiplies with workers under churn while the Ractor's stays flat; at ALLOC=0 the dataset stays Shared_Dirty
(shared) so processes match the Ractor.

**Decision: PIVOT holds.** Strong reduced signal that the win survives the STRONG baselines (not just refork), but it is
single-point and reduced — REPS≥6/DUR≥8/≥500MB/struct+blob/multi-point are unrun, and w4/ALLOC=100 throughput showed real
cross-baseline variance REPS=3 can't settle. **No false PASS:** the verifier pins the runner SHA and adds
`check_strong_host_gate_v2_reduced` (now 15/15) which records the reduced finding, asserts the ALLOC=0 control still fails,
and forbids the artifact from masquerading as `full_host` — it does NOT assert a gate pass; `economic_final_gate_passed`
stays false. The exact full-host command (SHAPES=hash,struct,blob TARGETS_MB=200,500,1000 ALLOCS=0,100,500 WORKERS=1,2,4,8
REPS=6 DUR=8, on a dedicated large Linux host) is recorded in FINDINGS Audit #55. Next blocker: run that full gate, or the
real Discourse write-side outbox. Hard rules honored: no product/gem/DSL; struct still throughput-unconfirmed; macOS never
feeds a memory claim; verifier strengthened, not weakened (additive guard only).

## 2026-06-17 — Strong gate v2 hardening pass 2: killed-rerun recovery + two methodological P1s + forgery residual (PIVOT held)

**Context.** A reduced re-run with the new runner was killed mid-flight, leaving an inconsistent tree (fresh raw log/SHA,
stale aggregate, mixed per-cell files → verifier failed on SHA mismatch). It was recovered: the reduced Linux run was
re-done cleanly with runner `e2efbe21…`, docs reconciled to the new aggregate, and the verifier re-pinned. Two methodological
P1s and one forgery residual that would turn into false-PASS on a big, noisy full run were then closed **before** the full gate.

**What changed.** (1) **Adversarial-baseline pessimistic PASS** — the worst-case PSS band now compares the Ractor's worst
PSS against the *lowest* `iso_pss_lo` across ALL reachable baselines (`adversarial_baseline`), not the median-selected one;
the reported ratio/saving stay the median baseline's. (2) **Pessimistic per-worker `wins`** — a final win requires the
pessimistic per-worker gate AND not-extrapolated AND not-straddling; the median view is kept as `median_wins`
(informational), and a `survives` with no pessimistic worker win is demoted to `inconclusive`. (3) **Verifier per-cell +
roster + forgery guards** — `check_strong_host_gate_v2_reduced` asserts the exact 7-model roster, cross-checks every
per-cell JSON byte-for-byte against its aggregate record (dir must contain exactly those files), hard-fails if a full-host
artifact exists without `check_strong_host_gate_v2_full`, and ties each verdict's headline ratio/saving to the raw per-cell
PSS (F1). `run_class=full_host` is now explicitly an operational label only; a full economic claim requires the (unwritten)
full check.

**Verification.** New reduced (Linux, aarch64, run_class=reduced, 42 cells): ALLOC=0 → **PIVOT** (67.8% PSS / 95.1MB / 99.5%
reach vs `process_gc_compact`; below the 100MB floor, control fires); ALLOC=100 → **SURVIVES** (50.8% PSS / 263.3MB / 94.4%
reach vs `process_gc_compact_plus_warmup`, PSS band `[0.508,0.509]`, single-point w4). `verify_findings_evidence.rb` → 15/15
PASS, exit 0; runner SHA on disk == pin == aggregate `runner_sha256`; Docker idle. All new guards tamper-proven to fail
(per-cell missing/divergent/extra; verdict ratio→56 and saving→210 forged inside the old tolerance bands; headline PSS
decoupled from its cell). An independent adversarial review (3 read-only reviewers + 1 adjudicator that re-checked each flag
against the files) returned **0 real blockers**; its single residual — the verifier still trusts the runner's
iso-*interpolation* of the baseline (covered by the SHA pin, not recomputed) — is a bounded forgery threat, not a real-run
false-PASS.

**Decision: PIVOT holds.** Stronger, honest reduced signal that now beats the STRONG static molds (`gc_compact_plus_warmup`),
but still Colima/reduced, hash-only, 200MB, REPS=3/DUR=3, single-point w4 — does NOT license CONTINUE/gem/DSL/product.
`economic_final_gate_passed` stays false. Next technical step: run the full host gate on a dedicated Linux host into
`strong_gate_v2_full_runs`, then write `check_strong_host_gate_v2_full` before crediting any full result. Hard rules honored:
no product/gem/DSL; struct still throughput-unconfirmed; macOS never feeds a memory claim; verifier strengthened, not weakened.

## 2026-06-18 — Full-gate infrastructure built (atomic launcher + INDEPENDENT full verifier); full run BLOCKED_BY_HOST_LINUX (PIVOT holds)

**Context.** The only path to the economic decision is the full host gate on a dedicated Linux host. This host is macOS/Colima
(NOT dedicated). So instead of minting a non-dedicated full artifact (forbidden), built and PROVED the host-independent
tooling that gates the eventual real run.

**Built.** (1) `phase3_migration/run_strong_gate_full.sh` — an ATOMIC launcher: classifies the host
(DEDICATED_LINUX_HOST / MAC_OR_COLIMA / NO_DOCKER_OR_NO_LINUX), REFUSES to mint a full economic artifact unless dedicated
(`ALLOW_NON_DEDICATED=1` is diagnostic only; the verifier rejects completed full artifacts whose manifest `host_class` is not
`DEDICATED_LINUX_HOST`), isolates each run under `strong_gate_v2_full_runs/<run_id>/`, writes the aggregate JSON
to `.partial` and ATOMIC-renames only on the runner's `JSON written:` completion marker, stamps a manifest started→complete,
and never clobbers the canonical artifact or the reduced evidence. A killed run leaves a `started` manifest the verifier
ignores. Canary mode writes to a separate `strong_gate_v2_canary_runs/` and is never validated as an economic result. The
SHA-pinned runner is NOT modified. (2) `check_strong_host_gate_v2_full` in the verifier — an INDEPENDENT reimplementation of
`verdict_for` (`sg_recompute_verdict`) that DERIVES status/ratio/saving/reach/baselines/pessimistic-wins from the raw
per-cell cells instead of trusting the runner's emitted verdict (this also closes the F1 residual). It self-tests every run:
the recompute MUST reproduce the runner's emitted verdicts. Validation of a completed full run asserts manifest
`host_class=DEDICATED_LINUX_HOST`, run_class=full_host,
Linux/Ruby-4.0.5 (top-level AND per-cell), runner_sha256==pin, the EXACT full config, exact grid coverage (every
shape×target×alloc×workers tuple carries the precise 7-model roster — closes duplicate-one/drop-one), a MANDATORY per-cell
byte cross-check, and rejects any survives that recomputes as extrapolated / median-only / straddle.

**Proven (facts).** The recompute reproduces the reduced verdicts EXACTLY (pivot@0 67.8%/95.1MB/99.5%; survives@100
50.8%/263.3MB/94.4%; baselines + wins all match). A synthetic 756-cell full run validates end-to-end; a forged kill→survives
is REJECTED (`recompute status kill != emitted survives`); and after a 3-agent review (sk-ruby + thermo + adversarial
false-PASS hunt) the found false-PASS holes were closed and tamper-proven to fail: skippable per-cell cross-check (now
mandatory), duplicate-one/drop-one (now grid+roster checked), `sg_iso_at` divide-by-zero→NaN (guarded), null pss (rejected).
verify_findings_evidence.rb → 16/16 PASS, exit 0. On THIS host the launcher correctly prints `BLOCKED_BY_HOST_LINUX` and runs
nothing.

**Decision: PIVOT holds; nothing promoted.** `economic_final_gate_passed` stays false; `check_strong_host_gate_v2_full` never
flips it (the verdict promotion stays a deliberate manual step once a real dedicated-host full run validates). The single
remaining experiment: `phase3_migration/run_strong_gate_full.sh full` on a DEDICATED Linux host, then judge by the (now built)
independent full verifier. Residual (accepted, documented): the recompute trusts forger-supplied cells if ALL coupled inputs
(cells + per-cell mirrors + verdict + SHA-pin string) are mutually consistent — the SHA pin proves the code is unmodified, not
that the JSON came from running it; this is a manual-forgery threat, not a real-run false-PASS.

## 2026-06-29 — Establish an honest public repo contract (no deploy theater)

**Context.** The repository already contained real R&D evidence, but the publication surface was weak: no root manifest, no
single repository verification entrypoint, a placeholder README in `rails_capsule_mini_app`, a committed
`rails_capsule_mini_app/config/master.key`, and a `rails_capsule_slice_b/run.sh` path that claimed `DATABASE_URL` override
support while still hard-requiring Docker bootstrap. Those were credibility and publication problems, not thesis problems.

**Options considered.**
1. Keep the repo as an ad hoc working directory and rely on manual commands plus existing notes.
2. Add product/deploy surface to satisfy a generic checklist.
3. Keep the repo explicitly R&D, add a small root contract, support external Postgres URLs for the fast proof surfaces, and
   remove the tracked key.

**Decision.** Choose option 3. Added a root `.ruby-version`, a minimal root `Gemfile` for the day-1 smoke dependency, `bin/setup`,
`bin/check`, GitHub Actions CI, a real mini-app README, test database URL overrides for the booted Rails slice, and a Slice B
runner that skips Docker bootstrap when `DATABASE_URL` is already provided. Deleted the committed mini-app `config/master.key`
and ignored it locally. The local `phase3_migration/discourse/` checkout stays external to the outer repo history; the patch,
scripts, raw logs, and findings remain versioned here. No deploy manifest was added.

**Pros.**
- A reviewer can run the fast falsification contract in minutes.
- Local Postgres and CI Postgres service both work without pretending the repo is a deployable service.
- Secret/publication risk is reduced immediately.

**Cons.**
- The fast contract still does not rerun the expensive Linux economic gates.
- The repository now has three Bundler contexts (root, mini app, Slice B) because the surfaces are genuinely different.

**Consequences.**
- `bin/check` now proves mechanics + booted Rails protocol + owner-side ActiveRecord/Postgres protocol.
- Phase 3 Linux gate evidence remains manual and documented in existing findings/raw logs.
- Future loops should deepen Phase 3 or tighten evidence publication, not add deploy posture.

**Verification evidence.**
- `bin/setup`
- `bin/check` → `day1_smoke_test.rb`: 0 unexpected errors
- `bin/check` → `rails_capsule_mini_app`: 20 runs, 109 assertions, 0 failures, 0 errors
- `bin/check` → `rails_capsule_slice_b`: 13 runs, 62 assertions, 0 failures, 0 errors

## 2026-06-29 — Add evaluator-grade architecture and root contract evidence

**Context.** The repo was already honest about its R&D state, but the publication harness still lacked a
recognized top-level architecture document and a root test surface. The evaluator also inferred deploy posture from
README wording that described a deployable shape the repo does not claim.

**Options considered.**
1. Add fake deploy material so the harness sees a more conventional app.
2. Change only the evaluator and leave the repository publication surface weak.
3. Strengthen the repository's own evidence: add a recognized architecture document, a small root contract test,
   wire it into `bin/check`, and rewrite the README so it does not read like a hidden runtime.

**Decision.** Choose option 3. Added `docs/architecture.md`, a root `test/` directory with
`test/research_contract_test.rb`, and made `bin/check` run that contract before the heavier proof slices. Reworded
the README to keep the repo explicitly research-shaped and to avoid deploy/runtime language the evaluator treats as
an application signal.

**Consequences.**
- The repository now exposes architecture and verification surfaces the evaluator can detect without adding theater.
- The fast proof path now checks the publication contract before running the Rails/Postgres slices.
- If deploy classification still needs a tooling-side override later, that follow-up is now about evaluator policy,
  not missing repo evidence.

## 2026-06-29 — Surface the deep research audit without pretending it belongs in public CI

**Context.** The repo already had `phase3_migration/verify_findings_evidence.rb`, which is the strongest machine check
in the repository, but a reviewer had to discover it indirectly through long-form findings and raw scripts. At the same
time, that verifier depends on the external local Discourse checkout intentionally ignored from outer git history, so
blindly moving it into GitHub Actions would be theater.

**Options considered.**
1. Leave the verifier buried in Phase 3 notes and keep the public contract shallow.
2. Pretend the verifier belongs in public CI and ignore the missing external checkout.
3. Add an explicit local entrypoint for the deep audit, document the boundary, and keep public CI limited to the vendored contract.

**Decision.** Choose option 3. Added `bin/research-check` as the honest entrypoint for the machine findings audit and
documented that it requires the local `phase3_migration/discourse/` checkout. The root contract test now guards the
existence of that entrypoint and the README explains why it is intentionally outside GitHub Actions.

**Consequences.**
- Reviewers now have a visible path from the fast contract to the deep research audit.
- The repo exposes more of its specialist evidence without pretending that ignored local fixtures are vendored inputs.
- Future work can still decide to vendor or replace the Discourse fixture, but until then the boundary is explicit.

---

## 2026-06-29 — Publish the research repo under the MIT License

**Decision.** Add `LICENSE.txt` and a README license section so the benchmark
evidence, harnesses, and research notes are intentionally reusable.

**Why.** This repository is already public and explicitly framed as research.
Default copyright would keep the experiments readable but leave the legal reuse
boundary unclear for engineers who want to study or adapt the harnesses.

**Tradeoffs accepted.** A permissive license can lead to partial reuse of the
benchmarks without all the caveats preserved in the decision log. That risk is
acceptable because the repo's purpose is research communication, not product
capture.

**Refs.** `LICENSE.txt`, `README.md`.
