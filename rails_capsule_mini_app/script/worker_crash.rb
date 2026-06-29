# frozen_string_literal: true

# Dispatcher instrumented to SIGKILL itself at one of the three dangerous points, to falsify the
# crash-recovery claim. Boots the full Rails env. CRASH_POINT:
#   A = after claiming the outbox row, BEFORE delivering to the consumer
#   B = after delivering, BEFORE marking published_at  (the at-least-once window)
#   C = after marking published_at
# SIGKILL (not exit) so no ensure/at_exit can paper over the crash.
require_relative "../config/environment"

point = ENV.fetch("CRASH_POINT")
lease_seconds = Float(ENV.fetch("LEASE_SECONDS", Capsule::OutboxDispatcher::DEFAULT_LEASE_SECONDS.to_s))
event = Capsule::OutboxDispatcher.claim(1, lease_seconds:).first
exit(2) if event.nil? # nothing to claim — surfaces as an unexpected status

Process.kill("KILL", Process.pid) if point == "A"
Capsule::ExternalConsumer.deliver!(event)
Process.kill("KILL", Process.pid) if point == "B"
Capsule::OutboxDispatcher.mark_published(event)
Process.kill("KILL", Process.pid) if point == "C"
exit(0)
