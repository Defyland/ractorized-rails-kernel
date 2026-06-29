# frozen_string_literal: true

# Models the EXTERNAL idempotent consumer's own dedup store (its own unique key).
# It stands in for "the real external system" so we can OBSERVE exactly-once external
# effect under at-least-once delivery without a live network dependency.
class ExternalCharge < ApplicationRecord
end
