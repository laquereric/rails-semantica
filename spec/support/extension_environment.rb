# frozen_string_literal: true

# PLAN_0.1.0 Phase G — extension-environment lifecycle for specs.
#
# Boots ActiveRecord + sqlite3 with an in-memory connection and
# loads the compiled sqlite-sparql extension on first access. The
# whole thing is best-effort: if any prerequisite is missing (gems
# not bundled, extension not built), `.available?` returns false and
# `.skip_reason` carries the verbatim hint.
#
# Specs that need a live store tag themselves `:requires_extension`;
# spec_helper.rb skips them when this module reports unavailable.
module Vv::Graph
  module SpecSupport
    module ExtensionEnvironment
      class << self
        def available?
          ensure_attempted!
          @available
        end

        def skip_reason
          ensure_attempted!
          @skip_reason
        end

        # Empties the triple store between examples so test isolation
        # holds. Cheap — single `rdf_clear()` call.
        #
        # PLAN_0.6.0 Phase E — under engine ≥ 0.2.0 the store is
        # shared process-wide. `reset_store!` is *required* between
        # examples (not just hygiene); parallel test workers (e.g.
        # rspec-parallel) will clobber each other's stores. Run gem
        # specs serially.
        #
        # Ensures the extension is loaded on the current AR
        # connection before calling rdf_clear — without this guard,
        # specs that create AR connections in their own before(:all)
        # hooks (or any test ordering that causes AR to check out a
        # fresh connection between example files) hit "no such
        # function: rdf_clear" on the first :requires_extension
        # spec in the new connection's lifecycle. The Loader uses
        # a sentinel probe + skip so the call is a no-op when the
        # extension is already loaded.
        def reset_store!
          return unless available?
          ::Vv::Graph::Loader.ensure_extension_loaded!
          ::ActiveRecord::Base.connection.execute("SELECT rdf_clear()")
        end

        private

        def ensure_attempted!
          return if defined?(@attempted)
          @attempted = true
          @available = false
          @skip_reason = nil
          attempt_bootstrap
        end

        def attempt_bootstrap
          begin
            require "active_record"
            require "sqlite3"
          rescue LoadError => e
            @skip_reason = "skipping — required gems not loadable (#{e.message}). Run `bundle install` inside vendor/vv-graph."
            return
          end

          ext_path = ::Vv::Graph::Loader.extension_path
          unless ext_path
            @skip_reason = build_hint
            return
          end

          begin
            ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
            ::Vv::Graph::Loader.ensure_extension_loaded!
            ::ActiveRecord::Base.connection.execute("SELECT rdf_count()")
          rescue StandardError => e
            @skip_reason = "skipping — extension found at #{ext_path} but failed to load: #{e.message}"
            return
          end

          @available = true
        end

        def build_hint
          <<~HINT.strip
            skipping — sqlite-sparql extension not built. Build with:
              cd vendor/sqlite-sparql && cargo build --release
            Or set VV_GRAPH_SQLITE_SPARQL_PATH to an already-built .dylib / .so.
          HINT
        end
      end
    end
  end
end
