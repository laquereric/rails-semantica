# frozen_string_literal: true

require "json"

module Semantica
  # PLAN_0.1.0 Phase C — SPARQL facade.
  #
  # Four class methods, all returning structured envelopes; **never
  # raises**. Refusal envelopes carry verbatim because-clauses
  # (substrate Architect's-No #18 inheritance).
  #
  #   Semantica::Sparql.select(query)
  #     success → { ok: true,  results: [{ "var" => "value", ... }, ...] }
  #     failure → { ok: false, reason: <symbol>, because: <verbatim engine message> }
  #
  #   Semantica::Sparql.ask(query)
  #     success → { ok: true,  value: true|false }
  #
  #   Semantica::Sparql.construct(query)
  #     success → { ok: true,  ntriples: "<s> <p> <o> .\n..." }
  #
  #   Semantica::Sparql.execute(update_query)
  #     success → { ok: true,  count: <integer> }
  #
  # Reason symbols (part of the v0.1.0 contract):
  #   :sparql_parse_error, :extension_not_loaded,
  #   :ar_connection_error, :unexpected_error
  #
  # The facade calls Semantica::Loader.ensure_extension_loaded! at
  # the top of every method as a belt-and-braces guard. The Railtie
  # already did this at boot; the per-call check covers
  # connection-pool churn and non-Railtie hosts. Cost: one cheap
  # sentinel `SELECT rdf_count()` per call.
  module Sparql
    REASON_SPARQL_PARSE_ERROR   = :sparql_parse_error
    REASON_EXTENSION_NOT_LOADED = :extension_not_loaded
    REASON_AR_CONNECTION_ERROR  = :ar_connection_error
    REASON_UNEXPECTED_ERROR     = :unexpected_error

    module_function

    def select(query)
      with_extension do |connection|
        json = connection.select_value("SELECT sparql_query(#{connection.quote(query)})")
        results = json.nil? || json.empty? ? [] : ::JSON.parse(json)
        { ok: true, results: results }
      end
    end

    def ask(query)
      with_extension do |connection|
        value = connection.select_value("SELECT sparql_ask(#{connection.quote(query)})")
        { ok: true, value: value.to_i == 1 }
      end
    end

    def construct(query)
      with_extension do |connection|
        ntriples = connection.select_value("SELECT sparql_construct(#{connection.quote(query)})")
        { ok: true, ntriples: ntriples.to_s }
      end
    end

    # SPARQL 1.1 Update — v0.1.0 supports INSERT DATA / DELETE DATA /
    # CLEAR ALL via the scalar extension functions. Arbitrary SPARQL
    # UPDATE is post-0.1.0; callers that need it should reach for
    # the scalar functions directly via raw SQL. Storable's DSL uses
    # only the two forms this method covers.
    def execute(query)
      with_extension do |connection|
        count = dispatch_update(connection, query)
        { ok: true, count: count }
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
      def classify_statement_error(error)
        msg = error.message.to_s.downcase
        return REASON_EXTENSION_NOT_LOADED if msg.include?("no such function")
        return REASON_SPARQL_PARSE_ERROR   if msg.include?("sparql") || msg.include?("parse")
        REASON_UNEXPECTED_ERROR
      end

      def dispatch_update(connection, query)
        stripped = query.to_s.strip
        case stripped
        when /\AINSERT\s+DATA\s*\{(.+)\}\s*\z/im
          body = Regexp.last_match(1).strip
          loaded = connection.select_value(
            "SELECT rdf_load_ntriples(#{connection.quote(body)})",
          )
          loaded.to_i
        when /\ADELETE\s+DATA\s*\{(.+)\}\s*\z/im
          body = Regexp.last_match(1).strip
          delete_each_triple(connection, body)
        when /\ACLEAR\s+(ALL|DEFAULT)\s*\z/im
          connection.select_value("SELECT rdf_clear()")
          0
        else
          raise ::ActiveRecord::StatementInvalid, "unsupported SPARQL UPDATE form (v0.1.0 supports INSERT DATA / DELETE DATA / CLEAR ALL): #{stripped[0, 80]}"
        end
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
      def delete_each_triple(connection, body)
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
            "SELECT rdf_delete(" \
              "#{connection.quote(s)}," \
              "#{connection.quote(p)}," \
              "#{connection.quote(o)})",
          )
          count += 1
        end
        count
      end

      def unwrap_iri(term)
        return term unless term.start_with?("<") && term.end_with?(">")
        term[1..-2]
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
