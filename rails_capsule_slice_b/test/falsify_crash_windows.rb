# frozen_string_literal: true

# Reviewer #6 — crash at the THREE dangerous points of the dispatcher, not just "after commit".
# Each worker SIGKILLs itself at A / B / C; we inspect the DB right after the kill, then run a normal
# recovery dispatcher and assert the effect lands exactly once (B must NOT double, C must NOT reprocess).
Warning[:experimental] = false
require_relative "../boot"
require_relative "../schema"
require_relative "../domain"
require_relative "../capsule"
require "minitest/autorun"

class CrashWindowsTest < Minitest::Test
  CRASH_WORKER     = File.expand_path("../worker_crash.rb", __dir__)
  MARKFIRST_WORKER = File.expand_path("../worker_crash_markfirst.rb", __dir__)
  LEASE_SECONDS    = "30"

  def setup
    ActiveRecord::Base.connection.truncate_tables("delivery_attempts", "external_charges", "outbox_events", "orders", "users")
  end

  def seed_one(key)
    OutboxEvent.create!(idempotency_key: key, event_type: "charge", payload: { "amount_cents" => 700 })
  end

  def crash_at(point)
    pid = Process.spawn(
      { "DATABASE_URL" => DB_URL, "CRASH_POINT" => point, "LEASE_SECONDS" => LEASE_SECONDS },
      RbConfig.ruby,
      CRASH_WORKER,
      out: File::NULL
    )
    Process.waitpid2(pid).last
  end

  def expire_outbox_leases!
    OutboxEvent.unpublished.update_all(locked_until: Capsule::OutboxDispatcher.current_database_time - 1)
  end

  def test_crash_A_before_delivery_is_recoverable
    seed_one("crash-A")
    st = crash_at("A")
    assert st.signaled? && st.termsig == 9, "worker was SIGKILLed: #{st.inspect}"
    assert_equal 1, OutboxEvent.unpublished.count, "A: event still pending"
    assert_equal 0, ExternalCharge.count, "A: no external effect yet"
    assert_equal 1, OutboxEvent.first.attempt_count, "A: crash worker claimed a lease"

    assert_equal 0, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f),
                 "A: leased row must not be reclaimed before locked_until"
    expire_outbox_leases!
    assert_equal 1, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 0, OutboxEvent.unpublished.count
    assert_equal 1, ExternalCharge.count, "A: recovery delivers exactly once"
    assert_equal 2, OutboxEvent.first.attempt_count, "A: recovery claimed after lease expiry"
  end

  def test_crash_B_after_delivery_before_mark_dedupes
    seed_one("crash-B")
    st = crash_at("B")
    assert st.signaled? && st.termsig == 9, "worker was SIGKILLed: #{st.inspect}"
    assert_equal 1, OutboxEvent.unpublished.count, "B: NOT marked published"
    assert_equal 1, ExternalCharge.count, "B: external effect already happened (the at-least-once window)"
    assert_equal 1, OutboxEvent.first.attempt_count, "B: crash worker claimed a lease"

    assert_equal 0, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f),
                 "B: leased row must not be reclaimed before locked_until"
    expire_outbox_leases!
    assert_equal 1, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 0, OutboxEvent.unpublished.count
    assert_equal 1, ExternalCharge.count, "B: re-delivery deduped -> still ONE effect, NOT two"
    assert_equal 2, OutboxEvent.first.attempt_count, "B: recovery claimed after lease expiry"
  end

  def test_crash_C_after_mark_does_not_reprocess
    seed_one("crash-C")
    st = crash_at("C")
    assert st.signaled? && st.termsig == 9, "worker was SIGKILLed: #{st.inspect}"
    assert_equal 0, OutboxEvent.unpublished.count, "C: already marked published"
    assert_equal 1, ExternalCharge.count, "C: effect happened"

    Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 1, ExternalCharge.count, "C: no reprocess — no second effect"
  end

  # Proves the deliver-before-mark ordering is load-bearing: marking first then crashing loses the
  # effect FOREVER, because recovery sees a published row and never re-delivers.
  def test_mark_before_deliver_loses_the_effect_forever
    seed_one("markfirst")
    pid = Process.spawn(
      { "DATABASE_URL" => DB_URL, "LEASE_SECONDS" => LEASE_SECONDS },
      RbConfig.ruby,
      MARKFIRST_WORKER,
      out: File::NULL
    )
    st = Process.waitpid2(pid).last
    assert st.signaled? && st.termsig == 9, "worker SIGKILLed: #{st.inspect}"

    assert_equal 0, OutboxEvent.unpublished.count, "wrongly marked published"
    assert_equal 0, ExternalCharge.count, "but the external effect never happened"

    Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f) # recovery cannot help
    assert_equal 0, ExternalCharge.count, "mark-before-deliver loses the effect permanently (why we deliver first)"
  end
end
