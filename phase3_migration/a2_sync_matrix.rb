# frozen_string_literal: true

# Runs the A2.3 bounded-sync gateway sweep as the REAL 3D matrix and aggregates JSON.
#
# Internal audit harness only. The README/FINDINGS axis for A2.3 is gateway_calls/compute_ms — a function of
# read frequency (CAP_EVERY) AND compute weight (SCAN) AND allocation pressure (ALLOC). A CAP_EVERY×TIMEOUT
# slice with SCAN/ALLOC fixed does NOT cover that axis, so this sweeps SCAN × ALLOC × CAP_EVERY, each at a
# representative TIMEOUT and at least one aggressive TIMEOUT as a negative control (it must force timeouts → FAIL).
#
# Example:
#   SCANS=100,500,1500 ALLOCS=0,100,500 CAP_EVERYS=1,10,100,1000 TIMEOUTS=1.0,0.000001 \
#     REPS=2 DURATION=1.0 ruby phase3_migration/a2_sync_matrix.rb
require "fileutils"
require "json"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
PHASE3 = File.join(ROOT, "phase3_migration")
RAW_DIR = File.join(PHASE3, "raw_logs")
MATRIX_NAME = ENV.fetch("MATRIX_NAME", "a2_sync_matrix")
RUN_DIR = File.expand_path(ENV.fetch("MATRIX_RUN_DIR", File.join(PHASE3, "#{MATRIX_NAME}_runs")))
MATRIX_OUT = File.expand_path(ENV.fetch("MATRIX_OUT", File.join(PHASE3, "#{MATRIX_NAME}_results.json")))
RAW_PREFIX = ENV.fetch("MATRIX_RAW_PREFIX", MATRIX_NAME)

def csv(name, default)
  ENV.fetch(name, default).split(",").map(&:strip).reject(&:empty?)
end

def docker_env
  return {} if ENV["DOCKER_HOST"]

  colima_socket = File.join(Dir.home, ".colima", "default", "docker.sock")
  File.exist?(colima_socket) ? { "DOCKER_HOST" => "unix://#{colima_socket}" } : {}
end

def relative_to_root(path)
  expanded = File.expand_path(path)
  prefix = "#{ROOT}/"
  raise "#{expanded} must live under #{ROOT}; Docker only mounts the repo root" unless expanded.start_with?(prefix)

  expanded.sub(prefix, "")
end

def slug_num(value)
  value.to_s.tr(".", "p").tr("-", "m")
end

def run_a2(scan, alloc, cap_every, timeout_s, json_path, log_path)
  image = ENV.fetch("RUBY_DOCKER_IMAGE", "ruby:4.0-slim")
  gate_env = {
    "N_RULES" => ENV.fetch("N_RULES", "80000"),
    "ITEMS" => ENV.fetch("ITEMS", "300"),
    "SCAN" => scan.to_s,
    "ALLOC" => alloc.to_s,
    "POOL" => ENV.fetch("POOL", "4"),
    "DURATION" => ENV.fetch("DURATION", "1.0"),
    "REPS" => ENV.fetch("REPS", "2"),
    "CACHE_SZ" => ENV.fetch("CACHE_SZ", "1000"),
    "CAP_EVERY" => cap_every.to_s,
    "TIMEOUT_S" => timeout_s.to_s,
    "JSON_OUT" => relative_to_root(json_path),
  }

  cmd = ["docker", "run", "--rm", "-v", "#{ROOT}:/app", "-w", "/app"]
  gate_env.each { |key, value| cmd.concat(["-e", "#{key}=#{value}"]) }
  cmd.concat([image, "ruby", "a2_cache_sync.rb"])

  stdout, stderr, status = Open3.capture3(docker_env, *cmd)
  File.write(log_path, stdout + stderr)
  unless status.success?
    raise "a2_cache_sync failed for SCAN=#{scan} ALLOC=#{alloc} CAP_EVERY=#{cap_every} TIMEOUT_S=#{timeout_s}; see #{log_path}"
  end

  JSON.parse(File.read(json_path))
end

def compact_result(result)
  sync = result.fetch("models").fetch("ractor_sync_cache")
  process = result.fetch("models").fetch("process_direct_cache")
  no_cache = result.fetch("models").fetch("ractor_no_cache")
  derived = result.fetch("derived")
  verdict = result.fetch("verdict")
  {
    "status" => verdict.fetch("status"),
    "reason" => verdict["reason"],
    "correct" => sync.fetch("correct"),
    "timeouts" => sync.fetch("timeouts"),
    "stale" => sync.fetch("stale"),
    "sync_gateway_tax_percent" => derived.fetch("sync_gateway_tax_percent"),
    "throughput_vs_process_percent" => derived.fetch("throughput_vs_process_percent"),
    "ractor_sync_items_s" => sync.fetch("tput"),
    "process_items_s" => process.fetch("tput"),
    "ractor_no_cache_items_s" => no_cache.fetch("tput"),
    "p50_ms" => sync.fetch("p50"),
    "p95_ms" => sync.fetch("p95"),
    "p99_ms" => sync.fetch("p99"),
  }
end

