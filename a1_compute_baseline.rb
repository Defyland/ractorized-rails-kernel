# frozen_string_literal: true
#
# a1_compute_baseline.rb — Ractorized Rails Kernel · Slice A1
#
# QUESTION A1 answers: on CPU-bound compute over a LARGE, read-only, FROZEN/shareable
# dataset, does a Ractor pool match a PROCESS pool on throughput? (Memory/PSS is the
# decisive gate and is Linux-only — measured by the companion harness inside colima.)
#
# Three execution models over the SAME work:
#   - ractors : 1 process, N Ractors, dataset frozen+shareable (pass-by-reference)
#   - procs   : fork N workers AFTER loading the dataset (read-only → CoW shares it)
#   - threads : N threads sharing the dataset — NEGATIVE CONTROL (GVL serializes CPU Ruby)
#
# Knobs (env): N_RULES, N_ITEMS, SCAN (cpu per item), POOL, REPS.
#
#   ruby a1_compute_baseline.rb
#   N_RULES=400000 N_ITEMS=4000 SCAN=6000 ruby a1_compute_baseline.rb

require "etc"

CORES   = Etc.nprocessors
N_RULES = Integer(ENV.fetch("N_RULES", 200_000))
N_ITEMS = Integer(ENV.fetch("N_ITEMS", 2_000))
SCAN    = Integer(ENV.fetch("SCAN",    4_000))   # rules scanned per item — the CPU knob
POOL    = Integer(ENV.fetch("POOL",    CORES))
REPS    = Integer(ENV.fetch("REPS",    3))

# --- large read-only dataset (the "frozen pricing ruleset") ---
def build_dataset(n)
  Array.new(n) do |i|
    { id: i, threshold: i % 1000, factor: ((i * 37) % 100) / 100.0, base: (i % 50) }
  end
end

# --- pure CPU-bound compute for one item over a window of the dataset ---
# References only the SCAN constant (Integer = shareable) + its args → Ractor-safe.
def compute_item(dataset, item)
  start = item[:seed] % (dataset.length - SCAN)
  acc = 0.0
  SCAN.times do |k|
    r = dataset[start + k]
    acc += r[:factor] * (item[:value] + r[:base]) if item[:value] > r[:threshold]
  end
  { id: item[:id], total: acc.round(4) }
end

def chunks_of(items, pool)
  items.each_slice((items.size / pool.to_f).ceil).to_a
end

# --- NEGATIVE CONTROL: threads share the GVL for CPU-bound Ruby → ~1x ---
def run_threads(dataset, items, pool)
  out = []; mtx = Mutex.new
  chunks_of(items, pool).map { |chunk|
    Thread.new { part = chunk.map { |it| compute_item(dataset, it) }; mtx.synchronize { out.concat(part) } }
  }.each(&:join)
  out
end

# --- PROCESS pool: dataset shared via copy-on-write after fork ---
def run_processes(dataset, items, pool)
  readers = []; pids = []
  chunks_of(items, pool).each do |chunk|
    r, w = IO.pipe
    pids << fork do
      r.close
      Marshal.dump(chunk.map { |it| compute_item(dataset, it) }, w)
      w.close
      exit!(0)
    end
    w.close
    readers << r
  end
  # drain concurrently to avoid pipe-buffer deadlock
  bufs = readers.map { |r| Thread.new { d = r.read; r.close; d } }.map(&:value)
  pids.each { |pid| Process.wait(pid) }
  bufs.flat_map { |d| Marshal.load(d) }
end

# --- RACTOR pool: dataset frozen+shareable, passed by reference; small input copied ---
def run_ractors(frozen_dataset, items, pool)
  chunks_of(items, pool).map { |chunk|
    Ractor.new(frozen_dataset, chunk) do |ds, ch|
      ch.map { |it| compute_item(ds, it) }
    end
  }.flat_map(&:value)
end

def timed
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = yield
  [r, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0]
end

def best_of(reps)
  (1..reps).map { yield }.min
end

puts "Ruby #{RUBY_VERSION} (#{RUBY_ENGINE}) cores=#{CORES} pool=#{POOL}"
puts "N_RULES=#{N_RULES} N_ITEMS=#{N_ITEMS} SCAN=#{SCAN} REPS=#{REPS} " \
     "(=#{N_ITEMS * SCAN} inner ops/run)"
puts

dataset = build_dataset(N_RULES)
items   = Array.new(N_ITEMS) { |i| { id: i, seed: i * 7919, value: (i * 13) % 1500 } }

# correctness oracle (single-threaded)
oracle, t_seq = timed { items.map { |it| compute_item(dataset, it) } }
oracle_sig = oracle.sum { |r| r[:total] }.round(2)

frozen = Ractor.make_shareable(build_dataset(N_RULES))

runs = {
  "threads (control)" => -> { run_threads(dataset, items, POOL) },
  "processes (CoW)"   => -> { run_processes(dataset, items, POOL) },
  "ractors (frozen)"  => -> { run_ractors(frozen, items, POOL) },
}

printf "%-20s %10s %12s %9s  %s\n", "model", "best_s", "items/s", "speedup", "correct?"
printf "%-20s %10.3f %12.0f %9s  %s\n", "sequential", t_seq, (N_ITEMS / t_seq), "1.00x", "oracle"
runs.each do |name, fn|
  best = best_of(REPS) do
    res, t = timed { fn.call }
    @last = res
    t
  end
  sig = @last.sum { |r| r[:total] }.round(2)
  ok  = (sig == oracle_sig) ? "yes" : "NO(#{sig}!=#{oracle_sig})"
  printf "%-20s %10.3f %12.0f %8.2fx  %s\n", name, best, (N_ITEMS / best), (t_seq / best), ok
end

puts "\nNote: throughput axis only. The DECISIVE gate (PSS / Private_Dirty, Ractor vs"
puts "process pool) is Linux-only and runs in colima — RSS on macOS misrepresents CoW."
