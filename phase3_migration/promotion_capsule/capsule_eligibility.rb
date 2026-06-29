# frozen_string_literal: true

# Phase 3 — Promotion eligibility extracted as a CAPSULE: a pure function over a frozen,
# Ractor-shareable snapshot. This is the capsule half of the Discourse Promotion migration.
#
# RULE (enforced): nothing here touches ActiveRecord, SiteSetting, DiscourseEvent, BadgeGranter,
# Rails.cache, Redis, or a logger. All inputs are plain numerics carried in the snapshot. The owner
# builds the snapshot (the ONLY place globals/AR are read); this module is what runs in the Ractor.
#
# Logic is VERBATIM from discourse/lib/promotion.rb (tl1_met?/tl2_met?), including the exact arithmetic:
#   stat.time_read / 60                       -> Integer division (time_read is Integer seconds)
#   (Time.now - user.created_at) / 60         -> Float division (age in seconds)
module CapsuleEligibility
  # Frozen, all-numeric snapshot. Every SiteSetting + user_stat + user field the rules read is lifted
  # here by the owner. Ractor.make_shareable succeeds because every member is an Integer/Float.
  Snapshot =
    Data.define(
      :trust_level,
      :manual_locked,
      :created_at_epoch,
      :now_epoch,
      # user_stat fields
      :topics_entered,
      :posts_read_count,
      :time_read,
      :days_visited,
      :likes_received,
      :likes_given,
      :topic_reply_count, # RESIDUE: owner pre-resolves calc_topic_reply_count! (live query+mutation)
      # SiteSetting thresholds (lifted onto the owner)
      :tl1_requires_topics_entered,
      :tl1_requires_read_posts,
      :tl1_requires_time_spent_mins,
      :tl2_requires_topics_entered,
      :tl2_requires_read_posts,
      :tl2_requires_time_spent_mins,
      :tl2_requires_days_visited,
      :tl2_requires_likes_received,
      :tl2_requires_likes_given,
      :tl2_requires_topic_reply_count,
    )

  module_function

  def tl1_met?(s)
    return false if s.topics_entered < s.tl1_requires_topics_entered
    return false if s.posts_read_count < s.tl1_requires_read_posts
    return false if (s.time_read / 60) < s.tl1_requires_time_spent_mins
    return false if ((s.now_epoch - s.created_at_epoch) / 60) < s.tl1_requires_time_spent_mins
    true
  end

  def tl2_met?(s)
    return false if s.topics_entered < s.tl2_requires_topics_entered
    return false if s.posts_read_count < s.tl2_requires_read_posts
    return false if (s.time_read / 60) < s.tl2_requires_time_spent_mins
    return false if ((s.now_epoch - s.created_at_epoch) / 60) < s.tl2_requires_time_spent_mins
    return false if s.days_visited < s.tl2_requires_days_visited
    return false if s.likes_received < s.tl2_requires_likes_received
    return false if s.likes_given < s.tl2_requires_likes_given
    return false if s.topic_reply_count < s.tl2_requires_topic_reply_count
    true
  end

  # The whole capsule decision: which trust level (if any) the user is now eligible for.
  # Mirrors Promotion#review's tl0->tl1->tl2 ladder (TL>=2 is deferred to a background job upstream).
  # Returns the target level (1 or 2) or nil. PURE — safe to run in a non-main Ractor.
  def decide(s)
    return nil if s.manual_locked
    return 1 if s.trust_level == 0 && tl1_met?(s)
    return 2 if s.trust_level == 1 && tl2_met?(s)
    nil
  end
end
