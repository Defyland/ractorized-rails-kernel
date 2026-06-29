# Current evidence verdict

Verdict atual: **PIVOT / continue only as narrow P&D**, not product/runtime/platform.

- Promotion: eligibility-only compatibility proof. The real Discourse patch is one file (`lib/promotion.rb`, +71/-17) and
  remains `eligibility_only`; the write side still does not implement `Proposal + EffectIntent + outbox` in Discourse.
- Guardian: structural non-fit.
- Report: partial only.
- Economic gate: current reduced Linux matrices have **no surviving allocs** in the broad matrix and no surviving allocs in
  the struct-stability matrix. The calibrated `struct` re-run is now guarded separately: ALLOC=100 fails the memory floor;
  ALLOC=500 is memory-favorable but throughput-unconfirmed because a latest positive cell conflicts with an earlier
  identical-config inconclusive run.
- A2 sync gateway: 3D SCAN×ALLOC×CAP_EVERY matrix (72 cells) — chatty bounded-sync (CAP_EVERY=1) fails at every SCAN/ALLOC;
  only infrequent sync (≈1 read per ≥100 items, or ≥10 under heavy compute) at modest allocation is tolerable, and never
  under heavy allocation — sync deps in capsules must be rare or forbidden. 12/72 tolerable, 53 fail, 7 inconclusive;
  the aggressive-timeout negative control fails all 36 cells.
- Promotion benchmark: owner snapshot build + decide is slower than inline in the current artifact; pure decide parallelizes,
  but this is not an end-to-end performance win.
- Historical Discourse `spec/lib/promotion_spec.rb` before/after output is **not current machine-guarded evidence**; no
  raw before/after spec logs are part of the evidence bundle.
- Strong host-gate v2 (`strong_host_gate_v2.rb`, NEW — REDUCED, NOT the final gate): a bias-corrected runner (7-model
  strong-baseline battery — naive / GC.compact / Process.warmup / compact+warmup / prefork-warmed / refork vs the Ractor
  frozen image — full PSS/Private_Dirty/Shared_Clean/Shared_Dirty breakdown, every fairness lever made symmetric after an
  adversarial review found them tilting toward the thesis). A REDUCED Linux pass (hash @ 200MB, REPS=3, DUR=3): ALLOC=0 →
	  **PIVOT** (95MB saving, 68% PSS — below the 100MB floor; negative control fires correctly); ALLOC=100 →
	  Ractor **51% PSS / 263MB saving / 94% reach** vs the strongest *static* baseline (process_gc_compact_plus_warmup) — but **only at the w4
  operating point (single-point)**, with a near-zero per-REPS PSS band (memory deterministic → not median-luck). Strong reduced signal that the hash-under-allocation win survives the STRONG baselines
  (not just refork), CoW mechanism now measured (process Private_Dirty multiplies with workers; the Ractor's stays flat). It
  is **not** a passed full gate — REPS≥6/DUR≥8/≥500MB/struct+blob/multi-operating-point are unrun; `economic_final_gate_passed`
  stays false; verdict stays **PIVOT**.
- Do not advance to gem/DSL/product. The next materially useful experiment is either a real Discourse write-side outbox
  patch for Promotion or a larger Linux process/refork gate.

---

# Phase 3 — Migration Cost Slice (Discourse) — Audit #1 (capsule-hostility)

Target: real OSS Rails app **Discourse** (shallow clone, `36ee9d7c`, 2026-06-12), ~294 MB. Measured how
capsule-hostile 3 real services are *before* attempting a migration — the crux is "do enough real Rails services fit
the frozen-read-model capsule model without a rewrite?" Counts are a reproducible static scan over the target git ref
(`git ls-tree` for file discovery + `git show` for file contents), then grounded by reading the code.

## The three services + measured profile

| Service (role) | file(s) | LOC | call-sites (files / calls) | `SiteSetting` | `I18n` | live AR / `DB.query` | held mutable state | shape |
|---|---|---|---|---|---|---|---|---|
| **Guardian** (authorization/policy) | `lib/guardian.rb` + 16 modules | **2267** | **179 files / 668 calls** | **138** | 0 | **47 AR** | `@user` (**113 refs**) | **224** live `can_*?`/`is_*?` predicates |
| **Report** (report/export) | `app/models/report.rb` | 611 | 16 files / 33 calls | 4 | 7 | 14 AR + 2 `DB.query` | 12 `@ivar` (builds data) | cached read model (`Discourse.cache.read(cache_key)`, `add_report(&block)`) |
| **Promotion** (rules) | `lib/promotion.rb` | 176 | 7 files / 8 calls | 12 | 1 | 2 AR (+`calc_topic_reply_count!`) | `@user` | pure eligibility rules + a write action |

> All numbers above are regenerated from the reproducible `audit.rb` → `audit_output.json` (the authoritative
> source). Guardian's call-site count is **668** (predicate calls **plus** `Guardian.new` + `@guardian` refs across
> `app/`+`lib/`); an earlier draft cited **325** from a narrower manual grep that counted only `guardian.can_*`/`is_*`
> predicate calls. The larger, reproducible count only **strengthens** the non-fit conclusion. LOC is `audit.rb`'s
> per-file line sum (2267) vs an earlier `wc -l` (2251).

## Grounded verdict per service (capsule fit)

**Promotion — BEST FIT for eligibility only (not a complete capsule product claim).** The eligibility half (`tl1_met?`/`tl2_met?`) is a *pure
function* of `user.user_stat` fields + `SiteSetting.tl*_requires_*` config — snapshot both into a frozen, Ractor-
shareable `CapsuleContext` and the rule logic moves verbatim. The write half (`change_trust_level!`) is a transaction
emitting side effects (`UserHistory`, `DiscourseEvent`, `BadgeGranter.queue_badge_grant`, `Group.user_trust_level_change!`)
— this is only a **candidate mapping** onto the separate mini-app protocol; it is **not implemented or validated inside
Discourse in this phase**. A complete claim would require a real `Proposal + EffectIntent + outbox` patch against
Discourse. **Residue:** `calc_topic_reply_count!`
is a live query+mutation (the `!`) that must be pre-resolved on the owner before freezing; the 12 `SiteSetting` reads
must be lifted into the snapshot. Small blast radius, but the reproducible baseline is **7 files / 8 calls**, not the
older 4-file manual count.

**Report — PARTIAL FIT.** It is *already* a cached read model (`find_cached` → `Discourse.cache.read`), conceptually
the closest to a capsule. But the cache is the **Redis global** (`Discourse.cache`/`Discourse.redis`) — a synchronous
gateway dependency (Phase-1 design law: sync deps must be batched/async or they erode the economy), and each report is
**live SQL aggregation** at request time, not a pre-frozen model. Migration = move the SQL to owner-side pre-freeze +
replace the Redis read with the capsule, keep I18n labels (7) at the owner edge. Medium blast radius (16 files).

**Guardian — NON-FIT (a rewrite, not a migration).** 224 predicates, each evaluating the **live** state of the target
object per call (`can_edit?(post)` depends on the post's *current* row), with 47 inline AR queries + 138 `SiteSetting`
reads against a held mutable `@user` (113 refs). Authorization is "decide on current state now" — the inverse of a
frozen snapshot. You cannot pre-freeze "can this user edit this post" without freezing the entire mutable object graph
the check inspects. And it is the **most-called service in the codebase: 179 files, 668 call-sites** — so even a
partial migration is a repo-wide change. Discourse's own `CLAUDE.md` reinforces the coupling ("use `user.guardian`
shorthand", "`can_see?`/`can_edit?` patterns").

## The headline finding (falsifiable, potentially thesis-narrowing)

**Capsule-friendliness is inversely correlated with (a) live per-call state lookups and (b) call-site centrality.**
The service that would benefit MOST from parallelism — hot authorization checks (Guardian, 179 files) — is the WORST
fit. The best fits (pure rules like Promotion) are small and rarely called (7 files / 8 calls). The middle (Report) is a read
model but leans on a Redis sync-gateway + live SQL.

So the niche is **real but narrow and correctly named**: "Frozen **Read-Model** Capsules" fit read-models and
pure-rule services, NOT live-lookup authorization. The open question for the project's value is no longer "is the
protocol real" (it is) — it is **"is the addressable surface big enough?"** In Discourse, by call-site weight, the
dominant service (authorization) is out of scope by construction.

## Next (proposed)
1. **Real migration of Promotion → capsule** (small, best fit) to produce a *measured* diff: LOC changed, globals
   removed (12 SiteSetting + the held user), callbacks→descriptors, EffectIntents emitted, residue named, and a
   before/after of the eligibility path. This is the gold-standard migration-cost number.
2. **Guardian non-fit proof:** take one predicate (`can_edit?(post)`) and show the concrete set of live lookups that
   cannot be frozen — quantifying *why* it is a rewrite.
3. Only then judge whether the addressable niche justifies continuing toward a public API.

---

# Phase 3 — Audit #2: Promotion → capsule migration (MEASURED, real Discourse)

Commit `36ee9d7cc8262ee2c90aedd4771ed0389122d227`. Reproducible audit: `audit.rb` → `audit_output.json`.
The historical Discourse spec comparison was run on Ruby 3.4.9 (asdf) + Postgres 16 (pgvector container) + Redis; spec
is `spec/lib/promotion_spec.rb`. Current machine-readable environment proof for the active artifacts lives in
`raw_logs/environment_proof_latest.json` and records Ruby 4.0.5, Rails 8.1.3 mini-app, ActiveRecord 8.1.3, and Postgres
16.14 targets.

## Artifacts (all measured, not estimated)
- **Patch:** `promotion_capsule/promotion.patch` — `lib/promotion.rb`, **+71 / −17, one file**, syntax OK. Eligibility
  now delegates to a pure `Eligibility` module over a frozen `Snapshot`; the comparisons are byte-identical.
- **Historical spec before/after (not current evidence):** a previous same-env/same-seed run of
  `spec/lib/promotion_spec.rb` observed BEFORE (unpatched) `29 examples, 3 failures` and AFTER (patched)
  `29 examples, 3 failures`, with the same 3 JS-asset setup failures (`PrettyText`/mini_racer needing
  `node_modules/loader.js`). This is useful context but **not current machine-guarded evidence**: no raw before/after
  Discourse spec logs are present in `raw_logs`, and `verify_findings_evidence.rb` does not replay the Discourse spec.
  The current guarded evidence for Promotion is proof/drift/patch/benchmark/write-gap, not this historical RSpec output.
- **Eligibility correctness (independent of the JS gap):** `promotion_capsule/proof.rb` — the extracted decision
  equals Discourse's original logic on **8 fixtures** (incl. the exact tl1-promotion + account-too-young age-gate +
  tl2 + residue-field cases the 3 blocked spec tests check), each **run in a non-main Ractor**.
- **Ractor-shareable:** `Ractor.shareable?(snapshot) == true`; static check confirms the capsule references **no**
  `SiteSetting`/`ActiveRecord`/`Rails.`/`DiscourseEvent`/`BadgeGranter`/`Redis`/logger.
- **Proof payload:** 21 primitive fields, **537 bytes** in `raw_logs/promotion_capsule_proof_latest.json`. No AR graph
  crosses the boundary.
- **Benchmark** (`raw_logs/promotion_bench_latest.json`, pure CPU): latest run shows inline full ~1.76M decisions/s,
  owner snapshot build + decide ~479K/s (**0.27× vs inline**), decide-only ~3.12M/s, and decide-only ×4 Ractors ~12.87M/s
  (**4.12× vs single decide**). Interpretation: compatibility proof, **not** an end-to-end performance win; the pure
  decide parallelizes, but the owner still pays snapshot build per call.

## Globals removed from the hot path / EffectIntents / residue
- **Globals lifted to the owner snapshot:** 12 `SiteSetting.tl*_requires_*` reads + `user`/`user_stat` fields +
  `Time.now`. The capsule path touches **zero** globals.
- **Write side status:** not migrated in Discourse. `change_trust_level!` still performs AR writes and side effects
  inline. The plausible mapping is 7 `EffectIntent`s — `UserHistory` audit row, `DiscourseEvent :user_promoted`,
  `Group.user_trust_level_change!`, `BadgeGranter.queue_badge_grant`, the tl0→tl1 member-welcome message, the tl1→tl2
  promotion message — but this remains design residue until a real Discourse outbox patch exists.
- **Residue (must stay on the owner):** `calc_topic_reply_count!` (live query+mutation — pre-resolved into the
  snapshot, lazily, only when trust_level==1); `recook_bio` (PrettyText/mini_racer native — owner-only, like
  Nokogiri); the AR writes + transaction; `DiscoursePluginRegistry.apply_modifier(:review_trust_level/...)` plugin
  hooks (global registry, run before the capsule); TL3 (`TrustLevel3Requirements`, expensive — already deferred).

## Gate verdict — Promotion eligibility compatibility only; project gates remain failing
- migration changes little code locally ✓ (+71/−17, one file) · CapsuleContext shareable ✓ · proof payload small ✓ (537 B) ·
  eligibility runs in a Ractor without Rails globals ✓ · historical Discourse spec comparison is not current
  machine-guarded evidence · residues few and named ✓ (4).
- full claim blocked: side effects do **not** become `EffectIntent`s in the Discourse patch, mutable Proposal rejection is
  not tested against Discourse, and commit/outbox soundness is inherited from the synthetic Rails slice rather than proven
  in Discourse.
- Local Promotion-eligibility migration blockers are not hit: no big rewrite, SiteSetting/User/UserStat snapshot cleanly
  (primitive fields), and no large AR graph crosses the boundary. This is **not** a project-level continuation gate:
  the write side is still inline, owner snapshot+decide is slower than inline in the current benchmark, A2 sync-gateway
  cells all fail, and the economic matrices have no surviving allocs.

## Guardian non-fit — PROVEN (`guardian_non_fit_proof.rb`)
Grounded in real `can_edit_post?` dependencies. A frozen snapshot of the answer diverges from a live re-check on
**3/3** mutations: post locked, **clock advanced past `edit_time_limit` (no data changed at all)**, post soft-deleted.
Staying correct needs an owner round-trip for every live read (post.locked?/deleted_at/hidden?/wiki, the wall-clock
edit-limit, @user.admin?/staff?/silenced?, ~10 SiteSettings, `Discourse.static_doc_topic_ids`, ~10 recursive
predicates) — i.e. it stops being a capsule.

