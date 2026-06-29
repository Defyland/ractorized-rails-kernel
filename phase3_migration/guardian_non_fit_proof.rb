# frozen_string_literal: true

# Reproducible non-fit proof for Discourse Guardian#can_edit_post?.
# Scope is intentionally honest:
# - Reads the real lib/guardian/post_guardian.rb predicate and reports the
#   exact lines that touch live mutable state, SiteSetting, globals, or recursive
#   Guardian predicates.
# - Runs a faithful minimal slice for the owner-edit case to show that a frozen
#   answer/snapshot goes stale after ordinary mutations or clock movement.
# - Does not boot Rails and does not execute the real Guardian object.
#
# Run:
#   ruby phase3_migration/guardian_non_fit_proof.rb [path-to-discourse]
require "json"
require "digest"

root = File.expand_path(ARGV[0] || File.join(__dir__, "discourse"))
file = File.join(root, "lib/guardian/post_guardian.rb")
abort("missing #{file}") unless File.file?(file)

lines = File.readlines(file, encoding: "UTF-8").map(&:scrub)
start_idx = lines.index { |line| line.match?(/^\s+def can_edit_post\?\(post\)/) }
abort("can_edit_post? not found in #{file}") unless start_idx

next_method_idx =
  ((start_idx + 1)...lines.length).find { |idx| lines[idx].match?(/^\s+def /) } || lines.length
body_lines = lines[start_idx...next_method_idx]

READ_PATTERNS = {
  discourse_global: /Discourse\./,
  site_setting: /SiteSetting\./,
  post_state: /\bpost\./,
  topic_or_category_state: /\bpost\.topic|\.category\b/,
  user_state: /@user\b|\buser\b/,
  recursive_guardian_predicate: /\b(can_|is_|trusted_with_)[a-z_?!]+\(/,
  clock_dependent: /edit_time_limit_expired\?|\.ago\b|Time\.|Date\./,
}.freeze

live_reads =
  body_lines.each_with_index.flat_map do |line, offset|
    READ_PATTERNS.filter_map do |kind, regex|
      next unless line.match?(regex)
      next if kind == :recursive_guardian_predicate && line.match?(/^\s*def /)

      {
        line: start_idx + offset + 1,
        category: kind,
        code: line.strip,
      }
    end
  end

LivePost = Struct.new(:owner_id, :created_at, :locked, :deleted_at)

def live_owner_edit_slice(post, user_id:, staff:, edit_time_limit_secs:, now:)
  return false if post.locked && !staff
  return false if post.deleted_at
  return false unless post.owner_id == user_id

  !((now - post.created_at) > edit_time_limit_secs)
end

post = LivePost.new(7, 1_000.0, false, nil)
ctx = { user_id: 7, staff: false, edit_time_limit_secs: 300, now: 1_060.0 }
snapshot_answer = live_owner_edit_slice(post, **ctx)

mutations = []

post.locked = true
live = live_owner_edit_slice(post, **ctx)
mutations << { mutation: "post.locked = true", live: live, snapshot: snapshot_answer, stale: live != snapshot_answer }
post.locked = false

later = ctx.merge(now: 1_400.0)
live = live_owner_edit_slice(post, **later)
mutations << { mutation: "clock advances past edit_time_limit", live: live, snapshot: snapshot_answer, stale: live != snapshot_answer }

post.deleted_at = 1_200.0
live = live_owner_edit_slice(post, **ctx)
mutations << { mutation: "post.deleted_at set", live: live, snapshot: snapshot_answer, stale: live != snapshot_answer }

result = {
  commit: Dir.chdir(root) { `git rev-parse HEAD`.strip },
  predicate: "Guardian#can_edit_post?",
  file: "lib/guardian/post_guardian.rb",
  source_sha256: Digest::SHA256.file(file).hexdigest,
  line_range: [start_idx + 1, next_method_idx],
  evidence_scope: "static real-source dependency extraction plus faithful owner-edit stale-snapshot slice; not a Rails boot test",
  live_reads_observed: live_reads.uniq,
  stale_snapshot_slice: {
    initial_snapshot_answer: snapshot_answer,
    mutations: mutations,
    stale_count: mutations.count { |m| m[:stale] },
  },
  conclusion: "Guardian is structural non-fit for Frozen Read-Model Capsules.",
  reason: "Correctness depends on live post/topic/category/user state, SiteSetting/global reads, recursive Guardian predicates, and wall-clock edit limits. Keeping a frozen capsule correct would require owner round-trips per decision.",
}

puts JSON.pretty_generate(result)

exit(result[:stale_snapshot_slice][:stale_count] == 3 && live_reads.any? ? 0 : 1)
