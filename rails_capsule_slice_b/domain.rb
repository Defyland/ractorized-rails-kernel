# frozen_string_literal: true

# Real Rails domain: AR models + ActiveSupport::CurrentAttributes (the resistant global).
require_relative "boot"

class User < ActiveRecord::Base; end

class Order < ActiveRecord::Base
  belongs_to :user
  # No `lock_version` declaration needed: AR auto-enables optimistic locking from the column name.
end

class OutboxEvent < ActiveRecord::Base
  scope :unpublished, -> { where(published_at: nil) }
end

# The external system's idempotent dedup store (its own unique key). Not part of Rails app code;
# it stands in for "the real external consumer" so we can OBSERVE exactly-once external effect
# under at-least-once delivery without a real network dependency.
class ExternalCharge < ActiveRecord::Base; end

# Append-only attempt log (no dedup). One row per delivery ATTEMPT, so the stress can count duplicate
# external calls (the real money/rate-limit cost the unique index hides).
class DeliveryAttempt < ActiveRecord::Base; end

# The classic resistant global: a mutable, thread/request-scoped singleton. NOT Ractor-shareable,
# NOT capsule-safe — its whole purpose is implicit ambient state. CapsuleContext replaces it.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
end
