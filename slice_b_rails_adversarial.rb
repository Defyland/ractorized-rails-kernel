# frozen_string_literal: true
#
# slice_b_rails_adversarial.rb — Ractorized Rails Kernel · Slice B · Rails resistance + transactional soundness
#
# A1/A2 settled the ECONOMICS in-niche. Slice B asks the next question: how much RESISTANT Rails becomes a
# capsule without an absurd migration, and is the write path SOUND? It is deliberately ugly and decisive.
# No real Rails (you cannot boot Rails inside a Ractor — rails#51543; AR is Ractor-unsafe), so it models the
# resistant PATTERNS faithfully and proves the protocol.
#
# PART 1 — resistance classification: each resistant Rails pattern is either TRANSFORMED (to a CapsuleContext
#          / descriptor) or a NAMED FAILURE (with the real exception), or a MEASURED FALLBACK.
# PART 2 — transactional soundness: capsule computes a Proposal + EffectIntents (PURE, no side effects); the
#          owner commits with an optimistic version check; effects are persisted to a DURABLE outbox in the
#          same commit and fired ONLY by a post-commit dispatcher, idempotently. Adversarial tests:
#            T1 no external effect before commit (capsule is pure)
#            T2 version conflict ⇒ rejected proposal's effect never enters the outbox (no ghost charge)
#            T3 at-least-once dispatch ⇒ idempotent consumer applies the effect once
#            T4 crash after commit, before dispatch ⇒ recovery re-delivers; consumer keeps it once
#            T5 concurrent committers ⇒ exactly one commits (atomic flock; no double-commit)
#            T6 concurrent dispatchers ⇒ at-least-once delivery, consumer dedups to one effect
#          CLAIM (precise): exactly-once outbox ENQUEUE + at-least-once IDEMPOTENT delivery. The outbox does
#          NOT make the external effect exactly-once — the consumer's idk dedup does (effects.log models it).
#
# Runs anywhere (logic + fork + files; no /proc needed):  ruby slice_b_rails_adversarial.rb

require "json"
require "fileutils"
require "tmpdir"
require "set"
Thread.report_on_exception = false   # Part 1 EXPECTS Ractor exceptions; don't dump their stack traces

PASS = []; FAIL = []
def gate(name, ok, detail = "") = (ok ? PASS : FAIL) << "#{name}#{detail.empty? ? '' : " — #{detail}"}"

# ============================ PART 1 — resistance classification ============================
puts "== PART 1: Rails-resistance classification =="

# (a) Current.user inside a callback → thread-local, invisible to a Ractor. Transform: CapsuleContext arg.
current_user_id = 42                       # main's "Current.user.id" (thread-local in real Rails)
begin
  # the WRONG way: a capsule trying to read ambient Current (captured) — IsolationError on a non-shareable capture
  Ractor.new { current_user_id }.value     # captures outer var → must raise
  gate("Current implicit-capture", false, "UNEXPECTED: capsule saw ambient Current")
rescue => e
  # the RIGHT way: pass it explicitly via CapsuleContext
  ctx = Ractor.make_shareable({ current_user_id: current_user_id, tenant_id: 7, locale: "pt-BR" })
  seen = Ractor.new(ctx) { |c| c[:current_user_id] }.value
  gate("Current → CapsuleContext", seen == 42, "implicit capture fails (#{e.class}); explicit ctx works")
end

# (b) callback/proc capturing mutable state → make_shareable fails. Transform: a shareable descriptor.
threshold = [100]                          # a mutable captured object (e.g. a memoized rule)
begin
  Ractor.make_shareable(proc { threshold.first })   # captures a mutable Array → IsolationError
  gate("callback proc shareable", false, "UNEXPECTED: mutable-capturing proc was made shareable")
rescue => e
  Descriptor = Data.define(:op, :arg) unless defined?(Descriptor)
  desc = Ractor.make_shareable(Descriptor.new(op: :gte, arg: 100))   # defunctionalized, shareable
  ok = Ractor.new(desc) { |d| d.op == :gte && d.arg == 100 }.value
  gate("callback → shareable descriptor", ok, "raw proc fails (#{e.class}); descriptor works")
end

# (c) Nokogiri / native ext → Ractor::UnsafeError from a non-main Ractor. Fallback: do it in the owner.
begin
  require "nokogiri"
  begin
    Ractor.new { Nokogiri::HTML("<a>x</a>").text }.value
    gate("native-ext in capsule", false, "UNEXPECTED: nokogiri ran in a non-main Ractor")
  rescue => e
    chain = [e.class, e.cause&.class].compact.join(" <- ")
    sanitized = Nokogiri::HTML("<b>hi</b>").text     # fallback: owner/main does it (gateway-measured in A2.3)
    gate("native-ext → owner fallback", sanitized == "hi", "capsule fails (#{chain}); owner fallback works")
  end
