# frozen_string_literal: true

# Falsification #13 — external consumer that fails intermittently.
# CLAIM under test: the dispatcher does NOT mark an event published when the external
# consumer fails; a later retry delivers; and the idempotency_key prevents a duplicate
# external effect on reprocess.
#
# We model an intermittently-failing external system with FlakyConsumer: the FIRST
# delivery attempt per idempotency_key raises (transient failure), and every subsequent
# attempt delegates to the REAL idempotent consumer (Capsule::ExternalConsumer.deliver!,
# which is ON CONFLICT DO NOTHING on external_charges.idempotency_key).
#
# The local dispatch loop (drain) marks published ONLY on a successful deliver!; a raised
# delivery short-circuits before update! so the row stays unpublished — exactly the
# at-least-once contract the protocol promises.
Warning[:experimental] = false

require_relative "../boot"
require_relative "../schema"   # force-recreates the real tables in THIS isolated DB
require_relative "../domain"
require_relative "../capsule"
require "minitest/autorun"

class FailingConsumerTest < Minitest::Test
  IDK = "charge-13-flaky" # deterministic idempotency_key for the single seeded event

  # A flaky external consumer: fails the FIRST attempt per key, then succeeds by delegating
  # to the real idempotent consumer. One instance is reused across drains so the per-key
  # attempt counter persists (the "transient" failure happens once).
  class FlakyConsumer
    attr_reader :attempts

    def initialize
      @attempts = Hash.new(0)
    end

    def deliver!(event)
      @attempts[event.idempotency_key] += 1
      raise "transient external failure" if @attempts[event.idempotency_key] == 1

      Capsule::ExternalConsumer.deliver!(event)
    end
  end

  # Minimal dispatcher loop: mark published ONLY on a successful delivery. A raised
  # deliver! is swallowed so the row is left unpublished for a later retry.
  def drain(consumer)
    OutboxEvent.unpublished.order(:id).each do |ev|
      begin
        consumer.deliver!(ev)
        Capsule::OutboxDispatcher.mark_published(ev)
      rescue => e
        # delivery failed: do NOT mark published. Row remains for retry. (e observed, not re-raised)
      end
    end
  end

  def setup
    ActiveRecord::Base.connection.truncate_tables("delivery_attempts", "external_charges", "outbox_events", "orders", "users")
  end

  def test_failing_consumer_no_premature_publish_then_retry_then_dedup
    # Seed exactly ONE outbox event with a deterministic idempotency_key.
    OutboxEvent.create!(idempotency_key: IDK, event_type: "charge", payload: { "amount_cents" => 700 })
    assert_equal 1, OutboxEvent.unpublished.count, "precondition: one unpublished event seeded"
    assert_equal 0, ExternalCharge.count, "precondition: no external effect yet"

    consumer = FlakyConsumer.new # ONE instance reused across all drains

    # ---- First drain: consumer raises (transient) => NOT marked, NO external effect.
    drain(consumer)
    assert_equal 1, consumer.attempts[IDK], "exactly one delivery attempt happened"
    assert_equal 1, OutboxEvent.unpublished.count, "failed delivery must NOT mark the event published"
    assert_nil OutboxEvent.first.published_at, "published_at stays nil after a failed delivery"
    assert_equal 0, ExternalCharge.count, "no premature external charge on a failed delivery"

    # ---- Second drain (same instance): retry succeeds => external effect lands, event published.
    drain(consumer)
    assert_equal 2, consumer.attempts[IDK], "retry was a second attempt on the same key"
    assert_equal 1, ExternalCharge.count, "retry delivered exactly one external charge"
    assert_equal 1, ExternalCharge.where(idempotency_key: IDK).count, "charge carries the event's idempotency_key"
    refute_nil OutboxEvent.first.published_at, "successful delivery marks the event published"
    assert_equal 0, OutboxEvent.unpublished.count, "nothing left unpublished after a successful retry"

    # ---- Third reprocess: force re-delivery (null published_at) => dedup holds, STILL one charge.
    OutboxEvent.where(idempotency_key: IDK).update_all(published_at: nil)
    assert_equal 1, OutboxEvent.unpublished.count, "event re-queued for reprocessing"
    drain(consumer)
    assert_equal 3, consumer.attempts[IDK], "a third delivery attempt actually ran"
    assert_equal 1, ExternalCharge.count, "idempotency_key dedups the duplicate on reprocess: STILL one"
    assert_equal 1, ExternalCharge.where(idempotency_key: IDK).count, "no duplicate row for the same key"
    assert_equal 0, OutboxEvent.unpublished.count, "reprocess re-published the event"
  end
end
