# frozen_string_literal: true

module Semantica
  # PLAN 0.29.1 Phase B — boots the sqlite-sparql SQLite extension
  # across AR connection-pool restarts. Stub-only in Phase A.
  module Loader
    class ExtensionMissing < StandardError; end

    module_function

    def ensure_extension_loaded!
      # Phase B fills in. Walks ActiveRecord::Base.connection_pool,
      # checks each connection's loaded_extensions, calls
      # `enable_load_extension` + loads the .dylib / .so from
      # ENV["MM_SQLITE_SPARQL_PATH"]. Idempotent.
      raise NotImplementedError, "Semantica::Loader.ensure_extension_loaded! ships in PLAN_0_29_1 Phase B"
    end
  end
end
