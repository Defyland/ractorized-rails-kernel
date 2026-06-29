# frozen_string_literal: true

# Phase 3 — proof that the extracted Promotion eligibility is a real capsule:
#  (1) it computes the SAME decision as Discourse's original logic (faithful extraction),
#  (2) it runs inside a NON-MAIN Ractor over a frozen snapshot (so it provably touches no globals),
#  (3) the snapshot is Ractor.shareable? and small,
#  (4) a static check confirms the capsule file references no forbidden global.
# Run: ruby phase3_migration/promotion_capsule/proof.rb
Warning[:experimental] = false
require "json"
require "time"
require "digest"
require_relative "capsule_eligibility"

# --- Reference = Discourse's ORIGINAL promotion.rb logic, verbatim, over mock objects -------------
# (mirrors lib/promotion.rb tl1_met?/tl2_met? and Promotion#review's tl0->tl1->tl2 ladder)
module Ref
  module_function

  def tl1_met?(u, ss, now)
    st = u[:stat]
    return false if st[:topics_entered] < ss[:tl1_requires_topics_entered]
    return false if st[:posts_read_count] < ss[:tl1_requires_read_posts]
    return false if (st[:time_read] / 60) < ss[:tl1_requires_time_spent_mins]
    return false if ((now - u[:created_at]) / 60) < ss[:tl1_requires_time_spent_mins]
    true
  end

  def tl2_met?(u, ss, now)
    st = u[:stat]
    return false if st[:topics_entered] < ss[:tl2_requires_topics_entered]
    return false if st[:posts_read_count] < ss[:tl2_requires_read_posts]
    return false if (st[:time_read] / 60) < ss[:tl2_requires_time_spent_mins]
    return false if ((now - u[:created_at]) / 60) < ss[:tl2_requires_time_spent_mins]
    return false if st[:days_visited] < ss[:tl2_requires_days_visited]
    return false if st[:likes_received] < ss[:tl2_requires_likes_received]
    return false if st[:likes_given] < ss[:tl2_requires_likes_given]
    return false if st[:topic_reply_count] < ss[:tl2_requires_topic_reply_count] # calc_topic_reply_count!
    true
  end

  def decide(u, ss, now)
    return nil if u[:manual_locked]
    return 1 if u[:trust_level] == 0 && tl1_met?(u, ss, now)
    return 2 if u[:trust_level] == 1 && tl2_met?(u, ss, now)
    nil
  end
end

# --- The owner-side snapshot builder (the ONLY place globals/AR would be read in real Discourse) ---
def snapshot(u, ss, now)
  st = u[:stat]
  CapsuleEligibility::Snapshot.new(
    trust_level: u[:trust_level], manual_locked: u[:manual_locked],
    created_at_epoch: u[:created_at].to_f, now_epoch: now.to_f,
    topics_entered: st[:topics_entered], posts_read_count: st[:posts_read_count],
    time_read: st[:time_read], days_visited: st[:days_visited],
    likes_received: st[:likes_received], likes_given: st[:likes_given],
    topic_reply_count: st[:topic_reply_count],
    tl1_requires_topics_entered: ss[:tl1_requires_topics_entered],
    tl1_requires_read_posts: ss[:tl1_requires_read_posts],
    tl1_requires_time_spent_mins: ss[:tl1_requires_time_spent_mins],
    tl2_requires_topics_entered: ss[:tl2_requires_topics_entered],
    tl2_requires_read_posts: ss[:tl2_requires_read_posts],
    tl2_requires_time_spent_mins: ss[:tl2_requires_time_spent_mins],
    tl2_requires_days_visited: ss[:tl2_requires_days_visited],
    tl2_requires_likes_received: ss[:tl2_requires_likes_received],
    tl2_requires_likes_given: ss[:tl2_requires_likes_given],
    tl2_requires_topic_reply_count: ss[:tl2_requires_topic_reply_count],
  )
end

SS = { # Discourse-like default thresholds
  tl1_requires_topics_entered: 5, tl1_requires_read_posts: 30, tl1_requires_time_spent_mins: 10,
  tl2_requires_topics_entered: 20, tl2_requires_read_posts: 100, tl2_requires_time_spent_mins: 60,
  tl2_requires_days_visited: 15, tl2_requires_likes_received: 20, tl2_requires_likes_given: 30,
  tl2_requires_topic_reply_count: 10,
}.freeze

def stat(**o)
  { topics_entered: 0, posts_read_count: 0, time_read: 0, days_visited: 0,
    likes_received: 0, likes_given: 0, topic_reply_count: 0 }.merge(o)
end

NOW = 1_700_000_000.0 # fixed epoch (deterministic)
DAY = 86_400
MIN = 60

