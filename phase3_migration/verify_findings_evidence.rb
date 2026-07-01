# frozen_string_literal: true

# Verifies that the machine-readable evidence still supports the high-risk claims
# in FINDINGS.md. This is not a benchmark runner; it is a drift guard for the
# audit record itself.
require "digest"
require "json"
require "open3"
require "time"

# Raw logs / sources are UTF-8 (refork_gate emits ×, →, ≤); force UTF-8 reads so the guard runs under any locale
# (an empty LANG defaults Ruby to US-ASCII and would crash on the first UTF-8 byte). Robustness only — no check relaxed.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
PHASE3 = File.join(ROOT, "phase3_migration")
RAW_DIR = File.join(PHASE3, "raw_logs")
FINDINGS = File.join(PHASE3, "FINDINGS.md")
DISCOURSE = File.expand_path(ENV.fetch("DISCOURSE_DIR", File.join(PHASE3, "discourse")), ROOT)
JSON_OUT = ENV["JSON_OUT"]
ECONOMIC_RUNNER_SHA256 = {
  "refork_gate.rb" => "5133daf8893133e22d796a92b39e6bc42bc59b38f5c889e57454acd81675cc9c",
  "bench_kernel.rb" => "be9df2f9bb7db950f6ae71dab369590910a88d80b683207465fe28a2b788cb5e",
  "phase3_migration/economic_gate_matrix.rb" => "12104a403058a55b094bce584accb38ded6771deaf096395fd6c14505408737a",
}.freeze
A2_RUNNER_SHA256 = {
  "a2_cache_sync.rb" => "c900ab383cdec1e0e7c802403fe0d74680b9be1e70c7941f2e328abeae4ca6e0",
  "bench_kernel.rb" => "be9df2f9bb7db950f6ae71dab369590910a88d80b683207465fe28a2b788cb5e",
  "phase3_migration/a2_sync_matrix.rb" => "4bcfb2c139bef55e2f5cc24914175d8fbf323b803a31518e64a416992d37b578",
}.freeze
OUTBOX_STRESS_SHA256 = {
  "rails_capsule_slice_b/stress_run.rb" => "e112cdb7f07e509a678013112645351eeb4d35e9e6d663be24285255b8d219e3",
  "rails_capsule_slice_b/worker_stress.rb" => "e06753280832199aac3887eab939777cb1eb7930e12c86fd0177db9978bf7066",
  "rails_capsule_slice_b/capsule.rb" => "d6e7471c590a83c925c0b051bfcc9b1c0d3f2ddfd607187f697727933390e0f2",
  "rails_capsule_slice_b/domain.rb" => "360cb46b4ec94cdfc02f6b17ca42ad75ad54c390229fbb439e23860fda80bec6",
  "rails_capsule_slice_b/boot.rb" => "abebcef2b45222d462b84f37afbd4a7802979bf5bbb2b6aea769230a6a12e419",
  "rails_capsule_slice_b/schema.rb" => "ce1b80f3749c945b116a0d3a40bb35fc0bd9584195b0e2a31fcc0019359b8d96",
  "rails_capsule_mini_app/script/stress_dispatch.rb" => "5d5e439ba680575db94d4706a949c52b25be02b1f175e8fed88d14f9302dd5f7",
  "rails_capsule_mini_app/script/worker_stress_dispatch.rb" => "b223b1628374d8f327679168ddf68990b7d9300a0733789937f53e205a38d5b0",
  "rails_capsule_mini_app/app/services/capsule.rb" => "98b0c67d8b026c266d9242a47598cd30e5561800cd4e788b589f52e0558cd4fb",
  "rails_capsule_mini_app/app/models/outbox_event.rb" => "de57cd5351219f8e75de874d851695de374182e6a43d624c58881b91d7ce7768",
  "rails_capsule_mini_app/app/models/delivery_attempt.rb" => "eae0ff73d2cada441933b7acf05c39b5e1b74e4c829f1485a4f1d279dd982187",
  "rails_capsule_mini_app/app/models/external_charge.rb" => "c0e26fb2af3fb3bf9b66808c47e150891269829a2b7dc818cdb643d08f5c4dde",
  "rails_capsule_mini_app/db/migrate/20260613000005_create_delivery_attempts.rb" => "ff702b93f25e764fbcb5261d3a81d87ae7ae901fa9578f6eac9c3e17b3769c3a",
  "rails_capsule_mini_app/db/migrate/20260613000006_add_lease_to_outbox_events.rb" => "081bf696fd5a33a238565ccc9dd94115756877c6762d06d69dd0b22ddbdb6540",
}.freeze
TRANSACTION_SUITE_SHA256 = {
  "rails_capsule_slice_b/test/slice_b_test.rb" => "8fec4ec688cca3a6e6115cba6fda250eb365965af0fa5ba841340f5b34472ebf",
  "rails_capsule_slice_b/test/falsify_after_commit.rb" => "1af010ebfecb29c0b23104149478b74e163c4441c52c353bb690a08d00686b83",
  "rails_capsule_slice_b/test/falsify_crash_windows.rb" => "0667069a7612dc20f0755455014b3cdf196c42d4217d823886c2a634a585da85",
  "rails_capsule_slice_b/test/falsify_current_leakage.rb" => "690109491ec420a6fc14e013ec347905014ba21200c4850b156656c0a5f8df39",
  "rails_capsule_slice_b/test/falsify_failing_consumer.rb" => "7ae9c33606cbc29598967078f2bbca895c3a6bfdc90c1d46b6fae26aa424159b",
  "rails_capsule_slice_b/test/falsify_nokogiri_ractor.rb" => "52c716eb7f49df83b348068dcb7fa495a49f062d3d8528306cd3bcb4efb43051",
  "rails_capsule_slice_b/test/falsify_request_id_contract.rb" => "933b12fb0a2a512bf0a5eb94f3f4edf83527a3353191dc9d2952bcc084e7fa9f",
  "rails_capsule_slice_b/test/falsify_skip_locked.rb" => "6fa5028eed35637a760bcfae640f30366482f4cb5dcccaa3cc8d4d188d396ca5",
  "rails_capsule_slice_b/adversarial_service.rb" => "a57d21a28bc3bfb4443bcccda637e5ad61dcc19697d7fbe89848d3ead4ffe5a1",
  "rails_capsule_slice_b/capsule.rb" => "d6e7471c590a83c925c0b051bfcc9b1c0d3f2ddfd607187f697727933390e0f2",
  "rails_capsule_slice_b/domain.rb" => "360cb46b4ec94cdfc02f6b17ca42ad75ad54c390229fbb439e23860fda80bec6",
  "rails_capsule_slice_b/schema.rb" => "ce1b80f3749c945b116a0d3a40bb35fc0bd9584195b0e2a31fcc0019359b8d96",
  "rails_capsule_slice_b/boot.rb" => "abebcef2b45222d462b84f37afbd4a7802979bf5bbb2b6aea769230a6a12e419",
  "rails_capsule_slice_b/worker_dispatch.rb" => "2a132c829fdb9b7a183532db980c541aa66a8abd8c65a3df0983b17b812acaa9",
  "rails_capsule_slice_b/worker_commit.rb" => "31888e13300ceca26be524b3f0be5db7237f9711fe3a1a9ee635e6332e2fbfa8",
  "rails_capsule_slice_b/worker_crash.rb" => "2cb69bea319fc6f632c9fe24328509c40882c322b0faad9f2ac4ada664f3db56",
  "rails_capsule_mini_app/test/capsule_rails_test.rb" => "a3fdaf2c0ffa73a0fa97b77736d4f1f6c2e7c9257a3f0bba59bf029d875c8951",
  "rails_capsule_mini_app/app/services/adversarial_service.rb" => "3a55efcfea588beb4f269cebb36f51f298920f51fd0196737338fe02f315c2c4",
  "rails_capsule_mini_app/app/services/capsule.rb" => "98b0c67d8b026c266d9242a47598cd30e5561800cd4e788b589f52e0558cd4fb",
  "rails_capsule_mini_app/app/models/current.rb" => "0f77c0e8a173f7d979782ff40a11704ca2f72806477b188d53843d0fa4a5c3be",
  "rails_capsule_mini_app/app/models/order.rb" => "65f4a06a02569b8be1e4233ba8ef056403fd01e324536e5649c79a2c442b8a05",
  "rails_capsule_mini_app/app/models/outbox_event.rb" => "de57cd5351219f8e75de874d851695de374182e6a43d624c58881b91d7ce7768",
  "rails_capsule_mini_app/app/models/external_charge.rb" => "c0e26fb2af3fb3bf9b66808c47e150891269829a2b7dc818cdb643d08f5c4dde",
  "rails_capsule_mini_app/app/models/delivery_attempt.rb" => "eae0ff73d2cada441933b7acf05c39b5e1b74e4c829f1485a4f1d279dd982187",
  "rails_capsule_mini_app/app/models/user.rb" => "9bcd67fc035c18b3b9e1460b613ac400ea0fd639bc1ab2f9c6f0805c9327255d",
  "rails_capsule_mini_app/script/worker_dispatch.rb" => "085925a20a871f2047a8b62cc99411bc419e00e056b7f711c5c12842ee9a2737",
  "rails_capsule_mini_app/script/worker_commit.rb" => "e0d10d00a19b2f6456a7d9036870fa437453ea943c730f388411909695d33e47",
  "rails_capsule_mini_app/script/worker_crash.rb" => "e3a8e05094fc6a6a6a8889df740fb5b2c2c2a69a060e3f67040ecf3116438c61",
  "rails_capsule_mini_app/db/migrate/20260613000001_create_users.rb" => "8761503fa3f0ee999728fc071b92e8da5a6e108dfa8e4bfd14f83774fe778027",
  "rails_capsule_mini_app/db/migrate/20260613000002_create_orders.rb" => "6502fe7ae3fc97b1226fe7efab88f92515411f083d32dd0c8e0294ead51bca71",
  "rails_capsule_mini_app/db/migrate/20260613000003_create_outbox_events.rb" => "8bf5e2899a88782de1c3589902327256a6dd5f463419edf45b7f466090288365",
  "rails_capsule_mini_app/db/migrate/20260613000004_create_external_charges.rb" => "9d6cd57245840ba6ccfc2130215dd369a8d7301edef5bca77953cb84cbb6e117",
  "rails_capsule_mini_app/db/migrate/20260613000005_create_delivery_attempts.rb" => "ff702b93f25e764fbcb5261d3a81d87ae7ae901fa9578f6eac9c3e17b3769c3a",
  "rails_capsule_mini_app/db/migrate/20260613000006_add_lease_to_outbox_events.rb" => "081bf696fd5a33a238565ccc9dd94115756877c6762d06d69dd0b22ddbdb6540",
}.freeze
CAPSULE_HOSTILITY_AUDIT_RUNNER_SHA256 = {
  "phase3_migration/audit.rb" => "dfd739feffe136663e1dbcd81a3fbd99e915896dc8f5428acea74c902c0c89f0",
}.freeze
DISCOURSE_CLASSIFICATION_RUNNER_SHA256 = {
  "phase3_migration/guardian_non_fit_proof.rb" => "dbf5683783720174ceb40171f38778a250574dd0c16b6f461d59c10fbceae459",
  "phase3_migration/report_partial_proof.rb" => "517a1072e4aa934260106b825fbb096c20bfd3925da11c0c5a18dfc9a0e7d3e8",
  "phase3_migration/promotion_capsule/drift_check.rb" => "53e129f8ae403b892eaa864f2537c9eecf8ce5e45c3a767b9a4da4db010a54bc",
  "phase3_migration/promotion_write_side_gap.rb" => "2248ad1225e9a09c0760f99cb0f1e27bf92fe5cb6fec2aac6279571eb0c7cf90",
}.freeze
ENVIRONMENT_PROOF_RUNNER_SHA256 = {
  "phase3_migration/environment_proof.rb" => "1e9c631fa56bddf966570a2d83fe3b611fce889ce65ff47fe1b343f2751565a1",
}.freeze
PROMOTION_AMORTIZATION_RUNNER_SHA256 = {
  "phase3_migration/promotion_capsule/promotion_amortization.rb" => "8a9d294361f3a6a6e0a5ec4171bbd928b11a58087d92a15d0c7fbac912186ad0",
  "phase3_migration/promotion_capsule/capsule_eligibility.rb" => "325ecdf26c2faefe027cf316d70372ece11e1d3ea374abbcb1e5674b75db7c10",
}.freeze
PROMOTION_WRITE_SIDE_SPEC_RUNNER_SHA256 = {
  "phase3_migration/promotion_write_side_spec.rb" => "673dd595af8f63b40bb25f0209808e7d449e9a78e1eab3113afd546a4ac3bf07",
}.freeze

STRONG_GATE_V2_RUNNER_SHA256 = {
  "strong_host_gate_v2.rb" => "e2efbe21be060d6fd491867074bf7ea9233746af5ab5590a12bb0e83121fc853",
}.freeze
# exact model roster the reduced run must contain (asserted, not just count) — must match DEFAULT_MODELS in the runner
STRONG_GATE_V2_REDUCED_MODELS = %w[
  process_naive process_gc_compact process_warmup process_gc_compact_plus_warmup
  process_prefork_warmed process_refork ractor_frozen_image
].freeze
STRONG_GATE_V2_REDUCED_DIR = "phase3_migration/strong_gate_v2_reduced_runs"
# a full-host artifact may NOT be blessed by the reduced guard; this path must stay absent until check_strong_host_gate_v2_full exists
STRONG_GATE_V2_FULL_ARTIFACT = "phase3_migration/raw_logs/strong_gate_v2_results.json"

def read_json(path)
  JSON.parse(File.read(File.join(ROOT, path)))
end

def assert!(condition, message)
  raise message unless condition
end

def statuses_by_alloc(matrix, shape)
  matrix.fetch("by_shape").fetch(shape).fetch("statuses").transform_keys(&:to_i)
end

def relative_file(path)
  File.join(ROOT, path)
end

def assert_nonempty_file!(path)
  expanded = relative_file(path)
  assert!(File.file?(expanded), "#{path} does not exist")
  assert!(File.size(expanded).positive?, "#{path} is empty")
end

def assert_pinned_file_hashes!(pins, context)
  pins.each do |path, expected|
    actual = Digest::SHA256.file(relative_file(path)).hexdigest
    assert!(
      actual == expected,
      "#{context} input #{path} changed: expected #{expected}, got #{actual}. Rerun the evidence or update the pin with justification."
    )
  end
end

def assert_linux_ruby_cell!(cell, path)
  ruby = cell.fetch("ruby")
  platform = cell.fetch("platform")
  assert!(ruby.include?("ruby 4.0.5"), "#{path} was not run on Ruby 4.0.5: #{ruby.inspect}")
  assert!(ruby.include?("[#{platform}]"), "#{path} ruby description does not include platform #{platform.inspect}")
  assert!(platform.end_with?("linux"), "#{path} was not run on Linux: #{platform.inspect}")
end

def economic_shape_verdicts(result)
  result.fetch("shapes").to_h do |shape|
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
    [shape.fetch("shape"), row]
  end
end

def legacy_positive_economic_probes
  %w[
    phase3_migration/economic_gate_large_probe.json
    phase3_migration/economic_gate_struct_probe.json
  ].flat_map do |path|
    read_json(path).fetch("shapes").filter_map do |shape|
      verdict = shape.fetch("verdict")
      next unless verdict.fetch("status") == "survives"

      {
        "path" => path,
        "shape" => shape.fetch("shape"),
        "absolute_saving_mb" => verdict.fetch("absolute_saving_mb"),
        "throughput_reach_percent" => verdict.fetch("throughput_reach_percent"),
      }
    end
  end
end

def economic_by_shape(runs)
  grouped = Hash.new { |hash, key| hash[key] = [] }
  runs.each do |run|
    run.fetch("shape_verdicts").each do |shape, verdict|
      grouped[shape] << verdict.merge("alloc" => run.fetch("alloc"))
    end
  end

  grouped.transform_values do |verdicts|
    survives = verdicts.select { |verdict| verdict.fetch("status") == "survives" }
    {
      "allocs" => verdicts.map { |verdict| verdict.fetch("alloc") },
      "statuses" => verdicts.to_h { |verdict| [verdict.fetch("alloc").to_s, verdict.fetch("status")] },
      "survives_allocs" => survives.map { |verdict| verdict.fetch("alloc") },
      "max_absolute_saving_mb" => verdicts.filter_map { |verdict| verdict["absolute_saving_mb"] }.max,
      "min_pss_ratio_percent" => verdicts.filter_map { |verdict| verdict["pss_ratio_percent"] }.min,
      "min_throughput_reach_percent" => verdicts.filter_map { |verdict| verdict["throughput_reach_percent"] }.min,
    }
  end
end

def economic_status_marker(status)
  {
    "invalid" => "→ INVALID:",
    "inconclusive" => "→ INCONCLUSIVE",
    "kill" => "→ THESIS DIES:",
    "economic_no_op" => "→ ECONOMIC NO-OP",
    "tradeoff_fail" => "→ TRADEOFF",
  }.fetch(status)
end

def economic_status_markers(status)
  return ["→ Ractor SURVIVES", "OVERALL PASS"] if status == "survives"

  [economic_status_marker(status)]
end

def economic_shape_log_section(log, shape, n_rules, path)
  pattern = /^=+ shape: #{Regexp.escape(shape)} \(N=#{n_rules}\) =+\n(.*?)(?=^=+ shape:|\nJSON written:|\z)/m
  match = log.match(pattern)
  assert!(match, "#{path} missing raw log section for #{shape} N=#{n_rules}")
  match[1]
