# frozen_string_literal: true

# The capsule protocol on REAL ActiveRecord. Same shape as synthetic Slice B, now backed by
# Postgres primitives instead of files+flock:
#   Proposal (versioned) -> CommitCoordinator (one AR transaction: optimistic update + outbox insert)
#   -> OutboxDispatcher (FOR UPDATE SKIP LOCKED, post-commit) -> idempotent ExternalConsumer.
#
# CLAIM (unchanged from the corrected Slice B claim):
#   exactly-once outbox ENQUEUE  + idempotent AT-LEAST-ONCE dispatch.
# NOT "exactly-once external side effect": the dispatcher may deliver the same EffectIntent more
# than once (crash/retry); the external consumer's unique idempotency_key collapses it to one.
require_relative "domain"

module Capsule
  # Named failures — never silent. Each maps a resistant Rails pattern to an explicit error.
  class CapsuleContextRequired < StandardError; end  # Current.user used where a CapsuleContext is required
  class CallbackNotShareable   < StandardError; end  # a proc capturing mutable AR state can't cross a Ractor
  class StaleProposal          < StandardError; end  # proposal.base_version != order.lock_version
  class OrderSnapshotRequired  < StandardError; end  # a live AR record was passed where a shareable snapshot is required
  class ProposalNotShareable   < StandardError; end  # proposal/effects must be deeply immutable across the boundary

  # Replaces Current: a frozen, Ractor-shareable value carrying only the identity the capsule needs.
  CapsuleContext = Data.define(:user_id, :user_name) do
    def self.from_current
      raise CapsuleContextRequired, "Current.user is nil; a capsule needs an explicit CapsuleContext" if Current.user.nil?
      Ractor.make_shareable(new(user_id: Current.user.id, user_name: Current.user.name.dup))
    end
  end

  # A write intent. idempotency_key is deterministic — the spine of dedup.
  EffectIntent = Data.define(:idempotency_key, :event_type, :payload) do
    # PRECONDITION: request_id MUST be a stable, deterministic token per logical operation.
    # Fresh id on retry => double charge. Reused id for a different op => lost charge.
    def self.charge(order_id:, request_id:, amount_cents:)
      Ractor.make_shareable(new(
        idempotency_key: "charge-#{order_id}-#{request_id}",
        event_type: "charge",
        payload: { "order_id" => order_id, "amount_cents" => amount_cents }
      ))
    end
  end

  # A versioned proposal: the only thing a (would-be Ractor) capsule emits. No DB handle, no side effect.
  Proposal = Data.define(:order_id, :base_version, :total_cents, :effects) do
    def self.build(order_id:, base_version:, total_cents:, effects:)
      Ractor.make_shareable(new(order_id:, base_version:, total_cents:, effects: effects.to_a))
    end
  end

  # A shareable snapshot of the mutable Order, built by the OWNER. Passing this — not the live AR
  # record — is what lets the proposal computation run INSIDE a Ractor (no ActiveRecord, only frozen
  # primitives). capsule_propose ENFORCES that only this type crosses the boundary.
  OrderSnapshot = Data.define(:id, :lock_version, :total_cents) do
    def self.from(order)
      Ractor.make_shareable(new(id: order.id, lock_version: order.lock_version, total_cents: order.total_cents))
    end
  end

  # The external system, modelled as an idempotent consumer with its OWN dedup store.
  # insert_all(..., unique_by:) => Postgres ON CONFLICT DO NOTHING: at-least-once becomes one effect,
  # and a duplicate does NOT raise (so it never poisons the dispatcher's transaction).
  module ExternalConsumer
    def self.deliver!(event)
      now = Time.now
      ExternalCharge.insert_all(
        [{ idempotency_key: event.idempotency_key,
           amount_cents: event.payload.fetch("amount_cents"),
           created_at: now, updated_at: now }],
        unique_by: :idempotency_key
      )
    end
  end

  # Commit coordinator: order update + outbox insert in ONE real transaction.
  # Returns :committed or :conflict. On conflict NOTHING is written (order unchanged, zero outbox rows)
  # because the whole transaction rolls back.
  module CommitCoordinator
    def self.commit!(proposal)
      raise ProposalNotShareable, "proposal must be deeply Ractor-shareable" unless Ractor.shareable?(proposal)

      ActiveRecord::Base.transaction do
        order = Order.find(proposal.order_id)
        # Fast, explicit guard for a proposal we already know is stale (named, not silent).
        raise StaleProposal unless order.lock_version == proposal.base_version
        order.total_cents = proposal.total_cents
        order.save!  # AR optimistic lock: UPDATE ... WHERE lock_version = N. 0 rows => StaleObjectError.
        proposal.effects.each do |fx|
          OutboxEvent.create!(
            idempotency_key: fx.idempotency_key, event_type: fx.event_type, payload: fx.payload
          )
        end
        :committed
      end
    rescue ActiveRecord::StaleObjectError, StaleProposal
      :conflict  # transaction rolled back: proposal + ALL its EffectIntents discarded together
    end
  end

  # Post-commit relay. Honestly at-least-once: delivery commits INDEPENDENTLY of the publish-mark
  # (they are NOT wrapped in one transaction — doing so would couple a local-table "external system"
  # to the mark and fake exactly-once). A crash between the two re-delivers; the external consumer's
  # unique idempotency_key collapses the duplicate. FOR UPDATE SKIP LOCKED + a short lease reduce
  # contention and duplicate-attempt amplification, but idempotency is still the correctness layer.
  module OutboxDispatcher
    module_function

    DEFAULT_LEASE_SECONDS = 30.0

    def run_once(batch: 50, lease_seconds: DEFAULT_LEASE_SECONDS)
      delivered = 0
      while (events = claim(batch, lease_seconds:)).any?
        events.each do |event|
          ExternalConsumer.deliver!(event)        # external system: its OWN commit (idempotent on idk)
          mark_published(event)                   # publish-mark: a SEPARATE commit
          delivered += 1                          # crash between the two => lease expiry => deduped re-delivery
        end
      end
      delivered
    end

    # Claim unpublished, unleased rows with FOR UPDATE SKIP LOCKED and mark a time-bounded lease
    # before delivery starts. The external delivery still happens outside the DB transaction, so the
    # protocol remains at-least-once; if a worker dies, the row becomes claimable after locked_until.
    def claim(batch, lease_seconds: DEFAULT_LEASE_SECONDS)
      ActiveRecord::Base.transaction do
        now = current_database_time
        locked_until = now + lease_seconds
        events =
          OutboxEvent
            .unpublished
            .where("locked_until IS NULL OR locked_until <= ?", now)
            .order(:id)
            .limit(batch)
            .lock("FOR UPDATE SKIP LOCKED")
            .to_a

        events.each do |event|
          event.update_columns(
            claimed_at: now,
            locked_until: locked_until,
            attempt_count: event.attempt_count + 1,
            updated_at: now,
          )
        end
        events
      end
    end

    def mark_published(event)
      event.update!(published_at: current_database_time, locked_until: nil)
    end

    def current_database_time
      ActiveRecord::Base.connection.select_value("SELECT CURRENT_TIMESTAMP")
    end
  end
end
