#!/usr/bin/env bash
# Phase 2 — run the real-Rails-integration gates against either:
#   1. an externally provided DATABASE_URL (skips Docker bootstrap), or
#   2. the disposable local postgres:16 container used in the original experiment notes.
# Usage: ./run.sh
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/opt/homebrew/opt/ruby/bin:$PATH"

if [[ -n "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL=${DATABASE_URL} (external Postgres; skipping Docker bootstrap)"
  exec bundle exec ruby test/slice_b_test.rb "$@"
fi

PORT="${CAPSULE_PG_PORT:-65432}"
export DATABASE_URL="postgres://capsule:capsule@127.0.0.1:${PORT}/capsule_test"

# Bring up a pinned, disposable Postgres if it isn't already running.
if ! docker exec capsule_pg pg_isready -U capsule -d capsule_test >/dev/null 2>&1; then
  echo "starting capsule_pg (postgres:16) on host port ${PORT} ..."
  docker rm -f capsule_pg >/dev/null 2>&1 || true
  docker run -d --name capsule_pg \
    -e POSTGRES_PASSWORD=capsule -e POSTGRES_USER=capsule -e POSTGRES_DB=capsule_test \
    -p "${PORT}:5432" postgres:16 >/dev/null
  for _ in $(seq 1 30); do
    docker exec capsule_pg pg_isready -U capsule -d capsule_test >/dev/null 2>&1 && break
    sleep 1
  done
fi

echo "DATABASE_URL=${DATABASE_URL}"
exec bundle exec ruby test/slice_b_test.rb "$@"
