# frozen_string_literal: true

# Real schema, loaded into real Postgres. force: true => drop+recreate (test harness).
# The two production-critical guarantees the synthetic Slice B only MODELLED (files+flock)
# are now REAL DB constraints:
#   - orders.lock_version          -> AR optimistic locking -> ActiveRecord::StaleObjectError
#   - outbox_events unique index   -> ActiveRecord::RecordNotUnique on duplicate idempotency_key
#   - external_charges unique idx  -> the IDEMPOTENT external consumer's own dedup store
require_relative "boot"

ActiveRecord::Schema.verbose = false

ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :name, null: false
    t.timestamps
  end

  create_table :orders, force: true do |t|
    t.references :user, null: false
    t.integer :total_cents, null: false, default: 0
    t.integer :lock_version, null: false, default: 0  # AR optimistic locking (magic column name)
    t.timestamps
  end

  create_table :outbox_events, force: true do |t|
    t.string   :idempotency_key, null: false
    t.string   :event_type, null: false
    t.jsonb    :payload, null: false, default: {}
    t.datetime :published_at
    t.datetime :claimed_at
    t.datetime :locked_until
    t.integer  :attempt_count, null: false, default: 0
    t.timestamps
    t.index :idempotency_key, unique: true        # exactly-once ENQUEUE (real unique constraint)
    t.index :published_at                          # dispatcher scans unpublished
    t.index [:locked_until, :id], where: "published_at IS NULL", name: "idx_outbox_unpublished_lease"
  end

  # Models the EXTERNAL idempotent consumer's own dedup ledger. A real unique constraint is the
  # honest upgrade of Slice B's effects.log: at-least-once delivery collapses to one effect here.
  create_table :external_charges, force: true do |t|
    t.string  :idempotency_key, null: false
    t.integer :amount_cents, null: false
    t.timestamps
    t.index :idempotency_key, unique: true
  end

  # Append-only log of EVERY delivery ATTEMPT (no unique index). The unique index on external_charges
  # dedups effects, but each attempt is still a real external call (money / rate-limit) — this lets the
  # stress measure how many DUPLICATE attempts the at-least-once dispatcher actually makes.
  create_table :delivery_attempts, force: true do |t|
    t.string :idempotency_key, null: false
    t.index :idempotency_key
  end
end
