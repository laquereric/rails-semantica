# frozen_string_literal: true

module Semantica
  # PLAN_0.9.0 — `Semantica::Reasoner` — forward-chaining OWL 2 RL.
  #
  # Phase A (#6e4233b) shipped the facade module, refusal symbols,
  # value-object hierarchy, and an empty Rules::OwlRl. Phase B
  # (this commit) implements the iteration loop + transcribes a
  # core subset of the W3C OWL 2 RL/RDF rule table into
  # Rules::OwlRl. The remaining ~55 rules (key axioms, hasValue /
  # oneOf / intersection / union / complement / disjoint / sameAs
  # term propagation, datatype reasoning) are Phase B.1 / B.2
  # follow-up commits — see Rules::PHASE_B_PENDING below.
  #
  #   Semantica::Reasoner.materialise!(
  #     asserted:  "urn:mm:graph:catalogue",
  #     inferred:  "urn:mm:graph:catalogue:inferred",
  #     rules:     :owl_2_rl,
  #     max_iterations: 50,
  #   )
  #   # => { ok: true, iterations: 3, derived: 7, fixpoint: true,
  #   #      per_rule: { "scm-sco" => 4, "cax-sco" => 3, ... } }
  #
  # Phase B's rule application is the SPARQL 1.1 dataset shape:
  #
  #   PREFIX rdf:  <…> PREFIX rdfs: <…> PREFIX owl: <…>
  #   WITH    <inferred>          -- INSERT destination
  #   INSERT  { <rule head> }
  #   USING   <asserted>          -- WHERE reads asserted ∪ inferred
  #   USING   <inferred>
  #   WHERE   { <rule body> }
  #
  # Probe-confirmed against engine 0.7.0. Counts come back as
  # SPARQL UPDATE signed-net-delta; fixpoint when the per-iteration
  # sum is 0.
  #
  # Provenance (RDF-star `:derivedBy` / `:derivedFrom` annotations
  # on inferred triples) is Phase E — Phase B ships the bare rule
  # set; the `provenance:` kwarg is accepted but ignored.
  #
  # PLAN_0.13.0 Phase A note: `scope:` kwarg layering on top of
  # `asserted:` / `inferred:` happens in Phase A of v0.13.0.
  module Reasoner
    REASON_INVALID_GRAPH      = :invalid_graph
    REASON_INVALID_DSL        = :invalid_dsl
    REASON_RULE_SET_UNKNOWN   = :rule_set_unknown
    REASON_REASONER_DIVERGED  = :reasoner_diverged

    DEFAULT_MAX_ITERATIONS = 50

    # Common prefix preamble prepended to every rule's SPARQL at
    # execution time. Lets rule bodies use `rdfs:subClassOf`,
    # `rdf:type`, `owl:TransitiveProperty`, etc. without each rule
    # carrying its own PREFIX declarations.
    PREFIX_PREAMBLE = <<~SPARQL.freeze
      PREFIX rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
      PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
      PREFIX owl:  <http://www.w3.org/2002/07/owl#>
      PREFIX xsd:  <http://www.w3.org/2001/XMLSchema#>
    SPARQL

    # Phase B value object. Carries the W3C OWL 2 RL rule's
    # metadata + the SPARQL UPDATE form. `sparql:` is the
    # graph-agnostic body (an `INSERT { … } WHERE { … }`); the
    # iteration loop wraps it with `WITH <inferred> … USING
    # <asserted> USING <inferred>` at execution time.
    Rule = Struct.new(:id, :name, :description, :sparql, keyword_init: true) do
      def initialize(id:, name:, description:, sparql:)
        super
        freeze
      end
    end

    # Ordered collection of Rules. Composable by `+`.
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
      # ----- OWL 2 RL Phase B core subset (15 rules) -----
      #
      # Picked for "rules MM is most likely to exercise" coverage:
      # subClassOf / subPropertyOf hierarchies, instance-type
      # propagation, domain / range entailment, transitive /
      # symmetric / inverse property characteristics, sameAs
      # symmetric + transitive, equivalentClass / equivalentProperty
      # mutual-subclass-property unfolding, functional property
      # sameAs derivation.
      #
      # Each rule's WHERE clause includes a guard against trivial
      # re-derivation where applicable (`FILTER(?a != ?c)` for
      # transitive closures) so the closure terminates against
      # fixed-point counting.
      #
      # The 70-rule W3C OWL 2 RL/RDF table's remaining ~55 entries
      # (PHASE_B_PENDING) cover:
      #   eq-ref, eq-rep-s, eq-rep-p, eq-rep-o, eq-diff1/2/3
      #     (sameAs term substitution + differentFrom)
      #   prp-irp, prp-asyp, prp-pdw, prp-adp, prp-npa1, prp-npa2
      #     (irreflexive / asymmetric / disjoint / assertions of NPA)
      #   prp-key (key axioms — hasKey ⇒ sameAs derivation)
      #   prp-ifp (inverse-functional property — sameAs from object)
      #   cls-* slice: cls-int1, cls-int2, cls-uni, cls-com,
      #     cls-svf1, cls-svf2, cls-avf, cls-hv1, cls-hv2,
      #     cls-maxc1, cls-maxc2, cls-maxqc1..4, cls-oo
      #     (intersection / union / complement / someValuesFrom /
      #      allValuesFrom / hasValue / maxCardinality / oneOf)
      #   cax-eqc1/2, cax-dw, cax-adc
      #     (equivalentClass / disjointWith via cax-prefix)
      #   scm-cls, scm-dom1/2, scm-rng1/2, scm-hv, scm-svf1/2,
      #   scm-avf1/2, scm-int, scm-uni
      #     (schema-only T-Box closures over class expressions)
      #   dt-type1, dt-type2, dt-eq, dt-diff
      #     (datatype-level reasoning — only the SPARQL-expressible
      #      slice is in scope per PLAN_0.9.0 Why-OWL-2-RL section)
      #
      # Each pending rule is a mechanical transcription against the
      # W3C OWL 2 Profiles section "Reasoning in OWL 2 RL and RDF
      # Graphs using Rules" table. Adding them is additive — order
      # within Rules::OwlRl doesn't matter for monotonic Datalog.
      PHASE_B_PENDING = [
        "eq-ref", "eq-rep-s", "eq-rep-p", "eq-rep-o",
        "eq-diff1", "eq-diff2", "eq-diff3",
        "prp-irp", "prp-asyp", "prp-pdw", "prp-adp",
        "prp-npa1", "prp-npa2", "prp-key", "prp-ifp",
        "cls-int1", "cls-int2", "cls-uni", "cls-com",
        "cls-svf1", "cls-svf2", "cls-avf", "cls-hv1", "cls-hv2",
        "cls-maxc1", "cls-maxc2",
        "cls-maxqc1", "cls-maxqc2", "cls-maxqc3", "cls-maxqc4",
        "cls-oo",
        "cax-eqc1", "cax-eqc2", "cax-dw", "cax-adc",
        "scm-cls", "scm-dom1", "scm-dom2", "scm-rng1", "scm-rng2",
        "scm-hv", "scm-svf1", "scm-svf2", "scm-avf1", "scm-avf2",
        "scm-int", "scm-uni",
        "dt-type1", "dt-type2", "dt-eq", "dt-diff",
      ].freeze

      OwlRl = RuleSet.new([
        # ---- Class hierarchy (T-Box transitive closure) ----
        Rule.new(
          id:          "scm-sco",
          name:        "Transitive subClassOf",
          description: "If ?c1 rdfs:subClassOf ?c2 and ?c2 rdfs:subClassOf ?c3, then ?c1 rdfs:subClassOf ?c3.",
          sparql: <<~SPARQL,
            INSERT { ?c1 rdfs:subClassOf ?c3 }
            WHERE  { ?c1 rdfs:subClassOf ?c2 .
                     ?c2 rdfs:subClassOf ?c3 .
                     FILTER(?c1 != ?c3) }
          SPARQL
        ),
        Rule.new(
          id:          "scm-spo",
          name:        "Transitive subPropertyOf",
          description: "If ?p1 rdfs:subPropertyOf ?p2 and ?p2 rdfs:subPropertyOf ?p3, then ?p1 rdfs:subPropertyOf ?p3.",
          sparql: <<~SPARQL,
            INSERT { ?p1 rdfs:subPropertyOf ?p3 }
            WHERE  { ?p1 rdfs:subPropertyOf ?p2 .
                     ?p2 rdfs:subPropertyOf ?p3 .
                     FILTER(?p1 != ?p3) }
          SPARQL
        ),

        # ---- equivalentClass / equivalentProperty unfolding ----
        Rule.new(
          id:          "scm-eqc1",
          name:        "equivalentClass implies mutual subClassOf",
          description: "If ?c1 owl:equivalentClass ?c2, then ?c1 rdfs:subClassOf ?c2 and ?c2 rdfs:subClassOf ?c1.",
          sparql: <<~SPARQL,
            INSERT { ?c1 rdfs:subClassOf ?c2 .
                     ?c2 rdfs:subClassOf ?c1 }
            WHERE  { ?c1 owl:equivalentClass ?c2 }
          SPARQL
        ),
        Rule.new(
          id:          "scm-eqp1",
          name:        "equivalentProperty implies mutual subPropertyOf",
          description: "If ?p1 owl:equivalentProperty ?p2, then ?p1 rdfs:subPropertyOf ?p2 and ?p2 rdfs:subPropertyOf ?p1.",
          sparql: <<~SPARQL,
            INSERT { ?p1 rdfs:subPropertyOf ?p2 .
                     ?p2 rdfs:subPropertyOf ?p1 }
            WHERE  { ?p1 owl:equivalentProperty ?p2 }
          SPARQL
        ),

        # ---- A-Box propagation through hierarchies ----
        Rule.new(
          id:          "cax-sco",
          name:        "rdf:type propagation via subClassOf",
          description: "If ?x rdf:type ?c1 and ?c1 rdfs:subClassOf ?c2, then ?x rdf:type ?c2.",
          sparql: <<~SPARQL,
            INSERT { ?x rdf:type ?c2 }
            WHERE  { ?x rdf:type ?c1 .
                     ?c1 rdfs:subClassOf ?c2 .
                     FILTER(?c1 != ?c2) }
          SPARQL
        ),
        Rule.new(
          id:          "prp-spo1",
          name:        "Predicate propagation via subPropertyOf",
          description: "If ?x ?p1 ?y and ?p1 rdfs:subPropertyOf ?p2, then ?x ?p2 ?y.",
          sparql: <<~SPARQL,
            INSERT { ?x ?p2 ?y }
            WHERE  { ?x ?p1 ?y .
                     ?p1 rdfs:subPropertyOf ?p2 .
                     FILTER(?p1 != ?p2) }
          SPARQL
        ),

        # ---- Domain / range entailment ----
        Rule.new(
          id:          "prp-dom",
          name:        "rdfs:domain entailment",
          description: "If ?p rdfs:domain ?c and ?x ?p ?y, then ?x rdf:type ?c.",
          sparql: <<~SPARQL,
            INSERT { ?x rdf:type ?c }
            WHERE  { ?p rdfs:domain ?c .
                     ?x ?p ?y }
          SPARQL
        ),
        Rule.new(
          id:          "prp-rng",
          name:        "rdfs:range entailment",
          description: "If ?p rdfs:range ?c and ?x ?p ?y, then ?y rdf:type ?c.",
          sparql: <<~SPARQL,
            INSERT { ?y rdf:type ?c }
            WHERE  { ?p rdfs:range ?c .
                     ?x ?p ?y }
          SPARQL
        ),

        # ---- Property characteristics ----
        Rule.new(
          id:          "prp-trp",
          name:        "Transitive property",
          description: "If ?p rdf:type owl:TransitiveProperty and ?x ?p ?y and ?y ?p ?z, then ?x ?p ?z.",
          sparql: <<~SPARQL,
            INSERT { ?x ?p ?z }
            WHERE  { ?p rdf:type owl:TransitiveProperty .
                     ?x ?p ?y .
                     ?y ?p ?z .
                     FILTER(?x != ?z) }
          SPARQL
        ),
        Rule.new(
          id:          "prp-symp",
          name:        "Symmetric property",
          description: "If ?p rdf:type owl:SymmetricProperty and ?x ?p ?y, then ?y ?p ?x.",
          sparql: <<~SPARQL,
            INSERT { ?y ?p ?x }
            WHERE  { ?p rdf:type owl:SymmetricProperty .
                     ?x ?p ?y .
                     FILTER(?x != ?y) }
          SPARQL
        ),
        Rule.new(
          id:          "prp-inv1",
          name:        "Inverse property (forward)",
          description: "If ?p1 owl:inverseOf ?p2 and ?x ?p1 ?y, then ?y ?p2 ?x.",
          sparql: <<~SPARQL,
            INSERT { ?y ?p2 ?x }
            WHERE  { ?p1 owl:inverseOf ?p2 .
                     ?x ?p1 ?y }
          SPARQL
        ),
        Rule.new(
          id:          "prp-inv2",
          name:        "Inverse property (reverse)",
          description: "If ?p1 owl:inverseOf ?p2 and ?x ?p2 ?y, then ?y ?p1 ?x.",
          sparql: <<~SPARQL,
            INSERT { ?y ?p1 ?x }
            WHERE  { ?p1 owl:inverseOf ?p2 .
                     ?x ?p2 ?y }
          SPARQL
        ),
        Rule.new(
          id:          "prp-fp",
          name:        "Functional property ⇒ sameAs",
          description: "If ?p rdf:type owl:FunctionalProperty and ?x ?p ?y1 and ?x ?p ?y2, then ?y1 owl:sameAs ?y2.",
          sparql: <<~SPARQL,
            INSERT { ?y1 owl:sameAs ?y2 }
            WHERE  { ?p rdf:type owl:FunctionalProperty .
                     ?x ?p ?y1 .
                     ?x ?p ?y2 .
                     FILTER(?y1 != ?y2) }
          SPARQL
        ),

        # ---- sameAs closure (partial — full term substitution is PHASE_B_PENDING) ----
        Rule.new(
          id:          "eq-sym",
          name:        "owl:sameAs symmetric",
          description: "If ?x owl:sameAs ?y, then ?y owl:sameAs ?x.",
          sparql: <<~SPARQL,
            INSERT { ?y owl:sameAs ?x }
            WHERE  { ?x owl:sameAs ?y .
                     FILTER(?x != ?y) }
          SPARQL
        ),
        Rule.new(
          id:          "eq-trans",
          name:        "owl:sameAs transitive",
          description: "If ?x owl:sameAs ?y and ?y owl:sameAs ?z, then ?x owl:sameAs ?z.",
          sparql: <<~SPARQL,
            INSERT { ?x owl:sameAs ?z }
            WHERE  { ?x owl:sameAs ?y .
                     ?y owl:sameAs ?z .
                     FILTER(?x != ?z) }
          SPARQL
        ),
      ])
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

      # Phase B — actual rule application loop.
      #
      # Each iteration runs every rule's rewritten SPARQL UPDATE,
      # sums per-rule deltas, and checks for fixpoint (total = 0).
      # `max_iterations` guards non-termination; a non-fixpoint
      # exit returns `:reasoner_diverged` with the iterations
      # count so operators can re-run with a higher cap or inspect
      # which rules are still firing.
      def run_fixpoint(rule_set, asserted, inferred, _provenance, max_iterations)
        return { ok: true, iterations: 0, derived: 0, fixpoint: true, per_rule: {} } if rule_set.empty?

        total_derived = 0
        per_rule      = Hash.new(0)
        iterations    = 0
        fixpoint      = false

        max_iterations.times do
          iterations += 1
          iteration_delta = 0

          rule_set.each do |rule|
            result = ::Semantica::Sparql.execute(rewrite_rule(rule, asserted, inferred))
            unless result[:ok]
              # Surface engine errors verbatim — a rule that can't
              # parse against the engine is a contract failure;
              # bail out of the closure rather than silently skip.
              return result.merge(iterations: iterations,
                                  derived: total_derived,
                                  fixpoint: false,
                                  per_rule: per_rule.to_h)
            end

            delta = result[:count].to_i
            next if delta.zero?

            iteration_delta    += delta
            per_rule[rule.id]  += delta
          end

          total_derived += iteration_delta

          if iteration_delta.zero?
            fixpoint = true
            break
          end
        end

        if fixpoint
          { ok: true, iterations: iterations, derived: total_derived,
            fixpoint: true, per_rule: per_rule.to_h }
        else
          refused(
            REASON_REASONER_DIVERGED,
            "fixpoint not reached after #{max_iterations} iterations (derived=#{total_derived}); re-run with a higher max_iterations or inspect per_rule for the divergent rule",
          ).merge(iterations: iterations, derived: total_derived,
                  per_rule: per_rule.to_h)
        end
      end

      # SPARQL 1.1 UPDATE dataset wrapper:
      #   WITH <inferred>   — INSERT/DELETE target
      #   USING <asserted>  — WHERE pattern reads from asserted ∪ inferred
      #   USING <inferred>
      # Plus the shared PREFIX preamble so rule bodies can use
      # rdfs:, rdf:, owl: shorthand.
      def rewrite_rule(rule, asserted, inferred)
        body = rule.sparql.strip

        # Split the rule body at INSERT { ... } / WHERE { ... } so
        # we can inject the dataset clauses between them. Cheap
        # textual rewrite; the rules library is operator-curated
        # so we don't need a full SPARQL parser.
        m = body.match(/\A\s*INSERT\s*\{(.+?)\}\s*WHERE\s*\{(.+)\}\s*\z/m)
        unless m
          raise ArgumentError,
                "Reasoner::Rule #{rule.id.inspect}: expected `INSERT { … } WHERE { … }`; got: #{body.inspect}"
        end

        insert_block = m[1].strip
        where_block  = m[2].strip

        <<~SPARQL
          #{PREFIX_PREAMBLE}
          WITH <#{inferred}>
          INSERT { #{insert_block} }
          USING <#{asserted}>
          USING <#{inferred}>
          WHERE  { #{where_block} }
        SPARQL
      end

      def refused(reason, because)
        { ok: false, reason: reason, because: because.to_s }
      end
    end
  end
end
