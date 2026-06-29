# frozen_string_literal: true

class AddLeaseToOutboxEvents < ActiveRecord::Migration[8.1]
  def change
    change_table :outbox_events do |t|
      t.datetime :claimed_at
      t.datetime :locked_until
      t.integer :attempt_count, null: false, default: 0
    end

    add_index :outbox_events,
              [:locked_until, :id],
              where: "published_at IS NULL",
              name: "index_outbox_events_unpublished_lease"
  end
end
