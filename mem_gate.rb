# frozen_string_literal: true
#
# mem_gate.rb — Ractorized Rails Kernel · Slice A1 · THE DECISIVE GATE (Linux only)
#
# QUESTION: holding ONE large read-only frozen dataset, does a Ractor pool use
# materially less memory than a PROCESS pool? The crux is CoW: forked workers
# share the dataset via copy-on-write, BUT Ruby's GC marks objects, and a
# non-compacting mark flips shared-clean pages to PRIVATE-DIRTY — silently
# multiplying real memory toward N×dataset. Ractors share ONE heap, so the dataset
# is counted once. We measure PSS / Private_Dirty from /proc to see which wins.
#
# Each model runs in its OWN isolated child process (no cross-contamination of heaps).
#
# Run INSIDE Linux (colima/docker), not macOS:
#   docker run --rm -v "$PWD":/app -w /app ruby:4.0-slim ruby mem_gate.rb

abort "Linux only — no /proc/smaps_rollup on #{RUBY_PLATFORM}" unless File.exist?("/proc/self/smaps_rollup")

N_RULES     = Integer(ENV.fetch("N_RULES", 1_000_000))
POOL        = Integer(ENV.fetch("POOL", `nproc`.to_i.clamp(2, 8)))
GC_PRESSURE = Integer(ENV.fetch("GC_PRESSURE", 3))   # GC cycles per worker (steady-state sim)
TOUCH       = Integer(ENV.fetch("TOUCH", 200_000))   # dataset elements each worker reads

# DEPRECATED — superseded by frontier_harness.rb (frontier 1..N + iso-throughput + reps + median +
# fail-loud smaps + absolute-saving gate). This script measured only a single 4-vs-N point. Kept for
# history; do not cite its numbers as the gate.
unless ENV["RUN_DEPRECATED"]
  abort "DEPRECATED: use frontier_harness.rb (the real gate). Set RUN_DEPRECATED=1 to run this anyway."
end

def build_dataset(n)
  Array.new(n) { |i| { id: i, threshold: i % 1000, factor: ((i * 37) % 100) / 100.0, base: (i % 50) } }
end

def smaps(pid = Process.pid)
  txt = File.read("/proc/#{pid}/smaps_rollup")
  g = ->(k) { txt[/^#{k}:\s+(\d+)\s+kB/, 1] || raise("smaps: field #{k} missing for pid #{pid}") }
  { pss: g["Pss"].to_i, pdirty: g["Private_Dirty"].to_i, sclean: g["Shared_Clean"].to_i, sdirty: g["Shared_Dirty"].to_i }
rescue Errno::ENOENT
  raise "smaps: process #{pid} gone before snapshot (OOM/crash?) — measurement invalid"
end

def worker_touch(dataset)
  s = 0
  TOUCH.times { |k| s += dataset[k % dataset.length][:base] }  # force reads of shared pages
  GC_PRESSURE.times { GC.start }                               # mark over the heap (CoW killer)
  s
end

# run a block in a clean isolated child; return its Marshal-able result
def isolated
  r, w = IO.pipe
  pid = fork do
    r.close
    w.write(Marshal.dump(yield)); w.close
    exit!(0)
  end
  w.close
  data = r.read; r.close
  Process.wait(pid)
  Marshal.load(data)
end

def process_model(warmup:)
  dataset = build_dataset(N_RULES)
  GC.start
  # Process.warmup (Ruby 3.3+) pre-promotes to old gen + compacts before fork —
  # the standard CoW-protection used by Pitchfork/Puma. This is the STRONG baseline.
  Process.warmup if warmup
  dataset_mb = smaps[:pss]
  readers = []; pids = []
  POOL.times do
    r, w = IO.pipe
    pids << fork do
      r.close
      worker_touch(dataset)
      w.write(Marshal.dump(smaps)); w.close
      exit!(0)
    end
    w.close; readers << r
  end
  parent = smaps
  kids = readers.map { |r| d = r.read; r.close; Marshal.load(d) }
  pids.each { |p| Process.wait(p) }
  { pss: parent[:pss] + kids.sum { |c| c[:pss] },
    pdirty: parent[:pdirty] + kids.sum { |c| c[:pdirty] },
    sclean: kids.sum { |c| c[:sclean] },
    one_proc_pss: dataset_mb }
end

def ractor_model
  frozen = Ractor.make_shareable(build_dataset(N_RULES))
  gate = Ractor::Port.new
  ractors = POOL.times.map do
    Ractor.new(frozen, gate) do |ds, g|
      worker_touch(ds)
      rp = Ractor::Port.new
      g.send([:ready, rp])
      rp.receive                 # stay ALIVE while main snapshots
    end
  end
  replies = POOL.times.map { _t, rp = gate.receive; rp }  # all alive
  GC.start
  snap = smaps                                            # ONE process = all Ractors
  replies.each { |rp| rp.send(:go) }
  ractors.each(&:value)
  snap
end

mb = ->(kb) { (kb / 1024.0).round(1) }

puts "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) pool=#{POOL} N_RULES=#{N_RULES} " \
     "gc_pressure=#{GC_PRESSURE} touch=#{TOUCH}"
pr  = isolated { process_model(warmup: false) }
prw = isolated { process_model(warmup: true) }
ra  = isolated { ractor_model }

puts
puts "single dataset footprint ≈ #{mb[pr[:one_proc_pss]]}MB"
puts
printf "%-26s %12s %14s %13s\n", "model", "total_PSS", "private_dirty", "shared_clean"
printf "%-26s %10.1fMB %12.1fMB %11.1fMB\n", "process pool (naive fork)",
       mb[pr[:pss]], mb[pr[:pdirty]], mb[pr[:sclean]]
printf "%-26s %10.1fMB %12.1fMB %11.1fMB\n", "process pool (warmup/CoW)",
       mb[prw[:pss]], mb[prw[:pdirty]], mb[prw[:sclean]]
printf "%-26s %10.1fMB %12.1fMB %13s\n", "ractor pool (1 proc)",
       mb[ra[:pss]], mb[ra[:pdirty]], "n/a"
puts
rn = ra[:pss].to_f / pr[:pss]
rw = ra[:pss].to_f / prw[:pss]
puts "Ractor PSS vs naive-fork  = #{(rn * 100).round(1)}%"
puts "Ractor PSS vs warmup-fork = #{(rw * 100).round(1)}%   <- the HONEST number"
puts "(gate: Ractor <= 70-80% of the STRONG baseline justifies the ~20% throughput loss)"
puts rw <= 0.80 ? "→ MEMORY GATE PASS: Ractor beats even warmup-protected CoW." :
                  "→ MEMORY GATE FAIL: warmup rescues CoW; Ractor's memory edge is marginal."
