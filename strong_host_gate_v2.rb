# frozen_string_literal: true
#
# strong_host_gate_v2.rb — Ractorized Rails Kernel · STRONG HOST-LINUX ECONOMIC GATE v2 (Linux for memory)
#
# Decisive question: does the Ractor frozen-image still win >=25-30% PSS against a BATTERY OF STRONG process
# baselines at EQUIVALENT throughput — or does a compacted / warmed / prefork-warmed / reforked process already
# close the gap? v1 (refork_gate.rb) only pit Ractor vs {warmup, refork}. v2 adds the strong STATIC baselines and
# the full smaps breakdown (PSS / Private_Dirty / Shared_Clean / Shared_Dirty / RSS), startup cost, steady-state-after-GC,
# and an iso-throughput frontier across shape x dataset-target x alloc x workers. Ractor must beat the STRONGEST process
# technique at iso-throughput, not the naive one.
#
# Models:
#   process_naive                   fork, no prep                                  (weak control)
#   process_gc_compact              GC.compact then fork
#   process_warmup                  Process.warmup then fork
#   process_gc_compact_plus_warmup  GC.compact + Process.warmup then fork
#   process_prefork_warmed          compact + warmup + extra full-mark GCs then fork (Process.warmup already compacts and
#                                   ages survivors to old-gen, so this is usually ~equal to compact+warmup — kept as a
#                                   control proving the warmed mold is already maximal, not as a distinct stronger model)
#   process_refork                  periodic refork on a wall-clock cadence        (Pitchfork-style; fork cost reported separately)
#   ractor_frozen_image             one process, make_shareable dataset, pool Ractors   (the thesis)
#
# FAIRNESS (every lever made symmetric after an adversarial review found all biases tilting toward the thesis):
#   - ONE throughput basis for EVERY model: tput = sum(done) / work_wall, where work_wall = sum over generations of the
#     SLOWEST worker's in-`work` elapsed (max, not median — the honest drain time of a barrier-joined pool). One-time
#     spawn/fork and all IPC/snapshot are EXCLUDED for every model; refork's recurring per-generation fork+settle overhead
#     is reported SEPARATELY as recurring_fork_s (it does not flatter or penalise throughput).
#   - SYMMETRIC steady-state: STEADY_GC GC.start cycles settle churn before the PSS snapshot for EVERY model incl. refork.
#   - SYMMETRIC deadlines: every worker (process child AND Ractor) stamps its own deadline = mono + DURATION after it starts.
#   - Memory = steady-state PSS of the whole tree (parent + children) summed; PSS pre-divides shared pages so the tree-sum
#     counts a CoW-shared page once — a fair counterpart to the Ractor's single-process PSS.
#   - Verdict compares at iso-throughput, anchors the reach band to the SINGLE strongest-throughput process cell, excludes
#     baselines that cannot reach the Ractor throughput from "strongest" selection, and SURFACES the per-worker ratio so a
#     non-monotonic Ractor frontier cannot hide a worker where the Ractor loses.
#
# Memory is measured ONLY on Linux (/proc/<pid>/smaps_rollup). Off-Linux the runner still exercises throughput +
# correctness as a SMOKE but emits NO memory and NO economic verdict — a macOS result can never feed a memory claim.
#
#   docker run --rm -v "$PWD":/app -w /app ruby:4.0-slim ruby strong_host_gate_v2.rb
#   SHAPES=hash,struct,blob TARGETS_MB=50,200,500 ALLOCS=0,100,500 WORKERS=1,2,3,4 REPS=6 DURATION=8 \
#     JSON_OUT="$PWD/phase3_migration/raw_logs/strong_gate_v2_results.json" ruby strong_host_gate_v2.rb

require "json"
require "time"
require "fileutils"
require "digest"
require_relative "bench_kernel"
BK = BenchKernel
# NB: do NOT set Encoding.default_external = UTF-8 here — it makes IO.pipe transcode and corrupts the binary
# Marshal.dump that BK.isolated writes over the pipe (ASCII-8BIT -> UTF-8 raises). The log file is opened w:UTF-8 instead.

MEM = File.exist?("/proc/self/smaps_rollup")   # memory measurable only on Linux

# ---------- config ----------
SHAPES   = ENV.fetch("SHAPES", "hash,struct,blob").split(",").map { _1.strip.to_sym }
TARGETS  = ENV.fetch("TARGETS_MB", "50,200,500").split(",").map { Float(_1.strip) }
ALLOCS   = ENV.fetch("ALLOCS", "0,100,500").split(",").map { Integer(_1.strip) }
WORKERS  = ENV.fetch("WORKERS", "1,2,3,4").split(",").map { Integer(_1.strip) }
ITEMS    = Integer(ENV.fetch("ITEMS", 2_000))
SCAN     = Integer(ENV.fetch("SCAN", 1_500))
DURATION = Float(ENV.fetch("DURATION", 4.0))
REPS     = Integer(ENV.fetch("REPS", 3))
REFORK_EVERY_S = Float(ENV.fetch("REFORK_EVERY_S", "1.0"))
STEADY_GC = Integer(ENV.fetch("STEADY_GC", 2))           # GC cycles to settle steady-state memory (ALL models, symmetric)
CALIB_N0  = Integer(ENV.fetch("CALIB_N0", 200_000))      # records used to measure bytes/record per shape
DEFAULT_MODELS = %w[process_naive process_gc_compact process_warmup process_gc_compact_plus_warmup
                    process_prefork_warmed process_refork ractor_frozen_image]