end

def check_economic_raw_log_matches_json!(run, cell)
  log_path = run.fetch("raw_log")
  log = File.read(relative_file(log_path))
  config = cell.fetch("config")

  [
    "Ruby 4.0.5 (#{cell.fetch("platform")}) refork death-test",
    "ALLOC=#{config.fetch("alloc")}",
    "ITEMS=#{config.fetch("items")} SCAN=#{config.fetch("scan")}",
    "DURATION=#{config.fetch("duration_s")}s REPS=#{config.fetch("reps")}",
    "JSON written: #{run.fetch("json_file")}",
  ].each do |fragment|
    assert!(log.include?(fragment), "#{log_path} missing raw-log/config fragment #{fragment.inspect}")
  end

  cell.fetch("shapes").each do |shape|
    shape_name = shape.fetch("shape")
    verdict = shape.fetch("verdict")
    section = economic_shape_log_section(log, shape_name, shape.fetch("n_rules"), log_path)
    assert!(
      economic_status_markers(verdict.fetch("status")).any? { |marker| section.include?(marker) },
      "#{log_path} #{shape_name} verdict text drifted from JSON status #{verdict.fetch("status")}"
    )

    next unless verdict["ractor_best"]

    ractor_best = verdict.fetch("ractor_best")
    fragments = [
      "#{ractor_best.fetch("throughput_items_s").round} items/s @ pool #{ractor_best.fetch("pool")}, PSS #{format("%.1f", ractor_best.fetch("pss_mb"))}MB",
      "refork  @ iso-tput: PSS #{format("%.1f", verdict.fetch("refork_iso_pss_mb"))}MB",
      "Ractor PSS / refork PSS = #{format("%.1f", verdict.fetch("pss_ratio_percent"))}%",
      "absolute saving #{verdict.fetch("absolute_saving_mb")}MB",
      "throughput reach vs refork max = #{format("%.1f", verdict.fetch("throughput_reach_percent"))}%",
    ]
    if verdict["refork_interval_p50_s"] && verdict["refork_interval_p95_s"]
      fragments << format(
        "actual interval p50=%.3fs p95=%.3fs",
        verdict.fetch("refork_interval_p50_s"),
        verdict.fetch("refork_interval_p95_s")
      )
    end
    fragments.each do |fragment|
      assert!(section.include?(fragment), "#{log_path} #{shape_name} raw metric drifted from JSON: #{fragment.inspect}")
    end
  end
end

def check_legacy_refork_probe_logs
  legacy_runs = [
    {
      "json_file" => "phase3_migration/economic_gate_large_probe.json",
      "raw_log" => "phase3_migration/raw_logs/refork_gate_large_probe_latest.log",
    },
    {
      "json_file" => "phase3_migration/economic_gate_struct_probe.json",
      "raw_log" => "phase3_migration/raw_logs/refork_gate_struct_probe_latest.log",
    },
  ]

  checked = legacy_runs.map do |run|
    cell = read_json(run.fetch("json_file"))
    assert_linux_ruby_cell!(cell, run.fetch("json_file"))
    check_economic_raw_log_matches_json!(run, cell)
    survives = cell.fetch("shapes").select { |shape| shape.fetch("verdict").fetch("status") == "survives" }
    {
      "json_file" => run.fetch("json_file"),
      "raw_log" => run.fetch("raw_log"),
      "surviving_shapes" => survives.map { |shape| shape.fetch("shape") },
    }
  end

  smoke_path = "phase3_migration/raw_logs/refork_gate_smoke_latest.log"
  assert_nonempty_file!(smoke_path)
  smoke = File.read(relative_file(smoke_path))
  assert!(smoke.include?("N_RULES=20000"), "#{smoke_path} no longer looks like the reduced smoke run")
  assert!(
    smoke.include?("JSON written: phase3_migration/economic_gate_results.json"),
    "#{smoke_path} no longer records the old superseded JSON target; reinterpret FINDINGS"
  )

  {
    "checked_probe_logs" => checked,
    "superseded_smoke_log" => smoke_path,
  }
end

def struct_shape(result)
  shapes = result.fetch("shapes")
  assert!(shapes.size == 1, "struct rerun should contain exactly one shape")
  shape = shapes.first
  assert!(shape.fetch("shape") == "struct", "struct rerun shape changed: #{shape.fetch("shape").inspect}")
  shape
end

def assert_struct_rerun_config!(result, path, alloc)
  assert_linux_ruby_cell!(result, path)
  config = result.fetch("config")
  expected = {
    "pools" => [1, 2, 4],
    "shapes" => ["struct"],
    "n_rules" => 1_000_000,
    "n_rules_by_shape" => { "struct" => 5_000_000 },
    "items" => 2_000,
    "scan" => 1_500,
    "alloc" => alloc,
    "duration_s" => 8.0,
    "refork_every_s" => 1.0,
    "passes_per_gen" => 1,
    "reps" => 6,
  }
  assert!(config == expected, "#{path} config changed: expected #{expected.inspect}, got #{config.inspect}")
end

def struct_rerun_log_section(log, alloc)
  pattern = /^#### struct ALLOC=#{alloc}.*?\n(.*?)(?=^#### struct ALLOC=|\z)/m
  match = log.match(pattern)
  assert!(match, "struct_rerun.log missing ALLOC=#{alloc} section")
  match[1]
end

def assert_struct_rerun_log_matches_json!(log, result, alloc)
  section = struct_rerun_log_section(log, alloc)
  shape = struct_shape(result)
  verdict = shape.fetch("verdict")
  ractor_best = verdict.fetch("ractor_best")
  [
    "Ruby 4.0.5 (#{result.fetch("platform")}) refork death-test",
    "POOLS=[1, 2, 4] SHAPES=[:struct] N_by_shape={struct: 5000000}",
    "ITEMS=2000 SCAN=1500 ALLOC=#{alloc} DURATION=8.0s REPS=6",
    "JSON written: /app/struct_rerun_a#{alloc}.json",
    "ractor best:        #{ractor_best.fetch("throughput_items_s").round} items/s @ pool #{ractor_best.fetch("pool")}, PSS #{format("%.1f", ractor_best.fetch("pss_mb"))}MB",
    "refork  @ iso-tput: PSS #{format("%.1f", verdict.fetch("refork_iso_pss_mb"))}MB",
    "Ractor PSS / refork PSS = #{format("%.1f", verdict.fetch("pss_ratio_percent"))}%",
    "absolute saving #{verdict.fetch("absolute_saving_mb")}MB",
    "throughput reach vs refork max = #{format("%.1f", verdict.fetch("throughput_reach_percent"))}%",
  ].each do |fragment|
    assert!(section.include?(fragment), "struct_rerun.log ALLOC=#{alloc} drifted from JSON: #{fragment.inspect}")
  end
  assert!(
    economic_status_markers(verdict.fetch("status")).any? { |marker| section.include?(marker) },
    "struct_rerun.log ALLOC=#{alloc} verdict text drifted from JSON status #{verdict.fetch("status")}"
  )
end

def check_struct_rerun_artifacts
  a100 = read_json("struct_rerun_a100.json")
  a500 = read_json("struct_rerun_a500.json")
  prior = read_json("sweep_alloc500_hi.json")
  log_path = "struct_rerun.log"
  assert_nonempty_file!(log_path)
  log = File.read(relative_file(log_path))

  assert_struct_rerun_config!(a100, "struct_rerun_a100.json", 100)
  assert_struct_rerun_config!(a500, "struct_rerun_a500.json", 500)
  assert_struct_rerun_log_matches_json!(log, a100, 100)
  assert_struct_rerun_log_matches_json!(log, a500, 500)
  assert!(log.include?("EXIT=0"), "struct_rerun.log did not record EXIT=0")

  a100_verdict = struct_shape(a100).fetch("verdict")
  assert!(a100_verdict.fetch("status") == "tradeoff_fail", "struct rerun ALLOC=100 status changed")
  assert!(a100_verdict.fetch("absolute_saving_mb") < 100.0, "struct rerun ALLOC=100 now clears absolute memory floor")
  assert!(a100_verdict.fetch("pss_ratio_percent") > 80.0, "struct rerun ALLOC=100 now clears PSS ratio floor")

  a500_verdict = struct_shape(a500).fetch("verdict")
  assert!(a500_verdict.fetch("status") == "survives", "struct rerun ALLOC=500 no longer has the positive memory/throughput cell")
  assert!(a500_verdict.fetch("absolute_saving_mb") >= 500.0, "struct rerun ALLOC=500 lost large memory saving")
  assert!(a500_verdict.fetch("pss_ratio_percent") <= 55.0, "struct rerun ALLOC=500 lost strong PSS ratio")
  assert!(a500_verdict.fetch("throughput_reach_percent") >= 100.0, "struct rerun ALLOC=500 lost positive reach cell")

  prior_struct = prior.fetch("shapes").find { |shape| shape.fetch("shape") == "struct" } ||
    raise("sweep_alloc500_hi.json missing struct shape")
  prior_verdict = prior_struct.fetch("verdict")
  assert!(prior.fetch("config").fetch("n_rules_by_shape").fetch("struct") == 5_000_000, "prior struct run N changed")
  assert!(prior.fetch("config").fetch("alloc") == 500, "prior struct run ALLOC changed")
  assert!(prior.fetch("config").fetch("duration_s") == 8.0, "prior struct run duration changed")
  assert!(prior.fetch("config").fetch("reps") == 6, "prior struct run reps changed")
  assert!(prior_verdict.fetch("status") == "inconclusive", "prior struct run is no longer inconclusive")
  assert!(prior_verdict.fetch("absolute_saving_mb") >= 500.0, "prior struct run lost large memory saving")
  assert!(prior_verdict.fetch("throughput_reach_percent") < 75.0, "prior struct run no longer shows throughput miss")

  {
    status: "memory_favorable_throughput_unconfirmed",
    alloc100: {
      status: a100_verdict.fetch("status"),
      absolute_saving_mb: a100_verdict.fetch("absolute_saving_mb"),
      pss_ratio_percent: a100_verdict.fetch("pss_ratio_percent"),
      throughput_reach_percent: a100_verdict.fetch("throughput_reach_percent"),
    },
    alloc500_latest: {
      status: a500_verdict.fetch("status"),
      absolute_saving_mb: a500_verdict.fetch("absolute_saving_mb"),
      pss_ratio_percent: a500_verdict.fetch("pss_ratio_percent"),
      throughput_reach_percent: a500_verdict.fetch("throughput_reach_percent"),
    },
    alloc500_prior: {
      status: prior_verdict.fetch("status"),
      absolute_saving_mb: prior_verdict.fetch("absolute_saving_mb"),
      pss_ratio_percent: prior_verdict.fetch("pss_ratio_percent"),
      throughput_reach_percent: prior_verdict.fetch("throughput_reach_percent"),
    },
  }
end

def check_economic_matrix_consistency(path)
  matrix = read_json(path)
  first_config = nil
  first_gates = nil
  matrix.fetch("runs").each do |run|
    assert_nonempty_file!(run.fetch("json_file"))
    assert_nonempty_file!(run.fetch("raw_log"))
    cell = read_json(run.fetch("json_file"))
    assert_linux_ruby_cell!(cell, run.fetch("json_file"))
    config = cell.fetch("config")
    first_config ||= config
    first_gates ||= cell.fetch("gates")

    assert!(config.fetch("alloc") == run.fetch("alloc"), "#{run.fetch("json_file")} ALLOC differs from aggregate run")
    %w[pools shapes n_rules n_rules_by_shape items scan duration_s refork_every_s passes_per_gen reps].each do |key|
      assert!(
        config.fetch(key) == first_config.fetch(key),
        "#{run.fetch("json_file")} config #{key} differs from other matrix cells"
      )
    end
    assert!(cell.fetch("gates") == first_gates, "#{run.fetch("json_file")} economic gates differ from other cells")

    scope = matrix.fetch("scope")
    assert!(config.fetch("shapes") == scope.fetch("shapes"), "#{path} scope shapes differ from #{run.fetch("json_file")}")
    assert!(
      config.fetch("pools").join(",") == scope.fetch("pools"),
      "#{path} scope pools differ from #{run.fetch("json_file")}"
    )
    assert!(config.fetch("duration_s") == scope.fetch("duration_s"), "#{path} scope duration differs from #{run.fetch("json_file")}")
    assert!(config.fetch("reps") == scope.fetch("reps"), "#{path} scope reps differ from #{run.fetch("json_file")}")

    actual = economic_shape_verdicts(cell)
    assert!(
      run.fetch("shape_verdicts") == actual,
      "#{path} run ALLOC=#{run.fetch("alloc")} drifted from #{run.fetch("json_file")}"
    )
    check_economic_raw_log_matches_json!(run, cell)
  end

  rebuilt = economic_by_shape(matrix.fetch("runs"))
  assert!(matrix.fetch("by_shape") == rebuilt, "#{path} by_shape summary drifted from its runs")
  matrix
end

def a2_compact_result(result)
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

# EXACT replicas of a2_sync_matrix.rb's `aggregate` and `by_scan_alloc` so the verifier can rebuild the stored
# aggregate and assert no drift. Keep these byte-identical to the matrix runner's versions.
def a2_aggregate(runs, timeouts)
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

def a2_by_scan_alloc(runs)
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

def a2_log_model_rows(log, path)
  labels = ["ractor no-cache", "ractor SYNC cache (gw)", "process direct cache"]
  labels.to_h do |label|
    line = log.lines.find { |candidate| candidate.start_with?(label) }
    assert!(line, "#{path} missing A2 model row #{label.inspect}")
    match = line.match(
      /^#{Regexp.escape(label)}\s+([0-9]+)\s+([0-9]+)\.\.([0-9]+)\s+([0-9.]+)ms\s+([0-9.]+)ms\s+([0-9.]+)ms\s+(yes|NO)/
    )
    assert!(match, "#{path} unparsable A2 model row: #{line.inspect}")
    [
      label,
      {
        "tput" => Integer(match[1]),
        "tlo" => Integer(match[2]),
        "thi" => Integer(match[3]),
        "p50" => match[4],
        "p95" => match[5],
        "p99" => match[6],
        "correct" => match[7] == "yes",
      },
    ]
  end
end

def assert_a2_log_model_matches_json!(rows, label, model)
  row = rows.fetch(label)
  {
    "tput" => model.fetch("tput").round,
    "tlo" => model.fetch("tlo").round,
    "thi" => model.fetch("thi").round,
  }.each do |key, expected|
    assert!(row.fetch(key) == expected, "#{label} #{key} raw log drifted from JSON: #{row.fetch(key)} != #{expected}")
  end

  %w[p50 p95 p99].each do |key|
    expected = format("%.3f", model.fetch(key))
    assert!(row.fetch(key) == expected, "#{label} #{key} raw log drifted from JSON: #{row.fetch(key)} != #{expected}")
  end
  assert!(
    row.fetch("correct") == model.fetch("correct"),
    "#{label} correct raw log drifted from JSON: #{row.fetch("correct")} != #{model.fetch("correct")}"
  )
end

def check_a2_raw_log_matches_json!(run, cell)
  log_path = run.fetch("raw_log")
  log = File.read(relative_file(log_path))
  config = cell.fetch("config")
  sync = cell.fetch("models").fetch("ractor_sync_cache")
  derived = cell.fetch("derived")
  verdict = cell.fetch("verdict")

  [
    "Ruby 4.0.5 (#{cell.fetch("platform")}) A2.3 bounded-SYNC cache read",
    "N_RULES=#{config.fetch("n_rules")} ITEMS=#{config.fetch("items")} SCAN=#{config.fetch("scan")}",
    "DURATION=#{config.fetch("duration_s")}s ALLOC=#{config.fetch("alloc")} POOL=#{config.fetch("pool")}",
    "CAP_EVERY=#{config.fetch("cap_every")} CACHE_SZ=#{config.fetch("cache_size")} REPS=#{config.fetch("reps")}",
    "JSON written: #{run.fetch("json_file")}",
    "→ A2.3: #{verdict.fetch("status").upcase}",
  ].each do |fragment|
    assert!(log.include?(fragment), "#{log_path} missing A2 raw-log fragment #{fragment.inspect}")
  end

  rows = a2_log_model_rows(log, log_path)
  assert_a2_log_model_matches_json!(rows, "ractor no-cache", cell.fetch("models").fetch("ractor_no_cache"))
  assert_a2_log_model_matches_json!(rows, "ractor SYNC cache (gw)", sync)
  assert_a2_log_model_matches_json!(rows, "process direct cache", cell.fetch("models").fetch("process_direct_cache"))

  [
    format("sync-gateway tax (ractor cache vs no-cache): %+.1f%%", derived.fetch("sync_gateway_tax_percent")),
    format("[%.1f..%.1f]", derived.fetch("sync_gateway_tax_min_percent"), derived.fetch("sync_gateway_tax_max_percent")),
    format("ractor(sync cache) throughput vs process:    %.1f%%", derived.fetch("throughput_vs_process_percent")),
    format("[%.1f..%.1f]", derived.fetch("throughput_vs_process_min_percent"), derived.fetch("throughput_vs_process_max_percent")),
    format(
      "round-trip latency: p50 %.3fms / p95 %.3fms / p99 %.3fms ; timeouts %d ; stale replies dropped %d",
      sync.fetch("p50"),
      sync.fetch("p95"),
      sync.fetch("p99"),
      sync.fetch("timeouts"),
      sync.fetch("stale")
    ),
  ].each do |fragment|
    assert!(log.include?(fragment), "#{log_path} A2 verdict metric drifted from JSON: #{fragment.inspect}")
  end
