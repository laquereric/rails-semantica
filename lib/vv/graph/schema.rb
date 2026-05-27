# frozen_string_literal: true

module Vv; end

module Vv::Graph
  # PLAN_0.16.0 Phase A — minimal Schema adapter.
  #
  # Resolves symbolic `field:` references in a QueryIR program to a
  # storage-plane-specific surface. Phase A only needs the SPARQL
  # side (an `iri:` per field). Phase B adds `ar_column:`; Phase D
  # adds AR-introspection-first lookup + `:schema` scope reads.
  #
  #   Vv::Graph::Schema.field(model: :Product, name: :brand)
  #   # => { iri: "mm:Product/brand",
  #   #      ar_column: nil,
  #   #      xsd: nil,
  #   #      supports_closure: false }
  #
  # The IRI is computed from the configurable `iri_prefix` (default
  # `mm:`); the convention is `<prefix><Model>/<field>`. Operators
  # with non-default mappings register overrides via the
  # `Vv::Graph::Schema.override(...)` table — Phase A ships a Ruby
  # hash; Phase D revisits whether YAML / `:schema` scope is the
  # canonical source.
  module Schema
    DEFAULT_IRI_PREFIX = "mm:"

    class << self
      def iri_prefix
        @iri_prefix ||= DEFAULT_IRI_PREFIX
      end

      def iri_prefix=(prefix)
        @iri_prefix = prefix
      end

      def overrides
        @overrides ||= {}
      end

      def reset!
        @iri_prefix = DEFAULT_IRI_PREFIX
        @overrides = {}
      end

      # Register an explicit field mapping. Used by operators whose
      # IRI shape diverges from the `<prefix><Model>/<field>` default
      # or whose AR column name differs from the field name.
      #
      #   Vv::Graph::Schema.override(
      #     model: :Product, name: :brand,
      #     iri: "mm:Product/brandName",
      #     ar_column: "brand_name",
      #   )
      def override(model:, name:, iri: nil, ar_column: nil, xsd: nil, supports_closure: false)
        key = key_for(model: model, name: name)
        overrides[key] = {
          iri: iri,
          ar_column: ar_column,
          xsd: xsd,
          supports_closure: supports_closure
        }.compact
      end

      def field(model:, name:)
        key = key_for(model: model, name: name)
        defaults = {
          iri: default_iri_for(model: model, name: name),
          ar_column: nil,
          xsd: nil,
          supports_closure: false
        }
        defaults.merge(overrides.fetch(key, {}))
      end

      # Resolve a type symbol (Find#type) to the class IRI used in
      # `?s a <iri>` rdf:type filters. Same convention as field IRIs
      # minus the `/<field>` suffix.
      def class_iri(type)
        "#{iri_prefix}#{type}"
      end

      private

      def key_for(model:, name:)
        [model.to_sym, name.to_sym]
      end

      def default_iri_for(model:, name:)
        "#{iri_prefix}#{model}/#{name}"
      end
    end
  end
end