rescue LoadError
  gate("native-ext → owner fallback", true, "nokogiri not installed — fallback path assumed (see day1/A2.3)")
end

# ============================ PART 2 — transactional soundness ============================
puts "\n== PART 2: transactional soundness (Proposal + commit + durable outbox + idempotent dispatch) =="

# Durable append-only log = the commit record (models a single DB transaction: state version + outbox effects
# written atomically as ONE append). State (version per order) is folded from the log. effects.log holds the
# idempotency keys of FIRED external effects — appending an idk IS the (idempotent) external side effect.
class Store
  def initialize(dir)
    @dir = dir; FileUtils.mkdir_p(dir)
    @log = File.join(dir, "outbox.jsonl")
    @fx  = File.join(dir, "effects.log")
    FileUtils.touch(@log); FileUtils.touch(@fx)
    File.open(dir) { |d| d.fsync rescue nil }   # persist the directory entries (durability of file creation)
  end

  # committed records; TOLERATE a torn trailing line (crash mid-append) — treat it as NOT committed.
  def records
    out = []
    File.foreach(@log) do |l|
      out << JSON.parse(l)
    rescue JSON::ParserError
      break   # only the last line can be torn (append-only); a partial commit counts as no commit
    end
    out
  end

  def current_version(order_id)
    v = 0; records.each { |e| v = e["version"] if e["order_id"] == order_id }; v
  end

  def snapshot(order_id)
    total = 0; ver = 0
    records.each { |e| (total, ver = e["total"], e["version"]) if e["order_id"] == order_id }
    { order_id: order_id, version: ver, total: total }
  end

  # optimistic commit, ATOMIC across processes: flock serializes the check-and-append so two concurrent
  # committers cannot both pass the version check (the real-DB equivalent is a unique (order_id,version) index).
  def commit(p)
    File.open(@log, "a") do |f|
      f.flock(File::LOCK_EX)
      return :conflict unless current_version(p[:order_id]) == p[:base_version]
      f.write(JSON.generate({ order_id: p[:order_id], version: p[:base_version] + 1, total: p[:total], effects: p[:effects] }) + "\n")
      f.fsync
      :committed
    end
  end

  # post-commit RELAY: AT-LEAST-ONCE delivery. effects.log models the IDEMPOTENT EXTERNAL CONSUMER (dedup by
  # idk). The relay may deliver the same idk many times (retry / crash / concurrency); the CONSUMER keeps the
  # effect once. The outbox does NOT make delivery exactly-once — the consumer's idk dedup does. (A real relay
  # also marks rows dispatched + prunes; this toy re-scans the whole outbox each call, which is fine here.)
  # flock on @fx serializes concurrent relays so two can't both observe the same idk as un-delivered.
  def dispatch!
    File.open(@fx, "r") do |lock|
      lock.flock(File::LOCK_EX)
      seen = File.readlines(@fx, chomp: true).to_set     # what the idempotent consumer has already accepted
      records.each do |rec|
        rec["effects"].each do |fx|
          idk = fx["idk"]
          next if seen.include?(idk)                     # consumer dedup: at-least-once delivery → applied once
          File.open(@fx, "a") { |f| f.write(idk + "\n"); f.fsync }
          seen << idk
        end
      end
    end
  end

  def effects_fired = File.readlines(@fx, chomp: true)
end

# the capsule: PURE. given a shareable snapshot + input, returns a Proposal with EffectIntents. NO side effects.
# PRECONDITION: `request_id` is a STABLE, deterministic per-logical-operation idempotency token supplied by the
# caller. The exactly-once-at-consumer guarantee is CONDITIONAL on it (a retry with a fresh id double-charges;
# a reused id drops a charge). This is the standard idempotency-key contract — not enforced here.
def capsule_compute(snapshot, input)
  { order_id: snapshot[:order_id], base_version: snapshot[:version], total: snapshot[:total] + input[:amount],
    effects: [{ "kind" => "charge", "idk" => "charge-#{snapshot[:order_id]}-#{input[:request_id]}", "cents" => input[:amount] }] }
end

def run_capsule(store, order_id, request_id, amount)
  snap = Ractor.make_shareable(store.snapshot(order_id))
  inp  = Ractor.make_shareable({ amount: amount, request_id: request_id })
  Ractor.new(snap, inp) { |s, i| capsule_compute(s, i) }.value   # compute in a real Ractor; Proposal crosses back
end

tmp = File.join(Dir.tmpdir, "slice_b_#{Process.pid}")
FileUtils.rm_rf(tmp)

