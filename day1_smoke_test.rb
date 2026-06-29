# frozen_string_literal: true
#
# day1_smoke_test.rb — Ractorized Rails Kernel · falsification milestone · Day 1
#
# PURPOSE: probe the Ruby 4.0 Ractor mechanics the kernel depends on and
# CLASSIFY each as PASS / OK(fail) / ERROR. The job of this file is to *discover*
# whether the experimental API behaves as assumed — do NOT treat any call here as
# known-correct. Some probes are EXPECTED to fail (native extensions); that is the
# point. Adjust calls to the real 4.0 API as the failures tell you to.
#
# Run:
#   ruby -v                 # confirm 4.0.x  (Ractor is experimental → STDERR warning expected)
#   gem install nokogiri    # needed for probe 6 (the native-ext fallback proof)
#   ruby day1_smoke_test.rb
#
# Baseline note: this file only probes mechanics. Throughput/memory benchmarks
# (Ractors vs a PROCESS pool, not threads; PSS measured on Linux) live in the harness.

RESULTS = []
NOTES   = []
Thread.report_on_exception = false   # probe 6 EXPECTS a Ractor exception; don't dump its stack trace

def probe(name, expect: :pass)
  value = yield
  if expect == :fail
    # the block RETURNED but we predicted a failure → that is an anomaly, flag it as ERROR
    RESULTS << [name, :error, "UNEXPECTED SUCCESS (predicted failure did not happen): #{value.inspect[0, 80]}"]
  else
    RESULTS << [name, :pass, value.inspect[0, 110]]
  end
rescue => e
  RESULTS << [name, (expect == :fail ? :ok_fail : :error), "#{e.class}: #{e.message.to_s[0, 110]}"]
end

puts "Ruby #{RUBY_VERSION} (#{RUBY_ENGINE})  main_ractor=#{Ractor.main?}"

# 1. Port request/reply: a worker computes and replies on a port main owns.
probe("1 port request/reply") do
  reply = Ractor::Port.new
  Ractor.new(reply) { |rp| rp.send(40 + 2) }
  reply.receive            # => 42
end

# 2. Port is a shareable handle passable INSIDE a message (the gateway pattern):
#    worker gets the gateway inbox, sends its own reply port through it, main answers.
probe("2 port is shareable handle") do
  raise "Port not shareable" unless Ractor.shareable?(Ractor::Port.new)
  inbox  = Ractor::Port.new
  worker = Ractor.new(inbox) do |gw|
    reply = Ractor::Port.new
    gw.send([:ping, reply])
    reply.receive
  end
  _cmd, reply = inbox.receive   # main drains the gateway request
  reply.send(:pong)             # main answers on the worker's reply port
  worker.value                  # => :pong
end

# 3. DEADLOCK CHECK: main must drain the gateway on a DEDICATED THREAD while it
#    ALSO awaits the capsule's value. A synchronous gateway joined on the same
#    thread that awaits the capsule is the classic deadlock.
probe("3 concurrent drain + value (no deadlock)") do
  gw = Ractor::Port.new
  drain = Thread.new do
    loop do
      msg = gw.receive
      break if msg == :stop
      _kind, reply = msg
      reply.send("ack")
    end
  end
  cap = Ractor.new(gw) do |g|
    r = Ractor::Port.new
    g.send([:info, r])
    "compute-done(#{r.receive})"
  end
  out = cap.value          # main awaits the capsule...
  gw.send(:stop)           # ...then stops the drain
  drain.join
  out
end

# 4. Ractor#value and #join (4.0 replacements for #take / Ractor.yield).
probe("4 value/join") do
  r1 = Ractor.new { 21 * 2 }
  r2 = Ractor.new { :ok }
  r2.join
  [r1.value, r2.value]
end

# 5. make_shareable on a nested config/rules graph + zero-copy read in a worker.
probe("5 make_shareable nested config") do
  cfg = { region: "BR",
          tiers: [{ min: 0, pct: 0.10 }, { min: 100, pct: 0.20 }],
          flags: { fast: true } }
  frozen = Ractor.make_shareable(cfg)
  raise "not shareable" unless Ractor.shareable?(frozen)
  Ractor.new(frozen) { |c| c[:tiers].sum { |t| t[:pct] } }.value   # => 0.3
