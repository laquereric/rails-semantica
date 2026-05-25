# frozen_string_literal: true

module Vv; end

module Vv::Graph
  module Shacl
    # PLAN_0.10.0 Phase B — SHACL Core validation engine.
    #
    # Walks shapes_graph for sh:NodeShape declarations, resolves
    # focus nodes against data_graph via sh:targetClass /
    # sh:targetNode, evaluates each declared constraint component
    # on each property shape, writes a W3C-conformant
    # `sh:ValidationReport` graph to report_graph.
    #
    # Multi-step pipeline:
    #   1. Clear report_graph (validation reports are not additive).
    #   2. Discover sh:NodeShape declarations in shapes_graph.
    #   3. Per shape: resolve targets → focus_nodes against data_graph.
    #   4. Per shape: discover sh:property attachments (property shapes).
    #   5. Per (focus, property_shape):
    #      - Read sh:path → predicate IRI.
    #      - Query data_graph: value nodes via SELECT ?v WHERE { focus path ?v }.
    #      - For each constraint declared on property shape:
    #        - Look up the Constraint by parameter IRI.
    #        - Call evaluator(focus:, values:, parameter:, validator: self).
    #        - If non-nil, record a violation.
    #   6. Write sh:ValidationReport + per-violation sh:ValidationResult
    #      blocks to report_graph via bulk_insert (one FFI crossing
    #      per chunk of report triples).
    #
    # Internal — operators consume via `Vv::Graph::Shacl.validate(...)`.
    class Validator
      def initialize(data_graph:, shapes_graph:, report_graph:, provenance:, library:)
        @data_graph   = data_graph
        @shapes_graph = shapes_graph
        @report_graph = report_graph
        @provenance   = provenance
        @library      = library
        @violations   = []
        @unknown_components = []
      end

      def run
        clear_report_graph!
        shapes = discover_node_shapes
        shapes.each { |shape| evaluate_shape(shape) }

        if @unknown_components.any?
          return refused(
            Shacl::REASON_UNKNOWN_CONSTRAINT_COMPONENT,
            "shapes graph references constraint component(s) not in the active library: " \
              "#{@unknown_components.uniq.inspect}",
          )
        end

        write_report

        {
          ok:           true,
          conforms:     @violations.empty?,
          violations:   @violations,
          report_graph: @report_graph,
        }
      end

      # Constraint evaluators may call this to chase sh:class with
      # rdf:type membership against data_graph. Phase B does NOT
      # chase rdfs:subClassOf transitively — Phase B.1 work; if MM
      # needs subClassOf-aware sh:class, materialise with the
      # Reasoner (PLAN_0.9.0) first and validate against the
      # combined inferred graph.
      def has_type?(value_iri, class_iri)
        r = ::Vv::Graph::Sparql.ask(
          "ASK { <#{value_iri}> <#{Shacl::RDF_TYPE}> <#{class_iri}> }",
          graph: @data_graph,
        )
        r[:ok] && r[:value]
      end

      private

      def clear_report_graph!
        ::Vv::Graph::Sparql.execute("CLEAR GRAPH <#{@report_graph}>")
      end

      def discover_node_shapes
        r = ::Vv::Graph::Sparql.select(
          "SELECT ?shape WHERE { ?shape <#{Shacl::RDF_TYPE}> <#{Shacl::SH_NODE_SHAPE}> }",
          graph: @shapes_graph,
        )
        return [] unless r[:ok]
        r[:results].map { |row| unwrap(row["shape"]) }.compact
      end

      def evaluate_shape(shape_iri)
        targets = resolve_targets(shape_iri)
        property_shapes = discover_property_shapes(shape_iri)

        targets.each do |focus_iri|
          property_shapes.each do |prop_shape|
            evaluate_property_shape(shape_iri, focus_iri, prop_shape)
          end
        end
      end

      # Returns focus_node IRIs as bare strings (without angle brackets).
      def resolve_targets(shape_iri)
        focus_nodes = []

        # sh:targetClass — every instance of the named class in data_graph
        target_classes = read_property_values(@shapes_graph, shape_iri, Shacl::SH_TARGET_CLASS)
        target_classes.each do |klass|
          klass_iri = unwrap(klass)
          next unless klass_iri
          r = ::Vv::Graph::Sparql.select(
            "SELECT ?x WHERE { ?x <#{Shacl::RDF_TYPE}> <#{klass_iri}> }",
            graph: @data_graph,
          )
          next unless r[:ok]
          r[:results].each do |row|
            iri = unwrap(row["x"])
            focus_nodes << iri if iri
          end
        end

        # sh:targetNode — direct enumeration of focus IRIs
        target_nodes = read_property_values(@shapes_graph, shape_iri, Shacl::SH_TARGET_NODE)
        target_nodes.each do |node|
          iri = unwrap(node)
          focus_nodes << iri if iri
        end

        focus_nodes.uniq
      end

      # Property shapes are blank-or-named nodes linked via sh:property
      # off the parent node shape. The IRI returned is the raw N-Triples
      # term — we use it as-is to read sh:path / sh:minCount / etc.
      def discover_property_shapes(shape_iri)
        read_property_values(@shapes_graph, shape_iri, Shacl::SH_PROPERTY)
      end

      def evaluate_property_shape(shape_iri, focus_iri, prop_shape_term)
        # sh:path — currently must be an IRI (Phase B limit). Path
        # expressions (sh:inversePath, sh:alternativePath, etc.)
        # are Phase B.1.
        path_terms = read_property_values_for_term(@shapes_graph, prop_shape_term, Shacl::SH_PATH)
        return if path_terms.empty?
        path_iri = unwrap(path_terms.first)
        return unless path_iri

        # Value nodes via the data graph
        value_nodes = read_property_values(@data_graph, focus_iri, path_iri)

        # Discover declared constraint parameters on this property
        # shape — every triple with subject = property shape term
        # and predicate matching a Constraint.parameter is a
        # constraint declaration.
        declared = constraint_declarations(prop_shape_term)

        # sh:in's parameter is an RDF list — Phase B accepts a
        # flat enumeration via repeated triples for ergonomics,
        # OR a single rdf:List head; the validator resolves both.
        # Phase B.1: full RDF list traversal.
        declared.each do |parameter_iri, parameter_value|
          constraint = @library.by_parameter(parameter_iri)
          unless constraint
            @unknown_components << parameter_iri
            next
          end

          # sh:in special-case: collect every parameter_value
          # triple (not just one) and pass as an Array.
          if parameter_iri == "#{Shacl::SH}in"
            parameter_value = resolve_in_list(prop_shape_term, parameter_value)
          end

          result = constraint.evaluator.call(
            focus:     focus_iri,
            values:    value_nodes,
            parameter: parameter_value,
            validator: self,
          )
          next if result.nil?

          @violations << build_violation(
            shape_iri:       shape_iri,
            focus_iri:       focus_iri,
            path_iri:        path_iri,
            prop_shape_term: prop_shape_term,
            constraint:      constraint,
            message:         constraint.message_for(
                              focus:            focus_iri,
                              values:           value_nodes,
                              parameter:        parameter_value,
                              evaluator_result: result,
                            ),
          )
        end
      end

      # Returns the list of (parameter_iri, parameter_value) pairs
      # for the given property shape — every triple where the
      # subject is the property shape and the predicate is
      # something in shapes_graph that we recognise as a Constraint
      # parameter OR is in PHASE_B_PENDING.
      def constraint_declarations(prop_shape_term)
        # Get every (predicate, object) pair for this property shape
        r = ::Vv::Graph::Sparql.select(
          "SELECT ?p ?o WHERE { #{format_subject(prop_shape_term)} ?p ?o }",
          graph: @shapes_graph,
        )
        return [] unless r[:ok]

        results = []
        r[:results].each do |row|
          predicate_iri = unwrap(row["p"])
          next unless predicate_iri
          # Only declarations that match a known parameter or a
          # PHASE_B_PENDING component flow through as constraints.
          # All other predicates (sh:path, sh:name, sh:description)
          # are not constraints.
          next unless @library.by_parameter(predicate_iri) ||
                      pending_parameter?(predicate_iri)
          results << [predicate_iri, row["o"]]
        end
        results
      end

      # PHASE_B_PENDING tracks the constraint *component* IRIs.
      # The parameter IRI of e.g. sh:NotConstraintComponent is
      # sh:not. We don't have a clean mapping from parameter to
      # component IRI for pending entries, so for Phase B we
      # whitelist a small set of "known but unimplemented"
      # parameter IRIs to surface as :unknown_constraint_component
      # refusals.
      PENDING_PARAMETERS = %w[
        http://www.w3.org/ns/shacl#not
        http://www.w3.org/ns/shacl#and
        http://www.w3.org/ns/shacl#or
        http://www.w3.org/ns/shacl#xone
        http://www.w3.org/ns/shacl#node
        http://www.w3.org/ns/shacl#closed
        http://www.w3.org/ns/shacl#ignoredProperties
        http://www.w3.org/ns/shacl#equals
        http://www.w3.org/ns/shacl#disjoint
        http://www.w3.org/ns/shacl#lessThan
        http://www.w3.org/ns/shacl#lessThanOrEquals
        http://www.w3.org/ns/shacl#languageIn
        http://www.w3.org/ns/shacl#uniqueLang
        http://www.w3.org/ns/shacl#qualifiedValueShape
      ].freeze

      def pending_parameter?(parameter_iri)
        PENDING_PARAMETERS.include?(parameter_iri)
      end

      # Phase B's interim sh:in parameter handling: collect every
      # `<prop_shape> sh:in ?v` triple and return the values as an
      # Array. Real SHACL sh:in is a single RDF list — full RDF
      # list traversal lands in Phase B.1.
      def resolve_in_list(prop_shape_term, _initial_value)
        r = ::Vv::Graph::Sparql.select(
          "SELECT ?o WHERE { #{format_subject(prop_shape_term)} <#{Shacl::SH}in> ?o }",
          graph: @shapes_graph,
        )
        return [] unless r[:ok]
        r[:results].map { |row| row["o"] }
      end

      # Read all `<subject> <predicate> ?o` triples in `graph` and
      # return the objects in N-Triples form.
      def read_property_values(graph, subject_iri, predicate_iri)
        r = ::Vv::Graph::Sparql.select(
          "SELECT ?o WHERE { <#{subject_iri}> <#{predicate_iri}> ?o }",
          graph: graph,
        )
        return [] unless r[:ok]
        r[:results].map { |row| row["o"] }
      end

      # Same, but the subject is already a raw N-Triples term
      # (operators may emit property shapes as blank nodes).
      def read_property_values_for_term(graph, subject_term, predicate_iri)
        r = ::Vv::Graph::Sparql.select(
          "SELECT ?o WHERE { #{format_subject(subject_term)} <#{predicate_iri}> ?o }",
          graph: graph,
        )
        return [] unless r[:ok]
        r[:results].map { |row| row["o"] }
      end

      # Subject formatting: IRI terms in N-Triples come back
      # already-wrapped (`<urn:foo>`); blank nodes as `_:b1`. Pass
      # through verbatim.
      def format_subject(term)
        term.to_s
      end

      def unwrap(term)
        return nil if term.nil?
        return term[1..-2] if term.start_with?("<") && term.end_with?(">")
        term
      end

      def build_violation(shape_iri:, focus_iri:, path_iri:, prop_shape_term:,
                          constraint:, message:)
        {
          focus_node:                   "<#{focus_iri}>",
          path:                         "<#{path_iri}>",
          source_shape:                 prop_shape_term,
          source_constraint_component:  "<#{constraint.iri}>",
          severity:                     "<#{Shacl::SH_VIOLATION}>",
          value:                        nil,
          message:                      message,
        }
      end

      # Emit the sh:ValidationReport + per-violation sh:ValidationResult
      # blocks. Single bulk_insert call per chunk so the round-trip is
      # one FFI crossing per ~N triples.
      def write_report
        report_node = "urn:vv-graph:validation-report:#{SecureRandom.uuid}"

        # All rows in raw N-Triples engine form so bulk_insert(raw:true)
        # passes them through without TermSerializer wrapping. Bare
        # IRIs in s/p columns; bare IRI in o column or N-Triples
        # literal `"…"^^<…>` form.
        rows = [
          [report_node, Shacl::RDF_TYPE, Shacl::SH_VALIDATION_REPORT, @report_graph],
          [report_node, Shacl::SH_CONFORMS,
           "\"#{@violations.empty?}\"^^<http://www.w3.org/2001/XMLSchema#boolean>",
           @report_graph],
        ]

        @violations.each do |v|
          result_node = "urn:vv-graph:validation-result:#{SecureRandom.uuid}"
          rows << [result_node, Shacl::RDF_TYPE,         Shacl::SH_VALIDATION_RESULT, @report_graph]
          rows << [result_node, Shacl::SH_FOCUS_NODE,    strip_brackets(v[:focus_node]),                     @report_graph]
          rows << [result_node, Shacl::SH_RESULT_PATH,   strip_brackets(v[:path]),                           @report_graph]
          rows << [result_node, Shacl::SH_SOURCE_SHAPE,  strip_brackets(v[:source_shape]),                   @report_graph]
          rows << [result_node, Shacl::SH_SOURCE_CONSTRAINT_CMP, strip_brackets(v[:source_constraint_component]), @report_graph]
          rows << [result_node, Shacl::SH_RESULT_SEVERITY, strip_brackets(v[:severity]),                     @report_graph]
          rows << [result_node, Shacl::SH_RESULT_MESSAGE,
                   "\"#{v[:message].gsub('"', '\\"')}\"",
                   @report_graph]
          rows << [report_node, Shacl::SH_RESULT,        result_node,                 @report_graph]
        end

        ::Vv::Graph::Sparql.bulk_insert(rows, raw: true) unless rows.empty?
      end

      def strip_brackets(term)
        return term unless term.is_a?(String)
        return term[1..-2] if term.start_with?("<") && term.end_with?(">")
        term
      end

      def refused(reason, because)
        { ok: false, reason: reason, because: because.to_s }
      end
    end
  end
end
