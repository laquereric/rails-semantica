# frozen_string_literal: true

module Vv; end

module Vv::Graph
  module Backend
    # PLAN_0.16.0 Phase B — IR → ActiveRecord scope compiler.
    #
    # Lowers a flat Array<QueryIR::*> program to an AR scope chain:
    #   Find(type: :Product)              → Product.all
    #   Filter(field:, op: :eq, value:)   → .where(col => value)
    #   Filter(... op: :neq)              → .where.not(col => value)
    #   Filter(... op: :lt|:lte|:gt|:gte) → .where("col OP ?", value)
    #   FilterRange(...)                  → .where(col => lo..hi) (or lo...hi)
    #   FilterIn(...)                     → .where(col => values)
    #   Sort(field:, dir:)                → .order(col => dir)
    #   Limit(n:)                         → .limit(n)
    #   Project(fields:)                  → .pluck(*cols) → [{field => value, ...}]
    #   Count                             → .count → { ok:, count: }
    #   Compare(field:, left:, right:)    → two find_by(id: …) calls
    #
    # Result rows match the SPARQL backend's shape: an Array of
    # String-keyed Hashes with `"s"` carrying the row identifier
    # (AR primary key value stringified, mirroring SPARQL's `?s`
    # subject variable).
    #
    # Capabilities (v0.16.0):
    #   owl_closure: false  — lifted by vv-learn's future plan
    #   shacl:       false  — same
    #   joins:       :ar
    #   datetime_filter: true
    #   fts:         false
    #   named_graphs: false — `scope:` is ignored
    module Relational
      CAPABILITIES = {
        owl_closure: false,
        shacl: false,
        joins: :ar,
        datetime_filter: true,
        fts: false,
        named_graphs: false
      }.freeze

      REASON_AR_NOT_LOADED  = :ar_not_loaded
      REASON_MODEL_UNKNOWN  = :model_unknown
      REASON_AR_QUERY_ERROR = :ar_query_error

      class << self
        def capabilities
          CAPABILITIES
        end

        # Phase B — supports every IR node by lowering to AR. Capability-
        # gating (e.g. refuse OWL-closure-requiring IRs) lands in
        # Phase C when the router consults `capabilities`.
        def supports?(_ir)
          true
        end

        def execute(ir, scope: nil)
          unless defined?(::ActiveRecord::Base)
            return refuse(REASON_AR_NOT_LOADED,
                          "ActiveRecord is not loaded — relational backend cannot run")
          end

          find = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Find) }
          klass = ::Vv::Graph::Schema.resolve_model(find.type)
          unless klass
            return refuse(REASON_MODEL_UNKNOWN,
                          "Relational backend cannot resolve model #{find.type.inspect} to an ActiveRecord::Base subclass")
          end

          compare = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Compare) }
          return execute_compare(klass, find, compare) if compare

          count_node = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Count) }
          return execute_count(klass, find, ir) if count_node

          execute_select(klass, find, ir)
        rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::UnknownAttributeReference => e
          refuse(REASON_AR_QUERY_ERROR, e.message)
        end

        private

        # ── Execution shapes ─────────────────────────────────────

        def execute_select(klass, find, ir)
          scope = apply_filters_and_order(klass.all, klass, find, ir)
          project = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Project) }
          fields = projected_fields(project: project, ir: ir, find: find)
          ar_cols = fields.map { |f| ar_column_for(find: find, field: f) }
          pk = klass.primary_key

          rows = scope.pluck(pk, *ar_cols).map do |row|
            id_val, *vals = row
            hash = { "s" => id_val.to_s }
            fields.each_with_index { |f, i| hash[f.to_s] = vals[i] }
            hash
          end

          { ok: true, results: rows, from: :relational }
        end

        def execute_count(klass, find, ir)
          scope = apply_filters_and_order(klass.all, klass, find, ir,
                                          include_order: false, include_limit: false)
          { ok: true, count: scope.count, from: :relational }
        end

        def execute_compare(klass, find, compare)
          col = ar_column_for(find: find, field: compare.field)
          pk = klass.primary_key
          left  = klass.where(pk => compare.left).pick(col)
          right = klass.where(pk => compare.right).pick(col)

          {
            ok: true,
            from: :relational,
            results: [{
              "left"  => left,
              "right" => right,
              "equal" => left == right
            }]
          }
        end

        # ── Scope building ───────────────────────────────────────

        def apply_filters_and_order(scope, klass, find, ir, include_order: true, include_limit: true)
          ir.each do |node|
            case node
            when ::Vv::Graph::QueryIR::Filter
              scope = apply_filter(scope, klass, find, node)
            when ::Vv::Graph::QueryIR::FilterRange
              col = ar_column_for(find: find, field: node.field)
              if node.inclusive
                scope = scope.where(col => (node.lo..node.hi))
              else
                # Match SPARQL backend's strict-on-both-ends semantics
                # (FILTER(?v > lo && ?v < hi)); Ruby's `lo...hi` is
                # half-open (excludes only the upper bound).
                quoted = quote_col(klass, col)
                scope = scope.where("#{quoted} > ? AND #{quoted} < ?", node.lo, node.hi)
              end
            when ::Vv::Graph::QueryIR::FilterIn
              col = ar_column_for(find: find, field: node.field)
              scope = scope.where(col => node.values)
            when ::Vv::Graph::QueryIR::Sort
              next unless include_order
              col = ar_column_for(find: find, field: node.field)
              scope = scope.order(col => node.dir)
            when ::Vv::Graph::QueryIR::Limit
              next unless include_limit
              scope = scope.limit(node.n)
            end
          end
          scope
        end

        def apply_filter(scope, klass, find, node)
          col = ar_column_for(find: find, field: node.field)
          case node.op
          when :eq
            scope.where(col => node.value)
          when :neq
            scope.where.not(col => node.value)
          when :lt
            scope.where("#{quote_col(klass, col)} < ?", node.value)
          when :lte
            scope.where("#{quote_col(klass, col)} <= ?", node.value)
          when :gt
            scope.where("#{quote_col(klass, col)} > ?", node.value)
          when :gte
            scope.where("#{quote_col(klass, col)} >= ?", node.value)
          else
            raise ArgumentError,
                  "Vv::Graph::Backend::Relational: unknown Filter op #{node.op.inspect}"
          end
        end

        def projected_fields(project:, ir:, find:)
          return project.fields if project
          # Default to all schema-known fields. Without a project,
          # use the AR class's columns minus the primary key
          # (which already lands as `"s"`).
          klass = ::Vv::Graph::Schema.resolve_model(find.type)
          klass.column_names.map(&:to_sym) - [klass.primary_key.to_sym]
        end

        def ar_column_for(find:, field:)
          field_def = ::Vv::Graph::Schema.field(model: find.type, name: field)
          field_def[:ar_column] || field.to_s
        end

        def quote_col(klass, col)
          klass.connection.quote_column_name(col)
        end

        def refuse(reason, message)
          {
            ok: false,
            reason: reason,
            because: "Vv::Graph::Backend::Relational: #{message}",
            from: :relational
          }
        end
      end
    end
  end
end
