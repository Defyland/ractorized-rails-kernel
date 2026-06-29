# frozen_string_literal: true

# Falsification #4 — real ActiveRecord after_commit / after_rollback semantics.
#
# CLAIM under test: ActiveRecord's after_commit callback fires ONLY after a real Postgres
# COMMIT, and NEVER fires when the surrounding transaction rolls back. We prove this with a
# REAL transaction (ActiveRecord::Base.transaction) and a REAL model callback registered on a
# probe model pointed at an existing table (outbox_events). No minitest transactional fixtures
# exist in this slice, so the transaction boundary is the genuine DB boundary.
Warning[:experimental] = false

require_relative "../boot"
require_relative "../schema"   # force-recreates the real tables once, at require time
require_relative "../domain"
require_relative "../capsule"
require "minitest/autorun"

# Probe model: a SECOND AR class pointed at the existing outbox_events table. Defining it here
# (not in the shared domain) keeps the shared classes untouched. Its after_commit appends the
# row id to a class-level array so the test can observe EXACTLY when (and whether) it ran.
class CommitProbe < ActiveRecord::Base
  self.table_name = "outbox_events"

  @fired = []
  class << self; attr_accessor :fired; end

  # Records the committed id. If this ever runs on a rolled-back transaction, the array is non-empty.
  after_commit { CommitProbe.fired << id }
end

class FalsifyAfterCommitTest < Minitest::Test
  # A minimal valid outbox_events row (idempotency_key/event_type are NOT NULL; payload defaults).
  def new_probe(key)
    CommitProbe.new(idempotency_key: key, event_type: "charge", payload: {})
  end

  def setup
    ActiveRecord::Base.connection.truncate_tables("external_charges", "outbox_events", "orders", "users")
    CommitProbe.fired = []
  end

  # after_commit must NOT fire when the transaction rolls back, and nothing may persist.
  def test_after_commit_does_not_fire_on_rollback
    probe = new_probe("rollback-key")

    ActiveRecord::Base.transaction do
      probe.save!                       # row created inside the (uncommitted) transaction
      # The callback has NOT run yet: after_commit is deferred to the real COMMIT.
      assert_empty CommitProbe.fired, "after_commit must not fire mid-transaction"
      raise ActiveRecord::Rollback     # abort: the COMMIT never happens
    end

    assert_empty CommitProbe.fired, "after_commit must NOT fire when the transaction rolled back"
    assert_equal 0, OutboxEvent.count, "rolled-back row must not persist (real ROLLBACK)"
    assert_nil probe.id, "AR rolls back the in-memory id assignment too" if probe.id.nil?
  end

  # after_commit MUST fire after a real COMMIT, and the row must persist.
  def test_after_commit_fires_after_commit
    CommitProbe.fired = []
    probe = new_probe("commit-key")

    ActiveRecord::Base.transaction do
      probe.save!                       # row created inside the transaction
      # Still inside the open transaction: after_commit is deferred until COMMIT lands.
      assert_empty CommitProbe.fired, "after_commit must not fire before COMMIT, even after save!"
    end                                 # block exits cleanly => real COMMIT => callback fires

    assert_includes CommitProbe.fired, probe.id, "after_commit must fire after the real COMMIT"
    assert_equal 1, OutboxEvent.count, "committed row must persist"
    assert_equal probe.id, OutboxEvent.first.id, "the persisted row is the one the callback observed"
  end
end
