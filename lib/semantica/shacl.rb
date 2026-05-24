# frozen_string_literal: true

module Semantica
  # PLAN_0.10.0 Phase A — `Semantica::Shacl` facade skeleton.
  #
  # SHACL Core constraint-validation facade. Phase A ships the
  # facade module, the pinned refusal symbols, the Constraint +
  # ConstraintLibrary value objects, and an **empty**
  # Constraints::Core constant. The ~30-component library
  # transcription + actual constraint evaluation is Phase B.
  #
  #   Semantica::Shacl.validate(
  #     data_graph:   "urn:mm:graph:catalogue",
  #     shapes_graph: "urn:semantica:shapes:product",
  #     report_graph: "urn:mm:graph:catalogue:report",
  #     provenance:   true,
  #   )
  #   # => { ok: true, conforms: true, violations: [],
  #   #      report_graph: "urn:..." }
  #   #    (Phase A: empty constraint library, so every input
  #   #     trivially conforms.)
  #
  # Refusal envelopes:
  #   :invalid_graph                — blank-node IRI
  #   :shape_parse_error            — Phase B+; embedded sh:select fails to parse
  #   :unknown_constraint_component — Phase B+; shape declares an unimplemented IRI
  #   :cycle_detected               — Phase B+; sh:node references form a cycle
  #
  # PLAN_0.13.0 layering: `scope:` kwarg arrives in that plan's
  # Phase A. Phase A here keeps the per-kwarg shape.
  module Shacl
    REASON_INVALID_GRAPH                = :invalid_graph
    REASON_SHAPE_PARSE_ERROR            = :shape_parse_error
    REASON_UNKNOWN_CONSTRAINT_COMPONENT = :unknown_constraint_component
    REASON_CYCLE_DETECTED               = :cycle_detected

    # PLAN_0.10.0 Phase B value object — a SHACL Core constraint
    # component definition. Carries the IRI, the parameter
    # predicate names operators set on shapes (e.g., :min_count),
    # the SPARQL template the evaluator runs, and a default
    # message builder. Phase A ships the shape; Phase B populates
    # Constraints::Core.
    Constraint = Struct.new(:iri, :name, :parameters, :validates,
                            :default_message, keyword_init: true) do
      def initialize(iri:, name:, parameters:, validates:, default_message:)
        super
        freeze
      end
    end

    # PLAN_0.10.0 Phase B — registry keyed by Constraint IRI.
    # Composable by `+`. Phase A ships the empty-registry shape.
    class ConstraintLibrary
      include Enumerable

      attr_reader :constraints

      def initialize(constraints = [])
        @constraints = constraints.freeze
        @by_iri      = constraints.each_with_object({}) { |c, h| h[c.iri] = c }.freeze
        freeze
      end

      def each(&block) = constraints.each(&block)
      def empty?       = constraints.empty?
      def length       = constraints.length
      def [](iri)      = @by_iri[iri]
      def +(other)     = ConstraintLibrary.new(constraints + other.constraints)
    end

    module Constraints
      # Phase A — empty registry; validate is a trivial "conforms"
      # until Phase B transcribes the SHACL Core constraint
      # component catalogue (Rec section 4).
      Core = ConstraintLibrary.new([])
    end

    module_function

    def validate(data_graph:, shapes_graph:, report_graph: nil, provenance: true)
      graph_error = validate_graphs(data_graph, shapes_graph, report_graph)
      return graph_error if graph_error

      report_graph ||= "#{data_graph}:report"

      # Phase A: empty Constraints::Core means every input
      # trivially conforms. Phase B walks shapes_graph for
      # sh:NodeShape declarations, resolves targets, and
      # evaluates each constraint component.
      _ = provenance  # contract-pinned kwarg; Phase B activates it
      {
        ok:           true,
        conforms:     true,
        violations:   [],
        report_graph: report_graph,
      }
    end

    class << self
      private

      def validate_graphs(*graphs)
        graphs.compact.each do |g|
          next unless g.is_a?(String)
          next unless g.start_with?("_:")
          return refused(REASON_INVALID_GRAPH, "blank-node graph: #{g.inspect}")
        end
        nil
      end

      def refused(reason, because)
        { ok: false, reason: reason, because: because.to_s }
      end
    end
  end
end
