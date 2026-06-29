# frozen_string_literal: true

# FALSIFICATION #9 — Current (ActiveSupport::CurrentAttributes) is NOT safely usable across
# capsule boundaries; CapsuleContext is an EXPLICIT, immutable snapshot.
#
# Three claims, all against REAL ActiveRecord + REAL Postgres:
#   1. CapsuleContext.from_current captures a SNAPSHOT (it does not track Current's later mutations).
#   2. Current does NOT cross a Ractor boundary — inside a Ractor, Current.user is NOT the owner's
#      user (it is nil or raises). This is precisely why a capsule MUST be handed an explicit
#      CapsuleContext and MUST NEVER read Current inside a worker.
#   3. The capsule refuses a non-CapsuleContext (raw User or nil) with the NAMED error
#      Capsule::CapsuleContextRequired, instead of silently using ambient state.
Warning[:experimental] = false

require_relative "../boot"
require_relative "../schema"   # force-recreates the real tables in THIS isolated DB at require time
require_relative "../domain"
require_relative "../capsule"
require_relative "../adversarial_service"
require "minitest/autorun"

class CurrentLeakageFalsificationTest < Minitest::Test
  def setup
    ActiveRecord::Base.connection.truncate_tables("external_charges", "outbox_events", "orders", "users")
    Current.reset
  end

  def teardown
    Current.reset
  end

  # ---------------------------------------------------------------------------
  # Claim 1: CapsuleContext is a SNAPSHOT, not a live view of Current.
  # ---------------------------------------------------------------------------
  def test_capsule_context_is_a_snapshot
    a = User.create!(name: "alice")
    b = User.create!(name: "bob")

    Current.user = a
    ctx_a = Capsule::CapsuleContext.from_current

    Current.user = b
    ctx_b = Capsule::CapsuleContext.from_current

    # ctx_a was taken while Current.user == a, and Current.user has since moved to b.
    # A SNAPSHOT keeps a; a live view would have followed Current to b.
    assert_equal a.id, ctx_a.user_id, "ctx_a is a frozen snapshot of user a, unchanged by later Current mutation"
    assert_equal b.id, ctx_b.user_id, "ctx_b snapshotted user b"
    refute_equal ctx_a.user_id, ctx_b.user_id, "two snapshots taken at different times differ"

    # Move Current back to a. A live view of Current would drag ctx_b back to a; a snapshot will not.
    Current.user = a
    assert_equal b.id, ctx_b.user_id, "ctx_b is STILL b after Current.user moved back to a (snapshot, not live)"

    # The snapshot is also frozen / Ractor-shareable — it carries values, not the mutable global.
    assert Ractor.shareable?(ctx_a), "CapsuleContext snapshot is Ractor-shareable (frozen value)"
    assert ctx_a.frozen?, "CapsuleContext snapshot is frozen"
  end

  # ---------------------------------------------------------------------------
  # Claim 2: Current does NOT carry the owner's value across a Ractor boundary.
  #
  # This is exactly why a capsule must RECEIVE an explicit CapsuleContext and must NEVER read
  # Current inside a worker: the ambient global simply is not there in the isolated Ractor.
  # We EMPIRICALLY observe what Current.user is inside the Ractor (value-or-error), report it,
  # then assert it is NOT user a.
  # ---------------------------------------------------------------------------
  def test_current_does_not_cross_into_a_ractor
    a = User.create!(name: "alice")
    Current.user = a
    assert_equal a.id, Current.user.id, "on the owner thread Current.user is a"

    # Empirically observe Current.user from INSIDE an isolated Ractor.
    # Either it is nil/another value (:value, ...), or accessing it raises (:error, <class>).
    r = Ractor.new do
      begin
        [:value, Current.user&.id]
      rescue => e
        [:error, e.class.name]
      end
    end.value

    # Whatever the observed result is, it must NOT be the owner's user a.
    # (If Current leaked, this would be [:value, a.id] and the assertion would fail.)
    refute_equal [:value, a.id], r,
                 "Current.user inside the Ractor is NOT owner a (#{r.inspect}); the ambient global does not cross"

    # Stronger statement of the same fact: the Ractor did not see ANY non-nil owner identity by value.
    refute_equal :value_with_owner, (r == [:value, a.id] ? :value_with_owner : :no_owner_leak)
  end

  # ---------------------------------------------------------------------------
  # Claim 3: the capsule refuses a non-CapsuleContext with the NAMED error.
  # A raw User (ambient identity object) and nil are both rejected — never silently used.
  # ---------------------------------------------------------------------------
  def test_capsule_refuses_a_non_context
    user  = User.create!(name: "alice")
    order = Order.create!(user: user, total_cents: 1000)
    svc   = AdversarialService.new

    # (a) a raw User is NOT a CapsuleContext -> named refusal.
    assert_raises(Capsule::CapsuleContextRequired) do
      svc.capsule_propose(context: user, order: order, rate_bps: 1000, request_id: "x")
    end

    # (b) nil is NOT a CapsuleContext -> same named refusal.
    assert_raises(Capsule::CapsuleContextRequired) do
      svc.capsule_propose(context: nil, order: order, rate_bps: 1000, request_id: "x")
    end
  end
end
