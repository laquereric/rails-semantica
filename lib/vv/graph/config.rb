# frozen_string_literal: true

module Vv; end

module Vv::Graph
  # PLAN_0.16.0 Phase C — operator-tunable configuration.
  #
  #   Vv::Graph.config.default_query_backend = :sparql       # default
  #   Vv::Graph.config.query_backend_override_env = "VV_GRAPH_QUERY_BACKEND"
  #
  # The Router consults these in precedence layers 2 (env) and 4
  # (default). Layer 1 is the explicit `backend:` hint on the
  # `QueryIR.run` call; layer 3 is capability fit (does the IR need
  # anything one backend lacks).
  #
  # Phase C ships only the query-routing knobs. Future phases may
  # add more (e.g. `default_iri_prefix` migrates from
  # `Vv::Graph::Schema.iri_prefix`).
  class Config
    attr_accessor :default_query_backend, :query_backend_override_env

    def initialize
      @default_query_backend = :sparql
      @query_backend_override_env = "VV_GRAPH_QUERY_BACKEND"
    end
  end

  class << self
    def config
      @config ||= Config.new
    end

    def reset_config!
      @config = nil
    end
  end
end
