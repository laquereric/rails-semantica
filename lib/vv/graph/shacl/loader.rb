# frozen_string_literal: true

require "digest"

module Vv; end
module Vv::Graph; end
module Vv::Graph::Shacl; end unless defined?(::Vv::Graph::Shacl)

module Vv::Graph
  module Shacl
    # PLAN_0.17.0 Phase C — SHACL shapes loader.
    #
    #   Vv::Graph::Shacl.load_shapes("config/shapes/product.ttl")
    #     # => { ok: true, loaded: 18, scope: "urn:vv-graph:shapes" }
    #
    # Accepts a file path or a string body. `format: :ttl` (default)
    # routes through the engine's `rdf_load_turtle_to_graph` scalar
    # (sqlite-sparql ≥ 0.12.0 inherited; the function predates the
    # current floor). `format: :nt` routes through
    # `Vv::Graph::Sparql.execute("INSERT DATA { … }")` after reading
    # the file into a single INSERT block.
    #
    # **Idempotency.** The loader emits one metadata triple per
    # load into a sibling `urn:vv-graph:shapes:meta` graph carrying
    # the SHA-256 of the canonicalised input + the source identifier.
    # Re-loading the same content returns
    # `{ ok: true, loaded: 0, reason: :unchanged }` without
    # touching the shapes scope.
    module Loader
      DEFAULT_SHAPES_GRAPH = "urn:vv-graph:shapes"
      META_GRAPH_SUFFIX    = ":meta"
      META_PREDICATE_HASH   = "<urn:vv-graph:shapes-content-hash>"
      META_PREDICATE_SOURCE = "<urn:vv-graph:shapes-source>"

      ALLOWED_FORMATS = %i[ttl nt].freeze

      module_function

      def load(source, format: :ttl, scope: nil)
        return refuse_format(format) unless ALLOWED_FORMATS.include?(format)

        body, source_label = read_source(source)
        return body if body.is_a?(Hash) && body[:ok] == false

        target_scope = scope || DEFAULT_SHAPES_GRAPH
        meta_graph   = "#{target_scope}#{META_GRAPH_SUFFIX}"
        hash         = ::Digest::SHA256.hexdigest(body)

        if hash_matches?(meta_graph, hash)
          return { ok: true, loaded: 0, scope: target_scope, reason: :unchanged }
        end

        env = case format
              when :ttl then load_turtle(body, target_scope)
              when :nt  then load_ntriples(body, target_scope)
              end
        return env unless env[:ok]

        write_meta(meta_graph, hash, source_label)
        { ok: true, loaded: env[:loaded], scope: target_scope }
      end

      # ── Format-specific loaders ──────────────────────────────

      def load_turtle(body, graph)
        ::Vv::Graph::Sparql.send(:with_extension) do |connection|
          quoted_body  = connection.quote(body)
          quoted_graph = connection.quote(graph)
          count = connection.select_value(
            "SELECT rdf_load_turtle_to_graph(#{quoted_body}, #{quoted_graph})"
          ).to_i
          { ok: true, loaded: count }
        end
      rescue ::ActiveRecord::StatementInvalid => e
        { ok: false, reason: :shapes_parse_error,
          because: "Vv::Graph::Shacl.load_shapes: engine refused Turtle: #{e.message}" }
      end

      def load_ntriples(body, graph)
        # N-triples is line-oriented; each non-blank, non-comment
        # line is a single triple terminated by `.`. Wrap the lot
        # in one INSERT DATA call.
        statements = body.each_line.map(&:strip)
                         .reject { |l| l.empty? || l.start_with?("#") }
                         .join(" ")
        env = ::Vv::Graph::Sparql.execute("INSERT DATA { #{statements} }", graph: graph)
        return env unless env[:ok]

        # `count:` from Sparql.execute reports the engine's net
        # delta. Surface as `loaded:` for consistency with the
        # turtle path.
        { ok: true, loaded: env[:count] }
      end

      # ── Source resolution ────────────────────────────────────

      # File-extension heuristic: a String ending in one of these
      # is treated as a path, never as an inline body. Lets the
      # loader refuse "./missing.ttl" with :shapes_file_missing
      # rather than handing the literal string to the engine.
      PATH_LIKE_EXTENSIONS = %w[.ttl .nt .n3 .rdf .shapes .shacl].freeze

      # Returns [body_string, source_label] OR [refusal, nil].
      def read_source(source)
        if source.is_a?(String) && path_like?(source)
          if ::File.file?(source)
            [::File.read(source), source]
          else
            [{ ok: false, reason: :shapes_file_missing,
               because: "Vv::Graph::Shacl.load_shapes: file not found at #{source.inspect}" },
             nil]
          end
        elsif source.is_a?(String) && source.length < 1024 && ::File.file?(source)
          [::File.read(source), source]
        elsif source.is_a?(String)
          [source, "<inline>"]
        elsif source.respond_to?(:read)
          [source.read, source.respond_to?(:path) ? source.path : "<io>"]
        else
          [{ ok: false, reason: :shapes_file_missing,
             because: "Vv::Graph::Shacl.load_shapes: source #{source.inspect} is neither a file path, string body, nor IO" },
           nil]
        end
      rescue ::Errno::ENOENT, ::Errno::EISDIR => e
        [{ ok: false, reason: :shapes_file_missing,
           because: "Vv::Graph::Shacl.load_shapes: #{e.message}" }, nil]
      end

      def path_like?(source)
        return false if source.include?("\n")
        PATH_LIKE_EXTENSIONS.any? { |ext| source.downcase.end_with?(ext) }
      end

      # ── Metadata graph ───────────────────────────────────────

      def hash_matches?(meta_graph, hash)
        env = ::Vv::Graph::Sparql.ask(
          "ASK { <urn:vv-graph:shapes-load> #{META_PREDICATE_HASH} \"#{hash}\" }",
          graph: meta_graph
        )
        env[:ok] && env[:value] == true
      end

      def write_meta(meta_graph, hash, source_label)
        ::Vv::Graph::Sparql.execute("CLEAR GRAPH <#{meta_graph}>")
        ::Vv::Graph::Sparql.execute(<<~SPARQL, graph: meta_graph)
          INSERT DATA {
            <urn:vv-graph:shapes-load> #{META_PREDICATE_HASH}   "#{hash}" .
            <urn:vv-graph:shapes-load> #{META_PREDICATE_SOURCE} "#{escape(source_label)}" .
          }
        SPARQL
      end

      def escape(str)
        str.to_s.gsub('"', '\\"')
      end

      def refuse_format(format)
        {
          ok: false,
          reason: :shapes_format_unknown,
          because: "Vv::Graph::Shacl.load_shapes: format #{format.inspect} not recognised " \
                   "(known: #{ALLOWED_FORMATS.inspect})"
        }
      end
    end

    REASON_SHAPES_FILE_MISSING   = :shapes_file_missing
    REASON_SHAPES_FORMAT_UNKNOWN = :shapes_format_unknown
    REASON_SHAPES_PARSE_ERROR    = :shapes_parse_error

    # Public entry point — operators call Vv::Graph::Shacl.load_shapes(...)
    # without reaching into the Loader sub-module.
    def self.load_shapes(source, format: :ttl, scope: nil)
      Loader.load(source, format: format, scope: scope)
    end
  end
end
