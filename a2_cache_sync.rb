# frozen_string_literal: true
#
# a2_cache_sync.rb — Ractorized Rails Kernel · Slice A2.3 · bounded-SYNC cache read (the likely killer)
#
# A2.1 (async logger) was cheap because it is fire-and-forget. A2.3 is the dangerous case: a SYNCHRONOUS
# capability. A Ractor worker can't share the mutable cache, so for each read it does a request→reply
# round-trip to the single gateway and BLOCKS (with a timeout). If reads are frequent, N workers serialize
# through one gateway → latency climbs, throughput collapses. A process pool reads its OWN local cache
# directly (no round-trip). This measures the throughput hit + round-trip latency p50/95/99 + timeouts,
# swept by read frequency (CAP_EVERY). The thesis needs: chatty sync reads must be cheap OR forbidden.
#
#   docker run --rm -v "$PWD":/app -w /app ruby:4.0-slim ruby a2_cache_sync.rb
#   POOL=4 ALLOC=100 CAP_EVERY=1 REPS=3 docker run ...   # CAP_EVERY=1 = read every item (worst case)

require "json"
require "time"
require "timeout"
require_relative "bench_kernel"
BK = BenchKernel

abort "Linux only — no /proc/smaps_rollup on #{RUBY_PLATFORM}" unless File.exist?("/proc/self/smaps_rollup")

N_RULES   = Integer(ENV.fetch("N_RULES",  1_000_000))
ITEMS     = Integer(ENV.fetch("ITEMS",    2_000))
SCAN      = Integer(ENV.fetch("SCAN",     1_500))
DURATION  = Float(ENV.fetch("DURATION",   4.0))
ALLOC     = Integer(ENV.fetch("ALLOC",    100))
REPS      = Integer(ENV.fetch("REPS",     3))
POOL      = Integer(ENV.fetch("POOL",     4))
CAP_EVERY = Integer(ENV.fetch("CAP_EVERY", 1))    # one cache read every N items
CACHE_SZ  = Integer(ENV.fetch("CACHE_SZ", 1_000))
TIMEOUT_S = Float(ENV.fetch("TIMEOUT_S",  1.0))
JSON_OUT  = ENV["JSON_OUT"]
MB = ->(kb) { (kb / 1024.0).round(1) }

def build_cache(n) = (0...n).to_h { |i| [i, i * 2] }
def pct(sorted, p) = sorted.empty? ? 0.0 : sorted[(p * (sorted.length - 1)).round]

# worker loop; `cache.call(key)` returns the value or :timeout (sync round-trip), called every CAP_EVERY items
def work_sync(dataset, count, items, cache)
  t0 = BK.mono; deadline = t0 + DURATION
  done = 0; cksum = 0.0; first_pass = false; calls = 0; timeouts = 0; lats = []
  until BK.mono > deadline
    items.each do |it|
      acc = BK.compute(dataset, count, it, SCAN)
      BK.churn(ALLOC) unless ALLOC.zero?
      if cache && (done % CAP_EVERY).zero?
        t = BK.mono
        v = cache.call(it[:id] % CACHE_SZ)
        lats << (BK.mono - t) * 1_000.0      # ms
        if v == :timeout
          timeouts += 1                       # a timeout = MISSING data -> breaks the checksum below
        elsif !first_pass
          cksum += v                          # the cache value MUST affect the checksum (catches stale/wrong replies)
        end
        calls += 1
      end
      cksum += acc unless first_pass
      done += 1
    end
    first_pass = true
  end
  ls = lats.sort
  { done: done, elapsed: BK.mono - t0, cksum: cksum.round(4), full_pass: first_pass, calls: calls,
    timeouts: timeouts, stale: 0, p50: pct(ls, 0.50), p95: pct(ls, 0.95), p99: pct(ls, 0.99) }
end

# PROCESS model: each worker reads its OWN local cache directly — no round-trip.
def run_process(dataset, count, pool, cached:)
  GC.start; Process.warmup
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }
  res_r = []; hold_w = []; pids = []; released = false
  begin
    pool.times do |i|
      rr, rw = IO.pipe; hr, hw = IO.pipe
      pids << fork do
        rr.close; hw.close
        local = cached ? build_cache(CACHE_SZ) : nil
        fn = local && ->(k) { local[k] }
        Marshal.dump(work_sync(dataset, count, shards[i], fn), rw); rw.close
        hr.read(1); exit!(0)
      end
      rw.close; hr.close
      res_r << rr; hold_w << hw
    end
    results = res_r.map { |r| Marshal.load(r.read) }
    mem = [BK.smaps, *pids.map { |p| BK.smaps(p) }]
    hold_w.each { |w| w.write("x") }; released = true
    { results: results, pss: mem.sum { _1[:pss] } }
  ensure
    (res_r + hold_w).each { |io| io.close unless io.closed? }
    pids.each { |p| (Process.kill("KILL", p) rescue nil) unless released; Process.wait(p) rescue nil }
  end
