# frozen_string_literal: true

class CreateOutboxEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :outbox_events do |t|
      t.string   :idempotency_key, null: false
      t.string   :event_type, null: false
      t.jsonb    :payload, null: false, default: {}
      t.datetime :published_at
      t.timestamps

      # exactly-once ENQUEUE: a real UNIQUE constraint. A duplicate idempotency_key
      # raises ActiveRecord::RecordNotUnique, aborting the whole commit transaction.
      t.index :idempotency_key, unique: true
      # The dispatcher scans unpublished rows.
      t.index :published_at
    end
  end
end
