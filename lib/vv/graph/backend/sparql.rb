# frozen_string_literal: true

require "date"
require "time"

module Vv; end

module Vv::Graph
  module Backend
    # PLAN_0.16.0 Phase A — IR → SPARQL compiler + executor.
    #
    # Lowers a flat Array<QueryIR::*> program to a SPARQL string and
    # dispatches through Vv::Graph::Sparql.{select,ask}. Returns the
    # same envelope shape the existing SPARQL facade emits, plus an
    # `from: :sparql` field naming the backend that served the call.
    #
    # Phase A scope: `Find`, `Filter` (eq/neq/lt/lte/gt/gte),
    # `FilterRange`, `FilterIn`, `Sort` (asc/desc), `Limit`,
    # `Project`, `Count`, `Compare`. The compiler is intentionally
    # straightforward — the cleverness lives in the IR's narrowness,
    # not the compiler.
    module Sparql
      CAPABILITIES = {
        owl_closure: true,
        shacl: true,
        joins: :rdf,
        datetime_filter: true,
        fts: false,
        named_graphs: true
      }.freeze

      class << self
        def capabilities
          CAPABILITIES
        end

        # Phase A — every IR program the algebra admits is
        # SPARQL-compilable. Phase C may refine this when
        # capability gating lands.
        def supports?(_ir)
          true
        end

        def execute(ir, scope: nil)
          compare = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Compare) }
          return execute_compare(ir, compare, scope: scope) if compare

          count_node = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Count) }
          return execute_count(ir, scope: scope) if count_node

          execute_select(ir, scope: scope)
        end

        private

        # ── Compilation entry points ─────────────────────────────

        def execute_select(ir, scope:)
          query = compile_select(ir)
          env = ::Vv::Graph::Sparql.select(query, graph: scope)
          return env.merge(from: :sparql, query: query) unless env[:ok]
          { ok: true, results: unwrap_rows(env[:results]), from: :sparql, query: query }
        end

        def execute_count(ir, scope:)
          query = compile_count(ir)
          env = ::Vv::Graph::Sparql.select(query, graph: scope)
          return env.merge(from: :sparql, query: query) unless env[:ok]
          row = env[:results].first || {}
          raw = row["count"] || row[:count] || 0
          count = unwrap_literal(raw).to_i
          { ok: true, count: count, from: :sparql, query: query }
        end

        def execute_compare(ir, compare, scope:)
          find = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Find) }
          left  = compile_compare_lookup(find: find, focus: compare.left,  field: compare.field)
          right = compile_compare_lookup(find: find, focus: compare.right, field: compare.field)

          left_env  = ::Vv::Graph::Sparql.select(left,  graph: scope)
          return left_env.merge(from: :sparql)  unless left_env[:ok]
          right_env = ::Vv::Graph::Sparql.select(right, graph: scope)
          return right_env.merge(from: :sparql) unless right_env[:ok]

          left_val  = unwrap_literal((left_env[:results].first  || {}).then { |r| r["val"] || r[:val] })
          right_val = unwrap_literal((right_env[:results].first || {}).then { |r| r["val"] || r[:val] })

          {
            ok: true,
            from: :sparql,
            results: [{
              "left" => left_val,
              "right" => right_val,
              "equal" => left_val == right_val
            }]
          }
        end

        # ── Compilers ────────────────────────────────────────────

        def compile_select(ir)
          find    = required_find(ir)
          fields  = field_set(ir)
          project = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Project) }
          sort    = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Sort) }
          limit   = ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Limit) }

          select_vars = compile_select_vars(project: project, fields: fields)
          where = compile_where(find: find, ir: ir, fields: fields)
          tail  = +""
          tail << " ORDER BY #{compile_sort(sort)}" if sort
          tail << " LIMIT #{Integer(limit.n)}" if limit
          "SELECT #{select_vars} WHERE { #{where} }#{tail}"
        end

        def compile_count(ir)
          find  = required_find(ir)
          where = compile_where(find: find, ir: ir, fields: field_set(ir))
          "SELECT (COUNT(?s) AS ?count) WHERE { #{where} }"
        end

        def compile_compare_lookup(find:, focus:, field:)
          model = find.type
          field_def = ::Vv::Graph::Schema.field(model: model, name: field)
          predicate = iri(field_def[:iri])
          "SELECT ?val WHERE { #{iri(focus)} #{predicate} ?val }"
        end

        # ── WHERE-clause assembly ────────────────────────────────

        def compile_where(find:, ir:, fields:)
          parts = []
          parts << "?s a #{iri(::Vv::Graph::Schema.class_iri(find.type))} ."
          fields.each do |fname|
            field_def = ::Vv::Graph::Schema.field(model: find.type, name: fname)
            parts << "?s #{iri(field_def[:iri])} ?#{var_name(fname)} ."
          end
          ir.each do |node|
            case node
            when ::Vv::Graph::QueryIR::Filter      then parts << compile_filter(node)
            when ::Vv::Graph::QueryIR::FilterRange then parts << compile_filter_range(node)
            when ::Vv::Graph::QueryIR::FilterIn    then parts << compile_filter_in(node)
            end
          end
          parts.join(" ")
        end

        def compile_select_vars(project:, fields:)
          if project
            (["?s"] + project.fields.map { |f| "?#{var_name(f)}" }).uniq.join(" ")
          else
            (["?s"] + fields.map { |f| "?#{var_name(f)}" }).join(" ")
          end
        end

        # ── Per-node filter compilers ────────────────────────────

        FILTER_OP_SPARQL = {
          eq: "=", neq: "!=",
          lt: "<", lte: "<=",
          gt: ">", gte: ">="
        }.freeze

        def compile_filter(node)
          op = FILTER_OP_SPARQL.fetch(node.op) do
            raise ArgumentError,
                  "Vv::Graph::Backend::Sparql: unknown Filter op #{node.op.inspect} " \
                  "(known: #{FILTER_OP_SPARQL.keys.inspect})"
          end
          "FILTER(?#{var_name(node.field)} #{op} #{term(node.value)})"
        end

        def compile_filter_range(node)
          v = "?#{var_name(node.field)}"
          lo_op = node.inclusive ? ">=" : ">"
          hi_op = node.inclusive ? "<=" : "<"
          "FILTER(#{v} #{lo_op} #{term(node.lo)} && #{v} #{hi_op} #{term(node.hi)})"
        end

        def compile_filter_in(node)
          v = "?#{var_name(node.field)}"
          values = node.values.map { |val| term(val) }.join(", ")
          "FILTER(#{v} IN (#{values}))"
        end

        def compile_sort(sort)
          dir = sort.dir == :desc ? "DESC" : "ASC"
          "#{dir}(?#{var_name(sort.field)})"
        end

        # ── Helpers ──────────────────────────────────────────────

        # Fields referenced anywhere in the IR (filter / sort /
        # project). Each contributes a triple pattern in WHERE
        # and a SELECT variable when projected.
        def field_set(ir)
          fields = []
          ir.each do |node|
            case node
            when ::Vv::Graph::QueryIR::Filter      then fields << node.field
            when ::Vv::Graph::QueryIR::FilterRange then fields << node.field
            when ::Vv::Graph::QueryIR::FilterIn    then fields << node.field
            when ::Vv::Graph::QueryIR::Sort        then fields << node.field
            when ::Vv::Graph::QueryIR::Project     then fields.concat(node.fields)
            end
          end
          fields.uniq
        end

        def required_find(ir)
          ir.find { |n| n.is_a?(::Vv::Graph::QueryIR::Find) } or
            raise ArgumentError, "Vv::Graph::Backend::Sparql: IR is missing a Find node " \
                                 "(validation should have caught this in QueryIR.run)"
        end

        def var_name(field)
          field.to_s.tr("-/.", "_")
        end

        # Wrap a raw IRI for SPARQL emission. Already-bracketed
        # forms (`<urn:...>` / `<<...>>`) pass through; everything
        # else is wrapped in `<>`. The gem doesn't emit PREFIX
        # declarations, so bare `mm:Product` would be a SPARQL
        # parse error — bracket-wrapping is the safe path for both
        # full IRIs and prefix-form strings (Oxigraph treats
        # `<mm:Product>` as a (possibly-relative) IRI).
        def iri(raw)
          str = raw.to_s
          return str if str.start_with?("<")
          "<#{str}>"
        end

        # Unwrap each cell of an SPARQL result row into a plain Ruby
        # value. Strips N-triples literal quoting + typed-literal
        # tails so results align with the Relational backend.
        def unwrap_rows(rows)
          rows.map { |row| row.transform_values { |v| unwrap_literal(v) } }
        end

        # Engine returns literals as N-triples-ish strings:
        #   "Alpha"               → "Alpha"
        #   "2"^^<...integer>     → 2
        #   "3.14"^^<...double>   → 3.14
        #   "true"^^<...boolean>  → true
        #   <urn:x>               → "urn:x" (bracket-stripped IRI)
        #   "2026-05-27T...Z"^^<...dateTime> → kept as string for parity
        def unwrap_literal(raw)
          return raw unless raw.is_a?(String)
          # IRI form
          if raw.start_with?("<") && raw.end_with?(">")
            return raw[1..-2]
          end
          # Typed-literal form: "value"^^<datatype>
          if (m = raw.match(/\A"((?:[^"\\]|\\.)*)"\^\^<([^>]+)>\z/))
            value = m[1].gsub(/\\(.)/, '\1')
            datatype = m[2]
            return coerce_literal(value, datatype)
          end
          # Plain string literal: "..."
          if raw.start_with?('"') && raw.end_with?('"')
            return raw[1..-2].gsub(/\\(.)/, '\1')
          end
          raw
        end

        XSD_NS = "http://www.w3.org/2001/XMLSchema#"

        def coerce_literal(value, datatype)
          return value unless datatype.start_with?(XSD_NS)
          case datatype.sub(XSD_NS, "")
          when "integer", "int", "long", "short", "byte",
               "nonNegativeInteger", "nonPositiveInteger",
               "positiveInteger", "negativeInteger",
               "unsignedLong", "unsignedInt", "unsignedShort", "unsignedByte"
            Integer(value)
          when "double", "float", "decimal"
            Float(value)
          when "boolean"
            value == "true"
          else
            value
          end
        rescue ArgumentError, TypeError
          value
        end

        # SPARQL term serialisation. Strings literal-quoted; numerics
        # bare; booleans bare; Time/Date typed. Operators wanting a
        # raw IRI value pass a bracketed string (`"<urn:...>"`).
        def term(value)
          case value
          when String
            return value if value.start_with?("<") && value.end_with?(">")
            %("#{value.gsub('"', '\\"')}")
          when true, false
            value.to_s
          when Integer
            value.to_s
          when Float
            value.to_s
          when ::Time, ::DateTime
            iso = value.utc.iso8601
            %("#{iso}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)
          when ::Date
            %("#{value.iso8601}"^^<http://www.w3.org/2001/XMLSchema#date>)
          when nil
            "UNDEF"
          else
            %("#{value.to_s.gsub('"', '\\"')}")
          end
        end
      end
    end
  end
end