MODELS = ENV.fetch("MODELS", DEFAULT_MODELS.join(",")).split(",").map(&:strip)

# economic gates — single source of truth, emitted into the JSON so logic and report cannot desync
PSS_RATIO_MAX = Float(ENV.fetch("PSS_RATIO_MAX", "0.75"))   # Ractor PSS must be <= this fraction of the strongest baseline
SAVING_MB_MIN = Float(ENV.fetch("SAVING_MB_MIN", "100"))    # AND the ABSOLUTE saving must clear this floor
REACH_MIN     = Float(ENV.fetch("REACH_MIN", "0.75"))       # AND Ractor throughput must reach >= this fraction of best process tput

OUT_DIR  = ENV.fetch("OUT_DIR", File.join(__dir__, "phase3_migration", "strong_gate_v2_reduced_runs"))
RAW_LOG  = ENV.fetch("RAW_LOG", File.join(__dir__, "phase3_migration", "raw_logs", "strong_gate_v2_run.log"))
JSON_OUT = ENV["JSON_OUT"]

abort "DURATION must be > 0" unless DURATION > 0
abort "REPS must be >= 1" unless REPS >= 1
N_OVERRIDE = ->(shape) { (v = ENV["N_#{shape.to_s.upcase}"]) && Integer(v) }

MB = ->(kb) { kb.nil? ? nil : (kb / 1024.0).round(1) }
FileUtils.mkdir_p(OUT_DIR)
FileUtils.mkdir_p(File.dirname(RAW_LOG))
LOG_IO = File.open(RAW_LOG, "w:UTF-8")
def log(line = "")
  puts line
  LOG_IO.puts(line)
  LOG_IO.flush
end

# ---------- shape-aware dataset / compute / work (same kernel shape as refork_gate.rb; redefined here on purpose —
#            v2 is a standalone runner that must not modify the SHA-pinned refork_gate.rb. The hash-shape oracle is
#            cross-checked against bench_kernel at startup to lock out silent drift.) ----------
Rec = Data.define(:threshold, :factor, :base)
BLOB_FMT = "lld"
BLOB_SIZE = 16
def field_values(i) = [i % 1000, ((i * 37) % 100) / 100.0, i % 50]

def build_dataset(shape, n)
  case shape
  when :hash   then Array.new(n) { |i| t, f, b = field_values(i); { threshold: t, factor: f, base: b } }
  when :struct then Array.new(n) { |i| t, f, b = field_values(i); Rec.new(threshold: t, factor: f, base: b) }
  when :blob   then (+"").tap { |s| n.times { |i| t, f, b = field_values(i); s << [t, b, f].pack(BLOB_FMT) } }
  else abort "unknown shape #{shape}"
  end
end
def count_of(dataset, shape) = shape == :blob ? dataset.bytesize / BLOB_SIZE : dataset.length

def compute(dataset, shape, count, item)
  start = item[:seed] % (count - SCAN)
  v = item[:value]
  acc = 0.0
  case shape
  when :hash
    SCAN.times { |j| r = dataset[start + j]; acc += r[:factor] * (v + r[:base]) if v > r[:threshold] }
  when :struct
    SCAN.times { |j| r = dataset[start + j]; acc += r.factor * (v + r.base) if v > r.threshold }
  when :blob
    SCAN.times do |j|
      off = (start + j) * BLOB_SIZE
      threshold = dataset.unpack1("l", offset: off)
      acc += dataset.unpack1("d", offset: off + 8) * (v + dataset.unpack1("l", offset: off + 4)) if v > threshold
    end
  end
  acc
end

# sustained loop until `deadline`; first-pass checksum proves correctness; GC.stat deltas prove the alloc->CoW mechanism
def work(dataset, shape, count, items, alloc, deadline)
  g0 = GC.stat
  t0 = BK.mono
  done = 0; cksum = 0.0; first_pass = false
  until BK.mono > deadline
    items.each do |it|
      acc = compute(dataset, shape, count, it)
      BK.churn(alloc) unless alloc.zero?
      cksum += acc unless first_pass
      done += 1
    end
    first_pass = true
  end
  g1 = GC.stat
  { done: done, elapsed: BK.mono - t0, cksum: cksum.round(4), full_pass: first_pass,
    gc_count: g1[:count] - g0[:count], gc_time_ms: (g1[:time] || 0) - (g0[:time] || 0),
    alloc_objs: g1[:total_allocated_objects] - g0[:total_allocated_objects] }
end

