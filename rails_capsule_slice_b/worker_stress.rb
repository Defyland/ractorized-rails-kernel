# frozen_string_literal: true

# Stress dispatcher: same claim/deliver/mark shape as the real OutboxDispatcher, but with random
# jitter between the steps to WIDEN the at-least-once window (maximize the chance two workers deliver
# the same event), so the idempotency_key dedup is genuinely stressed. Spawned, never forked.
require_relative "boot"
require_relative "domain"
require_relative "capsule"

batch  = Integer(ENV.fetch("BATCH", "5"))
jitter = Float(ENV.fetch("JITTER_MS", "0")) / 1000.0
lease_seconds = Float(ENV.fetch("LEASE_SECONDS", Capsule::OutboxDispatcher::DEFAULT_LEASE_SECONDS.to_s))

loop do
  events = Capsule::OutboxDispatcher.claim(batch, lease_seconds:)
  break if events.empty?

  events.each do |event|
    sleep(rand * jitter) if jitter.positive?
    DeliveryAttempt.create!(idempotency_key: event.idempotency_key)
    Capsule::ExternalConsumer.deliver!(event)
    sleep(rand * jitter) if jitter.positive?
    Capsule::OutboxDispatcher.mark_published(event)
  end
end