end

# RACTOR model: workers round-trip to ONE gateway (drain thread owns the mutable cache).
def run_ractor(dataset_shareable, count, pool, cached:)
  ready = Ractor::Port.new
  req   = cached ? Ractor::Port.new : nil
  cache = cached ? build_cache(CACHE_SZ) : nil          # the single owner's mutable cache
  drain = cached && Thread.new do
    loop do
      msg = req.receive
      break if msg == :stop
      key, rid, reply = msg
      reply.send([cache[key], rid])           # tag the reply so a late one (post-timeout) is droppable
    end
  end
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }
  rs = pool.times.map do |i|
    Ractor.new(dataset_shareable, count, shards[i], ready, req) do |ds, cnt, sh, rdy, reqport|
      stale = 0
      fn = if reqport
        reply = Ractor::Port.new                        # one reply channel per worker, reused
        rid = 0
        lambda do |k|
          rid += 1
          reqport.send([k, rid, reply])
          begin
            Timeout.timeout(TIMEOUT_S) do
              loop do                                    # accept ONLY the reply tagged with this rid; a late
                val, got = reply.receive                 # reply from a previously timed-out request is dropped
                break val if got == rid                  # (counted as `stale`) so it can't be consumed as fresh
                stale += 1
              end
            end
          rescue Timeout::Error
            :timeout
          end
        end
      end
      out = work_sync(ds, cnt, sh, fn).merge(stale: stale)
      hold = Ractor::Port.new
      rdy.send([out, hold])
      hold.receive
      out
    end
  end
  collected = pool.times.map { ready.receive }
  mem = BK.smaps(Process.pid)
  collected.each { |(_o, h)| h.send(:go) }
  rs.each(&:value)
  if cached
    req.send(:stop); drain.join
  end
  { results: collected.map(&:first), pss: mem[:pss] }
end

def tput(rs) = rs.sum { _1[:done] } / rs.map { _1[:elapsed] }.max
def correct?(rs, oracle)
  return false unless rs.all? { _1[:full_pass] }
  (rs.sum { _1[:cksum] } - oracle).abs <= oracle.abs * 1e-9 + 1e-3
end
def agg(rs, k) = BK.median(rs.map { _1[k] })

def cell(oracle)
  rows = Array.new(REPS) { yield }
  ts = rows.map { tput(_1[:results]) }
  { tput: BK.median(ts), tlo: ts.min, thi: ts.max, pss: BK.median(rows.map { _1[:pss] }),
    p50: BK.median(rows.map { agg(_1[:results], :p50) }), p95: BK.median(rows.map { agg(_1[:results], :p95) }),
    p99: BK.median(rows.map { agg(_1[:results], :p99) }),
    timeouts: rows.sum { |row| row[:results].sum { |r| r[:timeouts] } },
    stale: rows.sum { |row| row[:results].sum { |r| r[:stale] } },
    correct: rows.all? { correct?(_1[:results], oracle) } }
end

# ---------- driver ----------
puts "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) A2.3 bounded-SYNC cache read (end-to-end round-trip)"
puts "N_RULES=#{N_RULES} ITEMS=#{ITEMS} SCAN=#{SCAN} DURATION=#{DURATION}s ALLOC=#{ALLOC} POOL=#{POOL} " \
     "CAP_EVERY=#{CAP_EVERY} CACHE_SZ=#{CACHE_SZ} REPS=#{REPS}"

oracle_compute = BK.isolated do
  ds = BK.build_dataset(N_RULES)
  BK.make_items(ITEMS).sum { |it| BK.compute(ds, ds.length, it, SCAN) }.round(4)
end
# Cache contribution to the FIRST-PASS checksum, at exactly the positions work_sync reads (per shard,
# every CAP_EVERY items). Folding this in is what makes a stale / wrong / timed-out cache reply DETECTABLE:
# a cached run is `correct` only if every first-pass read returned the right value (no timeouts, no stale).
oracle_cache = begin
  cache = build_cache(CACHE_SZ); items = BK.make_items(ITEMS); total = 0.0
  POOL.times do |i|
    done = 0
    BK.shard(items, POOL, i).each do |it|
      total += cache[it[:id] % CACHE_SZ] if (done % CAP_EVERY).zero?
      done += 1
    end
  end
  total.round(4)
end
exp_nocache = oracle_compute
exp_cache   = (oracle_compute + oracle_cache).round(4)

r_off = cell(exp_nocache) { BK.isolated { ds = Ractor.make_shareable(BK.build_dataset(N_RULES)); run_ractor(ds, ds.length, POOL, cached: false) } }
r_on  = cell(exp_cache)   { BK.isolated { ds = Ractor.make_shareable(BK.build_dataset(N_RULES)); run_ractor(ds, ds.length, POOL, cached: true) } }
p_on  = cell(exp_cache)   { BK.isolated { ds = BK.build_dataset(N_RULES); run_process(ds, ds.length, POOL, cached: true) } }

