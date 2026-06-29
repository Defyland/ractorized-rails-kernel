# frozen_string_literal: true

# Phase 3 — HONEST before/after benchmark for the Promotion eligibility migration.
# apples-to-apples: the "before" (inline) runs the FULL eligibility logic (all tl1 + tl2 guards,
# including the live calc_topic_reply_count!) directly off a realistic mock — exactly what the capsule
# computes. We separate every cost so the Ractor speedup is NOT sold without the snapshot/boundary cost:
#   - inline full (before)        : pre-migration per-call cost (reads mock live, calls calc each time)
#   - owner snapshot build + decide: post-migration per-call cost on the OWNER (builds the snapshot)
#   - decide only (pre-built)      : the PURE part that actually runs in the Ractor
#   - decide x4 Ractors            : the parallel upside — applies ONLY to the pure decide
# NOTE: calc_topic_reply_count! is a DB query in real Discourse; here it is a cheap stand-in, so the
# real owner-side build cost is UNDER-counted — the boundary cost is a floor, not the full story.
Warning[:experimental] = false
require "digest"
require "json"
require "time"
require_relative "capsule_eligibility"

CAPSULE_PATH = File.expand_path("capsule_eligibility.rb", __dir__)

# realistic mock: a trust_level-1 user that MEETS tl2 (so the full 8-guard tl2 path executes).
Mock = Struct.new(:trust_level, :manual_locked, :created_at_epoch,
                  :topics_entered, :posts_read_count, :time_read, :days_visited,
                  :likes_received, :likes_given, :_calc_calls) do
  def calc_topic_reply_count! # live residual in real Discourse (a query+mutation); cheap stand-in here
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

# "before": the COMPLETE original logic (mirrors lib/promotion.rb tl1_met?/tl2_met? + the ladder),
# reading the mock live and calling calc_topic_reply_count! inline — same result the capsule computes.
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

# owner-side snapshot build (the migration's per-call cost: reads the mock + resolves the residual).
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

# sanity: before == after (same decision) on this mock
raise "logic mismatch" unless inline_full(mk, SS, NOW) == CapsuleEligibility.decide(build_snapshot(mk, SS, NOW))

N = Integer(ENV.fetch("N", "1000000"))
PER = Integer(ENV.fetch("PER_RACTOR", "2000000"))
JSON_OUT = ENV["JSON_OUT"]
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def bench(n) = (t = now; n.times { yield }; n / (now - t))

inline   = bench(N) { inline_full(mk, SS, NOW) }                       # before (full logic)
snap_pc  = bench(N) { CapsuleEligibility.decide(build_snapshot(mk, SS, NOW)) } # after, build EVERY call
pre      = build_snapshot(mk, SS, NOW)
snap_1   = bench(N) { CapsuleEligibility.decide(pre) }                 # after, snapshot reused (decide only)
shared   = Ractor.make_shareable(pre)
# large per-Ractor workload so spawn/startup overhead amortizes (fair parallel read)
t = now
Array.new(4) { Ractor.new(shared) { |s| PER.times { CapsuleEligibility.decide(s) }; :ok } }.each(&:value)
par = (PER * 4) / (now - t)
payload_bytes = Marshal.dump(pre).bytesize
payload_fields = CapsuleEligibility::Snapshot.members.size
owner_ratio = snap_pc / inline
parallel_ratio = par / snap_1

summary = {
  generated_at_utc: Time.now.utc.iso8601,
  ruby: RUBY_DESCRIPTION,
  status: "pass",
  bench_sha256: Digest::SHA256.file(__FILE__).hexdigest,
  capsule_sha256: Digest::SHA256.file(CAPSULE_PATH).hexdigest,
  correct: inline_full(mk, SS, NOW) == CapsuleEligibility.decide(build_snapshot(mk, SS, NOW)),
  config: {
    n: N,
    per_ractor: PER,
    ractors: 4,
  },
  throughput: {
    inline_full_before_decisions_s: inline,
    owner_snapshot_build_plus_decide_decisions_s: snap_pc,
    decide_only_snapshot_reused_decisions_s: snap_1,
    decide_only_x4_ractors_decisions_s: par,
  },
  ratios: {
    owner_snapshot_build_plus_decide_vs_inline: owner_ratio,
    decide_x4_ractors_vs_decide_only: parallel_ratio,
  },
  payload: {
    fields: payload_fields,
    bytes: payload_bytes,
  },
  interpretation: {
    compatibility_only_not_end_to_end_win: owner_ratio < 1.0,
    pure_decide_parallelizes: parallel_ratio > 1.0,
    owner_build_cost_included: true,
    calc_topic_reply_count_is_under_counted_mock: true,
  },
}

puts format("inline full (BEFORE, per call)        : %9.0f decisions/s", inline)
puts format("owner snapshot build + decide (AFTER) : %9.0f decisions/s  (%.2fx vs before — the per-call migration cost)", snap_pc, owner_ratio)
puts format("decide only, snapshot reused          : %9.0f decisions/s  (the PURE part that runs in the Ractor)", snap_1)
puts format("decide only x4 Ractors                : %9.0f decisions/s  (%.2fx vs 1 — parallelism applies ONLY to the pure decide)", par, parallel_ratio)
puts "snapshot payload: #{payload_fields} fields, #{payload_bytes} bytes"
puts "HONEST READ: the migration's real per-call cost is the OWNER snapshot build (#{owner_ratio.round(2)}x the inline cost,"
puts "and UNDER-counted here because calc_topic_reply_count! is a real DB query in production). The #{parallel_ratio.round(1)}x"
puts "parallel speedup is on the PURE decide only — you still pay the owner build per call. Not an end-to-end win by itself."

if JSON_OUT
  File.write(JSON_OUT, JSON.pretty_generate(summary))
  puts "JSON written: #{JSON_OUT}"
end
