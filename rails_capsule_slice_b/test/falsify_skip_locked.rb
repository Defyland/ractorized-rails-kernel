# frozen_string_literal: true

# Reviewer #5 — prove FOR UPDATE SKIP LOCKED against a REALLY held lock, not "looks concurrent".
# A separate process holds a real `FOR UPDATE` lock on one row; the dispatcher's SKIP LOCKED claim
# must skip exactly that row and return the other, and a plain FOR UPDATE on it must block.
Warning[:experimental] = false
require_relative "../boot"
require_relative "../schema"
require_relative "../domain"
require_relative "../capsule"
require "minitest/autorun"

class SkipLockedTest < Minitest::Test
  HOLD_WORKER = File.expand_path("../worker_hold.rb", __dir__)

  def setup
    ActiveRecord::Base.connection.truncate_tables("delivery_attempts", "external_charges", "outbox_events", "orders", "users")
  end

  def seed_two
    (1..2).map { |i| OutboxEvent.create!(idempotency_key: "k#{i}", event_type: "charge", payload: { "amount_cents" => i }) }
  end

  def test_skip_locked_skips_a_really_locked_row
    e1, e2 = seed_two
    ready = "/tmp/skiplocked_ready_#{Process.pid}"
    File.delete(ready) if File.exist?(ready)

    pid = Process.spawn({ "DATABASE_URL" => DB_URL, "LOCK_ID" => e1.id.to_s, "READY_FILE" => ready, "HOLD_SECS" => "6" },
                        RbConfig.ruby, HOLD_WORKER, out: File::NULL)
    50.times { break if File.exist?(ready); sleep 0.1 } # wait until the worker holds the lock
    assert File.exist?(ready), "holder process acquired the FOR UPDATE lock on row e1"

    # The dispatcher's REAL claim (Capsule::OutboxDispatcher.claim — production code path, not a copy)
    # must skip the locked e1 and return only e2. With plain FOR UPDATE it would block on e1 and return
    # both; this is what makes the mutation test catch SKIP LOCKED removal.
    claimed = Capsule::OutboxDispatcher.claim(10)
    assert_equal [e2.id], claimed.map(&:id), "the dispatcher's SKIP LOCKED claim skipped the really-locked row"

    # Prove the lock is REAL: a plain FOR UPDATE on e1 blocks until statement_timeout fires.
    blocked = false
    begin
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '800ms'")
        ActiveRecord::Base.connection.execute("SELECT id FROM outbox_events WHERE id = #{e1.id} FOR UPDATE")
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::QueryCanceled, ActiveRecord::LockWaitTimeout
      blocked = true
    end
    assert blocked, "a plain FOR UPDATE on the locked row blocked until statement_timeout — the lock is real"

    Process.waitpid(pid)
    File.delete(ready) if File.exist?(ready)
  end
end
