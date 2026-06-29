# frozen_string_literal: true

# Phase 3 — reproducible capsule-hostility audit of real Discourse services.
# Deterministic static counts (no Discourse boot needed). Run:
#   ruby phase3_migration/audit.rb [path-to-discourse]   # default: ./discourse next to this script
# Emits JSON to stdout. Counts are orientation metrics; the migration patch + Ractor proof are the evidence.
require "digest"
require "json"
require "open3"

ROOT = File.expand_path(ARGV[0] || File.join(__dir__, "discourse"))
abort("discourse checkout not found at #{ROOT}") unless File.directory?(ROOT)
SOURCE_REF = ENV.fetch("AUDIT_SOURCE_REF", "HEAD")
BLOB_CACHE = {}
TRACKED_FILES_CACHE = {}

def git_capture(*args)
  Dir.chdir(ROOT) { Open3.capture3("git", *args) }
end

def repo_rel(file) = file.sub("#{ROOT}/", "")

def tracked_files
  TRACKED_FILES_CACHE.fetch(SOURCE_REF) do
    out, err, status = git_capture("ls-tree", "-r", "--name-only", SOURCE_REF, "--")
    raise "could not list #{SOURCE_REF}: #{err}" unless status.success?

    TRACKED_FILES_CACHE[SOURCE_REF] = out.lines.map(&:strip).reject(&:empty?)
  end
end

def slurp(f)
  rel = repo_rel(f)
  return BLOB_CACHE.fetch(rel) if BLOB_CACHE.key?(rel)

  out, err, status = git_capture("show", "#{SOURCE_REF}:#{rel}")
  raise "could not read #{SOURCE_REF}:#{rel}: #{err}" unless status.success?

  BLOB_CACHE[rel] = out.force_encoding("UTF-8").scrub
end
def rel(*globs)
  tracked_files
    .select { |path| globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) } }
    .sort
    .map { |path| File.join(ROOT, path) }
end

def app_lib_ruby_files
  tracked_files
    .select { |path| path.end_with?(".rb") && path.match?(%r{\A(app|lib)/}) }
    .sort
    .map { |path| File.join(ROOT, path) }
end

def read_all(files) = files.map { |f| slurp(f) }.join("\n")
def count(text, re) = text.scan(re).size

# files anywhere under app/ or lib/ that reference a pattern, + total occurrences
def call_sites(re)
  hit_files = 0
  occurrences = 0
  app_lib_ruby_files.each do |f|
    n = slurp(f).scan(re).size
    next if n.zero?
    hit_files += 1
    occurrences += n
  end
  { files: hit_files, occurrences: occurrences }
end

SIDE_EFFECT_RE =
  /
    \b(create!|update!|save!|destroy!|delete_all|update_all|update_column)\b |
    \b(enqueue|perform_async|deliver_later|deliver_now|publish)\b |
    DiscourseEvent\.trigger |
    BadgeGranter\.queue_badge_grant |
    UserHistory\.create! |
    Group\.user_trust_level_change! |
    StaffActionLogger
  /x

# Loose ORIENTATION label only, NOT a capsule-fit verdict. `callbacks_or_procs.zero?` (the OR-branch below) does NOT
# prove capsule-compatibility, so the `fit` bucket in auto_candidates can over-count false positives. The authoritative
# fit/non-fit is the manual per-service proof (guardian_non_fit_proof.rb / report_partial_proof.rb / the migration patch
# + Ractor proof), never this heuristic. The PIVOT verdict does not rest on this label.
def candidate_for(metrics)
  return "non_fit" if metrics[:held_ar_state_refs].positive? && metrics[:ar_queries] + metrics[:db_queries] > 10
  return "partial" if metrics[:rails_cache_reads] + metrics[:redis_reads] + metrics[:db_queries] + metrics[:ar_queries] > 0
  return "fit" if metrics[:site_setting_reads].positive? || metrics[:callbacks_or_procs].zero?
  "partial"
end

def reasons_for(metrics)
  reasons = []
  reasons << "large call-site surface" if metrics[:call_sites] > 100
  reasons << "held mutable @user/@state references" if metrics[:held_ar_state_refs].positive?
  reasons << "live AR/DB reads" if metrics[:ar_queries] + metrics[:db_queries] > 0
  reasons << "Rails/Discourse cache or Redis global" if metrics[:rails_cache_reads] + metrics[:redis_reads] > 0
  reasons << "SiteSetting global reads" if metrics[:site_setting_reads] > 0
  reasons << "side-effect calls in service body" if metrics[:side_effect_calls].any?
  reasons << "callbacks/procs/dynamic blocks" if metrics[:callbacks_or_procs] > 0
  reasons
end

