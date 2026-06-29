# frozen_string_literal: true

# Falsification #8 — the request_id / idempotency_key contract (negative tests).
#
# THE CONTRACT (precondition the dedup guarantee silently depends on):
#   idempotency_key MUST represent the LOGICAL OPERATION, not the retry/attempt.
#   EffectIntent.charge builds idempotency_key = "charge-<order_id>-<request_id>", so request_id
#   IS the operation token. The external consumer (ExternalConsumer.deliver!) dedups purely by that
#   key (Postgres ON CONFLICT DO NOTHING on external_charges.idempotency_key).
#
#   Hold the contract  => at-least-once retries collapse to exactly one effect (safety).
#   Break the contract => two DISTINCT logical operations that reuse one request_id collide on the
#                         same key and the SECOND is silently dropped. The dedup store cannot tell a
#                         retry from a different operation; the caller owes it that distinction.
#
# These tests drive ExternalConsumer.deliver! directly with EffectIntents (an EffectIntent is a
# Data with .idempotency_key/.event_type/.payload, the exact shape deliver! consumes) to make the
# precondition VISIBLE: when violated, an operation vanishes with no error.
Warning[:experimental] = false

require_relative "../boot"
require_relative "../schema"   # force-recreates the real tables in the isolated DB at require time
require_relative "../domain"
require_relative "../capsule"
require "minitest/autorun"

class FalsifyRequestIdContractTest < Minitest::Test
  ORDER_ID = 42

  def setup
    ActiveRecord::Base.connection.truncate_tables("external_charges", "outbox_events", "orders", "users")
  end

  # SAME order_id + SAME request_id => SAME idempotency_key => an idempotent retry collapses to ONE
  # effect. This is the contract HELD: the key encodes the operation, the second delivery is a retry.
  def test_same_request_id_yields_one_effect
    fx1 = Capsule::EffectIntent.charge(order_id: ORDER_ID, request_id: "req-A", amount_cents: 500)
    fx2 = Capsule::EffectIntent.charge(order_id: ORDER_ID, request_id: "req-A", amount_cents: 500)

    assert_equal fx1.idempotency_key, fx2.idempotency_key,
                 "same order_id + same request_id must produce the same idempotency_key"

    Capsule::ExternalConsumer.deliver!(fx1)
    Capsule::ExternalConsumer.deliver!(fx2)

    assert_equal 1, ExternalCharge.count, "at-least-once retry deduped to exactly one external effect"
  end

  # SAME order_id + DIFFERENT request_ids => TWO distinct idempotency_keys => two genuinely separate
  # operations are each delivered. The dedup store does not collapse what the key keeps distinct.
  def test_different_request_id_yields_two_effects
    fx1 = Capsule::EffectIntent.charge(order_id: ORDER_ID, request_id: "req-A", amount_cents: 500)
    fx2 = Capsule::EffectIntent.charge(order_id: ORDER_ID, request_id: "req-B", amount_cents: 900)

    refute_equal fx1.idempotency_key, fx2.idempotency_key,
                 "different request_ids must produce different idempotency_keys"

    Capsule::ExternalConsumer.deliver!(fx1)
    Capsule::ExternalConsumer.deliver!(fx2)

    assert_equal 2, ExternalCharge.count, "two distinct operations => two external effects"
  end

  # THE PRECONDITION MADE VISIBLE.
  # CONTRACT: idempotency_key must represent the OPERATION, not the retry. request_id is that
  # operation token. Here TWO genuinely different logical operations (charge 500, then charge 900)
  # WRONGLY reuse the SAME request_id. They collide on one idempotency_key; the idempotent consumer
  # cannot distinguish "different operation" from "retry of the same operation", so ON CONFLICT DO
  # NOTHING silently DROPS the second. The guarantee was never exactly-once-per-operation; it was
  # exactly-once-per-key, and a mislabeled key loses real work with no error raised.
  def test_reused_request_id_silently_drops_an_operation
    op1 = Capsule::EffectIntent.charge(order_id: ORDER_ID, request_id: "shared-id", amount_cents: 500)
    op2 = Capsule::EffectIntent.charge(order_id: ORDER_ID, request_id: "shared-id", amount_cents: 900)

    # The two operations are NOT retries of each other — they differ in amount_cents — yet the
    # mislabeled (reused) request_id forces them onto a single idempotency_key.
    refute_equal op1.payload.fetch("amount_cents"), op2.payload.fetch("amount_cents"),
                 "these are two DIFFERENT logical operations (different amounts)"
    assert_equal op1.idempotency_key, op2.idempotency_key,
                 "but a reused request_id wrongly maps them to the SAME idempotency_key"

    Capsule::ExternalConsumer.deliver!(op1)
    Capsule::ExternalConsumer.deliver!(op2)  # silently a no-op: ON CONFLICT DO NOTHING

    assert_equal 1, ExternalCharge.count,
                 "the second operation was silently dropped (deduped against the first's key)"
    surviving = ExternalCharge.find_by!(idempotency_key: op1.idempotency_key)
    assert_equal 500, surviving.amount_cents,
                 "the FIRST operation survived; the SECOND (900) was silently lost — work vanished, no error"
  end
end