FIXTURES = {
  "tl0 did nothing -> nil" =>
    { trust_level: 0, manual_locked: false, created_at: NOW - 2 * DAY, stat: stat },
  "tl0 meets tl1, old account -> 1" =>
    { trust_level: 0, manual_locked: false, created_at: NOW - 2 * DAY,
      stat: stat(topics_entered: 5, posts_read_count: 30, time_read: 11 * MIN) },
  "tl0 meets tl1 stats but account 1min old -> nil (age gate)" =>
    { trust_level: 0, manual_locked: false, created_at: NOW - 1 * MIN,
      stat: stat(topics_entered: 5, posts_read_count: 30, time_read: 11 * MIN) },
  "tl0 manual_locked -> nil" =>
    { trust_level: 0, manual_locked: true, created_at: NOW - 30 * DAY,
      stat: stat(topics_entered: 50, posts_read_count: 300, time_read: 100 * MIN) },
  "tl1 meets tl2 -> 2" =>
    { trust_level: 1, manual_locked: false, created_at: NOW - 30 * DAY,
      stat: stat(topics_entered: 20, posts_read_count: 100, time_read: 61 * MIN,
                 days_visited: 15, likes_received: 20, likes_given: 30, topic_reply_count: 10) },
  "tl1 short on likes_given -> nil" =>
    { trust_level: 1, manual_locked: false, created_at: NOW - 30 * DAY,
      stat: stat(topics_entered: 20, posts_read_count: 100, time_read: 61 * MIN,
                 days_visited: 15, likes_received: 20, likes_given: 29, topic_reply_count: 10) },
  "tl1 short on topic_reply_count (residue field) -> nil" =>
    { trust_level: 1, manual_locked: false, created_at: NOW - 30 * DAY,
      stat: stat(topics_entered: 20, posts_read_count: 100, time_read: 61 * MIN,
                 days_visited: 15, likes_received: 20, likes_given: 30, topic_reply_count: 9) },
  "tl2 already -> nil (deferred upstream)" =>
    { trust_level: 2, manual_locked: false, created_at: NOW - 30 * DAY,
      stat: stat(topics_entered: 99, posts_read_count: 999, time_read: 999 * MIN,
                 days_visited: 99, likes_received: 99, likes_given: 99, topic_reply_count: 99) },
}.freeze

# --- (4) static check: the capsule file must reference NO forbidden global -------------------------
forbidden = %w[SiteSetting ActiveRecord Rails. DiscourseEvent BadgeGranter Discourse. Redis redis logger]
capsule_path = File.join(__dir__, "capsule_eligibility.rb")
src = File.read(capsule_path, encoding: "UTF-8").scrub
# strip comments before scanning (the header documents the rule)
code = src.lines.reject { |l| l.strip.start_with?("#") }.join
leaks = forbidden.select { |tok| code.include?(tok) }
puts "static no-globals check: #{leaks.empty? ? 'PASS (capsule code references no global)' : "FAIL leaks=#{leaks}"}"

# --- (1)+(2)+(3): equivalence, in a real Ractor, with a shareable snapshot ------------------------
mismatches = []
fixture_results = []
ractor_ok = true
shareable_ok = true
FIXTURES.each do |name, u|
  snap = Ractor.make_shareable(snapshot(u, SS, NOW))
  snap_shareable = Ractor.shareable?(snap)
  shareable_ok &&= snap_shareable
  capsule, off_main = Ractor.new(snap) { |s| [CapsuleEligibility.decide(s), Ractor.current != Ractor.main] }.value
  ractor_ok &&= off_main
  reference = Ref.decide(u, SS, NOW)
  fixture_results << {
    name: name,
    reference: reference,
    capsule: capsule,
    ractor_off_main: off_main,
    snapshot_shareable: snap_shareable,
  }
  mismatches << [name, reference, capsule] if reference != capsule
end

snap0 = Ractor.make_shareable(snapshot(FIXTURES.values.first, SS, NOW))
payload_fields = CapsuleEligibility::Snapshot.members.size
payload_bytes = Marshal.dump(snap0).bytesize

puts "ractor decisions ran off main Ractor: #{ractor_ok ? 'yes' : 'no'} (#{FIXTURES.size} fixtures)"
puts "snapshot Ractor.shareable?: #{shareable_ok ? 'true (all)' : 'FALSE'}"
puts "snapshot payload: #{payload_fields} primitive fields, #{payload_bytes} bytes (Marshal)"
if mismatches.empty?
  puts "EQUIVALENCE: PASS — capsule decision == Discourse reference on all #{FIXTURES.size} fixtures"
else
  puts "EQUIVALENCE: FAIL"
  mismatches.each { |n, r, c| puts "  #{n}: reference=#{r.inspect} capsule=#{c.inspect}" }
end

ok = leaks.empty? && ractor_ok && shareable_ok && mismatches.empty?
puts(ok ? "\nPROOF OK" : "\nPROOF FAIL")
if ENV["JSON_OUT"]
  File.write(ENV.fetch("JSON_OUT"), JSON.pretty_generate({
    generated_at_utc: Time.now.utc.iso8601,
    status: ok ? "pass" : "fail",
    ruby: RUBY_DESCRIPTION,
    proof_sha256: Digest::SHA256.file(__FILE__).hexdigest,
    capsule_sha256: Digest::SHA256.file(capsule_path).hexdigest,
    fixture_count: FIXTURES.size,
    ractor_off_main: ractor_ok,
    snapshot_shareable: shareable_ok,
    payload_fields: payload_fields,
    payload_bytes: payload_bytes,
    forbidden_global_leaks: leaks,
    mismatch_count: mismatches.size,
    fixture_results: fixture_results,
    mismatches: mismatches.map do |name, reference, capsule|
      { fixture: name, reference: reference, capsule: capsule }
    end,
  }))
end
exit(ok ? 0 : 1)
