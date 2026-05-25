# frozen_string_literal: true

module Vv; end

module Vv::Graph
  # PLAN 0.29.1 Phase B — Rails integration. Hooks
  # Vv::Graph::Loader.ensure_extension_loaded! into
  # config.after_initialize so the sqlite-sparql extension boots once
  # at app start. Subclass-of-::Rails::Railtie when Rails is present;
  # no-op otherwise so the gem stays loadable from non-Rails contexts
  # (specs, scripts).
  #
  # Failure mode: if the extension isn't on disk, the after_initialize
  # hook re-raises Vv::Graph::Loader::ExtensionMissing with the build
  # command verbatim. The substrate fails to boot loudly rather than
  # starting in a half-functional state where SPARQL queries would
  # raise undefined-function errors at first call.
  #
  # Operators who want a soft-fail boot (e.g., CI environments that
  # don't build the extension yet, or substrates that don't use the
  # SPARQL surface) set MM_SEMANTICA_SOFT_FAIL=1; the hook logs a
  # warning + returns instead of raising. Use sparingly; the runtime
  # SPARQL surface raises undefined-function errors on first call
  # when the extension is missing.
  if defined?(::Rails::Railtie)
    class Railtie < ::Rails::Railtie
      initializer "semantica.ensure_extension_loaded" do
        config.after_initialize do
          begin
            ::Vv::Graph::Loader.ensure_extension_loaded!
          rescue ::Vv::Graph::Loader::ExtensionMissing => e
            if ENV["MM_SEMANTICA_SOFT_FAIL"] == "1"
              ::Rails.logger&.warn("Vv::Graph::Loader soft-fail: #{e.message.lines.first&.strip}")
            else
              raise
            end
          end
        end
      end
    end
  end
end
