# frozen_string_literal: true
#
# refork_gate.rb — Ractorized Rails Kernel · A1 STRONG-BASELINE death test (Linux only)
#
# The strong process baseline is not `Process.warmup` alone — it is Pitchfork-style REFORK: a warm mold
# from which workers are periodically re-forked, RESTORING the CoW that drifts under allocation. This is a
# FRONTIER / ISO-THROUGHPUT comparison (sweeps POOL like the A1 harness), three models:
#   - ractor            : 1 process, frozen shareable dataset (the thesis)
#   - process_norefork  : warmup + run for DURATION (CoW drifts — the weak baseline)
#   - process_refork    : warmup mold + generations re-forked on a WALL-CLOCK cadence (REFORK_EVERY_S, default 1s);
#                         PASSES_PER_GEN is a diagnostic fallback. Actual refork interval p50/p95 is measured + reported.
# Verdict reads Ractor vs the refork baseline at ISO-THROUGHPUT + Pareto dominance + an absolute-saving gate
# + an INCONCLUSIVE guard. GC.stat (median across reps) proves the allocation→CoW mechanism.
#
#   docker run --rm -v "$PWD":/app -w /app ruby:4.0-slim ruby refork_gate.rb
#   POOLS=1,2,4 ALLOC=100 PASSES_PER_GEN=1 DURATION=4 REPS=3 docker run ...

require "json"
require "time"
require_relative "bench_kernel"
BK = BenchKernel

abort "Linux only — no /proc/smaps_rollup on #{RUBY_PLATFORM}" unless File.exist?("/proc/self/smaps_rollup")

POOLS    = ENV.fetch("POOLS", "1,2,4").split(",").map { Integer(_1) }
SHAPES   = ENV.fetch("SHAPES", "hash,struct,blob").split(",").map(&:to_sym)
N_RULES  = Integer(ENV.fetch("N_RULES", 1_000_000))        # default; per-shape override via N_RULES_HASH/STRUCT/BLOB
ITEMS    = Integer(ENV.fetch("ITEMS",   2_000))
SCAN     = Integer(ENV.fetch("SCAN",    1_500))
ALLOC    = Integer(ENV.fetch("ALLOC",   100))
DURATION = Float(ENV.fetch("DURATION",  4.0))
# Refork cadence. PRIMARY = wall-clock: each generation runs ~REFORK_EVERY_S seconds, then re-forks (gens ≈ DURATION/T).
# Diagnostic fallback (REFORK_EVERY_S<=0) = fixed full passes per generation. The harness ALWAYS measures and reports
# the ACTUAL refork interval p50/p95 (fork→work→snapshot→release), so the baseline is comparable across shape/ALLOC/pool.
REFORK_EVERY_S = Float(ENV.fetch("REFORK_EVERY_S", "1.0"))
PASSES_PER_GEN = Integer(ENV.fetch("PASSES_PER_GEN", 1))   # DIAGNOSTIC only (used when REFORK_EVERY_S<=0)
REPS     = Integer(ENV.fetch("REPS",    3))
MB = ->(kb) { (kb / 1024.0).round(1) }
JSON_OUT = ENV["JSON_OUT"]

# economic gates — single source of truth, also emitted into the JSON `gates` block so logic + report cannot desync
PSS_RATIO_MAX = 0.80   # Ractor PSS must be ≤ this fraction of refork PSS at iso-throughput
SAVING_MB_MIN = 100    # AND the ABSOLUTE saving must clear this floor (a ratio win on a small dataset is a no-op)
REACH_MIN     = 0.75   # AND Ractor throughput must reach ≥ this fraction of the refork-max throughput

abort "DURATION must be > 0 (got #{DURATION})" unless DURATION > 0

# per-shape dataset size: a blob is 16 B/record but a hash is ~200 B/record, so a single N_RULES can't hit a target
# resident size across shapes. N_RULES_HASH / N_RULES_STRUCT / N_RULES_BLOB override per shape (calibrated to clear ≥100MB).
def n_for(shape) = Integer(ENV.fetch("N_RULES_#{shape.to_s.upcase}", N_RULES))

Rec = Data.define(:threshold, :factor, :base)
BLOB_FMT = "lld"
BLOB_SIZE = 16

