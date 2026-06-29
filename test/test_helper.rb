# frozen_string_literal: true

require "minitest/autorun"
require "pathname"

module ResearchContractHelpers
  ROOT = Pathname(__dir__).join("..").expand_path

  def root_path(*parts)
    ROOT.join(*parts)
  end

  def read_file(*parts)
    root_path(*parts).read
  end
end

class Minitest::Test
  include ResearchContractHelpers
end
