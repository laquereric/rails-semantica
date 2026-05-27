# frozen_string_literal: true

require_relative "query_ir/nodes"

module Vv; end

module Vv::Graph
  # PLAN_0.16.0 Phase A — QueryIR run entry point.
  #
  #   Vv::Graph::QueryIR.run(ir, scope:, backend: nil, with_meta: false)
  #
  # ir       : Array<QueryIR::*> — composition is a flat list. Find
  #            is required and must come first; one Limit max; one
  #            Sort max (multi-sort additive in v0.17.0); one Count
  #            max; one Compare max; one Project max. Composition
  #            rule violations refuse with :ir_invalid.
  # scope    : graph IRI (sparql) or model namespace (relational).
  #            Both backends accept it; both are safe to pass.
  # backend  : :sparql | :relational | nil. Phase A always honours
  #            :sparql (the router lands in Phase C). When nil,
  #            Phase A picks :sparql.
  # with_meta: when true, the success envelope grows
  #            { plan: <query string>, backend: :sparql, ms: <float> }.
  #
  # Never raises. Refusal envelopes carry the structural shape the
  # rest of the gem emits: { ok: false, reason:, because: }.
  module QueryIR
    REASON_IR_INVALID                  = :ir_invalid
    REASON_SCHEMA_FIELD_UNKNOWN        = :schema_field_unknown
    REASON_BACKEND_MISSING_CAPABILITY  = :backend_missing_capability
    REASON_UNKNOWN_BACKEND             = :unknown_backend

    BACKENDS = {
      sparql:     -> { ::Vv::Graph::Backend::Sparql },
      relational: -> { ::Vv::Graph::Backend::Relational }
    }.freeze

    module_function

    def run(ir, scope: nil, backend: nil, with_meta: false)
      ir_array = Array(ir)
      validation = validate(ir_array)
      return validation unless validation == :ok

      pick = ::Vv::Graph::Backend::Router.pick(ir_array, hint: backend)
      return pick unless pick[:ok]

      backend_key = pick[:backend]
      backend_mod = pick[:module]
      started = monotonic_now
      envelope = backend_mod.execute(ir_array, scope: scope)
      elapsed_ms = ((monotonic_now - started) * 1000.0).round(3)

      return envelope unless envelope[:ok]
      return envelope unless with_meta

      envelope.merge(
        plan: envelope[:query],
        backend: backend_key,
        ms: elapsed_ms
      )
    end

    # Returns :ok on success, or a refusal envelope on failure.
    def validate(ir)
      unless ir.is_a?(Array) && !ir.empty?
        return refuse_ir_invalid("IR must be a non-empty Array; got #{ir.class}")
      end

      finds      = count_of(ir, ::Vv::Graph::QueryIR::Find)
      limits     = count_of(ir, ::Vv::Graph::QueryIR::Limit)
      sorts      = count_of(ir, ::Vv::Graph::QueryIR::Sort)
      counts     = count_of(ir, ::Vv::Graph::QueryIR::Count)
      projects   = count_of(ir, ::Vv::Graph::QueryIR::Project)
      compares   = count_of(ir, ::Vv::Graph::QueryIR::Compare)

      return refuse_ir_invalid("IR must contain exactly one Find node; got #{finds}") if finds != 1
      return refuse_ir_invalid("Find must be the first node in the IR") unless ir.first.is_a?(::Vv::Graph::QueryIR::Find)
      return refuse_ir_invalid("at most one Limit node permitted (got #{limits})")     if limits > 1
      return refuse_ir_invalid("at most one Sort node permitted in v0.16.0 (got #{sorts}); multi-sort is additive in v0.17.0") if sorts > 1
      return refuse_ir_invalid("at most one Count node permitted (got #{counts})")     if counts > 1
      return refuse_ir_invalid("at most one Project node permitted (got #{projects})") if projects > 1
      return refuse_ir_invalid("at most one Compare node permitted (got #{compares})") if compares > 1

      if counts > 0 && (limits > 0 || sorts > 0 || projects > 0)
        return refuse_ir_invalid("Count is incompatible with Limit/Sort/Project in v0.16.0")
      end

      if compares > 0 && (limits > 0 || sorts > 0 || projects > 0 || counts > 0)
        return refuse_ir_invalid("Compare is incompatible with Limit/Sort/Project/Count in v0.16.0")
      end

      ir.each_with_index do |node, idx|
        return refuse_ir_invalid("node at index #{idx} is not a QueryIR value object: #{node.class}") unless qir_node?(node)
      end

      :ok
    end

    class << self
      private

      def count_of(ir, klass)
        ir.count { |n| n.is_a?(klass) }
      end

      def refuse_ir_invalid(message)
        {
          ok: false,
          reason: REASON_IR_INVALID,
          because: "Vv::Graph::QueryIR.run: #{message}"
        }
      end

      def qir_node?(node)
        [
          ::Vv::Graph::QueryIR::Find,
          ::Vv::Graph::QueryIR::Filter,
          ::Vv::Graph::QueryIR::FilterRange,
          ::Vv::Graph::QueryIR::FilterIn,
          ::Vv::Graph::QueryIR::Sort,
          ::Vv::Graph::QueryIR::Limit,
          ::Vv::Graph::QueryIR::Project,
          ::Vv::Graph::QueryIR::Count,
          ::Vv::Graph::QueryIR::Compare
        ].any? { |k| node.is_a?(k) }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
