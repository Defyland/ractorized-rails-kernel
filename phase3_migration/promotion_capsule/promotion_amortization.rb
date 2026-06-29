# frozen_string_literal: true

# Phase 3 — Promotion AMORTIZATION gate. The per-call bench (bench.rb) showed owner snapshot build + decide is
# SLOWER than inline (~0.27x). This asks the next question: is there a BATCH size N where building the capsule
# snapshots + deciding (in parallel Ractors) beats inline×N — i.e. does the boundary ever amortize?
#
# Variants per N (total wall time, best-of REPS to cut noise):
#   a) inline×N                         — the pre-migration baseline (full logic, live calc per user)
#   b) capsule seq: (build+decide)×N    — the naive migration, sequential
#   c) capsule par: build N + decide N across RACTORS — owner builds sequentially, decide parallelizes
#   d) frozen-reuse par: decide N across RACTORS on ONE shared snapshot — the parallel UPPER BOUND, but NOT a
#      real Promotion scenario (every user has distinct user_stat fields → they do NOT share one snapshot)
#
# Expected result is NEGATIVE and we do not try to save the thesis: the per-user owner build is paid
# sequentially for every user and already costs more than inline, so (b) and (c) can never beat inline×N for
# Promotion. Only (d) — a shared snapshot AND an expensive decide — could cross over, and Promotion has neither
# (snapshot is 537 bytes / ~10 integer compares). Platform-robust pure-compute throughput (no /proc, no PSS).
Warning[:experimental] = false
require "digest"
require "json"
require "time"
require_relative "capsule_eligibility"

CAPSULE_PATH = File.expand_path("capsule_eligibility.rb", __dir__)

# Same realistic tl1→tl2 mock + settings as bench.rb (copied: this is a standalone probe; a sanity assert below
# guards that the inline path and the capsule decide still agree, so a drift in either is caught).
Mock = Struct.new(:trust_level, :manual_locked, :created_at_epoch,
                  :topics_entered, :posts_read_count, :time_read, :days_visited,
                  :likes_received, :likes_given, :_calc_calls) do
  def calc_topic_reply_count!
    self._calc_calls += 1
    10
  end
end
SS = { tl1_requires_topics_entered: 5, tl1_requires_read_posts: 30, tl1_requires_time_spent_mins: 10,
       tl2_requires_topics_entered: 20, tl2_requires_read_posts: 100, tl2_requires_time_spent_mins: 60,
       tl2_requires_days_visited: 15, tl2_requires_likes_received: 20, tl2_requires_likes_given: 30,
       tl2_requires_topic_reply_count: 10 }.freeze
NOW = 9_999_999.0

def mk = Mock.new(1, false, 0.0, 20, 100, 3660, 15, 20, 30, 0)

def inline_full(m, ss, now)
  return nil if m.manual_locked
  if m.trust_level == 0
    return 1 if inline_tl1?(m, ss, now)
  elsif m.trust_level == 1
    return 2 if inline_tl2?(m, ss, now)
  end
  nil
end

def inline_tl1?(m, ss, now)
  return false if m.topics_entered < ss[:tl1_requires_topics_entered]
  return false if m.posts_read_count < ss[:tl1_requires_read_posts]
  return false if (m.time_read / 60) < ss[:tl1_requires_time_spent_mins]
  return false if ((now - m.created_at_epoch) / 60) < ss[:tl1_requires_time_spent_mins]
  true
end

def inline_tl2?(m, ss, now)
  return false if m.topics_entered < ss[:tl2_requires_topics_entered]
  return false if m.posts_read_count < ss[:tl2_requires_read_posts]
  return false if (m.time_read / 60) < ss[:tl2_requires_time_spent_mins]
  return false if ((now - m.created_at_epoch) / 60) < ss[:tl2_requires_time_spent_mins]
  return false if m.days_visited < ss[:tl2_requires_days_visited]
  return false if m.likes_received < ss[:tl2_requires_likes_received]
  return false if m.likes_given < ss[:tl2_requires_likes_given]
  return false if m.calc_topic_reply_count! < ss[:tl2_requires_topic_reply_count]
  true
