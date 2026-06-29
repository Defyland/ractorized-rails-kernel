# frozen_string_literal: true

# Append-only audit table for dispatcher stress tests. It records every delivery
# attempt, including duplicate attempts that the external consumer's unique
# idempotency_key collapses.
class DeliveryAttempt < ApplicationRecord
end
