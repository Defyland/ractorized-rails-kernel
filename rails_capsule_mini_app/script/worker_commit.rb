# frozen_string_literal: true

# A standalone committer worker — one independent OS process (full Rails env booted) racing to
# commit a proposal built on base_version 0 of ORDER_ID. Exactly one such process can win the
# optimistic-lock race; the rest hit ActiveRecord::StaleObjectError (or the explicit StaleProposal
# pre-check) and roll back. Exit 0 = won (:committed), 3 = lost (:conflict). Any other code = a
# real, unexpected failure. Spawned, never forked.
require_relative "../config/environment"

order = Order.find(Integer(ENV.fetch("ORDER_ID")))
proposal = Capsule::Proposal.build(
  order_id: order.id,
  base_version: 0, # every committer targets v0 on purpose => deterministic single winner
  total_cents: 1000 + (Process.pid % 1000),
  effects: [Capsule::EffectIntent.charge(order_id: order.id, request_id: "p#{Process.pid}", amount_cents: 1)]
)

exit(Capsule::CommitCoordinator.commit!(proposal) == :committed ? 0 : 3)