## Phase-3 conclusion (this sample)
The niche is REAL but narrower than the optimistic claim: Promotion eligibility migrated with a +71/−17 one-file patch,
a 537-byte proof snapshot, zero globals in the capsule, and 4 named residues. The historical Discourse spec comparison is
not current machine-guarded evidence. The write side is not migrated in Discourse. The niche is also NARROW: the best fit
(Promotion) has 7 files / 8 calls; the dominant
service by call-site weight (Guardian, 179 files) is a proven non-fit. The crux ("is the addressable surface big enough?")
now needs the survey — how many real services look like Promotion/Report vs Guardian.

---

# Phase 3 — Audit #3: false-PASS cleanup and adversarial artifacts

This pass tightened claims against the stricter "Frozen Read-Model Capsules for Rails" bar.

## New/reworked artifacts

- `audit.rb` now emits the required operational fields (`rails_cache_reads`, `rails_logger_reads`, `redis_reads`,
  `current_reads`, `callbacks_or_procs`, `native_ext_touches`, `held_ar_state_refs`, `side_effect_calls`,
  `candidate`, `reasons`) and includes 3 extra heuristic candidates beyond Promotion/Guardian/Report.
- `audit_output.json` was regenerated against Discourse `36ee9d7cc8262ee2c90aedd4771ed0389122d227`; it reports 6
  services/candidates.
- `guardian_non_fit_proof.rb` is now a top-level artifact. It reads real `lib/guardian/post_guardian.rb`, extracts
  `Guardian#can_edit_post?` lines 153-203, reports 44 real-source live-read hits, and shows a faithful owner-edit slice
  goes stale on 3/3 ordinary changes (`post.locked`, edit-limit clock advancement, `post.deleted_at`).
- `report_partial_proof.rb` classifies Report as `partial`, not `fit`, with concrete line evidence: cache/Redis globals
  at lines 252/365/370, live DB/AR query points in `find`/`req_report`, I18n/logger/SiteSetting reads, and dynamic
  `add_report`/`public_send` dispatch.
- `drift_check.rb` now includes negative controls: operator mutation, field mutation, removed guard, and order mutation
  all go red. The check remains explicitly static.

## Commands and results

- `ruby -c phase3_migration/audit.rb && ruby -c phase3_migration/report_partial_proof.rb && ruby -c phase3_migration/promotion_capsule/drift_check.rb && ruby -c phase3_migration/promotion_capsule/proof.rb && ruby -c phase3_migration/promotion_capsule/bench.rb`
  - PASS: all syntax OK.
- `ruby phase3_migration/promotion_capsule/drift_check.rb`
  - PASS: tl1/tl2 guard field/operator/threshold/order match real `lib/promotion.rb@36ee9d7c`.
  - PASS: all 4 mutation controls go red.
- `ruby phase3_migration/report_partial_proof.rb`
  - PASS: classification `partial`; `find_cached` has 1 synchronous cache read; `req_report` has 8 query ops in the
    extracted body.
- `ruby phase3_migration/guardian_non_fit_proof.rb`
  - PASS: 44 live-read hits from real predicate source; stale snapshot slice diverges 3/3.
- `ruby phase3_migration/promotion_capsule/proof.rb && JSON_OUT=phase3_migration/raw_logs/promotion_bench_latest.json ruby phase3_migration/promotion_capsule/bench.rb`
  - PASS: snapshot shareable, 8 fixture equivalence, no forbidden capsule globals.
  - Bench: latest artifact reports inline full ~1.76M decisions/s; owner snapshot build + decide ~479K/s (0.27x vs
    inline); decide-only ~3.12M/s; decide-only x4 Ractors ~12.87M/s. Interpretation: compatibility proof, not
    end-to-end performance win.
- Docker/Linux refork smoke:
  - `N_RULES=20000 ITEMS=200 SCAN=200 ALLOC=20 POOLS=1,2 SHAPES=hash,blob DURATION=0.6 REPS=1 PASSES_PER_GEN=1 ruby refork_gate.rb`
  - Raw log: `raw_logs/refork_gate_smoke_latest.log`. The old smoke JSON was superseded; `economic_gate_results.json`
    now points to the reduced ALLOC matrix.
  - `hash`: Ractor best 84,973 items/s, PSS 12.9MB; refork iso PSS 16.4MB; saving 3.6MB -> `tradeoff_fail`.
  - `blob`: Ractor best 41,392 items/s, PSS 9.6MB; refork iso PSS 14.5MB; saving 5.0MB -> `tradeoff_fail`.
  - This is a smoke only, not the large Linux economic gate.
- Docker/Linux A2.3 sync gateway:
  - `N_RULES=80000 ITEMS=300 SCAN=500 ALLOC=100 POOL=4 DURATION=1.2 CAP_EVERY=10 TIMEOUT_S=0.000001 REPS=1 ruby a2_cache_sync.rb`
  - FAIL as desired: gateway tax +36.6%, throughput vs process 57.7%, 2146 timeouts, 2138 stale replies dropped,
    `correct=false`.

## Updated adversarial verdict

Promotion eligibility is a local compatibility win, not yet a product/platform win. The Discourse write side is still
inline AR + side effects, so the real Discourse patch does **not** prove `Proposal + EffectIntent + outbox`.

Guardian should not be forced. The top-level proof now grounds the non-fit in the real predicate body, and the stale
slice confirms the structural reason: correctness depends on live mutable graph and wall clock.

Report is partial only. It can become a capsule target only if the owner materializes complete report snapshots or batch
read models before the boundary. A synchronous cache/SQL gateway inside a Ractor would violate the economic model.

Current recommendation remains **PIVOT / continue P&D only inside the narrow read-model/rules niche** until the large
Linux economic gate and a real Discourse outbox patch exist.

## Promotion write-side gap verifier

`promotion_write_side_gap.rb` reads real `lib/promotion.rb` and emits `raw_logs/promotion_write_side_gap_latest.json`.
Current result: `classification=eligibility_only`, `eligibility_capsule_present=true`, `capsule_protocol_mentions=0`,
and 16 inline write/side-effect lines. This is an explicit guard against the false claim that Discourse Promotion already
validates `Proposal + EffectIntent + outbox`.

## Raw evidence files

- `audit_output.json`
- `raw_logs/environment_proof_latest.json`
- `raw_logs/environment_proof_latest.log`
- `a2_sync_matrix_results.json`
- `a2_sync_matrix_runs/*.json`
- `economic_gate_results.json`
- `economic_gate_matrix_results.json`
- `economic_gate_struct_matrix_results.json`
- `economic_gate_large_probe.json`
- `economic_gate_struct_probe.json`
- `economic_gate_matrix_runs/alloc_0.json`
- `economic_gate_matrix_runs/alloc_100.json`
- `economic_gate_matrix_runs/alloc_500.json`
- `economic_gate_struct_matrix_runs/alloc_0.json`
- `economic_gate_struct_matrix_runs/alloc_100.json`
- `economic_gate_struct_matrix_runs/alloc_500.json`
- `raw_logs/drift_check_latest.log`
- `raw_logs/promotion_capsule_proof_latest.json`
- `raw_logs/promotion_drift_check_latest.json`
- `raw_logs/promotion_bench_latest.json`
- `raw_logs/promotion_bench_latest.log`
- `raw_logs/a2_sync_matrix_cap_*.log`
- `raw_logs/report_partial_proof_latest.json`
- `raw_logs/guardian_non_fit_proof_latest.json`
- `raw_logs/promotion_write_side_gap_latest.json`
- `raw_logs/mini_outbox_stress_reduced.json`
- `raw_logs/mini_outbox_stress_10k.json`
- `raw_logs/mini_outbox_stress_leased_reduced.json`
- `raw_logs/mini_outbox_stress_leased_10k.json`
- `raw_logs/mini_outbox_stress_zero_lease_negative.json`
- `raw_logs/slice_b_outbox_stress_leased_reduced.json`
- `raw_logs/slice_b_outbox_stress_leased_10k.json`
- `raw_logs/slice_b_outbox_stress_zero_lease_negative.json`
- `raw_logs/findings_evidence_check_latest.json`
- `raw_logs/refork_gate_smoke_latest.log`
- `raw_logs/refork_gate_large_probe_latest.log`
- `raw_logs/refork_gate_struct_probe_latest.log`
- `raw_logs/economic_gate_matrix_alloc_0.log`
- `raw_logs/economic_gate_matrix_alloc_100.log`
- `raw_logs/economic_gate_matrix_alloc_500.log`
- `raw_logs/economic_gate_struct_matrix_alloc_0.log`
- `raw_logs/economic_gate_struct_matrix_alloc_100.log`
- `raw_logs/economic_gate_struct_matrix_alloc_500.log`

---

# Phase 3 — Audit #4: economic gate harness correction

The economic harness had a material bug: `N_RULES_HASH/STRUCT/BLOB` were reported in the header/JSON but the model runs
still built datasets with global `N_RULES`. That could invalidate any per-shape conclusion. `refork_gate.rb` now uses the
per-shape `n` consistently for oracle, Ractor, no-refork, and refork models, and writes machine-readable JSON via
`JSON_OUT=...`.

## Valid large probe after fixing per-shape sizes

Command:

`N_RULES=1000000 N_RULES_HASH=800000 N_RULES_STRUCT=1500000 N_RULES_BLOB=8000000 ITEMS=500 SCAN=500 ALLOC=100 POOLS=1,2 SHAPES=hash,struct,blob DURATION=1.2 REPS=1 PASSES_PER_GEN=1 JSON_OUT=phase3_migration/economic_gate_large_probe.json ruby refork_gate.rb`

Single-ALLOC probe results:

| shape | N | status | Ractor best | Ractor PSS | refork iso PSS | PSS ratio | abs saving | reach vs refork |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| hash | 800,000 | tradeoff_fail | 27,783/s | 210.6MB | 253.7MB | 83.0% | 43.0MB | 93.3% |
| struct | 1,500,000 | survives | 24,771/s | 161.2MB | 333.2MB | 48.4% | 172.0MB | 149.4% |
| blob | 8,000,000 | tradeoff_fail | 14,591/s | 131.2MB | 137.0MB | 95.8% | 5.8MB | 98.5% |

Interpretation at this stage: shape mattered, but this was not stable enough to promote. The later multi-ALLOC matrix
supersedes this single probe for the current economic verdict.

## Focused struct confirmation

Command:

`N_RULES_STRUCT=1500000 ITEMS=500 SCAN=500 ALLOC=100 POOLS=1,2 SHAPES=struct DURATION=2.0 REPS=2 REFORK_EVERY_S=1.0 JSON_OUT=phase3_migration/economic_gate_struct_probe.json ruby refork_gate.rb`

Result: `struct` remained `survives` with 24,877 items/s, 161.8MB Ractor PSS, 277.5MB refork iso PSS, 58.3% PSS ratio,
115.6MB absolute saving, and 96.0% throughput reach. The later struct ALLOC matrix did **not** reproduce a material pass
across ALLOC values, so this result is now treated as an unstable positive probe, not a continuation gate.

## Updated economic interpretation

Continue only if the target market has real read models shaped like `Struct`/`Data` frozen object graphs that are reused
many times with small payloads **and** the result reproduces across ALLOC/REPS. If realistic production datasets are
packed blobs, columnar strings, MessagePack-like buffers, database-backed aggregates, or cache materializations, the
Ractor memory advantage largely disappears.

---

# Phase 3 — Audit #5: reduced ALLOC matrix

`economic_gate_matrix.rb` now runs named Docker/Linux matrices and aggregates JSON without executing on `require`.
The first reduced all-shape matrix used:

`ALLOCS=0,100,500 SHAPES=hash,struct,blob POOLS=1,2 DURATION=1.2 REPS=1 N_RULES_HASH=800000 N_RULES_STRUCT=1500000 N_RULES_BLOB=8000000 ruby phase3_migration/economic_gate_matrix.rb`

`economic_gate_results.json` now points to this reduced matrix, not the older single-ALLOC probe.

| ALLOC | hash | struct | blob |
|---:|---|---|---|
| 0 | kill, save -23.9MB, reach 78.9% | kill, save -69.3MB, reach 62.1% | tradeoff_fail, save 2.9MB, reach 95.4% |
| 100 | economic_no_op, save 51.1MB, reach 130.0% | economic_no_op, save 16.4MB, reach 205.2% | tradeoff_fail, save 5.6MB, reach 94.1% |
| 500 | tradeoff_fail, save 6.8MB, reach 66.8% | tradeoff_fail, save 64.2MB, reach 48.8% | tradeoff_fail, save 5.2MB, reach 88.3% |

Focused `struct` stability matrix:

`MATRIX_NAME=struct_matrix ALLOCS=0,100,500 SHAPES=struct POOLS=1,2 DURATION=2.0 REPS=2 N_RULES_STRUCT=1500000 ruby phase3_migration/economic_gate_matrix.rb`

| ALLOC | struct status | saving | PSS ratio | reach |
|---:|---|---:|---:|---:|
| 0 | kill | -68.0MB | 172.8% | 93.9% |
| 100 | tradeoff_fail | 80.8MB | 66.7% | 87.0% |
| 500 | inconclusive | 79.7MB | 67.0% | 69.8% |

Economic interpretation after matrix: current evidence does **not** justify CONTINUE as a platform/runtime bet. `blob`
is consistently dead. `hash` does not clear material savings. `struct` has a memory-ratio signal under allocation, but
misses the 100MB absolute gate in the stability matrix and becomes throughput-inconclusive at ALLOC=500. This pushes the
project toward **PIVOT** unless a larger host-Linux run with more memory, REPS, and tuned dataset sizes reproduces a
material `struct` win.

---

# Phase 3 — Audit #6: A2.3 sync gateway 3D matrix (SCAN × ALLOC × CAP_EVERY)

`a2_cache_sync.rb` supports `JSON_OUT=...`, and `a2_sync_matrix.rb` now runs the **real 3D matrix** the README named —
the A2.3 axis is `gateway_calls / compute_ms`, a function of read frequency (`CAP_EVERY`) AND compute weight (`SCAN`) AND
allocation pressure (`ALLOC`). The earlier `CAP_EVERY×TIMEOUT` slice with `SCAN`/`ALLOC` fixed did not cover that axis; it
is superseded by this 72-cell sweep (the fixed-SCAN/ALLOC slice is the `SCAN=500,ALLOC=100` plane of it).

Command:

`SCANS=100,500,1500 ALLOCS=0,100,500 CAP_EVERYS=1,10,100,1000 TIMEOUTS=1.0,0.000001 REPS=2 DURATION=1.0 N_RULES=80000 ITEMS=300 POOL=4 ruby phase3_migration/a2_sync_matrix.rb`

