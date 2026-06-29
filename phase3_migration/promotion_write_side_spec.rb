# frozen_string_literal: true

# Phase 3 — Promotion WRITE-SIDE migration SPEC (machine-readable blocker, NOT an implementation).
#
# promotion_write_side_gap.rb proves the blocker exists (inline write effects, zero capsule-protocol tokens →
# eligibility_only). This goes one step further WITHOUT writing any Discourse code: it maps each real inline
# side effect in lib/promotion.rb#change_trust_level! to the exact capsule construct it WOULD become (owner
# commit vs outbox EffectIntent vs owner-side residue), and emits the smallest realistic patch shape. It still
# asserts the patch is NOT present (no Proposal/EffectIntent/Outbox tokens), so the artifact can never be read
# as "write-side migrated". Pure static analysis of the real Discourse source — no Postgres, no boot.
#
# Run:
#   JSON_OUT=phase3_migration/raw_logs/promotion_write_side_spec_latest.json \
#     ruby phase3_migration/promotion_write_side_spec.rb [path-to-discourse]
require "json"
require "digest"
require "time"

ROOT = File.expand_path(ARGV[0] || File.join(__dir__, "discourse"))
FILE = File.join(ROOT, "lib/promotion.rb")
JSON_OUT = ENV["JSON_OUT"]
abort("missing #{FILE}") unless File.file?(FILE)

lines = File.readlines(FILE, encoding: "UTF-8").map(&:scrub)

# Each real write-side effect → where it lands in the capsule protocol. `kind`:
#   commit  = owner-side optimistic AR write (the trust-level state change itself; NOT an outbox effect)
#   effect  = idempotent outbox EffectIntent (at-least-once, deduped by idempotency_key on the consumer)
#   residue = owner-side pre-resolve / native call that cannot cross into a Ractor (stays on the owner)
# idempotency_key_basis is the deterministic token the consumer dedups on (exactly-once ENQUEUE, at-least-once
# idempotent DISPATCH — never exactly-once external effect).
MAPPING = {
  /change_trust_level!/ => { kind: "commit", effect_intent: nil,
                             note: "the trust_level state change is the owner optimistic COMMIT, not an outbox effect" },
  /@user\.save!/ => { kind: "commit", effect_intent: nil,
                      note: "persisting the user row is part of the owner commit" },
  /update_column/ => { kind: "commit", effect_intent: nil,
                       note: "direct column write is owner-side commit (skips callbacks)" },
  /UserHistory\.create!/ => { kind: "effect", effect_intent: "user_history",
                              idempotency_key_basis: "user_id+target_trust_level+'user_history'" },
  /StaffActionLogger/ => { kind: "effect", effect_intent: "staff_action_log",
                           idempotency_key_basis: "user_id+target_trust_level+'staff_action'" },
  /DiscourseEvent\.trigger/ => { kind: "effect", effect_intent: "discourse_event_user_promoted",
                                 idempotency_key_basis: "user_id+target_trust_level+'user_promoted'" },
  /Group\.user_trust_level_change!/ => { kind: "effect", effect_intent: "group_trust_level_change",
                                         idempotency_key_basis: "user_id+target_trust_level+'group_change'" },
  /BadgeGranter\.queue_badge_grant/ => { kind: "effect", effect_intent: "badge_grant",
                                         idempotency_key_basis: "user_id+target_trust_level+'badge'" },
  /enqueue_member_welcome_message/ => { kind: "effect", effect_intent: "member_welcome_message",
                                        idempotency_key_basis: "user_id+'tl1_welcome'" },
  /enqueue_tl2_promotion_message/ => { kind: "effect", effect_intent: "tl2_promotion_message",
                                       idempotency_key_basis: "user_id+'tl2_promotion'" },
  /recook_bio/ => { kind: "residue", effect_intent: nil,
                    note: "PrettyText/native cook — owner-side pre-resolve, cannot run in a Ractor" },
}.freeze

PROTOCOL_RE = /\b(Proposal|EffectIntent|Outbox|OutboxEvent|idempotency_key)\b/

found = lines.each_with_index.filter_map do |line, idx|
  hit = MAPPING.find { |re, _| line.match?(re) }
  next unless hit
  re, spec = hit
  { "line" => idx + 1, "code" => line.strip, "pattern" => re.source.gsub(/\\/, "") }.merge(spec.transform_keys(&:to_s))
end

protocol_present = lines.any? { |line| line.match?(PROTOCOL_RE) }
covered_patterns = found.map { |row| row["pattern"] }.uniq

by_kind = found.group_by { |row| row["kind"] }.transform_values(&:size)
effects = found.select { |row| row["kind"] == "effect" }

result = {
  "generated_at_utc" => Time.now.utc.iso8601,
  "commit" => Dir.chdir(ROOT) { `git rev-parse HEAD`.strip },
  "file" => "lib/promotion.rb",
  "source_sha256" => Digest::SHA256.file(FILE).hexdigest,
  "spec_runner_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
  "classification" => protocol_present ? "write_side_protocol_present" : "eligibility_only",
  "write_side_implemented" => protocol_present,
  "inline_effect_count" => found.size,
  "by_kind" => by_kind,
  "effect_intents_required" => effects.map { |row| row["effect_intent"] }.uniq,
  "mapping" => found,
  "smallest_realistic_patch" => [
    "1. Owner builds CapsuleEligibility::Snapshot + decides target trust_level (already done — eligibility_only).",
    "2. change_trust_level! becomes: owner optimistic AR COMMIT of the trust_level change (the `commit` rows).",
    "3. Each `effect` row becomes an idempotent OutboxEvent enqueued in the SAME transaction as the commit, " \
    "keyed by idempotency_key_basis (exactly-once ENQUEUE).",
    "4. A dispatcher delivers each EffectIntent at-least-once; the consumer dedups by idempotency_key " \
    "(NOT exactly-once external effect).",
    "5. `residue` rows (recook_bio) stay owner-side (native, pre-resolved).",
  ],
  "blocker" => "This SPEC is not implemented in Discourse: no Proposal/EffectIntent/Outbox/idempotency_key tokens " \
               "exist in lib/promotion.rb. Promotion remains eligibility_only; the write side is mapped, not migrated.",
}

puts JSON.pretty_generate(result)
File.write(File.expand_path(JSON_OUT, Dir.pwd), JSON.pretty_generate(result)) if JSON_OUT

# Exit non-zero unless: write side NOT implemented, real effects exist, AND every found line has a mapping kind.
ok = !protocol_present && effects.any? && found.all? { |row| %w[commit effect residue].include?(row["kind"]) }
exit(ok ? 0 : 1)
