# frozen_string_literal: true

require "strscan"

module Vv; end
module Vv::Graph; end
module Vv::Graph::Sparql; end unless defined?(::Vv::Graph::Sparql)

module Vv::Graph
  module Sparql
    # PLAN_0.17.0 Phase B — gem-side SPARQL plan parser.
    #
    # Parses the slice of SPARQL that vv-graph's own surfaces emit
    # (SELECT / ASK / CONSTRUCT plus the v0.3.0 UPDATE forms:
    # INSERT DATA, DELETE DATA, INSERT WHERE, DELETE WHERE, CLEAR,
    # LOAD) into a structured plan. The parser is intentionally
    # narrow — operators wanting cost numbers on richer queries
    # either get :sparql_parse_error or the `:unknown` fall-back.
    #
    # The plan shape is the v0.17.0 contract. See PLAN_0.17.0
    # Phase B for the full pin.
    module Explain
      KIND_SELECT    = :select
      KIND_ASK       = :ask
      KIND_CONSTRUCT = :construct
      KIND_UPDATE    = :update
      KIND_UNKNOWN   = :unknown

      UPDATE_OPERATIONS = %i[
        insert_data delete_data insert_where delete_where clear load drop create
      ].freeze

      module_function

      def parse(query)
        text = normalise_whitespace(query)
        kind = detect_kind(text)
        case kind
        when KIND_SELECT    then parse_select(text)
        when KIND_ASK       then parse_ask(text)
        when KIND_CONSTRUCT then parse_construct(text)
        when KIND_UPDATE    then parse_update(text)
        else
          { kind: KIND_UNKNOWN, raw: text }
        end
      end

      # ── Top-level dispatch ───────────────────────────────────

      def detect_kind(text)
        case text
        when /\A\s*SELECT\b/i    then KIND_SELECT
        when /\A\s*ASK\b/i       then KIND_ASK
        when /\A\s*CONSTRUCT\b/i then KIND_CONSTRUCT
        when /\A\s*(INSERT|DELETE|CLEAR|LOAD|DROP|CREATE)\b/i then KIND_UPDATE
        else KIND_UNKNOWN
        end
      end

      # ── SELECT ───────────────────────────────────────────────

      def parse_select(text)
        projection_match = text.match(/\ASELECT\s+(DISTINCT\s+|REDUCED\s+)?(.*?)\s+WHERE\b/im)
        projection = projection_match ? extract_projection(projection_match[2]) : ["*"]

        where_body = extract_braced_block(text, "WHERE")
        where = where_body ? parse_where(where_body) : { kind: :unknown }

        modifiers = parse_modifiers(text)

        {
          kind: KIND_SELECT,
          projection: projection,
          where: where,
          modifiers: modifiers
        }
      end

      # ── ASK ──────────────────────────────────────────────────

      def parse_ask(text)
        where_body = extract_braced_block(text, "WHERE") || extract_first_braced_block(text)
        where = where_body ? parse_where(where_body) : { kind: :unknown }
        { kind: KIND_ASK, where: where, modifiers: parse_modifiers(text) }
      end

      # ── CONSTRUCT ────────────────────────────────────────────

      def parse_construct(text)
        # CONSTRUCT { template } WHERE { pattern }
        template_body = extract_first_braced_block(text)
        where_start = text.index(/\bWHERE\b/i)
        where_body = where_start ? extract_braced_block(text[where_start..], "WHERE") : nil

        {
          kind: KIND_CONSTRUCT,
          template: template_body ? parse_triples(template_body) : [],
          where: where_body ? parse_where(where_body) : { kind: :unknown },
          modifiers: parse_modifiers(text)
        }
      end

      # ── UPDATE ───────────────────────────────────────────────

      def parse_update(text)
        op = detect_update_operation(text)
        result = { kind: KIND_UPDATE, operation: op }

        case op
        when :insert_data
          body = extract_braced_block(text, "INSERT\\s+DATA") || extract_first_braced_block(text)
          result[:data] = body ? parse_triples(body) : []
        when :delete_data
          body = extract_braced_block(text, "DELETE\\s+DATA") || extract_first_braced_block(text)
          result[:data] = body ? parse_triples(body) : []
        when :insert_where, :delete_where
          # Two braced blocks: the template + the WHERE pattern.
          blocks = extract_all_braced_blocks(text)
          if blocks.size >= 2
            result[:template] = parse_triples(blocks[0])
            result[:where]    = parse_where(blocks[1])
          else
            result[:template] = blocks.first ? parse_triples(blocks.first) : []
            result[:where]    = { kind: :unknown }
          end
        when :clear, :drop
          target = text.match(/\b(CLEAR|DROP)\s+(GRAPH\s+)?(.+)\z/i)
          result[:target] = target ? target[3].strip : nil
        when :load
          target = text.match(/\bLOAD\s+(SILENT\s+)?<([^>]+)>(?:\s+INTO\s+GRAPH\s+<([^>]+)>)?/i)
          result[:source]      = target ? target[2] : nil
          result[:into_graph]  = target ? target[3] : nil
        end

        result
      end

      def detect_update_operation(text)
        case text
        when /\AINSERT\s+DATA\b/i then :insert_data
        when /\ADELETE\s+DATA\b/i then :delete_data
        when /\AINSERT\b/i        then :insert_where
        when /\ADELETE\b/i        then :delete_where
        when /\ACLEAR\b/i         then :clear
        when /\ADROP\b/i          then :drop
        when /\ALOAD\b/i          then :load
        when /\ACREATE\b/i        then :create
        else :unknown
        end
      end

      # ── WHERE-block parser ───────────────────────────────────

      def parse_where(body)
        body = body.strip
        filters = []
        binds   = []
        graphs  = []
        optionals = []
        unions    = []

        # Strip + capture FILTER expressions.
        body = body.gsub(/FILTER\s*\(((?:[^()]|\([^()]*\))+)\)/i) do
          filters << { expression: $1.strip }
          ""
        end

        # Strip + capture BIND expressions.
        body = body.gsub(/BIND\s*\(([^)]+)\s+AS\s+(\?\w+)\)/i) do
          binds << { expression: $1.strip, var: $2 }
          ""
        end

        # Strip + capture OPTIONAL blocks (single-nested only).
        body = body.gsub(/OPTIONAL\s*\{([^{}]*)\}/i) do
          optionals << { kind: :bgp, patterns: parse_triples($1) }
          ""
        end

        # Strip + capture GRAPH <iri> { ... } blocks.
        body = body.gsub(/GRAPH\s+(<[^>]+>|\?\w+)\s*\{([^{}]*)\}/i) do
          graphs << { iri: $1, patterns: parse_triples($2) }
          ""
        end

        # Capture UNION (two adjacent blocks). Simplest detection:
        # split on the literal " UNION " token (case-insensitive)
        # only when the residual body has the shape "{ ... } UNION { ... }".
        union_match = body.match(/\{([^{}]+)\}\s+UNION\s+\{([^{}]+)\}/i)
        if union_match
          unions << { left:  { kind: :bgp, patterns: parse_triples(union_match[1]) },
                      right: { kind: :bgp, patterns: parse_triples(union_match[2]) } }
          body = body.sub(union_match[0], "")
        end

        bgp_patterns = parse_triples(body)

        plan = { kind: :bgp, patterns: bgp_patterns }
        plan[:filters]   = filters   unless filters.empty?
        plan[:binds]     = binds     unless binds.empty?
        plan[:graphs]    = graphs    unless graphs.empty?
        plan[:optionals] = optionals unless optionals.empty?
        plan[:unions]    = unions    unless unions.empty?
        plan
      end

      # Parse a triple-pattern body into a flat Array of
      # [s, p, o] String triples. Statements are period-separated;
      # tokens inside each statement are whitespace-separated.
      # Handles the basic forms vv-graph's surfaces emit; richer
      # forms (semicolons, comma-shorthand) fall back to a single
      # un-split string.
      def parse_triples(body)
        statements = body.split(/\s*\.\s*(?![^<>]*>)/).map(&:strip).reject(&:empty?)
        statements.map do |stmt|
          tokens = tokenise_statement(stmt)
          tokens.length == 3 ? tokens : [stmt]
        end
      end

      # Tokenise on whitespace but keep bracketed IRIs, quoted
      # triples, and quoted literals (incl. typed/lang tails)
      # together. Best-effort for the in-scope syntax.
      def tokenise_statement(stmt)
        tokens = []
        scanner = StringScanner.new(stmt)
        until scanner.eos?
          scanner.skip(/\s+/)
          break if scanner.eos?

          if scanner.scan(/<<.+?>>/)
            tokens << scanner.matched
          elsif scanner.scan(/<[^>]+>/)
            tokens << scanner.matched
          elsif scanner.scan(/"(?:[^"\\]|\\.)*"(?:\^\^<[^>]+>|@[A-Za-z][A-Za-z0-9\-]*)?/)
            tokens << scanner.matched
          elsif scanner.scan(/\?\w+/)
            tokens << scanner.matched
          elsif scanner.scan(/\S+/)
            tokens << scanner.matched
          end
        end
        tokens
      end

      # ── Modifiers ────────────────────────────────────────────

      def parse_modifiers(text)
        {
          order_by: parse_order_by(text),
          limit:    parse_limit(text),
          offset:   parse_offset(text),
          group_by: parse_group_by(text),
          having:   parse_having(text)
        }
      end

      def parse_order_by(text)
        m = text.match(/ORDER\s+BY\s+(.+?)(?:\s+(?:LIMIT|OFFSET|GROUP|HAVING)\b|\z)/im)
        return nil unless m
        body = m[1].strip
        body.scan(/(ASC|DESC)\s*\(\s*(\?\w+)\s*\)|(\?\w+)/i).map do |dir, var, bare|
          if bare
            { var: bare, dir: :asc }
          else
            { var: var, dir: dir.casecmp("DESC").zero? ? :desc : :asc }
          end
        end
      end

      def parse_limit(text)
        m = text.match(/\bLIMIT\s+(\d+)\b/i)
        m ? Integer(m[1]) : nil
      end

      def parse_offset(text)
        m = text.match(/\bOFFSET\s+(\d+)\b/i)
        m ? Integer(m[1]) : nil
      end

      def parse_group_by(text)
        m = text.match(/GROUP\s+BY\s+(.+?)(?:\s+(?:HAVING|ORDER|LIMIT|OFFSET)\b|\z)/im)
        return nil unless m
        m[1].strip.scan(/\?\w+/)
      end

      def parse_having(text)
        m = text.match(/HAVING\s*\(((?:[^()]|\([^()]*\))+)\)/i)
        m ? m[1].strip : nil
      end

      # ── Brace-extraction helpers ─────────────────────────────

      # Extract the body inside `{ ... }` immediately following the
      # given keyword (regex source — already-escaped for embedded
      # whitespace). Tolerates nested braces.
      def extract_braced_block(text, keyword)
        keyword_match = text.match(/\b#{keyword}\s*\{/i)
        return nil unless keyword_match
        start = keyword_match.end(0) - 1 # position of `{`
        body, _consumed = scan_balanced_block(text, start)
        body
      end

      # Extract the first `{ ... }` body in the text (no keyword
      # gate).
      def extract_first_braced_block(text)
        idx = text.index("{")
        return nil unless idx
        body, _ = scan_balanced_block(text, idx)
        body
      end

      def extract_all_braced_blocks(text)
        blocks = []
        cursor = 0
        loop do
          idx = text.index("{", cursor)
          break unless idx
          body, consumed = scan_balanced_block(text, idx)
          blocks << body
          cursor = consumed
        end
        blocks
      end

      # Returns [body_without_outer_braces, position-after-closing-brace]
      def scan_balanced_block(text, start_idx)
        depth = 0
        i = start_idx
        until i >= text.length
          case text[i]
          when "{" then depth += 1
          when "}" then depth -= 1
                       return [text[(start_idx + 1)...i].strip, i + 1] if depth.zero?
          end
          i += 1
        end
        [text[(start_idx + 1)..].to_s.strip, text.length]
      end

      # ── Misc ─────────────────────────────────────────────────

      def normalise_whitespace(text)
        text.to_s.strip
      end

      def extract_projection(body)
        body = body.strip
        return ["*"] if body == "*"
        body.scan(/\?\w+|\([^)]+\)/)
      end
    end
  end
end