def field_values(i) = [i % 1000, ((i * 37) % 100) / 100.0, i % 50]

def build_dataset(shape, n)
  case shape
  when :hash
    Array.new(n) { |i| t, f, b = field_values(i); { threshold: t, factor: f, base: b } }
  when :struct
    Array.new(n) { |i| t, f, b = field_values(i); Rec.new(threshold: t, factor: f, base: b) }
  when :blob
    (+"").tap { |s| n.times { |i| t, f, b = field_values(i); s << [t, b, f].pack(BLOB_FMT) } }
  else
    abort "unknown shape #{shape}"
  end
end

def count_of(dataset, shape) = shape == :blob ? dataset.bytesize / BLOB_SIZE : dataset.length

def compute(dataset, shape, count, item)
  start = item[:seed] % (count - SCAN)
  v = item[:value]
  acc = 0.0
  case shape
  when :hash
    SCAN.times do |j|
      r = dataset[start + j]
      acc += r[:factor] * (v + r[:base]) if v > r[:threshold]
    end
  when :struct
    SCAN.times do |j|
      r = dataset[start + j]
      acc += r.factor * (v + r.base) if v > r.threshold
    end
  when :blob
    SCAN.times do |j|
      off = (start + j) * BLOB_SIZE
      threshold = dataset.unpack1("l", offset: off)
      acc += dataset.unpack1("d", offset: off + 8) * (v + dataset.unpack1("l", offset: off + 4)) if v > threshold
    end
  end
  acc
end

def work(dataset, shape, count, items, deadline)
  g0 = GC.stat
  t0 = BK.mono
  done = 0
  cksum = 0.0
  first_pass = false
  until BK.mono > deadline
    items.each do |it|
      acc = compute(dataset, shape, count, it)
      BK.churn(ALLOC) unless ALLOC.zero?
      cksum += acc unless first_pass
      done += 1
    end
    first_pass = true
  end
  g1 = GC.stat
  { done: done, elapsed: BK.mono - t0, cksum: cksum.round(4), full_pass: first_pass,
    gc_count: g1[:count] - g0[:count],
    gc_time_ms: (g1[:time] || 0) - (g0[:time] || 0),
    alloc_objs: g1[:total_allocated_objects] - g0[:total_allocated_objects] }
end

def work_passes(dataset, shape, count, items, passes)
  g0 = GC.stat
  t0 = BK.mono
  done = 0
  cksum = 0.0
  passes.times do |p|
    items.each do |it|
      acc = compute(dataset, shape, count, it)
      BK.churn(ALLOC) unless ALLOC.zero?
      cksum += acc if p.zero?
      done += 1
    end
  end
  g1 = GC.stat
  { done: done, elapsed: BK.mono - t0, cksum: cksum.round(4), full_pass: passes >= 1,
    gc_count: g1[:count] - g0[:count],
    gc_time_ms: (g1[:time] || 0) - (g0[:time] || 0),
    alloc_objs: g1[:total_allocated_objects] - g0[:total_allocated_objects] }
end

# fork `pool` workers, each running `worker.call(dataset, shard)`, barrier-snapshot the tree, return [results, pss, snap_s].
# snap_s = wall spent reading /proc smaps of the held tree — a MEASUREMENT artifact (production refork never reads smaps).
# It is returned so callers can exclude it from the throughput denominator (refork pays it gens× vs ractor/norefork 1×).
def run_generation(dataset, pool, worker)
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }   # built once — symmetric with the Ractor model
  res_r = []; hold_w = []; pids = []; released = false
  begin
    pool.times do |i|
      rr, rw = IO.pipe; hr, hw = IO.pipe
      pids << fork do
        rr.close; hw.close
        Marshal.dump(worker.call(dataset, shards[i]), rw); rw.close
        hr.read(1); exit!(0)
      end
      rw.close; hr.close
      res_r << rr; hold_w << hw
    end
    results = res_r.map { |r| Marshal.load(r.read) }
    s0 = BK.mono
    pss = [BK.smaps, *pids.map { |p| BK.smaps(p) }].sum { _1[:pss] }
    snap_s = BK.mono - s0
    hold_w.each { |w| w.write("x") }; released = true
    [results, pss, snap_s]
  ensure
    (res_r + hold_w).each { |io| io.close unless io.closed? }
    pids.each { |p| (Process.kill("KILL", p) rescue nil) unless released; Process.wait(p) rescue nil }
  end