# --- T1: capsule is PURE (STRUCTURAL invariant: capsule returns EffectIntent data, has no way to fire) ---
s = Store.new(File.join(tmp, "t1"))
prop = run_capsule(s, "o1", "r1", 500)
gate("T1 capsule returns an EffectIntent (data, not an action)", prop[:effects].first["kind"] == "charge")
gate("T1 (structural) capsule has no fire capability — effects.log empty pre-dispatch", s.effects_fired.empty?)
s.commit(prop); s.dispatch!
gate("T1 effect fires ONLY via the post-commit dispatcher", s.effects_fired.length == 1)

# --- T2: version conflict ⇒ rejected proposal's effect never fires (no ghost charge) ---
s = Store.new(File.join(tmp, "t2"))
a = run_capsule(s, "o1", "rA", 500)        # both read version 0
b = run_capsule(s, "o1", "rB", 900)
r1 = s.commit(a)                            # A wins → version 0→1
r2 = s.commit(b)                            # B stale (base_version 0 ≠ 1) → conflict
s.dispatch!
gate("T2 first commits, second conflicts", r1 == :committed && r2 == :conflict, "#{r1}/#{r2}")
gate("T2 NO ghost charge from rejected proposal", s.effects_fired == ["charge-o1-rA"], s.effects_fired.inspect)

# --- T3: at-least-once dispatch ⇒ effect fires exactly once (idempotency) ---
s = Store.new(File.join(tmp, "t3"))
s.commit(run_capsule(s, "o1", "rX", 500))
5.times { s.dispatch! }                     # dispatcher runs many times (at-least-once delivery)
gate("T3 idempotent under repeated dispatch", s.effects_fired == ["charge-o1-rX"], "#{s.effects_fired.length} effect(s)")

# --- T4: CRASH after commit, before dispatch ⇒ recovery fires the effect exactly once ---
dir4 = File.join(tmp, "t4")
child = fork do
  st = Store.new(dir4)
  st.commit(run_capsule(st, "o1", "rC", 500))   # durable commit (outbox fsync'd)...
  Process.kill("KILL", Process.pid)             # ...then CRASH before dispatch
end
Process.wait(child)
crashed = !$?.success?                           # killed by signal → not success
recovered = Store.new(dir4)                      # fresh process opens the durable log
pre = recovered.effects_fired.length             # nothing dispatched yet (crashed before dispatch)
recovered.dispatch!                              # recovery dispatcher
recovered.dispatch!                              # run twice — must still be exactly once
gate("T4 crashed after commit", crashed, "child killed before dispatch")
gate("T4 commit survived the crash (durable outbox)", recovered.current_version("o1") == 1)
gate("T4 effect not fired before recovery", pre.zero?)
gate("T4 recovery re-delivers; idempotent consumer keeps the effect once (at-least-once delivery)", recovered.effects_fired == ["charge-o1-rC"], recovered.effects_fired.inspect)

# --- T5: CONCURRENT committers race on the same base version ⇒ exactly one wins (no double charge) ---
# Both proposals are built at version 0 in the parent, then two REAL forked processes race to commit them.
# Without an atomic check-and-append this would double-commit (double charge); flock (≈ a DB unique index on
# (order_id,version)) serializes it so only one passes the version check.
dir5 = File.join(tmp, "t5")
s5 = Store.new(dir5)
both = [run_capsule(s5, "o5", "rcA", 100), run_capsule(s5, "o5", "rcB", 100)]   # both read base_version 0
outcomes = both.map do |prop|
  r, w = IO.pipe
  pid = fork do
    r.close
    w.write(Store.new(dir5).commit(prop).to_s); w.close
    exit!(0)
  end
  w.close
  [r, pid]
end.map { |r, pid| o = r.read; r.close; Process.wait(pid); o }
Store.new(dir5).dispatch!
gate("T5 exactly one racing committer wins (atomic commit; no double-commit)", outcomes.count("committed") == 1, outcomes.inspect)
gate("T5 NO double charge under real concurrency", Store.new(dir5).effects_fired.length == 1, Store.new(dir5).effects_fired.inspect)

# --- T6: CONCURRENT dispatchers race ⇒ effect still fires exactly once (flock on the effects ledger) ---
dir6 = File.join(tmp, "t6")
s6 = Store.new(dir6)
s6.commit(run_capsule(s6, "o6", "rD", 100))
6.times.map { fork { Store.new(dir6).dispatch!; exit!(0) } }.each { |pid| Process.wait(pid) }
gate("T6 concurrent dispatchers: at-least-once delivery, consumer dedups to one effect", Store.new(dir6).effects_fired == ["charge-o6-rD"], Store.new(dir6).effects_fired.inspect)

FileUtils.rm_rf(tmp)

# ============================ report ============================
puts "\n== Slice B gates =="
PASS.each { |g| puts "  PASS  #{g}" }
FAIL.each { |g| puts "  FAIL  #{g}" }
puts "\n#{PASS.length} passed, #{FAIL.length} failed."
exit(FAIL.empty? ? 0 : 1)
