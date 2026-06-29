# frozen_string_literal: true

# A standalone outbox-dispatcher worker — one independent OS process, its own fresh libpq
# connection (spawned, never forked: libpq is not fork-safe on macOS). This is how production
# runs N dispatchers. Deliberately does NOT require schema.rb (that would truncate the table the
# parent just seeded). Exit 0 on success; non-zero propagates a real failure to the parent.
require_relative "boot"
require_relative "domain"
require_relative "capsule"

batch = Integer(ENV.fetch("BATCH", "10"))
lease_seconds = Float(ENV.fetch("LEASE_SECONDS", Capsule::OutboxDispatcher::DEFAULT_LEASE_SECONDS.to_s))
Capsule::OutboxDispatcher.run_once(batch:, lease_seconds:)
