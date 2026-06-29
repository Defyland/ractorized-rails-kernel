# frozen_string_literal: true

# Demonstrates WHY the dispatcher must deliver BEFORE marking published_at. This worker does the
# WRONG order — mark first, then crash before delivering — to prove the effect is then lost forever.
# Spawned, never forked. Does NOT require schema.rb.
require_relative "boot"
require_relative "domain"
require_relative "capsule"

lease_seconds = Float(ENV.fetch("LEASE_SECONDS", Capsule::OutboxDispatcher::DEFAULT_LEASE_SECONDS.to_s))
event = Capsule::OutboxDispatcher.claim(1, lease_seconds:).first
exit(2) if event.nil?

Capsule::OutboxDispatcher.mark_published(event) # WRONG: mark published before the external effect happened
Process.kill("KILL", Process.pid)      # crash before delivery
Capsule::ExternalConsumer.deliver!(event) # never reached
