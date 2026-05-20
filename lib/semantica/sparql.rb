# frozen_string_literal: true

require "json"

module Semantica
  # PLAN_0.1.0 Phase C — SPARQL facade.
  # PLAN_0.5.0 Phase A — every public method gains a `graph:` kwarg
  # (default graph when nil/omitted; named graph when set). Blank-node
  # graphs refuse at the gem boundary with :invalid_graph. Combinations
  # that don't make sense (`graph:` with `CLEAR ALL`) refuse with
  # :invalid_dsl. The engine's 4-arg `rdf_insert(s,p,o,graph)` /
  # `rdf_delete(s,p,o,graph)` (sqlite-sparql 0.3.0) is the dispatch
  # target for `execute`; read paths textually prepend `FROM <graph>`
  # so operator-authored `GRAPH <g> { ... }` patterns layer on top.
  #
  # Four class methods, all returning structured envelopes; **never
  # raises**. Refusal envelopes carry verbatim because-clauses
  # (substrate Architect's-No #18 inheritance).
  #
  #   Semantica::Sparql.select(query, graph: nil)
  #     success → { ok: true,  results: [{ "var" => "value", ... }, ...] }
  #     failure → { ok: false, reason: <symbol>, because: <verbatim engine message> }
  #
  #   Semantica::Sparql.ask(query, graph: nil)
  #     success → { ok: true,  value: true|false }
  #
  #   Semantica::Sparql.construct(query, graph: nil)
  #     success → { ok: true,  ntriples: "<s> <p> <o> .\n..." }
  #
  #   Semantica::Sparql.execute(update_query, graph: nil)
  #     success → { ok: true,  count: <integer> }
  #
  # Reason symbols (part of the v0.5.0 contract; additions on top of
  # v0.1.0):
  #   :sparql_parse_error, :extension_not_loaded,
  #   :ar_connection_error, :unexpected_error,
  #   :invalid_graph         (PLAN_0.5.0 — blank-node graph IRI),
  #   :invalid_dsl           (PLAN_0.5.0 — CLEAR ALL/DEFAULT + graph:).
  #
  # The facade calls Semantica::Loader.ensure_extension_loaded! at
  # the top of every method as a belt-and-braces guard. The Railtie
  # already did this at boot; the per-call check covers
  # connection-pool churn and non-Railtie hosts. Cost: one cheap
  # sentinel `SELECT rdf_count()` per call.
  module Sparql
    REASON_SPARQL_PARSE_ERROR   = :sparql_parse_error
    REASON_SPARQL_EVAL_ERROR    = :sparql_eval_error
    REASON_EXTENSION_NOT_LOADED = :extension_not_loaded
    REASON_AR_CONNECTION_ERROR  = :ar_connection_error
    REASON_UNEXPECTED_ERROR     = :unexpected_error
    REASON_INVALID_GRAPH        = :invalid_graph
    REASON_INVALID_DSL          = :invalid_dsl

    # PLAN_0.5.0 — sentinel raised by `dispatch_update` when the
    # operator's SPARQL UPDATE form combined with `graph:` is
    # ambiguous (e.g., `CLEAR ALL` + `graph: "..."`). `with_extension`
    # rescues this + emits the :invalid_dsl refusal envelope.
    class InvalidDsl < StandardError; end

    module_function

    def select(query, graph: nil)
      graph_error = validate_graph(graph)
      return graph_error if graph_error

      with_extension do |connection|
        effective = GraphScoping.scope_read(query, graph)
        json = connection.select_value("SELECT sparql_query(#{connection.quote(effective)})")
        results = json.nil? || json.empty? ? [] : ::JSON.parse(json)
        { ok: true, results: results }
      end
    end

    def ask(query, graph: nil)
      graph_error = validate_graph(graph)
      return graph_error if graph_error

      with_extension do |connection|
        effective = GraphScoping.scope_read(query, graph)
        value = connection.select_value("SELECT sparql_ask(#{connection.quote(effective)})")
        { ok: true, value: value.to_i == 1 }
      end
    end

    def construct(query, graph: nil)
      graph_error = validate_graph(graph)
      return graph_error if graph_error

      with_extension do |connection|
        effective = GraphScoping.scope_read(query, graph)
        ntriples = connection.select_value("SELECT sparql_construct(#{connection.quote(effective)})")
        { ok: true, ntriples: ntriples.to_s }
      end
    end

    # SPARQL 1.1 Update — v0.1.0 supports INSERT DATA / DELETE DATA /
    # CLEAR ALL via the scalar extension functions. v0.5.0 routes
    # graph-scoped writes through the engine's 4-arg `rdf_insert` /
    # `rdf_delete` forms when `graph:` is set. v0.3.0 routes any
    # UPDATE form that doesn't match the four fast paths through the
    # engine's `sparql_update` scalar (signed net delta). When
    # `graph:` is set on an arbitrary UPDATE path, the gem prepends
    # `WITH <graph>` to the query — SPARQL 1.1's graph-scoping prefix
    # for INSERT / DELETE / INSERT WHERE / DELETE WHERE forms.
    def execute(query, graph: nil)
      graph_error = validate_graph(graph)
      return graph_error if graph_error

      with_extension do |connection|
        count = dispatch_update(connection, query, graph)
        { ok: true, count: count }
      end
    end

    # PLAN_0.4.0 Phase A — bulk write facade.
    #
    #   Semantica::Sparql.bulk_insert([
    #     { s: "urn:mm:p:1", p: "schema:name", o: "Foo" },
    #     { s: "urn:mm:p:1", p: "schema:tag",  o: "bar", graph: "urn:g:gh" },
    #   ])
    #   # => { ok: true, inserted: 2 }
    #
    #   Semantica::Sparql.bulk_insert([
    #     ["urn:mm:p:1", "schema:name", "Foo"],
    #     ["urn:mm:p:1", "schema:tag",  "bar", "urn:g:gh"],
    #   ])
    #   # => { ok: true, inserted: 2 }
    #
    # Refusal envelope semantics inherited from the rest of the
    # facade. The engine aborts the whole batch on any malformed
    # row; the gem mirrors that — no partial-success path. Empty
    # input returns `{ ok: true, inserted: 0 }` (or `:deleted: 0`).
    # PLAN_0.6.0 Phase C — total-triples reader, routed to the
    # engine's `rdf_count_all()` / `rdf_count()` / `rdf_count(graph)`
    # scalars.
    #
    #   Semantica::Sparql.store_size
    #     → { ok: true, count: <integer> }  # rdf_count_all — every graph
    #
    #   Semantica::Sparql.store_size(graph: nil)
    #     → { ok: true, count: <integer> }  # rdf_count — default graph only
    #
    #   Semantica::Sparql.store_size(graph: "urn:mm:graph:bhphoto")
    #     → { ok: true, count: <integer> }  # rdf_count(graph)
    #
    # Omitting graph: defaults to the cross-graph total; explicit
    # `graph: nil` opts in to default-graph-only.
    def store_size(**kwargs)
      omitted = !kwargs.key?(:graph)
      graph = kwargs[:graph]

      unless omitted || graph.nil?
        graph_error = validate_graph(graph)
        return graph_error if graph_error
      end

      with_extension do |connection|
        sql =
          if omitted
            "SELECT rdf_count_all()"
          elsif graph.nil?
            "SELECT rdf_count()"
          else
            "SELECT rdf_count(#{connection.quote(graph)})"
          end
        count = connection.select_value(sql)
        { ok: true, count: count.to_i }
      end
    end

    def bulk_insert(rows, raw: false)
      bulk_write(rows, "rdf_insert_many", :inserted, raw: raw)
    end

    def bulk_delete(rows, raw: false)
      bulk_write(rows, "rdf_delete_many", :deleted, raw: raw)
    end

    # PLAN_0.5.0 Phase A — validate graph IRIs at the gem boundary.
    # nil is the default graph (always valid). Blank-node graphs
    # (`_:foo`) refuse. Everything else (including obvious-junk strings)
    # passes through to the engine which has the final word on IRI
    # validity. Cheap belt-and-braces; the engine rejects blank-node
    # graphs at the 4-arg rdf_insert boundary regardless.
    def validate_graph(graph)
      return nil if graph.nil?
      return nil unless graph.is_a?(String)
      return nil unless graph.start_with?("_:")
      { ok: false, reason: REASON_INVALID_GRAPH,
        because: "blank-node graph IRIs are not supported (received #{graph.inspect})" }
    end

    # PLAN_0.5.0 — textual rewriting of read-side SPARQL to scope the
    # default-dataset to a named graph. Inserts `FROM <graph>` at the
    # correct SPARQL grammar position: after the SELECT projection
    # (or ASK keyword, or CONSTRUCT template) and before the WHERE
    # clause's opening `{`. Operators who hand-author `GRAPH <g> { ... }`
    # patterns inside WHERE keep working; the kwarg layers on top.
    #
    # The injection point is the body's opening `{` (the WHERE clause's
    # group pattern). For CONSTRUCT, the body is the SECOND `{` block
    # — the first is the construct template. SPARQL 1.1 treats the
    # WHERE keyword as optional, so `FROM <g>` followed by `WHERE { ... }`
    # parses cleanly whether or not the operator's original query had
    # an explicit WHERE.
    module GraphScoping
      module_function

      def scope_read(query, graph)
        return query if graph.nil? || graph.empty?

        # Locate the body's opening `{`. For CONSTRUCT, skip the
        # construct template's `{...}` block first.
        body_start = body_brace_index(query)
        return query unless body_start

        # If the query already has an explicit WHERE keyword
        # immediately before the body, drop it (we'll re-add it
        # after the FROM clause for clarity).
        head = query[0...body_start]
        body = query[body_start..]
        head_trimmed = head.sub(/\s*\bWHERE\b\s*\z/i, "").rstrip

        "#{head_trimmed}\nFROM <#{graph}>\nWHERE #{body}"
      end

      def body_brace_index(query)
        first = query.index("{")
        return nil unless first
        return first unless query =~ /\ACONSTRUCT\b/i

        # CONSTRUCT — skip the template's matching `{...}` block.
        template_end = matching_close(query, first)
        return nil unless template_end
        after = query.index("{", template_end + 1)
        after
      end

      def matching_close(string, open_idx)
        depth = 0
        i = open_idx
        while i < string.length
          case string[i]
          when "{" then depth += 1
          when "}"
            depth -= 1
            return i if depth.zero?
          end
          i += 1
        end
        nil
      end
    end

    class << self
      private

      def with_extension
        unless defined?(::ActiveRecord::Base)
          return refused(REASON_AR_CONNECTION_ERROR, "ActiveRecord::Base is not loaded")
        end

        begin
          ::Semantica::Loader.ensure_extension_loaded!
        rescue ::Semantica::Loader::ExtensionMissing => e
          return refused(REASON_EXTENSION_NOT_LOADED, e.message)
        rescue StandardError => e
          return refused(REASON_AR_CONNECTION_ERROR, e.message)
        end

        connection = ::ActiveRecord::Base.connection
        yield connection
      rescue InvalidDsl => e
        refused(REASON_INVALID_DSL, e.message)
      rescue ::ActiveRecord::StatementInvalid => e
        refused(classify_statement_error(e), e.message)
      rescue ::JSON::ParserError => e
        refused(REASON_UNEXPECTED_ERROR, "engine returned non-JSON: #{e.message}")
      rescue StandardError => e
        refused(REASON_UNEXPECTED_ERROR, e.message)
      end

      def refused(reason, because)
        { ok: false, reason: reason, because: because.to_s }
      end

      # SQLite surfaces SPARQL parse errors and "no such function"
      # both as ActiveRecord::StatementInvalid. Discriminate by the
      # underlying message text.
      #
      # PLAN_0.3.0 Phase C — the engine's sparql_update surface prefixes
      # parse failures with "SPARQL parse error:" and evaluation
      # failures with "SPARQL evaluation error:". Branch on those so
      # callers can distinguish "the query didn't parse" from "the query
      # parsed but referred to undefined predicates / bad IRIs / etc."
      def classify_statement_error(error)
        msg = error.message.to_s
        downcased = msg.downcase
        return REASON_EXTENSION_NOT_LOADED if downcased.include?("no such function")
        return REASON_SPARQL_EVAL_ERROR    if msg.include?("SPARQL evaluation error")
        return REASON_SPARQL_PARSE_ERROR   if msg.include?("SPARQL parse error")
        return REASON_SPARQL_PARSE_ERROR   if downcased.include?("sparql") || downcased.include?("parse")
        REASON_UNEXPECTED_ERROR
      end

      def dispatch_update(connection, query, graph = nil)
        stripped = query.to_s.strip
        case stripped
        when /\AINSERT\s+DATA\s*\{(.+)\}\s*\z/im
          body = Regexp.last_match(1).strip
          if graph
            insert_each_triple(connection, body, graph)
          else
            loaded = connection.select_value(
              "SELECT rdf_load_ntriples(#{connection.quote(body)})",
            )
            loaded.to_i
          end
        when /\ADELETE\s+DATA\s*\{(.+)\}\s*\z/im
          body = Regexp.last_match(1).strip
          delete_each_triple(connection, body, graph)
        when %r{\ADELETE\s+WHERE\s*\{\s*<([^>]+)>\s+<([^>]+)>\s+\?\w+\s*\.?\s*\}\s*\z}im
          # PLAN_0.2.0 Phase B — DELETE WHERE { <s> <p> ?o }: retract every triple
          # with the given subject + predicate regardless of object. Internal
          # translation: SELECT ?o WHERE { ... } then rdf_delete per result.
          # PLAN_0.5.0 — graph-scoped variant routes through the same path with
          # a graph-scoped inner SELECT + 4-arg rdf_delete.
          subject_iri   = Regexp.last_match(1)
          predicate_iri = Regexp.last_match(2)
          delete_where_subject_predicate(connection, subject_iri, predicate_iri, graph)
        when /\ACLEAR\s+(ALL|DEFAULT)\s*\z/im
          # PLAN_0.5.0 — CLEAR ALL / CLEAR DEFAULT name the dataset
          # explicitly; combining with `graph:` is ambiguous. Reject
          # at the gem boundary rather than letting the engine
          # silently ignore one of the two scopings.
          if graph
            raise InvalidDsl, "CLEAR #{Regexp.last_match(1).upcase} does not accept graph: (use execute(\"CLEAR GRAPH <#{graph}>\") to clear a named graph)"
          end
          connection.select_value("SELECT rdf_clear()")
          0
        else
          # PLAN_0.3.0 Phase A — engine sparql_update fallback.
          # Routes arbitrary SPARQL 1.1 UPDATE forms (INSERT WHERE,
          # DELETE WHERE with bindings, DELETE/INSERT WHERE, COPY,
          # MOVE, ADD, CLEAR GRAPH, etc.) through the engine's
          # `sparql_update` scalar. Returns the engine's signed net
          # delta (inserts − deletes); `count:` widens from unsigned
          # to signed for this path only.
          #
          # PLAN_0.5.0 — when `graph:` is set, prepend SPARQL 1.1's
          # `WITH <graph>` scoping prefix. Valid for INSERT / DELETE
          # / INSERT WHERE / DELETE WHERE forms; the engine's
          # parse-error path will surface anything else.
          effective = graph ? "WITH <#{graph}>\n#{stripped}" : stripped
          delta = connection.select_value(
            "SELECT sparql_update(#{connection.quote(effective)})",
          )
          delta.to_i
        end
      end

      # PLAN_0.5.0 — parse N-Triples body + insert each via 4-arg
      # `rdf_insert(s,p,o,graph)`. Used when execute is called with
      # `graph:` set, since `rdf_load_ntriples` is default-graph-only.
      # Term-encoding parity with delete_each_triple: subject +
      # predicate strip their angle brackets (rdf_insert takes bare
      # IRIs); literals + blank nodes pass through.
      def insert_each_triple(connection, body, graph)
        count = 0
        body.each_line do |line|
          line = line.strip.chomp(".").strip
          next if line.empty?
          terms = split_ntriple(line)
          next unless terms && terms.length == 3
          s = unwrap_iri(terms[0])
          p = unwrap_iri(terms[1])
          o = terms[2].start_with?("<") ? unwrap_iri(terms[2]) : terms[2]
          connection.select_value(
            "SELECT rdf_insert(" \
              "#{connection.quote(s)}," \
              "#{connection.quote(p)}," \
              "#{connection.quote(o)}," \
              "#{connection.quote(graph)})",
          )
          count += 1
        end
        count
      end

      # Retract every triple matching (subject_iri, predicate_iri) regardless
      # of object. Internal translation since v0.2.0 — until sparql_update
      # routes arbitrary UPDATE forms through the engine (PLAN_0.3.0).
      # PLAN_0.5.0 — graph-scoped variant: inner SELECT prepends
      # `FROM <graph>`; deletes route through 4-arg `rdf_delete(s,p,o,graph)`.
      def delete_where_subject_predicate(connection, subject_iri, predicate_iri, graph = nil)
        inner =
          if graph
            "SELECT ?o FROM <#{graph}> WHERE { <#{subject_iri}> <#{predicate_iri}> ?o }"
          else
            "SELECT ?o WHERE { <#{subject_iri}> <#{predicate_iri}> ?o }"
          end
        results_json = connection.select_value(
          "SELECT sparql_query(#{connection.quote(inner)})",
        )
        return 0 if results_json.nil? || results_json.empty?
        rows = ::JSON.parse(results_json)
        count = 0
        rows.each do |row|
          old_o = row["o"]
          next if old_o.nil? || old_o.empty?
          o = old_o.start_with?("<") ? unwrap_iri(old_o) : old_o
          sql =
            if graph
              "SELECT rdf_delete(" \
                "#{connection.quote(subject_iri)}," \
                "#{connection.quote(predicate_iri)}," \
                "#{connection.quote(o)}," \
                "#{connection.quote(graph)})"
            else
              "SELECT rdf_delete(" \
                "#{connection.quote(subject_iri)}," \
                "#{connection.quote(predicate_iri)}," \
                "#{connection.quote(o)})"
            end
          connection.select_value(sql)
          count += 1
        end
        count
      end

      # Parse a N-Triples body and issue one rdf_delete per triple.
      #
      # Term-encoding asymmetry: rdf_load_ntriples accepts terms in
      # full N-Triples form (IRIs wrapped in `<...>`), but rdf_delete
      # calls NamedNode::new directly on the subject/predicate, which
      # expects bare IRIs. Strip the angle brackets here so the two
      # write paths round-trip. Literals (starting with `"`) and
      # blank nodes (`_:`) pass through unchanged — those are
      # accepted in N-Triples form by parse_term.
      # PLAN_0.5.0 — when graph is set, route through the engine's
      # 4-arg rdf_delete; default-graph deletes keep the 3-arg form.
      def delete_each_triple(connection, body, graph = nil)
        count = 0
        body.each_line do |line|
          line = line.strip.chomp(".").strip
          next if line.empty?
          terms = split_ntriple(line)
          next unless terms && terms.length == 3
          s = unwrap_iri(terms[0])
          p = unwrap_iri(terms[1])
          o = terms[2].start_with?("<") ? unwrap_iri(terms[2]) : terms[2]
          sql =
            if graph
              "SELECT rdf_delete(" \
                "#{connection.quote(s)}," \
                "#{connection.quote(p)}," \
                "#{connection.quote(o)}," \
                "#{connection.quote(graph)})"
            else
              "SELECT rdf_delete(" \
                "#{connection.quote(s)}," \
                "#{connection.quote(p)}," \
                "#{connection.quote(o)})"
            end
          connection.select_value(sql)
          count += 1
        end
        count
      end

      def unwrap_iri(term)
        return term unless term.start_with?("<") && term.end_with?(">")
        term[1..-2]
      end

      # PLAN_0.4.0 Phase A — shared backbone for bulk_insert /
      # bulk_delete. Validates rows, runs each term through
      # TermSerializer, unwraps IRIs (engine wants bare), marshals
      # to JSON, single FFI crossing per batch.
      #
      # raw: true skips term normalization — rows are passed through
      # to the engine as-is. Used by Storable's :bulk dispatch path
      # (PLAN_0.4.0 Phase B), which assembles already-engine-form
      # rows from SELECT results.
      def bulk_write(rows, fn_name, payload_key, raw:)
        with_extension do |connection|
          normalized = raw ? Array(rows) : normalize_bulk_rows(rows)
          if normalized.empty?
            { ok: true, payload_key => 0 }
          else
            json = ::JSON.generate(normalized)
            count = connection.select_value(
              "SELECT #{fn_name}(#{connection.quote(json)})",
            )
            { ok: true, payload_key => count.to_i }
          end
        end
      end

      # Accept Array<Hash> or Array<Array>; return a uniform
      # Array<Array> in the shape rdf_insert_many expects: 3- or
      # 4-element string arrays. Hash rows with :graph => nil and
      # Array rows with 3 elements collapse to the 3-element shape.
      def normalize_bulk_rows(rows)
        return [] if rows.nil? || rows.empty?
        unless rows.respond_to?(:each)
          raise InvalidDsl, "bulk_insert / bulk_delete expects an Array of rows"
        end

        rows.map.with_index do |row, idx|
          s, p, o, graph = extract_row(row, idx)
          validate_bulk_graph(graph, idx) if graph

          s_bare = unwrap_iri(::Semantica::Storable::TermSerializer.iri(s))
          p_bare = unwrap_iri(::Semantica::Storable::TermSerializer.predicate(p))
          o_term = ::Semantica::Storable::TermSerializer.object(o)
          o_engine = o_term.start_with?("<") ? unwrap_iri(o_term) : o_term

          if graph
            g_bare = unwrap_iri(graph.to_s)
            [s_bare, p_bare, o_engine, g_bare]
          else
            [s_bare, p_bare, o_engine]
          end
        end
      end

      def extract_row(row, idx)
        case row
        when Hash
          [row[:s] || row["s"], row[:p] || row["p"], row[:o] || row["o"],
           row[:graph] || row["graph"]]
        when Array
          case row.length
          when 3 then [row[0], row[1], row[2], nil]
          when 4 then row
          else
            raise InvalidDsl,
                  "row #{idx}: array form expects 3 or 4 elements, got #{row.length}"
          end
        else
          raise InvalidDsl,
                "row #{idx}: expected Hash or Array, got #{row.class}"
        end
      end

      def validate_bulk_graph(graph, idx)
        return unless graph.is_a?(String) && graph.start_with?("_:")
        raise ::ActiveRecord::StatementInvalid,
              "row #{idx}: blank-node graph IRIs are not supported"
      end

      # Split a single N-Triples line into [subject, predicate, object].
      # Terms keep their N-Triples encoding so they pass through to
      # rdf_delete unchanged.
      def split_ntriple(line)
        terms = []
        rest = line.dup
        while rest && !rest.empty? && terms.length < 3
          rest = rest.lstrip
          break if rest.empty?
          term, rest = take_term(rest)
          return nil unless term
          terms << term
        end
        terms.length == 3 ? terms : nil
      end

      def take_term(rest)
        case rest[0]
        when "<"
          close = rest.index(">")
          return [nil, nil] unless close
          [rest[0..close], rest[(close + 1)..]]
        when '"'
          i = 1
          while i < rest.length
            if rest[i] == "\\" && i + 1 < rest.length
              i += 2
            elsif rest[i] == '"'
              break
            else
              i += 1
            end
          end
          return [nil, nil] if i >= rest.length
          tail = i + 1
          if rest[tail] == "@"
            tail += 1
            tail += 1 while tail < rest.length && rest[tail] =~ /[A-Za-z0-9-]/
          elsif rest[tail, 2] == "^^"
            tail += 2
            if rest[tail] == "<"
              close = rest.index(">", tail)
              tail = close + 1 if close
            end
          end
          [rest[0...tail], rest[tail..]]
        when "_"
          m = rest.match(/\A_:\S+/)
          return [nil, nil] unless m
          [m[0], rest[m[0].length..]]
        else
          [nil, nil]
        end
      end
    end
  end
end
