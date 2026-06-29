# frozen_string_literal: true

# Deliberately resistant Rails service code, plus its capsule transform — now inside a REAL,
# booted Rails app. The RAW path leans on the genuine Rails globals (Rails.logger, Rails.cache,
# Current.user); the CAPSULE path takes an explicit CapsuleContext, emits a Proposal, and touches
# NO Rails global, so it can run anywhere — including a worker that never sees the main process's
# ambient state.
#
# Real Ractor exception classes observed on Ruby 4.0.5 (asserted by the test, not assumed):
#   make_shareable(capturing proc)            -> Ractor::IsolationError
#   real Nokogiri C-ext off the main Ractor   -> Ractor::UnsafeError (via Ractor::RemoteError#cause)
#   make_shareable(Data of frozen members)    -> shareable (no raise)

# Transform artifact for a callback that captured a live AR object: a frozen, all-primitive
# descriptor. Ractor-shareable; reproduces the computation without holding the record.
PricingDescriptor = Data.define(:rate_bps, :base_cents) do
  def apply = base_cents + (base_cents * rate_bps / 10_000)
end

class AdversarialService
  attr_reader :last_fallback_reason

  # ---------------------------------------------------------------------------
  # RAW resistant Rails code (the "before") — works today, hostile to a capsule.
  # Touches THREE real Rails globals (Current.user, Rails.logger, Rails.cache), captures a live AR
  # object in a proc, calls a native ext inline, and (worst) performs the external charge BEFORE —
  # and outside — the DB commit.
  # ---------------------------------------------------------------------------
  def raw_charge!(order_id:, rate_bps:)
    user  = Current.user                                       # (1) ambient global — invisible dependency
    order = Order.find(order_id)
    Rails.logger.info("raw_charge order=#{order_id} user=#{user.id}") # (1b) real Rails.logger global
    pricer = -> { order.total_cents + (order.total_cents * rate_bps / 10_000) } # (2) captures live AR object
    new_total = pricer.call
    Rails.cache.write("last_charge:#{order_id}", new_total)    # (1c) real Rails.cache global (memory_store)
    note = native_capability_result("ord:#{order_id}:u#{user.id}") # (3) native ext, inline
    deliver_external_charge(order_id, new_total)               # (4) side effect PRE-commit
    order.update!(total_cents: new_total)
    note
  end

  # Reads the value the raw path wrote to the REAL Rails.cache — proves the cache is genuine.
  def last_cached_charge(order_id) = Rails.cache.read("last_charge:#{order_id}")

  # ---------------------------------------------------------------------------
  # CAPSULE transform (the "after") — pure: requires explicit context, holds no record, no side
  # effect, touches NO Rails global and NO ActiveRecord. `order:` MUST be a shareable
  # Capsule::OrderSnapshot (not a live AR record), which is exactly what lets this run INSIDE a
  # non-main Ractor. Emits a Proposal; the external effect becomes a deferred EffectIntent (post-commit).
  # ---------------------------------------------------------------------------
  def capsule_propose(context:, order:, rate_bps:, request_id:)
    unless context.is_a?(Capsule::CapsuleContext) # (1) Current -> explicit CapsuleContext
      raise Capsule::CapsuleContextRequired, "capsule_propose needs a CapsuleContext, got #{context.class}"
    end
    # ENFORCED boundary: refuse a live ActiveRecord record. Only a shareable Capsule::OrderSnapshot may
    # cross into the capsule — this is what makes "runs in a Ractor" a real boundary, not a happy path.
    unless order.is_a?(Capsule::OrderSnapshot)
      raise Capsule::OrderSnapshotRequired, "capsule_propose needs a Capsule::OrderSnapshot, got #{order.class}"
    end
    new_total = PricingDescriptor.new(rate_bps:, base_cents: order.total_cents).apply # (2) callback -> descriptor
    effect = Capsule::EffectIntent.charge( # (4) side effect -> deferred EffectIntent
      order_id: order.id, request_id:, amount_cents: new_total
    )
    Capsule::Proposal.build(
      order_id: order.id, base_version: order.lock_version, total_cents: new_total, effects: [effect]
    )
  end

  # (2) A callback that captured a live AR object cannot cross a Ractor boundary. The capsule
  # discipline refuses it with a NAMED error instead of letting it fail deep inside a worker.
  def raw_pricer_proc(order:, rate_bps:)
    -> { order.total_cents + (order.total_cents * rate_bps / 10_000) } # captures `order` (AR, non-shareable)
  end

  def assert_shareable_callback!(callback)
    Ractor.make_shareable(callback)
  rescue Ractor::IsolationError => e
    raise Capsule::CallbackNotShareable, "callback captures non-shareable state (#{e.class}); use a descriptor"
  end

  # (3) A native-extension capability — REAL Nokogiri (a libxml2 C-ext). Off the main Ractor it raises
  # a genuine Ractor::UnsafeError, which surfaces through Ractor#value as Ractor::RemoteError whose
  # #cause is the UnsafeError. The capsule classifies it owner-only and runs the OWNER fallback (main
  # Ractor). The routing is exercised against the real C-ext, not a proxy.
  def native_capability_result(input)
    run_native_in_ractor(input)
  rescue Ractor::RemoteError, Ractor::UnsafeError, Ractor::IsolationError => e
    @last_fallback_reason = (e.is_a?(Ractor::RemoteError) && e.cause ? e.cause.class.name : e.class.name)
    native_parse(input) # OWNER fallback (Ractor.current == Ractor.main)
  end

  # The native capability itself — a real Nokogiri parse; runs on the owner.
  def native_parse(input)
    require "nokogiri"
    Nokogiri::XML("<note>#{input}</note>").root.name
  end

  private

  # Attempt the C-ext capability in a non-main Ractor; Nokogiri raises Ractor::UnsafeError there.
  # We EXPECT that raise (it is the whole point — it triggers the owner fallback), so silence Ruby's
  # report_on_exception around it to keep output readable. The exception is still raised, surfaced
  # through #value as Ractor::RemoteError, and rescued by native_capability_result — nothing hidden.
  def run_native_in_ractor(input)
    prev = Thread.report_on_exception
    Thread.report_on_exception = false
    Ractor.new(input.dup) { |x| require "nokogiri"; Nokogiri::XML("<note>#{x}</note>").root.name }.value
  ensure
    Thread.report_on_exception = prev
  end

  # (4) the forbidden raw external call (named so a test can assert it ran pre-commit, and never
  # runs during a capsule commit).
  def deliver_external_charge(order_id, amount_cents)
    now = Time.now
    ExternalCharge.insert_all(
      [{ idempotency_key: "raw-#{order_id}", amount_cents:, created_at: now, updated_at: now }],
      unique_by: :idempotency_key
    )
  end
end
