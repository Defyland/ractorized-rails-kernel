# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_13_000006) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "delivery_attempts", force: :cascade do |t|
    t.string "idempotency_key", null: false
    t.index ["idempotency_key"], name: "index_delivery_attempts_on_idempotency_key"
  end

  create_table "external_charges", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "idempotency_key", null: false
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_external_charges_on_idempotency_key", unique: true
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_orders_on_user_id"
  end

  create_table "outbox_events", force: :cascade do |t|
    t.integer "attempt_count", default: 0, null: false
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "idempotency_key", null: false
    t.datetime "locked_until"
    t.jsonb "payload", default: {}, null: false
    t.datetime "published_at"
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_outbox_events_on_idempotency_key", unique: true
    t.index ["locked_until", "id"], name: "index_outbox_events_unpublished_lease", where: "(published_at IS NULL)"
    t.index ["published_at"], name: "index_outbox_events_on_published_at"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "orders", "users"
end
