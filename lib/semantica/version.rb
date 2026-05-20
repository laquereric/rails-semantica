# frozen_string_literal: true

module Semantica
  # Single source of truth for the gem version is the root VERSION
  # file, matching the substrate's repo-root convention
  # (agent-os/rules/ruby.md). The gemspec consumes
  # Semantica::VERSION; bumps go in the VERSION file, not here.
  VERSION = File.read(File.expand_path("../../VERSION", __dir__)).strip
end
