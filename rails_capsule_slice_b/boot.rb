# frozen_string_literal: true

# Phase 2 boot — real ActiveRecord + ActiveSupport against a real Postgres.
require "bundler/setup"
require "active_record"
require "active_support"
require "active_support/current_attributes"
require "logger"
require "json"

# Real Postgres. Default points at the disposable Docker container on host:65432
# (see ../docs/decisions.md Phase 2). Override with DATABASE_URL to use any PG >= 9.5
# (needs: jsonb, FOR UPDATE SKIP LOCKED, optimistic lock_version — all app/AR-level).
DB_URL = ENV.fetch("DATABASE_URL", "postgres://capsule:capsule@127.0.0.1:65432/capsule_test")

ActiveRecord::Base.establish_connection(DB_URL)
# Silence query logging in tests; flip with AR_LOG=1 to inspect the real SQL the protocol emits.
ActiveRecord::Base.logger = ENV["AR_LOG"] == "1" ? Logger.new($stdout) : Logger.new(IO::NULL)
