# frozen_string_literal: true

class CreateDeliveryAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :delivery_attempts do |t|
      t.string :idempotency_key, null: false

      # No unique index on purpose: this is an attempt log, not a dedup ledger.
      # The stress harness uses it to measure duplicate external calls hidden by
      # the external consumer's idempotency key.
      t.index :idempotency_key
    end
  end
end
