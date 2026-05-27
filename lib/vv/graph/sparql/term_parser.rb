# frozen_string_literal: true

module Vv; end
module Vv::Graph; end
module Vv::Graph::Sparql; end unless defined?(::Vv::Graph::Sparql)

module Vv::Graph
  module Sparql
    # PLAN_0.17.0 Phase A — typed term parser.
    #
    # The engine returns SPARQL SELECT bindings as N-triples-ish
    # strings:
    #
    #   "Alpha"                                    → plain literal
    #   "42"^^<http://www.w3.org/2001/XMLSchema#integer>
    #   "fr"@en-US                                 → language-tagged literal
    #   <urn:mm:product:1>                         → IRI
    #   _:b0                                       → blank node
    #   << <s> <p> <o> >>                          → quoted triple (RDF-star)
    #
    # This module parses each cell into one of two shapes:
    #
    #   .parse_plain(raw)
    #     # => "Alpha" | 42 | true | "urn:mm:product:1" | "_:b0" | "<< ... >>"
    #     The v0.16.0 Backend::Sparql.unwrap_literal behaviour:
    #     literal quoting + typed-literal tails stripped; IRI brackets
    #     stripped; native Ruby types for xsd:integer/double/boolean.
    #
    #   .parse_typed(raw)
    #     # => { value:, kind:, datatype:, lang: }
    #     The v0.17.0 with_types: true shape:
    #     - value:    plain Ruby value (Integer/Float/Bool/String)
    #     - kind:     :iri | :literal | :blank_node | :quoted_triple | :unknown
    #     - datatype: full IRI string for typed literals, else nil
    #     - lang:     BCP47 tag for language-tagged literals, else nil
    #
    # Both parsers are side-effect-free pure functions. The Backend
    # compiler delegates to .parse_plain; Sparql.select(.., with_types:
    # true) delegates to .parse_typed.
    module TermParser
      XSD_NS = "http://www.w3.org/2001/XMLSchema#"

      XSD_INTEGER_TYPES = %w[
        integer int long short byte
        nonNegativeInteger nonPositiveInteger
        positiveInteger negativeInteger
        unsignedLong unsignedInt unsignedShort unsignedByte
      ].freeze

      XSD_FLOAT_TYPES = %w[double float decimal].freeze

      module_function

      def parse_plain(raw)
        parsed = parse_typed(raw)
        case parsed[:kind]
        when :literal
          coerce_value(parsed[:value], parsed[:datatype])
        when :iri
          parsed[:value]
        else
          parsed[:value]
        end
      end

      def parse_typed(raw)
        return { value: nil, kind: :unknown, datatype: nil, lang: nil } if raw.nil?
        return { value: raw, kind: :unknown, datatype: nil, lang: nil } unless raw.is_a?(String)

        # Quoted triple (RDF-star) — pass through verbatim; consumers
        # that need to peer inside re-parse with Sparql.split_ntriple.
        if raw.start_with?("<<") && raw.end_with?(">>")
          return { value: raw, kind: :quoted_triple, datatype: nil, lang: nil }
        end

        # IRI form
        if raw.start_with?("<") && raw.end_with?(">")
          return { value: raw[1..-2], kind: :iri, datatype: nil, lang: nil }
        end

        # Blank node
        if raw.start_with?("_:")
          return { value: raw, kind: :blank_node, datatype: nil, lang: nil }
        end

        # Typed literal: "value"^^<datatype>
        if (m = raw.match(/\A"((?:[^"\\]|\\.)*)"\^\^<([^>]+)>\z/))
          return { value: unescape(m[1]), kind: :literal, datatype: m[2], lang: nil }
        end

        # Language-tagged literal: "value"@lang
        if (m = raw.match(/\A"((?:[^"\\]|\\.)*)"@([A-Za-z][A-Za-z0-9\-]*)\z/))
          return { value: unescape(m[1]), kind: :literal, datatype: nil, lang: m[2] }
        end

        # Plain literal: "value"
        if raw.start_with?('"') && raw.end_with?('"')
          return { value: unescape(raw[1..-2]), kind: :literal, datatype: nil, lang: nil }
        end

        # Anything else — engine quirk or unrecognised form.
        { value: raw, kind: :unknown, datatype: nil, lang: nil }
      end

      # Coerce a string literal's value to a native Ruby type based
      # on its xsd: datatype. Used by .parse_plain to produce
      # Integer / Float / Boolean values.
      def coerce_value(value, datatype)
        return value if datatype.nil?
        return value unless datatype.start_with?(XSD_NS)
        suffix = datatype.sub(XSD_NS, "")
        case suffix
        when *XSD_INTEGER_TYPES then Integer(value)
        when *XSD_FLOAT_TYPES   then Float(value)
        when "boolean"          then value == "true"
        else value
        end
      rescue ArgumentError, TypeError
        value
      end

      def unescape(value)
        value.gsub(/\\(.)/, '\1')
      end
    end
  end
end
