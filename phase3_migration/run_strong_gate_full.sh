#!/usr/bin/env bash
# Atomic launcher for the Strong Host-Linux Economic Gate v2 FULL (and CANARY) runs.
#
# WHY THIS EXISTS (Phase 1 atomicity): the full gate is long; a kill mid-run must NOT leave an old aggregate next to fresh
# per-cell files, must NOT clobber the canonical full artifact, and must NOT touch the saved reduced evidence. This wrapper
# isolates every run under its own run_id dir, writes the aggregate JSON to a .partial and only ATOMIC-RENAMEs it on success,
# and stamps a manifest (started -> complete). The SHA-pinned runner strong_host_gate_v2.rb is NOT modified by any of this.
#
# It also REFUSES to mint a full economic artifact on a non-dedicated host (macOS/Colima/small VM) — a real economic claim
# may only come from a DEDICATED_LINUX_HOST. ALLOW_NON_DEDICATED=1 is for diagnostics only; the verifier rejects completed
# full artifacts whose manifest host_class is not DEDICATED_LINUX_HOST.
#
# Usage:
#   phase3_migration/run_strong_gate_full.sh full      # the decisive gate: hash,struct,blob x 200,500,1000 x 0,100,500 x 1,2,4,8
#   phase3_migration/run_strong_gate_full.sh canary    # runtime/cost probe only (hash x 500 x 0,100 x 1,2,4,8) — DOES NOT decide the thesis
#
# A completed FULL run lands in   phase3_migration/strong_gate_v2_full_runs/<run_id>/   and is validated by
# check_strong_host_gate_v2_full in verify_findings_evidence.rb (independent recompute). A CANARY lands in
# phase3_migration/strong_gate_v2_canary_runs/<run_id>/ and is NEVER validated as an economic result.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  full|canary) ;;
  *) echo "usage: $0 {full|canary}"; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
RUNNER="strong_host_gate_v2.rb"
[ -f "$RUNNER" ] || { echo "FATAL: $RUNNER not found in $REPO_ROOT"; exit 2; }
RUNNER_SHA="$(shasum -a 256 "$RUNNER" | cut -d' ' -f1)"

# ----- single source of truth for run parameters (the printed audit command and the executed run derive from THESE) -----
FULL_SHAPES="hash,struct,blob"; FULL_TARGETS="200,500,1000"; FULL_ALLOCS="0,100,500"; FULL_WORKERS="1,2,4,8"
CANARY_SHAPES="hash";          CANARY_TARGETS="500";        CANARY_ALLOCS="0,100";     CANARY_WORKERS="1,2,4,8"
REPS=6; DURATION=8; REFORK_EVERY_S=1.0

# ----- host classification -----
OS="$(uname -s)"
CLASS="UNKNOWN"
NCPU="?"; MEMKB="?"
if [ "$OS" = "Linux" ] && [ -e /proc/self/smaps_rollup ]; then
  NCPU="$(nproc 2>/dev/null || echo 1)"
  MEMKB="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "${NCPU:-0}" -ge 8 ] && [ "${MEMKB:-0}" -ge 16000000 ]; then
    CLASS="DEDICATED_LINUX_HOST"
  else
    CLASS="LINUX_UNDERSIZED"
  fi
else
  CLASS="MAC_OR_COLIMA"
fi
if ! docker info >/dev/null 2>&1; then
  CLASS="NO_DOCKER_OR_NO_LINUX"
fi

# the exact canonical full command, printed for auditability / running on a real host
print_full_command() {
  cat <<EOF
# Run this on a DEDICATED Linux host (native Docker), from the repo root:
#   ${0} full
# (equivalent raw docker command the wrapper wraps with atomicity:)
docker run --rm -v "\$PWD":/app -w /app -e LANG=C.UTF-8 \\
  -e SHAPES=${FULL_SHAPES} -e TARGETS_MB=${FULL_TARGETS} -e ALLOCS=${FULL_ALLOCS} -e WORKERS=${FULL_WORKERS} \\
  -e REPS=${REPS} -e DURATION=${DURATION} -e REFORK_EVERY_S=${REFORK_EVERY_S} \\
  -e OUT_DIR=/app/phase3_migration/strong_gate_v2_full_runs/<run_id>/cells \\
  -e RAW_LOG=/app/phase3_migration/strong_gate_v2_full_runs/<run_id>/run.log \\
  -e JSON_OUT=/app/phase3_migration/strong_gate_v2_full_runs/<run_id>/results.json \\
  ruby:4.0-slim ruby ${RUNNER}
# then: JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb
EOF
}

echo "host_class=$CLASS os=$OS ncpu=$NCPU memkb=$MEMKB runner_sha256=$RUNNER_SHA mode=$MODE"

