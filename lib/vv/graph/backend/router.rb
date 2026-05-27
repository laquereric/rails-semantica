# frozen_string_literal: true

module Vv; end

module Vv::Graph
  module Backend
    # PLAN_0.16.0 Phase C — capability-aware backend router.
    #
    #   Vv::Graph::Backend::Router.pick(ir, hint: nil)
    #     # => { ok: true,  backend: :sparql | :relational, module: <const> }
    #     # => { ok: false, reason: :unknown_backend | :backend_missing_capability, ... }
    #
    # Precedence layers (each prior layer wins when set):
    #
    #   1. Explicit `hint:` (`backend: :sparql | :relational` on
    #      the QueryIR.run call).
    #   2. Env override (`ENV[Vv::Graph.config.query_backend_override_env]`).
    #   3. Capability fit: if the IR needs a capability one backend
    #      lacks AND the other has, pick the one that has it. If
    #      neither has the required capability, refuse with
    #      :backend_missing_capability. If both can run it, fall
    #      through to layer 4.
    #   4. Configured default (`Vv::Graph.config.default_query_backend`).
    #
    # When a hint or env override names a backend that can't run
    # the IR (capability gap), the refusal envelope carries the
    # missing-capability list. When a hint or env override names an
    # unknown backend, refuses with :unknown_backend.
    module Router
      REASON_UNKNOWN_BACKEND            = :unknown_backend
      REASON_BACKEND_MISSING_CAPABILITY = :backend_missing_capability

      ENV_BACKEND_VALUES = %w[sparql relational].freeze

      class << self
        def pick(ir, hint: nil)
          # ── Layer 1: explicit hint ────────────────────────────
          if hint
            return resolve_named(hint, ir, source: "hint")
          end

          # ── Layer 2: env override ─────────────────────────────
          env_name = ::Vv::Graph.config.query_backend_override_env
          env_value = env_name && ::ENV[env_name]
          if env_value && !env_value.empty?
            return resolve_named(env_value.to_sym, ir, source: "env override #{env_name}=#{env_value.inspect}")
          end

          # ── Layer 3: capability fit ───────────────────────────
          sparql_fit     = backend_for(:sparql).supports?(ir)
          relational_fit = backend_for(:relational).supports?(ir)

          sparql_ok     = sparql_fit     == true
          relational_ok = relational_fit == true

          if !sparql_ok && !relational_ok
            missing = collected_missing(sparql_fit, relational_fit)
            return missing_capability_refusal(missing, available: [:sparql, :relational])
          end

          if sparql_ok && !relational_ok
            return success(:sparql)
          end

          if relational_ok && !sparql_ok
            return success(:relational)
          end

          # ── Layer 4: configured default ───────────────────────
          default = ::Vv::Graph.config.default_query_backend
          resolve_named(default, ir, source: "config default")
        end

        private

        def resolve_named(key, ir, source:)
          key = key.to_sym
          mod = backend_for(key)
          unless mod
            return {
              ok: false,
              reason: REASON_UNKNOWN_BACKEND,
              because: "Vv::Graph::Backend::Router: #{source} requested backend #{key.inspect}, " \
                       "but it is not registered (known: #{::Vv::Graph::QueryIR::BACKENDS.keys.inspect})"
            }
          end

          fit = mod.supports?(ir)
          return success(key) if fit == true

          missing_capability_refusal(fit_missing(fit), available: [key], source: source)
        end

        def backend_for(key)
          thunk = ::Vv::Graph::QueryIR::BACKENDS[key.to_sym]
          thunk && thunk.call
        end

        def success(key)
          { ok: true, backend: key, module: backend_for(key) }
        end

        def fit_missing(fit)
          return [] if fit == true || fit.nil?
          return Array(fit[:missing]) if fit.is_a?(Hash)
          []
        end

        def collected_missing(*fits)
          fits.flat_map { |f| fit_missing(f) }.uniq
        end

        def missing_capability_refusal(missing, available:, source: nil)
          {
            ok: false,
            reason: REASON_BACKEND_MISSING_CAPABILITY,
            because: "Vv::Graph::Backend::Router: " \
                     "#{source ? "#{source} backend " : ""}cannot serve IR; missing: #{missing.inspect}",
            missing: missing,
            available_backends: available
          }
        end
      end
    end
  end
end
