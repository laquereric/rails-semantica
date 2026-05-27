# frozen_string_literal: true

module Vv; end

module Vv::Graph
  # PLAN_0.16.0 Phase A → B — Schema adapter.
  #
  # Resolves symbolic `field:` references in a QueryIR program to a
  # storage-plane-specific surface (`iri:` for the SPARQL backend;
  # `ar_column:` + `xsd:` for the Relational backend).
  #
  # Phase A shipped prefix-based defaults + a Ruby-hash override
  # table. Phase B adds **AR introspection**: when a model symbol
  # resolves to an `ActiveRecord::Base` subclass with the column
  # present, `ar_column:` and `xsd:` populate from
  # `connection.columns(table_name)`. Phase D adds the `:schema`
  # scope read path (operator-emitted RDF schema graph).
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
        ar_info = ar_introspect(model: model, name: name)
        defaults = {
          iri: default_iri_for(model: model, name: name),
          ar_column: ar_info[:ar_column],
          xsd: ar_info[:xsd],
          supports_closure: false
        }
        defaults.merge(overrides.fetch(key, {}))
      end

      # Resolve a model symbol or class to an ActiveRecord::Base
      # subclass. Symbols constantize against the top-level
      # namespace (`:Product` → `::Product`); already-class inputs
      # pass through. Returns nil when AR isn't loaded or the
      # constant can't be resolved.
      def resolve_model(model)
        return model if model.is_a?(Class) && defined?(::ActiveRecord::Base) && model < ::ActiveRecord::Base
        return nil unless defined?(::ActiveRecord::Base)
        sym = model.to_sym
        return nil unless Object.const_defined?(sym)
        const = Object.const_get(sym)
        return const if const.is_a?(Class) && const < ::ActiveRecord::Base
        nil
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

      # AR introspection. Returns { ar_column:, xsd: } when the
      # model symbol resolves to an AR class with the column
      # present; { ar_column: nil, xsd: nil } otherwise.
      #
      # The fall-back convention is "ar_column = field name" when
      # introspection isn't possible — the Relational compiler can
      # still issue a `.where(field => value)` call and let AR
      # raise `ActiveRecord::StatementInvalid` if the column truly
      # doesn't exist.
      def ar_introspect(model:, name:)
        klass = resolve_model(model)
        return { ar_column: name.to_s, xsd: nil } unless klass

        column_name = name.to_s
        column = klass.columns_hash[column_name]
        return { ar_column: column_name, xsd: nil } unless column

        { ar_column: column_name, xsd: xsd_for_ar_type(column.type) }
      end

      AR_TYPE_TO_XSD = {
        string:   "xsd:string",
        text:     "xsd:string",
        integer:  "xsd:integer",
        bigint:   "xsd:integer",
        float:    "xsd:double",
        decimal:  "xsd:decimal",
        boolean:  "xsd:boolean",
        date:     "xsd:date",
        datetime: "xsd:dateTime",
        time:     "xsd:time",
        binary:   "xsd:base64Binary"
      }.freeze

      def xsd_for_ar_type(type)
        AR_TYPE_TO_XSD[type.to_sym]
      end
    end
  end
end
