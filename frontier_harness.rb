# frozen_string_literal: true
#
# frontier_harness.rb — Ractorized Rails Kernel · Slice A1 · consolidated Linux harness
#
# Answers the REVISED gate in ONE run, on Linux, fixing the review findings:
#   - throughput AND memory (PSS/Private_Dirty) measured in the same run     (H2)
#   - pool size swept 1..N → a throughput/memory FRONTIER, not a 4-vs-4 point (frontier gate)
#   - both models snapshot memory at a BARRIER with all workers alive         (H1)
#   - measured after SUSTAINED load (workers loop for DURATION, GC drifts)     (H3)
#   - strong process baseline: Process.warmup (prod CoW protection)           (strong baseline)
#   - dataset-shape matrix: Array<Hash> | frozen Data | packed blob           (market-defining)
#   - pools created OUTSIDE the timed region; workers return CHECKSUMS         (H3/transfer)
#   - smaps parse FAILS LOUD; forks/pipes cleaned up in ensure                 (P2)
#
# Linux only:  docker run --rm -v "$PWD":/app -w /app ruby:4.0-slim ruby frontier_harness.rb
#   POOLS=1,2,4 SHAPES=hash,struct,blob DURATION=2.0 ITEMS=2000 SCAN=2000 docker run ...

require "etc"

abort "Linux only — no /proc/smaps_rollup on #{RUBY_PLATFORM}" unless File.exist?("/proc/self/smaps_rollup")

CORES    = Etc.nprocessors
POOLS    = ENV.fetch("POOLS", (1..CORES.clamp(1, 4)).to_a.join(",")).split(",").map { Integer(_1) }
SHAPES   = ENV.fetch("SHAPES", "hash,struct,blob").split(",").map(&:to_sym)
N_RULES  = Integer(ENV.fetch("N_RULES", 1_000_000))
ITEMS    = Integer(ENV.fetch("ITEMS",   2_000))
SCAN     = Integer(ENV.fetch("SCAN",    2_000))   # rules scanned per item (CPU knob)
DURATION = Float(ENV.fetch("DURATION",  2.0))     # sustained-load seconds per worker
ALLOC    = Integer(ENV.fetch("ALLOC",   0))       # throwaway objects per item — simulates Rails churn
REPS     = Integer(ENV.fetch("REPS",    3))       # measurements per cell → median + spread (H-A)

Rec = Data.define(:threshold, :factor, :base)
BLOB_FMT  = "lld"        # int32 threshold, int32 base, float64 factor — 16 bytes/record
BLOB_SIZE = 16

# ---------- dataset shapes ----------
def field_values(i) = [i % 1000, ((i * 37) % 100) / 100.0, i % 50]  # [threshold, factor, base]

def build_dataset(shape, n)
  case shape
  when :hash   then Array.new(n) { |i| t, f, b = field_values(i); { threshold: t, factor: f, base: b } }
  when :struct then Array.new(n) { |i| t, f, b = field_values(i); Rec.new(threshold: t, factor: f, base: b) }
  when :blob   then (+"").tap { |s| n.times { |i| t, f, b = field_values(i); s << [t, b, f].pack(BLOB_FMT) } }
  else abort "unknown shape #{shape}"
  end
end

def count_of(dataset, shape) = shape == :blob ? dataset.bytesize / BLOB_SIZE : dataset.length

# pure CPU-bound compute over a window — identical math per shape, allocation-light hot path
# (field access inlined; shape branch hoisted OUT of the inner loop so it costs nothing per record)
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
      acc += dataset.unpack1("d", offset: off + 8) * (v + dataset.unpack1("l", offset: off + 4)) if v > dataset.unpack1("l", offset: off)
    end
  end
  acc
end

# synthetic per-item object churn — a SEPARATE knob (not part of the kernel); simulates Rails
# allocation pressure. Discards what it allocates, so it never affects the checksum.
def churn(n) = n.times { |i| { k: i, a: [i, i] } }
def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def make_items(n) = Array.new(n) { |i| { id: i, seed: i * 7919, value: (i * 13) % 1500 } }
def shard(items, pool, idx) = items.each_slice((items.size / pool.to_f).ceil).to_a.fetch(idx, [])

# sustained worker loop: run shard repeatedly until DURATION; first-pass checksum for correctness
def work(dataset, shape, count, items)
  t0 = mono
  deadline = t0 + DURATION
  done = 0
  cksum = 0.0
  first_pass = false
  until mono > deadline
    items.each do |it|
      acc = compute(dataset, shape, count, it)
      churn(ALLOC) unless ALLOC.zero?
      cksum += acc unless first_pass
      done += 1
    end
    first_pass = true
  end
  { done: done, elapsed: mono - t0, cksum: cksum.round(4), full_pass: first_pass }
