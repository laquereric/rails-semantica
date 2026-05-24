# frozen_string_literal: true

# PLAN 0.29.1 Phase A — gem entry point. Pulls every sub-module in;
# the Railtie boots itself when Rails is present.
require "active_support"
require "active_support/concern"
require "active_support/core_ext/object/blank"

require_relative "semantica/version"
require_relative "semantica/loader"
require_relative "semantica/sparql"
require_relative "semantica/storable"
require_relative "semantica/ethereal_graph"
require_relative "semantica/scope"
require_relative "semantica/change_set"
require_relative "semantica/reasoner"
require_relative "semantica/shacl"
require_relative "semantica/shacl/rules"
require_relative "semantica/railtie" if defined?(::Rails::Railtie)

module Semantica
end
