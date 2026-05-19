# frozen_string_literal: true

module Semantica
  # PLAN 0.29.1 Phase B — Rails integration. Hooks
  # Semantica::Loader.ensure_extension_loaded! into
  # config.after_initialize so the sqlite-sparql extension boots once
  # at app start + survives connection-pool churn. Subclass-of-
  # ::Rails::Railtie when Rails is present; no-op otherwise so the
  # gem stays loadable from non-Rails contexts (specs, scripts).
  if defined?(::Rails::Railtie)
    class Railtie < ::Rails::Railtie
      initializer "semantica.ensure_extension_loaded" do
        config.after_initialize do
          # Phase B fills in. Phase A keeps the hook silent so
          # `bundle install` + Rails boot stay green.
        end
      end
    end
  end
end
