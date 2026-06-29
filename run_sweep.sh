#!/bin/sh
# run_sweep.sh — decisive core refork sweep (Linux/Docker). Runs SERIALLY (parallel containers corrupt throughput).
# 3 shapes calibrated to ~400MB resident, POOLS 1/2/4, ALLOC {0,100,500} at wall-clock 1.0s/gen, + a 0.3s aggressive
# spot check at ALLOC=100/pool=4. Writes per-config JSON and tees everything to sweep.log.
set -e
cd /Users/allanflavio/Documents/projects/PERSONAL/backend-challenges/ractorized-rails-kernel
NH=2300000; NS=5000000; NB=26000000   # calibrated per-shape N (measured ~410/400/405 MB)

for A in 0 100 500; do
  echo "######## ALLOC=$A  cadence=wall 1.0s/gen  POOLS=1,2,4  REPS=4  DURATION=5 ########"
  docker run --rm -v "$PWD":/app -w /app \
    -e SHAPES=hash,struct,blob -e N_RULES_HASH=$NH -e N_RULES_STRUCT=$NS -e N_RULES_BLOB=$NB \
    -e POOLS=1,2,4 -e DURATION=5 -e REPS=4 -e REFORK_EVERY_S=1.0 -e ALLOC=$A \
    -e JSON_OUT=/app/sweep_alloc${A}.json \
    ruby:4.0-slim ruby refork_gate.rb
  echo ""
done

echo "######## AGGRESSIVE cadence=0.3s/gen  ALLOC=100  POOLS=4  REPS=4  DURATION=5 (refork's best memory shot) ########"
docker run --rm -v "$PWD":/app -w /app \
  -e SHAPES=hash,struct,blob -e N_RULES_HASH=$NH -e N_RULES_STRUCT=$NS -e N_RULES_BLOB=$NB \
  -e POOLS=4 -e DURATION=5 -e REPS=4 -e REFORK_EVERY_S=0.3 -e ALLOC=100 \
  -e JSON_OUT=/app/sweep_aggressive.json \
  ruby:4.0-slim ruby refork_gate.rb

echo "######## SWEEP DONE ########"
