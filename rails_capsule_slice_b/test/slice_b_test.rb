# frozen_string_literal: true

# Phase 2 gates — the capsule protocol on REAL ActiveRecord + real Postgres.
# Each named test maps to a gate from the Phase 2 spec. Run: ../run.sh  (or see README).
Warning[:experimental] = false

require_relative "../boot"
require_relative "../schema"   # force-recreates the real tables once, at require time
require_relative "../domain"
require_relative "../capsule"
require_relative "../adversarial_service"
require "minitest/autorun"

class SliceBTest < Minitest::Test
  def setup
    ActiveRecord::Base.connection.truncate_tables("delivery_attempts", "external_charges", "outbox_events", "orders", "users")
    Current.reset
  end

  # ---- helpers ----------------------------------------------------------------
  def seed_order(total_cents: 1000)
    Order.create!(user: User.create!(name: "ann"), total_cents:)
  end

  def context_for(order)
    Current.user = order.user
    Capsule::CapsuleContext.from_current
  end

  # Real OS-process concurrency: SPAWN independent worker processes (never fork — libpq is not
  # fork-safe on macOS and segfaults in connect_start). Each gets a fresh process image and its own
  # libpq connection to the same Postgres, exactly as production runs N workers. Returns exit codes;
  # stdout discarded, stderr inherited so a real failure is visible.
  DISPATCH_WORKER = File.expand_path("../worker_dispatch.rb", __dir__)
  COMMIT_WORKER   = File.expand_path("../worker_commit.rb", __dir__)
  LEASE_SECONDS   = "30"

  def spawn_workers(n, worker, extra_env = {})
    env = { "DATABASE_URL" => DB_URL }.merge(extra_env) # BUNDLE_GEMFILE inherited from `bundle exec`
    pids = Array.new(n) { Process.spawn(env, RbConfig.ruby, worker, out: File::NULL) }
    pids.map { |pid| Process.waitpid2(pid)[1].exitstatus }
  end

  # ---- Gate 1: optimistic lock conflict drops the outbox ----------------------
  def test_commit_conflict_drops_outbox
    order = seed_order(total_cents: 1000)

    # (a) the underlying DB primitive is REAL: two stale instances -> native StaleObjectError.
    a = Order.find(order.id)
    b = Order.find(order.id)
    a.update!(total_cents: 111)
    assert_raises(ActiveRecord::StaleObjectError) { b.update!(total_cents: 222) }
    order.reload

    # (b) the PROTOCOL: a stale proposal is rejected and its EffectIntents are discarded with it.
    svc = AdversarialService.new
    ctx = context_for(order)
    order_a = Order.find(order.id)
    order_b = Order.find(order.id) # both read the same base_version
    p_a = svc.capsule_propose(context: ctx, order: Capsule::OrderSnapshot.from(order_a), rate_bps: 1000, request_id: "ra")
    p_b = svc.capsule_propose(context: ctx, order: Capsule::OrderSnapshot.from(order_b), rate_bps: 5000, request_id: "rb")

    assert_equal :committed, Capsule::CommitCoordinator.commit!(p_a)
    assert_equal :conflict,  Capsule::CommitCoordinator.commit!(p_b)

    order.reload
    assert_equal p_a.total_cents, order.total_cents, "winner's value, not the stale proposal's"
    assert_equal 1, OutboxEvent.count, "only the winning proposal's effect enqueued"
    assert_equal p_a.effects.first.idempotency_key, OutboxEvent.first.idempotency_key
  end

  # ---- Gate 2: order update + outbox insert are atomic ------------------------
  def test_commit_and_outbox_are_atomic
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new
    ctx = context_for(order)

    # success: both the order change and the outbox row land; NO external effect yet (deferred).
    p_ok = svc.capsule_propose(context: ctx, order: Capsule::OrderSnapshot.from(order.reload), rate_bps: 1000, request_id: "ok")
    assert_equal :committed, Capsule::CommitCoordinator.commit!(p_ok)
    assert_equal 1100, order.reload.total_cents
    assert_equal 1, OutboxEvent.count
    assert_equal 0, ExternalCharge.count, "no external side effect at commit time"

    # rollback: an effect colliding with an existing outbox key aborts the whole transaction.
    dup = Capsule::EffectIntent.charge(order_id: order.id, request_id: "ok", amount_cents: 1)
    assert_equal 1, OutboxEvent.where(idempotency_key: dup.idempotency_key).count # already enqueued above
    p_dup = Capsule::Proposal.build(order_id: order.id, base_version: order.reload.lock_version,
                                    total_cents: 9999, effects: [dup])
    before_total, before_lock, before_outbox = order.total_cents, order.lock_version, OutboxEvent.count
    assert_raises(ActiveRecord::RecordNotUnique) { Capsule::CommitCoordinator.commit!(p_dup) }

    order.reload
    assert_equal before_total,  order.total_cents,   "order change rolled back with the failed outbox insert"
    assert_equal before_lock,   order.lock_version,  "optimistic version bump rolled back too"
    assert_equal before_outbox, OutboxEvent.count,   "no partial outbox row"
  end

  # ---- Gate 3: real unique constraint on the outbox idempotency_key -----------
  def test_idempotency_key_is_unique
    OutboxEvent.create!(idempotency_key: "k1", event_type: "charge", payload: {})
    assert_raises(ActiveRecord::RecordNotUnique) do
      OutboxEvent.create!(idempotency_key: "k1", event_type: "charge", payload: {})
    end
    assert_equal 1, OutboxEvent.where(idempotency_key: "k1").count

    # the idempotent external consumer's insert path is a NO-OP on duplicate, not a raise.
    fx = Capsule::EffectIntent.charge(order_id: 1, request_id: "k1", amount_cents: 7)
    ev = OutboxEvent.new(idempotency_key: fx.idempotency_key, event_type: fx.event_type, payload: fx.payload)
    2.times { Capsule::ExternalConsumer.deliver!(ev) }
    assert_equal 1, ExternalCharge.where(idempotency_key: fx.idempotency_key).count
  end

  # ---- Gate 4: concurrent dispatchers, each effect delivered exactly once -----
  def test_concurrent_dispatchers_dedupe
    order = seed_order
    n = 200
    n.times do |i|
      fx = Capsule::EffectIntent.charge(order_id: order.id, request_id: "c#{i}", amount_cents: i + 1)
      OutboxEvent.create!(idempotency_key: fx.idempotency_key, event_type: fx.event_type, payload: fx.payload)
    end

    statuses = spawn_workers(4, DISPATCH_WORKER, "BATCH" => "7", "LEASE_SECONDS" => LEASE_SECONDS)

    assert statuses.all?(&:zero?), "every dispatcher exited cleanly: #{statuses.inspect}"
    assert_equal 0, OutboxEvent.unpublished.count, "no event left stuck unpublished"
    assert_equal n, ExternalCharge.count, "exactly one external effect per idempotency_key"
    assert_equal n, ExternalCharge.distinct.count(:idempotency_key)
  end

  # ---- Gate 5: crash between commit and dispatch recovers, dedup on re-delivery
  def test_crash_after_commit_before_dispatch_recovers
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new
    p = svc.capsule_propose(context: context_for(order), order: Capsule::OrderSnapshot.from(order.reload), rate_bps: 1000, request_id: "crash")
    assert_equal :committed, Capsule::CommitCoordinator.commit!(p)

    # crash: the process died before the dispatcher ran. Durable outbox row, zero external effect.
    assert_equal 1, OutboxEvent.unpublished.count
    assert_equal 0, ExternalCharge.count

    # the at-least-once window: external call SUCCEEDED but "mark published" was lost on crash.
    ev = OutboxEvent.first
    Capsule::ExternalConsumer.deliver!(ev)
    assert_equal 1, ExternalCharge.count
    assert_nil ev.reload.published_at

    # recovery re-delivers (at-least-once); the idempotency_key dedups to ONE effect.
    Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 0, OutboxEvent.unpublished.count
    assert_equal 1, ExternalCharge.count, "re-delivery deduped by idempotency_key"

    # re-running the dispatcher is a clean no-op.
    assert_equal 0, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 1, ExternalCharge.count
  end

  # ---- Gate 6a: Current -> CapsuleContext, or a named failure -----------------
  def test_current_requires_capsule_context
    order = seed_order
    svc = AdversarialService.new

    Current.user = nil
    assert_raises(Capsule::CapsuleContextRequired) { Capsule::CapsuleContext.from_current }
    assert_raises(Capsule::CapsuleContextRequired) do
      svc.capsule_propose(context: order.user, order:, rate_bps: 1000, request_id: "r") # raw user, not a context
    end

    ctx = context_for(order)
    assert Ractor.shareable?(ctx), "CapsuleContext must be Ractor-shareable"
    assert_instance_of Capsule::Proposal,
                       svc.capsule_propose(context: ctx, order: Capsule::OrderSnapshot.from(order), rate_bps: 1000, request_id: "r")
  end

  def test_proposal_and_effect_intents_are_deeply_shareable
    order = seed_order(total_cents: 1000)
    proposal = AdversarialService.new.capsule_propose(
      context: context_for(order),
      order: Capsule::OrderSnapshot.from(order),
      rate_bps: 1000,
      request_id: "immutable"
    )

    assert Ractor.shareable?(proposal), "proposal crossing the boundary must be deeply shareable"
    assert Ractor.shareable?(proposal.effects.first), "effect intent must be deeply shareable"
    assert_raises(FrozenError) { proposal.effects << proposal.effects.first }
    assert_raises(FrozenError) { proposal.effects.first.payload["amount_cents"] = 9999 }
  end

  def test_commit_coordinator_refuses_mutable_proposal
    order = seed_order(total_cents: 1000)
    fx = Capsule::EffectIntent.new(
      idempotency_key: "charge-#{order.id}-mutable",
      event_type: "charge",
      payload: { "order_id" => order.id, "amount_cents" => 1100 }
    )
    mutable = Capsule::Proposal.new(
      order_id: order.id,
      base_version: order.lock_version,
      total_cents: 1100,
      effects: [fx]
    )

    refute Ractor.shareable?(mutable)
    assert_raises(Capsule::ProposalNotShareable) { Capsule::CommitCoordinator.commit!(mutable) }
    assert_equal 1000, order.reload.total_cents
    assert_equal 0, OutboxEvent.count
  end

  # The boundary is ENFORCED: a live ActiveRecord record is refused; only a shareable OrderSnapshot crosses.
  def test_capsule_propose_refuses_live_activerecord_order
    order = seed_order
    ctx = context_for(order)
    refute Ractor.shareable?(order), "a live AR Order is not shareable (the thing we refuse)"
    err = assert_raises(Capsule::OrderSnapshotRequired) do
      AdversarialService.new.capsule_propose(context: ctx, order: order, rate_bps: 1000, request_id: "r")
    end
    assert_match(/OrderSnapshot/, err.message)
  end

  # ---- Gate 6b: a callback capturing AR state -> descriptor, or named failure --
  def test_callback_requires_descriptor
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new

    raw = svc.raw_pricer_proc(order:, rate_bps: 1000) # captures a live AR object
    assert_raises(Capsule::CallbackNotShareable) { svc.assert_shareable_callback!(raw) }

    desc = PricingDescriptor.new(rate_bps: 1000, base_cents: order.total_cents)
    assert Ractor.shareable?(Ractor.make_shareable(desc)), "descriptor must be Ractor-shareable"
    assert_equal raw.call, desc.apply, "descriptor reproduces the computation without the record"
  end

  # ---- Gate 6c: native extension -> owner fallback ----------------------------
  def test_native_extension_uses_owner_fallback
    svc = AdversarialService.new
    assert_equal "note", svc.native_capability_result("abc"), "owner fallback parsed via real Nokogiri"
    assert_equal "Ractor::UnsafeError", svc.last_fallback_reason,
                 "real Nokogiri C-ext is Ractor-unsafe off the main Ractor"
  end

  # ---- Gate 1 (reinforce): native StaleObjectError under REAL concurrent committers (synthetic T5) ----
  def test_concurrent_committers_one_wins
    order = seed_order(total_cents: 1000) # lock_version 0
    statuses = spawn_workers(6, COMMIT_WORKER, "ORDER_ID" => order.id.to_s)

    wins      = statuses.count(0)
    conflicts = statuses.count(3)
    assert_equal 6, wins + conflicts, "every committer ended win-or-conflict (no crashes): #{statuses.inspect}"
    assert_equal 1, wins, "exactly one committer wins the optimistic-lock race"
    assert_equal 5, conflicts

    order.reload
    assert_equal 1, order.lock_version, "single committed version bump"
    assert_equal 1, OutboxEvent.count, "only the winner enqueued; losers discarded proposal + intents together"
  end

  # ---- Gate 6 (reinforce): raw path charges pre-commit; capsule defers to an EffectIntent --------
  def test_raw_path_charges_precommit_capsule_defers
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new
    Current.user = order.user

    svc.raw_charge!(order_id: order.id, rate_bps: 1000) # the anti-pattern
    assert_equal 1, ExternalCharge.where(idempotency_key: "raw-#{order.id}").count, "raw path charged pre-commit"
    assert_equal 0, OutboxEvent.count, "raw path bypassed the outbox entirely"

    ExternalCharge.delete_all
    prop = svc.capsule_propose(context: Capsule::CapsuleContext.from_current,
                               order: Capsule::OrderSnapshot.from(order.reload), rate_bps: 1000, request_id: "cap")
    assert_equal :committed, Capsule::CommitCoordinator.commit!(prop)
    assert_equal 0, ExternalCharge.count, "capsule commit performed NO external effect"
    assert_equal 1, OutboxEvent.count, "capsule enqueued an EffectIntent instead"
  end
end
