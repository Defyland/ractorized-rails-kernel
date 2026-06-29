# frozen_string_literal: true

# Reviewer #7 — high-volume concurrent dispatch with SQL verification.
# N events, WORKERS spawned jittered dispatchers, batch sizes 1/5/10, RUNS each. After every run:
#   unpublished == 0  (nothing stranded), charges == N == distinct keys, dups == 0 (no duplicate effect),
#   and raw delivery attempts stay within MAX_DUP_ATTEMPT_PERCENT.
require "json"
require "time"
require_relative "boot"
require_relative "schema"
require_relative "domain"
require_relative "capsule"

N       = Integer(ENV.fetch("N", "10000"))
WORKERS = Integer(ENV.fetch("WORKERS", "16"))
RUNS    = Integer(ENV.fetch("RUNS", "2"))
JITTER  = ENV.fetch("JITTER_MS", "1")
LEASE_SECONDS = ENV.fetch("LEASE_SECONDS", "30")
MAX_DUP_ATTEMPT_PERCENT = Float(ENV.fetch("MAX_DUP_ATTEMPT_PERCENT", "0"))
BATCHES = ENV.fetch("BATCHES", "1,5,10").split(",").map(&:to_i)
WORKER  = File.expand_path("worker_stress.rb", __dir__)
JSON_OUT = ENV["JSON_OUT"]
conn    = ActiveRecord::Base.connection

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

all_ok = true
runs = []
BATCHES.each do |batch|
  RUNS.times do |r|
    conn.truncate_tables("external_charges", "outbox_events", "orders", "users", "delivery_attempts")
    order = Order.create!(user: User.create!(name: "s"), total_cents: 1)
    rows = Array.new(N) do |i|
      f = Capsule::EffectIntent.charge(order_id: order.id, request_id: "x#{i}", amount_cents: i + 1)
      { idempotency_key: f.idempotency_key, event_type: f.event_type, payload: f.payload,
        created_at: Time.now, updated_at: Time.now }
    end
    OutboxEvent.insert_all(rows)

    env = {
      "DATABASE_URL" => ENV["DATABASE_URL"],
      "BATCH" => batch.to_s,
      "JITTER_MS" => JITTER,
      "LEASE_SECONDS" => LEASE_SECONDS,
    }
    t0 = now
    pids = Array.new(WORKERS) { Process.spawn(env, RbConfig.ruby, WORKER, out: File::NULL) }
    statuses = pids.map { |p| Process.waitpid2(p).last.exitstatus }
    dt = now - t0

    unpub    = conn.select_value("select count(*) from outbox_events where published_at is null").to_i
    charges  = conn.select_value("select count(*) from external_charges").to_i
    distinct = conn.select_value("select count(distinct idempotency_key) from external_charges").to_i
    dups     = conn.select_value("select count(*) from (select idempotency_key from external_charges group by 1 having count(*) > 1) t").to_i
    # Attempt cost: external_charges dedups to N, but each ATTEMPT is a real external call.
    attempts = conn.select_value("select count(*) from delivery_attempts").to_i
    dup_attempt_percent = (attempts - N) * 100.0 / N
    ok =
      unpub.zero? &&
      charges == N &&
      distinct == N &&
      dups.zero? &&
      statuses.all?(&:zero?) &&
      dup_attempt_percent <= MAX_DUP_ATTEMPT_PERCENT
    all_ok &&= ok
    attempt_note = format(" attempts=%d dup_attempts=%d (+%.1f%%)", attempts, attempts - N, dup_attempt_percent)
    runs << {
      batch: batch,
      run: r,
      workers: WORKERS,
      n: N,
      jitter_ms: Float(JITTER),
      lease_seconds: Float(LEASE_SECONDS),
      max_allowed_duplicate_attempt_percent: MAX_DUP_ATTEMPT_PERCENT,
      exit_codes: statuses,
      unpublished: unpub,
      charges: charges,
      distinct_charges: distinct,
      duplicate_effect_keys: dups,
      attempts: attempts,
      duplicate_attempts: attempts - N,
      duplicate_attempt_percent: dup_attempt_percent.round(2),
      elapsed_s: dt.round(3),
      ok: ok,
    }
    puts format("batch=%-2d run=%d workers=%d exits=%s unpublished=%d charges=%d distinct=%d dups=%d%s %5.1fs => %s",
                batch, r, WORKERS, statuses.uniq.inspect, unpub, charges, distinct, dups, attempt_note, dt, ok ? "OK" : "FAIL")
  end
end

if JSON_OUT
  summary = {
    generated_at_utc: Time.now.utc.iso8601,
    n: N,
    workers: WORKERS,
    batches: BATCHES,
    runs_per_batch: RUNS,
    jitter_ms: Float(JITTER),
    lease_seconds: Float(LEASE_SECONDS),
    max_allowed_duplicate_attempt_percent: MAX_DUP_ATTEMPT_PERCENT,
    all_ok: all_ok,
    max_duplicate_attempt_percent: runs.map { |run| run[:duplicate_attempt_percent] }.max,
    runs: runs,
  }
  File.write(JSON_OUT, JSON.pretty_generate(summary))
end

puts(all_ok ? "STRESS OK (N=#{N}, workers=#{WORKERS}, jitter=#{JITTER}ms)" : "STRESS FAIL")
exit(all_ok ? 0 : 1)