end

def check_a2_matrix_consistency(path)
  matrix = read_json(path)
  scope = matrix.fetch("scope")
  first_config = nil
  matrix.fetch("runs").each do |run|
    assert_nonempty_file!(run.fetch("json_file"))
    assert_nonempty_file!(run.fetch("raw_log"))
    cell = read_json(run.fetch("json_file"))
    assert_linux_ruby_cell!(cell, run.fetch("json_file"))
    config = cell.fetch("config")
    first_config ||= config

    # 3D axes vary per cell: each must match its aggregate run record and lie within the declared scope arrays
    %w[scan alloc cap_every timeout_s].each do |key|
      assert!(config.fetch(key) == run.fetch(key), "#{run.fetch("json_file")} #{key} differs from aggregate run record")
    end
    assert!(scope.fetch("scans").include?(config.fetch("scan")), "#{run.fetch("json_file")} scan not in scope.scans")
    assert!(scope.fetch("allocs").include?(config.fetch("alloc")), "#{run.fetch("json_file")} alloc not in scope.allocs")
    assert!(scope.fetch("cap_everys").include?(config.fetch("cap_every")), "#{run.fetch("json_file")} cap_every not in scope.cap_everys")
    assert!(scope.fetch("timeouts_s").include?(config.fetch("timeout_s")), "#{run.fetch("json_file")} timeout_s not in scope.timeouts_s")

    # constants must be identical across every cell AND match the scope
    %w[n_rules items duration_s reps pool cache_size].each do |key|
      assert!(config.fetch(key) == first_config.fetch(key), "#{run.fetch("json_file")} config #{key} differs from other A2 matrix cells")
      assert!(config.fetch(key) == scope.fetch(key), "#{path} scope #{key} differs from #{run.fetch("json_file")}")
    end

    actual = a2_compact_result(cell)
    assert!(run.fetch("result") == actual, "#{path} cell #{run.fetch("json_file")} result drifted from its JSON")
    check_a2_raw_log_matches_json!(run, cell)
  end

  rebuilt_aggregate = a2_aggregate(matrix.fetch("runs"), scope.fetch("timeouts_s"))
  assert!(matrix.fetch("aggregate") == rebuilt_aggregate, "#{path} aggregate summary drifted from its runs")
  rebuilt_by = a2_by_scan_alloc(matrix.fetch("runs"))
  assert!(matrix.fetch("by_scan_alloc") == rebuilt_by, "#{path} by_scan_alloc summary drifted from its runs")
  matrix
end

def discourse_git(*args)
  out, err, status = Dir.chdir(DISCOURSE) { Open3.capture3("git", *args) }
  raise "git #{args.join(" ")} failed: #{err}" unless status.success?

  out
end

def discourse_head
  discourse_git("rev-parse", "HEAD").strip
end

def discourse_file_sha256(relative_path)
  Digest::SHA256.file(File.join(DISCOURSE, relative_path)).hexdigest
end

def discourse_head_blob_sha256(relative_path)
  src = discourse_git("show", "HEAD:#{relative_path}")
  raise "could not read HEAD:#{relative_path}" if src.empty?

  Digest::SHA256.hexdigest(src)
end

def check_economic_gate(checks)
  assert_pinned_file_hashes!(ECONOMIC_RUNNER_SHA256, "economic gate")

  canonical = File.join(PHASE3, "economic_gate_results.json")
  matrix = File.join(PHASE3, "economic_gate_matrix_results.json")
  assert!(
    Digest::SHA256.file(canonical).hexdigest == Digest::SHA256.file(matrix).hexdigest,
    "economic_gate_results.json drifted from economic_gate_matrix_results.json"
  )

  economic = check_economic_matrix_consistency("phase3_migration/economic_gate_results.json")
  expected = {
    "hash" => { 0 => "kill", 100 => "economic_no_op", 500 => "tradeoff_fail" },
    "struct" => { 0 => "kill", 100 => "economic_no_op", 500 => "tradeoff_fail" },
    "blob" => { 0 => "tradeoff_fail", 100 => "tradeoff_fail", 500 => "tradeoff_fail" },
  }
  expected.each do |shape, statuses|
    actual = statuses_by_alloc(economic, shape)
    assert!(actual == statuses, "economic #{shape} statuses changed: expected #{statuses.inspect}, got #{actual.inspect}")
    row = economic.fetch("by_shape").fetch(shape)
    assert!(row.fetch("survives_allocs").empty?, "economic #{shape} unexpectedly has surviving allocs")
  end

  struct = check_economic_matrix_consistency("phase3_migration/economic_gate_struct_matrix_results.json")
  struct_statuses = statuses_by_alloc(struct, "struct")
  expected_struct = { 0 => "kill", 100 => "tradeoff_fail", 500 => "inconclusive" }
  assert!(
    struct_statuses == expected_struct,
    "struct stability statuses changed: expected #{expected_struct.inspect}, got #{struct_statuses.inspect}"
  )
  struct_summary = struct.fetch("by_shape").fetch("struct")
  assert!(struct_summary.fetch("survives_allocs").empty?, "struct stability matrix unexpectedly has surviving allocs")
  assert!(
    struct_summary.fetch("max_absolute_saving_mb") < 100.0,
    "struct stability matrix now clears the 100MB saving gate; FINDINGS must be reinterpreted"
  )

  legacy_positive_probes = legacy_positive_economic_probes
  assert!(
    legacy_positive_probes.any?,
    "legacy positive economic probes disappeared; FINDINGS must be reinterpreted rather than silently passing"
  )
  assert!(
    legacy_positive_probes.all? { |probe| probe.fetch("shape") == "struct" },
    "legacy positive probes changed shape mix: #{legacy_positive_probes.inspect}"
  )
  legacy_refork_probe_logs = check_legacy_refork_probe_logs
  struct_rerun = check_struct_rerun_artifacts

  checks << {
    name: "economic_gate",
    status: "pass",
    all_shape_statuses: expected,
    struct_stability_statuses: expected_struct,
    legacy_positive_probes_superseded: true,
    legacy_positive_probes: legacy_positive_probes,
    legacy_refork_probe_logs: legacy_refork_probe_logs,
    struct_rerun: struct_rerun,
    matrix_runs_checked: economic.fetch("runs").size,
    struct_runs_checked: struct.fetch("runs").size,
    config_consistency_checked: true,
    raw_log_json_consistency_checked: true,
    runner_hashes_guarded: ECONOMIC_RUNNER_SHA256,
    linux_ruby_cells_checked: economic.fetch("runs").size + struct.fetch("runs").size,
  }
end

def check_lease_ratification_docs(checks)
  decisions = File.read(File.join(ROOT, "docs/decisions.md"))
  readme = File.read(File.join(ROOT, "README.md"))
  required_decisions = [
    "SUPERSEDED 2026-06-14",
    "LEASE — P1 directive conflict, RATIFIED by user decision",
    "the CANONICAL `OutboxDispatcher.claim` in both `rails_capsule_mini_app` and",
    "deliver! and mark_published remain **separate commits**",
    "Frozen claim UNCHANGED and honored",
    "slice_b **13 runs / 62 assertions / 0 failures**",
    "mini_app **20 runs / 109 assertions / 0 failures**",
    "struct @ ALLOC=500 → **memory win robust, throughput reach UNSTABLE.**",
    "`hash` remains the only clean, reproducible economic win",
  ]
  missing_decisions = required_decisions.reject { |fragment| decisions.include?(fragment) }
  assert!(missing_decisions.empty?, "docs/decisions.md missing ratification fragments: #{missing_decisions.inspect}")

  required_readme = [
    "**Dispatcher LEASE (ratified 2026-06-14):**",
    "deliver and publish-mark stay **separate",
    "Verified green: slice_b 13/62, mini_app 20/109",
    "**`struct` @ ALLOC=500 → memory win ROBUST",
    "NOT a clean pass",
  ]
  missing_readme = required_readme.reject { |fragment| readme.include?(fragment) }
  assert!(missing_readme.empty?, "README.md missing ratification fragments: #{missing_readme.inspect}")

  checks << {
    name: "lease_ratification_docs",
    status: "pass",
    decisions_fragments_checked: required_decisions.size,
    readme_fragments_checked: required_readme.size,
  }
end

def command_by_name(environment, name)
  environment.fetch("commands").find { |command| command.fetch("name") == name } ||
    raise("environment proof missing command #{name}")
end

def command_stdout(environment, name)
  command = command_by_name(environment, name)
  assert!(command.fetch("success"), "environment command #{name} failed: #{command.fetch("stderr")}")
  command.fetch("stdout")
end

def environment_log_summary(path, environment)
  assert_nonempty_file!(path)
  actual_lines = File.read(relative_file(path)).lines.map(&:chomp)
  expected_lines = [
    "ENVIRONMENT PROOF #{environment.fetch("status").upcase}",
    *environment.fetch("commands").map do |entry|
      "- #{entry.fetch("name")}: #{entry.fetch("success") ? "ok" : "FAIL"}"
    end,
  ]
  assert!(
    actual_lines == expected_lines,
    "#{path} drifted from environment_proof_latest.json"
  )

  {
    "status" => environment.fetch("status"),
    "command_count" => environment.fetch("commands").size,
  }
end

def check_environment_proof(checks)
  assert_pinned_file_hashes!(ENVIRONMENT_PROOF_RUNNER_SHA256, "environment proof")

  environment = read_json("phase3_migration/raw_logs/environment_proof_latest.json")
  log_summary = environment_log_summary("phase3_migration/raw_logs/environment_proof_latest.log", environment)
  assert!(environment.fetch("status") == "pass", "environment proof is not passing")
  assert!(environment.fetch("missing").empty?, "environment proof has missing commands")
  assert!(environment.fetch("failed").empty?, "environment proof has failed commands")
  environment.fetch("required").each do |name|
    command = command_by_name(environment, name)
    assert!(command.fetch("success"), "required environment command #{name} failed")
  end

  assert!(command_stdout(environment, "host_ruby_v").include?("ruby 4.0.5"), "host Ruby version changed")
  assert!(command_stdout(environment, "host_ruby_description").include?("ruby 4.0.5"), "host Ruby description changed")
  assert!(command_stdout(environment, "host_bundle_v").match?(/\A\d+\.\d+\.\d+/), "host Bundler version missing")
  assert!(command_stdout(environment, "discourse_head").strip == discourse_head, "environment Discourse HEAD drifted")
  assert!(
    command_stdout(environment, "discourse_status_short") == " M lib/promotion.rb\n?? run_migrate.rb\n",
    "environment Discourse status changed; inspect dirty tree before trusting evidence"
  )

  assert!(command_stdout(environment, "container_psql_version").include?("PostgreSQL) 16.14"), "container psql version changed")
  dbs = command_stdout(environment, "container_pg_databases").lines.map(&:strip)
  assert!(dbs.include?("capsule_test"), "environment proof missing capsule_test database")
  assert!(dbs.include?("capsule_railsapp_test"), "environment proof missing capsule_railsapp_test database")
  assert!(
    command_stdout(environment, "container_pg_server_version").include?("capsule_test|16.14"),
    "environment proof server version changed"
  )

  mini = command_stdout(environment, "mini_rails_boot_probe")
  assert!(command_stdout(environment, "mini_rails_rails_v").include?("Rails 8.1.3"), "mini Rails version changed")
  assert!(mini.include?("rails=8.1.3"), "mini Rails boot probe Rails version changed")
  assert!(mini.include?("active_record=8.1.3"), "mini Rails ActiveRecord version changed")
  assert!(mini.include?("eager_load=true"), "mini Rails proof no longer runs eager_load=true")
  assert!(mini.include?("cache_class=ActiveSupport::Cache::MemoryStore"), "mini Rails cache class changed")
  assert!(mini.include?("database=capsule_railsapp_test"), "mini Rails database changed")
  assert!(mini.include?("PostgreSQL 16.14"), "mini Rails DB server version changed")

  slice = command_stdout(environment, "slice_b_ar_postgres_probe")
  assert!(slice.include?("active_record=8.1.3"), "Slice B ActiveRecord version changed")
  assert!(slice.include?("database=capsule_test"), "Slice B database changed")
  assert!(slice.include?("PostgreSQL 16.14"), "Slice B DB server version changed")

  checks << {
    name: "environment_proof",
    status: "pass",
    host_ruby: command_stdout(environment, "host_ruby_v").strip,
    mini_rails_db: "capsule_railsapp_test",
    slice_b_db: "capsule_test",
    postgres: "16.14",
    command_count: log_summary.fetch("command_count"),
    raw_log_json_consistency_checked: true,
    runner_hashes_guarded: ENVIRONMENT_PROOF_RUNNER_SHA256,
  }
end

def check_capsule_hostility_audit(checks)
  assert_pinned_file_hashes!(CAPSULE_HOSTILITY_AUDIT_RUNNER_SHA256, "capsule hostility audit")

  audit = read_json("phase3_migration/audit_output.json")
  assert!(audit.fetch("generated_against_commit") == discourse_head, "audit_output.json is stale vs Discourse HEAD")
  assert!(audit.fetch("source_ref") == "HEAD", "audit_output.json must be generated from HEAD")
  assert!(
    audit.fetch("source_mode") == "git_show+git_ls_tree",
    "audit_output.json must read file lists and blobs from git, got #{audit.fetch("source_mode").inspect}"
  )

  services = audit.fetch("services")
  assert!(services.size >= 6, "audit_output.json must include the 3 fixed services plus at least 3 candidates")

  expected = {
    "guardian" => {
      "loc" => 2267,
      "call_site_files" => 179,
      "call_site_occurrences" => 668,
      "candidate" => "non_fit",
      "site_setting_reads" => 138,
      "ar_queries" => 47,
      "db_queries" => 0,
      "held_user_refs" => 113,
      "held_ar_state_refs" => 113,
      "can_is_predicates" => 224,
      "side_effect_count" => 0,
    },
    "report" => {
      "loc" => 611,
      "call_site_files" => 16,
      "call_site_occurrences" => 33,
      "candidate" => "partial",
      "rails_cache_reads" => 4,
      "redis_reads" => 1,
      "ar_queries" => 14,
      "db_queries" => 2,
      "side_effect_count" => 0,
    },
    "promotion" => {
      "loc" => 176,
      "call_site_files" => 7,
      "call_site_occurrences" => 8,
      "candidate" => "partial",
      "site_setting_reads" => 12,
      "ar_queries" => 2,
      "db_queries" => 0,
      "held_user_refs" => 29,
      "side_effect_count" => 7,
    },
  }

  expected.each do |service_name, expected_metrics|
    service = services.fetch(service_name)
    source_hashes = service.fetch("source_sha256_by_file")
    assert!(source_hashes.any?, "#{service_name} audit has no source hashes")
    source_hashes.each do |relative_path, sha256|
      assert!(
        sha256 == discourse_head_blob_sha256(relative_path),
        "#{service_name} audit hash drifted for HEAD:#{relative_path}"
      )
    end

    expected_metrics.each do |metric, expected_value|
      actual =
        if metric == "side_effect_count"
          service.fetch("side_effect_calls").size
        else
          service.fetch(metric)
        end
      assert!(
        actual == expected_value,
        "#{service_name} #{metric} changed: expected #{expected_value.inspect}, got #{actual.inspect}"
      )
    end
  end

  checks << {
    name: "capsule_hostility_audit",
    status: "pass",
    source_mode: audit.fetch("source_mode"),
    services_checked: expected.keys,
    runner_hashes_guarded: CAPSULE_HOSTILITY_AUDIT_RUNNER_SHA256,
  }
end

def check_a2_gateway(checks)
  assert_pinned_file_hashes!(A2_RUNNER_SHA256, "A2 sync gateway")

  matrix = check_a2_matrix_consistency("phase3_migration/a2_sync_matrix_results.json")
  runs = matrix.fetch("runs")
  scope = matrix.fetch("scope")
  agg = matrix.fetch("aggregate")
  expected_cells = scope.fetch("scans").size * scope.fetch("allocs").size *
                   scope.fetch("cap_everys").size * scope.fetch("timeouts_s").size
  assert!(runs.size == expected_cells, "A2 3D matrix should have #{expected_cells} cells, got #{runs.size}")

  # Negative control: every aggressive-timeout cell must actually fire a timeout AND be FAIL (the control bites).
  aggressive = scope.fetch("timeouts_s").min
  aggressive_cells = runs.select { |run| run.fetch("timeout_s") == aggressive }
  assert!(aggressive_cells.any?, "A2 matrix has no aggressive-timeout negative-control cells")
  assert!(
    aggressive_cells.all? { |run| run.dig("result", "timeouts").to_i.positive? && run.dig("result", "status") == "fail" },
    "A2 aggressive-timeout negative control did not fire+fail in every cell"
  )
  assert!(agg.fetch("aggressive_cells_all_fail"), "A2 aggregate aggressive_cells_all_fail must be true")

  # A pass is only meaningful under a NON-aggressive timeout (a microsecond timeout fails on missing data, not economics).
  passing = agg.fetch("passing_cells")
  assert!(passing.none? { |cell| cell.fetch("timeout_s") == aggressive }, "A2 passing cell under aggressive timeout is impossible (timeouts force fail)")

  chatty_cap = scope.fetch("cap_everys").min
  chatty_cells = runs.select { |run| run.fetch("cap_every") == chatty_cap }

  checks << {
    name: "a2_sync_gateway",
    status: "pass",
    cells: agg.fetch("cells"),
    failures: agg.fetch("fails"),
    passes: agg.fetch("passes"),
    inconclusive: agg.fetch("inconclusive"),
    any_cell_passes: agg.fetch("any_cell_passes"),
    aggressive_control_all_fail: agg.fetch("aggressive_cells_all_fail"),
    chatty_cap_every: chatty_cap,
    chatty_all_fail: chatty_cells.all? { |run| run.dig("result", "status") == "fail" },
    passing_cells: passing,
    aggregate_consistency_checked: true,
    raw_log_json_consistency_checked: true,
    config_consistency_checked: true,
    runner_hashes_guarded: A2_RUNNER_SHA256,
    linux_ruby_cells_checked: runs.size,
  }