end

def gc_sum(results)
  { count: results.sum { _1[:gc_count] }, time: results.sum { _1[:gc_time_ms] }, objs: results.sum { _1[:alloc_objs] } }
end

def pctl(xs, q)
  return 0.0 if xs.empty?
  s = xs.sort
  s[(q * (s.length - 1)).round]
end

def process_norefork(dataset, shape, count, pool)
  GC.start; Process.warmup
  t0 = BK.mono
  res, pss, snap = run_generation(dataset, pool, ->(ds, sh) { work(ds, shape, count, sh, BK.mono + DURATION) })
  wall = BK.mono - t0
  # compute_wall excludes the smaps-snapshot artifact so throughput is apples-to-apples with refork (which snapshots gens×)
  { results: res, pss: pss, wall: wall, compute_wall: wall - snap, snap_s: snap, gens: 1, gc: gc_sum(res) }
end

def process_refork(dataset, shape, count, pool)
  GC.start; Process.warmup                                  # warm mold; parent never runs the loop → stays clean
  # PRIMARY: wall-clock cadence — each child runs `work` for a fresh REFORK_EVERY_S budget (measured from when IT starts,
  # so fork latency is excluded from the budget but INCLUDED in the reported interval). DIAGNOSTIC: fixed passes/gen.
  worker =
    if REFORK_EVERY_S > 0
      ->(ds, sh) { work(ds, shape, count, sh, BK.mono + REFORK_EVERY_S) }
    else
      ->(ds, sh) { work_passes(ds, shape, count, sh, PASSES_PER_GEN) }
    end
  t0 = BK.mono; all = []; pss_samples = []; intervals = []; snap_total = 0.0; gens = 0
  # full-budget generations (never truncate the last one — a truncated pass would fail correctness); overshoot ≤ one budget
  while BK.mono - t0 < DURATION
    g_t0 = BK.mono
    res, pss, snap = run_generation(dataset, pool, worker)
    intervals << (BK.mono - g_t0)                           # ACTUAL refork interval: fork → work → barrier-snapshot → release (full)
    all.concat(res); pss_samples << pss; snap_total += snap; gens += 1
  end
  wall = BK.mono - t0
  # median END-OF-GENERATION PSS (max drift/gen — FAVORS Ractor; a time-average would sample mid-gen, lower).
  # compute_wall excludes the gens× smaps-snapshot artifact (the FORK cost stays — it is a real refork penalty).
  { results: all, pss: BK.median(pss_samples), wall: wall, compute_wall: wall - snap_total, snap_s: snap_total,
    gens: gens, gen_intervals: intervals, gc: gc_sum(all) }
end

def ractor_model(dataset_shareable, shape, count, pool)
  ready = Ractor::Port.new
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }
  t0 = BK.mono; deadline = t0 + DURATION
  g0 = GC.stat                                              # main-level: ONE heap covers all Ractors
  rs = pool.times.map do |i|
    Ractor.new(dataset_shareable, shape, count, shards[i], ready, deadline) do |ds, shp, cnt, sh, rdy, dl|
      out = work(ds, shp, cnt, sh, dl)
      h = Ractor::Port.new; rdy.send([out, h]); h.receive; out
    end
  end
  collected = pool.times.map { ready.receive }
  s0 = BK.mono
  pss = BK.smaps[:pss]; g1 = GC.stat
  snap = BK.mono - s0                                        # same smaps-snapshot artifact, excluded from compute_wall
  collected.each { |(_o, h)| h.send(:go) }
  rs.each(&:value)
  wall = BK.mono - t0
  { results: collected.map(&:first), pss: pss, wall: wall, compute_wall: wall - snap, snap_s: snap, gens: 1,
    gc: { count: g1[:count] - g0[:count], time: (g1[:time] || 0) - (g0[:time] || 0),
          objs: g1[:total_allocated_objects] - g0[:total_allocated_objects] } }
end

