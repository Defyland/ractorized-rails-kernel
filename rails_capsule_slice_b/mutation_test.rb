# frozen_string_literal: true

# Reviewer #14 — mutation tests. Break the code on purpose and prove the suite has teeth.
# For each mutation: confirm the guard test is GREEN at baseline, apply the mutation IN PLACE,
# confirm the guard test goes RED (the defect is caught), then restore the file verbatim.
# A mutation that SURVIVES (suite stays green) is a weak-suite failure.
require "rbconfig"

SLICE = __dir__
DB = ENV.fetch("MUT_DB_URL", "postgres://capsule:capsule@127.0.0.1:65432/capsule_mut")

MUTATIONS = [
  { name: "remove outbox unique index",
    file: "schema.rb",
    from: 't.index :idempotency_key, unique: true        # exactly-once ENQUEUE (real unique constraint)',
    to:   't.index :idempotency_key, unique: false       # MUTATED: unique constraint removed',
    test: "test/slice_b_test.rb", only: "test_idempotency_key_is_unique" },
  { name: "disable lock_version (AR optimistic locking)",
    file: "schema.rb",
    from: 't.integer :lock_version, null: false, default: 0  # AR optimistic locking (magic column name)',
    to:   't.integer :lock_version_off, null: false, default: 0  # MUTATED: AR no longer sees lock_version',
    test: "test/slice_b_test.rb", only: "test_commit_conflict_drops_outbox" },
  { name: "SKIP LOCKED -> plain FOR UPDATE",
    file: "capsule.rb",
    from: '.lock("FOR UPDATE SKIP LOCKED")',
    to:   '.lock("FOR UPDATE")',
    test: "test/falsify_skip_locked.rb", only: nil },
  { name: "non-deterministic idempotency_key (random per call)",
    file: "capsule.rb",
    from: 'idempotency_key: "charge-#{order_id}-#{request_id}",',
    to:   'idempotency_key: "charge-#{order_id}-#{request_id}-#{rand(1_000_000)}",  # MUTATED',
    test: "test/falsify_request_id_contract.rb", only: nil },
  { name: "dispatcher skips delivery",
    file: "capsule.rb",
    from: 'ExternalConsumer.deliver!(event)        # external system: its OWN commit (idempotent on idk)',
    to:   '# MUTATED: ExternalConsumer.deliver!(event) skipped',
    test: "test/falsify_crash_windows.rb", only: "test_crash_A_before_delivery_is_recoverable" },
]

def run_guard(test, only)
  args = ["bundle", "exec", "ruby", test]
  args += ["-n", only] if only
  env = { "DATABASE_URL" => DB, "PATH" => "/opt/homebrew/opt/ruby/bin:#{ENV['PATH']}" }
  out = IO.popen(env, args, chdir: SLICE, err: %i[child out], &:read)
  [out, $?.exitstatus]
end

def summary(out)
  out.lines.reverse.find { |l| l.match?(/runs,.*assertions/) }&.strip || out.lines.last&.strip
end

ok = true
MUTATIONS.each_with_index do |m, i|
  path = File.join(SLICE, m[:file])
  original = File.read(path)
  unless original.include?(m[:from])
    puts "MUT #{i + 1} #{m[:name]}: STALE from-string in #{m[:file]} -> harness error"
    ok = false
    next
  end

  base_out, base_code = run_guard(m[:test], m[:only])
  File.write(path, original.sub(m[:from], m[:to]))
  begin
    mut_out, mut_code = run_guard(m[:test], m[:only])
  ensure
    File.write(path, original) # ALWAYS restore verbatim
  end

  caught = base_code.zero? && mut_code != 0
  ok &&= caught
  puts "MUT #{i + 1}: #{m[:name]}"
  puts "   guard   : #{m[:test]}#{m[:only] ? " -n #{m[:only]}" : ''}"
  puts "   baseline: exit=#{base_code}  #{summary(base_out)}"
  puts "   mutated : exit=#{mut_code}  #{summary(mut_out)}"
  puts "   => #{caught ? 'CAUGHT (suite turned RED)' : 'SURVIVED — WEAK SUITE'}"
  puts
end

puts(ok ? "MUTATION SUITE OK: every mutation was caught (the tests have teeth)" : "MUTATION SUITE FAIL")
exit(ok ? 0 : 1)