end

def check_outbox_json(path, expected_ok:, expected_max:)
  json = read_json(path)
  assert!(json.fetch("all_ok") == expected_ok, "#{path} all_ok expected #{expected_ok}, got #{json.fetch("all_ok")}")
  actual_max = json.fetch("max_duplicate_attempt_percent")
  if expected_max == :positive
    assert!(actual_max.positive?, "#{path} expected positive duplicate attempts, got #{actual_max}")
  else
    assert!(actual_max == expected_max, "#{path} expected max duplicate #{expected_max}, got #{actual_max}")
  end
  json
end

def check_outbox_workload(
  path,
  expected_n:,
  expected_workers:,
  expected_batches:,
  expected_lease_seconds:,
  expected_max_allowed_duplicate_attempt_percent:,
  expected_run_ok:
)
  json = read_json(path)
  assert!(json.fetch("n") == expected_n, "#{path} n changed: expected #{expected_n}, got #{json.fetch("n")}")
  assert!(
    json.fetch("workers") == expected_workers,
    "#{path} workers changed: expected #{expected_workers}, got #{json.fetch("workers")}"
  )
  assert!(
    json.fetch("batches") == expected_batches,
    "#{path} batches changed: expected #{expected_batches.inspect}, got #{json.fetch("batches").inspect}"
  )
  if expected_lease_seconds == :absent
    assert!(!json.key?("lease_seconds"), "#{path} unexpectedly has lease_seconds")
  else
    assert!(
      json.fetch("lease_seconds") == expected_lease_seconds,
      "#{path} lease_seconds changed: expected #{expected_lease_seconds}, got #{json.fetch("lease_seconds")}"
    )
  end
  if expected_max_allowed_duplicate_attempt_percent == :absent
    assert!(
      !json.key?("max_allowed_duplicate_attempt_percent"),
      "#{path} unexpectedly has max_allowed_duplicate_attempt_percent"
    )
  else
    assert!(
      json.fetch("max_allowed_duplicate_attempt_percent") == expected_max_allowed_duplicate_attempt_percent,
      "#{path} duplicate-attempt budget changed: expected #{expected_max_allowed_duplicate_attempt_percent}, got #{json.fetch("max_allowed_duplicate_attempt_percent")}"
    )
  end

  runs_per_batch = json.fetch("runs_per_batch")
  runs = json.fetch("runs")
  expected_run_count = expected_batches.size * runs_per_batch
  assert!(runs.size == expected_run_count, "#{path} run count changed: expected #{expected_run_count}, got #{runs.size}")

  runs.each do |run|
    assert!(run.fetch("n") == expected_n, "#{path} run n changed")
    assert!(run.fetch("workers") == expected_workers, "#{path} run workers changed")
    assert!(expected_batches.include?(run.fetch("batch")), "#{path} unexpected batch #{run.fetch("batch")}")
    assert!(run.fetch("exit_codes") == Array.new(expected_workers, 0), "#{path} worker exit codes changed")
    assert!(run.fetch("unpublished").zero?, "#{path} left unpublished rows")
    assert!(run.fetch("charges") == expected_n, "#{path} charges changed")
    assert!(run.fetch("distinct_charges") == expected_n, "#{path} distinct charges changed")
    assert!(run.fetch("duplicate_effect_keys").zero?, "#{path} duplicate effect keys changed")
    assert!(run.fetch("ok") == expected_run_ok, "#{path} run ok changed")
    if expected_lease_seconds == :absent
      assert!(!run.key?("lease_seconds"), "#{path} run unexpectedly has lease_seconds")
    else
      assert!(run.fetch("lease_seconds") == expected_lease_seconds, "#{path} run lease_seconds changed")
    end
    if expected_max_allowed_duplicate_attempt_percent == :absent
      assert!(
        !run.key?("max_allowed_duplicate_attempt_percent"),
        "#{path} run unexpectedly has max_allowed_duplicate_attempt_percent"
      )
    else
      assert!(
        run.fetch("max_allowed_duplicate_attempt_percent") == expected_max_allowed_duplicate_attempt_percent,
        "#{path} run duplicate-attempt budget changed"
      )
    end
  end

  {
    path: path,
    n: expected_n,
    workers: expected_workers,
    batches: expected_batches,
    runs: runs.size,
    lease_seconds: expected_lease_seconds,
    max_allowed_duplicate_attempt_percent: expected_max_allowed_duplicate_attempt_percent,
  }
end

def check_outbox(checks)
  assert_pinned_file_hashes!(OUTBOX_STRESS_SHA256, "outbox stress")

  positive = %w[
    phase3_migration/raw_logs/mini_outbox_stress_leased_reduced.json
    phase3_migration/raw_logs/mini_outbox_stress_leased_10k.json
    phase3_migration/raw_logs/slice_b_outbox_stress_leased_reduced.json
    phase3_migration/raw_logs/slice_b_outbox_stress_leased_10k.json
  ]
  negative = %w[
    phase3_migration/raw_logs/mini_outbox_stress_zero_lease_negative.json
    phase3_migration/raw_logs/slice_b_outbox_stress_zero_lease_negative.json
  ]
  old_unsafe = %w[
    phase3_migration/raw_logs/mini_outbox_stress_reduced.json
    phase3_migration/raw_logs/mini_outbox_stress_10k.json
  ]

  positive.each { |path| check_outbox_json(path, expected_ok: true, expected_max: 0.0) }
  negative.each { |path| check_outbox_json(path, expected_ok: false, expected_max: :positive) }
  old_unsafe.each { |path| check_outbox_json(path, expected_ok: true, expected_max: :positive) }

  workload_checks = [
    check_outbox_workload(
      "phase3_migration/raw_logs/mini_outbox_stress_leased_reduced.json",
      expected_n: 200,
      expected_workers: 4,
      expected_batches: [1, 5],
      expected_lease_seconds: 30.0,
      expected_max_allowed_duplicate_attempt_percent: 0.0,
      expected_run_ok: true
    ),
    check_outbox_workload(
      "phase3_migration/raw_logs/mini_outbox_stress_leased_10k.json",
      expected_n: 10_000,
      expected_workers: 16,
      expected_batches: [1, 5, 10],
      expected_lease_seconds: 30.0,
      expected_max_allowed_duplicate_attempt_percent: 0.0,
      expected_run_ok: true
    ),
    check_outbox_workload(
      "phase3_migration/raw_logs/slice_b_outbox_stress_leased_reduced.json",
      expected_n: 200,
      expected_workers: 4,
      expected_batches: [1, 5],
      expected_lease_seconds: 30.0,
      expected_max_allowed_duplicate_attempt_percent: 0.0,
      expected_run_ok: true
    ),
    check_outbox_workload(
      "phase3_migration/raw_logs/slice_b_outbox_stress_leased_10k.json",
      expected_n: 10_000,
      expected_workers: 16,
      expected_batches: [1, 5, 10],
      expected_lease_seconds: 30.0,
      expected_max_allowed_duplicate_attempt_percent: 0.0,
      expected_run_ok: true
    ),
    check_outbox_workload(
      "phase3_migration/raw_logs/mini_outbox_stress_zero_lease_negative.json",
      expected_n: 100,
      expected_workers: 8,
      expected_batches: [5],
      expected_lease_seconds: 0.0,
      expected_max_allowed_duplicate_attempt_percent: 0.0,
      expected_run_ok: false
    ),
    check_outbox_workload(
      "phase3_migration/raw_logs/slice_b_outbox_stress_zero_lease_negative.json",
      expected_n: 100,
      expected_workers: 8,
      expected_batches: [5],
      expected_lease_seconds: 0.0,
      expected_max_allowed_duplicate_attempt_percent: 0.0,
      expected_run_ok: false
    ),
    check_outbox_workload(
      "phase3_migration/raw_logs/mini_outbox_stress_reduced.json",
      expected_n: 200,
      expected_workers: 4,
      expected_batches: [1, 5],
      expected_lease_seconds: :absent,
      expected_max_allowed_duplicate_attempt_percent: :absent,
      expected_run_ok: true
    ),
    check_outbox_workload(
      "phase3_migration/raw_logs/mini_outbox_stress_10k.json",
      expected_n: 10_000,
      expected_workers: 16,
      expected_batches: [1, 5, 10],
      expected_lease_seconds: :absent,
      expected_max_allowed_duplicate_attempt_percent: :absent,
      expected_run_ok: true
    ),
  ]

  checks << {
    name: "outbox_attempt_budget",
    status: "pass",
    leased_positive_files: positive,
    negative_control_files: negative,
    old_unsafe_files: old_unsafe,
    old_unsafe_scope: "mini_rails_only",
    slice_b_old_unsafe_preserved: false,
    workload_checks: workload_checks,
    runner_hashes_guarded: OUTBOX_STRESS_SHA256,
  }
end

