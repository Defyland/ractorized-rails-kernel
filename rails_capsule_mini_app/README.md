# Rails Capsule Mini App

Booted Rails proof for the `ractorized-rails-kernel` thesis. This app is not a product shell and not a deploy target.
Its job is narrower: prove that the Proposal + Outbox + CapsuleContext protocol still behaves correctly inside a genuinely
booted Rails 8 app with real Rails globals, real Active Record, and real Postgres.

## What this slice proves

- Rails globals such as `Current`, `Rails.cache`, and `Rails.logger` are not safely usable from a worker Ractor.
- A capsule can still compute inside a non-main Ractor when it receives only explicit, shareable inputs.
- Owner-side commit/outbox semantics stay correct under real optimistic locking, `after_commit`, spawned worker processes,
  and idempotent re-delivery.

## What this slice does not prove

- Whole-request execution from a Ractor
- Deployability or operations of a Rails service
- A generic gem or migration path for arbitrary Rails apps

## Requirements

- Ruby 4.0.5
- PostgreSQL 14+ or 16+

The committed `config/credentials.yml.enc` is unused by the current experiment. `config/master.key` is intentionally not
tracked; generate your own only if you later choose to add credentials-dependent behavior.

## Run the test suite

Using a local Postgres over the default Unix socket:

```sh
createdb capsule_railsapp_test || true
RAILS_ENV=test TEST_DATABASE_URL=postgres:///capsule_railsapp_test bundle exec bin/rails db:prepare
RAILS_ENV=test TEST_DATABASE_URL=postgres:///capsule_railsapp_test bundle exec ruby test/capsule_rails_test.rb
```

Using the original Docker-oriented database address from the research notes:

```sh
RAILS_ENV=test TEST_DATABASE_URL=postgres://capsule:capsule@127.0.0.1:65432/capsule_railsapp_test \
  bundle exec bin/rails db:prepare
RAILS_ENV=test TEST_DATABASE_URL=postgres://capsule:capsule@127.0.0.1:65432/capsule_railsapp_test \
  bundle exec ruby test/capsule_rails_test.rb
```

## Key files

- `test/capsule_rails_test.rb`: booted-Rails falsification suite
- `script/worker_*.rb`: spawned multi-process committer/dispatcher/crash helpers
- `config/database.yml`: Docker-default config with explicit test URL override support

The top-level repository [`README.md`](../README.md) is the canonical evaluation path for reviewers.
