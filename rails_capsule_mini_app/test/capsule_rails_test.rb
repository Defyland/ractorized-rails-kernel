# frozen_string_literal: true

# Reviewer item #16: prove the Proposal + Outbox + CapsuleContext protocol inside a GENUINELY
# BOOTED Rails 8 app — not standalone ActiveRecord. This suite requires the full Rails environment
# (config/environment), runs production-like (eager_load = true, real :memory_store cache), and
# exercises every Phase-2 gate plus the Rails-specific gate: Rails globals are unusable inside a
# Ractor, so a capsule MUST receive explicit values.
Warning[:experimental] = false

require_relative "../config/environment"
require "minitest/autorun"

# Fail loud if we are NOT actually booted production-like — the whole point of this slice.
unless Rails.application.config.eager_load
  abort "REFUSING TO RUN: config.eager_load is false; this slice must run production-like (eager_load=true)."
end

class CapsuleRailsTest < Minitest::Test
  WORKER_DIR      = File.expand_path("../script", __dir__)
  DISPATCH_WORKER = File.join(WORKER_DIR, "worker_dispatch.rb")
  COMMIT_WORKER   = File.join(WORKER_DIR, "worker_commit.rb")
  CRASH_WORKER    = File.join(WORKER_DIR, "worker_crash.rb")
  LEASE_SECONDS   = "30"

  def setup
    ActiveRecord::Base.connection.truncate_tables("delivery_attempts", "external_charges", "outbox_events", "orders", "users")
    Current.reset
    Rails.cache.clear
  end

  # ---- helpers ----------------------------------------------------------------
  def seed_order(total_cents: 1000)
    Order.create!(user: User.create!(name: "ann"), total_cents:)
  end

  def context_for(order)
    Current.user = order.user
    Capsule::CapsuleContext.from_current
  end

  # Run a block inside a non-main Ractor and return its #value. The Ractor is EXPECTED to raise
  # here (that is the gate); Ruby's Thread#report_on_exception would otherwise dump the backtrace
  # to stderr. Silence it ONLY around this intentional probe so the captured run stays readable —
  # the exception itself is still raised and asserted by the caller, nothing is swallowed.
  def in_ractor(*args, &blk)
    prev = Thread.report_on_exception
    Thread.report_on_exception = false
    Ractor.new(*args, &blk).value
  ensure
    Thread.report_on_exception = prev
  end

  # Real OS-process concurrency: SPAWN independent worker processes (never fork — libpq is not
  # fork-safe on macOS and segfaults in connect_start). Each child BOOTS THE FULL RAILS ENV and
  # opens its own libpq connection to the same Postgres, exactly as production runs N workers.
  # Inherit RAILS_ENV=test + the bundler env so the child loads this same app. Returns exit codes.
  def spawn_workers(n, worker, extra_env = {})
    env = { "RAILS_ENV" => "test" }.merge(extra_env)
    pids = Array.new(n) { Process.spawn(env, RbConfig.ruby, worker, out: File::NULL) }
    pids.map { |pid| Process.waitpid2(pid)[1] }
  end

  def expire_outbox_leases!
    OutboxEvent.unpublished.update_all(locked_until: Capsule::OutboxDispatcher.current_database_time - 1)
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

  # ---- Gate 2: order update + outbox insert are atomic in ONE transaction -----
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
    assert_equal 1, OutboxEvent.where(idempotency_key: dup.idempotency_key).count # already enqueued
    p_dup = Capsule::Proposal.build(order_id: order.id, base_version: order.reload.lock_version,
                                    total_cents: 9999, effects: [dup])
    before_total, before_lock, before_outbox = order.total_cents, order.lock_version, OutboxEvent.count
    assert_raises(ActiveRecord::RecordNotUnique) { Capsule::CommitCoordinator.commit!(p_dup) }

    order.reload
    assert_equal before_total,  order.total_cents,  "order change rolled back with the failed outbox insert"
    assert_equal before_lock,   order.lock_version, "optimistic version bump rolled back too"
    assert_equal before_outbox, OutboxEvent.count,  "no partial outbox row"
  end

  # ---- Gate 3: real unique constraint on the outbox idempotency_key -----------
  def test_idempotency_key_is_unique_consumer_dedups_without_raising
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

    statuses = spawn_workers(4, DISPATCH_WORKER, "BATCH" => "7")

    assert statuses.all?(&:success?), "every dispatcher exited cleanly: #{statuses.map(&:exitstatus).inspect}"
    assert_equal 0, OutboxEvent.unpublished.count, "no event left stuck unpublished"
    assert_equal n, ExternalCharge.count, "exactly one external effect per idempotency_key"
    assert_equal n, ExternalCharge.distinct.count(:idempotency_key)
  end

  # ---- Gate 5a: crash after claim before delivery waits for lease expiry, then recovers
  def test_crash_after_claim_before_delivery_waits_for_lease_then_recovers
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new
    p = svc.capsule_propose(context: context_for(order), order: Capsule::OrderSnapshot.from(order.reload), rate_bps: 1000, request_id: "crash-a")
    assert_equal :committed, Capsule::CommitCoordinator.commit!(p)

    status = spawn_workers(1, CRASH_WORKER, "CRASH_POINT" => "A", "LEASE_SECONDS" => LEASE_SECONDS).first
    assert status.signaled?, "worker was killed mid-flight, not a clean exit: #{status.inspect}"
    assert_equal 0, ExternalCharge.count, "worker died before delivery"
    assert_equal 1, OutboxEvent.unpublished.count
    assert_equal 1, OutboxEvent.first.attempt_count

    assert_equal 0, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f),
                 "leased row must not be reclaimed before locked_until"
    assert_equal 0, ExternalCharge.count

    expire_outbox_leases!
    assert_equal 1, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 0, OutboxEvent.unpublished.count
    assert_equal 1, ExternalCharge.count
    assert_equal 2, OutboxEvent.first.attempt_count
  end

  # ---- Gate 5b: crash after delivery before publish-mark recovers, dedup on re-delivery
  def test_crash_after_delivery_before_publish_mark_waits_for_lease_then_dedupes
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new
    p = svc.capsule_propose(context: context_for(order), order: Capsule::OrderSnapshot.from(order.reload), rate_bps: 1000, request_id: "crash-b")
    assert_equal :committed, Capsule::CommitCoordinator.commit!(p)

    # crash: the committing process died before any dispatcher ran. Durable outbox row, no effect.
    assert_equal 1, OutboxEvent.unpublished.count
    assert_equal 0, ExternalCharge.count

    # A real worker process crashes in the at-least-once window (CRASH_POINT=B): it DELIVERED the
    # external charge, then was SIGKILLed BEFORE marking published_at. SIGKILL => status.signaled?.
    status = spawn_workers(1, CRASH_WORKER, "CRASH_POINT" => "B", "LEASE_SECONDS" => LEASE_SECONDS).first
    assert status.signaled?, "worker was killed mid-flight, not a clean exit: #{status.inspect}"
    assert_equal 1, ExternalCharge.count, "external charge already landed before the crash"
    assert_equal 1, OutboxEvent.unpublished.count, "publish-mark was lost on crash (row still unpublished)"
    assert_equal 1, OutboxEvent.first.attempt_count

    assert_equal 0, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f),
                 "leased row must not be reclaimed before locked_until"
    assert_equal 1, ExternalCharge.count

    # After lease expiry, recovery re-delivers (at-least-once); the idempotency_key dedups to ONE effect.
    expire_outbox_leases!
    assert_equal 1, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 0, OutboxEvent.unpublished.count
    assert_equal 1, ExternalCharge.count, "re-delivery deduped by idempotency_key"
    assert_equal 2, OutboxEvent.first.attempt_count

    # re-running the dispatcher is a clean no-op.
    assert_equal 0, Capsule::OutboxDispatcher.run_once(batch: 1, lease_seconds: LEASE_SECONDS.to_f)
    assert_equal 1, ExternalCharge.count
  end

  # ---- Gate 6 (REINFORCE): native StaleObjectError under REAL concurrent committer PROCESSES ----
  def test_concurrent_committers_one_wins
    order = seed_order(total_cents: 1000) # lock_version 0
    statuses = spawn_workers(6, COMMIT_WORKER, "ORDER_ID" => order.id.to_s)
    codes = statuses.map(&:exitstatus)

    wins      = codes.count(0)
    conflicts = codes.count(3)
    assert_equal 6, wins + conflicts, "every committer ended win-or-conflict (no crashes): #{codes.inspect}"
    assert_equal 1, wins, "exactly one committer wins the optimistic-lock race"
    assert_equal 5, conflicts

    order.reload
    assert_equal 1, order.lock_version, "single committed version bump"
    assert_equal 1, OutboxEvent.count, "only the winner enqueued; losers discarded proposal + intents together"
  end

  # =====================================================================================
  # RAILS-SPECIFIC GATE (the point of this slice): Rails globals are UNUSABLE in a Ractor.
  # Empirically observed on Ruby 4.0.5 / Rails 8.1.3 and asserted here verbatim:
  #   Rails.cache  in a Ractor -> Ractor::RemoteError, cause Ractor::IsolationError (@cache from Rails)
  #   Rails.logger in a Ractor -> Ractor::RemoteError, cause Ractor::IsolationError (@logger from Rails)
  #   Current.user in a Ractor -> Ractor::RemoteError, cause RuntimeError "defined with an un-shareable
  #                               Proc in a different Ractor" (ActiveSupport::CurrentAttributes#defaults)
  # The lesson: a capsule must receive EXPLICIT, frozen values and never touch a Rails global in a worker.
  # =====================================================================================
  def test_current_user_becomes_shareable_capsule_context
    order = seed_order
    ctx = context_for(order)
    assert_instance_of Capsule::CapsuleContext, ctx
    assert Ractor.shareable?(ctx), "CapsuleContext snapshot must be Ractor-shareable"
    # And it actually carries the snapshotted identity, usable inside a Ractor with NO Rails global.
    name_in_ractor = Ractor.new(ctx) { |c| c.user_name }.value
    assert_equal order.user.name, name_in_ractor, "explicit snapshot crosses the Ractor boundary fine"
  end

  # THE Ractor-executability gate: the capsule service actually RUNS inside a non-main Ractor over a
  # shareable CapsuleContext + OrderSnapshot (no ActiveRecord, no Rails global), returns a Proposal,
  # and that Proposal commits soundly on the owner. This is what makes it a capsule, not just a
  # protocol validated owner-side.
  def test_capsule_service_runs_inside_a_ractor
    order = seed_order(total_cents: 1000)
    ctx = context_for(order)
    snap = Capsule::OrderSnapshot.from(order)
    assert Ractor.shareable?(ctx) && Ractor.shareable?(snap), "context + order snapshot must be shareable"

    proposal =
      Ractor.new(ctx, snap) do |c, s|
        # Runs OFF the main Ractor. If capsule_propose touched AR/SiteSetting/Rails.* this would raise.
        AdversarialService.new.capsule_propose(context: c, order: s, rate_bps: 1000, request_id: "ractor")
      end.value

    assert_instance_of Capsule::Proposal, proposal, "the Ractor produced a Proposal"
    assert_equal 1100, proposal.total_cents
    assert_equal order.lock_version, proposal.base_version
    assert_equal "charge-#{order.id}-ractor", proposal.effects.first.idempotency_key
    # The owner commits the Ractor-produced proposal — end to end.
    assert_equal :committed, Capsule::CommitCoordinator.commit!(proposal)
    assert_equal 1100, order.reload.total_cents
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

  # The boundary is ENFORCED, not documented: a live ActiveRecord record is refused. This is what
  # makes the Ractor execution a real boundary (you cannot pass a non-shareable AR object in).
  def test_capsule_propose_refuses_live_activerecord_order
    order = seed_order
    ctx = context_for(order)
    refute Ractor.shareable?(order), "a live AR Order is NOT shareable (the thing we must refuse)"
    err = assert_raises(Capsule::OrderSnapshotRequired) do
      AdversarialService.new.capsule_propose(context: ctx, order: order, rate_bps: 1000, request_id: "r")
    end
    assert_match(/OrderSnapshot/, err.message)
  end

  def test_rails_cache_inside_ractor_fails
    Rails.cache.write("probe", 1) # prove the cache is real and reachable on the main Ractor
    assert_equal 1, Rails.cache.read("probe")
    refute Ractor.shareable?(Rails.cache), "the real MemoryStore is not Ractor-shareable"

    err = assert_raises(Ractor::RemoteError) { in_ractor { Rails.cache.read("probe") } }
    assert_instance_of Ractor::IsolationError, err.cause
    assert_match(/@cache from Rails/, err.cause.message)
  end

  def test_rails_logger_inside_ractor_fails
    Rails.logger.info("probe-on-main") # real logger, reachable on the main Ractor
    refute Ractor.shareable?(Rails.logger), "the real logger is not Ractor-shareable"

    err = assert_raises(Ractor::RemoteError) { in_ractor { Rails.logger.info("x") } }
    assert_instance_of Ractor::IsolationError, err.cause
    assert_match(/@logger from Rails/, err.cause.message)
  end

  def test_current_user_inside_ractor_fails
    order = seed_order
    Current.user = order.user # real CurrentAttributes global on the main Ractor
    assert_equal order.user, Current.user

    err = assert_raises(Ractor::RemoteError) { in_ractor { Current.user } }
    assert_instance_of RuntimeError, err.cause
    assert_match(/un-shareable Proc in a different Ractor/, err.cause.message)
  end

  # ---- Gate 6b: Current -> CapsuleContext, or a named failure -----------------
  def test_current_requires_capsule_context
    order = seed_order
    svc = AdversarialService.new

    Current.user = nil
    assert_raises(Capsule::CapsuleContextRequired) { Capsule::CapsuleContext.from_current }
    assert_raises(Capsule::CapsuleContextRequired) do
      svc.capsule_propose(context: order.user, order:, rate_bps: 1000, request_id: "r") # raw user, not a context
    end

    ctx = context_for(order)
    assert_instance_of Capsule::Proposal,
                       svc.capsule_propose(context: ctx, order: Capsule::OrderSnapshot.from(order), rate_bps: 1000, request_id: "r")
  end

  # ---- Gate 6c: a callback capturing AR state -> descriptor, or named failure --
  def test_callback_requires_descriptor
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new

    raw = svc.raw_pricer_proc(order:, rate_bps: 1000) # captures a live AR object
    assert_raises(Capsule::CallbackNotShareable) { svc.assert_shareable_callback!(raw) }

    desc = PricingDescriptor.new(rate_bps: 1000, base_cents: order.total_cents)
    assert Ractor.shareable?(Ractor.make_shareable(desc)), "descriptor must be Ractor-shareable"
    assert_equal raw.call, desc.apply, "descriptor reproduces the computation without the record"
  end

  # ---- Gate 6d: native extension -> owner fallback (real Nokogiri C-ext) -------
  def test_native_extension_uses_owner_fallback
    svc = AdversarialService.new
    assert_equal "note", svc.native_capability_result("abc"), "owner fallback parsed via real Nokogiri"
    assert_equal "Ractor::UnsafeError", svc.last_fallback_reason,
                 "real Nokogiri C-ext is Ractor-unsafe off the main Ractor"
  end

  # ---- Gate 7: raw path uses REAL Rails globals + charges pre-commit; capsule defers -----
  def test_raw_path_uses_rails_globals_and_charges_precommit_capsule_defers
    order = seed_order(total_cents: 1000)
    svc = AdversarialService.new
    Current.user = order.user

    svc.raw_charge!(order_id: order.id, rate_bps: 1000) # the anti-pattern
    assert_equal 1, ExternalCharge.where(idempotency_key: "raw-#{order.id}").count, "raw path charged pre-commit"
    assert_equal 0, OutboxEvent.count, "raw path bypassed the outbox entirely"
    # the raw path wrote to the REAL Rails.cache (memory_store) — read it back to prove the cache is genuine.
    assert_equal 1100, svc.last_cached_charge(order.id), "raw path wrote the new total to the real Rails.cache"

    ExternalCharge.delete_all
    prop = svc.capsule_propose(context: Capsule::CapsuleContext.from_current,
                               order: Capsule::OrderSnapshot.from(order.reload), rate_bps: 1000, request_id: "cap")
    assert_equal :committed, Capsule::CommitCoordinator.commit!(prop)
    assert_equal 0, ExternalCharge.count, "capsule commit performed NO external effect"
    assert_equal 1, OutboxEvent.count, "capsule enqueued an EffectIntent instead"
  end

  # ---- Gate 8: REAL after_commit — fires only after commit, never on rollback -----
  def test_after_commit_fires_only_after_commit
    # rollback: the hook must NOT fire.
    Current.last_committed_order_id = nil
    user = User.create!(name: "bob")
    assert_raises(RuntimeError) do
      ActiveRecord::Base.transaction do
        o = Order.create!(user:, total_cents: 500)
        raise "force rollback after the create but before commit (o=#{o.id})"
      end
    end
    assert_nil Current.last_committed_order_id, "after_commit must NOT fire on rollback"

    # commit: the hook fires, and only AFTER the transaction commits.
    Current.last_committed_order_id = nil
    committed = nil
    ActiveRecord::Base.transaction do
      committed = Order.create!(user:, total_cents: 700)
      # still inside the open transaction: the after_commit has NOT run yet.
      assert_nil Current.last_committed_order_id, "after_commit must not fire before COMMIT"
    end
    assert_equal committed.id, Current.last_committed_order_id, "after_commit fired after the real COMMIT"
  end
end