def side_effect_calls(text)
  text.lines.grep(SIDE_EFFECT_RE).map(&:strip).uniq.first(25)
end

def source_hashes(files)
  files.to_h { |file| [repo_rel(file), Digest::SHA256.hexdigest(slurp(file))] }
end

def profile(files, call_re)
  t = read_all(files)
  cs = call_sites(call_re)
  metrics = {
    files: files.map { |f| repo_rel(f) },
    source_sha256_by_file: source_hashes(files),
    loc: t.lines.size,
    call_site_files: cs[:files],
    call_site_occurrences: cs[:occurrences],
    call_sites: cs[:occurrences],
    site_setting_reads: count(t, /SiteSetting\./),
    rails_cache_reads: count(t, /Rails\.cache|Discourse\.cache/),
    rails_logger_reads: count(t, /Rails\.logger/),
    redis_reads: count(t, /Discourse\.redis|\.redis\b/),
    metrics_reads: 0,
    i18n_reads: count(t, /\bI18n\./),
    current_reads: count(t, /\bCurrent\.|CurrentUser|current_user/),
    discourse_globals: count(t, /Discourse\.(redis|cache|current_user_provider|system_user|base_url|store)/),
    rails_globals: count(t, /Rails\.(cache|logger|application)/),
    ar_queries: count(t, /\.(where|find_by|find_each|pluck|exists\?|joins|includes)\(/),
    db_queries: count(t, /\bDB\.(query|exec|query_single|query_hash|build)/),
    db_query: count(t, /\bDB\.(query|exec|query_single|query_hash|build)/),
    callbacks_or_procs: count(t, /(\block\b|\blambda\b|\bproc\b|-> ?\(|define_method|instance_eval)/),
    native_ext_touches: count(t, /\b(Nokogiri|PrettyText|MiniRacer|Onebox|ImageMagick|FastImage)\b/),
    held_ar_state_refs: count(t, /@(user|guardian|current_user|topic|post|category)\b/),
    held_user_refs: count(t, /@user\b/),
    side_effect_calls: side_effect_calls(t),
    def_methods: count(t, /^\s+def /),
    can_is_predicates: count(t, /def (can_|is_)[a-z_?]+/),
    blocks_procs: count(t, /(\block\b|\blambda\b|\bproc\b|-> ?\()/),
  }
  metrics[:candidate] = candidate_for(metrics)
  metrics[:reasons] = reasons_for(metrics)
  metrics
end

def auto_candidates(existing)
  files = rel("app/models/**/*.rb", "app/services/**/*.rb", "lib/**/*.rb")
  scored =
    files.reject { |f| existing.include?(f) }
      .map do |f|
        t = slurp(f)
        next if t.lines.size < 40

        pure_rule_signals = count(t, /SiteSetting\.|TrustLevel|Requirement|Policy|Rule|Guardian|Report/)
        live_penalty = count(t, /@(user|topic|post|guardian)\b|\bDB\.|\.(where|joins|pluck|find_by)\(/)
        cache_signal = count(t, /Discourse\.cache|Rails\.cache/)
        score = pure_rule_signals + cache_signal - live_penalty
        [score, f]
      end
      .compact
      .sort_by { |score, f| [-score, f] }
      .first(3)

  scored.map do |_score, f|
    base = File.basename(f, ".rb")
    key = "candidate_#{base.gsub(/[^a-zA-Z0-9]+/, "_")}".downcase.to_sym
    [key, profile([f], /#{Regexp.escape(File.basename(f, ".rb").split("_").map(&:capitalize).join)}\.|#{Regexp.escape(base)}/)]
  end.to_h
end

def build_report
  commit, err, status = git_capture("rev-parse", SOURCE_REF)
  raise "could not resolve #{SOURCE_REF}: #{err}" unless status.success?

  fixed_files = rel("lib/guardian.rb", "lib/guardian/*.rb", "app/models/report.rb", "lib/promotion.rb")

  {
    generated_against_commit: commit.strip,
    source_ref: SOURCE_REF,
    source_mode: "git_show+git_ls_tree",
    discourse_path: ROOT,
    services: {
      guardian: profile(rel("lib/guardian.rb", "lib/guardian/*.rb"),
                        /guardian\.(can_|is_)[a-z_?]+|Guardian\.new|@guardian\b/),
      report: profile(rel("app/models/report.rb"),
                      /Report\.(find|new|_get|run|find_cached)/),
      promotion: profile(rel("lib/promotion.rb"),
                         /Promotion\.(new|review|recalculate)/),
    }.merge(auto_candidates(fixed_files)),
  }
end

puts JSON.pretty_generate(build_report) if $PROGRAM_NAME == __FILE__
