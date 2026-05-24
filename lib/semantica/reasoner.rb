# frozen_string_literal: true

module Semantica
  # PLAN_0.9.0 Phase A — `Semantica::Reasoner` facade skeleton.
  #
  # Forward-chaining OWL 2 RL reasoner. The Phase A rung ships the
  # facade module, the pinned refusal symbols, the Rule + RuleSet
  # value objects, and an **empty** Rules::OwlRl constant. The
  # ~70-rule library transcription + the actual rule-application
  # iteration is Phase B.
  #
  #   Semantica::Reasoner.materialise!(
  #     asserted:  "urn:mm:graph:catalogue",
  #     inferred:  "urn:mm:graph:catalogue:inferred",
  #     rules:     :owl_2_rl,
  #     provenance: true,
  #     max_iterations: 50,
  #   )
  #   # => { ok: true, iterations: 0, derived: 0, fixpoint: true }
  #   #    (Phase A: empty rule set, so the closure is a no-op.)
  #
  # Refusal envelopes:
  #   :invalid_graph     — blank-node IRI on asserted: / inferred:
  #   :invalid_dsl       — asserted == inferred
  #   :rule_set_unknown  — :rules symbol doesn't resolve
  #   :reasoner_diverged — max_iterations hit without fixpoint
  #
  # The structured-vs-string `rules:` kwarg accepts:
  #   - `:owl_2_rl` symbol → resolves to Rules::OwlRl
  #   - A RuleSet instance → passes through
  #   - Any other value → :rule_set_unknown
  #
  # PLAN_0.13.0 Phase A note: `scope:` kwarg layering on top of
  # `asserted:` / `inferred:` happens in Phase A of v0.13.0 (this
  # facade gains the kwarg without changing its return envelope).
  module Reasoner
    REASON_INVALID_GRAPH      = :invalid_graph
    REASON_INVALID_DSL        = :invalid_dsl
    REASON_RULE_SET_UNKNOWN   = :rule_set_unknown
    REASON_REASONER_DIVERGED  = :reasoner_diverged

    DEFAULT_MAX_ITERATIONS = 50

    # PLAN_0.9.0 Phase B value object. Carries the W3C OWL 2 RL
    # rule's metadata + the SPARQL UPDATE form. Phase A defines
    # the shape; Phase B populates Rules::OwlRl.
    Rule = Struct.new(:id, :name, :description, :sparql, keyword_init: true) do
      def initialize(id:, name:, description:, sparql:)
        super
        freeze
      end
    end

    # PLAN_0.9.0 Phase B — ordered collection of Rules. Composable
    # by `+`. Phase A ships the empty-set degenerate case.
    class RuleSet
      include Enumerable

      attr_reader :rules

      def initialize(rules = [])
        @rules = rules.freeze
        freeze
      end

      def each(&block) = rules.each(&block)
      def empty?       = rules.empty?
      def length       = rules.length
      def [](id)       = rules.find { |r| r.id == id }
      def +(other)     = RuleSet.new(rules + other.rules)
    end

    module Rules
      # Phase A — empty rule set; materialise! is a no-op until
      # Phase B transcribes the W3C OWL 2 RL/RDF rule table.
      OwlRl = RuleSet.new([])
    end

    module_function

    def materialise!(asserted:, inferred:, rules: :owl_2_rl,
                     provenance: true, max_iterations: DEFAULT_MAX_ITERATIONS)
      graph_error = validate_graphs(asserted, inferred)
      return graph_error if graph_error

      rule_set = resolve_rules(rules)
      return rule_set if rule_set.is_a?(Hash)  # refusal envelope

      run_fixpoint(rule_set, asserted, inferred, provenance, max_iterations)
    end

    class << self
      private

      def validate_graphs(asserted, inferred)
        [asserted, inferred].each do |g|
          next if g.nil?
          return refused(REASON_INVALID_GRAPH, "blank-node graph: #{g.inspect}") if g.start_with?("_:")
        end
        if asserted == inferred
          return refused(
            REASON_INVALID_DSL,
            "asserted: and inferred: must differ (got #{asserted.inspect}); the closure would loop",
          )
        end
        nil
      end

      def resolve_rules(rules)
        case rules
        when RuleSet
          rules
        when :owl_2_rl
          Rules::OwlRl
        else
          refused(
            REASON_RULE_SET_UNKNOWN,
            "rules: #{rules.inspect} did not resolve (known: :owl_2_rl, or a Semantica::Reasoner::RuleSet)",
          )
        end
      end

      def run_fixpoint(rule_set, _asserted, _inferred, _provenance, max_iterations)
        # Phase A: empty/no-rule sets fixpoint immediately. Phase
        # B implements the iteration loop calling Sparql.execute
        # per rule, tracking derived count, watching for
        # max_iterations.
        if rule_set.empty?
          return { ok: true, iterations: 0, derived: 0, fixpoint: true }
        end

        # Phase A placeholder for non-empty rule sets — operators
        # who land here are exercising the Phase A skeleton before
        # Phase B; return a refusal so the contract pins now.
        refused(
          REASON_REASONER_DIVERGED,
          "Reasoner Phase A — rule iteration loop is Phase B; max_iterations=#{max_iterations} would not be reached because no iteration runs",
        )
      end

      def refused(reason, because)
        { ok: false, reason: reason, because: because.to_s }
      end
    end
  end
end
