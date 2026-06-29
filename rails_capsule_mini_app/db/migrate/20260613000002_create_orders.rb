# frozen_string_literal: true

class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :total_cents, null: false, default: 0
      # AR auto-enables optimistic locking from this magic column name. A concurrent
      # update against a stale row raises ActiveRecord::StaleObjectError.
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
  end
end
