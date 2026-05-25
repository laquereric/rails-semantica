# frozen_string_literal: true

# vv-graph gem entry point. Pulls every sub-module in; the
# Railtie boots itself when Rails is present.
#
# Renamed from rails-semantica (v0.14.0 → v0.15.0). The top-level
# constant is `Vv::Graph` (matching the agent-os/rules/ruby.md
# convention pinning `Vv::*` for vv-* gems).
require "active_support"
require "active_support/concern"
require "active_support/core_ext/object/blank"

# Declare the outer namespace before requiring sub-files. Each
# sub-file opens `module Vv::Graph` (qualified shortcut), which
# requires `Vv` to already exist as a constant.
module Vv
  module Graph
  end
end

require_relative "vv/graph/version"
require_relative "vv/graph/loader"
require_relative "vv/graph/sparql"
require_relative "vv/graph/storable"
require_relative "vv/graph/ethereal_graph"
require_relative "vv/graph/scope"
require_relative "vv/graph/change_set"
require_relative "vv/graph/reasoner"
require_relative "vv/graph/shacl"
require_relative "vv/graph/shacl/rules"
require_relative "vv/graph/capabilities"
require_relative "vv/graph/railtie" if defined?(::Rails::Railtie)