# ---------- memory ----------
def smaps_full(pid = Process.pid)
  txt = File.read("/proc/#{pid}/smaps_rollup")
  grab = lambda do |key|
    m = txt[/^#{key}:\s+(\d+)\s+kB/, 1]
    raise "smaps: field #{key} not found for pid #{pid}" if m.nil?
    Integer(m)
  end
  { pss: grab["Pss"], pdirty: grab["Private_Dirty"], sclean: grab["Shared_Clean"], sdirty: grab["Shared_Dirty"], rss: grab["Rss"] }
rescue Errno::ENOENT
  raise "smaps: process #{pid} gone before snapshot (OOM/crash?)"
end
MEM_FIELDS = %i[pss pdirty sclean sdirty rss].freeze
def sum_mem(pids) = pids.map { smaps_full(_1) }.reduce { |a, b| a.merge(b) { |_k, x, y| x + y } }
def median_mem(samples) = MEM_FIELDS.to_h { |k| [k, BK.median(samples.map { _1[k] })] }

# ---------- one forked generation: pool workers run `work` for `dur`, settle GC (steady_gc cycles), barrier-snapshot ----------
def run_generation(dataset, shape, count, pool, alloc, dur, steady_gc:)
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }
  ios = []; res_r = []; hold_w = []; pids = []; released = false
  begin
    wall_t0 = BK.mono
    pool.times do |i|
      rr, rw = IO.pipe; hr, hw = IO.pipe
      ios.push(rr, rw, hr, hw)                            # track BEFORE fork so a mid-loop fork failure cannot leak fds
      pids << fork do
        rr.close; hw.close
        out = work(dataset, shape, count, shards[i], alloc, BK.mono + dur)  # each child stamps its own deadline post-fork
        steady_gc.times { GC.start }                      # settle steady-state (post-work; excluded from the work_wall basis)
        Marshal.dump(out, rw); rw.close
        hr.read(1); exit!(0)
      end
      rw.close; hr.close
      res_r << rr; hold_w << hw
    end
    results = res_r.map { |r| Marshal.load(r.read) }
    gen_wall = BK.mono - wall_t0                          # fork -> all-work+settle done (one-time/recurring overhead, NOT the work basis)
    s0 = BK.mono
    mem = MEM ? sum_mem([Process.pid, *pids]) : nil       # steady-state PSS of the whole held tree
    snap_s = BK.mono - s0
    hold_w.each { |w| w.write("x") }; released = true
    { results: results, mem: mem, gen_wall: gen_wall, snap_s: snap_s,
      work_wall: results.map { _1[:elapsed] }.max }       # honest drain time of the barrier-joined pool
  ensure
    ios.each { |io| io.close unless io.closed? }
    pids.each { |p| (Process.kill("KILL", p) rescue nil) unless released; Process.wait(p) rescue nil }
  end
end

# ---------- models (all return: results, mem, work_wall, recurring_fork_s, prep_s, gens, intervals) ----------
STATIC_PREPS = {
  "process_naive"                  => -> {},
  "process_gc_compact"             => -> { GC.start; GC.compact },
  "process_warmup"                 => -> { Process.warmup },
  "process_gc_compact_plus_warmup" => -> { GC.start; GC.compact; Process.warmup },
  # Process.warmup already compacts + ages survivors to old-gen; the extra full-mark GCs rarely change steady CoW, so this
  # is usually ~equal to compact+warmup. Kept as a control that the warmed mold is already maximal (see header).
  "process_prefork_warmed"         => -> { GC.start(full_mark: true, immediate_sweep: true); GC.compact; Process.warmup; 2.times { GC.start(full_mark: true) } },
}.freeze

def run_static(dataset, shape, count, pool, alloc, prep)
  p0 = BK.mono; prep.call; prep_s = BK.mono - p0
  g = run_generation(dataset, shape, count, pool, alloc, DURATION, steady_gc: STEADY_GC)
  { results: g[:results], mem: g[:mem], work_wall: g[:work_wall], recurring_fork_s: nil,
    prep_s: prep_s, gens: 1, intervals: [] }
end

def run_refork(dataset, shape, count, pool, alloc)
  p0 = BK.mono; GC.start; Process.warmup; prep_s = BK.mono - p0   # warm mold; parent never runs the loop -> stays clean
  all = []; mem_samples = []; intervals = []; total_gen_wall = 0.0; total_work_wall = 0.0; gens = 0; t0 = BK.mono
  while BK.mono - t0 < DURATION
    g = run_generation(dataset, shape, count, pool, alloc, (REFORK_EVERY_S > 0 ? REFORK_EVERY_S : DURATION), steady_gc: STEADY_GC)
    all.concat(g[:results]); mem_samples << g[:mem] if g[:mem]
    intervals << g[:gen_wall]; total_gen_wall += g[:gen_wall]; total_work_wall += g[:work_wall]; gens += 1
  end
  { results: all, mem: (mem_samples.empty? ? nil : median_mem(mem_samples)), work_wall: total_work_wall,
    recurring_fork_s: total_gen_wall - total_work_wall, prep_s: prep_s, gens: gens, intervals: intervals }
end