end

# ---------- memory: PSS from /proc, FAIL LOUD ----------
def smaps(pid = Process.pid)
  txt = File.read("/proc/#{pid}/smaps_rollup")
  grab = lambda do |key|
    m = txt[/^#{key}:\s+(\d+)\s+kB/, 1]
    raise "smaps: field #{key} not found for pid #{pid}" if m.nil?
    Integer(m)
  end
  { pss: grab["Pss"], pdirty: grab["Private_Dirty"], sclean: grab["Shared_Clean"] }
rescue Errno::ENOENT
  raise "smaps: process #{pid} gone before snapshot (OOM/crash?)"
end

MB = ->(kb) { (kb / 1024.0).round(1) }

# ---------- PROCESS model (barrier: parent reads /proc/<pid> of all children while alive) ----------
def run_process(dataset, shape, count, pool, warmup:)
  GC.start
  Process.warmup if warmup            # strong CoW baseline before fork
  items = make_items(ITEMS)
  shards = (0...pool).map { |i| shard(items, pool, i) }   # built once — symmetric with run_ractor
  res_r = []; hold_w = []; pids = []; released = false
  begin
    pool.times do |i|
      rr, rw = IO.pipe                 # child → parent: result
      hr, hw = IO.pipe                 # parent → child: hold/release
      pids << fork do
        rr.close; hw.close
        out = work(dataset, shape, count, shards[i])
        Marshal.dump(out, rw); rw.close
        hr.read(1)                     # stay ALIVE (blocked) for the barrier snapshot
        exit!(0)
      end
      rw.close; hr.close
      res_r << rr; hold_w << hw
    end
    results = res_r.map { |r| Marshal.load(r.read) }     # all workers finished their DURATION loop
    mem = [smaps(Process.pid), *pids.map { |pid| smaps(pid) }]  # snapshot whole tree, all alive
    hold_w.each { |w| w.write("x") }; released = true    # release
    { results: results,
      pss: mem.sum { _1[:pss] }, pdirty: mem.sum { _1[:pdirty] }, sclean: mem.sum { _1[:sclean] } }
  ensure
    (res_r + hold_w).each { |io| io.close unless io.closed? }
    pids.each do |pid|
      Process.kill("KILL", pid) rescue nil unless released   # only kill un-released workers
      Process.wait(pid) rescue nil
    end
  end
end

# ---------- RACTOR model (barrier: single process snapshot, all Ractors alive) ----------
def run_ractor(dataset_shareable, shape, count, pool)
  ready = Ractor::Port.new
  items_all = make_items(ITEMS)
  ractors = pool.times.map do |i|
    sh = shard(items_all, pool, i)
    Ractor.new(dataset_shareable, shape, count, sh, ready) do |ds, shp, cnt, items, rdy|
      out = work(ds, shp, cnt, items)
      hold = Ractor::Port.new
      rdy.send([out, hold])
      hold.receive            # stay ALIVE for the barrier snapshot
      out
    end
  end
  collected = pool.times.map { ready.receive }     # [[out, hold], ...] — all alive
  mem = smaps(Process.pid)                          # ONE process = all Ractors
  collected.each { |(_out, hold)| hold.send(:go) }
  ractors.each(&:value)
  { results: collected.map(&:first), pss: mem[:pss], pdirty: mem[:pdirty], sclean: mem[:sclean] }
end

# each model runs in its OWN isolated process (no heap cross-contamination)
def isolated
  r, w = IO.pipe
  pid = fork do
    r.close
    w.write(Marshal.dump(yield)); w.close
    exit!(0)
  end
  w.close
  data = r.read; r.close
  raise "isolated child #{pid} died without output (OOM?)" if data.empty?
  Process.wait(pid)
  Marshal.load(data)
ensure
  r.close unless r.closed?
end

def throughput(results) = results.sum { _1[:done] } / results.map { _1[:elapsed] }.max
def correct?(results, oracle)
  results.all? { _1[:full_pass] } && results.sum { _1[:cksum] }.round(2) == oracle.round(2)
end
def median(xs) = xs.sort.then { |s| s.length.odd? ? s[s.length / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2.0 }

# interpolate process PSS at throughput t (fair iso-throughput memory comparison across the frontier)
def iso_pss(points, t)
  s = points.sort_by { _1[:tput] }
  return s.first[:pss].to_f if t <= s.first[:tput]
  return s.last[:pss].to_f  if t >= s.last[:tput]
  hi = s.find { _1[:tput] >= t }
  lo = s.reverse.find { _1[:tput] <= t }
  frac = (t - lo[:tput]) / (hi[:tput] - lo[:tput]).to_f
  lo[:pss] + frac * (hi[:pss] - lo[:pss])
end

# run a cell REPS times → median throughput + spread + median PSS; correctness must hold every rep
def cell(oracle)
  tputs = []; psss = []; ok = true
  REPS.times do
    r = yield
    tputs << throughput(r[:results]); psss << r[:pss]; ok &&= correct?(r[:results], oracle)
  end
  { tput: median(tputs), tlo: tputs.min, thi: tputs.max, pss: median(psss), correct: ok }
end

# ---------- driver ----------
puts "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) cores=#{CORES}"
puts "pools=#{POOLS.inspect} shapes=#{SHAPES.inspect} N_RULES=#{N_RULES} ITEMS=#{ITEMS} " \
     "SCAN=#{SCAN} DURATION=#{DURATION}s ALLOC=#{ALLOC} REPS=#{REPS}"

SHAPES.each do |shape|
  puts "\n==================== shape: #{shape} (ALLOC=#{ALLOC}) ===================="
  oracle = isolated do
    ds = build_dataset(shape, N_RULES); cnt = count_of(ds, shape)
    make_items(ITEMS).sum { |it| compute(ds, shape, cnt, it) }.round(4)
  end

  frontier = { process: [], ractor: [] }
  printf "%-16s %5s %10s %16s %8s %8s\n", "model", "pool", "items/s", "tput[min..max]", "PSS_MB", "correct"
  POOLS.each do |pool|
    pcell = cell(oracle) do
      isolated do
        ds = build_dataset(shape, N_RULES); cnt = count_of(ds, shape)
        run_process(ds, shape, cnt, pool, warmup: true)
      end
    end
    rcell = cell(oracle) do
      isolated do
        ds = Ractor.make_shareable(build_dataset(shape, N_RULES)); cnt = count_of(ds, shape)
        run_ractor(ds, shape, cnt, pool)
      end
    end
    [["process(warmup)", :process, pcell], ["ractor(frozen)", :ractor, rcell]].each do |label, key, c|
      frontier[key] << c.merge(pool: pool)
      printf "%-16s %5d %10.0f %16s %6.1fMB %8s\n",
             label, pool, c[:tput], "#{c[:tlo].round}..#{c[:thi].round}", MB[c[:pss]], (c[:correct] ? "yes" : "NO")
    end
  end

  # verdict: MEMORY compared at ISO-THROUGHPUT (ractor best vs the process pool nearest in
  # throughput); THROUGHPUT REACH compared ractor-best vs process-max. Both points printed.
  r_best = frontier[:ractor].max_by { _1[:tput] }
  p_max  = frontier[:process].max_by { _1[:tput] }
  iso_p  = iso_pss(frontier[:process], r_best[:tput])   # process PSS interpolated at ractor's throughput
  pss_ratio = r_best[:pss].to_f / iso_p
  reach     = r_best[:tput] / p_max[:tput]
  reach_lo  = r_best[:tlo] / p_max[:thi]                 # noise guard: does the verdict flip
  reach_hi  = r_best[:thi] / p_max[:tlo]                 # across the measured spread?

  puts "\n  verdict (#{shape}, ALLOC=#{ALLOC}):"
  printf "    ractor best:   %.0f items/s @ pool %d, PSS %.1fMB\n", r_best[:tput], r_best[:pool], MB[r_best[:pss]]
  printf "    process:       max %.0f items/s; PSS interpolated to ractor's tput = %.1fMB\n", p_max[:tput], MB[iso_p]
  saved_kb   = iso_p - r_best[:pss]
  saved_frac = saved_kb / iso_p
  material   = MB[saved_kb] >= 100   # ABSOLUTE floor — a high ratio on a small dataset is an economic no-op
  printf "    memory @ iso-throughput:  Ractor PSS / process PSS = %.1f%%  (gate ≤70-80%%)\n", pss_ratio * 100
  printf "    absolute saving:          %.1fMB (%.1f%% of process)  (gate ≥100MB ABSOLUTE)\n", MB[saved_kb], saved_frac * 100
  printf "    throughput reach:         ractor best / process max = %.1f%%  (gate ≥75-80%%)\n", reach * 100
  if (reach_lo >= 0.75) != (reach_hi >= 0.75)
    puts "    → #{shape}: INCONCLUSIVE — throughput spread straddles the gate (raise REPS/DURATION)"
  else
    ratio_ok = pss_ratio <= 0.80 && reach >= 0.75
    pass = ratio_ok && material
    verdict = if pass then "PASS (in-niche thesis holds)"
              elsif ratio_ok then "ECONOMIC NO-OP — ratio passes but saving #{MB[saved_kb].round(1)}MB < 100MB (technical ratio pass, not an economic win)"
              else "FAIL"
              end
    puts "    → #{shape}: #{verdict}"
  end
end