if [ "$MODE" = "full" ] && [ "$CLASS" != "DEDICATED_LINUX_HOST" ] && [ "${ALLOW_NON_DEDICATED:-0}" != "1" ]; then
  echo "BLOCKED_BY_HOST_LINUX: refusing to mint a FULL economic artifact on host_class=$CLASS."
  echo "A full economic claim may only come from a DEDICATED_LINUX_HOST. Verdict stays PIVOT."
  print_full_command
  exit 3
fi
if [ "$CLASS" = "NO_DOCKER_OR_NO_LINUX" ]; then
  echo "BLOCKED_BY_HOST_LINUX: Docker/Linux not available — cannot run."
  print_full_command
  exit 3
fi

# ----- run configuration by mode -----
if [ "$MODE" = "full" ]; then
  RUN_BASE="phase3_migration/strong_gate_v2_full_runs"
  ENV_ARGS=(-e SHAPES="$FULL_SHAPES" -e TARGETS_MB="$FULL_TARGETS" -e ALLOCS="$FULL_ALLOCS" -e WORKERS="$FULL_WORKERS" -e REPS="$REPS" -e DURATION="$DURATION" -e REFORK_EVERY_S="$REFORK_EVERY_S")
else
  RUN_BASE="phase3_migration/strong_gate_v2_canary_runs"
  ENV_ARGS=(-e SHAPES="$CANARY_SHAPES" -e TARGETS_MB="$CANARY_TARGETS" -e ALLOCS="$CANARY_ALLOCS" -e WORKERS="$CANARY_WORKERS" -e REPS="$REPS" -e DURATION="$DURATION" -e REFORK_EVERY_S="$REFORK_EVERY_S")
fi

# run_id: timestamp + host + pid (no Date.now in the runner; bash supplies it). Isolated, never reused.
RUN_ID="${MODE}_$(date -u +%Y%m%dT%H%M%SZ)_$(hostname -s 2>/dev/null || echo host)_$$"
RUN_DIR="$RUN_BASE/$RUN_ID"
mkdir -p "$RUN_DIR/cells"

# manifest BEFORE the run (status=started) — a kill leaves this and the verifier ignores it (no status=complete)
write_manifest() { # $1=status
  cat > "$RUN_DIR/manifest.json" <<EOF
{
  "run_id": "$RUN_ID",
  "mode": "$MODE",
  "status": "$1",
  "runner_sha256": "$RUNNER_SHA",
  "host_class": "$CLASS",
  "ncpu": "$NCPU",
  "memkb": "$MEMKB",
  "started_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}
write_manifest "started"

PARTIAL="$RUN_DIR/results.json.partial"
FINAL="$RUN_DIR/results.json"
echo "launching $MODE run_id=$RUN_ID -> $RUN_DIR (JSON written atomically only on success)"

set +e
docker run --rm -v "$PWD":/app -w /app -e LANG=C.UTF-8 \
  "${ENV_ARGS[@]}" \
  -e OUT_DIR="/app/$RUN_DIR/cells" \
  -e RAW_LOG="/app/$RUN_DIR/run.log" \
  -e JSON_OUT="/app/$PARTIAL" \
  ruby:4.0-slim ruby "$RUNNER"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  write_manifest "failed"
  echo "RUN FAILED (exit $RC). Partial output left in $RUN_DIR; NO canonical results.json written; reduced untouched."
  exit "$RC"
fi
# completion gate (host-tool-free): the runner prints "JSON written:" as its LAST action, AFTER it finishes writing
# JSON_OUT. Its presence in the log + a non-empty partial means the aggregate was fully written, not truncated by a kill.
if [ ! -s "$PARTIAL" ] || ! grep -q "JSON written:" "$RUN_DIR/run.log" 2>/dev/null; then
  write_manifest "failed"
  echo "RUN did not finish writing $PARTIAL (no 'JSON written:' marker); NOT promoting. reduced untouched."
  exit 4
fi
# ATOMIC promote + mark complete
mv -f "$PARTIAL" "$FINAL"
write_manifest "complete"
{ echo "ATOMIC_RENAME results.json run_id=$RUN_ID status=complete runner_sha256=$RUNNER_SHA"; } >> "$RUN_DIR/run.log"
echo "RUN COMPLETE: $FINAL"
if [ "$MODE" = "full" ]; then
  echo "Now validate independently:"
  echo "  JSON_OUT=phase3_migration/raw_logs/findings_evidence_check_latest.json ruby phase3_migration/verify_findings_evidence.rb"
  echo "check_strong_host_gate_v2_full will recompute every verdict from the cells and reject any non-robust survives."
else
  echo "CANARY only — runtime/cost probe. It does NOT decide the thesis and is NOT validated as an economic result."
fi