def run_ractor(shareable, shape, count, pool, alloc)
  ready = Ractor::Port.new
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }
  rs = pool.times.map do |i|
    Ractor.new(shareable, shape, count, shards[i], alloc, DURATION, ready) do |ds, shp, cnt, sh, al, dur, rdy|
      out = work(ds, shp, cnt, sh, al, BK.mono + dur)     # each Ractor stamps its own deadline after it starts (symmetric with fork children)
      h = Ractor::Port.new; rdy.send([out, h]); h.receive; out
    end
  end
  collected = pool.times.map { ready.receive }
  STEADY_GC.times { GC.start }                            # settle steady-state (process-global GC covers every Ractor)
  mem = MEM ? sum_mem([Process.pid]) : nil                # single process — the whole point of the thesis
  collected.each { |(_o, h)| h.send(:go) }
  rs.each(&:value)
  results = collected.map(&:first)
  { results: results, mem: mem, work_wall: results.map { _1[:elapsed] }.max, recurring_fork_s: nil,
    prep_s: nil, gens: 1, intervals: [] }
end

def run_model(model, shape, n, pool, alloc)
  if model.start_with?("ractor")
    BK.isolated do
      ds0 = build_dataset(shape, n)
      p0 = BK.mono; ds = Ractor.make_shareable(ds0); prep_s = BK.mono - p0
      run_ractor(ds, shape, count_of(ds, shape), pool, alloc).merge(prep_s: prep_s)
    end
  elsif model == "process_refork"
    BK.isolated { ds = build_dataset(shape, n); run_refork(ds, shape, count_of(ds, shape), pool, alloc) }
  else
    prep = STATIC_PREPS.fetch(model)
    BK.isolated { ds = build_dataset(shape, n); run_static(ds, shape, count_of(ds, shape), pool, alloc, prep) }
  end
end

# ---------- throughput / correctness / frontier ----------
def tput(m) = m[:results].sum { _1[:done] } / m[:work_wall]   # ONE basis for every model: total work / honest drain wall
def correct?(m, oracle)
  return false unless m[:results].all? { _1[:full_pass] }
  expected = oracle * m[:gens]
  (m[:results].sum { _1[:cksum] } - expected).abs <= expected.abs * 1e-9 + 1e-3
end
def gc_sum(results) = { count: results.sum { _1[:gc_count] }, objs: results.sum { _1[:alloc_objs] } }
def pctl(xs, q)
  return nil if xs.empty?
  s = xs.sort; s[(q * (s.length - 1)).round]
end

# REPS runs of one (model, shape, n, pool, alloc) cell -> aggregated stats
def measure_cell(model, shape, n, pool, alloc, oracle)
  rows = Array.new(REPS) { run_model(model, shape, n, pool, alloc) }
  ts = rows.map { tput(_1) }
  mems = rows.map { _1[:mem] }.compact
  intervals = rows.flat_map { _1[:intervals] }
  {
    model: model, pool: pool, alloc: alloc,
    tput: BK.median(ts), tlo: ts.min, thi: ts.max,
    mem: mems.empty? ? nil : median_mem(mems),
    pss_lo: mems.empty? ? nil : mems.map { _1[:pss] }.min,   # PSS band across REPS — feeds the memory-variance gate
    pss_hi: mems.empty? ? nil : mems.map { _1[:pss] }.max,
    correct: rows.all? { correct?(_1, oracle) },
    gens_median: BK.median(rows.map { _1[:gens] }),
    prep_s: BK.median(rows.map { _1[:prep_s] || 0 }),
    recurring_fork_s: BK.median(rows.map { _1[:recurring_fork_s] || 0 }),
    gc: { count: BK.median(rows.map { gc_sum(_1[:results])[:count] }), objs: BK.median(rows.map { gc_sum(_1[:results])[:objs] }) },
    refork_interval_p50_s: pctl(intervals, 0.5), refork_interval_p95_s: pctl(intervals, 0.95),
  }
end

# interpolate a model's steady PSS (kB) at throughput t along its workers frontier; reachable? = t within the frontier
def frontier_reaches?(points, t) = points.reject { _1[:mem].nil? }.map { _1[:tput] }.max.to_f >= t
def iso_at(points, t)   # interpolate any per-point value (yielded) at throughput t along the workers frontier
  s = points.reject { _1[:mem].nil? }.sort_by { _1[:tput] }
  return nil if s.empty?
  return (yield s.first).to_f if t <= s.first[:tput]
  return (yield s.last).to_f  if t >= s.last[:tput]
  hi = s.find { _1[:tput] >= t }; lo = s.reverse.find { _1[:tput] <= t }
  ylo = yield(lo); yhi = yield(hi)
  ylo + (t - lo[:tput]) / (hi[:tput] - lo[:tput]).to_f * (yhi - ylo)
end
def iso_mem(points, t)    = iso_at(points, t) { |p| p[:mem][:pss] }   # median PSS frontier
def iso_pss_lo(points, t) = iso_at(points, t) { |p| p[:pss_lo] }      # lower PSS envelope (best-for-thesis baseline)
def iso_pss_hi(points, t) = iso_at(points, t) { |p| p[:pss_hi] }      # upper PSS envelope (worst-for-thesis baseline)

