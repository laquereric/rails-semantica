# frozen_string_literal: true

module Semantica
  # PLAN_0.13.0 Phase A — predicate-shaped capability advertisements.
  #
  # Substrate consumers (e.g., vv-memory per
  # `CONSUMER_REQUIREMENT_VV.md`) want to ask "can this gem do X?"
  # without parsing the `VERSION` string. The three module-level
  # methods below ship that surface:
  #
  #   Semantica.rdf_star_writes_enabled?
  #     # => true once PLAN_0.8.0 Phase B lands the operator-facing
  #     # Sparql.quoted_triple + Storable::DSL annotate. v0.13.0
  #     # itself: false (PLAN_0.8.0 Phase A spec-only).
  #
  #   Semantica.facade_version
  #     # => "0.13.0" — capability epoch (vs. VERSION which is the
  #     # release tag; they diverge only on pure-bugfix releases).
  #     # Compare via Gem::Version.
  #
  #   Semantica.checkpoint_can_round_trip?(content_kind: :plain_ntriples)
  #     # => true (since v0.7.0)
  #   Semantica.checkpoint_can_round_trip?(content_kind: :ntriples_star)
  #     # => true once PLAN_0.13.0 Phase B (the parse_ntriples /
  #     # split_ntriple balanced-bracket extension) ships.
  #
  # **Don't** sniff `VERSION` to answer these questions. The
  # predicates outlive the version-string-comparison shape and
  # consumers that lean on them stay portable across minor
  # versions that shuffle which release a capability lands in.
  module_function

  def rdf_star_writes_enabled?
    # Tied to whether the operator-facing write helpers from
    # PLAN_0.8.0 Phase B are defined. Phase A of v0.8.0 was
    # spec-only (no production code) so the helpers do NOT yet
    # exist; v0.13.0 ships `false` against the current state.
    #
    # When PLAN_0.8.0 Phase B lands `Sparql.quoted_triple` +
    # the `Storable::DSL annotate` keyword, this flips to `true`
    # by introspection — no need to bump version constants.
    ::Semantica::Sparql.respond_to?(:quoted_triple)
  end

  def facade_version
    # The capability epoch. Currently identical to the gem's
    # VERSION (the release tag); the two diverge only when a
    # release ships pure bugfixes without adding capabilities.
    # Consumers compare via Gem::Version, not string equality.
    ::Semantica::VERSION
  end

  CHECKPOINT_CONTENT_KINDS = %i[plain_ntriples ntriples_star].freeze

  def checkpoint_can_round_trip?(content_kind:)
    case content_kind
    when :plain_ntriples
      # `EtherealGraph#hydrate_ethereal_graph!` has round-tripped
      # plain N-Triples since v0.7.0 (PLAN_0.7.0 Phase A).
      true
    when :ntriples_star
      # The capability flips on once Sparql.split_ntriple
      # recognises `<< s p o >>` as a single token (PLAN_0.13.0
      # Phase B). Introspection-shaped to avoid drift: check
      # whether the tokenizer handles a quoted triple correctly.
      probe = "<< <urn:s> <urn:p> <urn:o> >> <urn:meta> <urn:m>"
      terms = ::Semantica::Sparql::GraphScoping if false # silence unused-const warning
      terms = nil
      # Sparql.split_ntriple is module_function-private. Call
      # through `send`. We accept the tokenizer is correct iff
      # it returns exactly 3 terms with the first as the full
      # `<< … >>` form.
      result = ::Semantica::Sparql.send(:split_ntriple, probe)
      result.is_a?(Array) &&
        result.length == 3 &&
        result[0].start_with?("<<") &&
        result[0].end_with?(">>")
    else
      raise ArgumentError,
            "Semantica.checkpoint_can_round_trip?: unknown content_kind " \
              "#{content_kind.inspect} (known: #{CHECKPOINT_CONTENT_KINDS.inspect})"
    end
  end
end
