# frozen_string_literal: true

require_relative "lib/vv/graph/version"

Gem::Specification.new do |spec|
  spec.name        = "vv-graph"
  spec.version     = Vv::Graph::VERSION
  spec.authors     = ["MagenticMarket contributors"]
  spec.email       = ["substrate@magenticmarket.ai"]

  spec.summary     = "ActiveRecord integration for sqlite-sparql — RDF triples + SPARQL inside Rails 8."
  spec.description = <<~DESC.strip
    Rails-ecosystem layer over the sqlite-sparql SQLite extension (Oxigraph via
    sqlite-loadable-rs). Provides Vv::Graph::Loader (wires extension loading
    across AR connection pools), Vv::Graph::Sparql (select / ask / construct /
    execute / bulk_* with structured envelopes; never raises), Vv::Graph::Storable
    (per-model triple-emission DSL via after_save / after_destroy hooks),
    Vv::Graph::EtherealGraph (per-AR-record durable named graphs via
    Active Storage), Vv::Graph::Reasoner (OWL 2 RL forward-chaining),
    Vv::Graph::Shacl (SHACL Core validation), Vv::Graph::Shacl::Rules
    (SHACL Rules derivation), Vv::Graph::Scope (cross-graph value object),
    Vv::Graph::ChangeSet (incremental capture).

    Renamed from rails-semantica at v0.15.0; the prior gem name shipped
    v0.1.0 through v0.14.0. Migration: replace `require "rails-semantica"`
    with `require "vv-graph"` and `Semantica::*` with `Vv::Graph::*`.
    See CHANGELOG.md for the full breaking-change list.

    Operator opt-in: add to Gemfile, run the setup generator, declare triples
    on models that should round-trip to the RDF store. Legacy ActiveRecord
    queries continue working unchanged.

    Status: v0.x.x — surface evolves with MagenticMarket as the first
    consumer. v1.0 ships when the API stabilises enough to invite outside
    Rails consumers + publication to RubyGems.
  DESC

  spec.homepage    = "https://github.com/laquereric/magentic-market-ai"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["allowed_push_host"] = "https://rubygems.org" if Gem::Version.new(spec.version.to_s) >= Gem::Version.new("1.0.0")
  spec.metadata["source_code_uri"]   = "https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-graph"
  spec.metadata["changelog_uri"]     = "https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-graph/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE-MIT",
    "LICENSE-APACHE",
    "CHANGELOG.md",
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", "~> 8.0"
  spec.add_dependency "railties",      "~> 8.0"
  spec.add_dependency "activerecord",  "~> 8.0"
  spec.add_dependency "sqlite3",       "~> 2.4"

  # activestorage is optional — only required for the
  # Vv::Graph::EtherealGraph concern (PLAN_0.7.0). Operators who
  # don't include that concern can omit it from their Gemfile.
  # The concern detects whether `has_one_attached` is available
  # and falls back to leaving attachment registration to the
  # operator if AS isn't loaded.

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake",  "~> 13.0"
end
