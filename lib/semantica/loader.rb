# frozen_string_literal: true

module Semantica
  # PLAN 0.29.1 Phase B — boots the sqlite-sparql SQLite extension
  # into ActiveRecord connections.
  #
  # Two callable shapes:
  #
  #   Semantica::Loader.ensure_extension_loaded!
  #     - Loads the extension into the current AR connection if not
  #       already loaded. Idempotent: probes a sentinel function
  #       (`rdf_count()`) to decide skip-vs-load.
  #     - Raises Semantica::Loader::ExtensionMissing with a structured
  #       because-clause + the build command when the binary isn't on
  #       disk at the expected path.
  #
  #   Semantica::Loader.extension_path
  #     - Resolves the on-disk path. Reads MM_SQLITE_SPARQL_PATH
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
    SENTINEL_QUERY = "SELECT rdf_count()"

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

          Or set MM_SQLITE_SPARQL_PATH to point at an already-built
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
      candidate = ENV["MM_SQLITE_SPARQL_PATH"]
      return candidate if candidate && !candidate.empty? && File.exist?(candidate)
      searched_paths.find { |p| File.exist?(p) }
    end

    # The ordered list of paths checked when MM_SQLITE_SPARQL_PATH
    # isn't set or isn't on disk. Specs + chrome reuse this for the
    # ExtensionMissing message + build-instruction docs.
    def searched_paths
      DEFAULT_PATHS.map { |p| absolute_for(p) }
    end

    def absolute_for(relative)
      base = if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.parent.to_s
      else
        Dir.pwd
      end
      File.expand_path(relative, base)
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
  end
end
