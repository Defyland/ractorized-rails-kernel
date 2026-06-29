# frozen_string_literal: true
#
# a2_gateway.rb — Ractorized Rails Kernel · Slice A2.1 · the smallest measurable gateway
#
# Q: does forcing a mutable global (the logger) through a Ractor GATEWAY erode the A1 throughput parity?
# A process pool logs DIRECTLY (each process owns its fd); a Ractor pool can't share the logger object, so
# it messages a single owner via a Port drained by a dedicated thread. This measures that asymmetry for the
# cheapest case: async fire-and-forget logging.
#
# STATUS (review round 3): PRODUCER-SIDE only — throughput is the workers' loop time; the gateway drain
# tail, send/drain latency p50/95/99, max backlog, drain-thread CPU, and timeout/drop semantics are NOT yet
# measured (that is A2 end-to-end, the next task). Treat any PASS here as provisional. Now has an
# INCONCLUSIVE guard when the tax spread straddles the gate, and uses the shared BenchKernel (no kernel drift).
#
#   docker run --rm -v "$PWD":/app -w /app ruby:4.0-slim ruby a2_gateway.rb
#   POOL=4 ALLOC=100 CAP_EVERY=10 REPS=4 DURATION=4 docker run ...

require_relative "bench_kernel"
BK = BenchKernel

abort "Linux only — no /proc/smaps_rollup on #{RUBY_PLATFORM}" unless File.exist?("/proc/self/smaps_rollup")

N_RULES   = Integer(ENV.fetch("N_RULES",  1_000_000))
ITEMS     = Integer(ENV.fetch("ITEMS",    2_000))
SCAN      = Integer(ENV.fetch("SCAN",     1_500))
DURATION  = Float(ENV.fetch("DURATION",   4.0))
ALLOC     = Integer(ENV.fetch("ALLOC",    100))
REPS      = Integer(ENV.fetch("REPS",     4))
POOL      = Integer(ENV.fetch("POOL",     4))
CAP_EVERY = Integer(ENV.fetch("CAP_EVERY", 1))   # emit one log line every N processed items
MB = ->(kb) { (kb / 1024.0).round(1) }

# sustained worker loop using the shared kernel; `cap` (or nil) is called every CAP_EVERY items
def work(dataset, count, items, cap)
  t0 = BK.mono
  deadline = t0 + DURATION
  done = 0; cksum = 0.0; first_pass = false; cap_calls = 0
  until BK.mono > deadline
    items.each do |it|
      acc = BK.compute(dataset, count, it, SCAN)
      BK.churn(ALLOC) unless ALLOC.zero?
      if cap && (done % CAP_EVERY).zero?
        cap.call("item #{it[:id]} v=#{it[:value]} acc=#{acc.round(2)}")
        cap_calls += 1
      end
      cksum += acc unless first_pass
      done += 1
    end
    first_pass = true
  end
  { done: done, elapsed: BK.mono - t0, cksum: cksum.round(4), full_pass: first_pass, cap_calls: cap_calls }
end

# PROCESS model: capability accessed DIRECTLY (each process owns its sink). Shards built once, symmetric.
def run_process(dataset, count, pool, cap:)
  GC.start; Process.warmup
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }
  res_r = []; hold_w = []; pids = []; released = false
  begin
    pool.times do |i|
      rr, rw = IO.pipe; hr, hw = IO.pipe
      pids << fork do
        rr.close; hw.close
        sink = cap ? File.open(File::NULL, "w") : nil
        capfn = sink && ->(line) { sink.write(line) }       # direct, in-process — no gateway
        out = work(dataset, count, shards[i], capfn)
        Marshal.dump(out, rw); rw.close
        hr.read(1); exit!(0)
      end
      rw.close; hr.close
      res_r << rr; hold_w << hw
    end
    results = res_r.map { |r| Marshal.load(r.read) }
    mem = [BK.smaps, *pids.map { |pid| BK.smaps(pid) }]
    hold_w.each { |w| w.write("x") }; released = true
    { results: results, pss: mem.sum { _1[:pss] }, backlog: 0 }
  ensure
    (res_r + hold_w).each { |io| io.close unless io.closed? }
    pids.each do |pid|
      (Process.kill("KILL", pid) rescue nil) unless released
      Process.wait(pid) rescue nil
    end
  end
end

