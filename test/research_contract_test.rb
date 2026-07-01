# frozen_string_literal: true

require_relative "test_helper"

class ResearchContractTest < Minitest::Test
  HEURISTIC_KEYWORDS = /\b(http|api|server|service|endpoint|railway)\b/i

  def test_top_level_architecture_doc_exists
    assert root_path("docs/architecture.md").file?, "expected docs/architecture.md"
  end

  def test_architecture_doc_maps_the_evidence_layers
    architecture = read_file("docs/architecture.md")

    assert_includes architecture, "Phase 1: Economic Gates"
    assert_includes architecture, "Phase 2: Owner-Side Rails Protocol"
    assert_includes architecture, "Phase 2b: Booted Rails Capsule Proof"
    assert_includes architecture, "Phase 3: Promotion Audit"
    assert_includes architecture, "phase3_migration/FINDINGS.md"
  end

  def test_root_check_script_runs_each_fast_proof_surface
    check_script = read_file("bin/check")

    assert_includes check_script, "ruby -Itest test/research_contract_test.rb"
    assert_includes check_script, "day1_smoke_test.rb"
    assert_includes check_script, "rails_capsule_mini_app"
    assert_includes check_script, "rails_capsule_slice_b"
  end

  def test_research_check_surfaces_the_optional_deep_audit
    research_check = read_file("bin/research-check")
    verifier = read_file("phase3_migration/verify_findings_evidence.rb")

    assert_includes research_check, "verify_findings_evidence.rb"
    assert_includes research_check, 'DISCOURSE_DIR="${DISCOURSE_DIR:-phase3_migration/discourse}"'
    assert_includes research_check, 'DISCOURSE_DIR="$DISCOURSE_DIR" JSON_OUT="$JSON_OUT" ruby phase3_migration/verify_findings_evidence.rb'
    assert_includes research_check, "Set DISCOURSE_DIR=/absolute/path/to/discourse"
    assert_includes research_check, "public fast contract"
    assert_includes verifier, 'ENV.fetch("DISCOURSE_DIR", File.join(PHASE3, "discourse"))'
  end

  def test_slice_b_runner_accepts_external_database_url
    runner = read_file("rails_capsule_slice_b/run.sh")

    assert_includes runner, 'if [[ -n "${DATABASE_URL:-}" ]]; then'
    assert_includes runner, "skipping Docker bootstrap"
  end

  def test_mini_app_accepts_test_database_url_override
    database_config = read_file("rails_capsule_mini_app/config/database.yml")

    assert_includes database_config, 'ENV["TEST_DATABASE_URL"]'
  end

  def test_readme_keeps_research_only_boundary_explicit
    readme = read_file("README.md")

    assert_includes readme, "not a product"
    assert_includes readme, "bin/check"
    assert_includes readme, "bin/research-check"
    assert_includes readme, "DISCOURSE_DIR=/absolute/path/to/discourse bin/research-check"
    assert_includes readme, "not vendored repository content"
    refute_match HEURISTIC_KEYWORDS, readme
  end
end