# throughput uses compute_wall (wall minus the smaps-snapshot measurement artifact), identical across all three models
def tput(m) = m[:results].sum { _1[:done] } / m[:compute_wall]
def correct?(m, oracle)
  return false unless m[:results].all? { _1[:full_pass] }
  expected = oracle * m[:gens]
  (m[:results].sum { _1[:cksum] } - expected).abs <= expected.abs * 1e-9 + 1e-3
end
def med_gc(rows, k) = BK.median(rows.map { _1[:gc][k] })

def cell(oracle)
  rows = Array.new(REPS) { yield }
  ts = rows.map { tput(_1) }
  { tput: BK.median(ts), tlo: ts.min, thi: ts.max, pss: BK.median(rows.map { _1[:pss] }),
    correct: rows.all? { correct?(_1, oracle) },
    intervals: rows.flat_map { _1[:gen_intervals] || [] },   # refork only; [] for ractor/norefork (single generation)
    gens_median: BK.median(rows.map { _1[:gens] }),          # a median of counts, not itself a count — labelled as such
    wall: BK.median(rows.map { _1[:wall] }),
    compute_wall: BK.median(rows.map { _1[:compute_wall] }),
    snap_s: BK.median(rows.map { _1[:snap_s] }),
    gc: { count: med_gc(rows, :count), time: med_gc(rows, :time), objs: med_gc(rows, :objs) } }
end

def iso_pss(points, t)   # interpolate a model's PSS at throughput t
  s = points.sort_by { _1[:tput] }
  return s.first[:pss].to_f if t <= s.first[:tput]
  return s.last[:pss].to_f  if t >= s.last[:tput]
  hi = s.find { _1[:tput] >= t }; lo = s.reverse.find { _1[:tput] <= t }
  lo[:pss] + (t - lo[:tput]) / (hi[:tput] - lo[:tput]).to_f * (hi[:pss] - lo[:pss])
end

# ---------- driver ----------
puts "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) refork death-test (frontier / iso-throughput)"
cadence = REFORK_EVERY_S > 0 ? "wall-clock #{REFORK_EVERY_S}s/gen" : "DIAGNOSTIC passes/gen=#{PASSES_PER_GEN}"
puts "POOLS=#{POOLS.inspect} SHAPES=#{SHAPES.inspect} N_by_shape=#{SHAPES.to_h { |s| [s, n_for(s)] }} " \
     "ITEMS=#{ITEMS} SCAN=#{SCAN} ALLOC=#{ALLOC} DURATION=#{DURATION}s REPS=#{REPS} refork-cadence=#{cadence}"

summary = {
  ruby: RUBY_DESCRIPTION,
  platform: RUBY_PLATFORM,
  generated_at_utc: Time.now.utc.iso8601,
  config: {
    pools: POOLS,
    shapes: SHAPES,
    n_rules: N_RULES,
    n_rules_by_shape: SHAPES.to_h { |shape| [shape, n_for(shape)] },
    items: ITEMS,
    scan: SCAN,
    alloc: ALLOC,
    duration_s: DURATION,
    refork_every_s: REFORK_EVERY_S,
    passes_per_gen: PASSES_PER_GEN,
    reps: REPS,
  },
  gates: {
    pss_ratio_max: PSS_RATIO_MAX,
    absolute_saving_mb_min: SAVING_MB_MIN,
    throughput_reach_min: REACH_MIN,
  },
  shapes: [],
}

