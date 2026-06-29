# frozen_string_literal: true

class CreateExternalCharges < ActiveRecord::Migration[8.1]
  def change
    create_table :external_charges do |t|
      t.string  :idempotency_key, null: false
      t.integer :amount_cents, null: false
      t.timestamps

      # The IDEMPOTENT external consumer's own dedup ledger. at-least-once delivery
      # collapses to exactly one external effect here, via ON CONFLICT DO NOTHING.
      t.index :idempotency_key, unique: true
    end
  end
end
