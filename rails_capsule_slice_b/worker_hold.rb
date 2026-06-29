# frozen_string_literal: true

# Helper for the SKIP LOCKED falsification: acquire a REAL `FOR UPDATE` row lock on LOCK_ID, signal
# readiness by touching READY_FILE, then hold the lock (sleep) so a concurrent dispatcher must skip
# the row. Spawned, never forked. Does NOT require schema.rb (would wipe the parent's seed).
require_relative "boot"
require_relative "domain"

id   = Integer(ENV.fetch("LOCK_ID"))
ready = ENV.fetch("READY_FILE")
hold = Float(ENV.fetch("HOLD_SECS", "5"))

ActiveRecord::Base.transaction do
  ActiveRecord::Base.connection.execute("SELECT id FROM outbox_events WHERE id = #{id} FOR UPDATE")
  File.write(ready, "locked") # visible to the parent only AFTER the lock is held
  sleep(hold)
end
