# frozen_string_literal: true

# Stress dispatcher worker: same claim/deliver/mark sequence as Capsule::OutboxDispatcher,
# with optional jitter to widen the at-least-once window. Spawned as an independent
# Rails process by stress_dispatch.rb.
require_relative "../config/environment"

batch = Integer(ENV.fetch("BATCH", "5"))
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