end

def build_snapshot(m, ss, now)
  CapsuleEligibility::Snapshot.new(
    trust_level: m.trust_level, manual_locked: m.manual_locked,
    created_at_epoch: m.created_at_epoch, now_epoch: now,
    topics_entered: m.topics_entered, posts_read_count: m.posts_read_count,
    time_read: m.time_read, days_visited: m.days_visited,
    likes_received: m.likes_received, likes_given: m.likes_given,
    topic_reply_count: m.trust_level == 1 ? m.calc_topic_reply_count! : 0,
    tl1_requires_topics_entered: ss[:tl1_requires_topics_entered], tl1_requires_read_posts: ss[:tl1_requires_read_posts],
    tl1_requires_time_spent_mins: ss[:tl1_requires_time_spent_mins],
    tl2_requires_topics_entered: ss[:tl2_requires_topics_entered], tl2_requires_read_posts: ss[:tl2_requires_read_posts],
    tl2_requires_time_spent_mins: ss[:tl2_requires_time_spent_mins], tl2_requires_days_visited: ss[:tl2_requires_days_visited],
    tl2_requires_likes_received: ss[:tl2_requires_likes_received], tl2_requires_likes_given: ss[:tl2_requires_likes_given],
    tl2_requires_topic_reply_count: ss[:tl2_requires_topic_reply_count]
  )
end

# Drift guard across EVERY decision branch (not just the tl1→tl2 fixture the benchmark times): tl0→tl1 pass/reject,
# tl1→tl2 pass/reject, and manual_locked. A divergence between the inline path and the capsule decide on any branch
# fails here before the benchmark runs.
FIXTURES = {
  "tl0_promote_to_tl1" => Mock.new(0, false, 0.0, 5, 30, 600, 1, 0, 0, 0),
  "tl0_reject"         => Mock.new(0, false, 0.0, 4, 30, 600, 1, 0, 0, 0),
  "tl1_promote_to_tl2" => Mock.new(1, false, 0.0, 20, 100, 3660, 15, 20, 30, 0),
  "tl1_reject"         => Mock.new(1, false, 0.0, 19, 100, 3660, 15, 20, 30, 0),
  "manual_locked"      => Mock.new(1, true, 0.0, 20, 100, 3660, 15, 20, 30, 0),
}.freeze
FIXTURES.each do |name, fixture|
  inline = inline_full(fixture, SS, NOW)
  capsule = CapsuleEligibility.decide(build_snapshot(fixture, SS, NOW))
  raise "logic mismatch on #{name}: inline=#{inline.inspect} capsule=#{capsule.inspect}" unless inline == capsule
end

NS = (ENV["NS"] || "100,1000,10000").split(",").map(&:strip).reject(&:empty?).map { Integer(_1) }
RACTORS = Integer(ENV.fetch("RACTORS", "4"))
REPS = Integer(ENV.fetch("REPS", "5"))
JSON_OUT = ENV["JSON_OUT"]

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def best_of(reps)
  Array.new(reps) { t = mono; yield; mono - t }.min   # min wall = least scheduler noise
end
def shard(items, parts) = items.each_slice((items.size / parts.to_f).ceil).to_a

