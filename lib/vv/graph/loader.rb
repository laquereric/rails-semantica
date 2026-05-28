# frozen_string_literal: true

module Vv; end

module Vv::Graph
  # PLAN 0.29.1 Phase B — boots the sqlite-sparql SQLite extension
  # into ActiveRecord connections.
  #
  # Two callable shapes:
  #
  #   Vv::Graph::Loader.ensure_extension_loaded!
  #     - Loads the extension into the current AR connection if not
  #       already loaded. Idempotent: probes a sentinel function
  #       (`rdf_count()`) to decide skip-vs-load.
  #     - Raises Vv::Graph::Loader::ExtensionMissing with a structured
  #       because-clause + the build command when the binary isn't on
  #       disk at the expected path.
  #
  #   Vv::Graph::Loader.extension_path
  #     - Resolves the on-disk path. Reads VV_GRAPH_SQLITE_SPARQL_PATH
  #       env var; falls back to vendor/sqlite-sparql/target/release/
  #       libsqlite_sparql.{dylib,so,dll} relative to the substrate
  #       repo root (or cwd if Rails isn't loaded).
  #
  # The Railtie calls ensure_extension_loaded! once at
  # config.after_initialize. Specs / scripts call it explicitly.
  # Connection-pool churn beyond Phase B is handled natively when
  # operators configure `extensions:` in database.yml (Rails 8 +
  # sqlite3 gem v2.4+); the Loader's runtime path covers the cases
  # where database.yml isn't authoritative (test connections,
  # multi-DB setups, scripts that build connections manually).
  module Loader
    # PLAN_0.6.0 Phase A — the sentinel proves the extension is
    # callable on the current AR connection. Under engine ≥ 0.2.0
    # the store is process-wide and may already have data from
    # other connections; that's expected, not a sign of re-loading.
    SENTINEL_QUERY = "SELECT rdf_count()"

    # PLAN_0.6.0 Phase A — placeholder for an engine version probe.
    # Returns :unknown until the engine exposes `rdf_version()`.
    # Pinned shape; the body grows when the engine ships the probe.
    ENGINE_VERSION_UNKNOWN = :unknown

    DEFAULT_PATHS = [
      "vendor/sqlite-sparql/target/release/libsqlite_sparql.dylib",  # macOS
      "vendor/sqlite-sparql/target/release/libsqlite_sparql.so",     # Linux
      "vendor/sqlite-sparql/target/release/sqlite_sparql.dll",       # Windows
    ].freeze

    class ExtensionMissing < StandardError
      def initialize(searched_paths)
        @searched_paths = Array(searched_paths)
        super(message_body)
      end

      private

      def message_body
        <<~MSG
          sqlite-sparql extension not found. Searched:
          #{@searched_paths.map { |p| "  - #{p}" }.join("\n")}

          Build the extension before loading the substrate:
            cd vendor/sqlite-sparql
            cargo build --release

          Or set VV_GRAPH_SQLITE_SPARQL_PATH to point at an already-built
          .dylib / .so file.
        MSG
      end
    end

    module_function

    def ensure_extension_loaded!
      path = extension_path
      raise ExtensionMissing.new(searched_paths) unless path

      return :no_active_record unless defined?(::ActiveRecord::Base)

      connection = ::ActiveRecord::Base.connection
      load_into_connection!(connection, path)
    end

    # Returns the resolved extension path, or nil if no candidate exists.
    def extension_path
      candidate = ENV["VV_GRAPH_SQLITE_SPARQL_PATH"]
      return candidate if candidate && !candidate.empty? && File.exist?(candidate)
      searched_paths.find { |p| File.exist?(p) }
    end

    # The ordered list of paths checked when VV_GRAPH_SQLITE_SPARQL_PATH
    # isn't set or isn't on disk. Specs + chrome reuse this for the
    # ExtensionMissing message + build-instruction docs.
    def searched_paths
      DEFAULT_PATHS.map { |p| absolute_for(p) }
    end

    # PLAN_0.18.0 — walk-up resolver (CR-VVZ B1). Combustion mounts
    # the engine under spec/internal, so the original single-level
    # `Rails.root.parent` walk landed short of `vendor/sqlite-sparql/`.
    # Walk upward to the first level where `relative` exists; if
    # nothing matches, return the start-dir-relative path so the
    # `ExtensionMissing` message still names a concrete location.
    def absolute_for(relative)
      start = if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      else
        Dir.pwd
      end
      walk_up_for(relative, start)
    end

    def walk_up_for(relative, start)
      dir = start
      loop do
        candidate = File.expand_path(relative, dir)
        return candidate if File.exist?(candidate)
        parent = File.expand_path("..", dir)
        return File.expand_path(relative, start) if parent == dir
        dir = parent
      end
    end

    # Loads the extension into a single AR connection. Idempotent —
    # probes the sentinel function first; skips if already loaded.
    # Returns :loaded on a fresh load, :already_loaded on a skip.
    def load_into_connection!(connection, path)
      return :already_loaded if extension_loaded?(connection)

      raw = connection.raw_connection
      raw.enable_load_extension(true)
      raw.load_extension(path)
      raw.enable_load_extension(false)
      :loaded
    end

    def extension_loaded?(connection)
      connection.execute(SENTINEL_QUERY)
      true
    rescue StandardError
      # ActiveRecord::StatementInvalid (when AR is present) or
      # SQLite3::SQLException (raw SQLite3 connection) — either way,
      # the sentinel function is undefined, so the extension hasn't
      # been loaded yet.
      false
    end

    # PLAN_0.6.0 Phase A — best-effort engine-version reader.
    # Returns the engine's `rdf_version()` string when the engine
    # exposes it (engine ≥ TBD), or :unknown otherwise. Operators
    # who need the engine version today read the substrate's
    # submodule pin for ground truth; this is a forward-looking
    # surface stub.
    def engine_version
      return ENGINE_VERSION_UNKNOWN unless defined?(::ActiveRecord::Base)
      connection = ::ActiveRecord::Base.connection
      connection.select_value("SELECT rdf_version()").to_s
    rescue StandardError
      ENGINE_VERSION_UNKNOWN
    end

    # ── PLAN_0.16.0 Phase D — schema normalisation ───────────────

    # Default IRI of the named graph that holds the emitted RDF
    # schema mapping. Operators override via `schema_graph:`.
    SCHEMA_GRAPH_DEFAULT = "urn:vv-graph:schema"

    DEFAULT_EXCLUDED_TABLES = %w[
      ar_internal_metadata
      schema_migrations
    ].freeze

    # Tables matching these prefixes are auto-excluded. Operators
    # who want them included pass `include: [...]` with the table
    # names verbatim.
    DEFAULT_EXCLUDED_PREFIXES = %w[active_storage_ action_text_].freeze

    OWL_CLASS              = "<http://www.w3.org/2002/07/owl#Class>"
    OWL_DATATYPE_PROPERTY  = "<http://www.w3.org/2002/07/owl#DatatypeProperty>"
    OWL_OBJECT_PROPERTY    = "<http://www.w3.org/2002/07/owl#ObjectProperty>"
    RDF_TYPE               = "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>"
    RDFS_DOMAIN            = "<http://www.w3.org/2000/01/rdf-schema#domain>"
    RDFS_RANGE             = "<http://www.w3.org/2000/01/rdf-schema#range>"

    # Reads AR's schema and emits an RDF mapping into the :schema
    # named graph. Idempotent: clears the schema graph before each
    # call, so re-running converges on the current AR state.
    #
    #   Vv::Graph::Loader.normalize_schema!(
    #     iri_prefix:   "mm:",
    #     include:      nil,            # nil = all non-excluded tables
    #     exclude:      [],             # extra tables to skip beyond the defaults
    #     schema_graph: "urn:vv-graph:schema",
    #   )
    #   # => { ok: true, classes: N, datatype_properties: M,
    #   #      object_properties: K, schema_graph: "urn:vv-graph:schema" }
    #
    # Emitted per AR class:
    #   <prefix><Model> a owl:Class .
    # Per column:
    #   <prefix><Model>/<col> a owl:DatatypeProperty ;
    #     rdfs:domain <prefix><Model> ;
    #     rdfs:range  <xsd:type> .
    # Per FK (column ending in `_id` with a known reflection):
    #   <prefix><Model>/<col> a owl:ObjectProperty ;
    #     rdfs:domain <prefix><Model> ;
    #     rdfs:range  <prefix><TargetModel> .
    def normalize_schema!(iri_prefix: nil, include: nil, exclude: [], schema_graph: SCHEMA_GRAPH_DEFAULT)
      unless defined?(::ActiveRecord::Base) && defined?(::Vv::Graph::Sparql)
        return { ok: false, reason: :ar_not_loaded,
                 because: "Vv::Graph::Loader.normalize_schema!: ActiveRecord / Vv::Graph::Sparql not loaded" }
      end

      prefix = iri_prefix || ::Vv::Graph::Schema.iri_prefix
      connection = ::ActiveRecord::Base.connection
      tables = select_tables(connection, include: include, exclude: exclude)

      ::Vv::Graph::Sparql.execute("CLEAR GRAPH <#{schema_graph}>")

      stats = { classes: 0, datatype_properties: 0, object_properties: 0 }
      tables.each do |table|
        model = model_for_table(table)
        emit_class(schema_graph, prefix, model)
        stats[:classes] += 1

        connection.columns(table).each do |column|
          if (ref = ar_reflection_for_column(table, column.name))
            emit_object_property(schema_graph, prefix, model, column.name, ref)
            stats[:object_properties] += 1
          else
            emit_datatype_property(schema_graph, prefix, model, column.name, column.type)
            stats[:datatype_properties] += 1
          end
        end
      end

      ::Vv::Graph.send(:set_schema_normalized!, schema_graph: schema_graph, iri_prefix: prefix)

      stats.merge(ok: true, schema_graph: schema_graph)
    end

    # ── private-by-convention helpers ────────────────────────────

    def select_tables(connection, include:, exclude:)
      all = connection.tables
      excluded = (DEFAULT_EXCLUDED_TABLES + Array(exclude)).map(&:to_s)
      kept = all.reject do |t|
        excluded.include?(t) || DEFAULT_EXCLUDED_PREFIXES.any? { |p| t.start_with?(p) }
      end
      include ? kept & Array(include).map(&:to_s) : kept
    end

    def model_for_table(table)
      table.classify
    end

    def ar_reflection_for_column(table, column_name)
      return nil unless column_name.end_with?("_id")
      target = column_name.sub(/_id\z/, "").classify
      return nil unless Object.const_defined?(target)
      const = Object.const_get(target)
      const if const.is_a?(Class) && const < ::ActiveRecord::Base
    rescue NameError
      nil
    end

    def emit_class(graph, prefix, model)
      iri = "<#{prefix}#{model}>"
      ::Vv::Graph::Sparql.execute("INSERT DATA { #{iri} #{RDF_TYPE} #{OWL_CLASS} . }", graph: graph)
    end

    def emit_datatype_property(graph, prefix, model, column, column_type)
      iri = "<#{prefix}#{model}/#{column}>"
      domain = "<#{prefix}#{model}>"
      range = xsd_iri_for(column_type)
      ::Vv::Graph::Sparql.execute(<<~SPARQL, graph: graph)
        INSERT DATA {
          #{iri} #{RDF_TYPE}    #{OWL_DATATYPE_PROPERTY} .
          #{iri} #{RDFS_DOMAIN} #{domain} .
          #{iri} #{RDFS_RANGE}  #{range} .
        }
      SPARQL
    end

    def emit_object_property(graph, prefix, model, column, target_class)
      iri = "<#{prefix}#{model}/#{column}>"
      domain = "<#{prefix}#{model}>"
      range  = "<#{prefix}#{target_class.name}>"
      ::Vv::Graph::Sparql.execute(<<~SPARQL, graph: graph)
        INSERT DATA {
          #{iri} #{RDF_TYPE}    #{OWL_OBJECT_PROPERTY} .
          #{iri} #{RDFS_DOMAIN} #{domain} .
          #{iri} #{RDFS_RANGE}  #{range} .
        }
      SPARQL
    end

    AR_TYPE_TO_XSD_IRI = {
      string:   "<http://www.w3.org/2001/XMLSchema#string>",
      text:     "<http://www.w3.org/2001/XMLSchema#string>",
      integer:  "<http://www.w3.org/2001/XMLSchema#integer>",
      bigint:   "<http://www.w3.org/2001/XMLSchema#integer>",
      float:    "<http://www.w3.org/2001/XMLSchema#double>",
      decimal:  "<http://www.w3.org/2001/XMLSchema#decimal>",
      boolean:  "<http://www.w3.org/2001/XMLSchema#boolean>",
      date:     "<http://www.w3.org/2001/XMLSchema#date>",
      datetime: "<http://www.w3.org/2001/XMLSchema#dateTime>",
      time:     "<http://www.w3.org/2001/XMLSchema#time>",
      binary:   "<http://www.w3.org/2001/XMLSchema#base64Binary>"
    }.freeze

    def xsd_iri_for(ar_type)
      AR_TYPE_TO_XSD_IRI[ar_type.to_sym] || "<http://www.w3.org/2001/XMLSchema#string>"
    end
  end
end
