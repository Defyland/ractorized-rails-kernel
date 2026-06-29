# frozen_string_literal: true

# A standalone outbox-dispatcher worker — one independent OS process that BOOTS THE FULL RAILS
# ENVIRONMENT and runs the dispatcher once. Spawned, never forked (libpq is not fork-safe on
# macOS and segfaults in connect_start). This is how production runs N dispatchers. Exit 0 on
# success; a non-zero status propagates a real failure to the parent test.
require_relative "../config/environment"

batch = Integer(ENV.fetch("BATCH", "10"))
lease_seconds = Float(ENV.fetch("LEASE_SECONDS", Capsule::OutboxDispatcher::DEFAULT_LEASE_SECONDS.to_s))
Capsule::OutboxDispatcher.run_once(batch:, lease_seconds:)