rows = NS.map do |n|
  users = Array.new(n) { mk }

  inline_w = best_of(REPS) { users.each { |u| inline_full(u, SS, NOW) } }
  seq_w    = best_of(REPS) { users.each { |u| CapsuleEligibility.decide(build_snapshot(u, SS, NOW)) } }

  par_w = best_of(REPS) do
    snaps = users.map { |u| Ractor.make_shareable(build_snapshot(u, SS, NOW)) }   # owner builds (sequential)
    shard(snaps, RACTORS).map { |sh| Ractor.new(sh) { |s| s.each { |x| CapsuleEligibility.decide(x) }; :ok } }.each(&:value)
  end

  shared = Ractor.make_shareable(build_snapshot(mk, SS, NOW))
  reuse_w = best_of(REPS) do
    per = (n / RACTORS.to_f).ceil
    Array.new(RACTORS) { Ractor.new(shared, per) { |s, p| p.times { CapsuleEligibility.decide(s) }; :ok } }.each(&:value)
  end

  {
    "n" => n,
    "inline_wall_s" => inline_w,
    "capsule_seq_wall_s" => seq_w,
    "capsule_par_decide_wall_s" => par_w,
    "frozen_reuse_par_wall_s" => reuse_w,
    "capsule_seq_speedup_vs_inline" => (inline_w / seq_w),
    "capsule_par_speedup_vs_inline" => (inline_w / par_w),
    "frozen_reuse_speedup_vs_inline" => (inline_w / reuse_w),
    "capsule_seq_amortizes" => seq_w < inline_w,
    "capsule_par_amortizes" => par_w < inline_w,
  }
end

any_real_amortization = rows.any? { |r| r["capsule_seq_amortizes"] || r["capsule_par_amortizes"] }
payload_bytes = Marshal.dump(build_snapshot(mk, SS, NOW)).bytesize

summary = {
  "generated_at_utc" => Time.now.utc.iso8601,
  "ruby" => RUBY_DESCRIPTION,
  "platform" => RUBY_PLATFORM,
  "status" => "pass",
  "amortization_runner_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
  "capsule_sha256" => Digest::SHA256.file(CAPSULE_PATH).hexdigest,
  "config" => { "ns" => NS, "ractors" => RACTORS, "reps" => REPS },
  "payload_bytes" => payload_bytes,
  "rows" => rows,
  "verdict" => {
    # REAL Promotion variants are (b) capsule_seq and (c) capsule_par; both pay the per-user owner build.
    "any_real_variant_amortizes" => any_real_amortization,
    "promotion_amortizes" => any_real_amortization,
    "classification" => any_real_amortization ? "amortizes_at_batch" : "compatibility_only_no_amortization",
    # (d) frozen-reuse is the UPPER BOUND only; it is NOT a real Promotion scenario (users have distinct snapshots).
    "frozen_reuse_is_real_promotion_scenario" => false,
    "note" => "Per-user owner snapshot build is paid sequentially for every user and already costs more than inline; " \
              "a shared snapshot AND an expensive decide would be required to cross over — Promotion has neither.",
  },
}

puts "Promotion amortization (#{RUBY_DESCRIPTION})"
printf "%-7s %12s %12s %12s %12s | %8s %8s %10s\n",
       "N", "inline_s", "seq_s", "par_s", "reuse_s", "seq/inl", "par/inl", "reuse/inl"
rows.each do |r|
  printf "%-7d %12.5f %12.5f %12.5f %12.5f | %8.3f %8.3f %10.3f  amortizes(seq/par)=%s/%s\n",
         r["n"], r["inline_wall_s"], r["capsule_seq_wall_s"], r["capsule_par_decide_wall_s"], r["frozen_reuse_par_wall_s"],
         r["capsule_seq_speedup_vs_inline"], r["capsule_par_speedup_vs_inline"], r["frozen_reuse_speedup_vs_inline"],
         r["capsule_seq_amortizes"], r["capsule_par_amortizes"]
end
puts "VERDICT: #{summary['verdict']['classification']} (any real variant amortizes = #{any_real_amortization})"
puts "  frozen-reuse speedup is an UPPER BOUND only — Promotion users have distinct snapshots, so it is not a real scenario."

if JSON_OUT
  File.write(JSON_OUT, JSON.pretty_generate(summary))
  puts "JSON written: #{JSON_OUT}"
end
