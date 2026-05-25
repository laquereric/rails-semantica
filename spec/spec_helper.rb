# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "vv-graph"
require_relative "support/extension_environment"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true

  if config.files_to_run.one?
    config.default_formatter = "doc"
  end

  # PLAN_0.1.0 Phase G — extension-environment lifecycle.
  #
  # Specs that tag `:requires_extension` round-trip real SPARQL
  # through the compiled sqlite-sparql binary. If the binary isn't
  # on disk, those specs skip with a one-line build hint rather than
  # failing the suite — the gem can be exercised at the contract /
  # envelope level without the engine present.
  config.before(:each, :requires_extension) do
    unless Vv::Graph::SpecSupport::ExtensionEnvironment.available?
      skip Vv::Graph::SpecSupport::ExtensionEnvironment.skip_reason
    end
    Vv::Graph::SpecSupport::ExtensionEnvironment.reset_store!
  end
end
