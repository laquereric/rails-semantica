# frozen_string_literal: true

module Vv; end

module Vv::Graph
  # PLAN_0.16.0 Phase A — backend interface.
  #
  # A backend executes a QueryIR program against some storage plane.
  # v0.16.0 ships two: `Backend::Sparql` (the existing SPARQL facade,
  # Phase A) and `Backend::Relational` (ActiveRecord scopes, Phase B).
  #
  # Required class methods on every backend:
  #
  #   execute(ir, scope:)
  #     ir    : Array<QueryIR::*> — a validated program
  #     scope : graph IRI (sparql) or model namespace (relational); both safe
  #     => envelope { ok:, results:|value:|count:, ... } or { ok: false, reason:, because: }
  #
  #   capabilities
  #     => Hash<Symbol, Object> — the backend's advertised capability map
  #
  #   supports?(ir)
  #     => true | { missing: [<capability symbols>] }
  #
  # The router (Phase C) inspects `capabilities` + `supports?` to
  # pick between backends. Phase A wires `QueryIR.run` to the Sparql
  # backend unconditionally; the router lands in Phase C.
  #
  # Capability symbols pinned at v0.16.0:
  #
  #   :owl_closure     — backend honours OWL 2 RL closure semantics
  #   :shacl           — backend composes with SHACL validation
  #   :joins           — :rdf | :ar | :none — what kind of joins
  #   :datetime_filter — backend can filter on xsd:dateTime / ar timestamp
  #   :fts             — full-text-search predicate (deferred to v0.17.x)
  #   :named_graphs    — backend honours a `scope:` graph kwarg
  module Backend
    CAPABILITY_KEYS = %i[owl_closure shacl joins datetime_filter fts named_graphs].freeze
  end
end
