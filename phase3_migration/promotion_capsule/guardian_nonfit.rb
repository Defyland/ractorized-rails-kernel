# frozen_string_literal: true

# Phase 3 — minimal proof that Guardian#can_edit_post? is a NON-FIT for a frozen capsule.
# Grounded in the real dependencies of discourse/lib/guardian/post_guardian.rb#can_edit_post?:
# it branches on LIVE mutable state — post.locked?, post.deleted_at, post.edit_time_limit_expired?
# (CLOCK-dependent), @user.silenced?, ~10 SiteSettings, Discourse.static_doc_topic_ids, plus ~10
# recursive guardian predicates. A snapshot of the answer goes stale the instant any of that changes.
#
# We model a faithful SLICE (owner's own post): can edit iff not locked, not deleted, and the edit
# time-limit hasn't expired. Then we snapshot the answer and mutate the world — and show the snapshot
# disagrees with a live re-check. Correctness would require an owner round-trip (defeating the capsule).
Warning[:experimental] = false

LivePost = Struct.new(:owner_id, :created_at, :locked, :deleted_at)

# A faithful slice of can_edit_post? for the owner's own post (see post_guardian.rb).
def live_can_edit?(post, user_id:, staff:, edit_time_limit_secs:, now:)
  return false if post.locked && !staff                 # post.locked? && !is_staff?
  return false if post.deleted_at                       # post.deleted_at
  return false unless post.owner_id == user_id          # is_my_own?
  !((now - post.created_at) > edit_time_limit_secs)      # !post.edit_time_limit_expired?(@user)
end

post = LivePost.new(owner_id: 7, created_at: 1_000.0, locked: false, deleted_at: nil)
ctx = { user_id: 7, staff: false, edit_time_limit_secs: 300, now: 1_060.0 } # 60s after creation, limit 300s

# Capsule would freeze the ANSWER (or the inputs) at decision time:
snapshot_answer = live_can_edit?(post, **ctx)
puts "t0  snapshot says can_edit? = #{snapshot_answer}  (frozen)"

stale = []

# (1) the post gets locked a moment later (a concurrent mutation)
post.locked = true
live1 = live_can_edit?(post, **ctx)
stale << "post.locked? flipped -> live=#{live1}, snapshot=#{snapshot_answer}" if live1 != snapshot_answer
post.locked = false

# (2) the edit time-limit simply EXPIRES with the clock — no data changed, only `now` advanced
ctx_later = ctx.merge(now: 1_400.0) # 400s after creation, past the 300s limit
live2 = live_can_edit?(post, **ctx_later)
stale << "clock advanced past edit_time_limit -> live=#{live2}, snapshot=#{snapshot_answer}" if live2 != snapshot_answer

# (3) the post gets soft-deleted
post.deleted_at = 1_200.0
live3 = live_can_edit?(post, **ctx)
stale << "post.deleted_at set -> live=#{live3}, snapshot=#{snapshot_answer}" if live3 != snapshot_answer
post.deleted_at = nil

puts "\nStale divergences after the snapshot was taken:"
stale.each { |s| puts "  - #{s}" }

LIVE_READS_FOR_CORRECTNESS = [
  "post.locked? / post.deleted_at / post.user_deleted / post.hidden? / post.wiki / post.archived?",
  "post.edit_time_limit_expired?(@user)  # depends on the WALL CLOCK",
  "@user.admin? / staff? / silenced? / in_any_groups?(...)",
  "~10 SiteSettings (shared_drafts_category, edit_wiki_post_allowed_groups_map, ...)",
  "Discourse.static_doc_topic_ids",
  "~10 recursive guardian predicates (can_create_post?, can_see_post_topic?, ...) each reading more live state",
]

puts "\nVERDICT: Guardian#can_edit_post? is a NON-FIT for a frozen capsule."
puts "A snapshot is stale on the very next mutation OR clock tick (#{stale.size}/3 mutations diverged here)."
puts "To stay correct the capsule would need owner round-trips for every live read below — i.e. it stops"
puts "being a capsule. The thesis exclusion of live-lookup authorization is confirmed on real code:"
LIVE_READS_FOR_CORRECTNESS.each { |r| puts "  * #{r}" }
exit(stale.size == 3 ? 0 : 1)