SHAPES.each do |shape|
  n = n_for(shape)                                           # per-shape dataset size (see N_RULES_* override)
  abort "N(#{shape})=#{n} must exceed SCAN=#{SCAN} (compute window would underflow)" if n <= SCAN
  oracle = BK.isolated do
    ds = build_dataset(shape, n)
    cnt = count_of(ds, shape)
    BK.make_items(ITEMS).sum { |it| compute(ds, shape, cnt, it) }.round(4)
  end

  front = { ractor: [], norefork: [], refork: [] }
  shape_summary = { shape: shape, n_rules: n, oracle: oracle, frontier: {}, verdict: nil }
  puts "\n==================== shape: #{shape} (N=#{n}) ===================="
  printf "%-22s %5s %10s %15s %8s %9s %12s %7s\n", "model", "pool", "items/s", "tput[min..max]", "PSS_MB", "GC_cnt", "alloc_objs", "ok"
  POOLS.each do |pool|
    {
      ractor: lambda {
        BK.isolated do
          ds = Ractor.make_shareable(build_dataset(shape, n))
          ractor_model(ds, shape, count_of(ds, shape), pool)
        end
      },
      norefork: lambda {
        BK.isolated do
          ds = build_dataset(shape, n)
          process_norefork(ds, shape, count_of(ds, shape), pool)
        end
      },
      refork: lambda {
        BK.isolated do
          ds = build_dataset(shape, n)
          process_refork(ds, shape, count_of(ds, shape), pool)
        end
      },
    }.each do |key, run|
      c = cell(oracle, &run)
      front[key] << c.merge(pool: pool)
      shape_summary[:frontier][key] ||= []
      shape_summary[:frontier][key] << {
        pool: pool,
        throughput_items_s: c[:tput],
        throughput_min_items_s: c[:tlo],
        throughput_max_items_s: c[:thi],
        pss_kb: c[:pss],
        pss_mb: MB[c[:pss]],
        correct: c[:correct],
        gc_count: c[:gc][:count],
        gc_time_ms: c[:gc][:time],
        allocated_objects: c[:gc][:objs],
        gens_median: c[:gens_median],
        wall_s: c[:wall],
        compute_wall_s: c[:compute_wall],
        snap_artifact_s: c[:snap_s],
        snap_artifact_pct_of_wall: c[:wall].to_f.positive? ? (c[:snap_s] / c[:wall] * 100).round(2) : 0.0,
        refork_interval_p50_s: key == :refork ? pctl(c[:intervals], 0.5) : nil,
        refork_interval_p95_s: key == :refork ? pctl(c[:intervals], 0.95) : nil,
      }
      printf "%-22s %5d %10.0f %15s %6.1fMB %9d %12d %7s\n",
             key.to_s, pool, c[:tput], "#{c[:tlo].round}..#{c[:thi].round}", MB[c[:pss]], c[:gc][:count], c[:gc][:objs], (c[:correct] ? "yes" : "NO")
      if key == :refork && !c[:intervals].empty?
        snap_pct = c[:wall].to_f.positive? ? c[:snap_s] / c[:wall] * 100 : 0.0
        printf "%-22s %5s  ↳ actual refork interval p50=%.3fs p95=%.3fs (%d gens, %s); smaps artifact excl. from tput %.2f%% of wall\n",
               "", "", pctl(c[:intervals], 0.5), pctl(c[:intervals], 0.95), c[:gens_median].round,
               (REFORK_EVERY_S > 0 ? "target #{REFORK_EVERY_S}s" : "passes #{PASSES_PER_GEN}"), snap_pct
      end
    end
  end

  # ---------- verdict: Ractor vs the REFORK strong baseline, at iso-throughput ----------
  ref_int = front[:refork].flat_map { _1[:intervals] }       # pooled actual refork intervals across pools/reps
  cad = REFORK_EVERY_S > 0 ? "wall #{REFORK_EVERY_S}s/gen" : "passes #{PASSES_PER_GEN}/gen"
  puts format("\n  verdict (%s, N=%d, ALLOC=%d, refork %s; actual interval p50=%.3fs p95=%.3fs):",
              shape, n, ALLOC, cad, pctl(ref_int, 0.5), pctl(ref_int, 0.95))
  if front.values.flatten.any? { |c| !c[:correct] }
    puts "    → INVALID: a model failed correctness (raise DURATION or lower POOL)."
    shape_summary[:verdict] = { status: "invalid", reason: "a model failed correctness" }
  else
    rb   = front[:ractor].max_by { _1[:tput] }
    rfx  = iso_pss(front[:refork],   rb[:tput])
    nrx  = iso_pss(front[:norefork], rb[:tput])
    rf_max = front[:refork].max_by { _1[:tput] }
    pss_ratio = rb[:pss] / rfx
    reach     = rb[:tput] / rf_max[:tput]
    reach_lo  = rb[:tlo] / rf_max[:thi]; reach_hi = rb[:thi] / rf_max[:tlo]
    saved     = MB[rfx - rb[:pss]]
    material  = saved >= SAVING_MB_MIN   # ABSOLUTE floor — a Pareto/ratio win on a small dataset is an economic no-op
    printf "    ractor best:        %.0f items/s @ pool %d, PSS %.1fMB\n", rb[:tput], rb[:pool], MB[rb[:pss]]
    printf "    refork  @ iso-tput: PSS %.1fMB   |   no-refork @ iso-tput: PSS %.1fMB\n", MB[rfx], MB[nrx]
    printf "    Ractor PSS / refork PSS = %.1f%% (gate ≤%d%%) ; absolute saving %sMB (gate ≥%dMB ABSOLUTE)\n", pss_ratio * 100, (PSS_RATIO_MAX * 100).round, saved, SAVING_MB_MIN
    printf "    throughput reach vs refork max = %.1f%% (gate ≥%d%%)\n", reach * 100, (REACH_MIN * 100).round
    # Pareto at the matched point. A Pareto win is only an ECONOMIC win if the absolute saving clears the floor.
    if (reach_lo >= REACH_MIN) != (reach_hi >= REACH_MIN)
      puts "    → INCONCLUSIVE — throughput spread straddles the gate (raise REPS/DURATION)."
      status = "inconclusive"
      reason = "throughput spread straddles the gate"
    elsif rfx <= rb[:pss] && rf_max[:tput] >= rb[:tput]
      puts "    → THESIS DIES: refork Pareto-dominates Ractor (≤PSS AND ≥throughput)."
      status = "kill"
      reason = "refork Pareto-dominates Ractor"
    elsif rb[:pss] <= rfx && rb[:tput] >= rf_max[:tput]
      if material
        puts "    → Ractor SURVIVES — Pareto-dominates refork (≤PSS AND ≥throughput) with a MATERIAL #{saved}MB saving."
        status = "survives"
        reason = "Ractor Pareto-dominates refork with material saving"
      else
        puts "    → ECONOMIC NO-OP — Ractor technically Pareto-dominates refork but the #{saved}MB saving is <#{SAVING_MB_MIN}MB (no real economic win)."
        status = "economic_no_op"
        reason = "Ractor Pareto-dominates refork but absolute saving is below #{SAVING_MB_MIN}MB"
      end
    else
      mem_gate = pss_ratio <= PSS_RATIO_MAX && material
      overall  = mem_gate && reach >= REACH_MIN
      puts "    → TRADEOFF (neither Pareto-dominates): Ractor throughput #{(reach * 100).round}% of refork-max, " \
           "Ractor PSS #{(pss_ratio * 100).round}% of refork. Memory gate (≤#{(PSS_RATIO_MAX * 100).round}% AND ≥#{SAVING_MB_MIN}MB): #{mem_gate ? 'pass' : 'fail'}; " \
           "throughput gate (≥#{(REACH_MIN * 100).round}%): #{reach >= REACH_MIN ? 'pass' : 'fail'} → OVERALL #{overall ? 'PASS' : 'FAIL'}."
      status = overall ? "survives" : "tradeoff_fail"
      reason = "neither model Pareto-dominates; memory gate #{mem_gate ? 'passes' : 'fails'}, throughput gate #{reach >= REACH_MIN ? 'passes' : 'fails'}"
    end

    shape_summary[:verdict] = {
      status: status,
      reason: reason,
      ractor_best: {
        pool: rb[:pool],
        throughput_items_s: rb[:tput],
        pss_kb: rb[:pss],
        pss_mb: MB[rb[:pss]],
      },
      refork_iso_pss_kb: rfx,
      refork_iso_pss_mb: MB[rfx],
      norefork_iso_pss_kb: nrx,
      norefork_iso_pss_mb: MB[nrx],
      refork_max_throughput_items_s: rf_max[:tput],
      refork_interval_p50_s: pctl(ref_int, 0.5),
      refork_interval_p95_s: pctl(ref_int, 0.95),
      pss_ratio: pss_ratio,
      pss_ratio_percent: (pss_ratio * 100).round(1),
      throughput_reach: reach,
      throughput_reach_percent: (reach * 100).round(1),
      throughput_reach_min: reach_lo,
      throughput_reach_max: reach_hi,
      absolute_saving_mb: saved,
      material_saving: material,
    }
  end
  summary[:shapes] << shape_summary
end

if JSON_OUT
  File.write(JSON_OUT, JSON.pretty_generate(summary))
  puts "\nJSON written: #{JSON_OUT}"
end