# RACTOR model: capability routed through a GATEWAY (port + dedicated drain thread). Shards built once.
def run_ractor(dataset_shareable, count, pool, cap:)
  ready = Ractor::Port.new
  gw    = cap ? Ractor::Port.new : nil
  drained = 0
  sink = cap ? File.open(File::NULL, "w") : nil
  drain = cap && Thread.new do
    loop do
      msg = gw.receive
      break if msg == :stop
      sink.write(msg); drained += 1
    end
  end
  items = BK.make_items(ITEMS)
  shards = (0...pool).map { |i| BK.shard(items, pool, i) }
  rs = pool.times.map do |i|
    Ractor.new(dataset_shareable, count, shards[i], ready, gw) do |ds, cnt, sh, rdy, gwport|
      capfn = gwport && ->(line) { gwport.send(line) }   # fire-and-forget across the boundary
      out = work(ds, cnt, sh, capfn)                     # top-level work (refs only shareable constants + BK)
      hold = Ractor::Port.new
      rdy.send([out, hold])
      hold.receive
      out
    end
  end
  collected = pool.times.map { ready.receive }
  mem = BK.smaps(Process.pid)
  drained_at_snap = drained
  sent = collected.sum { _1.first[:cap_calls] }
  collected.each { |(_o, h)| h.send(:go) }
  rs.each(&:value)
  if cap
    gw.send(:stop); drain.join
  end
  { results: collected.map(&:first), pss: mem[:pss], gw_sent: sent, backlog: sent - drained_at_snap }
end

def throughput(results) = results.sum { _1[:done] } / results.map { _1[:elapsed] }.max
def correct?(results, oracle)
  return false unless results.all? { _1[:full_pass] }
  (results.sum { _1[:cksum] } - oracle).abs <= oracle.abs * 1e-9 + 1e-3
end
def cell(oracle)
  tputs = []; psss = []; backs = []; ok = true
  REPS.times do
    r = yield
    tputs << throughput(r[:results]); psss << r[:pss]; backs << r[:backlog]; ok &&= correct?(r[:results], oracle)
  end
  { tput: BK.median(tputs), tlo: tputs.min, thi: tputs.max, pss: BK.median(psss), backlog: BK.median(backs), correct: ok }
end

# ---------- driver ----------
puts "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) A2.1 logger-async gateway (PRODUCER-SIDE — end-to-end pending)"
puts "N_RULES=#{N_RULES} ITEMS=#{ITEMS} SCAN=#{SCAN} DURATION=#{DURATION}s ALLOC=#{ALLOC} " \
     "POOL=#{POOL} CAP_EVERY=#{CAP_EVERY} REPS=#{REPS}"

oracle = BK.isolated do
  ds = BK.build_dataset(N_RULES)
  BK.make_items(ITEMS).sum { |it| BK.compute(ds, ds.length, it, SCAN) }.round(4)
end

r_off = cell(oracle) { BK.isolated { ds = Ractor.make_shareable(BK.build_dataset(N_RULES)); run_ractor(ds, ds.length, POOL, cap: false) } }
r_on  = cell(oracle) { BK.isolated { ds = Ractor.make_shareable(BK.build_dataset(N_RULES)); run_ractor(ds, ds.length, POOL, cap: true) } }
p_on  = cell(oracle) { BK.isolated { ds = BK.build_dataset(N_RULES); run_process(ds, ds.length, POOL, cap: true) } }

puts
printf "%-26s %10s %15s %8s %10s %8s\n", "model", "items/s", "tput[min..max]", "PSS_MB", "gw_backlog", "correct"
[["ractor no-gateway", r_off], ["ractor gateway (logger)", r_on], ["process direct (logger)", p_on]].each do |label, c|
  printf "%-26s %10.0f %15s %6.1fMB %10d %8s\n",
         label, c[:tput], "#{c[:tlo].round}..#{c[:thi].round}", MB[c[:pss]], c[:backlog], (c[:correct] ? "yes" : "NO")
end

overhead    = (r_off[:tput] - r_on[:tput]) / r_off[:tput]
overhead_lo = (r_off[:tlo] - r_on[:thi]) / r_off[:tlo]        # noise guard: does the 5% gate flip
overhead_hi = (r_off[:thi] - r_on[:tlo]) / r_off[:thi]        # across the measured spread?
vs_proc     = r_on[:tput] / p_on[:tput]
mem_ratio   = r_on[:pss].to_f / p_on[:pss]
puts
puts "  A2.1 verdict (logger async, every #{CAP_EVERY} item#{CAP_EVERY == 1 ? '' : 's'}) — PRODUCER-SIDE:"
printf "    gateway tax (ractor ON vs no-gateway):   %+.1f%% [%.1f..%.1f]  (gate ≤5%%)\n", overhead * 100, overhead_lo * 100, overhead_hi * 100
printf "    ractor(gateway) throughput vs process:   %.1f%%    (gate ≥75-80%%)\n", vs_proc * 100
printf "    ractor(gateway) PSS vs process:          %.1f%%    (gate ≤70-80%%)\n", mem_ratio * 100
printf "    drain backlog at snapshot (median):      %d msgs   (NOT max backlog — end-to-end pending)\n", r_on[:backlog]
if (overhead_lo <= 0.05) != (overhead_hi <= 0.05)
  puts "    → A2.1: INCONCLUSIVE — gateway-tax spread straddles the 5% gate (raise REPS/DURATION)"
else
  pass = overhead <= 0.05 && vs_proc >= 0.75 && mem_ratio <= 0.80
  puts "    → A2.1: #{pass ? 'PASS (provisional — producer-side only)' : 'FAIL'}"
end
