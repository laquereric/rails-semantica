# frozen_string_literal: true

require "securerandom"

module Semantica
  # PLAN_0.10.0 — `Semantica::Shacl` — SHACL Core constraint validation.
  #
  # Phase A (#5d70317) shipped the facade module, refusal symbols,
  # the Constraint + ConstraintLibrary value objects, and an empty
  # Constraints::Core. Phase B (this commit) implements the
  # validation engine + transcribes a core subset of the W3C SHACL
  # Rec section 4 constraint component catalogue.
  #
  #   Semantica::Shacl.validate(
  #     data_graph:   "urn:mm:graph:catalogue",
  #     shapes_graph: "urn:semantica:shapes:product",
  #     report_graph: "urn:mm:graph:catalogue:report",
  #   )
  #   # => { ok: true,
  #   #      conforms: false,
  #   #      violations: [
  #   #        { focus_node: "<urn:mm:product:1>", path: "<schema:gtin>",
  #   #          source_shape: "<urn:semantica:shape:Product/gtin>",
  #   #          source_constraint_component: "<http://www.w3.org/ns/shacl#MinCountConstraintComponent>",
  #   #          severity: "<http://www.w3.org/ns/shacl#Violation>",
  #   #          value: nil,
  #   #          message: "expected at least 1 value(s); got 0" },
  #   #        ...
  #   #      ],
  #   #      report_graph: "urn:mm:graph:catalogue:report" }
  #
  # Phase B scope (vs. PLAN_0.10.0's full Phase B contract):
  #
  # IN SCOPE
  #   - sh:NodeShape with sh:targetClass + sh:targetNode targets
  #   - sh:property attachments with IRI-only sh:path (no path
  #     expressions like sh:inversePath / sh:alternativePath /
  #     sh:zeroOrMorePath — those need recursive SPARQL property
  #     paths, deferred to Phase B.1)
  #   - 12 constraint components — see Constraints::Core list
  #   - Validation report as a `sh:ValidationReport` graph with
  #     `sh:result` linking to per-violation `sh:ValidationResult`
  #     nodes carrying the six pinned PLAN_0.10.0 predicates
  #
  # PHASE B.1 / B.2 (deferred — see Constraints::PHASE_B_PENDING)
  #   - The remaining ~18 SHACL Core constraint components
  #     (sh:not, sh:and, sh:or, sh:xone, sh:node, sh:qualified*,
  #      sh:closed, sh:ignoredProperties, sh:equals, sh:disjoint,
  #      sh:lessThan, sh:lessThanOrEquals, sh:languageIn,
  #      sh:uniqueLang, sh:targetSubjectsOf, sh:targetObjectsOf)
  #   - SHACL-SPARQL embedded `sh:select` constraints
  #   - Custom constraint component definitions
  #   - sh:closed semantics
  #   - sh:resultSeverity overrides (Phase B defaults all to sh:Violation)
  #   - sh:message operator overrides (Phase B uses default messages)
  #
  # Refusal envelopes (Phase B):
  #   :invalid_graph                — blank-node IRI
  #   :unknown_constraint_component — shape uses a parameter predicate
  #                                    whose component isn't in
  #                                    Constraints::Core or
  #                                    Constraints::PHASE_B_PENDING
  module Shacl
    REASON_INVALID_GRAPH                = :invalid_graph
    REASON_SHAPE_PARSE_ERROR            = :shape_parse_error
    REASON_UNKNOWN_CONSTRAINT_COMPONENT = :unknown_constraint_component
    REASON_CYCLE_DETECTED               = :cycle_detected

    # SHACL Core namespace + key term IRIs. Pinned here so the
    # validator's SPARQL strings can reference them without
    # spreading the namespace across the codebase.
    SH                = "http://www.w3.org/ns/shacl#"
    SH_NODE_SHAPE     = "#{SH}NodeShape"
    SH_PROPERTY_SHAPE = "#{SH}PropertyShape"
    SH_TARGET_CLASS   = "#{SH}targetClass"
    SH_TARGET_NODE    = "#{SH}targetNode"
    SH_PROPERTY       = "#{SH}property"
    SH_PATH           = "#{SH}path"
    SH_VIOLATION      = "#{SH}Violation"
    SH_VALIDATION_REPORT = "#{SH}ValidationReport"
    SH_VALIDATION_RESULT = "#{SH}ValidationResult"
    SH_CONFORMS              = "#{SH}conforms"
    SH_RESULT                = "#{SH}result"
    SH_FOCUS_NODE            = "#{SH}focusNode"
    SH_RESULT_PATH           = "#{SH}resultPath"
    SH_SOURCE_SHAPE          = "#{SH}sourceShape"
    SH_SOURCE_CONSTRAINT_CMP = "#{SH}sourceConstraintComponent"
    SH_RESULT_SEVERITY       = "#{SH}resultSeverity"
    SH_RESULT_MESSAGE        = "#{SH}resultMessage"
    SH_VALUE                 = "#{SH}value"

    RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

    # Phase B value object. The `evaluator` is a Ruby callable —
    # PLAN_0.10.0 Phase B's `validates: <<~SPARQL` shape is more
    # ergonomic on paper but harder to compose (each component
    # would need its own SPARQL aggregation). The Ruby evaluator
    # receives the focus node, the value nodes returned from the
    # sh:path SELECT, and the constraint's parameter value;
    # returns nil (conforms) or a violation message.
    #
    # `parameter` is the IRI of the SHACL predicate that carries
    # the constraint's value on a property shape (e.g.,
    # "http://www.w3.org/ns/shacl#minCount"). The validator
    # discovers constraints by looking for the parameter predicate
    # on a property shape.
    Constraint = Struct.new(:iri, :name, :parameter, :evaluator,
                            :default_message, keyword_init: true) do
      def initialize(iri:, name:, parameter:, evaluator:,
                     default_message: nil)
        super
        freeze
      end

      # The validator calls this when a focus + value-set + parameter
      # combo violates the constraint. Returns the violation message;
      # falls back to the constraint name if no default_message is
      # set + the evaluator returns just a plain message string.
      def message_for(focus:, values:, parameter:, evaluator_result:)
        return evaluator_result if evaluator_result.is_a?(String)
        return default_message.call(focus, values, parameter) if default_message
        "#{name} violated"
      end
    end

    # Registry keyed by Constraint IRI. Composable by `+`.
    class ConstraintLibrary
      include Enumerable

      attr_reader :constraints

      def initialize(constraints = [])
        @constraints  = constraints.freeze
        @by_iri       = constraints.each_with_object({}) { |c, h| h[c.iri] = c }.freeze
        @by_parameter = constraints.each_with_object({}) { |c, h| h[c.parameter] = c }.freeze
        freeze
      end

      def each(&block)         = constraints.each(&block)
      def empty?               = constraints.empty?
      def length               = constraints.length
      def [](iri)              = @by_iri[iri]
      def by_parameter(p_iri)  = @by_parameter[p_iri]
      def +(other)             = ConstraintLibrary.new(constraints + other.constraints)
    end

    module Constraints
      # IRIs of SHACL Core constraint components NOT yet implemented
      # in Constraints::Core. The validator refuses with
      # :unknown_constraint_component when a shape uses a parameter
      # whose component IRI is in this set (vs. silently ignoring
      # the constraint — operators see the gap rather than a false
      # "conforms").
      PHASE_B_PENDING = %w[
        http://www.w3.org/ns/shacl#NotConstraintComponent
        http://www.w3.org/ns/shacl#AndConstraintComponent
        http://www.w3.org/ns/shacl#OrConstraintComponent
        http://www.w3.org/ns/shacl#XoneConstraintComponent
        http://www.w3.org/ns/shacl#NodeConstraintComponent
        http://www.w3.org/ns/shacl#QualifiedValueShapeConstraintComponent
        http://www.w3.org/ns/shacl#QualifiedMinCountConstraintComponent
        http://www.w3.org/ns/shacl#QualifiedMaxCountConstraintComponent
        http://www.w3.org/ns/shacl#ClosedConstraintComponent
        http://www.w3.org/ns/shacl#IgnoredPropertiesConstraintComponent
        http://www.w3.org/ns/shacl#EqualsConstraintComponent
        http://www.w3.org/ns/shacl#DisjointConstraintComponent
        http://www.w3.org/ns/shacl#LessThanConstraintComponent
        http://www.w3.org/ns/shacl#LessThanOrEqualsConstraintComponent
        http://www.w3.org/ns/shacl#LanguageInConstraintComponent
        http://www.w3.org/ns/shacl#UniqueLangConstraintComponent
      ].freeze

      # ----- Helper: extract literal lexical value from N-Triples form -----
      #
      # Constraint evaluators receive value nodes in N-Triples
      # encoding (e.g., `"hello"`, `"42"^^<xsd:integer>`, `<urn:foo>`).
      # Most constraints need the bare value — strip the wrapping.
      def self.lexical(term)
        return nil if term.nil?
        m = term.match(/\A"(.*)"(?:@[A-Za-z0-9-]+|\^\^<[^>]+>)?\z/)
        return m[1] if m
        # IRI form
        m = term.match(/\A<(.+)>\z/)
        return m[1] if m
        term
      end

      # Returns the IRI of the datatype (or rdf:langString for
      # lang-tagged literals) for a literal value; nil for an IRI
      # or blank-node value.
      def self.datatype_of(term)
        return nil unless term.is_a?(String) && term.start_with?('"')
        if (m = term.match(/\^\^<([^>]+)>\z/))
          m[1]
        elsif term.match?(/@[A-Za-z0-9-]+\z/)
          "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"
        else
          "http://www.w3.org/2001/XMLSchema#string"
        end
      end

      # Phase B core subset — 12 most-used SHACL Core constraint
      # components. Picked for "constraints MM is most likely to
      # reach for" coverage: cardinality, value-type, value-range,
      # string-shape (length + regex), enumeration, exact-value.
      Core = ConstraintLibrary.new([
        Constraint.new(
          iri:       "#{SH}MinCountConstraintComponent",
          name:      "sh:minCount",
          parameter: "#{SH}minCount",
          evaluator: ->(focus:, values:, parameter:, **) {
            min = Constraints.lexical(parameter).to_i
            actual = values.length
            actual < min ? "expected at least #{min} value(s); got #{actual}" : nil
          },
        ),
        Constraint.new(
          iri:       "#{SH}MaxCountConstraintComponent",
          name:      "sh:maxCount",
          parameter: "#{SH}maxCount",
          evaluator: ->(focus:, values:, parameter:, **) {
            max = Constraints.lexical(parameter).to_i
            actual = values.length
            actual > max ? "expected at most #{max} value(s); got #{actual}" : nil
          },
        ),
        Constraint.new(
          iri:       "#{SH}DatatypeConstraintComponent",
          name:      "sh:datatype",
          parameter: "#{SH}datatype",
          evaluator: ->(focus:, values:, parameter:, **) {
            expected = Constraints.lexical(parameter)
            offenders = values.reject { |v| Constraints.datatype_of(v) == expected }
            return nil if offenders.empty?
            "expected sh:datatype <#{expected}>; got values with datatype(s) " \
              "#{offenders.map { |v| Constraints.datatype_of(v) || "IRI/BlankNode" }.uniq}"
          },
        ),
        Constraint.new(
          iri:       "#{SH}NodeKindConstraintComponent",
          name:      "sh:nodeKind",
          parameter: "#{SH}nodeKind",
          evaluator: ->(focus:, values:, parameter:, **) {
            kind = Constraints.lexical(parameter)
            # Phase B implements the three common kinds; rare ones
            # (BlankNodeOrIRI etc.) fall through as "OK".
            offenders = values.reject do |v|
              case kind
              when "#{SH}IRI"      then v.start_with?("<") && v.end_with?(">")
              when "#{SH}Literal"  then v.start_with?('"')
              when "#{SH}BlankNode" then v.start_with?("_:")
              else true   # Unknown kinds pass through; future tightening
              end
            end
            offenders.empty? ? nil : "expected sh:nodeKind <#{kind}>; some values are not that kind"
          },
        ),
        Constraint.new(
          iri:       "#{SH}ClassConstraintComponent",
          name:      "sh:class",
          parameter: "#{SH}class",
          evaluator: ->(focus:, values:, parameter:, validator:, **) {
            expected_class = Constraints.lexical(parameter)
            offenders = values.reject do |v|
              v_iri = Constraints.lexical(v)
              next false unless v.start_with?("<")
              validator.has_type?(v_iri, expected_class)
            end
            offenders.empty? ? nil : "expected sh:class <#{expected_class}>; some values lack rdf:type"
          },
        ),
        Constraint.new(
          iri:       "#{SH}PatternConstraintComponent",
          name:      "sh:pattern",
          parameter: "#{SH}pattern",
          evaluator: ->(focus:, values:, parameter:, **) {
            regex_src = Constraints.lexical(parameter)
            regex = Regexp.new(regex_src)
            offenders = values.reject do |v|
              next false unless v.start_with?('"')
              lex = Constraints.lexical(v)
              lex && regex.match?(lex)
            end
            offenders.empty? ? nil : "expected sh:pattern #{regex_src.inspect}; some values don't match"
          },
        ),
        Constraint.new(
          iri:       "#{SH}MinLengthConstraintComponent",
          name:      "sh:minLength",
          parameter: "#{SH}minLength",
          evaluator: ->(focus:, values:, parameter:, **) {
            min = Constraints.lexical(parameter).to_i
            offenders = values.reject do |v|
              next false unless v.start_with?('"')
              (Constraints.lexical(v) || "").length >= min
            end
            offenders.empty? ? nil : "expected sh:minLength #{min}; some values are shorter"
          },
        ),
        Constraint.new(
          iri:       "#{SH}MaxLengthConstraintComponent",
          name:      "sh:maxLength",
          parameter: "#{SH}maxLength",
          evaluator: ->(focus:, values:, parameter:, **) {
            max = Constraints.lexical(parameter).to_i
            offenders = values.reject do |v|
              next false unless v.start_with?('"')
              (Constraints.lexical(v) || "").length <= max
            end
            offenders.empty? ? nil : "expected sh:maxLength #{max}; some values are longer"
          },
        ),
        Constraint.new(
          iri:       "#{SH}HasValueConstraintComponent",
          name:      "sh:hasValue",
          parameter: "#{SH}hasValue",
          evaluator: ->(focus:, values:, parameter:, **) {
            # parameter arrives in N-Triples form — direct equality
            # match against the value nodes (which are also in
            # N-Triples form). Phase B does not normalize datatype
            # IRIs (xsd:string vs no-datatype) — Phase B.1 work.
            values.include?(parameter) ? nil : "expected sh:hasValue #{parameter} among values"
          },
        ),
        Constraint.new(
          iri:       "#{SH}InConstraintComponent",
          name:      "sh:in",
          parameter: "#{SH}in",
          # sh:in's parameter is itself an RDF list. Phase B
          # accepts the parameter as a comma-separated-N-Triples
          # string; the validator resolves the actual list members
          # before passing it in. (See Validator#resolve_in_list.)
          evaluator: ->(focus:, values:, parameter:, **) {
            allowed = parameter.is_a?(Array) ? parameter : []
            offenders = values.reject { |v| allowed.include?(v) }
            offenders.empty? ? nil : "expected sh:in #{allowed.inspect}; some values are not in the set"
          },
        ),
        Constraint.new(
          iri:       "#{SH}MinInclusiveConstraintComponent",
          name:      "sh:minInclusive",
          parameter: "#{SH}minInclusive",
          evaluator: ->(focus:, values:, parameter:, **) {
            min = Constraints.lexical(parameter).to_f
            offenders = values.reject do |v|
              next false unless v.start_with?('"')
              Constraints.lexical(v).to_f >= min
            end
            offenders.empty? ? nil : "expected sh:minInclusive #{min}; some values are below"
          },
        ),
        Constraint.new(
          iri:       "#{SH}MaxInclusiveConstraintComponent",
          name:      "sh:maxInclusive",
          parameter: "#{SH}maxInclusive",
          evaluator: ->(focus:, values:, parameter:, **) {
            max = Constraints.lexical(parameter).to_f
            offenders = values.reject do |v|
              next false unless v.start_with?('"')
              Constraints.lexical(v).to_f <= max
            end
            offenders.empty? ? nil : "expected sh:maxInclusive #{max}; some values are above"
          },
        ),
      ])
    end

    module_function

    def validate(data_graph:, shapes_graph:, report_graph: nil, provenance: true,
                 constraint_library: Constraints::Core)
      graph_error = validate_graphs(data_graph, shapes_graph, report_graph)
      return graph_error if graph_error

      report_graph ||= "#{data_graph}:report"

      Validator.new(
        data_graph:   data_graph,
        shapes_graph: shapes_graph,
        report_graph: report_graph,
        provenance:   provenance,
        library:      constraint_library,
      ).run
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

require_relative "shacl/validator"
