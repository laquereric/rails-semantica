# frozen_string_literal: true

module Vv; end

module Vv::Graph
  module QueryIR
    # PLAN_0.16.0 Phase A — frozen algebra value objects.
    #
    # Each node is a keyword-init Struct that freezes on construction.
    # Composition is a flat Array<QueryIR::*> passed to `QueryIR.run`.
    # The algebra is intentionally narrow: nine node types, one Find
    # (required, first), one Limit max, one Sort max for v0.16.0
    # (multi-sort additive in v0.17.0).

    Find = Struct.new(:type, :scope, keyword_init: true) do
      def initialize(type:, scope: nil)
        super(type: type, scope: scope)
        freeze
      end
    end

    Filter = Struct.new(:field, :op, :value, keyword_init: true) do
      OPS = %i[eq neq lt lte gt gte].freeze

      def initialize(field:, op:, value:)
        super(field: field, op: op, value: value)
        freeze
      end
    end

    FilterRange = Struct.new(:field, :lo, :hi, :inclusive, keyword_init: true) do
      def initialize(field:, lo:, hi:, inclusive: true)
        super(field: field, lo: lo, hi: hi, inclusive: inclusive)
        freeze
      end
    end

    FilterIn = Struct.new(:field, :values, keyword_init: true) do
      def initialize(field:, values:)
        super(field: field, values: values.to_a.freeze)
        freeze
      end
    end

    Sort = Struct.new(:field, :dir, keyword_init: true) do
      DIRS = %i[asc desc].freeze

      def initialize(field:, dir: :asc)
        super(field: field, dir: dir)
        freeze
      end
    end

    Limit = Struct.new(:n, keyword_init: true) do
      def initialize(n:)
        super(n: n)
        freeze
      end
    end

    Project = Struct.new(:fields, keyword_init: true) do
      def initialize(fields:)
        super(fields: fields.to_a.freeze)
        freeze
      end
    end

    Count = Struct.new(keyword_init: true) do
      def initialize
        super()
        freeze
      end
    end

    # Pair-compare convenience: bind ?left + ?right for the same
    # field on two different focus IRIs. Backends decide whether
    # to materialise the comparison gem-side or push it down. On
    # SPARQL: two `SELECT ?val WHERE { <iri> <p> ?val }` queries
    # paired in Ruby. On Relational: two `find_by` calls.
    Compare = Struct.new(:field, :left, :right, keyword_init: true) do
      def initialize(field:, left:, right:)
        super(field: field, left: left, right: right)
        freeze
      end
    end
  end
end