puts
printf "%-26s %10s %15s %8s %8s %8s %8s\n", "model", "items/s", "tput[min..max]", "rt_p50", "rt_p95", "rt_p99", "correct"
[["ractor no-cache", r_off], ["ractor SYNC cache (gw)", r_on], ["process direct cache", p_on]].each do |label, c|
  printf "%-26s %10.0f %15s %6.3fms %6.3fms %6.3fms %8s\n",
         label, c[:tput], "#{c[:tlo].round}..#{c[:thi].round}", c[:p50], c[:p95], c[:p99], (c[:correct] ? "yes" : "NO")
end

overhead    = (r_off[:tput] - r_on[:tput]) / r_off[:tput]
overhead_lo = (r_off[:tlo] - r_on[:thi]) / r_off[:tlo]
overhead_hi = (r_off[:thi] - r_on[:tlo]) / r_off[:thi]
vs_proc     = r_on[:tput] / p_on[:tput]
vs_proc_lo  = r_on[:tlo] / p_on[:thi]
vs_proc_hi  = r_on[:thi] / p_on[:tlo]
puts
puts "  A2.3 verdict (sync cache read every #{CAP_EVERY} item#{CAP_EVERY == 1 ? '' : 's'}):"
printf "    sync-gateway tax (ractor cache vs no-cache): %+.1f%% [%.1f..%.1f]  (gate ≤10-15%%)\n", overhead * 100, overhead_lo * 100, overhead_hi * 100
printf "    ractor(sync cache) throughput vs process:    %.1f%% [%.1f..%.1f]  (gate ≥75%%)\n", vs_proc * 100, vs_proc_lo * 100, vs_proc_hi * 100
printf "    round-trip latency: p50 %.3fms / p95 %.3fms / p99 %.3fms ; timeouts %d ; stale replies dropped %d\n", r_on[:p50], r_on[:p95], r_on[:p99], r_on[:timeouts], r_on[:stale]
# A correctness/timeout failure is DEFINITIVE — it trumps any "inconclusive on spread" (a wrong answer
# is wrong regardless of how tight the throughput spread is).
if !r_on[:correct] || r_on[:timeouts].positive?
  status = "fail"
  reason = "timeouts/stale or incorrect sync reads"
  puts "    → A2.3: FAIL — #{r_on[:timeouts]} timeouts, #{r_on[:stale]} stale dropped, correct=#{r_on[:correct]} " \
       "(stale/missing reads); forbid chatty sync deps in capsules"
elsif (overhead_lo <= 0.15) != (overhead_hi <= 0.15) || (vs_proc_lo >= 0.75) != (vs_proc_hi >= 0.75)
  status = "inconclusive"
  reason = "throughput spread straddles a gate"
  puts "    → A2.3: INCONCLUSIVE — tax OR vs-process spread straddles a gate (raise REPS/DURATION)"
else
  # Gate (only reached when correct AND no timeouts): low tax vs no-cache AND ≥75% of the PROCESS pool
  # (the real competitor — it reads its own cache locally).
  pass = overhead <= 0.15 && vs_proc >= 0.75
  reason = vs_proc < 0.75 ? "loses to the process pool (#{(vs_proc * 100).round}% < 75%)" : "sync-gateway tax > 15%"
  status = pass ? "pass" : "fail"
  puts "    → A2.3: #{pass ? 'PASS (sync gateway tolerable AND competitive vs process)' : "FAIL — #{reason}; forbid chatty sync deps in capsules"}"
end

if JSON_OUT
  File.write(JSON_OUT, JSON.pretty_generate({
    generated_at_utc: Time.now.utc.iso8601,
    ruby: RUBY_DESCRIPTION,
    platform: RUBY_PLATFORM,
    config: {
      n_rules: N_RULES,
      items: ITEMS,
      scan: SCAN,
      duration_s: DURATION,
      alloc: ALLOC,
      reps: REPS,
      pool: POOL,
      cap_every: CAP_EVERY,
      cache_size: CACHE_SZ,
      timeout_s: TIMEOUT_S,
    },
    models: {
      ractor_no_cache: r_off,
      ractor_sync_cache: r_on,
      process_direct_cache: p_on,
    },
    derived: {
      sync_gateway_tax: overhead,
      sync_gateway_tax_percent: (overhead * 100).round(1),
      sync_gateway_tax_min_percent: (overhead_lo * 100).round(1),
      sync_gateway_tax_max_percent: (overhead_hi * 100).round(1),
      throughput_vs_process: vs_proc,
      throughput_vs_process_percent: (vs_proc * 100).round(1),
      throughput_vs_process_min_percent: (vs_proc_lo * 100).round(1),
      throughput_vs_process_max_percent: (vs_proc_hi * 100).round(1),
    },
    verdict: {
      status: status,
      reason: reason,
    },
  }))
  puts "\nJSON written: #{JSON_OUT}"
end
