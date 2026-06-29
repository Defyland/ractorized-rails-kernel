# frozen_string_literal: true

# Runs refork_gate.rb as a reproducible Docker/Linux matrix and aggregates JSON.
#
# This is an internal audit harness, not product/runtime tooling. It exists to
# make the economic gate falsifiable across ALLOC and dataset shapes instead of
# relying on hand-run probes.
#
# Example:
#   DOCKER_HOST=unix://$HOME/.colima/default/docker.sock \
#   ALLOCS=0,100,500 SHAPES=hash,struct,blob REPS=1 DURATION=1.2 \
#   ruby phase3_migration/economic_gate_matrix.rb
require "fileutils"
require "json"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
PHASE3 = File.join(ROOT, "phase3_migration")
RAW_DIR = File.join(PHASE3, "raw_logs")
MATRIX_NAME = ENV.fetch("MATRIX_NAME", "matrix")
RUN_DIR = File.expand_path(ENV.fetch("MATRIX_RUN_DIR", File.join(PHASE3, "economic_gate_#{MATRIX_NAME}_runs")))
MATRIX_OUT = File.expand_path(ENV.fetch("MATRIX_OUT", File.join(PHASE3, "economic_gate_#{MATRIX_NAME}_results.json")))
RAW_PREFIX = ENV.fetch("MATRIX_RAW_PREFIX", "economic_gate_#{MATRIX_NAME}")

def csv(name, default)
  ENV.fetch(name, default).split(",").map(&:strip).reject(&:empty?)
end

def docker_env
  env = {}
  return env if ENV["DOCKER_HOST"]

  colima_socket = File.join(Dir.home, ".colima", "default", "docker.sock")
  env["DOCKER_HOST"] = "unix://#{colima_socket}" if File.exist?(colima_socket)
  env
end

def run_refork_gate(alloc, json_path, log_path)
  image = ENV.fetch("RUBY_DOCKER_IMAGE", "ruby:4.0-slim")
  gate_env = {
    "N_RULES" => ENV.fetch("N_RULES", "1000000"),
    "N_RULES_HASH" => ENV.fetch("N_RULES_HASH", "800000"),
    "N_RULES_STRUCT" => ENV.fetch("N_RULES_STRUCT", "1500000"),
    "N_RULES_BLOB" => ENV.fetch("N_RULES_BLOB", "8000000"),
    "ITEMS" => ENV.fetch("ITEMS", "500"),
    "SCAN" => ENV.fetch("SCAN", "500"),
    "ALLOC" => alloc.to_s,
    "POOLS" => ENV.fetch("POOLS", "1,2"),
    "SHAPES" => ENV.fetch("SHAPES", "hash,struct,blob"),
    "DURATION" => ENV.fetch("DURATION", "1.2"),
    "REPS" => ENV.fetch("REPS", "1"),
    "REFORK_EVERY_S" => ENV.fetch("REFORK_EVERY_S", "1.0"),
    "PASSES_PER_GEN" => ENV.fetch("PASSES_PER_GEN", "1"),
    "JSON_OUT" => relative_to_root(json_path),
  }

  cmd = ["docker", "run", "--rm", "-v", "#{ROOT}:/app", "-w", "/app"]
  gate_env.each { |key, value| cmd.concat(["-e", "#{key}=#{value}"]) }
  cmd.concat([image, "ruby", "refork_gate.rb"])

  stdout, stderr, status = Open3.capture3(docker_env, *cmd)
  File.write(log_path, stdout + stderr)
  raise "refork_gate failed for ALLOC=#{alloc}; see #{log_path}" unless status.success?

  JSON.parse(File.read(json_path))
end

def relative_to_root(path)
  expanded = File.expand_path(path)
  prefix = "#{ROOT}/"
  raise "#{expanded} must live under #{ROOT}; Docker only mounts the repo root" unless expanded.start_with?(prefix)

  expanded.sub(prefix, "")
end

def shape_verdicts(run)
  run.fetch("shapes").to_h do |shape|
    verdict = shape.fetch("verdict")
    row = {
      "n_rules" => shape.fetch("n_rules"),
      "status" => verdict.fetch("status"),
      "reason" => verdict["reason"],
    }
    if verdict["ractor_best"]
      row.merge!(
        "absolute_saving_mb" => verdict.fetch("absolute_saving_mb"),
        "pss_ratio_percent" => verdict.fetch("pss_ratio_percent"),
        "throughput_reach_percent" => verdict.fetch("throughput_reach_percent"),
        "ractor_pss_mb" => verdict.fetch("ractor_best").fetch("pss_mb"),
        "refork_iso_pss_mb" => verdict.fetch("refork_iso_pss_mb"),
      )
    end
    [
      shape.fetch("shape"),
      row,
    ]
  end
end

def summarize_by_shape(runs)
  grouped = Hash.new { |h, k| h[k] = [] }
  runs.each do |run|
    run.fetch("shape_verdicts").each do |shape, verdict|
      grouped[shape] << verdict.merge("alloc" => run.fetch("alloc"))
    end
  end

  grouped.transform_values do |verdicts|
    survives = verdicts.select { |v| v.fetch("status") == "survives" }
    {
      "allocs" => verdicts.map { |v| v.fetch("alloc") },
      "statuses" => verdicts.to_h { |v| [v.fetch("alloc"), v.fetch("status")] },
      "survives_allocs" => survives.map { |v| v.fetch("alloc") },
      "max_absolute_saving_mb" => verdicts.filter_map { |v| v["absolute_saving_mb"] }.max,
      "min_pss_ratio_percent" => verdicts.filter_map { |v| v["pss_ratio_percent"] }.min,
      "min_throughput_reach_percent" => verdicts.filter_map { |v| v["throughput_reach_percent"] }.min,
    }
  end
end

def main
  FileUtils.mkdir_p(RUN_DIR)
  FileUtils.mkdir_p(RAW_DIR)

  allocs = csv("ALLOCS", "0,100,500,2000").map { |value| Integer(value) }
  runs = []

  allocs.each do |alloc|
    json_path = File.join(RUN_DIR, "alloc_#{alloc}.json")
    log_path = File.join(RAW_DIR, "#{RAW_PREFIX}_alloc_#{alloc}.log")
    puts "running ALLOC=#{alloc} -> #{json_path}"
    result = run_refork_gate(alloc, json_path, log_path)
    runs << {
      "alloc" => alloc,
      "json_file" => json_path.sub("#{ROOT}/", ""),
      "raw_log" => log_path.sub("#{ROOT}/", ""),
      "shape_verdicts" => shape_verdicts(result),
    }
  end

  summary = {
    "generated_at_utc" => Time.now.utc.iso8601,
    "scope" => {
      "allocs" => allocs,
      "shapes" => ENV.fetch("SHAPES", "hash,struct,blob").split(","),
      "pools" => ENV.fetch("POOLS", "1,2"),
      "duration_s" => Float(ENV.fetch("DURATION", "1.2")),
      "reps" => Integer(ENV.fetch("REPS", "1")),
      "note" => "Reduced local matrix unless ALLOCS/REPS/DURATION are raised; final gate still requires broader Linux runs.",
    },
    "runs" => runs,
    "by_shape" => summarize_by_shape(runs),
  }

  File.write(MATRIX_OUT, JSON.pretty_generate(summary))
  puts "matrix JSON written: #{MATRIX_OUT}"
end

main if $PROGRAM_NAME == __FILE__
