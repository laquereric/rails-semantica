# frozen_string_literal: true

require "securerandom"

module Vv; end

module Vv::Graph
  module Shacl
    # PLAN_0.12.0 — `Vv::Graph::Shacl::Rules` — SHACL Rules
    # shape-scoped derivation. Phase A (#593d31c) shipped the
    # facade, refusal symbols, Rule + TripleRule + SparqlRule
    # value objects. Phase B (this commit) implements the
    # materialisation engine.
    #
    # The Rules slice of SHACL Advanced Features (W3C Note,
    # 8 June 2017): `sh:TripleRule` (single-triple derivation per
    # focus) and `sh:SPARQLRule` (embedded CONSTRUCT). Each rule
    # attaches to a sh:NodeShape via `sh:rule`. The engine walks
    # shapes_graph for rule attachments, resolves focus nodes
    # against the parent shape's `sh:targetClass` / `sh:targetNode`,
    # and emits derivations into the inferred graph.
    #
    #   Vv::Graph::Shacl::Rules.materialise!(
    #     data_graph:   "urn:mm:graph:catalogue",
    #     shapes_graph: "urn:vv-graph:shapes:product",
    #     inferred:     "urn:mm:graph:catalogue:inferred",
    #     max_iterations: 50,
    #   )
    #   # => { ok: true, iterations: 1, rules_fired: 2,
    #   #      derived: 5, per_rule: { "urn:rule:1" => 3, ... },
    #   #      fixpoint: true }
    #
    # Phase B scope:
    #
    # IN SCOPE
    #   - sh:rule discovery from sh:NodeShape declarations
    #   - sh:TripleRule with bare-IRI / bare-literal subject /
    #     predicate / object (with sh:this resolving to the focus
    #     node)
    #   - sh:SPARQLRule with embedded sh:construct (CONSTRUCT
    #     rewritten to INSERT WHERE; ?this substituted with focus IRI)
    #   - sh:order ordering (numeric; default 0)
    #   - sh:deactivated true → skip
    #   - sh:condition gating (recursive Shacl.validate against
    #     the focus; rule fires only if condition conforms)
    #   - Fixpoint iteration with max_iterations guard
    #   - Per-rule fire counts via the per_rule: envelope key
    #
    # PHASE B.1 / B.2 (deferred)
    #   - sh:JSRule (JavaScript — out of scope entirely)
    #   - Node-expression operators on sh:object (sh:path,
    #     sh:expression, etc. inside a TripleRule object)
    #   - Cross-graph rules (parent shape in graph A, data in
    #     graph B with explicit graph attribution)
    #   - Engine-side batched CONSTRUCT execution (engine 0.8.0's
    #     rdf_construct_many — perf optimisation deferred until
    #     telemetry shows the per-rule sparql_update is the
    #     bottleneck)
    #   - Provenance annotations (RDF-star :derivedBy on each
    #     derived triple — Phase E of PLAN_0.12.0)
    module Rules
      REASON_INVALID_GRAPH           = :invalid_graph
      REASON_RULE_PARSE_ERROR        = :rule_parse_error
      REASON_UNKNOWN_RULE_TYPE       = :unknown_rule_type
      REASON_CONDITION_SHAPE_MISSING = :condition_shape_missing
      REASON_REASONER_DIVERGED       = :reasoner_diverged

      DEFAULT_MAX_ITERATIONS = 50

      RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
      SH       = "http://www.w3.org/ns/shacl#"
      SH_RULE         = "#{SH}rule"
      SH_TRIPLE_RULE  = "#{SH}TripleRule"
      SH_SPARQL_RULE  = "#{SH}SPARQLRule"
      SH_JS_RULE      = "#{SH}JSRule"          # rejected — see :unknown_rule_type
      SH_ORDER        = "#{SH}order"
      SH_DEACTIVATED  = "#{SH}deactivated"
      SH_CONDITION    = "#{SH}condition"
      SH_DESCRIPTION  = "#{SH}description"
      SH_SUBJECT      = "#{SH}subject"
      SH_PREDICATE    = "#{SH}predicate"
      SH_OBJECT       = "#{SH}object"
      SH_CONSTRUCT    = "#{SH}construct"
      SH_THIS         = "#{SH}this"
      SH_NODE_SHAPE   = "#{SH}NodeShape"
      SH_TARGET_CLASS = "#{SH}targetClass"
      SH_TARGET_NODE  = "#{SH}targetNode"

      # Base value object (Phase A shape).
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

      class TripleRule < Rule
        attr_reader :subject, :predicate, :object

        def initialize(subject:, predicate:, object:, **rest)
          @subject   = subject
          @predicate = predicate
          @object    = object
          super(**rest)
        end
      end

      class SparqlRule < Rule
        attr_reader :construct

        def initialize(construct:, **rest)
          @construct = construct
          super(**rest)
        end
      end

      # PLAN_0.13.0 Phase D — Shacl::Rules.materialise! accepts
      # either the per-kwarg trio or a `scope:`. Scope's `data:` →
      # `data_graph:`, `shapes:` → `shapes_graph:`, `inferred:` →
      # `inferred:`. Required scope roles: data + shapes + inferred.
      SHACL_RULES_SCOPE_MAPPING = {
        data: :data_graph, shapes: :shapes_graph, inferred: :inferred,
      }.freeze
      SHACL_RULES_REQUIRED_ROLES = %i[data shapes inferred].freeze

      module_function

      def materialise!(data_graph: nil, shapes_graph: nil, inferred: nil,
                       scope: nil,
                       rules: :all, provenance: true,
                       max_iterations: DEFAULT_MAX_ITERATIONS)
        resolved = ::Vv::Graph::Scope::FacadeAdapter.resolve(
          scope: scope,
          kwargs: { data_graph: data_graph, shapes_graph: shapes_graph,
                    inferred: inferred },
          mapping: SHACL_RULES_SCOPE_MAPPING,
          required: SHACL_RULES_REQUIRED_ROLES,
        )
        return resolved unless resolved.is_a?(Hash) && resolved[:kwargs]
        data_graph   = resolved[:kwargs][:data_graph]
        shapes_graph = resolved[:kwargs][:shapes_graph]
        inferred     = resolved[:kwargs][:inferred]

        graph_error = validate_graphs(data_graph, shapes_graph, inferred)
        return graph_error if graph_error

        engine = Engine.new(
          data_graph:     data_graph,
          shapes_graph:   shapes_graph,
          inferred:       inferred,
          rules_filter:   rules,
          provenance:     provenance,
          max_iterations: max_iterations,
        )
        engine.run
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

      # ---- Internal: rule discovery + iteration engine ----
      #
      # Operators consume via the module's `materialise!` method;
      # the Engine class is internal scaffolding.
      class Engine
        PREFIX_PREAMBLE = <<~SPARQL.freeze
          PREFIX rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
          PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
          PREFIX owl:  <http://www.w3.org/2002/07/owl#>
          PREFIX sh:   <http://www.w3.org/ns/shacl#>
          PREFIX xsd:  <http://www.w3.org/2001/XMLSchema#>
        SPARQL

        def initialize(data_graph:, shapes_graph:, inferred:,
                       rules_filter:, provenance:, max_iterations:)
          @data_graph     = data_graph
          @shapes_graph   = shapes_graph
          @inferred       = inferred
          @rules_filter   = rules_filter
          @provenance     = provenance        # ignored in Phase B
          @max_iterations = max_iterations
        end

        def run
          rules = discover_rules
          return rules if rules.is_a?(Hash)   # refusal envelope

          # Selective execution — if rules_filter is an Array of IRIs,
          # narrow the rule set. `:all` symbol or anything else passes
          # through.
          if @rules_filter.is_a?(Array)
            rules = rules.select { |r, _| @rules_filter.include?(r.iri) }
          end

          rules.sort_by! { |rule, _parent| [rule.order, rule.iri] }

          run_fixpoint(rules)
        end

        private

        # Returns an Array<[Rule, parent_shape_iri]> for every
        # discovered, non-deactivated rule attached via sh:rule
        # in the shapes_graph. Refuses with :unknown_rule_type if
        # any rule has an rdf:type the engine doesn't implement
        # (e.g., sh:JSRule).
        def discover_rules
          attachments = read_select(@shapes_graph,
            "SELECT ?shape ?rule WHERE { ?shape <#{SH_RULE}> ?rule }")

          rules = []
          unknown = []

          attachments.each do |row|
            parent_iri = unwrap(row["shape"]) or next
            rule_term  = row["rule"]
            rule_iri   = unwrap(rule_term) || rule_term  # may be blank-node

            type_rows = read_select(@shapes_graph,
              "SELECT ?t WHERE { #{format_term(rule_term)} <#{RDF_TYPE}> ?t }")
            types = type_rows.map { |r| unwrap(r["t"]) }.compact

            if types.include?(SH_JS_RULE)
              unknown << "#{SH_JS_RULE} on rule #{rule_iri}"
              next
            end

            common_kwargs = {
              iri:         rule_iri,
              order:       read_first_lexical_int(rule_term, SH_ORDER) || 0,
              condition:   read_first_unwrapped(rule_term, SH_CONDITION),
              deactivated: read_first_bool(rule_term, SH_DEACTIVATED),
              description: read_first_lexical(rule_term, SH_DESCRIPTION),
            }

            rule =
              if types.include?(SH_TRIPLE_RULE)
                build_triple_rule(rule_term, common_kwargs)
              elsif types.include?(SH_SPARQL_RULE)
                build_sparql_rule(rule_term, common_kwargs)
              else
                unknown << "rule #{rule_iri} has rdf:type(s) #{types.inspect} — not a recognised rule type"
                next
              end
            next unless rule
            next if rule.deactivated?

            # Confirm parent shape declares a target — without one
            # we can't resolve focus nodes for this rule. Skip
            # silently rather than refuse; orphan rules are an
            # operator authoring error not a runtime fault.
            next if parent_targets(parent_iri).empty?

            rules << [rule, parent_iri]
          end

          if unknown.any?
            return ::Vv::Graph::Shacl::Rules.send(:refused,
              REASON_UNKNOWN_RULE_TYPE,
              "shapes graph contains unsupported rule types: #{unknown.inspect}")
          end

          rules
        end

        def build_triple_rule(rule_term, common_kwargs)
          subject_term   = read_first_object(rule_term, SH_SUBJECT)
          predicate_term = read_first_object(rule_term, SH_PREDICATE)
          object_term    = read_first_object(rule_term, SH_OBJECT)

          # Phase B requires all three to be present + ground
          # (IRI / literal / sh:this sentinel).
          return nil unless subject_term && predicate_term && object_term

          TripleRule.new(
            subject:   subject_term,
            predicate: predicate_term,
            object:    object_term,
            **common_kwargs,
          )
        end

        def build_sparql_rule(rule_term, common_kwargs)
          construct = read_first_lexical(rule_term, SH_CONSTRUCT)
          return nil unless construct

          SparqlRule.new(construct: construct, **common_kwargs)
        end

        # Returns the focus-node IRIs for the parent shape via
        # sh:targetClass / sh:targetNode against data_graph.
        # Phase B does not support sh:targetSubjectsOf / sh:targetObjectsOf.
        def parent_targets(parent_iri)
          @target_cache ||= {}
          @target_cache[parent_iri] ||= begin
            focus = []
            read_select(@shapes_graph,
              "SELECT ?cls WHERE { <#{parent_iri}> <#{SH_TARGET_CLASS}> ?cls }").each do |row|
              cls = unwrap(row["cls"]) or next
              read_select(@data_graph,
                "SELECT ?x WHERE { ?x <#{RDF_TYPE}> <#{cls}> }").each do |sub|
                iri = unwrap(sub["x"]) or next
                focus << iri
              end
            end
            read_select(@shapes_graph,
              "SELECT ?n WHERE { <#{parent_iri}> <#{SH_TARGET_NODE}> ?n }").each do |row|
              iri = unwrap(row["n"]) or next
              focus << iri
            end
            focus.uniq
          end
        end

        def run_fixpoint(rules)
          return empty_result if rules.empty?

          total_derived = 0
          per_rule      = Hash.new(0)
          rules_fired   = 0
          iterations    = 0
          fixpoint      = false

          @max_iterations.times do
            iterations += 1
            iteration_delta = 0

            rules.each do |rule, parent_iri|
              parent_targets(parent_iri).each do |focus_iri|
                next if rule.condition && !focus_meets_condition?(focus_iri, rule.condition)

                delta = apply_rule(rule, focus_iri)
                next if delta.zero?

                iteration_delta   += delta
                per_rule[rule.iri] += delta
                rules_fired       += 1 if per_rule[rule.iri] == delta  # first fire only
              end
            end

            total_derived += iteration_delta
            if iteration_delta.zero?
              fixpoint = true
              break
            end
          end

          envelope = {
            iterations:  iterations,
            rules_fired: per_rule.length,
            derived:     total_derived,
            per_rule:    per_rule.to_h,
            fixpoint:    fixpoint,
          }

          if fixpoint
            envelope.merge(ok: true)
          else
            ::Vv::Graph::Shacl::Rules.send(:refused,
              REASON_REASONER_DIVERGED,
              "fixpoint not reached after #{@max_iterations} iterations (derived=#{total_derived})"
            ).merge(envelope.except(:fixpoint))
          end
        end

        def empty_result
          { ok: true, iterations: 0, rules_fired: 0, derived: 0, per_rule: {}, fixpoint: true }
        end

        def apply_rule(rule, focus_iri)
          sparql =
            case rule
            when TripleRule then rewrite_triple_rule(rule, focus_iri)
            when SparqlRule then rewrite_sparql_rule(rule, focus_iri)
            else return 0
            end
          return 0 unless sparql

          result = ::Vv::Graph::Sparql.execute(sparql)
          return 0 unless result[:ok]
          result[:count].to_i
        end

        # Build INSERT WHERE for a TripleRule:
        #   WITH <inferred>
        #   INSERT { <s> <p> <o> }
        #   WHERE  { }
        # where s/p/o are resolved against the focus (sh:this → focus_iri).
        def rewrite_triple_rule(rule, focus_iri)
          s = resolve_term(rule.subject,   focus_iri, allow_literal: false)
          p = resolve_term(rule.predicate, focus_iri, allow_literal: false)
          o = resolve_term(rule.object,    focus_iri, allow_literal: true)
          return nil unless s && p && o

          <<~SPARQL
            #{PREFIX_PREAMBLE}
            WITH <#{@inferred}>
            INSERT { #{s} #{p} #{o} }
            WHERE  { }
          SPARQL
        end

        # SparqlRule's construct is a full SPARQL CONSTRUCT body.
        # We rewrite to INSERT WHERE with ?this substituted to the
        # focus IRI. Reads from data_graph + inferred so derivations
        # can chain.
        def rewrite_sparql_rule(rule, focus_iri)
          body = rule.construct.strip
          m = body.match(/\A\s*CONSTRUCT\s*\{(.+?)\}\s*WHERE\s*\{(.+)\}\s*\z/m)
          return nil unless m

          construct_block = m[1].strip
          where_block     = m[2].strip

          # ?this substitution — bind the focus directly. Phase
          # B.1 may move this to a VALUES-based binding.
          substituted_construct = construct_block.gsub(/\?this\b/, "<#{focus_iri}>")
          substituted_where     = where_block.gsub(/\?this\b/, "<#{focus_iri}>")

          <<~SPARQL
            #{PREFIX_PREAMBLE}
            WITH <#{@inferred}>
            INSERT { #{substituted_construct} }
            USING <#{@data_graph}>
            USING <#{@inferred}>
            WHERE  { #{substituted_where} }
          SPARQL
        end

        # sh:condition gating: recursively run Shacl.validate
        # against the focus + the condition shape. Returns true
        # iff zero violations are produced. The condition shape's
        # report is written to a transient graph and cleared
        # afterwards.
        def focus_meets_condition?(focus_iri, condition_shape_iri)
          transient_report = "urn:vv-graph:rules:transient-report:#{SecureRandom.uuid}"
          transient_shapes = "urn:vv-graph:rules:transient-shapes:#{SecureRandom.uuid}"

          # Copy the entire shapes_graph into transient_shapes so
          # any nested sh:property / sh:node references survive.
          # Then add `<condition> sh:targetNode <focus>` so the
          # condition shape evaluates against just this focus.
          # Other shapes in the graph still get evaluated but
          # they target via sh:targetClass — irrelevant to the
          # condition's conformance for this focus, and rules
          # don't produce validation violations.
          ::Vv::Graph::Sparql.execute(<<~SPARQL)
            INSERT { GRAPH <#{transient_shapes}> {
              ?s ?p ?o .
              <#{condition_shape_iri}> <#{SH_TARGET_NODE}> <#{focus_iri}> .
            } }
            WHERE  { GRAPH <#{@shapes_graph}> { ?s ?p ?o . } }
          SPARQL

          report = ::Vv::Graph::Shacl.validate(
            data_graph:   @data_graph,
            shapes_graph: transient_shapes,
            report_graph: transient_report,
          )

          # Did THIS focus pass the condition shape's constraints?
          # The validator returns the full violations list — narrow
          # to just this focus to ignore other shapes' violations.
          conforms_for_focus =
            if report[:ok]
              report[:violations].none? { |v| v[:focus_node] == "<#{focus_iri}>" }
            else
              # Unknown constraint components or other engine errors
              # → fail closed (rule doesn't fire). Phase B's
              # condition checking is observational; the caller's
              # rule does not surface the condition's refusal.
              false
            end

          # Clean up transient graphs
          ::Vv::Graph::Sparql.execute("CLEAR GRAPH <#{transient_shapes}>")
          ::Vv::Graph::Sparql.execute("CLEAR GRAPH <#{transient_report}>")

          conforms_for_focus
        end

        # ---- Term helpers ----

        # Resolve a rule term (subject/predicate/object) into the
        # SPARQL form. `sh:this` resolves to <focus_iri>; bare IRIs
        # pass through; literals require allow_literal:true.
        def resolve_term(term, focus_iri, allow_literal:)
          return nil if term.nil?
          if term.start_with?("<") && term.end_with?(">")
            iri = term[1..-2]
            return "<#{focus_iri}>" if iri == SH_THIS
            return term
          end
          if term.start_with?('"') && allow_literal
            return term
          end
          nil
        end

        def read_select(graph, sparql)
          r = ::Vv::Graph::Sparql.select(sparql, graph: graph)
          return [] unless r[:ok]
          r[:results]
        end

        def read_first_object(term, predicate_iri)
          rows = read_select(@shapes_graph,
            "SELECT ?o WHERE { #{format_term(term)} <#{predicate_iri}> ?o }")
          rows.first && rows.first["o"]
        end

        def read_first_lexical(term, predicate_iri)
          val = read_first_object(term, predicate_iri)
          return nil if val.nil?
          # Strip surrounding "..." for plain literals; full xsd:
          # parsing not necessary for Phase B.
          if val.is_a?(String) && val.start_with?('"')
            m = val.match(/\A"(.*)"(?:@[A-Za-z0-9-]+|\^\^<[^>]+>)?\z/m)
            return m[1] if m
          end
          val
        end

        def read_first_lexical_int(term, predicate_iri)
          lex = read_first_lexical(term, predicate_iri)
          lex && lex.to_i
        end

        def read_first_bool(term, predicate_iri)
          lex = read_first_lexical(term, predicate_iri)
          lex == "true"
        end

        def read_first_unwrapped(term, predicate_iri)
          val = read_first_object(term, predicate_iri)
          unwrap(val)
        end

        def format_term(term)
          term.to_s
        end

        def unwrap(term)
          return nil if term.nil?
          return term[1..-2] if term.is_a?(String) && term.start_with?("<") && term.end_with?(">")
          term
        end
      end
    end
  end
end
