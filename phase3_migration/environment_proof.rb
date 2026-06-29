# frozen_string_literal: true

# Machine-readable environment proof for the Phase 3 evidence bundle.
# This is not a setup script. It records the exact local runtimes and DB targets
# used by the current artifacts so FINDINGS cannot rely on stale environment prose.
require "json"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
PHASE3 = File.join(ROOT, "phase3_migration")
RAW_DIR = File.join(PHASE3, "raw_logs")
DISCOURSE = File.join(PHASE3, "discourse")
MINI_RAILS = File.join(ROOT, "rails_capsule_mini_app")
SLICE_B = File.join(ROOT, "rails_capsule_slice_b")
JSON_OUT = ENV["JSON_OUT"]

def rel(path)
  File.expand_path(path).sub("#{ROOT}/", "")
end

def command_entry(name, argv, cwd: ROOT, env: {})
  stdout, stderr, status = Open3.capture3(env, *argv, chdir: cwd)
  {
    "name" => name,
    "cwd" => rel(cwd),
    "argv" => argv,
    "exitstatus" => status.exitstatus,
    "success" => status.success?,
    "stdout" => stdout,
    "stderr" => stderr,
  }
end

def ruby_eval(code)
  [RbConfig.ruby, "-e", code]
end

commands = []

commands << command_entry("host_ruby_v", [RbConfig.ruby, "-v"])
commands << command_entry("host_bundle_v", ["bundle", "-v"])
commands << command_entry("host_ruby_description", ruby_eval("puts RUBY_DESCRIPTION"))
commands << command_entry("docker_version", ["docker", "--version"])

commands << command_entry("discourse_head", ["git", "rev-parse", "HEAD"], cwd: DISCOURSE)
commands << command_entry("discourse_branch", ["git", "branch", "--show-current"], cwd: DISCOURSE)
commands << command_entry("discourse_status_short", ["git", "status", "--short"], cwd: DISCOURSE)

commands << command_entry("container_pg_isready_capsule_test", ["docker", "exec", "capsule_pg", "pg_isready", "-U", "capsule", "-d", "capsule_test"])
commands << command_entry("container_pg_isready_capsule_railsapp_test", ["docker", "exec", "capsule_pg", "pg_isready", "-U", "capsule", "-d", "capsule_railsapp_test"])
commands << command_entry("container_psql_version", ["docker", "exec", "capsule_pg", "psql", "--version"])
commands << command_entry(
  "container_pg_databases",
  [
    "docker", "exec", "capsule_pg", "psql", "-U", "capsule", "-d", "capsule_test", "-Atc",
    "select datname from pg_database where datname in ('capsule_test','capsule_railsapp_test','capsule_railsapp') order by 1",
  ],
)
commands << command_entry(
  "container_pg_server_version",
  [
    "docker", "exec", "capsule_pg", "psql", "-U", "capsule", "-d", "capsule_test", "-Atc",
    "select current_database() || '|' || current_setting('server_version')",
  ],
)

commands << command_entry("mini_rails_ruby_v", [RbConfig.ruby, "-v"], cwd: MINI_RAILS)
commands << command_entry("mini_rails_bundle_v", ["bundle", "-v"], cwd: MINI_RAILS)
commands << command_entry("mini_rails_rails_v", ["bundle", "exec", "rails", "-v"], cwd: MINI_RAILS, env: { "RAILS_ENV" => "test" })
commands << command_entry(
  "mini_rails_boot_probe",
  ["bundle", "exec", *ruby_eval(<<~'RUBY')],
    require_relative "config/environment"
    puts "ruby=#{RUBY_DESCRIPTION}"
    puts "rails=#{Rails.version}"
    puts "active_record=#{ActiveRecord.version}"
    puts "eager_load=#{Rails.application.config.eager_load}"
    puts "cache_class=#{Rails.cache.class.name}"
    puts "database=#{ActiveRecord::Base.connection_db_config.database}"
    puts "server_version=#{ActiveRecord::Base.connection.select_value('select version()')}"
  RUBY
  cwd: MINI_RAILS,
  env: { "RAILS_ENV" => "test" },
)

slice_env = { "DATABASE_URL" => "postgres://capsule:capsule@127.0.0.1:65432/capsule_test" }
commands << command_entry("slice_b_ruby_v", [RbConfig.ruby, "-v"], cwd: SLICE_B, env: slice_env)
commands << command_entry("slice_b_bundle_v", ["bundle", "-v"], cwd: SLICE_B, env: slice_env)
commands << command_entry(
  "slice_b_ar_postgres_probe",
  ["bundle", "exec", *ruby_eval(<<~'RUBY')],
    require_relative "boot"
    puts "ruby=#{RUBY_DESCRIPTION}"
    puts "active_record=#{ActiveRecord.version}"
    puts "database=#{ActiveRecord::Base.connection_db_config.database}"
    puts "server_version=#{ActiveRecord::Base.connection.select_value('select version()')}"
  RUBY
  cwd: SLICE_B,
  env: slice_env,
)

required = %w[
  host_ruby_v
  host_bundle_v
  host_ruby_description
  discourse_head
  discourse_status_short
  container_pg_isready_capsule_test
  container_pg_isready_capsule_railsapp_test
  container_psql_version
  container_pg_databases
  container_pg_server_version
  mini_rails_rails_v
  mini_rails_boot_probe
  slice_b_ar_postgres_probe
]

by_name = commands.to_h { |entry| [entry.fetch("name"), entry] }
missing = required - by_name.keys
failed = required.select { |name| !by_name.fetch(name).fetch("success") }
status = missing.empty? && failed.empty? ? "pass" : "fail"

summary = {
  "generated_at_utc" => Time.now.utc.iso8601,
  "status" => status,
  "required" => required,
  "missing" => missing,
  "failed" => failed,
  "commands" => commands,
}

if JSON_OUT
  out = File.expand_path(JSON_OUT, ROOT)
  raise "JSON_OUT must live under #{RAW_DIR}" unless out.start_with?("#{RAW_DIR}/")

  File.write(out, JSON.pretty_generate(summary))
end

puts "ENVIRONMENT PROOF #{status.upcase}"
commands.each do |entry|
  puts "- #{entry.fetch("name")}: #{entry.fetch("success") ? "ok" : "FAIL"}"
end
exit(status == "pass" ? 0 : 1)
