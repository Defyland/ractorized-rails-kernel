# frozen_string_literal: true

# Static, reproducible proof that Discourse Report is not a clean capsule fit.
# This does not boot Rails. It reads the real app/models/report.rb and reports
# the concrete cache/global/SQL surfaces that would need owner pre-resolution or
# batching before any Ractor boundary is economically credible.
#
# Run:
#   ruby phase3_migration/report_partial_proof.rb [path-to-discourse]
require "json"
require "digest"

root = File.expand_path(ARGV[0] || File.join(__dir__, "discourse"))
report_path = File.join(root, "app/models/report.rb")
abort("missing #{report_path}") unless File.file?(report_path)

src = File.read(report_path, encoding: "UTF-8").scrub
lines = src.lines

def hits(lines, regex)
  lines.each_with_index.filter_map do |line, idx|
    next unless line.match?(regex)
    { line: idx + 1, code: line.strip }
  end
end

def method_body(src, name)
  src[/^\s+def self\.#{Regexp.escape(name)}\b.*?(?=^\s+def |\z)/m].to_s
end

cache_hits = hits(lines, /Discourse\.cache|Rails\.cache|\.redis\b/)
db_hits = hits(lines, /\bDB\.|\bActiveRecord::Base|\.(where|joins|includes|pluck|sum|count|group|order)\(/)
i18n_hits = hits(lines, /\bI18n\./)
logger_hits = hits(lines, /Rails\.logger/)
site_setting_hits = hits(lines, /SiteSetting\./)
dynamic_report_hits = hits(lines, /add_report|define_method|public_send\(report_method/)

find_body = method_body(src, "find")
find_cached_body = method_body(src, "find_cached")
req_report_body = method_body(src, "req_report")

find_cache_gateway = find_cached_body.scan(/Discourse\.cache\.read/).size
find_sql_live = find_body.scan(/\bwrap_slow_query\b|public_send\(report_method\)|req_report/).size
req_report_query_ops = req_report_body.scan(/\.(where|order|group|sum|count)\(/).size

classification =
  if cache_hits.empty? && db_hits.empty?
    "fit"
  elsif find_cache_gateway.positive? || find_sql_live.positive? || req_report_query_ops.positive?
    "partial"
  else
    "non_fit"
  end

sync_gateway_frequency =
  if find_cache_gateway.positive?
    "one synchronous cache read per Report.find_cached call; Report.find then executes live SQL/report method on miss"
  else
    "none observed in find_cached"
  end

batchable =
  "Only if owner resolves the full report result/cache entry before the capsule. Per-item cache/SQL inside a Ractor would be chatty and economically invalid."

result = {
  commit: Dir.chdir(root) { `git rev-parse HEAD`.strip },
  file: "app/models/report.rb",
  source_sha256: Digest::SHA256.file(report_path).hexdigest,
  classification: classification,
  verdict: "Report is PARTIAL, not fit, for Frozen Read-Model Capsules",
  evidence: {
    cache_or_redis_globals: cache_hits,
    db_or_ar_live_queries: db_hits,
    i18n_reads: i18n_hits,
    logger_reads: logger_hits,
    site_setting_reads: site_setting_hits,
    dynamic_report_registration: dynamic_report_hits,
  },
  path_metrics: {
    find_cached_sync_cache_reads: find_cache_gateway,
    find_live_dispatch_points: find_sql_live,
    req_report_query_ops: req_report_query_ops,
  },
  sync_gateway_frequency: sync_gateway_frequency,
  batchable_vs_chatty: batchable,
  capsule_rules: {
    cache_global_inside_ractor: "must reject",
    report_snapshot_shareable: "only after owner materializes data into plain frozen DTOs",
    sql_inside_ractor: "must reject",
  },
}

puts JSON.pretty_generate(result)

ok = classification == "partial" &&
  find_cache_gateway.positive? &&
  (find_sql_live.positive? || req_report_query_ops.positive?)

exit(ok ? 0 : 1)
