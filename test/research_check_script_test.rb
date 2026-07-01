# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "test_helper"

class ResearchCheckScriptTest < Minitest::Test
  def test_research_check_fails_loudly_when_discourse_checkout_is_missing
    Dir.mktmpdir("missing-discourse") do |path|
      json_out = File.join(path, "should-not-exist.json")

      stdout, stderr, status = Open3.capture3(
        {
          "DISCOURSE_DIR" => path,
          "JSON_OUT" => json_out,
        },
        root_path("bin", "research-check").to_s,
        chdir: root_path.to_s,
      )

      refute status.success?
      assert_equal "", stdout
      assert_includes stderr, "needs an external Discourse checkout at #{path}"
      assert_includes stderr, "Set DISCOURSE_DIR=/absolute/path/to/discourse"
      assert_includes stderr, "public fast contract"
      refute File.exist?(json_out)
    end
  end
end