# Deterministic aggregate — REPLICATED verbatim in verify_findings_evidence.rb (a2_aggregate) so the verifier
# can rebuild it and assert no drift. The aggressive timeout is the smallest TIMEOUTS value (negative control:
# it must force timeouts → FAIL in every cell). passing_cells makes the call/compute boundary machine-readable.
def aggregate(runs, timeouts)
  aggressive = timeouts.min
  statuses = runs.map { |run| run.dig("result", "status") }
  representative = runs.reject { |run| run.fetch("timeout_s") == aggressive }
  {
    "cells" => runs.size,
    "passes" => statuses.count("pass"),
    "fails" => statuses.count("fail"),
    "inconclusive" => statuses.count("inconclusive"),
    "all_cells_fail" => statuses.all? { |status| status == "fail" },
    "any_cell_passes" => statuses.include?("pass"),
    "aggressive_timeout_s" => aggressive,
    "aggressive_cells_all_fail" => runs.select { |run| run.fetch("timeout_s") == aggressive }
                                       .all? { |run| run.dig("result", "status") == "fail" },
    "representative_cells" => representative.size,
    "representative_passes" => representative.count { |run| run.dig("result", "status") == "pass" },
    "passing_cells" => runs.select { |run| run.dig("result", "status") == "pass" }
                          .map { |run| run.slice("scan", "alloc", "cap_every", "timeout_s") },
  }
end

# Per (scan, alloc) cell: which CAP_EVERY/TIMEOUT statuses, and the worst vs-process / best tax. Shows the
# boundary along the compute (SCAN) and allocation (ALLOC) axes.
def by_scan_alloc(runs)
  grouped = Hash.new { |hash, key| hash[key] = [] }
  runs.each { |run| grouped["scan=#{run.fetch("scan")},alloc=#{run.fetch("alloc")}"] << run }

  grouped.transform_values do |rows|
    {
      "statuses" => rows.to_h { |row| ["cap=#{row.fetch("cap_every")},to=#{row.fetch("timeout_s")}", row.dig("result", "status")] },
      "any_pass" => rows.any? { |row| row.dig("result", "status") == "pass" },
      "all_fail" => rows.all? { |row| row.dig("result", "status") == "fail" },
      "min_throughput_vs_process_percent" => rows.map { |row| row.dig("result", "throughput_vs_process_percent") }.min,
      "max_sync_gateway_tax_percent" => rows.map { |row| row.dig("result", "sync_gateway_tax_percent") }.max,
    }
  end
end

def main
  FileUtils.mkdir_p(RUN_DIR)
  FileUtils.mkdir_p(RAW_DIR)

  scans = csv("SCANS", "100,500,1500").map { |value| Integer(value) }
  allocs = csv("ALLOCS", "0,100,500").map { |value| Integer(value) }
  caps = csv("CAP_EVERYS", "1,10,100,1000").map { |value| Integer(value) }
  timeouts = csv("TIMEOUTS", "1.0,0.000001").map { |value| Float(value) }
  runs = []

  scans.product(allocs, caps, timeouts).each do |scan, alloc, cap_every, timeout_s|
    slug = "scan#{scan}_alloc#{alloc}_cap#{cap_every}_to#{slug_num(timeout_s)}"
    json_path = File.join(RUN_DIR, "#{slug}.json")
    log_path = File.join(RAW_DIR, "#{RAW_PREFIX}_#{slug}.log")
    puts "running SCAN=#{scan} ALLOC=#{alloc} CAP_EVERY=#{cap_every} TIMEOUT_S=#{timeout_s} -> #{json_path}"
    result = run_a2(scan, alloc, cap_every, timeout_s, json_path, log_path)
    runs << {
      "scan" => scan,
      "alloc" => alloc,
      "cap_every" => cap_every,
      "timeout_s" => timeout_s,
      "json_file" => relative_to_root(json_path),
      "raw_log" => relative_to_root(log_path),
      "result" => compact_result(result),
    }
  end

  summary = {
    "generated_at_utc" => Time.now.utc.iso8601,
    "scope" => {
      "scans" => scans,
      "allocs" => allocs,
      "cap_everys" => caps,
      "timeouts_s" => timeouts,
      "n_rules" => Integer(ENV.fetch("N_RULES", "80000")),
      "items" => Integer(ENV.fetch("ITEMS", "300")),
      "pool" => Integer(ENV.fetch("POOL", "4")),
      "duration_s" => Float(ENV.fetch("DURATION", "1.0")),
      "reps" => Integer(ENV.fetch("REPS", "2")),
      "cache_size" => Integer(ENV.fetch("CACHE_SZ", "1000")),
      "note" => "3D SCAN×ALLOC×CAP_EVERY sweep at representative + aggressive(negative-control) TIMEOUT. " \
                "Local reduced REPS/DURATION; raise for a final claim.",
    },
    "aggregate" => aggregate(runs, timeouts),
    "by_scan_alloc" => by_scan_alloc(runs),
    "runs" => runs,
  }

  File.write(MATRIX_OUT, JSON.pretty_generate(summary))
  puts "A2 3D matrix JSON written: #{MATRIX_OUT}"
  puts "aggregate: #{summary.fetch('aggregate').slice('cells', 'passes', 'fails', 'inconclusive', 'all_cells_fail', 'any_cell_passes')}"
end

main if $PROGRAM_NAME == __FILE__
