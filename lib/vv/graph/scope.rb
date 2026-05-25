# frozen_string_literal: true

require "set"

module Vv; end

module Vv::Graph
  # PLAN_0.13.0 Phase A — `Vv::Graph::Scope` value object.
  #
  # Names the multi-graph relationship a single unit of reasoning /
  # validation work operates against. Replaces the bare-string
  # `data_graph:` / `shapes_graph:` / `inferred:` kwargs across
  # every facade (Reasoner, Shacl, Shacl::Rules, ChangeSet) with a
  # structured object — five pinned roles plus an `additional:` Hash
  # escape hatch.
  #
  # Frozen + value-equal. Two Scopes with the same five role IRIs
  # are the same Scope.
  #
  #   scope = Vv::Graph::Scope.new(
  #     data:     "urn:mm:graph:workspace_42",
  #     schema:   "urn:mm:graph:shared:schema",
  #     shapes:   "urn:vv-graph:shapes:product",
  #     inferred: "urn:mm:graph:workspace_42:inferred",
  #     report:   "urn:mm:graph:workspace_42:report",
  #   )
  #
  # Optional roles default to `nil`. Per-facade required-role
  # checking happens at the facade boundary (not in the Scope
  # itself); the value object's only structural rule is that no
  # graph may appear in both a read role and a write role
  # (`:scope_read_write_overlap` refusal envelope from facades).
  #
  # PINNED ROLES:
  #   - `data`     — primary asserted graph; the "what is the case" graph
  #   - `schema`   — OWL/RDFS axioms; read-only contribution to reasoning
  #   - `shapes`   — SHACL Core constraints + SHACL Rules
  #   - `inferred` — write target for materialised derivations
  #   - `report`   — write target for SHACL validation reports
  #
  # The `additional:` Hash is operator-extensible — substrate code
  # may need named roles the gem doesn't enshrine (e.g.,
  # `:ontology`, `:shapes_library`); addressable via
  # `scope.additional[:ontology]`.
  Scope = Struct.new(:data, :schema, :shapes, :inferred, :report, :additional, keyword_init: true) do
    READ_ROLE_NAMES  = %i[data schema shapes].freeze
    WRITE_ROLE_NAMES = %i[inferred report].freeze

    class << self
      # Process-wide registry of Scopes. Operator-populated (e.g.,
      # from a Rails initializer iterating Workspace / Tenant /
      # Scope AR records). v0.13.0 does not auto-populate; the
      # Storable `graph "…"` DSL declares one graph per model,
      # which is not enough information to construct a full Scope.
      #
      # Test isolation: callers reset via `Vv::Graph::Scope.registry.clear`
      # in `before(:each)`.
      def registry
        @registry ||= Set.new
      end

      # Find a registered Scope whose `data:` graph matches the
      # given IRI. Returns nil when nothing matches.
      def find_by_data(iri)
        registry.find { |scope| scope.data == iri }
      end

      # PLAN_0.13.0 Phase C — convenience factory for the
      # single-graph case. Returns a degenerate Scope with
      # `graph_iri` as `data:` and every other role nil.
      # Lets consumers port per-kwarg call sites to the `scope:`
      # surface incrementally — start with just `data:`, fill
      # in `schema:` / `inferred:` / etc. later.
      #
      # Per-facade required-role validation still applies; if
      # the facade needs a role the degenerate Scope doesn't
      # declare, it refuses with `:scope_role_missing`.
      def from_(graph_iri)
        new(data: graph_iri)
      end
    end

    def initialize(data:, schema: nil, shapes: nil, inferred: nil, report: nil, additional: {})
      super(
        data:       data,
        schema:     schema,
        shapes:     shapes,
        inferred:   inferred,
        report:     report,
        additional: additional.freeze,
      )
      freeze
    end

    # The Set of graph IRIs the facades read from. Excludes write
    # roles (`inferred`, `report`) — those would only appear here
    # if an operator deliberately fed a read role with a write
    # role's IRI, which the `read_write_overlap?` check catches.
    def read_graphs
      Set.new(READ_ROLE_NAMES.map { |role| public_send(role) }.compact)
    end

    # The Set of graph IRIs the facades may write to.
    def write_graphs
      Set.new(WRITE_ROLE_NAMES.map { |role| public_send(role) }.compact)
    end

    # `true` when the operator declared the same IRI as both a
    # read role and a write role. Facades refuse with
    # `:scope_read_write_overlap` — emitting into a graph the
    # next read picks up would loop the reasoner.
    def read_write_overlap?
      !(read_graphs & write_graphs).empty?
    end

    # Equality by value across all five pinned roles + the
    # additional Hash. Two Scopes constructed with the same IRIs
    # are `==` and have the same `#hash` — usable as Set members.
    def hash
      [data, schema, shapes, inferred, report, additional].hash
    end

    def eql?(other)
      other.is_a?(Scope) && hash == other.hash
    end
    alias_method :==, :eql?
  end

  # PLAN_0.13.0 Phase D — shared helper for facade methods
  # accepting both per-kwarg and `scope:` calling conventions.
  #
  # Given a Scope (or nil) + the facade's current per-kwarg hash
  # + a role-to-kwarg mapping + a required-roles list, returns
  # either a translated kwargs Hash or a refusal envelope.
  #
  # The three pinned refusal symbols:
  #   :scope_kwarg_conflict     — caller passed scope: + an overlapping kwarg
  #   :scope_role_missing       — scope omits a role the facade needs
  #   :scope_read_write_overlap — scope's read/write graphs overlap
  #
  # Named under `Vv::Graph::Scope::FacadeAdapter` despite living
  # outside the Struct block — Struct.new's block doesn't reliably
  # define nested constants, so the module sits next to Scope and
  # is aliased into Scope's namespace below.
  module FacadeAdapter
    module_function

    # @return [Hash] either `{ kwargs: <Hash> }` (proceed with the
    #   translated kwargs) or a refusal envelope `{ ok: false, ... }`.
    def resolve(scope:, kwargs:, mapping:, required: [])
      return { kwargs: kwargs.compact } if scope.nil?

      unless scope.is_a?(::Vv::Graph::Scope)
        return refused(:scope_kwarg_conflict,
                       "scope: must be a Vv::Graph::Scope; got #{scope.class}")
      end

      conflicting = mapping.each_with_object([]) do |(_role, kwarg_name), acc|
        acc << kwarg_name if kwargs[kwarg_name]
      end
      if conflicting.any?
        return refused(:scope_kwarg_conflict,
                       "scope: passed with overlapping per-kwarg value(s): #{conflicting.inspect}")
      end

      if scope.read_write_overlap?
        return refused(:scope_read_write_overlap,
                       "scope has graph(s) in both read and write roles: " \
                         "#{(scope.read_graphs & scope.write_graphs).to_a.inspect}")
      end

      missing = required.reject { |role| scope.public_send(role) }
      if missing.any?
        return refused(:scope_role_missing,
                       "scope missing required role(s) for this facade: #{missing.inspect}")
      end

      translated = kwargs.compact
      mapping.each do |role, kwarg_name|
        value = scope.public_send(role)
        translated[kwarg_name] = value if value
      end
      { kwargs: translated }
    end

    def refused(reason, because)
      { ok: false, reason: reason, because: because.to_s }
    end
  end

  # Reachable as `Vv::Graph::Scope::FacadeAdapter` for the
  # documented contract addition (PLAN_0.13.0 Phase D's table).
  Scope.const_set(:FacadeAdapter, FacadeAdapter)
end
