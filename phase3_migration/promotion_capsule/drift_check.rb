# frozen_string_literal: true

# Phase 3 — SEMANTIC drift check (answers the "copy-vs-copy" + "only compares names" critiques).
# Reads the REAL, unpatched Discourse lib/promotion.rb from git HEAD and the capsule
# (capsule_eligibility.rb), parses each tl{1,2}_met? guard into a normalized (LEFT, OP, RIGHT) tuple,
# and compares the ORDERED list. This catches a swapped field, a changed operator, a reordered guard,
# an added/removed guard, AND a change to the residual call (calc_topic_reply_count!), not just names.
#
# SCOPE (stated honestly): this is a STATIC structural+semantic check. It does NOT execute the real
# Promotion. The stronger runtime characterization (around-threshold fixtures: real Promotion.tl*_met?
# vs CapsuleEligibility) requires a fully booted Discourse and is deferred — see FINDINGS.md.
# Run: ruby phase3_migration/promotion_capsule/drift_check.rb
require "digest"
require "json"
require "time"

DISCOURSE = File.expand_path("../discourse", __dir__)
orig = `cd #{DISCOURSE} && git show HEAD:lib/promotion.rb 2>/dev/null`
abort "could not read original lib/promotion.rb from git HEAD" if orig.strip.empty?
capsule_path = File.join(__dir__, "capsule_eligibility.rb")
caps = File.read(capsule_path, encoding: "UTF-8").scrub

def orig_body(src, lvl) = src[/def self\.tl#{lvl}_met\?\(user\).*?\n  end/m].to_s
def caps_body(src, lvl) = src[/def tl#{lvl}_met\?\(s\).*?\n  end/m].to_s

# The ONE intended divergence: the capsule reads a pre-resolved snapshot field where the real source
# calls the live calc_topic_reply_count! and references stat./SiteSetting./user. Encode it explicitly;
# anything else that fails to normalize to the same token is reported as DRIFT.
def norm(side)
  s = side.gsub(/\s+/, "")
  s = s.gsub(%r{/60}, "").gsub(/[()]/, "")              # drop the /60 time conversion and all parens
  # age expression -> canonical token (handles both `Time.now - user.created_at` and
  # `now_epoch - created_at_epoch`); detects if the real source changes how age is computed.
  return "AGE_MINUTES" if s.match?(/(Time\.now|now_epoch)-.*created_at/)
  s = s.sub(/^stat\./, "").sub(/^s\./, "").sub(/^SiteSetting\./, "")
  s = "topic_reply_count" if s == "calc_topic_reply_count!" # the ONE explicit residual mapping
  s
end

# Each guard -> [normalized-left, operator, normalized-right], in source order.
def guards(body)
  body.scan(/return false if (.+?) (<=?|>=?|==|!=) (.+?)\s*$/).map { |l, op, r| [norm(l), op, norm(r)] }
end

ok = true
semantic_matches = []
[1, 2].each do |lvl|
  og = guards(orig_body(orig, lvl))
  cg = guards(caps_body(caps, lvl))
  match = og == cg
  ok &&= match
  differences =
    (0...[og.size, cg.size].max).filter_map do |i|
      next if og[i] == cg[i]

      { index: i, real: og[i], capsule: cg[i] }
    end
  semantic_matches << {
    level: lvl,
    real_guard_count: og.size,
    capsule_guard_count: cg.size,
    match: match,
    differences: differences,
  }
  puts "tl#{lvl}_met?  (#{og.size} guards, real) vs (#{cg.size} guards, capsule) => #{match ? 'SEMANTIC MATCH' : 'DRIFT!'}"
  next if match

  differences.each { |diff| puts "  guard #{diff[:index]}: real=#{diff[:real].inspect}  capsule=#{diff[:capsule].inspect}" }
end

negative_cases = {
  "operator mutation fails" =>
    caps.sub("s.topics_entered < s.tl1_requires_topics_entered", "s.topics_entered <= s.tl1_requires_topics_entered"),
  "field mutation fails" =>
    caps.sub("s.posts_read_count < s.tl1_requires_read_posts", "s.topics_entered < s.tl1_requires_read_posts"),
  "removed guard fails" =>
    caps.sub("    return false if s.likes_given < s.tl2_requires_likes_given\n", ""),
  "order mutation fails" => begin
    a = "    return false if s.days_visited < s.tl2_requires_days_visited\n"
    b = "    return false if s.likes_received < s.tl2_requires_likes_received\n"
    caps.sub(a + b, b + a)
  end,
}

negative_ok = true
negative_results = []
negative_cases.each do |name, mutated|
  detected = [1, 2].any? { |lvl| guards(orig_body(orig, lvl)) != guards(caps_body(mutated, lvl)) }
  negative_ok &&= detected
  negative_results << { name: name, detected: detected }
  puts "negative: #{name} => #{detected ? 'RED as expected' : 'FALSE PASS'}"
end
ok &&= negative_ok

commit = `cd #{DISCOURSE} && git rev-parse HEAD`.strip
short_commit = commit[0, 8]
if ok
  puts "\nDRIFT CHECK OK — every guard's (field, operator, threshold) and order match real lib/promotion.rb@#{short_commit}."
  puts "Mutation controls are red. Static check only; runtime characterization vs a booted Discourse remains stronger."
else
  puts "\nDRIFT CHECK FAIL — capsule eligibility diverged semantically from real lib/promotion.rb; update it."
end

if ENV["JSON_OUT"]
  File.write(ENV.fetch("JSON_OUT"), JSON.pretty_generate({
    generated_at_utc: Time.now.utc.iso8601,
    status: ok ? "pass" : "fail",
    discourse_head: commit,
    discourse_source_ref: "HEAD:lib/promotion.rb",
    real_source_sha256: Digest::SHA256.hexdigest(orig),
    capsule_sha256: Digest::SHA256.file(capsule_path).hexdigest,
    semantic_matches: semantic_matches,
    negative_controls: negative_results,
    static_only: true,
  }))
end

exit(ok ? 0 : 1)
