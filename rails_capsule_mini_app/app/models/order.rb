# frozen_string_literal: true

class Order < ApplicationRecord
  belongs_to :user
  # No `lock_version` declaration is needed: AR auto-enables optimistic locking from
  # the column name. UPDATE ... WHERE lock_version = N; 0 rows affected => StaleObjectError.

  # A real after_commit hook. It fires ONLY after the enclosing transaction commits,
  # and never on rollback — the test asserts both halves empirically.
  #
  # WHY THE EXTERNAL EFFECT DOES NOT LIVE HERE:
  # after_commit is in-process and NON-durable. If the process crashes in the window
  # between the database COMMIT returning and Rails invoking the after_commit callback,
  # the callback is simply lost — there is no record that it still needs to run. For an
  # EXTERNAL side effect (charging a card) that lost callback means a silently dropped
  # charge. So the external effect is instead written DURABLY as an outbox row inside the
  # same committed transaction, and an INDEPENDENT dispatcher process delivers it later
  # (at-least-once) and the consumer's unique idempotency_key dedups. after_commit here is
  # only an observable in-process signal, never the delivery mechanism.
  after_commit :record_committed_signal

  # An in-memory, process-local signal the test can observe. Reset by Current between cases.
  def record_committed_signal
    Current.last_committed_order_id = id
  end
end
