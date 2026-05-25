# frozen_string_literal: true

require "active_support/concern"
require "set"
require "stringio"

# Active Storage is soft-optional. Operators including
# Vv::Graph::EtherealGraph with an Active Storage-enabled
# ActiveRecord::Base get auto-registered attachments; operators
# without Active Storage define the `vv_graph_blob`
# method themselves (returning any object that responds to
# `attached?` / `download` / `attach(io:, filename:, content_type:)`
# / `purge`).
begin
  require "openssl"
  require "active_storage"
  require "active_storage/attached/model"
rescue LoadError
  # Active Storage not loadable from this app's bundle; the
  # concern's `included do` block guards `has_one_attached`.
end

module Vv; end

module Vv::Graph
  # PLAN_0.7.0 Phase A — Rails-lifecycle-managed wrapper around a
  # named graph. The concern auto-registers
  # `has_one_attached :vv_graph_blob`; the operator's DSL
  # captures the graph IRI lambda and (optionally) a
  # `checkpoint_on:` policy.
  #
  #   class WorkspaceContext < ApplicationRecord
  #     include Vv::Graph::EtherealGraph
  #
  #     ethereal_graph do
  #       iri           -> { "urn:mm:workspace:#{id}:context" }
  #       checkpoint_on :explicit   # :explicit (default) | :save
  #     end
  #   end
  #
  # ## Lifecycle
  #
  # - `#hydrate_ethereal_graph!` — first SPARQL access pulls the
  #   blob → `Sparql.bulk_insert(rows, raw: true)` → marks the IRI
  #   in `HYDRATED_IRIS`. Subsequent calls are no-ops. Records
  #   without an attached blob early-return `:no_blob`.
  # - `#checkpoint_ethereal_graph!` (Phase B) — flushes engine
  #   state back to the blob.
  # - `#retract_ethereal_graph!` (Phase C) — `before_destroy`
  #   drops the graph from the engine + evicts from the cache;
  #   Active Storage purges the blob via the attachment.
  #
  # ## Concurrency
  #
  # `HYDRATED_IRIS` is a process-wide Set guarded by a Mutex.
  # Hydrate-once-per-process serves every connection and thread
  # (PLAN_0.6.0 shared-store posture). Multi-process operators
  # accept eventual consistency on checkpoints; per-IRI eviction
  # via `evict!(iri)` is the explicit escape hatch.
  module EtherealGraph
    extend ActiveSupport::Concern

    HYDRATED_IRIS = Set.new
    HYDRATE_MUTEX = Mutex.new

    REASON_NO_BLOB                  = :no_blob
    REASON_ALREADY_HYDRATED         = :already_hydrated
    REASON_EMPTY_BLOB               = :empty_blob
    REASON_ETHEREAL_GRAPH_UNDECLARED = :ethereal_graph_undeclared

    HYDRATION_BATCH_SIZE = 1000

    CHECKPOINT_CONSTRUCT_QUERY = "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }"
    CHECKPOINT_CONTENT_TYPE    = "application/n-triples"

    included do
      # In a full Rails app, the ActiveStorage railtie includes
      # `ActiveStorage::Attached::Model` into `ActiveRecord::Base`,
      # so every model picks up `has_one_attached`. Outside Rails
      # (gem specs, standalone AR), include the concern into the
      # including class just-in-time if AS is loaded. If AS isn't
      # loaded at all, leave `vv_graph_blob` for the operator
      # to define — any object responding to `attached?` / `download`
      # / `attach` / `purge` works.
      if !respond_to?(:has_one_attached) && defined?(::ActiveStorage::Attached::Model)
        include ::ActiveStorage::Attached::Model
      end

      if respond_to?(:has_one_attached)
        has_one_attached :vv_graph_blob, dependent: :purge_later
      end

      class_attribute :semantica_ethereal_declaration, instance_accessor: false

      if respond_to?(:before_destroy)
        before_destroy :retract_ethereal_graph!
      end
    end

    class_methods do
      def ethereal_graph(&block)
        raise ArgumentError, "ethereal_graph requires a block" unless block

        recorder = Recorder.new
        recorder.instance_eval(&block)
        decl = recorder.finalize!
        self.semantica_ethereal_declaration = decl

        if decl.checkpoint_on == :save && respond_to?(:after_save)
          after_save :checkpoint_ethereal_graph!
        end
      end
    end

    def ethereal_graph_iri
      decl = self.class.semantica_ethereal_declaration
      return nil unless decl
      instance_exec(&decl.iri_lambda)
    end

    def hydrate_ethereal_graph!
      decl = self.class.semantica_ethereal_declaration
      return { ok: false, reason: REASON_ETHEREAL_GRAPH_UNDECLARED, because: "no ethereal_graph declaration on #{self.class.name}" } unless decl

      iri = instance_exec(&decl.iri_lambda)
      return { ok: true, hydrated: 0, reason: REASON_ALREADY_HYDRATED } if EtherealGraph.hydrated?(iri)

      attachment = vv_graph_blob
      return { ok: true, hydrated: 0, reason: REASON_NO_BLOB } unless attachment.attached?

      blob_text = attachment.download.to_s.strip
      if blob_text.empty?
        EtherealGraph.mark_hydrated!(iri)
        return { ok: true, hydrated: 0, reason: REASON_EMPTY_BLOB }
      end

      rows = EtherealGraph.parse_ntriples(blob_text, iri)
      if rows.empty?
        EtherealGraph.mark_hydrated!(iri)
        return { ok: true, hydrated: 0, reason: REASON_EMPTY_BLOB }
      end

      total = 0
      rows.each_slice(HYDRATION_BATCH_SIZE) do |chunk|
        result = ::Vv::Graph::Sparql.bulk_insert(chunk, raw: true)
        return result unless result[:ok]
        total += result[:inserted].to_i
      end

      EtherealGraph.mark_hydrated!(iri)
      { ok: true, hydrated: total }
    end

    # PLAN_0.7.0 Phase B — flush engine state for this record's
    # named graph back to the Active Storage blob. CONSTRUCTs every
    # triple in the graph as N-Triples, detaches the existing
    # attachment if any, attaches a new blob.
    #
    # Re-entrant guard: attaching a new blob fires the host record's
    # `after_save` callbacks. Under `checkpoint_on: :save` that would
    # re-enter this method recursively. The thread-local guard breaks
    # the cycle without disturbing the unrelated callback chain.
    def checkpoint_ethereal_graph!
      decl = self.class.semantica_ethereal_declaration
      return { ok: false, reason: REASON_ETHEREAL_GRAPH_UNDECLARED, because: "no ethereal_graph declaration on #{self.class.name}" } unless decl

      iri = instance_exec(&decl.iri_lambda)
      guard_key = [object_id, iri]
      stack = Thread.current[:vv_semantica_checkpoint_stack] ||= []
      return { ok: true, written: 0, reason: :reentrant_checkpoint } if stack.include?(guard_key)

      stack.push(guard_key)
      begin
        construct = ::Vv::Graph::Sparql.construct(CHECKPOINT_CONSTRUCT_QUERY, graph: iri)
        return construct unless construct[:ok]

        ntriples = construct[:ntriples].to_s
        attachment = vv_graph_blob
        attachment.purge if attachment.attached?

        attachment.attach(
          io: StringIO.new(ntriples),
          filename: "#{checkpoint_filename_(iri)}.nt",
          content_type: CHECKPOINT_CONTENT_TYPE,
        )

        { ok: true, written: ntriples.bytesize }
      ensure
        stack.pop
      end
    end

    # PLAN_0.7.0 Phase C — retract this record's named graph from the
    # engine + drop it from the hydration cache. `has_one_attached`'s
    # `dependent: :purge_later` purges the blob when the record's
    # destroy completes, so we don't touch the attachment here.
    def retract_ethereal_graph!
      decl = self.class.semantica_ethereal_declaration
      return { ok: false, reason: REASON_ETHEREAL_GRAPH_UNDECLARED, because: "no ethereal_graph declaration on #{self.class.name}" } unless decl

      iri = instance_exec(&decl.iri_lambda)
      clear = ::Vv::Graph::Sparql.execute("CLEAR GRAPH <#{iri}>")
      EtherealGraph.evict!(iri)
      return clear unless clear[:ok]

      { ok: true, retracted: iri }
    end

    def checkpoint_filename_(iri)
      iri.to_s.gsub(/[^A-Za-z0-9._-]+/, "_").gsub(/\A_+|_+\z/, "")[0, 120].then do |slug|
        slug.empty? ? "graph" : slug
      end
    end

    class << self
      def hydrated?(iri)
        HYDRATE_MUTEX.synchronize { HYDRATED_IRIS.include?(iri) }
      end

      def mark_hydrated!(iri)
        HYDRATE_MUTEX.synchronize { HYDRATED_IRIS.add(iri) }
      end

      def evict!(iri)
        HYDRATE_MUTEX.synchronize { HYDRATED_IRIS.delete(iri) }
      end

      def reset!
        HYDRATE_MUTEX.synchronize { HYDRATED_IRIS.clear }
      end

      # Parse an N-Triples body into 4-tuple rows for
      # `Sparql.bulk_insert(rows, raw: true)`. Each non-blank,
      # non-comment line yields one row. Subjects + predicates +
      # IRI objects are stripped of angle brackets (engine wants
      # bare IRIs); literal objects pass through in N-Triples form.
      def parse_ntriples(text, graph_iri)
        rows = []
        text.each_line do |raw_line|
          line = raw_line.strip
          next if line.empty?
          next if line.start_with?("#")
          line = line.chomp(".").strip
          next if line.empty?
          terms = ::Vv::Graph::Sparql.send(:split_ntriple, line)
          next unless terms && terms.length == 3
          s = strip_brackets_(terms[0])
          p = strip_brackets_(terms[1])
          o = terms[2].start_with?("<") ? strip_brackets_(terms[2]) : terms[2]
          rows << [s, p, o, graph_iri]
        end
        rows
      end

      def strip_brackets_(term)
        return term unless term.is_a?(String)
        # PLAN_0.13.0 Phase B — quoted-triple terms (`<< s p o >>`)
        # are passed through verbatim; the engine's
        # `rdf_insert_many` (sqlite-sparql 0.7.0+) accepts them in
        # subject and object positions without bracket-stripping.
        return term if term.start_with?("<<")
        return term[1..-2] if term.start_with?("<") && term.end_with?(">")
        term
      end
    end

    # ── DSL recorder ────────────────────────────────────────────

    Declaration = Struct.new(:iri_lambda, :checkpoint_on) do
      def initialize(iri_lambda:, checkpoint_on: :explicit)
        super(iri_lambda, checkpoint_on)
      end
    end

    class Recorder
      VALID_CHECKPOINT_MODES = %i[explicit save].freeze

      def initialize
        @iri_lambda = nil
        @checkpoint_on = :explicit
      end

      def iri(callable = nil, &block)
        @iri_lambda = callable || block
      end

      def checkpoint_on(mode)
        unless VALID_CHECKPOINT_MODES.include?(mode)
          raise ArgumentError,
                "checkpoint_on expects one of #{VALID_CHECKPOINT_MODES.inspect}, got #{mode.inspect}"
        end
        @checkpoint_on = mode
      end

      def finalize!
        raise ArgumentError, "ethereal_graph block requires `iri`" unless @iri_lambda
        Declaration.new(iri_lambda: @iri_lambda, checkpoint_on: @checkpoint_on).freeze
      end
    end
  end
end