def minitest_summary(path)
  assert_nonempty_file!(path)
  body = File.read(relative_file(path))
  summaries = body.scan(/(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/)
  assert!(summaries.any?, "#{path} has no Minitest summary")
  assert!(
    summaries.size == 1,
    "#{path} has #{summaries.size} Minitest summaries; refusing to trust a concatenated or stale log"
  )
  assert!(
    body.scan(/^Finished in \d+(?:\.\d+)?s,/).size == 1,
    "#{path} does not look like exactly one Minitest run"
  )
  match = summaries.last
  {
    "runs" => Integer(match[0]),
    "assertions" => Integer(match[1]),
    "failures" => Integer(match[2]),
    "errors" => Integer(match[3]),
    "skips" => Integer(match[4]),
    "summary_count" => summaries.size,
    "body" => body,
  }
end

def check_transaction_suite_logs(checks)
  assert_pinned_file_hashes!(TRANSACTION_SUITE_SHA256, "transaction suite logs")

  slice = minitest_summary("phase3_migration/raw_logs/slice_b_full_test_latest.log")
  mini = minitest_summary("phase3_migration/raw_logs/mini_rails_full_test_latest.log")

  assert!(
    slice.slice("runs", "assertions", "failures", "errors", "skips") ==
      { "runs" => 29, "assertions" => 143, "failures" => 0, "errors" => 0, "skips" => 0 },
    "Slice B full test summary changed"
  )
  assert!(
    slice.fetch("body").include?("OBSERVED_NON_MAIN_RACTOR_EXCEPTION=Ractor::UnsafeError"),
    "Slice B full test log no longer records the Nokogiri non-main Ractor unsafe failure"
  )

  assert!(
    mini.slice("runs", "assertions", "failures", "errors", "skips") ==
      { "runs" => 20, "assertions" => 109, "failures" => 0, "errors" => 0, "skips" => 0 },
    "Mini Rails full test summary changed"
  )

  checks << {
    name: "transaction_suite_logs",
    status: "pass",
    slice_b: slice.slice("runs", "assertions", "failures", "errors", "skips"),
    mini_rails: mini.slice("runs", "assertions", "failures", "errors", "skips"),
    summary_counts: {
      slice_b: slice.fetch("summary_count"),
      mini_rails: mini.fetch("summary_count"),
    },
    runner_hashes_guarded: TRANSACTION_SUITE_SHA256,
  }
end

def promotion_benchmark_log_values(log)
  values = {}
  {
    "inline_full_before_decisions_s" => /inline full \(BEFORE, per call\)\s*:\s*([0-9]+) decisions\/s/,
    "owner_snapshot_build_plus_decide_decisions_s" => /owner snapshot build \+ decide \(AFTER\)\s*:\s*([0-9]+) decisions\/s/,
    "decide_only_snapshot_reused_decisions_s" => /decide only, snapshot reused\s*:\s*([0-9]+) decisions\/s/,
    "decide_only_x4_ractors_decisions_s" => /decide only x4 Ractors\s*:\s*([0-9]+) decisions\/s/,
  }.each do |key, pattern|
    match = log.match(pattern)
    assert!(match, "Promotion bench log missing throughput line for #{key}")
    values[key] = Integer(match[1])
  end

  owner_ratio = log.match(/owner snapshot build \+ decide \(AFTER\).*?\(([0-9]+(?:\.[0-9]+)?)x vs before/)
  x4_ratio = log.match(/decide only x4 Ractors.*?\(([0-9]+(?:\.[0-9]+)?)x vs 1/)
  payload = log.match(/snapshot payload:\s*([0-9]+) fields,\s*([0-9]+) bytes/)
  assert!(owner_ratio, "Promotion bench log missing owner ratio")
  assert!(x4_ratio, "Promotion bench log missing x4 ratio")
  assert!(payload, "Promotion bench log missing payload")

  values.merge(
    "owner_snapshot_build_plus_decide_vs_inline_display" => Float(owner_ratio[1]),
    "decide_x4_ractors_vs_decide_only_display" => Float(x4_ratio[1]),
    "payload_fields" => Integer(payload[1]),
    "payload_bytes" => Integer(payload[2]),
  )
end

def check_promotion_benchmark(checks)
  capsule_sha = Digest::SHA256.file(File.join(PHASE3, "promotion_capsule/capsule_eligibility.rb")).hexdigest
  bench_sha = Digest::SHA256.file(File.join(PHASE3, "promotion_capsule/bench.rb")).hexdigest
  bench = read_json("phase3_migration/raw_logs/promotion_bench_latest.json")
  log_path = "phase3_migration/raw_logs/promotion_bench_latest.log"
  assert_nonempty_file!(log_path)
  log = File.read(relative_file(log_path))

  assert!(bench.fetch("status") == "pass", "Promotion bench JSON is not passing")
  assert!(bench.fetch("ruby").include?("ruby 4.0.5"), "Promotion bench Ruby runtime changed: #{bench.fetch("ruby")}")
  assert!(bench.fetch("bench_sha256") == bench_sha, "Promotion bench JSON is stale vs bench.rb")
  assert!(bench.fetch("capsule_sha256") == capsule_sha, "Promotion bench JSON is stale vs capsule_eligibility.rb")
  assert!(bench.fetch("correct") == true, "Promotion bench sanity check failed")
  assert!(bench.fetch("config") == { "n" => 1_000_000, "per_ractor" => 2_000_000, "ractors" => 4 }, "Promotion bench config changed")
  assert!(bench.fetch("payload") == { "fields" => 21, "bytes" => 531 }, "Promotion bench payload changed")

  throughput = bench.fetch("throughput")
  %w[
    inline_full_before_decisions_s
    owner_snapshot_build_plus_decide_decisions_s
    decide_only_snapshot_reused_decisions_s
    decide_only_x4_ractors_decisions_s
  ].each do |key|
    assert!(throughput.fetch(key).positive?, "Promotion bench throughput #{key} is not positive")
  end

  ratios = bench.fetch("ratios")
  assert!(
    ratios.fetch("owner_snapshot_build_plus_decide_vs_inline") < 1.0,
    "Promotion bench no longer shows owner snapshot+decide below inline; reinterpret FINDINGS"
  )
  assert!(
    ratios.fetch("decide_x4_ractors_vs_decide_only") > 1.0,
    "Promotion bench no longer shows pure decide parallelism; reinterpret FINDINGS"
  )
  assert!(
    bench.fetch("interpretation").fetch("compatibility_only_not_end_to_end_win") == true,
    "Promotion bench lost compatibility-only interpretation"
  )
  assert!(
    log.include?("Not an end-to-end win by itself."),
    "Promotion bench log no longer states the end-to-end caveat"
  )
  log_values = promotion_benchmark_log_values(log)
  throughput.each do |key, value|
    assert!(
      value.round == log_values.fetch(key),
      "Promotion bench log #{key}=#{log_values.fetch(key)} drifted from JSON #{value}"
    )
  end
  assert!(
    log_values.fetch("payload_fields") == bench.fetch("payload").fetch("fields") &&
      log_values.fetch("payload_bytes") == bench.fetch("payload").fetch("bytes"),
    "Promotion bench log payload drifted from JSON"
  )
  {
    "owner_snapshot_build_plus_decide_vs_inline_display" => "owner_snapshot_build_plus_decide_vs_inline",
    "decide_x4_ractors_vs_decide_only_display" => "decide_x4_ractors_vs_decide_only",
  }.each do |log_key, json_key|
    expected = ratios.fetch(json_key).round(2)
    actual = log_values.fetch(log_key)
    assert!(
      (actual - expected).abs < 0.001,
      "Promotion bench log #{log_key}=#{actual} drifted from JSON #{json_key}=#{ratios.fetch(json_key)}"
    )
  end

  checks << {
    name: "promotion_benchmark",
    status: "pass",
    ruby: bench.fetch("ruby"),
    bench_sha256: bench.fetch("bench_sha256"),
    payload: bench.fetch("payload"),
    throughput: throughput,
    log_matches_json: true,
    ratios: ratios,
  }
end

def format_decisions_m(value)
  format("%.2fM", value / 1_000_000.0)
end

def format_decisions_k(value)
  format("%.0fK", value / 1_000.0)
end

def format_ratio(value)
  format("%.2f", value)
end

def check_promotion_patch_artifact
  patch_path = File.join(PHASE3, "promotion_capsule/promotion.patch")
  assert!(File.file?(patch_path), "promotion_capsule/promotion.patch is missing")
  patch = File.read(patch_path)
  diff = discourse_git("diff", "--", "lib/promotion.rb")
  assert!(patch == diff, "promotion.patch drifted from the current Discourse lib/promotion.rb diff")

  changed_files = discourse_git("diff", "--name-only").lines.map(&:strip).reject(&:empty?)
  assert!(changed_files == ["lib/promotion.rb"], "Discourse tracked diff is not limited to lib/promotion.rb: #{changed_files.inspect}")

  numstat = discourse_git("diff", "--numstat", "--", "lib/promotion.rb").strip.split(/\s+/, 3)
  additions, deletions, path = numstat
  assert!(path == "lib/promotion.rb", "Promotion patch numstat path changed: #{path.inspect}")
  assert!(additions == "71" && deletions == "17", "Promotion patch stats changed: +#{additions}/-#{deletions}")

  {
    sha256: Digest::SHA256.hexdigest(patch),
    changed_files: changed_files,
    additions: Integer(additions),
    deletions: Integer(deletions),
  }
end

def check_promotion_drift_log_consistency(drift, path, head)
  assert_nonempty_file!(path)
  lines = File.read(relative_file(path)).lines.map(&:chomp)
  semantic_lines = drift.fetch("semantic_matches").map do |row|
    "tl#{row.fetch("level")}_met?  (#{row.fetch("real_guard_count")} guards, real) vs " \
      "(#{row.fetch("capsule_guard_count")} guards, capsule) => SEMANTIC MATCH"
  end
  negative_lines = drift.fetch("negative_controls").map do |row|
    "negative: #{row.fetch("name")} => RED as expected"
  end
  expected_size = semantic_lines.size + negative_lines.size + 3

  assert!(lines.size == expected_size, "#{path} has unexpected line count: #{lines.size}, expected #{expected_size}")
  assert!(lines[0, semantic_lines.size] == semantic_lines, "#{path} semantic lines drifted from JSON")
  negative_start = semantic_lines.size
  assert!(lines[negative_start, negative_lines.size] == negative_lines, "#{path} negative-control lines drifted from JSON")
  assert!(lines.fetch(negative_start + negative_lines.size) == "", "#{path} missing separator line before conclusion")

  conclusion = lines.fetch(expected_size - 2)
  caveat = lines.fetch(expected_size - 1)
  short_head = head[0, 8]
  assert!(conclusion.include?("DRIFT CHECK OK"), "#{path} conclusion no longer reports OK")
  assert!(conclusion.include?("lib/promotion.rb@#{short_head}."), "#{path} conclusion is stale vs Discourse HEAD")
  assert!(caveat.include?("Mutation controls are red."), "#{path} lost mutation-control caveat")
  assert!(caveat.include?("Static check only;"), "#{path} lost static-only caveat")

  {
    semantic_lines: semantic_lines.size,
    negative_control_lines: negative_lines.size,
    conclusion_guarded: true,
  }
end

def check_guardian_non_fit_scope!(guardian)
  assert!(guardian.fetch("file") == "lib/guardian/post_guardian.rb", "Guardian proof file changed")
  assert!(guardian.fetch("line_range") == [153, 203], "Guardian proof line range changed")
  assert!(
    guardian.fetch("evidence_scope") ==
      "static real-source dependency extraction plus faithful owner-edit stale-snapshot slice; not a Rails boot test",
    "Guardian evidence scope changed"
  )
  assert!(
    guardian.fetch("conclusion") == "Guardian is structural non-fit for Frozen Read-Model Capsules.",
    "Guardian non-fit conclusion changed"
  )
  assert!(
    guardian.fetch("reason").include?("owner round-trips per decision"),
    "Guardian reason lost owner round-trip conclusion"
  )

  category_counts = guardian.fetch("live_reads_observed").group_by { |row| row.fetch("category") }.transform_values(&:size)
  expected_categories = {
    "discourse_global" => 1,
    "post_state" => 16,
    "topic_or_category_state" => 11,
    "recursive_guardian_predicate" => 10,
    "site_setting" => 2,
    "user_state" => 3,
    "clock_dependent" => 1,
  }
  assert!(
    category_counts == expected_categories,
    "Guardian live-read category counts changed: expected #{expected_categories.inspect}, got #{category_counts.inspect}"
  )

  code = guardian.fetch("live_reads_observed").map { |row| row.fetch("code") }.join("\n")
  [
    "Discourse.static_doc_topic_ids",
    "post.locked?",
    "post.deleted_at",
    "SiteSetting.edit_wiki_post_allowed_groups_map",
    "can_create_post?(post.topic)",
    "post.edit_time_limit_expired?(@user)",
  ].each do |fragment|
    assert!(code.include?(fragment), "Guardian proof lost critical live-read fragment #{fragment.inspect}")
  end

  expected_mutations = [
    { "mutation" => "post.locked = true", "live" => false, "snapshot" => true, "stale" => true },
    { "mutation" => "clock advances past edit_time_limit", "live" => false, "snapshot" => true, "stale" => true },
    { "mutation" => "post.deleted_at set", "live" => false, "snapshot" => true, "stale" => true },
  ]
  actual_mutations = guardian.dig("stale_snapshot_slice", "mutations").map do |row|
    row.slice("mutation", "live", "snapshot", "stale")
  end
  assert!(actual_mutations == expected_mutations, "Guardian stale mutation cases changed")

  {
    category_counts: category_counts,
    stale_mutations_guarded: expected_mutations.map { |row| row.fetch("mutation") },
  }
end

def check_report_partial_scope!(report)
  assert!(report.fetch("file") == "app/models/report.rb", "Report proof file changed")
  assert!(
    report.fetch("verdict") == "Report is PARTIAL, not fit, for Frozen Read-Model Capsules",
    "Report proof verdict changed"
  )
  assert!(
    report.fetch("sync_gateway_frequency") ==
      "one synchronous cache read per Report.find_cached call; Report.find then executes live SQL/report method on miss",
    "Report sync-gateway frequency changed"
  )
  assert!(
    report.fetch("batchable_vs_chatty").include?("Per-item cache/SQL inside a Ractor would be chatty"),
    "Report proof lost chatty cache/SQL economic warning"
  )

  expected_counts = {
    "cache_or_redis_globals" => 3,
    "db_or_ar_live_queries" => 19,
    "i18n_reads" => 7,
    "logger_reads" => 2,
    "site_setting_reads" => 4,
    "dynamic_report_registration" => 6,
  }
  actual_counts = report.fetch("evidence").transform_values(&:size)
  assert!(
    actual_counts == expected_counts,
    "Report evidence counts changed: expected #{expected_counts.inspect}, got #{actual_counts.inspect}"
  )

  expected_path_metrics = {
    "find_cached_sync_cache_reads" => 1,
    "find_live_dispatch_points" => 2,
    "req_report_query_ops" => 8,
  }
  assert!(
    report.fetch("path_metrics") == expected_path_metrics,
    "Report path metrics changed: expected #{expected_path_metrics.inspect}, got #{report.fetch("path_metrics").inspect}"
  )

  evidence_code = report.fetch("evidence").values.flatten.map { |row| row.fetch("code") }.join("\n")
  [
    "Discourse.cache.read(cache_key(report))",
    "Discourse.cache.write(cache_key(report), report.as_json",
    "ActiveRecord::Base.connection.transaction",
    "DB.exec \"SET TRANSACTION READ ONLY\"",
    "public_send(report_method",
    "SiteSetting.reporting_improvements",
    "Rails.logger.error",
  ].each do |fragment|
    assert!(evidence_code.include?(fragment), "Report proof lost critical evidence fragment #{fragment.inspect}")
  end

  expected_capsule_rules = {
    "cache_global_inside_ractor" => "must reject",
    "report_snapshot_shareable" => "only after owner materializes data into plain frozen DTOs",
    "sql_inside_ractor" => "must reject",
  }
  assert!(report.fetch("capsule_rules") == expected_capsule_rules, "Report capsule rules changed")

  {
    evidence_counts: actual_counts,
    path_metrics: report.fetch("path_metrics"),
  }
end

def expected_promotion_fixture_results
  [
    ["tl0 did nothing -> nil", nil],
    ["tl0 meets tl1, old account -> 1", 1],
    ["tl0 meets tl1 stats but account 1min old -> nil (age gate)", nil],
    ["tl0 manual_locked -> nil", nil],
    ["tl1 meets tl2 -> 2", 2],
    ["tl1 short on likes_given -> nil", nil],
    ["tl1 short on topic_reply_count (residue field) -> nil", nil],
    ["tl2 already -> nil (deferred upstream)", nil],
  ].map do |name, decision|
    { "name" => name, "reference" => decision, "capsule" => decision }
  end
end

def check_discourse_migration_artifacts(checks)
  assert_pinned_file_hashes!(DISCOURSE_CLASSIFICATION_RUNNER_SHA256, "Discourse classification artifacts")

  head = discourse_head
  capsule_sha = Digest::SHA256.file(File.join(PHASE3, "promotion_capsule/capsule_eligibility.rb")).hexdigest
  proof_sha = Digest::SHA256.file(File.join(PHASE3, "promotion_capsule/proof.rb")).hexdigest
  promotion_patch = check_promotion_patch_artifact

  proof = read_json("phase3_migration/raw_logs/promotion_capsule_proof_latest.json")
  assert!(proof.fetch("status") == "pass", "Promotion proof JSON is not passing")
  assert!(proof.fetch("ruby").include?("ruby 4.0.5"), "Promotion proof Ruby runtime changed: #{proof.fetch("ruby")}")
  assert!(proof.fetch("proof_sha256") == proof_sha, "Promotion proof JSON is stale vs proof.rb")
  assert!(proof.fetch("capsule_sha256") == capsule_sha, "Promotion proof JSON is stale vs capsule_eligibility.rb")
  assert!(proof.fetch("fixture_count") == 8, "Promotion proof fixture count changed")
  assert!(proof.fetch("ractor_off_main") == true, "Promotion proof did not verify non-main Ractor execution")
  assert!(proof.fetch("snapshot_shareable") == true, "Promotion snapshot is not shareable")
  assert!(proof.fetch("payload_fields") == 21, "Promotion snapshot field count changed")
  assert!(proof.fetch("payload_bytes") == 537, "Promotion snapshot byte size changed")
  assert!(proof.fetch("forbidden_global_leaks").empty?, "Promotion proof has forbidden global leaks")
  assert!(proof.fetch("mismatch_count").zero?, "Promotion proof has equivalence mismatches")
  fixture_results = proof.fetch("fixture_results")
  assert!(
    fixture_results.map { |row| row.slice("name", "reference", "capsule") } == expected_promotion_fixture_results,
    "Promotion proof fixture cases or expected decisions changed"
  )
  assert!(
    fixture_results.all? { |row| row.fetch("ractor_off_main") == true && row.fetch("snapshot_shareable") == true },
    "Promotion proof did not run every named fixture in a non-main Ractor with a shareable snapshot"
  )

  drift = read_json("phase3_migration/raw_logs/promotion_drift_check_latest.json")
  assert!(drift.fetch("status") == "pass", "Promotion drift JSON is not passing")
  assert!(drift.fetch("discourse_head") == head, "Promotion drift JSON is stale vs Discourse HEAD")
  assert!(
    drift.fetch("real_source_sha256") == discourse_head_blob_sha256("lib/promotion.rb"),
    "Promotion drift JSON is stale vs HEAD:lib/promotion.rb"
  )
  assert!(drift.fetch("capsule_sha256") == capsule_sha, "Promotion drift JSON is stale vs capsule_eligibility.rb")
  assert!(drift.fetch("semantic_matches").size == 2, "Promotion drift check must cover tl1 and tl2")
  assert!(drift.fetch("semantic_matches").all? { |row| row.fetch("match") }, "Promotion drift semantic match failed")
  assert!(drift.fetch("negative_controls").size == 4, "Promotion drift check must have 4 negative controls")
  assert!(
    drift.fetch("negative_controls").all? { |row| row.fetch("detected") },
    "Promotion drift check mutation controls are not all red"
  )
  drift_log_summary = check_promotion_drift_log_consistency(
    drift,
    "phase3_migration/raw_logs/drift_check_latest.log",
    head,
  )

  guardian = read_json("phase3_migration/raw_logs/guardian_non_fit_proof_latest.json")
  assert!(guardian.fetch("commit") == head, "Guardian proof JSON is stale vs Discourse HEAD")
  assert!(
    guardian.fetch("source_sha256") == discourse_file_sha256("lib/guardian/post_guardian.rb"),
    "Guardian proof JSON is stale vs lib/guardian/post_guardian.rb"
  )
  assert!(guardian.fetch("predicate") == "Guardian#can_edit_post?", "Guardian proof predicate changed")
  assert!(
    guardian.dig("stale_snapshot_slice", "stale_count") == 3,
    "Guardian non-fit proof no longer shows 3 stale mutations"
  )
  assert!(
    guardian.fetch("live_reads_observed").any?,
    "Guardian non-fit proof has no live read evidence"
  )
  guardian_scope = check_guardian_non_fit_scope!(guardian)

  report = read_json("phase3_migration/raw_logs/report_partial_proof_latest.json")
  assert!(report.fetch("commit") == head, "Report proof JSON is stale vs Discourse HEAD")
  assert!(
    report.fetch("source_sha256") == discourse_file_sha256("app/models/report.rb"),
    "Report proof JSON is stale vs app/models/report.rb"
  )
  assert!(report.fetch("classification") == "partial", "Report proof classification changed")
  assert!(
    report.dig("path_metrics", "find_cached_sync_cache_reads").to_i.positive?,
    "Report proof no longer observes a sync cache read"
  )
  assert!(
    report.dig("path_metrics", "find_live_dispatch_points").to_i.positive? ||
    report.dig("path_metrics", "req_report_query_ops").to_i.positive?,
    "Report proof no longer observes live dispatch/query points"
  )
  report_scope = check_report_partial_scope!(report)

  write_gap = read_json("phase3_migration/raw_logs/promotion_write_side_gap_latest.json")
  assert!(write_gap.fetch("commit") == head, "Promotion write-side gap JSON is stale vs Discourse HEAD")
  assert!(
    write_gap.fetch("source_sha256") == discourse_file_sha256("lib/promotion.rb"),
    "Promotion write-side gap JSON is stale vs working-tree lib/promotion.rb"
  )
  assert!(write_gap.fetch("classification") == "eligibility_only", "Promotion write-side classification changed")
  assert!(write_gap.fetch("eligibility_capsule_present") == true, "Promotion eligibility capsule marker missing")
  assert!(write_gap.fetch("capsule_protocol_mentions").empty?, "Promotion unexpectedly has write-side protocol tokens")
  expected_write_gap_conclusion =
    "Promotion patch validates eligibility extraction only; Proposal + EffectIntent + outbox are not implemented in real Discourse."
  assert!(
    write_gap.fetch("conclusion") == expected_write_gap_conclusion,
    "Promotion write-side gap conclusion changed"
  )
  inline_write_side_effects = write_gap.fetch("inline_write_side_effects")
  assert!(
    inline_write_side_effects.size == 16,
    "Promotion write-side gap count changed: expected 16, got #{inline_write_side_effects.size}"
  )
  side_effect_source = inline_write_side_effects.map { |row| row.fetch("code") }.join("\n")
  %w[
    change_trust_level!
    enqueue_member_welcome_message
    enqueue_tl2_promotion_message
    UserHistory.create!
    save!
    recook_bio
    DiscourseEvent.trigger
    Group.user_trust_level_change!
    BadgeGranter.queue_badge_grant
    update_column
  ].each do |token|
    assert!(side_effect_source.include?(token), "Promotion write-side gap no longer includes #{token}")
  end

  checks << {
    name: "discourse_migration_artifacts",
    status: "pass",
    discourse_head: head,
    promotion_fixtures: proof.fetch("fixture_count"),
    promotion_fixture_cases_guarded: true,
    promotion_proof_ruby: proof.fetch("ruby"),
    promotion_proof_sha256: proof.fetch("proof_sha256"),
    promotion_drift_log: drift_log_summary,
    guardian_stale_mutations: guardian.dig("stale_snapshot_slice", "stale_count"),
    guardian_non_fit_scope: guardian_scope,
    report_classification: report.fetch("classification"),
    report_partial_scope: report_scope,
    promotion_write_side_classification: write_gap.fetch("classification"),
    promotion_write_side_gap: {
      inline_write_side_effect_count: inline_write_side_effects.size,
      required_tokens_checked: 10,
      conclusion_guarded: true,
    },
    runner_hashes_guarded: DISCOURSE_CLASSIFICATION_RUNNER_SHA256,
    promotion_proof_payload: {
      fields: proof.fetch("payload_fields"),
      bytes: proof.fetch("payload_bytes"),
    },
    promotion_patch: promotion_patch,
  }
end

def check_findings_mentions(checks)
  findings = File.read(FINDINGS)
  required = [
    "# Current evidence verdict",
    "# Phase 3 — Audit #9: standalone Slice B outbox parity",
    "raw_logs/environment_proof_latest.json",
    "raw_logs/environment_proof_latest.log",
    "raw_logs/slice_b_outbox_stress_leased_reduced.json",
    "raw_logs/slice_b_outbox_stress_leased_10k.json",
    "raw_logs/slice_b_outbox_stress_zero_lease_negative.json",
    "raw_logs/slice_b_full_test_latest.log",
    "raw_logs/mini_rails_full_test_latest.log",
    "raw_logs/promotion_bench_latest.json",
    "raw_logs/promotion_bench_latest.log",
    "raw_logs/promotion_amortization_latest.json",
    "raw_logs/promotion_write_side_spec_latest.json",
    "# Phase 3 — Audit #10: findings evidence drift guard",
    "raw_logs/findings_evidence_check_latest.json",
    "raw_logs/promotion_capsule_proof_latest.json",
    "raw_logs/promotion_drift_check_latest.json",
    "raw_logs/drift_check_latest.log",
    "promotion_capsule/promotion.patch",
    "audit_output.json",
    "# Phase 3 — Audit #11: Promotion proof false-PASS cleanup",
    "# Phase 3 — Audit #12: Discourse evidence freshness guard",
    "# Phase 3 — Audit #13: baseline audit dirty-tree correction",
    "# Phase 3 — Audit #14: benchmark aggregate consistency guard",
    "# Phase 3 — Audit #15: transaction suite log guard",
    "# Phase 3 — Audit #16: Promotion patch freshness guard",
    "# Phase 3 — Audit #17: Promotion benchmark evidence guard",
    "# Phase 3 — Audit #18: environment proof guard",
    "# Phase 3 — Audit #19: Linux benchmark runtime guard",
    "# Phase 3 — Audit #20: current verdict guard",
    "# Phase 3 — Audit #21: Discourse spec comparison evidence gap guard",
    "# Phase 3 — Audit #22: local Promotion pass vs project gate guard",
    "# Phase 3 — Audit #23: legacy positive economic probe guard",
    "# Phase 3 — Audit #24: top-level verdict prose guard",
    "# Phase 3 — Audit #25: Minitest log summary guard",
    "# Phase 3 — Audit #26: outbox stress workload guard",
    "# Phase 3 — Audit #27: outbox old-unsafe scope guard",
    "# Phase 3 — Audit #28: Promotion proof payload byte guard",
    "# Phase 3 — Audit #29: outbox duplicate-attempt budget guard",
    "# Phase 3 — Audit #30: Promotion write-side gap count guard",
    "# Phase 3 — Audit #31: Promotion write-side conclusion guard",
    "# Phase 3 — Audit #32: Promotion benchmark Ruby runtime guard",
    "# Phase 3 — Audit #33: Promotion proof Ruby runtime guard",
    "# Phase 3 — Audit #34: Promotion benchmark log/JSON consistency guard",
    "# Phase 3 — Audit #35: Promotion proof fixture identity guard",
    "# Phase 3 — Audit #36: Promotion runner freshness guard",
    "# Phase 3 — Audit #37: Promotion benchmark report-text guard",
    "# Phase 3 — Audit #38: economic raw-log/JSON consistency guard",
    "# Phase 3 — Audit #39: economic runner hash guard",
    "# Phase 3 — Audit #40: A2 raw-log/JSON consistency guard",
    "# Phase 3 — Audit #41: A2 runner hash guard",
    "# Phase 3 — Audit #42: outbox stress runner hash guard",
    "# Phase 3 — Audit #43: transaction suite log input hash guard",
    "# Phase 3 — Audit #44: Discourse classification runner hash guard",
    "# Phase 3 — Audit #45: environment proof runner hash guard",
    "# Phase 3 — Audit #46: environment proof raw-log/JSON consistency guard",
    "# Phase 3 — Audit #47: Promotion drift raw-log/JSON consistency guard",
    "# Phase 3 — Audit #48: legacy refork probe raw-log scope guard",
    "# Phase 3 — Audit #49: Guardian/Report classification scope guard",
    "# Phase 3 — Audit #50: calibrated struct rerun guard",
    "# Phase 3 — Audit #51: lease ratification documentation guard",
    "# Phase 3 — Audit #52: Promotion amortization gate",
    "# Phase 3 — Audit #53: Promotion write-side migration spec",
    "# Phase 3 — Audit #54: A2.3 3D matrix axis upgrade",
    "each transaction-suite raw log has exactly one Minitest summary",
    "outbox stress artifacts must preserve their workload size, worker count, batches, and lease settings",
    "old unsafe no-lease dispatcher controls are mini Rails only",
    "Promotion proof payload bytes are now machine-guarded at 537",
    "leased and zero-lease outbox stress artifacts must keep max_allowed_duplicate_attempt_percent=0.0",
    "Promotion write-side gap count is now machine-guarded at 16 inline write/side-effect lines",
    "Promotion write-side gap conclusion is now machine-guarded",
    "Promotion benchmark Ruby runtime is now machine-guarded as Ruby 4.0.5",
    "Promotion proof Ruby runtime is now machine-guarded as Ruby 4.0.5",
    "Promotion benchmark raw log is now machine-checked against `promotion_bench_latest.json`",
    "Promotion proof fixture names and expected decisions are now machine-guarded",
    "Promotion proof and benchmark artifacts are now guarded against stale runner scripts",
    "Promotion benchmark numbers cited in FINDINGS.md are now derived from `promotion_bench_latest.json`",
    "Economic gate raw logs are now machine-checked against their per-ALLOC JSON artifacts",
    "Economic gate runner inputs are now hash-pinned",
    "A2 sync-gateway raw logs are now machine-checked against their per-cell JSON artifacts",
    "A2 sync-gateway runner inputs are now hash-pinned",
    "Outbox stress runner inputs are now hash-pinned",
    "Transaction suite log inputs are now hash-pinned",
    "Discourse classification runner inputs are now hash-pinned",
    "Environment proof runner input is now hash-pinned",
    "Environment proof raw log is now machine-checked against `environment_proof_latest.json`",
    "Promotion drift raw log is now machine-checked against `promotion_drift_check_latest.json`",
    "Legacy refork probe raw logs are now scope-guarded",
    "Guardian and Report classification scopes are now machine-guarded",
    "Calibrated struct rerun artifacts are now machine-guarded",
    "Lease ratification docs are now machine-guarded",
    "Historical Discourse `spec/lib/promotion_spec.rb` before/after output is **not current machine-guarded evidence**",
    "The current guarded evidence for Promotion is proof/drift/patch/benchmark/write-gap",
    "Local Promotion-eligibility migration blockers are not hit",
    "This is **not** a project-level continuation gate",
    "Legacy positive economic probes are context only, not continuation evidence",
    "Only `economic_gate_results.json`, `economic_gate_struct_matrix_results.json`, and the calibrated struct rerun artifacts",
  ]
  missing = required.reject { |text| findings.include?(text) }
  assert!(missing.empty?, "FINDINGS.md missing required evidence mentions: #{missing.inspect}")

  forbidden_current_claims = [
    ["real tests behavior-neutral ", "\u2713"].join,
    ["behavior-neutral ", "real spec"].join,
    "None of the kill conditions hit",
  ]
  present = forbidden_current_claims.select { |text| findings.include?(text) }
  assert!(
    present.empty?,
    "FINDINGS.md still presents historical Discourse spec output as current guarded evidence: #{present.inspect}"
  )

  checks << {
    name: "findings_mentions",
    status: "pass",
    required_mentions: required,
    forbidden_current_claims_absent: true,
    forbidden_current_claims_checked: forbidden_current_claims.size,
  }
end

def check_findings_promotion_benchmark_text(checks)
  findings = File.read(FINDINGS)
  benchmark = checks.find { |check| check.fetch(:name) == "promotion_benchmark" }
  assert!(benchmark, "Promotion benchmark check missing before FINDINGS benchmark text guard")

  throughput = benchmark.fetch(:throughput)
  ratios = benchmark.fetch(:ratios)
  inline = format_decisions_m(throughput.fetch("inline_full_before_decisions_s"))
  owner = format_decisions_k(throughput.fetch("owner_snapshot_build_plus_decide_decisions_s"))
  decide = format_decisions_m(throughput.fetch("decide_only_snapshot_reused_decisions_s"))
  x4 = format_decisions_m(throughput.fetch("decide_only_x4_ractors_decisions_s"))
  owner_ratio = format_ratio(ratios.fetch("owner_snapshot_build_plus_decide_vs_inline"))
  x4_ratio = format_ratio(ratios.fetch("decide_x4_ractors_vs_decide_only"))

  required = [
    "inline full ~#{inline} decisions/s",
    "owner snapshot build + decide ~#{owner}/s (**#{owner_ratio}× vs inline**)",
    "decide-only ~#{decide}/s",
    "decide-only ×4 Ractors ~#{x4}/s",
    "(**#{x4_ratio}× vs single decide**)",
    "Bench: latest artifact reports inline full ~#{inline} decisions/s; owner snapshot build + decide ~#{owner}/s (#{owner_ratio}x vs",
    "- Inline full: ~#{inline} decisions/s.",
    "- Owner snapshot build + decide: ~#{owner} decisions/s (`#{owner_ratio}x` vs inline).",
    "- Decide-only snapshot reused: ~#{decide} decisions/s.",
    "- Decide-only x4 Ractors: ~#{x4} decisions/s (`#{x4_ratio}x` vs single pure decide).",
  ]
  missing = required.reject { |fragment| findings.include?(fragment) }
  assert!(
    missing.empty?,
    "FINDINGS.md Promotion benchmark numbers drifted from promotion_bench_latest.json: #{missing.inspect}"
  )

  checks << {
    name: "findings_promotion_benchmark_text",
    status: "pass",
    inline_full: inline,
    owner_snapshot_build_plus_decide: owner,
    owner_ratio: owner_ratio,
    decide_only: decide,
    decide_x4_ractors: x4,
    x4_ratio: x4_ratio,
  }
end

def check_findings_current_verdict_text(checks)
  findings = File.read(FINDINGS)
  current_section = findings.split(/^---\n/, 2).first
  required = [
    "Verdict atual: **PIVOT / continue only as narrow P&D**, not product/runtime/platform.",
    "remains `eligibility_only`; the write side still does not implement `Proposal + EffectIntent + outbox` in Discourse.",
    "Economic gate: current reduced Linux matrices have **no surviving allocs**",
    "The calibrated `struct` re-run is now guarded separately: ALLOC=100 fails the memory floor;",
    "A2 sync gateway: 3D SCAN×ALLOC×CAP_EVERY matrix (72 cells) — chatty bounded-sync (CAP_EVERY=1) fails at every SCAN/ALLOC",
    "Promotion benchmark: owner snapshot build + decide is slower than inline",
    "Do not advance to gem/DSL/product.",
  ]
  missing = required.reject { |text| current_section.include?(text) }
  assert!(missing.empty?, "Current evidence verdict section is missing required bearish claims: #{missing.inspect}")

  forbidden = [
    "Verdict atual: **CONTINUE",
    "Verdict atual: **KILL",
    "economic_final_gate_passed=true",
    "advance_to_gem_or_dsl=true",
    "full_discourse_write_side_outbox_validated=true",
  ]
  present = forbidden.select { |text| current_section.include?(text) }
  assert!(present.empty?, "Current evidence verdict section contains forbidden verdict claims: #{present.inspect}")

  checks << {
    name: "findings_current_verdict_text",
    status: "pass",
    required_bearish_claims: required,
    forbidden_verdict_claims_absent: true,
  }
end

def check_promotion_amortization(checks)
  assert_pinned_file_hashes!(PROMOTION_AMORTIZATION_RUNNER_SHA256, "Promotion amortization")
  json = read_json("phase3_migration/raw_logs/promotion_amortization_latest.json")
  assert!(json.fetch("ruby").include?("ruby 4.0.5"), "Promotion amortization not run on Ruby 4.0.5: #{json.fetch("ruby").inspect}")
  assert!(
    json.fetch("amortization_runner_sha256") == PROMOTION_AMORTIZATION_RUNNER_SHA256.fetch("phase3_migration/promotion_capsule/promotion_amortization.rb"),
    "Promotion amortization runner sha in artifact does not match the pinned runner"
  )
  assert!(
    json.fetch("capsule_sha256") == PROMOTION_AMORTIZATION_RUNNER_SHA256.fetch("phase3_migration/promotion_capsule/capsule_eligibility.rb"),
    "Promotion amortization capsule sha in artifact does not match pinned capsule_eligibility.rb"
  )
  verdict = json.fetch("verdict")
  assert!(verdict.fetch("promotion_amortizes") == false, "Promotion amortization verdict claims amortization")
  assert!(verdict.fetch("any_real_variant_amortizes") == false, "Promotion amortization: a real variant claims to amortize")
  assert!(verdict.fetch("classification") == "compatibility_only_no_amortization", "Promotion amortization classification changed")
  assert!(verdict.fetch("frozen_reuse_is_real_promotion_scenario") == false, "Promotion amortization marks frozen-reuse as a real scenario")
  rows = json.fetch("rows")
  ns = rows.map { |row| row.fetch("n") }
  assert!(ns == [100, 1000, 10000], "Promotion amortization N set changed: #{ns.inspect}")
  rows.each do |row|
    assert!(row.fetch("capsule_seq_amortizes") == false, "Promotion amortization: capsule_seq amortized at N=#{row.fetch("n")}")
    assert!(row.fetch("capsule_par_amortizes") == false, "Promotion amortization: capsule_par amortized at N=#{row.fetch("n")}")
    assert!(row.fetch("capsule_seq_speedup_vs_inline") < 1.0, "Promotion amortization: capsule_seq not slower than inline at N=#{row.fetch("n")}")
  end
  checks << {
    name: "promotion_amortization",
    status: "pass",
    ns: ns,
    classification: verdict.fetch("classification"),
    any_real_variant_amortizes: verdict.fetch("any_real_variant_amortizes"),
    max_capsule_par_speedup_vs_inline: rows.map { |row| row.fetch("capsule_par_speedup_vs_inline") }.max,
    platform: json.fetch("platform"),
    runner_hashes_guarded: PROMOTION_AMORTIZATION_RUNNER_SHA256,
  }
end

def check_promotion_write_side_spec(checks)
  assert_pinned_file_hashes!(PROMOTION_WRITE_SIDE_SPEC_RUNNER_SHA256, "Promotion write-side spec")
  spec = read_json("phase3_migration/raw_logs/promotion_write_side_spec_latest.json")
  gap = read_json("phase3_migration/raw_logs/promotion_write_side_gap_latest.json")
  assert!(spec.fetch("classification") == "eligibility_only", "Promotion write-side spec classification changed")
  assert!(spec.fetch("write_side_implemented") == false, "Promotion write-side spec claims the write side is implemented")
  assert!(spec.fetch("inline_effect_count") == 16, "Promotion write-side spec inline effect count changed: #{spec.fetch("inline_effect_count")}")
  by_kind = spec.fetch("by_kind")
  assert!(by_kind == { "commit" => 7, "effect" => 8, "residue" => 1 }, "Promotion write-side spec kind breakdown changed: #{by_kind.inspect}")
  intents = spec.fetch("effect_intents_required")
  expected_intents = %w[badge_grant discourse_event_user_promoted group_trust_level_change member_welcome_message staff_action_log tl2_promotion_message user_history]
  assert!(intents.sort == expected_intents, "Promotion write-side spec EffectIntents changed: #{intents.inspect}")
  assert!(
    spec.fetch("source_sha256") == gap.fetch("source_sha256"),
    "Promotion write-side spec read a different lib/promotion.rb than the write-side gap artifact"
  )
  assert!(
    spec.fetch("spec_runner_sha256") == PROMOTION_WRITE_SIDE_SPEC_RUNNER_SHA256.fetch("phase3_migration/promotion_write_side_spec.rb"),
    "Promotion write-side spec runner sha in artifact does not match the pinned runner"
  )
  checks << {
    name: "promotion_write_side_spec",
    status: "pass",
    classification: spec.fetch("classification"),
    write_side_implemented: spec.fetch("write_side_implemented"),
    inline_effect_count: spec.fetch("inline_effect_count"),
    by_kind: by_kind,
    effect_intents_required: intents.sort,
    runner_hashes_guarded: PROMOTION_WRITE_SIDE_SPEC_RUNNER_SHA256,
  }
end

# F1 anti-forgery: tie a verdict's headline numbers to the RAW per-cell data so a hand-edited verdict block (numbers inside
# the tolerance bands but inconsistent with the cells) cannot pass. Anchors ractor_best PSS to its real per-cell value and
# checks the verdict's own ratio/saving arithmetic against the two PSS numbers it reports. It does NOT re-run the runner's
# iso-interpolation (the baseline iso PSS stays the runner's; the SHA pin covers the interpolation code) — it makes the
# per-cell cross-check load-bearing for the cited headline, not just for cell identity.
def assert_strong_gate_verdict_arithmetic!(verdict, cells, alloc)
  rb = verdict.fetch("ractor_best")
  ractor_pss = rb.fetch("pss_mb")
  w = rb.fetch("workers")
  cell = cells.find { |c| c.fetch("alloc") == alloc && c.fetch("workers") == w && c.fetch("model") == "ractor_frozen_image" }
  assert!(cell, "alloc=#{alloc} verdict ractor_best names workers=#{w} but no ractor cell exists there")
  assert!(cell.fetch("pss_mb") == ractor_pss,
          "alloc=#{alloc} verdict ractor_best.pss_mb #{ractor_pss} != the real w#{w} ractor cell pss_mb #{cell.fetch("pss_mb")} — forged headline PSS")
  iso = verdict.dig("strongest_baseline", "iso_pss_mb")
  assert!(iso && iso > 0, "alloc=#{alloc} verdict missing a positive strongest_baseline iso PSS")
  derived_ratio = 100.0 * ractor_pss / iso
  assert!((verdict.fetch("pss_ratio_percent") - derived_ratio).abs <= 1.5,
          "alloc=#{alloc} pss_ratio_percent #{verdict.fetch("pss_ratio_percent")} inconsistent with ractor/baseline PSS (#{ractor_pss}/#{iso} = #{derived_ratio.round(1)}%) — verdict arithmetic forged")
  derived_saving = iso - ractor_pss
  assert!((verdict.fetch("absolute_saving_mb") - derived_saving).abs <= 0.6,
          "alloc=#{alloc} absolute_saving_mb #{verdict.fetch("absolute_saving_mb")} inconsistent with baseline-ractor PSS (#{iso} - #{ractor_pss} = #{derived_saving.round(1)}) — verdict arithmetic forged")
end

def check_strong_host_gate_v2_reduced(checks)
  assert_pinned_file_hashes!(STRONG_GATE_V2_RUNNER_SHA256, "strong host gate v2")
  pinned_sha = STRONG_GATE_V2_RUNNER_SHA256.fetch("strong_host_gate_v2.rb")

  # P2 guard: a full-host artifact must NOT exist while there is no check_strong_host_gate_v2_full to validate it. The
  # reduced guard refuses to let a large run sit unverified under a green suite — implement the full check before landing one.
  assert!(!File.exist?(relative_file(STRONG_GATE_V2_FULL_ARTIFACT)),
          "a full-host artifact exists at #{STRONG_GATE_V2_FULL_ARTIFACT} but there is NO check_strong_host_gate_v2_full to validate it — implement that check (full config + the same hardened gates) before landing a full-host artifact; the reduced guard must not silently bless it")

  data = read_json("phase3_migration/raw_logs/strong_gate_v2_reduced.json")
  # HONESTY GUARD (NOT a gate pass): the reduced artifact must STAY labeled reduced, come from the PINNED runner, keep the
  # negative control failing, and match the numbers the docs cite. It does NOT assert the economic gate passed —
  # economic_final_gate_passed stays false in the project verdict.
  run_class = data.fetch("run_class")
  assert!(run_class == "reduced",
          "strong_gate_v2_reduced.json run_class must be 'reduced', got #{run_class.inspect} (a full-host run belongs in a separate artifact + check)")
  assert!(data.fetch("mem_measured") == true, "strong_gate_v2_reduced.json must have mem_measured=true (Linux)")
  assert!(data.fetch("platform").end_with?("linux"), "strong_gate_v2_reduced.json must be a Linux run")
  # the aggregate self-certifies which runner produced it; it MUST equal the pinned SHA (no swapped/unpinned runner)
  assert!(data.fetch("runner_sha256") == pinned_sha,
          "strong_gate_v2_reduced.json runner_sha256 #{data.fetch("runner_sha256").inspect} != pinned #{pinned_sha} — re-run with the pinned runner")

  # exact reduced config: a different config is a DIFFERENT experiment and must not reuse this guard
  cfg = data.fetch("config")
  assert!(cfg.fetch("shapes") == ["hash"], "reduced config shapes must be [hash], got #{cfg.fetch("shapes").inspect}")
  assert!(cfg.fetch("targets_mb") == [200.0], "reduced config targets_mb must be [200.0], got #{cfg.fetch("targets_mb").inspect}")
  assert!(cfg.fetch("allocs") == [0, 100], "reduced config allocs must be [0,100], got #{cfg.fetch("allocs").inspect}")
  assert!(cfg.fetch("workers") == [1, 2, 4], "reduced config workers must be [1,2,4], got #{cfg.fetch("workers").inspect}")
  assert!(cfg.fetch("reps") == 3, "reduced config reps must be 3, got #{cfg.fetch("reps").inspect}")
  assert!(cfg.fetch("duration_s") == 3.0, "reduced config duration_s must be 3.0, got #{cfg.fetch("duration_s").inspect}")

  cells = data.fetch("cells")
  expected_cells = 7 * 3 * 2   # 7 models x 3 workers x 2 allocs
  assert!(cells.size == expected_cells,
          "reduced run must have #{expected_cells} cells (7 models x 3 workers x 2 allocs), got #{cells.size}")
  assert!(cells.all? { |c| c.fetch("run_class") == "reduced" }, "every reduced cell must be labeled reduced (no full_host masquerade)")
  cells.each { |c| assert_linux_ruby_cell!(c, "strong_gate_v2_reduced cell") }

  # exact model roster (NOT just the count): the reduced run must contain precisely these 7 models
  models_seen = cells.map { |c| c.fetch("model") }.uniq.sort
  assert!(models_seen == STRONG_GATE_V2_REDUCED_MODELS.sort,
          "reduced models #{models_seen.inspect} != expected roster #{STRONG_GATE_V2_REDUCED_MODELS.sort.inspect}")

  # per-cell JSON cross-check (P2 guard): every aggregate cell must have a matching file in the reduced dir that is the SAME
  # record, and the dir must contain EXACTLY those files — no stale/missing/extra/divergent per-cell file silently
  # disagreeing with the aggregate the docs cite.
  cell_filename = ->(c) { "#{c.fetch("shape")}_t#{c.fetch("dataset_target_mb").to_i}_a#{c.fetch("alloc")}_w#{c.fetch("workers")}_#{c.fetch("model")}.json" }
  dir = relative_file(STRONG_GATE_V2_REDUCED_DIR)
  assert!(File.directory?(dir), "reduced per-cell dir #{STRONG_GATE_V2_REDUCED_DIR} is missing")
  expected_files = cells.map(&cell_filename).sort
  assert!(expected_files.uniq.size == expected_files.size, "reduced aggregate has colliding per-cell filenames (duplicate cell identity)")
  actual_files = Dir.children(dir).select { |f| f.end_with?(".json") }.sort
  assert!(actual_files == expected_files,
          "reduced per-cell dir mismatch: missing #{(expected_files - actual_files).inspect}, extra #{(actual_files - expected_files).inspect}")
  cell_fields = %w[shape dataset_target_mb alloc workers model mode ruby platform run_class mem_measured duration_s reps
                   throughput_items_s throughput_min_items_s throughput_max_items_s
                   pss_kb pss_mb pss_lo_mb pss_hi_mb private_dirty_mb correct]
  cells.each do |c|
    fname = cell_filename.call(c)
    pc = read_json(File.join(STRONG_GATE_V2_REDUCED_DIR, fname))
    cell_fields.each do |k|
      assert!(pc.fetch(k) == c.fetch(k),
              "per-cell #{fname} field #{k.inspect}=#{pc.fetch(k).inspect} diverges from aggregate #{c.fetch(k).inspect}")
    end
    assert!(pc == c, "per-cell #{fname} is not identical to its aggregate record (a field diverged)")
  end

  # raw-log <-> JSON consistency: the raw log must carry the SAME runner SHA and point at this JSON
  raw = File.read(relative_file("phase3_migration/raw_logs/strong_gate_v2_reduced.log"))
  assert!(raw.include?("runner_sha256=#{pinned_sha}"), "reduced raw log does not carry the pinned runner_sha256")
  assert!(raw.include?("strong_gate_v2_reduced.json"), "reduced raw log does not point at strong_gate_v2_reduced.json")
  assert!(raw.include?("run_class=reduced"), "reduced raw log does not state run_class=reduced")

  by_alloc = data.fetch("verdicts").to_h { |v| [v.fetch("alloc"), v] }
  control = by_alloc.fetch(0) { raise "reduced run missing the alloc=0 negative control" }
  rails_like = by_alloc.fetch(100) { raise "reduced run missing the alloc=100 cell" }
  # falsification discipline: with NO allocation pressure CoW stays intact and the strong process baselines must match
  # the Ractor, so the negative control must NOT show an economic win.
  assert!(control.fetch("status") == "pivot",
          "alloc=0 negative control must PIVOT (CoW intact -> processes match), got #{control.fetch("status").inspect}")

  # F1 anti-forgery: both verdicts' headline ratio/saving must be arithmetically consistent with the raw per-cell PSS
  assert_strong_gate_verdict_arithmetic!(control, cells, 0)
  assert_strong_gate_verdict_arithmetic!(rails_like, cells, 100)

  # alloc=100 cited result must match the JSON within tolerance (docs cite these; guard against doc drift / a flipped or
  # near-threshold result sneaking through). A survives requires ALL gate_states=pass (no straddle hidden under a median).
  ratio_pct = rails_like.fetch("pss_ratio_percent")
  saving    = rails_like.fetch("absolute_saving_mb")
  reach_pct = rails_like.fetch("throughput_reach_percent")
  gates     = rails_like.fetch("gate_states")
  assert!(rails_like.fetch("status") == "survives", "alloc=100 reduced status must be survives, got #{rails_like.fetch("status").inspect}")
  assert!(%w[ratio saving reach].all? { |k| gates.fetch(k) == "pass" },
          "alloc=100 survives requires every gate_state=pass (no median-luck straddle), got #{gates.inspect}")
  assert!((ratio_pct - 51.0).abs <= 1.5, "alloc=100 pss_ratio_percent #{ratio_pct} drifted from cited ~51% (>1.5pp) — re-reconcile docs+artifact")
  assert!((saving - 263.0).abs <= 5, "alloc=100 saving #{saving}MB drifted from cited ~263MB (>5MB) — re-reconcile docs+artifact")
  assert!((reach_pct - 94.0).abs <= 3, "alloc=100 reach #{reach_pct}% drifted from cited ~94% (>3pp) — re-reconcile docs+artifact")
  assert!(rails_like.dig("strongest_baseline", "model") == "process_gc_compact_plus_warmup",
          "alloc=100 strongest baseline drifted from cited process_gc_compact_plus_warmup: #{rails_like.dig("strongest_baseline", "model").inspect}")
  assert!(rails_like.fetch("win_is_single_operating_point") == true, "alloc=100 reduced is a single operating point (cited)")
  assert!(rails_like.dig("strongest_baseline", "extrapolated_out_of_range") == false,
          "alloc=100 survives must NOT be extrapolated (a baseline must actually reach the ractor throughput)")
  # survives now demands a PESSIMISTIC per-worker win (ractor worst PSS vs the adversarial lowest baseline lower-envelope),
  # so the final win list must be non-empty and the adversarial baseline it cleared must be a real process model.
  wins_at = Array(rails_like.fetch("ractor_wins_at_workers"))
  assert!(!wins_at.empty?,
          "alloc=100 survives must have >=1 PESSIMISTIC per-worker win, got #{wins_at.inspect} (a median-only win cannot pass)")
  adversarial = rails_like.fetch("adversarial_baseline")
  assert!(STRONG_GATE_V2_REDUCED_MODELS.include?(adversarial.fetch("model")),
          "alloc=100 adversarial baseline #{adversarial.inspect} must be one of the process roster")
  assert!(adversarial.fetch("model") == "process_gc_compact_plus_warmup",
          "alloc=100 adversarial baseline drifted from cited process_gc_compact_plus_warmup: #{adversarial.inspect}")

  docs_text = [
    File.read(relative_file("README.md")),
    File.read(FINDINGS),
    File.read(relative_file("docs/decisions.md")),
  ].join("\n")
  assert!(docs_text.include?("51% PSS / 263MB saving / 94% reach"),
          "docs do not cite the current strong_gate_v2_reduced alloc=100 numbers")
  assert!(!docs_text.include?("52% PSS / 251MB saving / 89% reach"),
          "docs still cite stale strong_gate_v2_reduced numbers")

  checks << {
    name: "strong_host_gate_v2_reduced",
    status: "pass",
    runner_hash_guarded: STRONG_GATE_V2_RUNNER_SHA256,
    runner_sha256_in_artifact_matches_pin: true,
    run_class: run_class,
    full_host_gate_run: false,
    full_host_artifact_absent: true,
    config_asserted: cfg.slice("shapes", "targets_mb", "allocs", "workers", "reps", "duration_s"),
    cells: cells.size,
    models_asserted: STRONG_GATE_V2_REDUCED_MODELS,
    per_cell_files_cross_checked: cells.size,
    verdict_arithmetic_tied_to_cells: true,
    raw_log_json_consistency_checked: true,
    alloc0_control_status: control.fetch("status"),
    alloc100_status: rails_like.fetch("status"),
    alloc100_gate_states: gates,
    alloc100_win_is_single_operating_point: rails_like["win_is_single_operating_point"],
    alloc100_ractor_wins_at_workers: wins_at,
    alloc100_ractor_median_wins_at_workers: rails_like["ractor_median_wins_at_workers"],
    alloc100_strongest_baseline: rails_like.dig("strongest_baseline", "model"),
    alloc100_adversarial_baseline: adversarial.fetch("model"),
    alloc100_pss_ratio_percent: ratio_pct,
    alloc100_absolute_saving_mb: saving,
    alloc100_throughput_reach_percent: reach_pct,
  }
end

# ---------------------------------------------------------------------------------------------------------------------
# INDEPENDENT recompute engine (Phase 3 / F1 closure): reimplements strong_host_gate_v2#verdict_for from the per-cell JSON
# so the verifier DERIVES status/ratio/saving/reach/baselines/pessimistic-wins from the raw cells instead of trusting the
# runner's emitted verdict. Proven to reproduce the reduced verdicts exactly (pivot@0 / survives@100). The duplication is
# DELIBERATE — an independent second implementation is what catches a forged/buggy emitted verdict; the self-test below
# keeps the two from drifting silently (it goes red the instant they disagree on real data).
SG_RACTOR = "ractor_frozen_image"
STRONG_GATE_V2_FULL_RUNS_DIR = "phase3_migration/strong_gate_v2_full_runs"
STRONG_GATE_V2_FULL_CONFIG = {
  "shapes" => %w[hash struct blob], "targets_mb" => [200.0, 500.0, 1000.0],
  "allocs" => [0, 100, 500], "workers" => [1, 2, 4, 8],
}.freeze

def sg_iso_at(points, t)   # interpolate the yielded per-point value at throughput t along the worker frontier (clamped)
  s = points.sort_by { |p| p[:tput] }
  return nil if s.empty?
  return (yield s.first).to_f if t <= s.first[:tput]
  return (yield s.last).to_f  if t >= s.last[:tput]
  hi = s.find { |p| p[:tput] >= t }; lo = s.reverse.find { |p| p[:tput] <= t }
  ylo = yield(lo); yhi = yield(hi)
  den = (hi[:tput] - lo[:tput]).to_f
  return ylo.to_f if den.zero?   # two frontier points share this throughput -> no span to interpolate (avoid NaN)
  ylo + (t - lo[:tput]) / den * (yhi - ylo)
end
def sg_reaches?(points, t) = points.map { |p| p[:tput] }.max.to_f >= t

def sg_recompute_verdict(cells, gates)
  ratio_max = gates.fetch("pss_ratio_max"); saving_min = gates.fetch("absolute_saving_mb_min"); reach_min = gates.fetch("throughput_reach_min")
  by_model = Hash.new { |h, k| h[k] = [] }
  cells.each do |c|
    # a real Linux run always carries numeric memory/throughput (smaps_full re-raises on a /proc miss); a null here is a
    # forged/degenerate cell — reject loudly rather than crash in sg_iso_at or silently coerce nil.to_f -> 0.0.
    %w[throughput_items_s throughput_min_items_s throughput_max_items_s pss_kb pss_lo_mb pss_hi_mb].each do |f|
      assert!(c.fetch(f).is_a?(Numeric), "recompute: cell #{c.values_at("shape", "alloc", "workers", "model").inspect} has non-numeric #{f}=#{c.fetch(f).inspect}")
    end
    by_model[c.fetch("model")] << {
      tput: c.fetch("throughput_items_s"), tlo: c.fetch("throughput_min_items_s"), thi: c.fetch("throughput_max_items_s"),
      pss: c.fetch("pss_kb").to_f, lo_mb: c.fetch("pss_lo_mb"), hi_mb: c.fetch("pss_hi_mb"),
      workers: c.fetch("workers"), correct: c.fetch("correct"),
    }
  end
  return { status: "invalid" } if cells.any? { |c| !c.fetch("correct") }
  ractor = (by_model[SG_RACTOR] || []).reject { |x| x[:tput].nil? }
  return { status: "no_ractor_model" } if ractor.empty?
  rb = ractor.max_by { |x| x[:tput] }
  pmodels = by_model.keys.reject { |m| m.start_with?("ractor") }
  pcells = pmodels.flat_map { |m| by_model[m] }
  return { status: "invalid" } if pcells.empty?
  pmax = pcells.max_by { |x| x[:tput] }
  reach = rb[:tput] / pmax[:tput]; reach_lo = rb[:tlo] / pmax[:thi]; reach_hi = rb[:thi] / pmax[:tlo]

  reachable = pmodels.select { |m| sg_reaches?(by_model[m], rb[:tput]) }
  extrapolated = reachable.empty?
  pool = extrapolated ? pmodels : reachable
  isos = pool.map { |m| [m, sg_iso_at(by_model[m], rb[:tput]) { |p| p[:pss] }] }.reject { |_m, v| v.nil? }
  return { status: "invalid" } if isos.empty?
  smodel, spss = isos.min_by { |_m, v| v }
  sf = by_model[smodel]
  s_hi = sg_iso_at(sf, rb[:tput]) { |p| p[:hi_mb] }   # reported baseline upper envelope (best-for-thesis edge)
  amodel, adv_lo = pool.map { |m| [m, sg_iso_at(by_model[m], rb[:tput]) { |p| p[:lo_mb] }] }.reject { |_m, v| v.nil? }.min_by { |_m, v| v }

  ratio = rb[:pss] / spss
  saving = ((spss - rb[:pss]) / 1024.0).round(1)
  ratio_lo = rb[:lo_mb] / s_hi; ratio_hi = rb[:hi_mb] / adv_lo
  saving_lo = (adv_lo - rb[:hi_mb]).round(1); saving_hi = (s_hi - rb[:lo_mb]).round(1)
  rstate = ratio_hi <= ratio_max ? :pass : (ratio_lo > ratio_max ? :fail : :straddle)
  vstate = saving_lo >= saving_min ? :pass : (saving_hi < saving_min ? :fail : :straddle)
  hstate = reach_lo >= reach_min ? :pass : (reach_hi < reach_min ? :fail : :straddle)
  straddle = [rstate, vstate, hstate].include?(:straddle)

  wins = ractor.sort_by { |x| x[:workers] }.select do |rc|
    w_lo = pool.map { |m| sg_iso_at(by_model[m], rc[:tput]) { |p| p[:lo_mb] } }.compact.min
    next false unless w_lo
    rp = rc[:hi_mb] / w_lo; rwp = rc[:tlo] / pmax[:thi]
    rp <= ratio_max && (w_lo - rc[:hi_mb]).round(1) >= saving_min && rwp >= reach_min
  end.map { |x| x[:workers] }
  wins = [] if extrapolated || straddle

  status =
    if extrapolated then "inconclusive"
    elsif rstate == :fail || vstate == :fail then (spss <= rb[:pss] ? "kill" : "pivot")
    elsif hstate == :fail then "pivot"
    elsif straddle then "inconclusive"
    elsif wins.empty? then "inconclusive"
    else "survives" end
  { status: status, ratio_pct: (ratio * 100).round(1), saving: saving, reach_pct: (reach * 100).round(1),
    smodel: smodel, amodel: amodel, gate_states: { "ratio" => rstate.to_s, "saving" => vstate.to_s, "reach" => hstate.to_s },
    wins: wins, extrapolated: extrapolated }
end

# assert the independent recompute reproduces what the runner EMITTED (drift / forgery / median-only / extrapolation catch)
def sg_assert_recompute_matches!(emitted, cells, gates, label)
  r = sg_recompute_verdict(cells, gates)
  assert!(r[:status] == emitted.fetch("status"),
          "#{label}: independent recompute status #{r[:status].inspect} != emitted #{emitted.fetch("status").inspect} (runner verdict not reproducible from cells)")
  if emitted["gate_states"]
    assert!(r[:gate_states] == emitted.fetch("gate_states"),
            "#{label}: recompute gate_states #{r[:gate_states].inspect} != emitted #{emitted.fetch("gate_states").inspect}")
  end
  if emitted["pss_ratio_percent"]
    assert!((r[:ratio_pct] - emitted.fetch("pss_ratio_percent")).abs <= 1.0, "#{label}: recompute ratio #{r[:ratio_pct]} != emitted #{emitted.fetch("pss_ratio_percent")}")
    assert!((r[:saving] - emitted.fetch("absolute_saving_mb")).abs <= 1.5, "#{label}: recompute saving #{r[:saving]} != emitted #{emitted.fetch("absolute_saving_mb")}")
    assert!((r[:reach_pct] - emitted.fetch("throughput_reach_percent")).abs <= 1.0, "#{label}: recompute reach #{r[:reach_pct]} != emitted #{emitted.fetch("throughput_reach_percent")}")
  end
  if emitted.dig("strongest_baseline", "model")
    assert!(r[:smodel] == emitted.dig("strongest_baseline", "model"), "#{label}: recompute strongest baseline #{r[:smodel]} != emitted #{emitted.dig("strongest_baseline", "model")}")
  end
  if emitted["adversarial_baseline"]
    assert!(r[:amodel] == emitted.dig("adversarial_baseline", "model"), "#{label}: recompute adversarial baseline #{r[:amodel]} != emitted #{emitted.dig("adversarial_baseline", "model")}")
  end
  if emitted["ractor_wins_at_workers"]
    assert!(r[:wins].sort == Array(emitted.fetch("ractor_wins_at_workers")).sort, "#{label}: recompute wins #{r[:wins].inspect} != emitted #{emitted.fetch("ractor_wins_at_workers").inspect}")
  end
  r
end

# Phase 3 full verifier. Always self-tests the recompute engine against the reduced evidence. When a COMPLETED full-host
# run exists (manifest status=complete + final results.json, atomic-renamed from .partial), it validates it INDEPENDENTLY:
# config/SHA/Linux, per-cell cross-check, and a recompute of every verdict that rejects any survives leaning on
# extrapolation / median-only / straddle / missing cell / stale runner. It NEVER flips economic_final_gate_passed — that
# promotion stays a deliberate manual decision once a real full run validates.
def check_strong_host_gate_v2_full(checks)
  pinned_sha = STRONG_GATE_V2_RUNNER_SHA256.fetch("strong_host_gate_v2.rb")

  # SELF-TEST (always): the engine MUST reproduce the runner's EMITTED reduced verdicts, proving it is live and correct
  # before it is trusted to gate any full run — and closing F1 for the reduced evidence too.
  reduced = read_json("phase3_migration/raw_logs/strong_gate_v2_reduced.json")
  rgates = reduced.fetch("gates")
  rcells = reduced.fetch("cells").group_by { |c| [c["shape"], c["dataset_target_mb"], c["alloc"]] }
  reduced.fetch("verdicts").each do |v|
    sg_assert_recompute_matches!(v, rcells.fetch([v["shape"], v["dataset_target_mb"], v["alloc"]]), rgates, "reduced self-test alloc=#{v["alloc"]}")
  end

  # locate COMPLETED full runs (manifest complete + final results.json; a bare .partial = aborted and is never accepted)
  full_dir = relative_file(STRONG_GATE_V2_FULL_RUNS_DIR)
  completed = []
  if File.directory?(full_dir)
    Dir.children(full_dir).sort.each do |rid|
      rd = File.join(full_dir, rid)
      next unless File.directory?(rd)
      manifest = File.join(rd, "manifest.json"); results = File.join(rd, "results.json")
      next unless File.file?(manifest) && File.file?(results)
      manifest_data = JSON.parse(File.read(manifest, encoding: "UTF-8"))
      completed << [rid, rd, results, manifest_data] if manifest_data["status"] == "complete"
    end
  end

  if completed.empty?
    checks << { name: "strong_host_gate_v2_full", status: "pass",
                full_artifact_present: false, recompute_engine_self_test: "pass",
                note: "no completed full-host run yet (BLOCKED_BY_HOST_LINUX); recompute engine validated against reduced; economic_final_gate stays false" }
    return
  end

  validated = completed.map do |rid, rd, results, manifest|
    data = JSON.parse(File.read(results, encoding: "UTF-8"))
    gates = data.fetch("gates")
    assert!(manifest.fetch("mode") == "full", "full run #{rid}: manifest mode must be full, got #{manifest.fetch("mode").inspect}")
    assert!(manifest.fetch("host_class") == "DEDICATED_LINUX_HOST",
            "full run #{rid}: manifest host_class must be DEDICATED_LINUX_HOST, got #{manifest.fetch("host_class").inspect} (Colima/undersized/override runs are diagnostics, not full economic evidence)")
    assert!(manifest.fetch("runner_sha256") == pinned_sha, "full run #{rid}: manifest runner_sha256 != pin")
    assert!(data.fetch("run_class") == "full_host", "full run #{rid}: run_class must be full_host, got #{data.fetch("run_class").inspect}")
    assert!(data.fetch("platform").end_with?("linux"), "full run #{rid}: must be a Linux run")
    assert!(data.fetch("ruby").include?("4.0."), "full run #{rid}: must be Ruby 4.0.x")
    assert!(data.fetch("runner_sha256") == pinned_sha, "full run #{rid}: runner_sha256 != pin (stale/unpinned runner)")
    cfg = data.fetch("config")
    STRONG_GATE_V2_FULL_CONFIG.each { |k, want| assert!(cfg.fetch(k) == want, "full run #{rid}: config #{k} #{cfg.fetch(k).inspect} != #{want.inspect}") }
    assert!(cfg.fetch("reps") >= 6, "full run #{rid}: reps must be >= 6, got #{cfg.fetch("reps")}")
    assert!(cfg.fetch("duration_s") >= 8, "full run #{rid}: duration_s must be >= 8, got #{cfg.fetch("duration_s")}")

    cells = data.fetch("cells")
    roster = STRONG_GATE_V2_REDUCED_MODELS.sort
    expected = STRONG_GATE_V2_FULL_CONFIG.values_at("shapes", "targets_mb", "allocs", "workers").map(&:size).reduce(:*) * roster.size
    assert!(cells.size == expected, "full run #{rid}: expected #{expected} cells, got #{cells.size}")
    # every cell must itself be a Linux/Ruby-4.0.5 full_host cell (top-level labels are not enough — a cell can lie)
    cells.each do |c|
      assert!(c.fetch("run_class") == "full_host", "full run #{rid}: a cell has run_class #{c.fetch("run_class").inspect}, expected full_host")
      assert_linux_ruby_cell!(c, "full run #{rid} cell")
    end
    # EXACT grid coverage (closes duplicate-one/drop-one and missing-strongest-baseline): the distinct shape/target/alloc/
    # workers present must equal the declared config, and EVERY (shape,target,alloc,workers) tuple must carry precisely the
    # 7-model roster once. cells.size alone cannot catch a duplicated cell masking a dropped (e.g. strongest) baseline.
    { "shape" => "shapes", "dataset_target_mb" => "targets_mb", "alloc" => "allocs", "workers" => "workers" }.each do |field, ck|
      assert!(cells.map { |c| c.fetch(field) }.uniq.sort == STRONG_GATE_V2_FULL_CONFIG.fetch(ck).sort,
              "full run #{rid}: distinct #{field} #{cells.map { |c| c.fetch(field) }.uniq.sort.inspect} != config #{STRONG_GATE_V2_FULL_CONFIG.fetch(ck).inspect}")
    end
    cells.group_by { |c| c.values_at("shape", "dataset_target_mb", "alloc", "workers") }.each do |tuple, group|
      assert!(group.map { |c| c.fetch("model") }.sort == roster,
              "full run #{rid}: tuple #{tuple.inspect} roster #{group.map { |c| c.fetch("model") }.sort.inspect} != #{roster.inspect} (duplicated/dropped model)")
    end
    # per-cell cross-check is MANDATORY (a missing cells/ dir must NOT silently skip it, unlike a forgeable optional path)
    cell_dir = File.join(rd, "cells")
    assert!(File.directory?(cell_dir), "full run #{rid}: per-cell cells/ dir is missing — required, not optional")
    cell_fname = ->(c) { "#{c.fetch("shape")}_t#{c.fetch("dataset_target_mb").to_i}_a#{c.fetch("alloc")}_w#{c.fetch("workers")}_#{c.fetch("model")}.json" }
    want_files = cells.map(&cell_fname).sort
    got_files = Dir.children(cell_dir).select { |f| f.end_with?(".json") }.sort
    assert!(got_files == want_files, "full run #{rid}: per-cell dir mismatch missing #{(want_files - got_files).inspect} extra #{(got_files - want_files).inspect}")
    cells.each do |c|
      pc = JSON.parse(File.read(File.join(cell_dir, cell_fname.call(c)), encoding: "UTF-8"))
      assert!(pc == c, "full run #{rid}: per-cell #{cell_fname.call(c)} diverges from its aggregate record")
    end

    cells_by = cells.group_by { |c| [c["shape"], c["dataset_target_mb"], c["alloc"]] }
    survives = 0
    data.fetch("verdicts").each do |v|
      label = "full #{rid} #{v["shape"]} t#{v["dataset_target_mb"]} a#{v["alloc"]}"
      r = sg_assert_recompute_matches!(v, cells_by.fetch([v["shape"], v["dataset_target_mb"], v["alloc"]]), gates, label)
      next unless v["status"] == "survives"
      survives += 1
      assert!(!r[:extrapolated], "#{label}: a survives must NOT be extrapolated")
      assert!(!r[:wins].empty?, "#{label}: a survives must have a PESSIMISTIC per-worker win (no median-only)")
      assert!(r[:gate_states].values.all? { |s| s == "pass" }, "#{label}: a survives requires every recomputed gate_state=pass")
    end
    { run_id: rid, cells: cells.size, survives: survives }
  end

  checks << { name: "strong_host_gate_v2_full", status: "pass",
              full_artifact_present: true, recompute_engine_self_test: "pass", validated_runs: validated }
end

def current_project_verdict(checks)
  economic = checks.find { |check| check.fetch(:name) == "economic_gate" }
  a2 = checks.find { |check| check.fetch(:name) == "a2_sync_gateway" }
  migration = checks.find { |check| check.fetch(:name) == "discourse_migration_artifacts" }
  benchmark = checks.find { |check| check.fetch(:name) == "promotion_benchmark" }
  amortization = checks.find { |check| check.fetch(:name) == "promotion_amortization" }
  write_side_spec = checks.find { |check| check.fetch(:name) == "promotion_write_side_spec" }
  strong = checks.find { |check| check.fetch(:name) == "strong_host_gate_v2_reduced" }
  strong_full = checks.find { |check| check.fetch(:name) == "strong_host_gate_v2_full" }

  assert!(economic, "current verdict missing economic gate")
  assert!(a2, "current verdict missing A2 gateway")
  assert!(migration, "current verdict missing Discourse migration artifacts")
  assert!(benchmark, "current verdict missing Promotion benchmark")
  assert!(amortization, "current verdict missing Promotion amortization")
  assert!(write_side_spec, "current verdict missing Promotion write-side spec")
  assert!(strong, "current verdict missing strong host gate v2 reduced")
  assert!(strong_full, "current verdict missing strong host gate v2 full check")

  economic_statuses = economic.fetch(:all_shape_statuses).values.flat_map(&:values)
  struct_statuses = economic.fetch(:struct_stability_statuses).values

  {
    status: "pivot",
    reason: "current evidence supports narrow compatibility research, not a product/runtime continue",
    promotion_scope: migration.fetch(:promotion_write_side_classification),
    promotion_patch_files: migration.fetch(:promotion_patch).fetch(:changed_files),
    promotion_benchmark_owner_ratio: benchmark.fetch(:ratios).fetch("owner_snapshot_build_plus_decide_vs_inline"),
    guardian: "structural_non_fit",
    report: migration.fetch(:report_classification),
    economic_survives_any_current_matrix: economic_statuses.include?("survives") || struct_statuses.include?("survives"),
    struct_rerun_status: economic.fetch(:struct_rerun).fetch(:status),
    economic_final_gate_passed: false,
    a2_all_cells_fail: a2.fetch(:failures) == a2.fetch(:cells),
    a2_chatty_sync_is_killer: a2.fetch(:chatty_all_fail),
    a2_tolerable_cell_count: a2.fetch(:passes),
    a2_aggressive_control_all_fail: a2.fetch(:aggressive_control_all_fail),
    promotion_amortizes: amortization.fetch(:any_real_variant_amortizes),
    promotion_amortization_classification: amortization.fetch(:classification),
    promotion_write_side_spec_classification: write_side_spec.fetch(:classification),
    promotion_write_side_effect_intents_required: write_side_spec.fetch(:effect_intents_required).size,
    full_discourse_write_side_outbox_validated: false,
    strong_gate_v2_full_host_run: strong_full.fetch(:full_artifact_present),
    strong_gate_v2_full_recompute_self_test: strong_full.fetch(:recompute_engine_self_test),
    strong_gate_v2_full_validated_runs: (strong_full[:validated_runs] || []).size,
    strong_gate_v2_run_class: strong.fetch(:run_class),
    strong_gate_v2_reduced_alloc0_control: strong.fetch(:alloc0_control_status),
    strong_gate_v2_reduced_alloc100: strong.fetch(:alloc100_status),
    strong_gate_v2_reduced_alloc100_single_operating_point: strong.fetch(:alloc100_win_is_single_operating_point),
    advance_to_gem_or_dsl: false,
  }
end

checks = []
check_economic_gate(checks)
check_environment_proof(checks)
check_capsule_hostility_audit(checks)
check_a2_gateway(checks)
check_outbox(checks)
check_transaction_suite_logs(checks)
check_promotion_benchmark(checks)
check_promotion_amortization(checks)
check_discourse_migration_artifacts(checks)
check_promotion_write_side_spec(checks)
check_lease_ratification_docs(checks)
check_findings_mentions(checks)
check_findings_current_verdict_text(checks)
check_findings_promotion_benchmark_text(checks)
check_strong_host_gate_v2_reduced(checks)
check_strong_host_gate_v2_full(checks)
verdict = current_project_verdict(checks)

summary = {
  generated_at_utc: Time.now.utc.iso8601,
  status: "pass",
  current_project_verdict: verdict,
  checks: checks,
}

if JSON_OUT
  out = File.expand_path(JSON_OUT, ROOT)
  assert!(out.start_with?("#{RAW_DIR}/"), "JSON_OUT must live under #{RAW_DIR}")
  File.write(out, JSON.pretty_generate(summary))
end

puts "FINDINGS EVIDENCE CHECK PASS"
checks.each { |check| puts "- #{check.fetch(:name)}: #{check.fetch(:status)}" }
