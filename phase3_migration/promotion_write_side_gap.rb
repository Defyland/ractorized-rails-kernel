# frozen_string_literal: true

# Verifies the remaining write-side gap in the real Discourse Promotion patch.
# This intentionally fails any attempt to claim a full Discourse capsule while
# change_trust_level!/review_tl* still perform inline AR writes or side effects.
#
# Run:
#   ruby phase3_migration/promotion_write_side_gap.rb [path-to-discourse]
require "json"
require "digest"

root = File.expand_path(ARGV[0] || File.join(__dir__, "discourse"))
file = File.join(root, "lib/promotion.rb")
abort("missing #{file}") unless File.file?(file)

lines = File.readlines(file, encoding: "UTF-8").map(&:scrub)

SIDE_EFFECT_RE = /
  enqueue_(member_welcome|tl2_promotion)_message |
  StaffActionLogger |
  UserHistory\.create! |
  @user\.save! |
  recook_bio |
  DiscourseEvent\.trigger |
  Group\.user_trust_level_change! |
  BadgeGranter\.queue_badge_grant |
  update_column |
  change_trust_level!
/x

CAPSULE_PROTOCOL_RE = /\b(Proposal|EffectIntent|Outbox|OutboxEvent|idempotency_key)\b/

side_effects =
  lines.each_with_index.filter_map do |line, idx|
    next unless line.match?(SIDE_EFFECT_RE)
    { line: idx + 1, code: line.strip }
  end

protocol_mentions =
  lines.each_with_index.filter_map do |line, idx|
    next unless line.match?(CAPSULE_PROTOCOL_RE)
    { line: idx + 1, code: line.strip }
  end

eligibility_capsule =
  lines.any? { |line| line.include?("module Eligibility") } &&
    lines.any? { |line| line.include?("Snapshot =") || line.include?("Snapshot=") }

result = {
  commit: Dir.chdir(root) { `git rev-parse HEAD`.strip },
  file: "lib/promotion.rb",
  source_sha256: Digest::SHA256.file(file).hexdigest,
  classification: protocol_mentions.empty? ? "eligibility_only" : "write_side_protocol_present",
  eligibility_capsule_present: eligibility_capsule,
  capsule_protocol_mentions: protocol_mentions,
  inline_write_side_effects: side_effects,
  conclusion: if protocol_mentions.empty?
    "Promotion patch validates eligibility extraction only; Proposal + EffectIntent + outbox are not implemented in real Discourse."
  else
    "Promotion contains capsule protocol tokens; inspect manually before claiming full write-side migration."
  end,
}

puts JSON.pretty_generate(result)

exit(protocol_mentions.empty? && side_effects.any? ? 0 : 1)