Result (`a2_sync_matrix_results.json` aggregate): **72 cells — 12 pass, 53 fail, 7 inconclusive.** `all_cells_fail=false`,
`any_cell_passes=true`. The aggressive-timeout (`1e-6`) negative control fires a timeout and **FAILS all 36 cells**.

Boundary (the 12 tolerable cells — all at representative `TIMEOUT_S=1.0`):

| SCAN (compute) | tolerable CAP_EVERY (reads ≤ 1 per N items) | ALLOC |
|---:|---|---|
| 100 | 100, 1000 | 0 |
| 500 | 100, 1000 | 0, 100 |
| 1500 | 10, 100, 1000 | 0, 100 |

Chatty sync (`CAP_EVERY=1`, read every item) **fails at every SCAN/ALLOC** (gateway tax 32–92%, throughput 8–59% of the
process pool). Heavy compute (`SCAN=1500`) widens the tolerable zone down to `CAP_EVERY=10`; heavy allocation
(`ALLOC=500`) is intolerable at every frequency (the shared GC across Ractors under heavy churn — consistent with the
economic gate's struct finding). Some low-timeout rows show `correct=true` with nonzero timeouts because the first-pass
checksum can't see every read; the verdict still fails because any timeout/stale reply is a missing dependency.

Interpretation: A2.3 is a hard constraint, **measured across the real axis** — not "always a killer" and not "free". The
prior canon guidance ("batch sync deps to ≤~1 per 100 items") is now MEASURED: a synchronous capability inside a capsule
is tolerable only when it is **rare** (≈1 read per ≥100 items; ≥10 if compute is heavy) AND allocation is not heavy;
otherwise it must be owner-side pre-resolved, batched, or forbidden. This does not change the PIVOT verdict — it is a
constraint on capsule shape, not an economic win.

---

# Phase 3 — Audit #7: outbox dispatcher amplification

The booted Rails mini-app now has an append-only `delivery_attempts` table plus stress scripts:

- `rails_capsule_mini_app/db/migrate/20260613000005_create_delivery_attempts.rb`
- `rails_capsule_mini_app/app/models/delivery_attempt.rb`
- `rails_capsule_mini_app/script/worker_stress_dispatch.rb`
- `rails_capsule_mini_app/script/stress_dispatch.rb`

Purpose: distinguish final idempotent effects from raw external delivery attempts. The existing outbox pattern is
logically sound at the effect ledger (`external_charges` has one row per idempotency key), but the dispatcher releases
the SQL lock before delivery and publish-mark. Under concurrency, multiple workers can deliver the same unpublished row
before one marks it published. The idempotent consumer dedups the final effect, but every duplicate attempt is still a
real external call.

Reduced validation:

`RAILS_ENV=test N=200 WORKERS=4 BATCHES=1,5 RUNS=1 JITTER_MS=1 JSON_OUT=../phase3_migration/raw_logs/mini_outbox_stress_reduced.json bundle exec ruby script/stress_dispatch.rb`

| batch | effects | attempts | duplicate attempts |
|---:|---:|---:|---:|
| 1 | 200 | 381 | 181 (+90.50%) |
| 5 | 200 | 488 | 288 (+144.00%) |

10k validation:

`RAILS_ENV=test N=10000 WORKERS=16 BATCHES=1,5,10 RUNS=1 JITTER_MS=1 JSON_OUT=../phase3_migration/raw_logs/mini_outbox_stress_10k.json bundle exec ruby script/stress_dispatch.rb`

| batch | effects | attempts | duplicate attempts | elapsed |
|---:|---:|---:|---:|---:|
| 1 | 10,000 | 29,696 | 19,696 (+196.96%) | 81.94s |
| 5 | 10,000 | 48,194 | 38,194 (+381.94%) | 101.36s |
| 10 | 10,000 | 58,748 | 48,748 (+487.48%) | 99.05s |

All runs ended with `unpublished=0`, `external_charges=distinct=effects`, and `duplicate_effect_keys=0`. So the
transactional/idempotency soundness claim still holds. The operational claim is weaker: this dispatcher shape can amplify
external calls by 2.0x-5.9x under concurrency and jitter. If the external effect is payment, email, webhook, API quota, or
anything with real cost/rate-limit, this is not production-ready.

Updated dispatcher verdict: outbox is sound as an at-least-once + idempotent protocol, but the current no-lease dispatcher
is economically unsafe under concurrency. A production version needs a claim lease (`claimed_at/locked_until/attempt_count`
or equivalent), bounded retry/backoff, and a separate crash-recovery test proving that lease expiry reprocesses stuck rows
without duplicate amplification beyond an explicit budget.

---

# Phase 3 — Audit #8: leased outbox dispatcher correction

The booted Rails mini-app dispatcher now claims rows by writing a time-bounded lease before external delivery:

- migration `20260613000006_add_lease_to_outbox_events.rb`: `claimed_at`, `locked_until`, `attempt_count`, plus a partial
  index on unpublished leased rows.
- `Capsule::OutboxDispatcher.claim`: `FOR UPDATE SKIP LOCKED` + `locked_until` lease written inside the claim transaction.
- claim and publish-mark use database time (`SELECT CURRENT_TIMESTAMP`) instead of app `Time.now`, avoiding a
  cross-host clock-skew trap in a production Rails deployment.
- `run_once` and stress/crash workers use the dispatcher's `mark_published` path, so test scripts no longer duplicate the
  publish protocol.
- `stress_dispatch.rb` now gates raw delivery amplification explicitly: default `MAX_DUP_ATTEMPT_PERCENT=0`, so
  `STRESS OK` no longer means only "final effects were deduped".
- crash tests now prove two distinct windows:
  - crash after claim before delivery: no effect occurs, immediate reclaim is blocked by lease, recovery after expiry works.
  - crash after delivery before publish mark: effect lands once, immediate reclaim is blocked by lease, recovery after
    expiry re-delivers and idempotency collapses it to one effect.

Verification:

- `ruby -c` over capsule service, dispatcher/crash/stress scripts, test file, and migration: PASS.
- `RAILS_ENV=test bundle exec rails db:prepare`: migration applied; schema version `2026_06_13_000006`.
- `RAILS_ENV=test bundle exec ruby test/capsule_rails_test.rb`: `20 runs, 109 assertions, 0 failures`.
- `RAILS_ENV=test bundle exec rails zeitwerk:check`: PASS.
- `RAILS_ENV=test bundle exec rails test`: `20 runs, 109 assertions, 0 failures`.
- leased stress JSONs regenerated with `max_allowed_duplicate_attempt_percent=0.0`; `all_ok=true` now includes the
  duplicate-attempt budget.
- negative control with `LEASE_SECONDS=0 MAX_DUP_ATTEMPT_PERCENT=0` exits nonzero: `100` effects, `281` attempts,
  `181` duplicate attempts (`+181.00%`), `STRESS FAIL`.

Reduced leased stress:

`RAILS_ENV=test N=200 WORKERS=4 BATCHES=1,5 RUNS=1 JITTER_MS=1 LEASE_SECONDS=30 JSON_OUT=../phase3_migration/raw_logs/mini_outbox_stress_leased_reduced.json bundle exec ruby script/stress_dispatch.rb`

| batch | effects | attempts | duplicate attempts | elapsed |
|---:|---:|---:|---:|---:|
| 1 | 200 | 200 | 0 (+0.00%) | 2.82s |
| 5 | 200 | 200 | 0 (+0.00%) | 2.76s |

10k leased stress:

`RAILS_ENV=test N=10000 WORKERS=16 BATCHES=1,5,10 RUNS=1 JITTER_MS=1 LEASE_SECONDS=30 JSON_OUT=../phase3_migration/raw_logs/mini_outbox_stress_leased_10k.json bundle exec ruby script/stress_dispatch.rb`

| batch | effects | attempts | duplicate attempts | elapsed |
|---:|---:|---:|---:|---:|
| 1 | 10,000 | 10,000 | 0 (+0.00%) | 38.22s |
| 5 | 10,000 | 10,000 | 0 (+0.00%) | 29.36s |
| 10 | 10,000 | 10,000 | 0 (+0.00%) | 33.13s |

Delta against the no-lease dispatcher:

| batch | old duplicate attempts | leased duplicate attempts | old elapsed | leased elapsed |
|---:|---:|---:|---:|---:|
| 1 | +196.96% | +0.00% | 81.94s | 38.22s |
| 5 | +381.94% | +0.00% | 101.36s | 29.36s |
| 10 | +487.48% | +0.00% | 99.05s | 33.13s |

Interpretation: this fixes the operational false-pass from Audit #7 for the measured workload. The protocol remains
at-least-once, not exactly-once; the correctness layer is still the external idempotency key. The lease eliminates
duplicate-attempt amplification only while `lease_seconds` comfortably exceeds the delivery p99. A production dispatcher
still needs explicit retry/backoff/dead-letter policy, lease renewal or conservative lease sizing for slow effects, and
monitoring on `attempt_count`, expired leases, and old unpublished rows.

---

# Phase 3 — Audit #9: standalone Slice B outbox parity

The older `rails_capsule_slice_b` ActiveRecord slice still had the pre-lease dispatcher shape after the booted Rails
mini-app was fixed. That was a dangerous artifact: future reviews could cite the standalone slice as green while it still
accepted duplicate external attempts hidden by idempotency.

Correction:

- `rails_capsule_slice_b/schema.rb` now includes `claimed_at`, `locked_until`, `attempt_count`, and a partial
  `idx_outbox_unpublished_lease` index.
- `rails_capsule_slice_b/capsule.rb` now uses the same leased claim pattern as the Rails mini-app:
  `FOR UPDATE SKIP LOCKED`, `locked_until`, `attempt_count`, database time, and centralized `mark_published`.
- `worker_dispatch.rb`, `worker_crash.rb`, `worker_crash_markfirst.rb`, and `worker_stress.rb` route through the
  dispatcher instead of duplicating claim/publish SQL.
- `stress_run.rb` now always records delivery attempts, defaults `MAX_DUP_ATTEMPT_PERCENT=0`, supports `JSON_OUT`, and
  fails if raw attempt amplification exceeds budget.
- Crash-window tests now assert immediate recovery does **not** reclaim a leased row; recovery only proceeds after lease
  expiry.

Verification:

- syntax over changed standalone files: PASS.
- full standalone test suite against real Postgres `capsule_test`: `29 runs, 143 assertions, 0 failures`.
- reduced leased stress:
  - `N=200 WORKERS=4 BATCHES=1,5 RUNS=1 JITTER_MS=1 LEASE_SECONDS=30 MAX_DUP_ATTEMPT_PERCENT=0`
  - batch 1: `200` effects, `200` attempts, `0 (+0.0%)` duplicate attempts, `1.82s`.
  - batch 5: `200` effects, `200` attempts, `0 (+0.0%)` duplicate attempts, `1.51s`.
- 10k leased stress:
  - `N=10000 WORKERS=16 BATCHES=1,5,10 RUNS=1 JITTER_MS=1 LEASE_SECONDS=30 MAX_DUP_ATTEMPT_PERCENT=0`
  - batch 1: `10,000` effects, `10,000` attempts, `0 (+0.0%)`, `28.39s`.
  - batch 5: `10,000` effects, `10,000` attempts, `0 (+0.0%)`, `23.04s`.
  - batch 10: `10,000` effects, `10,000` attempts, `0 (+0.0%)`, `20.36s`.
- negative control:
  - `N=100 WORKERS=8 BATCHES=5 RUNS=1 JITTER_MS=10 LEASE_SECONDS=0 MAX_DUP_ATTEMPT_PERCENT=0`
  - exits nonzero: `100` effects, `249` attempts, `149` duplicate attempts (`+149.0%`), `STRESS FAIL`.

Interpretation: the old standalone Slice B no longer contradicts the booted Rails mini-app. Both now enforce the same
operational claim: final idempotent effects are not enough; raw delivery attempts are part of the gate. This still does
not promote the outbox to exactly-once. It only removes a false-PASS and reduces duplicate attempt amplification when the
lease is sized above delivery p99.

---

# Phase 3 — Audit #10: findings evidence drift guard

The project had accumulated enough JSON/log artifacts that the next likely failure mode was no longer only a bad
benchmark; it was a stale manual interpretation in `FINDINGS.md`. `phase3_migration/verify_findings_evidence.rb` now
acts as a small auditor for the audit record itself.

What it verifies:

- `economic_gate_results.json` is byte-identical to `economic_gate_matrix_results.json`, so the canonical economic
  pointer cannot silently drift from the reduced ALLOC matrix.
- all-shape economic matrix still has no surviving allocs:
  - `hash`: `0=kill`, `100=economic_no_op`, `500=tradeoff_fail`
  - `struct`: `0=kill`, `100=economic_no_op`, `500=tradeoff_fail`
  - `blob`: `0/100/500=tradeoff_fail`
- focused struct stability matrix still has `0=kill`, `100=tradeoff_fail`, `500=inconclusive`, no surviving allocs, and
  max absolute saving below the `100MB` gate.
- A2 sync gateway 3D matrix has 53/72 fail, 12 tolerable, 7 inconclusive; chatty `CAP_EVERY=1` fails at every SCAN/ALLOC;
  the aggressive-timeout negative control fails all 36 cells; tolerable cells are infrequent reads (`CAP_EVERY≥100`, or `≥10`
  under heavy compute) at `ALLOC≤100`.
- leased outbox stress JSONs for both the Rails mini-app and standalone Slice B still pass with `0.0%` duplicate attempts.
- lease-zero negative controls still fail with positive duplicate attempts.
- old no-lease mini-app stress JSONs are still classified as unsafe evidence: `all_ok=true` for final dedup, but positive
  duplicate attempts.
- Discourse migration artifacts are checked at a summary level: Promotion eligibility proof, Promotion drift log,
  Guardian non-fit proof, Report partial proof, and Promotion write-side gap.
- `FINDINGS.md` still mentions the Slice B outbox parity artifacts.

Verification command:

`JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Result:

- `FINDINGS EVIDENCE CHECK PASS`
- economic gate: PASS
- A2 sync gateway: PASS
- outbox attempt budget: PASS
- Discourse migration artifacts: PASS
- findings mentions: PASS

Interpretation: this does not create new performance evidence. It prevents a worse mistake: continuing discussion from a
manual report that no longer matches the machine-readable artifacts. Future runs that change economic/A2/outbox JSONs must
either update the report or fail this verifier.

---

# Phase 3 — Audit #11: Promotion proof false-PASS cleanup

`phase3_migration/promotion_capsule/proof.rb` previously printed `ractor decisions ran off main Ractor: yes`, but the
boolean behind that line was initialized to true and never updated from inside the Ractor. The proof still executed
`Ractor.new(...).value`, but the specific off-main claim was not itself measured. That is a small but real false-PASS
pattern.

Correction:

- each fixture now returns `[decision, Ractor.current != Ractor.main]` from inside the worker Ractor.
- the proof fails unless every fixture reports `ractor_off_main=true`.
- the proof now emits `JSON_OUT`, recorded as `raw_logs/promotion_capsule_proof_latest.json`.
- wording changed from `numeric fields` to `primitive fields`, because `manual_locked` is boolean.
- `verify_findings_evidence.rb` now validates:
  - Promotion proof JSON: `status=pass`, `fixture_count=8`, `ractor_off_main=true`, `snapshot_shareable=true`,
    `payload_fields=21`, no forbidden global leaks, and `mismatch_count=0`.
  - Promotion drift log: 2 semantic matches and 4 mutation controls red.
  - Guardian non-fit JSON: `Guardian#can_edit_post?`, 3 stale mutations, live-read evidence present.
  - Report partial JSON: classification remains `partial`, with sync cache/live query evidence.
  - Promotion write-side gap JSON: classification remains `eligibility_only`, side effects remain inline, and no
    `Proposal`/`EffectIntent`/outbox protocol exists in the real Discourse patch.

Verification commands:

- `JSON_OUT=phase3_migration/raw_logs/promotion_capsule_proof_latest.json ruby phase3_migration/promotion_capsule/proof.rb`
- `ruby phase3_migration/promotion_capsule/drift_check.rb > phase3_migration/raw_logs/drift_check_latest.log`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Results:

- Promotion proof: `PROOF OK`, `8` fixtures, `ractor_off_main=true`, `mismatch_count=0`, `payload_fields=21`,
  `payload_bytes=537`.
- Drift check: `DRIFT CHECK OK`, 2 semantic matches, 4 mutation controls red.
- Findings evidence check: PASS including `discourse_migration_artifacts`.

Interpretation: this does not make the Discourse write side migrated. It only makes the Promotion eligibility claim
less hand-wavy: the off-main Ractor claim, shareability, no-global static check, and equivalence fixtures are now
machine-readable and guarded against report drift.

---

# Phase 3 — Audit #12: Discourse evidence freshness guard

The evidence verifier now checks not only that Discourse-related artifacts have the right shape, but that they are fresh
against the current source they claim to describe. This matters because `phase3_migration/discourse/lib/promotion.rb` is
intentionally dirty with the Promotion eligibility patch; a `commit` field alone cannot prove the write-side gap JSON was
generated from the current working tree.

Correction:

- `guardian_non_fit_proof.rb`, `report_partial_proof.rb`, and `promotion_write_side_gap.rb` now emit `source_sha256`.
- `promotion_capsule/proof.rb` emits `capsule_sha256`.
- `promotion_capsule/drift_check.rb` now emits structured JSON via `JSON_OUT`, including:
  - full `discourse_head`
  - `real_source_sha256` for `HEAD:lib/promotion.rb`
  - `capsule_sha256`
  - per-level semantic match rows
  - mutation-control results
- `verify_findings_evidence.rb` recomputes current hashes and fails if any artifact is stale:
  - Guardian proof vs current `lib/guardian/post_guardian.rb`
  - Report proof vs current `app/models/report.rb`
  - Promotion write-side gap vs current working-tree `lib/promotion.rb`
  - Promotion drift check vs `HEAD:lib/promotion.rb` and current `capsule_eligibility.rb`
  - Promotion proof vs current `capsule_eligibility.rb`

Verification commands:

- `ruby phase3_migration/guardian_non_fit_proof.rb > phase3_migration/raw_logs/guardian_non_fit_proof_latest.json`
- `ruby phase3_migration/report_partial_proof.rb > phase3_migration/raw_logs/report_partial_proof_latest.json`
- `ruby phase3_migration/promotion_write_side_gap.rb > phase3_migration/raw_logs/promotion_write_side_gap_latest.json`
- `JSON_OUT=phase3_migration/raw_logs/promotion_capsule_proof_latest.json ruby phase3_migration/promotion_capsule/proof.rb`
- `JSON_OUT=phase3_migration/raw_logs/promotion_drift_check_latest.json ruby phase3_migration/promotion_capsule/drift_check.rb > phase3_migration/raw_logs/drift_check_latest.log`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Result:

- Discourse HEAD checked: `36ee9d7cc8262ee2c90aedd4771ed0389122d227`.
- Promotion drift JSON: PASS, 2 semantic matches, 4 mutation controls detected.
- Promotion proof JSON: PASS, `ractor_off_main=true`, `mismatch_count=0`.
- Guardian/Report/write-gap JSONs: PASS and fresh against current source hashes.
- Findings evidence check: PASS including freshness checks.

Interpretation: this closes a subtle but important evidence hole. The project can no longer accidentally cite stale
Discourse JSONs after changing the source files they summarize. It still does not prove a full Discourse write-side
migration; it only makes the existing fit/non-fit/gap claims fresh and auditable.

---

# Phase 3 — Audit #13: baseline audit dirty-tree correction

`phase3_migration/audit.rb` had a more serious evidence flaw than the earlier stale-JSON issue: it reported
`generated_against_commit=36ee9d7cc8262ee2c90aedd4771ed0389122d227`, but read source from the current working tree. Since
`phase3_migration/discourse/lib/promotion.rb` is intentionally dirty with the capsule eligibility patch, the Promotion
baseline could be silently measured after migration while claiming to represent HEAD. That is a false-baseline pattern.

Correction:

- `audit.rb` now reads file contents from `git show HEAD:<path>`.
- File discovery also comes from `git ls-tree -r --name-only HEAD`, not `Dir.glob` over the working tree.
- `audit_output.json` now emits `source_ref=HEAD`, `source_mode=git_show+git_ls_tree`, and `source_sha256_by_file`.
- The broad side-effect regex was tightened. Generic `Group.`/`UserHistory.` references were false positives for
  Guardian read paths; the regex now counts specific write/effect operations such as `UserHistory.create!`,
  `Group.user_trust_level_change!`, `DiscourseEvent.trigger`, `BadgeGranter.queue_badge_grant`, AR mutation methods, and
  async delivery/enqueue calls.
- `audit.rb` is now require-safe; loading it does not execute the scan.
- `verify_findings_evidence.rb` now fails if `audit_output.json` drifts from Discourse HEAD, loses git-backed source
  mode, has stale `source_sha256_by_file` values, or changes the core Guardian/Report/Promotion metrics without updating
  the interpretation.

Corrected baseline:

- Guardian: 2267 LOC, 179 files / 668 calls, `candidate=non_fit`, 138 `SiteSetting` reads, 47 AR reads, 113 held `@user`
  refs, 224 predicates, **0 side-effect calls**.
- Report: 611 LOC, 16 files / 33 calls, `candidate=partial`, 4 cache reads, 1 Redis read, 14 AR reads, 2 DB query points,
  **0 side-effect calls**.
- Promotion: 176 LOC, 7 files / 8 calls, `candidate=partial`, 12 `SiteSetting` reads, 2 AR reads, 29 held `@user` refs,
  **7 side-effect calls**.

Verification commands:

- `ruby -c phase3_migration/audit.rb`
- `ruby -e 'require_relative "phase3_migration/audit"; puts "required"'`
- `ruby phase3_migration/audit.rb > phase3_migration/audit_output.json`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Interpretation: this does not make the thesis stronger. It makes the measurement less self-deceptive. The corrected
Promotion baseline is still a small read-model/rules target, but the previous 4-file call-site claim was undercounted.
The main verdict remains narrow P&D / pivot pressure until a real Discourse write-side outbox patch and a large Linux
economic gate survive.

---

# Phase 3 — Audit #14: benchmark aggregate consistency guard

The reduced Linux performance artifacts had another false-PASS risk: `economic_gate_*_results.json` and
`a2_sync_matrix_results.json` were accepted mostly by their high-level statuses. A stale or manually edited aggregate could
keep the same verdict table while drifting away from the per-cell JSON files and raw logs that supposedly support it.

Correction:

- `verify_findings_evidence.rb` now re-reads every `json_file` referenced by:
  - `economic_gate_results.json`
  - `economic_gate_struct_matrix_results.json`
  - `a2_sync_matrix_results.json`
- For economic gate matrices, the verifier reconstructs each run's `shape_verdicts` from the underlying
  `refork_gate.rb` JSON, then rebuilds `by_shape` and compares it to the aggregate.
- It also checks that every economic cell uses the same shared config (`pools`, `shapes`, `n_rules_by_shape`, `items`,
  `scan`, `duration_s`, `refork_every_s`, `passes_per_gen`, `reps`) and the same economic gates, while matching the
  aggregate's per-run `ALLOC`.
- For A2.3, the verifier reconstructs each compact cell result from the underlying `a2_cache_sync.rb` JSON, then rebuilds
  the `aggregate` and `by_scan_alloc` summaries and compares them to the stored matrix.
- The A2.3 matrix is now 3D: `scan` and `alloc` VARY per cell (matched per-run against the cell config and required to lie
  within `scope.scans`/`scope.allocs`), while `n_rules`, `items`, `duration_s`, `reps`, `pool`, `cache_size` stay constant
  and match the scope. The verifier also asserts the aggressive-timeout negative control fires and fails every cell.
- Every referenced `raw_log` must exist and be non-empty.

Verification commands:

- `ruby -c phase3_migration/verify_findings_evidence.rb`
- `ruby -c phase3_migration/economic_gate_matrix.rb && ruby -c phase3_migration/a2_sync_matrix.rb`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Result:

- Economic aggregate/config consistency: PASS, 3 reduced matrix runs checked plus 3 struct-stability runs checked.
- A2.3 aggregate/config consistency: PASS, 72 3D cells checked against their per-cell JSON files and raw logs.
- Findings evidence check: PASS with `economic_gate`, `a2_sync_gateway`, and all previous guards.

Interpretation: this still does not produce a final economic PASS. The current matrices remain reduced local evidence
(`REPS=1` for the broad matrix, `REPS=2` for struct stability, short durations). The improvement is narrower but important:
the report can no longer claim a benchmark aggregate that is not mechanically supported by its cell-level evidence.

---

# Phase 3 — Audit #15: transaction suite log guard

The outbox/protocol section had a weaker evidence chain than the code itself. `FINDINGS.md` cited green Rails/Slice B
test suites, but `verify_findings_evidence.rb` only checked stress JSONs and did not prove the full Minitest suites still
passed in the current tree. During this audit, a naive command shape also exposed a concrete trap: running
`ruby test/slice_b_test.rb test/falsify_*.rb` executes only the first file as the test program and treats the rest as
arguments. That produced a misleading `13 runs` result instead of the real full suite.

Correction:

- Full Slice B suite is now captured in `raw_logs/slice_b_full_test_latest.log` by requiring every `test/*_test.rb` and
  `test/falsify_*.rb` file.
- Booted Rails mini-app suite is now captured in `raw_logs/mini_rails_full_test_latest.log`.
- `verify_findings_evidence.rb` now parses both logs and fails unless:
  - Slice B reports `29 runs, 143 assertions, 0 failures, 0 errors, 0 skips`.
  - Mini Rails reports `20 runs, 109 assertions, 0 failures, 0 errors, 0 skips`.
  - Slice B log records `OBSERVED_NON_MAIN_RACTOR_EXCEPTION=Ractor::UnsafeError`, proving the Nokogiri unsafe fallback
    evidence is still present in the full-suite run.

Verification commands:

- `DATABASE_URL=postgres://capsule:capsule@127.0.0.1:65432/capsule_test bundle exec ruby -Itest -e 'Dir["test/*_test.rb", "test/falsify_*.rb"].flatten.sort.each { |file| require_relative file }'`
- `RAILS_ENV=test bundle exec ruby -Itest test/capsule_rails_test.rb`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Result:

- Slice B full suite: `29 runs, 143 assertions, 0 failures, 0 errors, 0 skips`.
- Mini Rails full suite: `20 runs, 109 assertions, 0 failures, 0 errors, 0 skips`.
- Findings evidence check: PASS including `transaction_suite_logs`.

Interpretation: this does not prove a Discourse write-side outbox migration. It does strengthen the protocol evidence:
the current tree still passes the real Postgres optimistic-lock/outbox/SKIP LOCKED/crash-window tests and the booted Rails
Ractor-boundary tests, and the report can no longer cite those suite results without current raw logs.

---

# Phase 3 — Audit #16: Promotion patch freshness guard

The Promotion migration claim depends on a concrete patch against real Discourse: `promotion_capsule/promotion.patch`.
Before this audit, the verifier checked Promotion proof/drift/write-gap artifacts, but it did not prove that the archived
patch file still matched the actual dirty `phase3_migration/discourse/lib/promotion.rb` working-tree diff. That leaves a
classic false-PASS gap: the report could keep saying `+71/-17, one file` while the applied patch had changed.

Correction:

- `verify_findings_evidence.rb` now compares `promotion_capsule/promotion.patch` byte-for-byte with
  `git -C phase3_migration/discourse diff -- lib/promotion.rb`.
- The verifier fails unless the tracked Discourse diff is limited to exactly `lib/promotion.rb`.
- The verifier fails unless `git diff --numstat -- lib/promotion.rb` remains `71 additions / 17 deletions`.
- The evidence summary now includes the Promotion patch SHA-256.

Verification commands:

- `ruby -c phase3_migration/verify_findings_evidence.rb`
- `ruby -e 'require "digest"; patch=File.read("phase3_migration/promotion_capsule/promotion.patch"); diff=\`git -C phase3_migration/discourse diff -- lib/promotion.rb\`; puts "patch_eq_diff=#{patch == diff}"; puts Digest::SHA256.hexdigest(patch); puts \`git -C phase3_migration/discourse diff --numstat -- lib/promotion.rb\`'`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Result:

- `patch_eq_diff=true`.
- Promotion patch SHA-256: `fe332d1c397982899b8cbe5c3d251b18319eabcf3ec1b044972df28d42c4beaa`.
- Numstat: `71	17	lib/promotion.rb`.
- Findings evidence check: PASS including the patch freshness guard.

Interpretation: this only proves the archived patch is the patch actually applied to the Discourse checkout. It does not
upgrade the claim to a full Discourse write-side capsule. The write side remains explicitly classified as
`eligibility_only`, with `Proposal + EffectIntent + outbox` still unimplemented in the real Discourse patch.

---

# Phase 3 — Audit #17: Promotion benchmark evidence guard

The Promotion benchmark claim had drifted into manual-report territory. `FINDINGS.md` contained two incompatible sets of
benchmark numbers for the same `promotion_capsule/bench.rb` story, and the verifier did not check either one. That is a
false-PASS risk because a performance paragraph can keep selling old numbers after the benchmark or capsule code changes.

Correction:

- `promotion_capsule/bench.rb` now supports `JSON_OUT`.
- The benchmark JSON records:
  - `capsule_sha256`
  - Ruby description
  - benchmark config (`n=1_000_000`, `per_ractor=2_000_000`, `ractors=4`)
  - throughputs for inline full, owner snapshot build + decide, decide-only, and decide-only x4 Ractors
  - ratios for owner cost vs inline and x4 pure decide vs single pure decide
  - payload fields/bytes for the benchmark mock
  - explicit interpretation flags: compatibility-only, pure decide parallelizes, owner build cost included, and
    `calc_topic_reply_count!` under-counted as a cheap mock
- `verify_findings_evidence.rb` now fails unless:
  - `raw_logs/promotion_bench_latest.json` is fresh against `capsule_eligibility.rb`.
  - the sanity check is correct.
  - benchmark config stays fixed.
  - benchmark mock payload remains 21 fields / 531 bytes.
  - owner snapshot build + decide is slower than inline (`ratio < 1.0`).
  - pure decide x4 remains faster than single decide (`ratio > 1.0`).
  - the raw log states: `Not an end-to-end win by itself.`

Current artifact:

- Inline full: ~1.76M decisions/s.
- Owner snapshot build + decide: ~479K decisions/s (`0.27x` vs inline).
- Decide-only snapshot reused: ~3.12M decisions/s.
- Decide-only x4 Ractors: ~12.87M decisions/s (`4.12x` vs single pure decide).
- Benchmark mock payload: 21 fields / 531 bytes.
- Proof fixture payload remains separately tracked at 21 fields / 537 bytes in `raw_logs/promotion_capsule_proof_latest.json`.

Verification commands:

- `ruby -c phase3_migration/promotion_capsule/bench.rb`
- `JSON_OUT=phase3_migration/raw_logs/promotion_bench_latest.json ruby phase3_migration/promotion_capsule/bench.rb > phase3_migration/raw_logs/promotion_bench_latest.log 2>&1`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Interpretation: this weakens the optimistic reading, as it should. The pure Ractor decide parallelizes, but rebuilding the
snapshot per call is materially slower than inline in this microbench, and the production owner-side cost is under-counted
because the real `calc_topic_reply_count!` residue is a live query/mutation. Promotion remains a compatibility proof and
small-surface candidate, not an end-to-end performance win.

---

# Phase 3 — Audit #18: environment proof guard

The evidence bundle previously mixed environment claims from different phases: a historical Discourse spec comparison on
Ruby 3.4.9 and the current Ruby 4.0.5/Rails 8.1.3/Postgres 16.14 artifacts. That is dangerous because performance,
Ractor behavior, and Rails boot behavior are all runtime-sensitive. A prose-only environment note is not enough.

Correction:

- Added `phase3_migration/environment_proof.rb`.
- Generated:
  - `raw_logs/environment_proof_latest.json`
  - `raw_logs/environment_proof_latest.log`
- The environment proof records raw stdout/stderr/exit status for:
  - host `ruby -v`, `bundle -v`, and `RUBY_DESCRIPTION`
  - Discourse `git rev-parse HEAD`, branch, and dirty status
  - Postgres container readiness for `capsule_test` and `capsule_railsapp_test`
  - container `psql --version` and server version
  - mini Rails `rails -v`, Rails boot probe, `eager_load=true`, cache class, DB name, and DB server version
  - Slice B ActiveRecord/Postgres probe, DB name, and DB server version
- `verify_findings_evidence.rb` now fails unless the environment proof is passing and matches the current evidence
  contract.

Current environment proof:

- Host Ruby: `ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +PRISM [arm64-darwin24]`.
- Bundler: `4.0.11`.
- Discourse HEAD: `36ee9d7cc8262ee2c90aedd4771ed0389122d227`.
- Discourse dirty status: `M lib/promotion.rb`, `?? run_migrate.rb`.
- Mini Rails: Rails `8.1.3`, ActiveRecord `8.1.3`, `eager_load=true`, `ActiveSupport::Cache::MemoryStore`,
  database `capsule_railsapp_test`.
- Slice B: ActiveRecord `8.1.3`, database `capsule_test`.
- Postgres container: `16.14`, with `capsule_test` and `capsule_railsapp_test` reachable.

Verification commands:

- `ruby -c phase3_migration/environment_proof.rb`
- `JSON_OUT=phase3_migration/raw_logs/environment_proof_latest.json ruby phase3_migration/environment_proof.rb > phase3_migration/raw_logs/environment_proof_latest.log 2>&1`
- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Interpretation: this does not make macOS memory conclusions valid for the final economic gate. It only prevents the local
evidence bundle from citing ambiguous runtimes or databases. Final memory validation still requires Linux
`/proc/<pid>/smaps_rollup`, and the current economic matrices already remain reduced local evidence rather than a final
PASS.

---

# Phase 3 — Audit #19: Linux benchmark runtime guard

The environment proof records the host Ruby and the Rails/Postgres environment, but the economic memory gates and A2.3
gateway matrix are Docker/Linux artifacts. Those per-cell JSON files already included `ruby` and `platform`, but the
verifier did not enforce them. That left a narrow but serious false-PASS gap: a matrix accidentally regenerated on the
wrong runtime or non-Linux platform could still pass aggregate/status checks if the numbers had the expected shape.

Correction:

- `verify_findings_evidence.rb` now checks every referenced economic/A2 cell JSON and fails unless:
  - `ruby` contains `ruby 4.0.5`.
  - `ruby` includes the reported platform tag.
  - `platform` ends with `linux`.
- This applies to:
  - 3 broad economic matrix cells.
  - 3 struct-stability economic matrix cells.
  - 72 A2.3 bounded-sync gateway cells (3D `SCAN×ALLOC×CAP_EVERY` matrix; was 15 before the upgrade).

Current result:

- Economic runtime cells checked: 6.
- A2.3 runtime cells checked: 72.
- All current cells report `ruby 4.0.5 ... [aarch64-linux]` and `platform=aarch64-linux`.

Verification command:

- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Interpretation: this is still not the final large Linux economic gate; it only prevents reduced benchmark artifacts from
being accepted if they are not actually Linux/Ruby 4.0.5 runs. The economic conclusion remains bearish and provisional:
Ractor has not survived the stronger process/refork gate in the current reduced evidence.

---

# Phase 3 — Audit #20: current verdict guard

The report had become chronologically accurate but adversarially fragile: older sections still contain single-probe
`struct survives` rows and local wins that are later superseded by broader matrices. A reader could quote an old probe and
ignore the current evidence state. That is a report-level false-PASS, not a code bug.

Correction:

- Added a `# Current evidence verdict` section at the top of `FINDINGS.md`.
- `verify_findings_evidence.rb` now requires that heading.
- `verify_findings_evidence.rb` now emits `current_project_verdict` in
  `raw_logs/findings_evidence_check_latest.json`, derived from checked artifacts rather than prose.

Current derived verdict:

- `status=pivot`.
- Promotion scope: `eligibility_only`.
- Guardian: structural non-fit.
- Report: partial.
- Economic final gate: not passed.
- A2 sync gateway: all current cells fail.
- Full Discourse write-side outbox: not validated.
- Advance to gem/DSL/product: false.

Verification command:

- `JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb`

Interpretation: this intentionally prevents optimistic cherry-picking. The current project state is a narrow
compatibility/protocol research result under pivot pressure, not a validated Rails/Ractor platform.

---

# Phase 3 — Audit #21: Discourse spec comparison evidence gap guard

The Promotion section still contained an over-strong historical claim: a previous `spec/lib/promotion_spec.rb` before/after
run had identical output (`29 examples, 3 failures` before and after), and the failures were attributed to a missing
JS/node_modules environment dependency rather than the migration. That observation may be true, but it is not current
machine-guarded evidence in this repository because no raw before/after Discourse spec logs are present in `raw_logs`, and
the verifier does not replay Discourse RSpec.

Correction:

- The spec comparison is now explicitly labeled historical context, not current evidence.
- `verify_findings_evidence.rb` now requires the caveat that the current guarded Promotion evidence is
  proof/drift/patch/benchmark/write-gap.
- `verify_findings_evidence.rb` now fails if `FINDINGS.md` reintroduces the old strong behavior-neutrality phrases as
  current evidence.

Current interpretation: the Promotion patch remains a useful eligibility compatibility proof, but the current evidence
bundle must not sell Discourse RSpec behavior-neutrality unless the project adds reproducible raw before/after logs or a
machine replay step. This keeps the verdict conservative: `eligibility_only`, no Discourse write-side outbox, and no
product/platform continuation gate.

---

# Phase 3 — Audit #22: local Promotion pass vs project gate guard

The Promotion gate wording still had a project-level ambiguity: "no kill conditions" could be read as if the project had
cleared the continuation gates. That is false under the current evidence. Promotion eligibility clears a local
compatibility slice only; the project-level gates remain failing or unproven.

Correction:

- The Promotion section now says `Promotion eligibility compatibility only; project gates remain failing`.
- The old broad kill-condition wording was replaced with the narrower claim: `Local Promotion-eligibility migration
  blockers are not hit`.
- The same paragraph now states why this does not authorize continuation as product/runtime/platform: write side remains
  inline, owner snapshot+decide is slower than inline in the current benchmark, all A2 sync-gateway cells fail, and the
  economic matrices have no surviving allocs.
- `verify_findings_evidence.rb` now requires the local-vs-project caveat and fails if the old broad kill-condition phrase
  is reintroduced.

Current interpretation: Promotion is a useful specimen for compatibility mechanics, not evidence that Ractorized Rails
Kernel should continue as a Rails runtime/platform. The decision remains `PIVOT` unless a real Discourse write-side outbox
patch and a stronger Linux economic gate change the machine-checked verdict.

---

# Phase 3 — Audit #23: legacy positive economic probe guard

The economic history still contains two positive `struct survives` probes:

- `economic_gate_large_probe.json`: `struct` saved 172.0MB and reached 149.4% throughput in one ALLOC=100 probe.
- `economic_gate_struct_probe.json`: `struct` saved 115.6MB and reached 96.0% throughput in a focused confirmation.

Those probes are useful context for where the hypothesis could still be alive, but they are not current continuation
evidence. The current economic verdict is fed by the multi-ALLOC matrices, and those are bearish:

- `economic_gate_results.json`: `hash`, `struct`, and `blob` all have `survives_allocs=[]`.
- `economic_gate_struct_matrix_results.json`: focused `struct` has `survives_allocs=[]` and max saving below the 100MB gate.

Correction:

- Legacy positive economic probes are context only, not continuation evidence.
- Only `economic_gate_results.json`, `economic_gate_struct_matrix_results.json`, and the calibrated struct rerun artifacts
  feed the current economic interpretation.
- `verify_findings_evidence.rb` now reads the legacy probe JSONs, records their positive `struct` rows, and still requires
  the current matrices to have no surviving allocs.

Current interpretation: the old `struct survives` rows identify a narrow shape worth retesting on a stronger Linux host,
but they do not authorize continuing as a product/runtime/platform. Any future `CONTINUE` claim must come from a matrix or
host-Linux gate that survives across allocation levels and throughput-equivalent process/refork baselines.

---

# Phase 3 — Audit #24: top-level verdict prose guard

The evidence verifier derived `current_project_verdict=pivot`, but it previously did not validate that the first section of
`FINDINGS.md` still told the same story. That left a report-level false-PASS: someone could edit the top prose toward
`CONTINUE` while keeping enough required mentions elsewhere for the evidence check to pass.

Correction:

- `verify_findings_evidence.rb` now has a dedicated `findings_current_verdict_text` check.
- The check fails unless the top `# Current evidence verdict` section states the bearish claims that matter:
  `PIVOT / continue only as narrow P&D`, `eligibility_only`, no surviving economic allocs, the A2 3D 72-cell matrix
  with chatty bounded-sync (`CAP_EVERY=1`) failing at every `SCAN`/`ALLOC` (`a2_all_cells_fail=false`, 12/72 tolerable),
  owner snapshot+decide slower than inline, and no advance to gem/DSL/product.
- The check also rejects forbidden top-level verdict claims such as `CONTINUE`, `economic_final_gate_passed=true`,
  `advance_to_gem_or_dsl=true`, or `full_discourse_write_side_outbox_validated=true`.

Current interpretation: the machine-derived verdict and the first thing a reader sees in the report are now tied together.
If future evidence improves, both the JSON-derived verdict and the top prose must be deliberately reinterpreted in the same
change.

---

# Phase 3 — Audit #25: Minitest log summary guard

The transaction soundness evidence depends on raw Minitest logs:

- `raw_logs/slice_b_full_test_latest.log`
- `raw_logs/mini_rails_full_test_latest.log`

The verifier previously used the first `N runs, N assertions, ...` match in each file. That is too permissive for evidence
logs: a concatenated log with an old passing run followed by a newer failing run could be misread as a PASS if the old
summary appeared first.

Correction:

- `verify_findings_evidence.rb` now requires that each transaction-suite raw log has exactly one Minitest summary.
- The verifier also requires exactly one `Finished in ...` line for each log.
- The evidence JSON now records `summary_counts` for Slice B and the mini Rails app.

Current interpretation: the full-suite transaction claims are still only as strong as the captured logs, but the logs can no
longer pass as stale/concatenated artifacts. A new failure must replace the raw log and will change the single final
summary that the verifier reads.

---

# Phase 3 — Audit #26: outbox stress workload guard

The outbox stress artifacts were checked for `all_ok` and duplicate-attempt percentage, but not for the workload that made
the result meaningful. That left a false-PASS path: a tiny stress run could keep `all_ok=true` and `0.0%` duplicate
attempts while replacing the intended 10k/16-worker evidence.

Correction:

- `verify_findings_evidence.rb` now requires that outbox stress artifacts must preserve their workload size, worker count, batches, and lease settings.
- The leased positive stress artifacts must still include:
  - reduced: `n=200`, `workers=4`, `batches=[1,5]`, `lease_seconds=30.0`.
  - 10k: `n=10000`, `workers=16`, `batches=[1,5,10]`, `lease_seconds=30.0`.
- The zero-lease negative controls must still use `n=100`, `workers=8`, `batches=[5]`, `lease_seconds=0.0`, and per-run
  `ok=false`.
- The old unsafe dispatcher artifacts must still be the reduced/10k workloads without lease fields and with positive
  duplicate attempts.
- For every run, the verifier now checks worker exit codes, unpublished rows, final charges, distinct charges, duplicate
  effect keys, and per-run `ok`.

Current interpretation: the outbox stress evidence is still not a full Discourse write-side proof, but it can no longer be
silently weakened from a 10k/16-worker stress artifact into a trivial smoke run.

---

# Phase 3 — Audit #27: outbox old-unsafe scope guard

The outbox evidence has asymmetric historical controls:

- Positive leased stress coverage exists for both the booted Rails mini-app and standalone Slice B.
- Zero-lease negative controls exist for both the booted Rails mini-app and standalone Slice B.
- old unsafe no-lease dispatcher controls are mini Rails only: `mini_outbox_stress_reduced.json` and
  `mini_outbox_stress_10k.json`.

That last point matters. The standalone Slice B pre-lease dispatcher was fixed in place rather than preserved as a separate
old-unsafe artifact. So the report must not imply that old unsafe no-lease dispatcher controls exist for both
implementations.

Correction:

- `verify_findings_evidence.rb` now records `old_unsafe_scope=mini_rails_only`.
- `verify_findings_evidence.rb` records `slice_b_old_unsafe_preserved=false`.
- `FINDINGS.md` now states the asymmetry explicitly.

Current interpretation: the outbox parity claim remains about the leased positive path and zero-lease negative controls in
both implementations. The old no-lease duplicate-amplification baseline is preserved only for the Rails mini-app.

---

# Phase 3 — Audit #28: Promotion proof payload byte guard

The report cited the Promotion proof payload as `21 primitive fields, 537 bytes`, but the verifier only guarded the field
count. That left a boundary-cost false-PASS: the proof payload could grow in bytes while preserving the same number of
fields, and the evidence check would still pass even though copy-tax economics depend on payload size, not just field
count.

Correction:

- Promotion proof payload bytes are now machine-guarded at 537.
- `verify_findings_evidence.rb` now fails if `raw_logs/promotion_capsule_proof_latest.json` changes `payload_bytes`.
- The Discourse migration artifact summary now emits `promotion_proof_payload={fields: 21, bytes: 537}`.

Current interpretation: Promotion still has a small boundary payload in the current proof artifact, but that claim is now
guarded against silent payload growth.

---

# Phase 3 — Audit #29: outbox duplicate-attempt budget guard

The outbox stress verifier checked observed duplicate attempts and workload size, but it still did not guard the configured
duplicate-attempt budget. That left a false-PASS path: a stress artifact could be regenerated with a relaxed
`MAX_DUP_ATTEMPT_PERCENT` while still preserving the same workload shape.

Correction:

- leased and zero-lease outbox stress artifacts must keep max_allowed_duplicate_attempt_percent=0.0.
- `verify_findings_evidence.rb` checks this budget at the top level and inside every run row.
- The old unsafe no-lease artifacts are expected to omit the budget field because they predate the budgeted stress runner;
  those remain mini Rails-only historical controls with positive duplicate attempts.

Current interpretation: leased outbox stress remains a zero-duplicate-attempt budget, not a tolerated-duplicate benchmark.
The zero-lease controls must continue to fail under the same zero budget.

---

# Phase 3 — Audit #30: Promotion write-side gap count guard

The report said `promotion_write_side_gap_latest.json` found 16 inline write/side-effect lines, but the verifier only
required that the array was non-empty. That was too weak for the `eligibility_only` conclusion: a drifted artifact with one
remaining side effect would still pass while the report kept citing the stronger 16-line write-side residue.

Correction:

- Promotion write-side gap count is now machine-guarded at 16 inline write/side-effect lines.
- `verify_findings_evidence.rb` now also checks for key write/side-effect tokens in the extracted source:
  `change_trust_level!`, welcome/promotion message enqueueing, `UserHistory.create!`, `save!`, `recook_bio`,
  `DiscourseEvent.trigger`, `Group.user_trust_level_change!`, `BadgeGranter.queue_badge_grant`, and `update_column`.
- The evidence JSON now emits `promotion_write_side_gap.inline_write_side_effect_count=16`.

Current interpretation: the Discourse patch remains `eligibility_only`. The real write side is still inline AR +
side effects; `Proposal + EffectIntent + outbox` is not implemented in Discourse.

---

# Phase 3 — Audit #31: Promotion write-side conclusion guard

The write-side gap artifact already carried the key conclusion:

`Promotion patch validates eligibility extraction only; Proposal + EffectIntent + outbox are not implemented in real Discourse.`

But the verifier only guarded the classification, protocol-token absence, and inline side-effect evidence. It did not guard
the artifact's explicit conclusion text. That left a small report-level drift path: the JSON conclusion could soften while
the report still relied on the hard `eligibility_only` reading.

Correction:

- Promotion write-side gap conclusion is now machine-guarded.
- `verify_findings_evidence.rb` now fails unless the conclusion remains exactly the hard claim above.
- The evidence JSON now emits `promotion_write_side_gap.conclusion_guarded=true`.

Current interpretation: the real Discourse patch is still only an eligibility extraction. It does not implement
`Proposal + EffectIntent + outbox`, and the verifier now guards that conclusion directly.

---

# Phase 3 — Audit #32: Promotion benchmark Ruby runtime guard

The Promotion benchmark JSON records the Ruby runtime, but the verifier was not checking it. That left a performance
evidence drift path: the benchmark could be regenerated under a different Ruby while preserving config, payload, and
ratios with the same rough shape.

Correction:

- Promotion benchmark Ruby runtime is now machine-guarded as Ruby 4.0.5.
- `verify_findings_evidence.rb` now fails unless `raw_logs/promotion_bench_latest.json` reports Ruby 4.0.5.
- The evidence JSON now emits the benchmark `ruby` string in the `promotion_benchmark` check.

Current interpretation: this does not make the Promotion benchmark a Linux memory gate. It only prevents mixing Ruby
runtimes for the compatibility/per-call benchmark that supports the "not an end-to-end win" conclusion.

---

# Phase 3 — Audit #33: Promotion proof Ruby runtime guard

The Promotion proof is the artifact that claims non-main Ractor execution, shareable snapshot, no forbidden globals, and
fixture equivalence. Unlike the benchmark, it did not record the Ruby runtime. That is a runtime-sensitive false-PASS risk:
Ractor behavior and shareability semantics can change across Ruby versions.

Correction:

- `promotion_capsule/proof.rb` now writes `ruby: RUBY_DESCRIPTION` into `raw_logs/promotion_capsule_proof_latest.json`.
- Promotion proof Ruby runtime is now machine-guarded as Ruby 4.0.5.
- `verify_findings_evidence.rb` now fails unless the proof artifact reports Ruby 4.0.5.
- The evidence JSON now emits `promotion_proof_ruby` in the Discourse migration artifact check.

Current interpretation: the Promotion compatibility proof is tied to the current Ruby 4.0.5 runtime. It remains a
compatibility proof only, not an end-to-end product/platform gate.

---

# Phase 3 — Audit #34: Promotion benchmark log/JSON consistency guard

The Promotion benchmark now has two evidence surfaces: `raw_logs/promotion_bench_latest.json` and
`raw_logs/promotion_bench_latest.log`. The verifier guarded the JSON and only checked that the log contained the
end-to-end caveat. That was still too permissive: a stale or manually edited log could keep reporting different
throughput numbers while the JSON passed, and `FINDINGS.md` cites both artifacts.

Correction:

- Promotion benchmark raw log is now machine-checked against `promotion_bench_latest.json`.
- `verify_findings_evidence.rb` parses the four printed throughput lines and requires them to match the rounded JSON
  values.
- The displayed owner-cost and x4-Ractor ratios must match the JSON ratios rounded to two decimals.
- The log payload line must match the JSON payload fields/bytes.
- The evidence JSON now emits `promotion_benchmark.log_matches_json=true`.

Current interpretation: this does not strengthen the benchmark into a continuation gate. It only prevents the current
compatibility/per-call performance paragraph from mixing stale textual output with a newer machine-readable artifact.

---

# Phase 3 — Audit #35: Promotion proof fixture identity guard

The Promotion proof JSON exposed `fixture_count=8` and `mismatch_count=0`, but not the identities or expected decisions of
the fixtures. That was too weak for the report claim that the proof includes the exact tl1-promotion, account-too-young
age-gate, tl2-promotion, and residue-field cases. Eight trivial or duplicate fixtures could still pass the old verifier.

Correction:

- `promotion_capsule/proof.rb` now writes `fixture_results` with fixture name, reference decision, capsule decision,
  per-fixture non-main Ractor status, and per-fixture shareability.
- Promotion proof fixture names and expected decisions are now machine-guarded.
- `verify_findings_evidence.rb` fails unless the exact eight adversarial fixtures and their expected decisions remain
  present.
- The verifier also requires every named fixture to run in a non-main Ractor over a shareable snapshot, not merely the
  aggregate booleans.

Current interpretation: the proof remains narrow, but the report can now honestly claim those specific Promotion edge
cases are covered by the current machine-readable artifact.

---

# Phase 3 — Audit #36: Promotion runner freshness guard

The Promotion proof and benchmark artifacts were fresh against `capsule_eligibility.rb`, but not against the scripts that
generated them. That left a stale-runner false-PASS: `proof.rb` or `bench.rb` could change while an older JSON/log pair
continued to satisfy the verifier.

Correction:

- `promotion_capsule/proof.rb` now emits `proof_sha256`.
- `promotion_capsule/bench.rb` now emits `bench_sha256`.
- Promotion proof and benchmark artifacts are now guarded against stale runner scripts.
- `verify_findings_evidence.rb` fails if `raw_logs/promotion_capsule_proof_latest.json` is stale against `proof.rb`.
- `verify_findings_evidence.rb` fails if `raw_logs/promotion_bench_latest.json` is stale against `bench.rb`.

Current interpretation: this still does not turn the Promotion slice into a product gate. It only makes the compatibility
proof and per-call benchmark reproducibility stricter: code, runner, JSON, and log must now move together.

---

# Phase 3 — Audit #37: Promotion benchmark report-text guard

The benchmark evidence was guarded at the artifact level, but the human report still repeated rounded throughput numbers
in multiple sections. That is enough to create a stale-report false-PASS: rerun `promotion_bench_latest.json`, keep the old
Markdown numbers, and the written conclusion can drift away from the machine-readable artifact.

Correction:

- Promotion benchmark numbers cited in FINDINGS.md are now derived from `promotion_bench_latest.json`.
- `verify_findings_evidence.rb` formats the current JSON throughputs/ratios into the same rounded strings used by the
  report.
- The verifier fails unless the top Promotion benchmark paragraph, the Audit #3 command-result summary, and the Audit #17
  current-artifact bullets contain the current rounded values.
- The guard covers inline full, owner snapshot build + decide, decide-only, x4 Ractors, owner ratio, and x4 ratio.

Current interpretation: this is not a new performance result. It prevents the written P&D/economic interpretation from
lagging behind the latest benchmark artifact.

---

# Phase 3 — Audit #38: economic raw-log/JSON consistency guard

The economic gate is the decisive evidence against continuing as a runtime/product, so its raw logs cannot be treated as
decorative attachments. Before this pass, `verify_findings_evidence.rb` rebuilt the matrix from per-ALLOC JSON artifacts
and only required each raw log to be non-empty. A stale raw log could therefore disagree with the JSON while still being
cited as evidence.

Correction:

- Economic gate raw logs are now machine-checked against their per-ALLOC JSON artifacts.
- For each economic matrix cell, the verifier checks the raw log's Ruby/platform header, ALLOC, ITEMS/SCAN,
  DURATION/REPS, and `JSON written:` path.
- For each shape section in each raw log, the verifier checks the JSON verdict status marker (`THESIS DIES`,
  `ECONOMIC NO-OP`, `TRADEOFF`, `INCONCLUSIVE`, or `SURVIVES`).
- For verdicts with a Ractor/refork comparison, the verifier checks the rounded ractor-best throughput/PSS,
  refork iso-PSS, PSS ratio, absolute saving, throughput reach, and refork interval p50/p95 against the JSON.

Current interpretation: this does not strengthen the economic result; it makes the artifact bundle harder to misread.
The current economic matrices still have no surviving allocs.

---

# Phase 3 — Audit #39: economic runner hash guard

The economic matrices are generated by a runner stack, not by the verifier itself:

- `refork_gate.rb`
- `bench_kernel.rb`
- `phase3_migration/economic_gate_matrix.rb`

The current JSON artifacts predate explicit runner hashes in their schema, so a future edit to the runner could leave old
economic results looking current. That is a direct threat to the project's main decision gate.

Correction:

- Economic gate runner inputs are now hash-pinned in `verify_findings_evidence.rb`.
- The verifier fails if `refork_gate.rb`, `bench_kernel.rb`, or `phase3_migration/economic_gate_matrix.rb` changes while
  the current economic artifacts remain in place.
- Any real runner change now requires rerunning the Linux matrices or deliberately updating the pin with a written
  justification.

Current interpretation: this is a prospective freshness guard, not retroactive proof that older artifacts embedded runner
hashes. It prevents silent reuse of current economic results after harness changes.

---

# Phase 3 — Audit #40: A2 raw-log/JSON consistency guard

The A2 sync-gateway result is one of the current pivot reasons: in the 3D 72-cell matrix, chatty bounded-sync
(`CAP_EVERY=1`) fails at every `SCAN`/`ALLOC` (12/72 tolerable, 53 fail, 7 inconclusive; `a2_all_cells_fail=false`). The aggregate verifier rebuilt
`a2_sync_matrix_results.json` from per-cell JSON artifacts, but it only required the raw logs to exist. That left a
false-PASS path where the cited raw logs and machine JSON could diverge.

Correction:

- A2 sync-gateway raw logs are now machine-checked against their per-cell JSON artifacts.
- For each cell, the verifier checks the raw log's Ruby/platform header, N_RULES, ITEMS/SCAN, DURATION, ALLOC, POOL,
  CAP_EVERY, CACHE size, REPS, and `JSON written:` path.
- The verifier parses the three model rows and compares rounded throughput, min/max throughput, p50/p95/p99 latency, and
  correctness against JSON.
- The verifier checks the A2 verdict line, sync-gateway tax, throughput-vs-process percentage, latency summary, timeout
  count, and stale-reply count against JSON.

Current interpretation: this does not make A2 a final production benchmark. It makes the current reduced sweep harder to
mis-cite: the raw log and per-cell JSON must tell the same story.

---

# Phase 3 — Audit #41: A2 runner hash guard

The A2 matrix is generated by a runner stack:

- `a2_cache_sync.rb`
- `bench_kernel.rb`
- `phase3_migration/a2_sync_matrix.rb`

Before this pass, changing the A2 runner could leave old JSON/log artifacts passing as if they still represented the
current harness.

Correction:

- A2 sync-gateway runner inputs are now hash-pinned.
- `verify_findings_evidence.rb` fails if `a2_cache_sync.rb`, `bench_kernel.rb`, or
  `phase3_migration/a2_sync_matrix.rb` changes while the current A2 artifacts remain in place.
- A runner change now requires rerunning the A2 matrix or explicitly updating the pin with justification.

Current interpretation: this is a freshness guard. The substantive A2 result remains unchanged: all current reduced
cells fail, so chatty bounded-sync dependencies remain economically unsafe under this evidence.

---

# Phase 3 — Audit #42: outbox stress runner hash guard

The outbox stress JSONs are strong only if they still correspond to the dispatcher code and stress harness that generated
them. The verifier already guarded workload size, workers, batches, lease settings, zero duplicate-attempt budget, and
positive/negative controls, but it did not invalidate old stress artifacts when the runner or dispatcher code changed.

Correction:

- Outbox stress runner inputs are now hash-pinned.
- `verify_findings_evidence.rb` fails if the Slice B stress runner, worker, capsule dispatcher, domain/schema/boot files,
  mini Rails stress runner, worker, capsule service, outbox/delivery models, or delivery/lease migrations change while the
  current stress artifacts remain in place.
- This covers both leased positive artifacts, zero-lease negative controls, and the preserved mini Rails old-unsafe
  controls.

Current interpretation: this is a freshness guard for synthetic outbox evidence. It still does **not** prove a real
Discourse write-side outbox patch; the Discourse Promotion patch remains eligibility-only.

---

# Phase 3 — Audit #43: transaction suite log input hash guard

The full Minitest logs are evidence only for the code and tests that produced them. The verifier already rejects
concatenated logs and checks the exact run/assertion summaries, but it did not reject stale logs after changes to the
test files, worker scripts, capsule protocol, Rails models, or migrations.

Correction:

- Transaction suite log inputs are now hash-pinned.
- `verify_findings_evidence.rb` fails if the Slice B full-suite tests, falsification tests, workers, capsule code,
  domain/schema/boot files, mini Rails test, capsule service, adversarial service, Rails models, worker scripts, or
  migrations change while `slice_b_full_test_latest.log` or `mini_rails_full_test_latest.log` remain in place.
- The existing summary guard still requires exactly one Minitest run per log and the expected pass counts.

Current interpretation: this preserves the current synthetic transaction-soundness evidence against stale logs. It still
does not validate the missing real Discourse write-side outbox implementation.

---

# Phase 3 — Audit #44: Discourse classification runner hash guard

The Discourse classification artifacts were fresh against Discourse source files, but not against every local runner that
generated the classifications. That left a false-PASS path: change the classifier/proof runner, keep the old JSON, and the
aggregate verifier would still accept stale Guardian, Report, Promotion drift, or Promotion write-side-gap evidence.

Correction:

- Discourse classification runner inputs are now hash-pinned.
- `verify_findings_evidence.rb` fails if `guardian_non_fit_proof.rb`, `report_partial_proof.rb`,
  `promotion_capsule/drift_check.rb`, or `promotion_write_side_gap.rb` changes while the current classification artifacts
  remain in place.
- `audit.rb` is separately hash-pinned for `audit_output.json`, so the top-level capsule-hostility audit also cannot be
  silently reused after a classifier change.
- The stale Guardian heading was corrected to point at the current `guardian_non_fit_proof.rb` artifact, not the old
  `promotion_capsule/guardian_nonfit.rb` note.

Current interpretation: this strengthens artifact freshness only. It does not make Guardian a fit, does not make Report a
full fit, and does not close the real Discourse Promotion write-side gap.

---

# Phase 3 — Audit #45: environment proof runner hash guard

The environment proof was guarded for command outputs and dirty-tree state, but not for the script that selected and
interpreted those commands. A future edit to `environment_proof.rb` could otherwise leave
`raw_logs/environment_proof_latest.json` and `.log` looking current.

Correction:

- Environment proof runner input is now hash-pinned.
- `verify_findings_evidence.rb` fails if `phase3_migration/environment_proof.rb` changes while the current environment
  proof artifacts remain in place.
- The emitted aggregate evidence now records the environment proof runner hash guard.

Current interpretation: this is a reproducibility guard for the audit environment, not new performance evidence. The
project verdict remains governed by the economic matrix, A2 gateway matrix, Promotion write-side gap, and transaction
soundness evidence.

---

# Phase 3 — Audit #46: environment proof raw-log/JSON consistency guard

`raw_logs/environment_proof_latest.log` was previously only required to exist and be non-empty. That was too weak for an
environment artifact cited by the report: the JSON could say one thing while the human-readable log said another, or a
concatenated/stale log could keep a misleading PASS header.

Correction:

- Environment proof raw log is now machine-checked against `environment_proof_latest.json`.
- The verifier requires the log header to match the JSON status exactly.
- The verifier requires the log command list to match the JSON command list exactly, in order, with the same ok/FAIL
  status for every command.
- The aggregate evidence now records `raw_log_json_consistency_checked=true` and the environment command count.

Current interpretation: this only removes a stale-log false-PASS path. It does not improve the macOS-vs-Linux limitation
of the environment proof and does not convert any compatibility result into an economic continuation gate.

---

# Phase 3 — Audit #47: Promotion drift raw-log/JSON consistency guard

`raw_logs/drift_check_latest.log` is explicitly cited in the Discourse evidence bundle, but the aggregate verifier only
trusted `raw_logs/promotion_drift_check_latest.json`. That left another stale-report path: the structured JSON could be
current while the human-readable drift log retained different guard counts, mutation-control status, or a stale Discourse
commit suffix.

Correction:

- Promotion drift raw log is now machine-checked against `promotion_drift_check_latest.json`.
- The verifier derives the expected `tl1_met?` and `tl2_met?` guard-count lines from the JSON semantic-match rows.
- The verifier derives the expected mutation-control lines from the JSON negative-control rows.
- The verifier requires the conclusion to report `DRIFT CHECK OK`, the current Discourse short HEAD, the mutation-control
  caveat, and the static-only caveat.
- The aggregate evidence now records a `promotion_drift_log` summary under `discourse_migration_artifacts`.

Current interpretation: the drift check remains static-only. This guard only prevents the Markdown/log layer from
overstating or drifting away from the JSON artifact.

---

# Phase 3 — Audit #48: legacy refork probe raw-log scope guard

The economic evidence bundle still carries three legacy refork logs:

- `raw_logs/refork_gate_smoke_latest.log`
- `raw_logs/refork_gate_large_probe_latest.log`
- `raw_logs/refork_gate_struct_probe_latest.log`

These are the easiest artifacts to misuse because two old JSON probes contain positive `struct` rows while the current
multi-ALLOC matrices do not. Before this pass, the verifier read the legacy positive JSON rows only as context, but it did
not check the matching large/struct raw logs and did not machine-record the superseded status of the smoke log.

Correction:

- Legacy refork probe raw logs are now scope-guarded.
- `refork_gate_large_probe_latest.log` is checked against `economic_gate_large_probe.json`.
- `refork_gate_struct_probe_latest.log` is checked against `economic_gate_struct_probe.json`, including the legacy
  `OVERALL PASS` wording for a non-Pareto `survives` result.
- `refork_gate_smoke_latest.log` is required to remain identifiable as the old reduced smoke run whose JSON target was
  superseded by the current matrix artifact.
- The aggregate economic check now emits `legacy_refork_probe_logs` while keeping
  `legacy_positive_probes_superseded=true`.

Current interpretation: the old positive `struct` probes remain context only. They identify a shape worth retesting, but
they still do not feed `economic_final_gate_passed`, do not override the all-fail current matrices, and do not justify
continuing as product/runtime/platform.

---

# Phase 3 — Audit #49: Guardian/Report classification scope guard

The Guardian and Report artifacts are classification evidence, not just metadata. Before this pass, the verifier checked
that Guardian had some live-read evidence and exactly three stale mutations, and that Report was `partial` with positive
cache/query metrics. That was still too permissive: a weaker artifact could keep the same high-level label while losing
the specific adversarial reasons that matter for the project boundary.

Correction:

- Guardian and Report classification scopes are now machine-guarded.
- Guardian must keep the exact source line range, explicit static/not-Rails-boot scope, structural non-fit conclusion,
  seven live-read category counts, critical live-read fragments, and the three exact stale mutation cases.
- Report must keep the exact partial verdict, cache/SQL sync-gateway frequency, evidence counts for cache, SQL, I18n,
  logger, SiteSetting, and dynamic dispatch, exact path metrics, critical evidence fragments, and capsule rejection rules.
- The aggregate Discourse evidence now emits `guardian_non_fit_scope` and `report_partial_scope`.

Current interpretation: this does not make either artifact stronger than its stated scope. Guardian is still a static
source extraction plus faithful owner-edit stale-snapshot slice, not a booted Discourse execution. Report is still a
static partial-fit proof, not a migrated/report benchmark. The guard only prevents the labels `non_fit` and `partial`
from surviving after their supporting adversarial evidence weakens.

---

# Phase 3 — Audit #50: calibrated struct rerun guard

The project now has a calibrated `struct` rerun outside the reduced Phase-3 matrix:

- `struct_rerun_a100.json`
- `struct_rerun_a500.json`
- `struct_rerun.log`
- prior comparator: `sweep_alloc500_hi.json`

Before this pass, the verifier ignored those files. That left a decision gap: README and `docs/decisions.md` correctly
said `struct` is memory-favorable but throughput-unconfirmed, while the machine evidence bundle still only knew about the
smaller reduced matrices and the old positive probes.

Correction:

- Calibrated struct rerun artifacts are now machine-guarded.
- `struct_rerun_a100.json` must remain Linux/Ruby 4.0.5, N=5M, REPS=6, DURATION=8, ALLOC=100, and `tradeoff_fail` below
  the 100MB memory floor.
- `struct_rerun_a500.json` must remain Linux/Ruby 4.0.5, same calibrated config, with a large memory-positive cell.
- `struct_rerun.log` is checked against both JSONs for config, verdict text, ractor/refork PSS, absolute saving, and
  throughput reach.
- `sweep_alloc500_hi.json` must still show the earlier identical-config struct ALLOC=500 run as `inconclusive` with
  throughput reach below 75%.
- The aggregate economic check now emits `struct_rerun.status=memory_favorable_throughput_unconfirmed`.

Current interpretation: `struct` is not a clean pass. The memory signal is real, but the throughput gate remains
unconfirmed because identical calibrated runs disagree across the throughput threshold. This preserves the narrower claim
that `hash` is the clean reproducible economic win.

---

# Phase 3 — Audit #51: lease ratification documentation guard

The lease decision changed from deferred to ratified. The code and tests were already guarded by hashes/logs, but the
decision record and README could still drift back to the old "no lease yet" canon while the dispatcher remained leased.

Correction:

- Lease ratification docs are now machine-guarded.
- `docs/decisions.md` must keep the superseded deferral note, explicit user-ratified lease decision, unchanged frozen
  claim, separate deliver/mark commits, green slice_b and mini_app test summaries, and the struct re-run interpretation.
- `README.md` must keep the ratified dispatcher lease summary, green test summary, and struct non-clean-pass language.

Current interpretation: the lease is canonical for this prototype, not accidental. It remains at-least-once plus
idempotent dispatch, not exactly-once external effects; the product tradeoff is explicit recovery latency vs duplicate
attempt amplification.

---

# Phase 3 — Audit #52: Promotion amortization gate

The per-call benchmark (Audit #17) showed owner snapshot build + decide is ~0.27× inline. This gate asks the next
question: is there a BATCH size N where building capsule snapshots + deciding (in parallel Ractors) beats inline×N — does
the boundary ever amortize? Runner `phase3_migration/promotion_capsule/promotion_amortization.rb`, artifact
`raw_logs/promotion_amortization_latest.json`. Pure-compute throughput (no `/proc`, no PSS), run on macOS Ruby 4.0.5 — the
metric is platform-robust (wall time / decisions), unlike the Linux-only economic/PSS gates.

Variants per N (total wall, best-of-REPS): (a) inline×N, (b) capsule seq `(build+decide)×N`, (c) capsule par `build N +
decide across 4 Ractors`, (d) frozen-reuse par `decide across 4 Ractors on ONE shared snapshot`.

| N | capsule_seq / inline | capsule_par / inline | frozen_reuse / inline (UPPER BOUND) |
|---:|---:|---:|---:|
| 100 | 0.22× | 0.17× | 0.53× |
| 1000 | 0.21× | 0.21× | 2.10× |
| 10000 | 0.20× | 0.18× | 5.01× |

Result: **`compatibility_only_no_amortization`** — neither REAL Promotion variant (b, c) ever beats inline; capsule stays
~0.2× inline (≈5× slower) at every N because the per-user owner snapshot build is paid sequentially for every user and
already costs more than inline. The frozen-reuse column DOES grow past 1× (4 Ractors over one snapshot), but it is an
UPPER BOUND only and **not a real Promotion scenario** — each user has distinct `user_stat` fields, so users do not share
one snapshot. Crossover would need BOTH a shared snapshot across many evaluations AND an expensive decide; Promotion
(531-byte mock snapshot, ~10 integer compares) has neither. This confirms the canon: Promotion is architectural compatibility,
not a perf win, and there is no batch size where the boundary flips. Guarded by `check_promotion_amortization` (Ruby 4.0.5,
runner+capsule hash pins, classification, and `capsule_seq/par_amortizes=false` at every N).

---

# Phase 3 — Audit #53: Promotion write-side migration spec

`promotion_write_side_gap.rb` (Audit #30/#31) proves the blocker (16 inline write effects, zero capsule-protocol tokens →
`eligibility_only`). `phase3_migration/promotion_write_side_spec.rb` goes one step further WITHOUT writing any Discourse
code: it maps each real inline side effect in `lib/promotion.rb` to the exact capsule construct it WOULD become, and emits
the smallest realistic patch. Artifact `raw_logs/promotion_write_side_spec_latest.json`; pure static analysis of the real
(patched, `eligibility_only`) Discourse source.

The 16 matched lines split into: **7 `commit`** (the trust-level state change itself — owner optimistic AR write, NOT an outbox
effect: `change_trust_level!`, `@user.save!`, `update_column`), **8 `effect`** (idempotent outbox EffectIntents), **1
`residue`** (`recook_bio` — PrettyText/native, owner-side pre-resolve). The 8 effect lines require **7 distinct
EffectIntents**: `user_history`, `staff_action_log`, `discourse_event_user_promoted`, `group_trust_level_change`,
`badge_grant`, `member_welcome_message`, `tl2_promotion_message`, each with a deterministic `idempotency_key_basis`
(`user_id + target_trust_level + effect_kind`).

Smallest realistic patch (NOT implemented): owner decides → optimistic AR COMMIT of the trust-level change → each `effect`
enqueued as an idempotent `OutboxEvent` in the SAME transaction (exactly-once ENQUEUE) → a dispatcher delivers each
at-least-once, consumer dedups by `idempotency_key` (**NOT exactly-once external effect**) → `recook_bio` stays owner-side.

**Blocker stands:** `classification = eligibility_only`, `write_side_implemented = false` — no `Proposal`/`EffectIntent`/
`Outbox`/`idempotency_key` tokens exist in `lib/promotion.rb`. The write side is now MAPPED, not migrated. Guarded by
`check_promotion_write_side_spec` (runner hash pin; the spec reads the same `lib/promotion.rb` source sha as the write-side
gap artifact; effect counts, kind split, and EffectIntent set are machine-guarded).

---

# Phase 3 — Audit #54: A2.3 3D matrix axis upgrade

`a2_sync_matrix.rb` was upgraded from a `CAP_EVERY×TIMEOUT` slice (SCAN/ALLOC fixed) to the real 3D `SCAN×ALLOC×CAP_EVERY`
matrix the README named (see the rewritten Audit #6 for the 72-cell result and the tolerable boundary). The verifier's A2
guard was updated in lockstep and NOT weakened: `check_a2_matrix_consistency` now treats `scan`/`alloc` as per-cell axes
(matched per-run and required to lie within `scope.scans`/`scope.allocs`) while keeping `n_rules`/`items`/`duration_s`/
`reps`/`pool`/`cache_size` constant; it rebuilds the `aggregate` + `by_scan_alloc` summaries from the runs; and
`check_a2_gateway` asserts the 72-cell count and that the aggressive-timeout negative control fires and fails every cell.
The runner hash pin was refreshed with this justification. The verdict now records `a2_all_cells_fail=false` honestly (12
tolerable cells) alongside `a2_chatty_sync_is_killer=true` and `a2_aggressive_control_all_fail=true` — a more precise
constraint, not an economic win; the PIVOT verdict is unchanged.

---

# Phase 3 — Audit #55: Strong Host-Linux Economic Gate v2 (`strong_host_gate_v2.rb`) — REDUCED, adversarially corrected

**Why.** v1 (`refork_gate.rb`) only pit the Ractor against `{Process.warmup, periodic refork}`. The open question was
whether a *stronger* process mold — `GC.compact`, `Process.warmup`, compact+warmup, or a prefork-warmed (old-gen-aged)
image — already closes the CoW gap without periodic refork, which would kill the economy. v2 is a new standalone runner
(does NOT touch the SHA-pinned `refork_gate.rb`/`bench_kernel.rb`; it reuses `bench_kernel` infra and self-checks its hash
kernel against `bench_kernel` at startup to lock out drift) that pits the Ractor frozen image against an **7-model strong
battery**: `process_naive`, `process_gc_compact`, `process_warmup`, `process_gc_compact_plus_warmup`,
`process_prefork_warmed`, `process_refork`, `ractor_frozen_image`. It measures the **full smaps breakdown**
(PSS / Private_Dirty / Shared_Clean / Shared_Dirty / RSS), startup, steady-state-after-GC, per-shape × dataset-target ×
alloc × workers, and decides at **iso-throughput** (gates: Ractor PSS ≤ 75% of the strongest reachable baseline AND
absolute saving ≥ 100MB AND throughput reach ≥ 75%).

**Adversarial review first (4 skeptics) — every measured bias tilted toward the thesis and was removed before any number
was trusted:** (1) refork was the only model denied the GC settle (`steady_gc:0`) → all models now settle symmetrically;
(2) throughput used `median(elapsed)` for static/ractor but a fork-inclusive wall for refork → ALL models now use one
basis `sum(done)/max(elapsed)` (honest pool drain), with refork's recurring fork cost reported separately; (3) the
straddle/INCONCLUSIVE guard divided a w4-Ractor by a w1-process (`reach_hi`=5.6, dead) → reach band now anchored to the
single strongest-throughput process cell; (4) `iso_mem` clamped unreachable baselines to their largest PSS → baselines
that cannot reach the Ractor throughput are now excluded from "strongest" selection; (5) the Ractor deadline was set
pre-spawn → each Ractor now stamps its own deadline post-start (symmetric with fork children); (6) the non-monotonic
Ractor PSS frontier let the max-throughput pick also be the min-PSS cell → the per-worker ratio is now surfaced so a
losing worker cannot hide. The smaps PSS-summing across the process tree was independently confirmed correct (PSS
pre-divides shared pages; the Ractor LOSES the w1 cell, proving no systematic under-count). `Shared_Dirty` was added so
the breakdown reconciles to PSS. The dead `gateway` model and an FD-leak-on-`fork`-failure were removed.

**REDUCED Linux result (hash @ 200MB measured, REPS=3, DUR=3, workers 1/2/4 — `run_class=reduced`, NOT the full gate):**

| ALLOC | verdict | Ractor PSS (w4) | strongest reachable baseline @ iso | ratio / saving / reach | per-worker |
|---|---|---|---|---|---|
| 0 (control) | **PIVOT** | 200.7MB | `process_gc_compact` 295.9MB | 68% / 95MB / 99.5% | no pessimistic worker win; saving floor fails |
| 100 (Rails-like) | **SURVIVES** | 272.1MB | `process_gc_compact_plus_warmup` 535.4MB | 51% / 263MB / 94% | w1/w2 do not pass; **w4 wins** |

(Hardened re-run, 2026-06-17, REPS=3: per-REPS PSS bands are near-zero — ratio band `[0.508,0.509]`, saving band
`[263.1,263.4]MB` — so the win is memory-deterministic, not a convenient median; `extrapolated_out_of_range=false`; all
three `gate_states` (ratio/saving/reach) PASS on the worst-case band. The reported and adversarial baseline is now
`process_gc_compact_plus_warmup` — the corrected out-of-range exclusion plus the lowest-`iso_pss_lo` adversarial guard picks
the strongest baseline that actually reaches the Ractor throughput on that run.)

**Mechanism (now measured via the breakdown):** at ALLOC=0 the dataset stays `Shared_Dirty` across the process tree (CoW
intact) so process PSS ≈ Ractor PSS and the negative control correctly fails; at ALLOC=100 churn breaks CoW, process
`Private_Dirty` multiplies with worker count while the Ractor's stays flat (one shared frozen heap), so the Ractor wins by
263MB — **but only at the w4 operating point (`win_is_single_operating_point=true`).** The strong static molds do NOT close
the gap (the strongest reachable baseline, `process_gc_compact_plus_warmup`, is still 535MB vs Ractor 272MB at iso-throughput).

**Honest status.** This is a strong, bias-corrected REDUCED signal that the hash-under-allocation win survives the STRONG
baselines (not just refork). It is **not** a passed full gate: REPS≥6/DUR≥8/≥500MB-1GB, struct+blob, and multi-operating-point
confirmation are unrun, and the w4/ALLOC=100 throughput showed real cross-baseline variance (warmup w4=16k vs prefork
w4=23k it/s) that REPS=3 cannot settle. Summed `Shared_Clean`/`Shared_Dirty`/`RSS` are sharer-inflated (only PSS and summed
`Private_Dirty` are tree-meaningful; the gate uses PSS). `economic_final_gate_passed` stays **false**; the project verdict
stays **PIVOT**.

**Hardening pass (2026-06-16, before any full gate) — false-PASS paths closed:** (1) per-REPS memory-variance band gate —
`survives` now requires the WORST-case PSS-ratio/saving band (not a convenient median) to clear every threshold, else
`inconclusive`; (2) extrapolation guard — if no process baseline reaches the Ractor throughput within the tested frontier,
the verdict is forced `inconclusive` (never `survives`) with a message to raise `WORKERS`; (3) reduced and full evidence now
write to SEPARATE dirs (`strong_gate_v2_reduced_runs` / `strong_gate_v2_full_runs`) so a full run cannot overwrite the
reduced per-cell JSON; (4) the runner emits its own `runner_sha256` into the aggregate; (5) docs say **7-model** (6 process +
1 Ractor), not 8. The verifier guard (`check_strong_host_gate_v2_reduced`) now asserts: the pinned runner SHA, the aggregate
`runner_sha256` == pin, the EXACT reduced config (hash / 200MB / alloc 0,100 / workers 1,2,4 / REPS=3 / DUR=3), the 42-cell
count, raw-log↔JSON consistency, the ALLOC=0 control PIVOTing, and the ALLOC=100 status + cited numbers (51% / 263MB / 94%,
all `gate_states` pass, `extrapolated_out_of_range=false`) within tolerance — it does **not** assert a gate pass;
`economic_final_gate_passed` stays false.

**Hardening pass 2 (2026-06-17, after a killed re-run was recovered) — two methodological P1s + a forgery residual closed:**
(1) **Adversarial-baseline pessimistic PASS** — the worst-case band (`ratio_hi`/`saving_lo`) no longer trusts the
median-selected baseline; it compares the Ractor's worst PSS against the **lowest `iso_pss_lo` across ALL reachable
baselines** (`adversarial_baseline`), so if any reachable baseline's lower envelope crosses the gate the verdict cannot be
`survives`. The reported ratio/saving stay the *median* baseline's (the cited numbers are the median, not the adversarial
edge). (2) **Pessimistic per-worker `wins`** — a worker is a final win only if it clears the pessimistic per-worker gate
(Ractor `pss_hi` vs the adversarial lower envelope at that worker's throughput, pessimistic reach) AND the run is neither
extrapolated nor straddling; the old median view survives as `median_wins` (informational, never cited as a win), and a
`survives` with no pessimistic worker win is demoted to `inconclusive`. (3) **Per-cell + roster + forgery guards in the
verifier** — `check_strong_host_gate_v2_reduced` now asserts the exact 7-model roster, reads **every** per-cell JSON in
`strong_gate_v2_reduced_runs/` and requires it to be byte-identical to its aggregate record with the dir containing
*exactly* those files (missing/extra/divergent all fail), hard-fails if a `strong_gate_v2_results.json` full artifact
exists without a `check_strong_host_gate_v2_full`, and **ties each verdict's headline ratio/saving to the raw per-cell PSS**
(F1: a hand-edited verdict whose numbers sit inside the tolerance bands but disagree with the cells is rejected). All four
new guards were tamper-proven to exit non-zero (per-cell missing/divergent/extra; verdict ratio→56 and saving→210 forged
within the old bands; headline PSS decoupled from its cell). An independent adversarial review (3 read-only reviewers +
1 adjudicator re-checking each flag against the files) returned **0 real blockers**; the single residual it named — the
verifier still trusts the runner's iso-*interpolation* of the baseline (covered by the SHA pin, not recomputed) — is a
bounded forgery threat, not a real-run false-PASS. The verdict stays **PIVOT**; `economic_final_gate_passed` stays false.

**Full-gate infrastructure built (2026-06-18) — full run BLOCKED_BY_HOST_LINUX.** The decisive experiment is now prepared so
it cannot be run carelessly: (1) `phase3_migration/run_strong_gate_full.sh full` — an ATOMIC launcher that classifies the host
and REFUSES to mint a full economic artifact unless it is a dedicated Linux host (`ALLOW_NON_DEDICATED=1` is diagnostic only;
the verifier rejects completed full artifacts whose manifest `host_class` is not `DEDICATED_LINUX_HOST`), isolates each run under
`strong_gate_v2_full_runs/<run_id>/`, writes the aggregate JSON via `.partial`→atomic-rename only on completion, stamps a
manifest, and never clobbers the reduced evidence (a killed run is ignored). (2) `check_strong_host_gate_v2_full` in the
verifier — an INDEPENDENT reimplementation of `verdict_for` (`sg_recompute_verdict`) that DERIVES every verdict from the raw
per-cell cells (closing the F1 residual: it no longer trusts the runner's emitted numbers). It self-tests against the reduced
evidence on every run (the recompute reproduces pivot@0 / survives@100 exactly), and when a completed full run exists it
asserts manifest `host_class=DEDICATED_LINUX_HOST`, run_class=full_host + Linux/Ruby-4.0.5 per cell, runner_sha256==pin, the exact full config, EXACT grid coverage (every
shape×target×alloc×workers tuple carries the precise 7-model roster), a MANDATORY per-cell byte cross-check, and rejects any
survives recomputing as extrapolated / median-only / straddle. Proven via a synthetic 756-cell run (accepts a valid run,
rejects a forged kill→survives, and — after a 3-agent review — blocks skippable-cross-check / duplicate-drop / NaN / null-pss
forgeries, all tamper-confirmed). The verifier stays **16/16**; `economic_final_gate_passed` is never auto-flipped.

**Run the decisive experiment on a DEDICATED Linux host (verdict promotion stays a deliberate manual step):**

```sh
# preferred (atomic, host-checked, isolated per run_id):
phase3_migration/run_strong_gate_full.sh full
# then validate INDEPENDENTLY (recompute from cells; rejects any non-robust survives):
JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb

# equivalent raw command the launcher wraps with atomicity (<run_id> per run):
docker run --rm -v "$PWD":/app -w /app -e LANG=C.UTF-8 \
  -e SHAPES=hash,struct,blob -e TARGETS_MB=200,500,1000 -e ALLOCS=0,100,500 -e WORKERS=1,2,4,8 \
  -e REPS=6 -e DURATION=8 -e REFORK_EVERY_S=1.0 \
  -e OUT_DIR=/app/phase3_migration/strong_gate_v2_full_runs/<run_id>/cells \
  -e RAW_LOG=/app/phase3_migration/strong_gate_v2_full_runs/<run_id>/run.log \
  -e JSON_OUT=/app/phase3_migration/strong_gate_v2_full_runs/<run_id>/results.json \
  ruby:4.0-slim ruby strong_host_gate_v2.rb
```
