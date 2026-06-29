# frozen_string_literal: true

# High-volume outbox dispatcher stress for the booted Rails mini app.
#
# This is an audit harness. It measures both externally deduped effects
# (external_charges) and raw delivery attempts (delivery_attempts), because the
# latter is the money/rate-limit cost hidden by idempotency.
#
# Example:
#   RAILS_ENV=test N=10000 WORKERS=16 BATCHES=1,5,10 RUNS=2 JITTER_MS=1 MAX_DUP_ATTEMPT_PERCENT=0 \
#   bundle exec ruby script/stress_dispatch.rb
require "json"
require "time"
require_relative "../config/environment"

N = Integer(ENV.fetch("N", "10000"))
WORKERS = Integer(ENV.fetch("WORKERS", "16"))
RUNS = Integer(ENV.fetch("RUNS", "2"))
JITTER_MS = ENV.fetch("JITTER_MS", "1")
LEASE_SECONDS = ENV.fetch("LEASE_SECONDS", "30")
MAX_DUP_ATTEMPT_PERCENT = Float(ENV.fetch("MAX_DUP_ATTEMPT_PERCENT", "0"))
BATCHES = ENV.fetch("BATCHES", "1,5,10").split(",").map { |value| Integer(value) }
WORKER = File.expand_path("worker_stress_dispatch.rb", __dir__)
JSON_OUT = ENV["JSON_OUT"]

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def reset_tables
  ActiveRecord::Base.connection.truncate_tables(
    "delivery_attempts", "external_charges", "outbox_events", "orders", "users"
  )
end

def seed_events(n)
  order = Order.create!(user: User.create!(name: "stress"), total_cents: 1)
  timestamp = Time.now
  rows =
    Array.new(n) do |i|
      effect = Capsule::EffectIntent.charge(order_id: order.id, request_id: "stress#{i}", amount_cents: i + 1)
      {
        idempotency_key: effect.idempotency_key,
        event_type: effect.event_type,
        payload: effect.payload,
        created_at: timestamp,
        updated_at: timestamp,
      }
    end
  OutboxEvent.insert_all!(rows)
end

def scalar(sql)
  ActiveRecord::Base.connection.select_value(sql).to_i
end

runs = []
all_ok = true

BATCHES.each do |batch|
  RUNS.times do |run_index|
    reset_tables
    seed_events(N)

    env = {
      "RAILS_ENV" => Rails.env,
      "BATCH" => batch.to_s,
      "JITTER_MS" => JITTER_MS,
      "LEASE_SECONDS" => LEASE_SECONDS,
    }
    started = now
    pids = Array.new(WORKERS) { Process.spawn(env, RbConfig.ruby, WORKER, out: File::NULL, err: File::NULL) }
    statuses = pids.map { |pid| Process.waitpid2(pid).last }
    elapsed = now - started

    unpublished = scalar("select count(*) from outbox_events where published_at is null")
    charges = scalar("select count(*) from external_charges")
    distinct_charges = scalar("select count(distinct idempotency_key) from external_charges")
    duplicate_effect_keys = scalar(<<~SQL)
      select count(*) from (
        select idempotency_key from external_charges group by 1 having count(*) > 1
      ) duplicate_keys
    SQL
    attempts = scalar("select count(*) from delivery_attempts")
    duplicate_attempts = attempts - N
    duplicate_attempt_percent = (duplicate_attempts * 100.0 / N).round(2)
    exit_codes = statuses.map(&:exitstatus)
    ok =
      statuses.all?(&:success?) &&
      unpublished.zero? &&
      charges == N &&
      distinct_charges == N &&
      duplicate_effect_keys.zero? &&
      attempts >= N &&
      duplicate_attempt_percent <= MAX_DUP_ATTEMPT_PERCENT
    all_ok &&= ok

    row = {
      batch: batch,
      run: run_index,
      workers: WORKERS,
      n: N,
      jitter_ms: Float(JITTER_MS),
      lease_seconds: Float(LEASE_SECONDS),
      exit_codes: exit_codes,
      unpublished: unpublished,
      charges: charges,
      distinct_charges: distinct_charges,
      duplicate_effect_keys: duplicate_effect_keys,
      attempts: attempts,
      duplicate_attempts: duplicate_attempts,
      duplicate_attempt_percent: duplicate_attempt_percent,
      max_allowed_duplicate_attempt_percent: MAX_DUP_ATTEMPT_PERCENT,
      elapsed_s: elapsed.round(3),
      ok: ok,
    }
    runs << row
    puts format(
      "batch=%-2d run=%d workers=%d exits=%s unpublished=%d charges=%d distinct=%d attempts=%d dup_attempts=%d (+%.2f%%) %.2fs => %s",
      batch,
      run_index,
      WORKERS,
      exit_codes.uniq.inspect,
      unpublished,
      charges,
      distinct_charges,
      attempts,
      duplicate_attempts,
      row[:duplicate_attempt_percent],
      elapsed,
      ok ? "OK" : "FAIL",
    )
  end
end

summary = {
  generated_at_utc: Time.now.utc.iso8601,
  rails_env: Rails.env,
  n: N,
  workers: WORKERS,
  batches: BATCHES,
  runs_per_batch: RUNS,
  jitter_ms: Float(JITTER_MS),
  lease_seconds: Float(LEASE_SECONDS),
  max_allowed_duplicate_attempt_percent: MAX_DUP_ATTEMPT_PERCENT,
  all_ok: all_ok,
  max_duplicate_attempt_percent: runs.map { |run| run[:duplicate_attempt_percent] }.max,
  runs: runs,
}

File.write(JSON_OUT, JSON.pretty_generate(summary)) if JSON_OUT
puts(all_ok ? "STRESS OK" : "STRESS FAIL")
exit(all_ok ? 0 : 1)
