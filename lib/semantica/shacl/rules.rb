# frozen_string_literal: true

module Semantica
  module Shacl
    # PLAN_0.12.0 Phase A — `Semantica::Shacl::Rules` facade skeleton.
    #
    # Operator-authored shape-scoped derivation via the W3C SHACL
    # Advanced Features rules slice — sh:TripleRule and
    # sh:SPARQLRule plugged into the Shape concern's DSL. Phase A
    # ships the facade module, the pinned refusal symbols, the
    # Rule + TripleRule + SparqlRule value objects, and an empty
    # default rule set. The actual rule-application iteration
    # (including sh:order, sh:condition, sh:deactivated semantics)
    # is Phase B.
    #
    #   Semantica::Shacl::Rules.materialise!(
    #     data_graph:   "urn:mm:graph:catalogue",
    #     shapes_graph: "urn:semantica:shapes:product",
    #     inferred:     "urn:mm:graph:catalogue:inferred",
    #     rules:        :all,
    #     provenance:   true,
    #     max_iterations: 50,
    #   )
    #   # => { ok: true, iterations: 0, rules_fired: 0,
    #   #      derived: 0, per_rule: {}, fixpoint: true }
    #
    # Refusal envelopes:
    #   :invalid_graph            — pre-existing
    #   :rule_parse_error         — Phase B+; sh:SPARQLRule's CONSTRUCT fails
    #   :unknown_rule_type        — Phase B+; rule has unsupported rdf:type
    #   :condition_shape_missing  — Phase B+; sh:condition references unknown shape
    module Rules
      REASON_INVALID_GRAPH           = :invalid_graph
      REASON_RULE_PARSE_ERROR        = :rule_parse_error
      REASON_UNKNOWN_RULE_TYPE       = :unknown_rule_type
      REASON_CONDITION_SHAPE_MISSING = :condition_shape_missing

      DEFAULT_MAX_ITERATIONS = 50

      # Base value object for SHACL Rules. TripleRule + SparqlRule
      # subclass it; PLAN_0.12.0 Phase A's contract is that both
      # share the IRI / order / condition / deactivated fields,
      # diverging only in their rule-specific payload.
      class Rule
        attr_reader :iri, :order, :condition, :deactivated, :description

        def initialize(iri:, order: 0, condition: nil, deactivated: false, description: nil)
          @iri         = iri
          @order       = order
          @condition   = condition
          @deactivated = deactivated
          @description = description
          freeze
        end

        def deactivated?
          @deactivated
        end
      end

      # sh:TripleRule — single-triple derivation per matched focus
      # node. Subject / predicate / object node-expression shapes
      # are pinned in PLAN_0.12.0 Phase B.
      class TripleRule < Rule
        attr_reader :subject, :predicate, :object

        def initialize(subject:, predicate:, object:, **rest)
          @subject   = subject
          @predicate = predicate
          @object    = object
          super(**rest)
        end
      end

      # sh:SPARQLRule — embed an arbitrary CONSTRUCT query the
      # validator rewrites to INSERT WHERE at materialisation
      # time.
      class SparqlRule < Rule
        attr_reader :construct

        def initialize(construct:, **rest)
          @construct = construct
          super(**rest)
        end
      end

      module_function

      def materialise!(data_graph:, shapes_graph:, inferred:,
                       rules: :all, provenance: true,
                       max_iterations: DEFAULT_MAX_ITERATIONS)
        graph_error = validate_graphs(data_graph, shapes_graph, inferred)
        return graph_error if graph_error

        # Phase A: no rule discovery is implemented yet — Phase B
        # walks shapes_graph for sh:rule attachments. The empty
        # result trivially fixpoints.
        _ = rules
        _ = provenance
        _ = max_iterations

        {
          ok:          true,
          iterations:  0,
          rules_fired: 0,
          derived:     0,
          per_rule:    {},
          fixpoint:    true,
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
end
