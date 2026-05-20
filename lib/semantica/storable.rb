# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/class/attribute"

module Semantica
  # PLAN_0.1.0 Phase D — per-model triple-emission DSL.
  # PLAN_0.2.0 Phase A — `on_subject` sub-blocks + literal-string
  # predicate values.
  #
  # ActiveSupport::Concern that takes a `triples do ... end` block
  # declaring a `subject` lambda + an ordered list of
  # `triple(predicate, value_lambda, if: optional_guard_lambda)`
  # entries. `on_subject` blocks declare additional emissions on a
  # different subject IRI; they share the same lifecycle hooks.
  #
  #   class Product < ApplicationRecord
  #     include Semantica::Storable
  #
  #     triples do
  #       subject       -> { "urn:mm:product:#{sku}" }
  #       triple "schema:name",     -> { name }
  #       triple "schema:category", -> { category }
  #       triple "schema:gtin",     -> { gtin }, if: -> { gtin.present? }
  #
  #       on_subject -> { "urn:mm:folder:category:#{category}" } do
  #         triple "rdf:type",    "<urn:mm:CategoryFolder>"
  #         triple "schema:name", -> { category.titleize }
  #       end
  #     end
  #   end
  #
  # The `triple` second argument may be a lambda (evaluated in
  # instance scope each emission) or a literal value (constant
  # across emissions). Operators wanting an IRI object pass a
  # pre-wrapped `"<urn:...>"`-shaped string; otherwise the value
  # routes through `TermSerializer.object` for type dispatch.
  #
  # ## Idempotency contract
  #
  # `after_save` runs on both create and update. To prevent stale
  # values accumulating, every emission is read-replace per
  # predicate: SELECT any current value(s) for `<subject> <predicate>`,
  # DELETE each, then INSERT the new value. Re-saving an unchanged
  # record produces identical triples — Oxigraph set semantics make
  # the round-trip a no-op at the store level (though it still costs
  # a SELECT + DELETE + INSERT). Optimising via dirty-tracking is
  # post-0.1.0; v0.3.0's `:sparql_update` dispatch mode collapses
  # the round-trips when the engine surface is present.
  #
  # ## Failure mode
  #
  # `Semantica::Sparql.*` calls never raise — they return refusal
  # envelopes. v0.1.0 silently swallows refusals during emission;
  # callers wanting strict mode set `MM_SEMANTICA_STRICT=1` to
  # surface them as `RuntimeError`. Matches the
  # `MM_SEMANTICA_SOFT_FAIL` boot pattern in spirit (env-toggled
  # discipline, default = lenient during the substrate's interim
  # window).
  module Storable
    extend ActiveSupport::Concern

    included do
      class_attribute :semantica_triples_declaration, instance_accessor: false
    end

    class_methods do
      def triples(&block)
        raise ArgumentError, "triples requires a block" unless block

        recorder = Recorder.new
        recorder.instance_eval(&block)
        declaration = recorder.finalize!

        self.semantica_triples_declaration = declaration

        # Install lifecycle hooks once per model. Re-declaring is
        # idempotent at the callback level because ActiveSupport
        # de-dups identical method-symbol callbacks; redefining the
        # declaration just replaces the data.
        if respond_to?(:after_save)
          after_save    :semantica_emit_triples!
          after_destroy :semantica_retract_triples!
        end
      end
    end

    def semantica_emit_triples!
      decl = self.class.semantica_triples_declaration
      return unless decl

      semantica_emit_for_(decl.subject_lambda, decl.predicates)
      decl.on_subject_blocks.each do |block|
        semantica_emit_for_(block.subject_lambda, block.predicates)
      end
      true
    end

    def semantica_retract_triples!
      decl = self.class.semantica_triples_declaration
      return unless decl

      semantica_retract_for_(decl.subject_lambda, decl.predicates)
      decl.on_subject_blocks.each do |block|
        semantica_retract_for_(block.subject_lambda, block.predicates)
      end
      true
    end

    private

    def semantica_emit_for_(subject_lambda, predicates)
      subject_term = TermSerializer.iri(instance_exec(&subject_lambda))
      predicates.each do |pred|
        next if pred.if_lambda && !instance_exec(&pred.if_lambda)
        value = instance_exec(&pred.value_lambda)
        if value.nil?
          retract_predicate!(subject_term, TermSerializer.predicate(pred.iri))
        else
          replace_predicate!(
            subject_term,
            TermSerializer.predicate(pred.iri),
            TermSerializer.object(value),
          )
        end
      end
    end

    def semantica_retract_for_(subject_lambda, predicates)
      subject_term = TermSerializer.iri(instance_exec(&subject_lambda))
      predicates.each do |pred|
        retract_predicate!(subject_term, TermSerializer.predicate(pred.iri))
      end
    end

    def replace_predicate!(subject_term, predicate_term, new_object_term)
      retract_predicate!(subject_term, predicate_term)
      result = ::Semantica::Sparql.execute(
        "INSERT DATA { #{subject_term} #{predicate_term} #{new_object_term} . }",
      )
      raise_if_strict(result, "INSERT DATA #{predicate_term}")
      result
    end

    def retract_predicate!(subject_term, predicate_term)
      current = ::Semantica::Sparql.select(
        "SELECT ?o WHERE { #{subject_term} #{predicate_term} ?o }",
      )
      return current unless current[:ok]

      current[:results].each do |row|
        old_o = row["o"]
        next if old_o.nil? || old_o.empty?
        del = ::Semantica::Sparql.execute(
          "DELETE DATA { #{subject_term} #{predicate_term} #{old_o} . }",
        )
        raise_if_strict(del, "DELETE DATA #{predicate_term}")
      end
      current
    end

    def raise_if_strict(envelope, context)
      return if envelope[:ok]
      return unless ENV["MM_SEMANTICA_STRICT"] == "1"
      raise "Semantica::Storable #{context} refused: #{envelope[:reason]} — #{envelope[:because]}"
    end

    # ── DSL recorder ────────────────────────────────────────────

    Declaration = Struct.new(:subject_lambda, :predicates, :on_subject_blocks) do
      def initialize(subject_lambda:, predicates:, on_subject_blocks: [])
        super(subject_lambda, predicates, on_subject_blocks)
      end
    end

    Predicate = Struct.new(:iri, :value_lambda, :if_lambda) do
      def initialize(iri:, value_lambda:, if_lambda: nil)
        super(iri, value_lambda, if_lambda)
      end
    end

    OnSubjectBlock = Struct.new(:subject_lambda, :predicates) do
      def initialize(subject_lambda:, predicates:)
        super(subject_lambda, predicates)
      end
    end

    # Shared triple-recording between the top-level Recorder and the
    # SubRecorder used inside `on_subject` blocks. Both maintain a
    # `@predicates` array; `triple` appends to it.
    module TripleRecording
      # triple "schema:name", -> { name }
      # triple "schema:gtin", -> { gtin }, if: -> { gtin.present? }
      # triple "rdf:type",    "<urn:mm:CategoryFolder>"          # literal value
      def triple(iri, value_or_lambda, **opts)
        @predicates << Predicate.new(
          iri: iri,
          value_lambda: as_callable(value_or_lambda),
          if_lambda: opts[:if],
        )
      end

      # Wrap a literal value in a lambda so the emission path stays
      # uniform. Callables (Procs, lambdas) pass through.
      def as_callable(value_or_lambda)
        if value_or_lambda.respond_to?(:call)
          value_or_lambda
        else
          captured = value_or_lambda
          -> { captured }
        end
      end
    end

    class SubRecorder
      include TripleRecording

      attr_reader :predicates

      def initialize
        @predicates = []
      end
    end

    class Recorder
      include TripleRecording

      def initialize
        @subject_lambda = nil
        @predicates = []
        @on_subject_blocks = []
      end

      # subject -> { "urn:mm:product:#{sku}" }
      # subject { "urn:mm:product:#{sku}" }
      def subject(callable = nil, &block)
        @subject_lambda = callable || block
      end

      # on_subject -> { "urn:mm:folder:category:#{category}" } do
      #   triple "rdf:type",    "<urn:mm:CategoryFolder>"
      #   triple "schema:name", -> { category.titleize }
      # end
      def on_subject(subject_callable, &predicates_block)
        raise ArgumentError, "on_subject requires a predicates block" unless predicates_block
        raise ArgumentError, "on_subject requires a subject lambda" unless subject_callable

        sub = SubRecorder.new
        sub.instance_eval(&predicates_block)
        @on_subject_blocks << OnSubjectBlock.new(
          subject_lambda: subject_callable,
          predicates: sub.predicates.freeze,
        )
      end

      def finalize!
        raise ArgumentError, "triples block requires `subject`" unless @subject_lambda
        Declaration.new(
          subject_lambda: @subject_lambda,
          predicates: @predicates.freeze,
          on_subject_blocks: @on_subject_blocks.freeze,
        ).freeze
      end
    end

    # ── N-Triples term serialization ────────────────────────────

    module TermSerializer
      XSD = "http://www.w3.org/2001/XMLSchema"

      module_function

      # Wraps a value as an N-Triples IRI: `<iri>`. Pass-through if
      # already wrapped.
      def iri(value)
        s = value.to_s
        return s if s.start_with?("<") && s.end_with?(">")
        "<#{s}>"
      end

      # Predicates are always IRIs.
      def predicate(value)
        iri(value)
      end

      # Object serialization — type-dispatch:
      #   String       → "escaped string" (literal)
      #   Integer      → "42"^^<xsd:integer>
      #   Float        → "3.14"^^<xsd:double>
      #   true/false   → "true"^^<xsd:boolean>
      #   Time/DateTime→ "iso8601"^^<xsd:dateTime>
      #   Date         → "iso8601"^^<xsd:date>
      #   Other        → value.to_s as literal
      #
      # Operators wanting IRI objects pass already-wrapped strings
      # (e.g. `"<urn:other>"`) — those pass through unchanged.
      def object(value)
        case value
        when String
          if value.start_with?("<") && value.end_with?(">")
            value
          else
            literal(value)
          end
        when Integer
          typed_literal(value.to_s, "#{XSD}#integer")
        when Float
          typed_literal(value.to_s, "#{XSD}#double")
        when TrueClass, FalseClass
          typed_literal(value.to_s, "#{XSD}#boolean")
        else
          temporal_or_literal(value)
        end
      end

      def temporal_or_literal(value)
        if value.respond_to?(:iso8601)
          datatype = value.respond_to?(:hour) ? "#{XSD}#dateTime" : "#{XSD}#date"
          typed_literal(value.iso8601, datatype)
        else
          literal(value.to_s)
        end
      end

      def literal(string)
        %("#{escape_literal(string)}")
      end

      def typed_literal(value, datatype_iri)
        %("#{escape_literal(value)}"^^<#{datatype_iri}>)
      end

      # Minimum N-Triples literal escape: backslash, double-quote,
      # LF, CR, TAB. The store round-trips these unchanged.
      def escape_literal(string)
        string
          .gsub("\\", "\\\\\\\\")
          .gsub('"', '\\"')
          .gsub("\n", '\\n')
          .gsub("\r", '\\r')
          .gsub("\t", '\\t')
      end
    end
  end
end