end

# 6. NATIVE-EXTENSION probe — ACTUALLY run nokogiri from a non-main Ractor and
#    capture the exact exception chain. EXPECTED to fail: an ext that does not
#    declare rb_ext_ractor_safe(true) raises deterministically. We are confirming
#    the failure class is real & classifiable (it forces the fallback design),
#    NOT re-deciding "is it safe" (the C source already answers that).
probe("6 nokogiri from non-main ractor", expect: :fail) do
  require "nokogiri"
  Ractor.new { Nokogiri::HTML("<a>x</a>").text }.value   # MUST raise from a non-main Ractor
rescue LoadError
  raise "nokogiri not installed (`gem install nokogiri`)"
rescue Ractor::RemoteError => e
  raise [e.class, e.cause&.class].compact.join(" <- ")    # surface the underlying UnsafeError
end

# 7. BOUNDARY COST: deep-copy send (default) vs frozen-share. Measures, per payload
#    size: copy_send (deep clone on Ractor.new), freeze_once (make_shareable cost,
#    paid once), frozen_send (sending the already-shareable object — should be ~0).
#    This is the economic crux: if copy_send dominates real payloads, the model is
#    fragile. Full table printed below the PASS/FAIL table.
probe("7 boundary send cost (see table below)") do
  build = ->(n) { Array.new(n) { |i| { id: i, v: "x" * 8 } } }
  ms  = ->(t) { (t * 1000).round(3) }
  clk = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  rows = { small: 1_000, medium: 50_000, large: 500_000 }.map do |label, n|
    src = build.(n)
    t0 = clk.(); Ractor.new(src) { |p| p.length }.value;            copy   = clk.() - t0
    src2 = build.(n)
    t1 = clk.(); frozen = Ractor.make_shareable(src2);              freeze = clk.() - t1
    t2 = clk.(); Ractor.new(frozen) { |p| p.length }.value;         sendf  = clk.() - t2
    [label, n, ms.(copy), ms.(freeze), ms.(sendf)]
  end
  NOTES << "boundary send cost (ms):"
  NOTES << format("    %-7s %-10s %-12s %-13s %-12s", "size", "n", "copy_send", "freeze_once", "frozen_send")
  rows.each { |l, n, c, f, s| NOTES << format("    %-7s %-10d %-12.3f %-13.3f %-12.3f", l, n, c, f, s) }
  :see_table
end

# 8. MOVE semantics: `move: true` should transfer ownership; the SENDER must lose
#    the object (touching it afterwards raises). Confirms the cheap alternative to
#    deep-copy and its ownership cost. If `move:` kw is unsupported on this build,
#    this ERRORs — which is itself a fact worth knowing.
probe("8 move transfers ownership") do
  reply = Ractor::Port.new
  Ractor.new(reply) do |rp|
    inbox = Ractor::Port.new
    rp.send(inbox)            # hand main a port to push into
    obj = inbox.receive       # receive the MOVED object
    rp.send(obj.sum)
  end
  wport = reply.receive
  big   = Array.new(100_000) { |i| i }
  wport.send(big, move: true) # MOVE ownership into the worker
  moved_sum = reply.receive
  begin
    big.length                                    # sender MUST have lost the object
    raise "move did NOT transfer ownership — sender still usable"
  rescue Ractor::MovedError
    # expected: sender was moved out
  end
  [moved_sum, "moved; sender raised Ractor::MovedError"]
end

# ---- report ----
puts
RESULTS.each do |name, status, detail|
  mark = { pass: "PASS", ok_fail: "OK(fail)", error: "ERROR" }[status]
  puts format("  %-9s %-40s %s", mark, name, detail)
end
unless NOTES.empty?
  puts
  NOTES.each { |l| puts l }
end
errors = RESULTS.count { |_, s, _| s == :error }
puts "\n#{errors} unexpected ERROR(s). PASS = mechanic works; OK(fail) = failed as predicted."
exit(errors.zero? ? 0 : 1)