# run_class is an OPERATIONAL label for the SHAPE of the run, NOT an economic verdict. "full_host" only means the config
# (REPS/DURATION/TARGETS) is large enough to be a candidate full gate; it does NOT assert the economy. A full ECONOMIC
# claim may ONLY be made by the verifier's check_strong_host_gate_v2_full (full config + same hardened gates) — never by
# the runner emitting "full_host", and the reduced verifier check refuses to bless a full artifact.
def run_class
  return "smoke" unless MEM
  full = REPS >= 6 && DURATION >= 8 && TARGETS.max >= 500
  full ? "full_host" : "reduced"
end

# ---------- verdict: ractor_frozen_image vs the STRONGEST process baseline, at iso-throughput ----------
def verdict_for(shape, target_mb, measured_mb, alloc, frontier)
  base = { shape: shape, dataset_target_mb: target_mb, dataset_measured_mb: measured_mb, alloc: alloc, mem_measured: MEM }
  ractor = (frontier["ractor_frozen_image"] || []).reject { _1[:tput].nil? }
  return base.merge(status: "no_ractor_model", reason: "ractor_frozen_image not in MODELS") if ractor.empty?
  if frontier.values.flatten.any? { !_1[:correct] }
    return base.merge(status: "invalid", reason: "a model failed correctness (raise DURATION or lower WORKERS)")
  end
  rb = ractor.max_by { _1[:tput] }
  process_models = frontier.keys.reject { _1.start_with?("ractor") }
  proc_cells = process_models.flat_map { frontier[_1] }
  unless MEM
    return base.merge(status: "smoke_no_memory",
                      reason: "throughput/correctness only (not Linux); ractor best #{rb[:tput].round} items/s @ #{rb[:pool]}w - NO economic verdict",
                      ractor_best: { workers: rb[:pool], throughput_items_s: rb[:tput] })
  end

  # reach band: anchor to the SINGLE strongest-throughput process cell (commensurable lo/median/hi)
  proc_max_cell = proc_cells.max_by { _1[:tput] }
  proc_max_tput = proc_max_cell[:tput]
  reach    = rb[:tput] / proc_max_tput
  reach_lo = rb[:tlo] / proc_max_cell[:thi]
  reach_hi = rb[:thi] / proc_max_cell[:tlo]

  # reachable baselines = those whose workers frontier actually REACHES the ractor throughput (no extrapolation).
  # If NONE reach it the comparison is an extrapolation -> force inconclusive (never survives); extend the frontier.
  reachable = process_models.select { |m| frontier_reaches?(frontier[m], rb[:tput]) }
  extrapolated = reachable.empty?
  pool_for_iso = extrapolated ? process_models : reachable

  # REPORTED baseline = lowest MEDIAN iso-PSS among the reachable baselines (this is what the docs/numbers cite).
  isos = pool_for_iso.map { |m| [m, iso_mem(frontier[m], rb[:tput])] }.reject { |_m, v| v.nil? }
  return base.merge(status: "invalid", reason: "no process baseline produced memory") if isos.empty?
  strongest_model, strongest_pss = isos.min_by { |_m, v| v }
  sf = frontier[strongest_model]
  strongest_pss_lo = iso_pss_lo(sf, rb[:tput])
  strongest_pss_hi = iso_pss_hi(sf, rb[:tput])

  # ADVERSARIAL lower envelope (P1 false-survives guard): the LOWEST iso_pss_lo across ALL reachable baselines — NOT
  # just the reported (median-selected) one. A different baseline can have a deeper lower envelope; the worst-case PASS
  # must pit the Ractor's WORST PSS against the single most baseline-favorable lower bound, or a near-threshold full run
  # passes because the median picked a conveniently-high baseline. If any reachable baseline's lower envelope crosses the
  # gate, ratio_hi/saving_lo reflect it -> the status can only be survives when EVEN that baseline is beaten.
  adv_model, adversarial_pss_lo =
    pool_for_iso.map { |m| [m, iso_pss_lo(frontier[m], rb[:tput])] }.reject { |_m, v| v.nil? }.min_by { |_m, v| v } ||
    [strongest_model, strongest_pss_lo]

  ratio  = rb[:mem][:pss] / strongest_pss          # REPORTED ratio  (ractor median vs reported-baseline median)
  saving = MB[strongest_pss - rb[:mem][:pss]]       # REPORTED saving (reported-baseline median - ractor median)
  # memory-variance bands across REPS — ratio_hi / saving_lo are the THESIS-WORST cases and use the ADVERSARIAL baseline's
  # lowest lower envelope; ratio_lo / saving_hi (thesis-best) use the reported baseline's upper envelope. survives requires
  # the WORST case to clear every gate, so neither a convenient median NOR a convenient baseline can sneak a pass through.
  ratio_lo  = rb[:pss_lo] / strongest_pss_hi
  ratio_hi  = rb[:pss_hi] / adversarial_pss_lo
  saving_lo = MB[adversarial_pss_lo - rb[:pss_hi]]
  saving_hi = MB[strongest_pss_hi - rb[:pss_lo]]
  # per-gate state: pass = worst case clears; fail = best case misses; straddle = band brackets the gate
  ratio_state  = ratio_hi <= PSS_RATIO_MAX ? :pass : (ratio_lo > PSS_RATIO_MAX ? :fail : :straddle)
  saving_state = saving_lo >= SAVING_MB_MIN ? :pass : (saving_hi < SAVING_MB_MIN ? :fail : :straddle)
  reach_state  = reach_lo >= REACH_MIN ? :pass : (reach_hi < REACH_MIN ? :fail : :straddle)
  overall_straddle = [ratio_state, saving_state, reach_state].include?(:straddle)

  # per-worker: report a MEDIAN ratio for transparency, but a FINAL win (`wins`) requires the PESSIMISTIC per-worker gate
  # (ractor WORST PSS vs the adversarial lowest baseline lower-envelope at THAT worker's throughput, plus pessimistic
  # reach) AND no overall extrapolation/straddle. `median_wins` keeps the optimistic median view visible; it is NOT a
  # final win and must never be cited as one. (P1: per-worker false-survives guard.)
  per_worker = ractor.sort_by { _1[:pool] }.map do |rc|
    iso_med = iso_mem(sf, rc[:tput])                                                    # reported baseline median PSS here
    w_lo    = pool_for_iso.map { |m| iso_pss_lo(frontier[m], rc[:tput]) }.compact.min    # adversarial lower envelope here
    r_med   = iso_med ? (rc[:mem][:pss] / iso_med) : nil
    r_pess  = w_lo ? (rc[:pss_hi] / w_lo) : nil
    reach_w      = rc[:tput] / proc_max_tput
    reach_w_pess = rc[:tlo] / proc_max_cell[:thi]                                        # pessimistic reach for this worker
    median_wins = !!(r_med && iso_med && r_med <= PSS_RATIO_MAX && MB[iso_med - rc[:mem][:pss]] >= SAVING_MB_MIN && reach_w >= REACH_MIN)
    pess_wins   = !!(r_pess && w_lo && r_pess <= PSS_RATIO_MAX && MB[w_lo - rc[:pss_hi]] >= SAVING_MB_MIN && reach_w_pess >= REACH_MIN)
    { workers: rc[:pool], throughput_items_s: rc[:tput], pss_mb: MB[rc[:mem][:pss]],
      strongest_iso_pss_mb: MB[iso_med], adversarial_iso_pss_lo_mb: MB[w_lo],
      ratio: r_med&.round(3), ratio_pessimistic: r_pess&.round(3),
      reach: reach_w.round(3), reach_pessimistic: reach_w_pess.round(3),
      median_wins: median_wins, wins: pess_wins && !extrapolated && !overall_straddle }
  end
  winning_workers        = per_worker.select { _1[:wins] }.map { _1[:workers] }
  median_winning_workers = per_worker.select { _1[:median_wins] }.map { _1[:workers] }
  losing_workers         = per_worker.select { |w| w[:ratio] && w[:ratio] > 1.0 }.map { _1[:workers] }

  status, reason =
    if extrapolated
      ["inconclusive", "no process baseline reaches the ractor throughput within the tested frontier (#{strongest_model} maxes below it) — raise WORKERS / expand the frontier, do NOT extrapolate a clamped baseline"]
    elsif ratio_state == :fail || saving_state == :fail
      if strongest_pss <= rb[:mem][:pss]
        ["kill", "strongest baseline (#{strongest_model}) already uses <= ractor PSS at iso-throughput — CoW closes the gap"]
      else
        ["pivot", "ractor PSS #{(ratio * 100).round}% (gate <=#{(PSS_RATIO_MAX * 100).round}%), saving #{saving}MB (gate >=#{SAVING_MB_MIN.round}MB) — a memory gate fails vs #{strongest_model}"]
      end
    elsif reach_state == :fail
      ["pivot", "ractor reaches only #{(reach * 100).round}% of #{proc_max_cell[:model]} throughput (gate >=#{(REACH_MIN * 100).round}%) — throughput gate fails"]
    elsif overall_straddle
      straddlers = { ratio: ratio_state, saving: saving_state, reach: reach_state }.select { |_k, v| v == :straddle }.keys
      ["inconclusive", "result straddles the gate on #{straddlers.join("+")} across REPS (ratio #{ratio_lo.round(2)}..#{ratio_hi.round(2)}, saving #{saving_lo}..#{saving_hi}MB, reach #{reach_lo.round(2)}..#{reach_hi.round(2)}) — raise REPS/DURATION; do NOT pass on a convenient median"]
    elsif winning_workers.empty?
      ["inconclusive", "aggregate worst-case bands clear but NO worker passes the PESSIMISTIC per-worker gate (ratio/saving/reach vs the adversarial baseline #{adv_model}) — the operating-point win is not robust; raise REPS/DURATION or expand WORKERS, do NOT promote on the aggregate alone"]
    else
      ["survives", "ractor PSS #{(ratio * 100).round}% of reported baseline (#{strongest_model}) at #{(reach * 100).round}% reach, saving #{saving}MB; the WORST-case REPS band vs the ADVERSARIAL baseline (#{adv_model}) still clears every gate (ratio <=#{(PSS_RATIO_MAX * 100).round}%, saving >=#{SAVING_MB_MIN.round}MB, reach >=#{(REACH_MIN * 100).round}%); pessimistic wins at #{winning_workers.inspect} workers#{losing_workers.empty? ? "" : ", LOSES at #{losing_workers.inspect}"}"]
    end

  base.merge(
    status: status, reason: reason,
    ractor_best: { workers: rb[:pool], throughput_items_s: rb[:tput], pss_mb: MB[rb[:mem][:pss]],
                   pss_lo_mb: MB[rb[:pss_lo]], pss_hi_mb: MB[rb[:pss_hi]],
                   private_dirty_mb: MB[rb[:mem][:pdirty]], shared_clean_mb: MB[rb[:mem][:sclean]] },
    strongest_baseline: { model: strongest_model, iso_pss_mb: MB[strongest_pss],
                          iso_pss_lo_mb: MB[strongest_pss_lo], iso_pss_hi_mb: MB[strongest_pss_hi],
                          extrapolated_out_of_range: extrapolated },
    # the single most baseline-favorable lower bound the worst-case PASS was tested against (may differ from the reported baseline)
    adversarial_baseline: { model: adv_model, iso_pss_lo_mb: MB[adversarial_pss_lo] },
    process_max_throughput_cell: { model: proc_max_cell[:model], workers: proc_max_cell[:pool], throughput_items_s: proc_max_tput },
    pss_ratio: ratio, pss_ratio_percent: (ratio * 100).round(1), pss_ratio_band: [ratio_lo.round(3), ratio_hi.round(3)],
    throughput_reach: reach, throughput_reach_percent: (reach * 100).round(1),
    throughput_reach_min: reach_lo, throughput_reach_max: reach_hi,
    absolute_saving_mb: saving, absolute_saving_band_mb: [saving_lo, saving_hi],
    gate_states: { ratio: ratio_state, saving: saving_state, reach: reach_state },
    win_is_single_operating_point: winning_workers.size <= 1,
    ractor_wins_at_workers: winning_workers,                 # PESSIMISTIC final wins (gate the verdict cites)
    ractor_median_wins_at_workers: median_winning_workers,   # optimistic median view (informational only, NOT a final win)
    ractor_loses_at_workers: losing_workers,
    per_worker: per_worker,
  )
end

# ---------- dataset target -> N calibration (Linux: measured bytes/record; else override or smoke N) ----------
def bytes_per_record(shape)
  BK.isolated do
    base = MEM ? smaps_full[:pss] : 0
    ds = build_dataset(shape, CALIB_N0)
    GC.start
    cnt = count_of(ds, shape)
    after = MEM ? smaps_full[:pss] : 0
    [(after - base) * 1024.0 / cnt, cnt]
  end
end

SMOKE_N = { hash: 120_000, struct: 120_000, blob: 1_500_000 }.freeze
def n_for(shape, target_mb)
  if (ov = N_OVERRIDE.call(shape)) then return ov end
  return SMOKE_N.fetch(shape, 120_000) unless MEM   # macOS smoke: fixed small N, memory not measured anyway
  bpr, = bytes_per_record(shape)
  [(target_mb * 1024 * 1024 / bpr).round, SCAN + 1].max
end

# ---------- startup drift-lock: v2's hash compute must match the SHA-pinned bench_kernel hash kernel ----------
def assert_kernel_parity!
  n = SCAN + 50
  ds = build_dataset(:hash, n); cnt = count_of(ds, :hash)
  items = BK.make_items(ITEMS)
  mine = items.sum { |it| compute(ds, :hash, cnt, it) }.round(6)
  theirs = items.sum { |it| BK.compute(ds, cnt, it, SCAN) }.round(6)
  abort "KERNEL DRIFT: v2 hash compute #{mine} != bench_kernel #{theirs}" unless (mine - theirs).abs <= 1e-6
end

# ---------- driver ----------
assert_kernel_parity!
log "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) — STRONG HOST-LINUX ECONOMIC GATE v2 — run_class=#{run_class} mem_measured=#{MEM}"
log "SHAPES=#{SHAPES.inspect} TARGETS_MB=#{TARGETS.inspect} ALLOCS=#{ALLOCS.inspect} WORKERS=#{WORKERS.inspect}"
log "MODELS=#{MODELS.inspect} ITEMS=#{ITEMS} SCAN=#{SCAN} DURATION=#{DURATION}s REPS=#{REPS} REFORK_EVERY_S=#{REFORK_EVERY_S} STEADY_GC=#{STEADY_GC}"
log "gates: ractor PSS <= #{(PSS_RATIO_MAX * 100).round}% of strongest baseline AND saving >= #{SAVING_MB_MIN.round}MB AND reach >= #{(REACH_MIN * 100).round}%"
log "runner_sha256=#{Digest::SHA256.file(__FILE__).hexdigest} json_out=#{JSON_OUT}"
log "NOTE: not Linux -> memory NOT measured; throughput/correctness only (SMOKE). No macOS result feeds a memory claim." unless MEM
log ""

aggregate = {
  ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, mem_measured: MEM, run_class: run_class,
  claim_policy: "run_class is an operational label only; a full economic claim requires the verifier's check_strong_host_gate_v2_full, never the runner emitting full_host",
  runner_sha256: Digest::SHA256.file(__FILE__).hexdigest,
  generated_at_utc: Time.now.utc.iso8601,
  config: { shapes: SHAPES, targets_mb: TARGETS, allocs: ALLOCS, workers: WORKERS, models: MODELS,
            items: ITEMS, scan: SCAN, duration_s: DURATION, reps: REPS, refork_every_s: REFORK_EVERY_S, steady_gc: STEADY_GC },
  gates: { pss_ratio_max: PSS_RATIO_MAX, absolute_saving_mb_min: SAVING_MB_MIN, throughput_reach_min: REACH_MIN },
  cells: [], verdicts: [],
}

SHAPES.each do |shape|
  TARGETS.each do |target_mb|
    n = n_for(shape, target_mb)
    measured_mb = nil
    if MEM
      bpr, = bytes_per_record(shape)
      measured_mb = (n * bpr / 1024.0 / 1024.0).round(1)
    end
    oracle = BK.isolated do
      ds = build_dataset(shape, n); cnt = count_of(ds, shape)
      BK.make_items(ITEMS).sum { |it| compute(ds, shape, cnt, it) }.round(4)
    end
    log "==================== shape=#{shape} target=#{target_mb}MB N=#{n}#{measured_mb ? " (measured ~#{measured_mb}MB)" : " (smoke)"} ===================="

    ALLOCS.each do |alloc|
      frontier = Hash.new { |h, k| h[k] = [] }
      log "  -- alloc=#{alloc} --"
      log format("  %-30s %5s %11s %9s %9s %9s %9s %9s %6s", "model", "wkrs", "items/s", "PSS_MB", "Pdirty", "Sclean", "Sdirty", "RSS", "ok")
      WORKERS.each do |pool|
        MODELS.each do |model|
          c = measure_cell(model, shape, n, pool, alloc, oracle)
          frontier[model] << c
          mem = c[:mem]
          cell_rec = {
            shape: shape, dataset_target_mb: target_mb, dataset_measured_mb: measured_mb, n_rules: n,
            alloc: alloc, workers: pool, model: model, mode: (model.start_with?("ractor") ? "ractor" : "process"),
            ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, mem_measured: MEM, run_class: run_class,
            duration_s: DURATION, reps: REPS,
            throughput_items_s: c[:tput], throughput_min_items_s: c[:tlo], throughput_max_items_s: c[:thi],
            pss_kb: mem&.dig(:pss), pss_mb: MB[mem&.dig(:pss)],
            pss_lo_mb: MB[c[:pss_lo]], pss_hi_mb: MB[c[:pss_hi]],
            private_dirty_kb: mem&.dig(:pdirty), private_dirty_mb: MB[mem&.dig(:pdirty)],
            shared_clean_kb: mem&.dig(:sclean), shared_clean_mb: MB[mem&.dig(:sclean)],
            shared_dirty_kb: mem&.dig(:sdirty), shared_dirty_mb: MB[mem&.dig(:sdirty)],
            rss_kb: mem&.dig(:rss), rss_mb: MB[mem&.dig(:rss)],
            correct: c[:correct], gc_count: c[:gc][:count], allocated_objects: c[:gc][:objs],
            startup_prep_s: c[:prep_s], recurring_fork_s: c[:recurring_fork_s], gens_median: c[:gens_median],
            refork_interval_p50_s: c[:refork_interval_p50_s], refork_interval_p95_s: c[:refork_interval_p95_s],
          }
          aggregate[:cells] << cell_rec
          cell_id = "#{shape}_t#{target_mb.to_i}_a#{alloc}_w#{pool}_#{model}"
          File.write(File.join(OUT_DIR, "#{cell_id}.json"), JSON.pretty_generate(cell_rec))
          log format("  %-30s %5d %11.0f %9s %9s %9s %9s %9s %6s", model, pool, c[:tput],
                     MB[mem&.dig(:pss)] || "n/a", MB[mem&.dig(:pdirty)] || "n/a", MB[mem&.dig(:sclean)] || "n/a",
                     MB[mem&.dig(:sdirty)] || "n/a", MB[mem&.dig(:rss)] || "n/a", c[:correct] ? "yes" : "NO")
        end
      end

      verdict = verdict_for(shape, target_mb, measured_mb, alloc, frontier)
      aggregate[:verdicts] << verdict
      log "  -> #{verdict[:status].upcase}: #{verdict[:reason]}"
      log ""
    end
  end
end

if JSON_OUT
  File.write(JSON_OUT, JSON.pretty_generate(aggregate))
  log "JSON written: #{JSON_OUT}"
end
log "per-cell JSON: #{OUT_DIR}/  raw log: #{RAW_LOG}"
LOG_IO.close
