# frozen_string_literal: true

# The classic resistant Rails global: a mutable, thread/request-scoped singleton
# (ActiveSupport::CurrentAttributes). Its whole purpose is implicit ambient state, which
# is exactly what makes it NOT Ractor-shareable and NOT capsule-safe. CapsuleContext
# replaces it with an explicit, frozen, Ractor-shareable value.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
  # A process-local observable used by Order's after_commit hook in the tests.
  attribute :last_committed_order_id
end
