# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/class/attribute"
require "json"

module Semantica
  # PLAN_0.1.0 Phase D — per-model triple-emission DSL.
  # PLAN_0.2.0 Phase A — `on_subject` sub-blocks + literal-string
  # predicate values.
  # PLAN_0.2.0 Phase B — `each` blocks for collection iteration +
  # multi-value predicates (one triple per collection element;
  # multi-value when the predicate IRI is constant across items).
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

    # PLAN_0.3.0 Phase B + C — dispatch-mode ladder.
    #
    # Three lifecycle implementations:
    #
    #   :sparql_update — engine ≥ 0.5.0 (`sparql_update` scalar
    #                    present). Each predicate replacement is a
    #                    single DELETE/INSERT WHERE round-trip.
    #   :bulk          — engine ≥ 0.4.0 (`rdf_insert_many` present,
    #                    no `sparql_update`). PLAN_0.4.0 fills in the
    #                    actual implementation; until then this rung
    #                    of the ladder falls through to :per_call.
    #   :per_call      — v0.2.0 baseline. SELECT + DELETE DATA + INSERT
    #                    DATA per predicate, one round-trip each.
    #
    # Operators force a mode via `MM_SEMANTICA_DISPATCH_MODE=...` for
    # predictable behaviour across upgrades. The probe runs once on
    # first call + caches; reset via `dispatch_mode_reset!` (specs).
    #
    # PLAN_0.6.0 Phase D — concurrency note. Under engine ≥ 0.2.0
    # the store is process-wide. Concurrent writes to the same
    # (subject, predicate) from different threads are atomic under
    # `:sparql_update` (the engine's Oxigraph store handles the
    # DELETE/INSERT WHERE in one call); `:bulk` and `:per_call` race.
    # Recommend `MM_SEMANTICA_DISPATCH_MODE=sparql_update` for
    # multi-threaded write workloads.
    ENV_DISPATCH_MODE = "MM_SEMANTICA_DISPATCH_MODE"

    DISPATCH_MODES = [:sparql_update, :bulk, :per_call].freeze

    class << self
      def dispatch_mode
        @dispatch_mode ||= detect_dispatch_mode
      end

      def dispatch_mode_reset!
        @dispatch_mode = nil
      end

      private

      def detect_dispatch_mode
        forced = ENV[ENV_DISPATCH_MODE]
        if forced && !forced.empty?
          sym = forced.to_sym
          return sym if DISPATCH_MODES.include?(sym)
        end

        return :per_call unless defined?(::ActiveRecord::Base)

        begin
          ::Semantica::Loader.ensure_extension_loaded!
          connection = ::ActiveRecord::Base.connection
          # Probe: a no-op SPARQL UPDATE. Engine returns 0 on success;
          # "no such function" surfaces from SQLite when the scalar
          # isn't registered (pre-0.5.0 engine). Anything else means
          # the function exists — even a parse error proves it.
          connection.select_value(
            "SELECT sparql_update(#{connection.quote('CLEAR SILENT GRAPH <urn:semantica:dispatch-probe>')})",
          )
          :sparql_update
        rescue ::ActiveRecord::StatementInvalid => e
          return :per_call if e.message.to_s.downcase.include?("no such function")
          :sparql_update
        rescue StandardError
          :per_call
        end
      end
    end

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

      with_bulk_buffer_if_bulk_mode_ do
        graph = decl.graph_iri
        semantica_emit_for_(decl.subject_lambda, decl.predicates, graph)
        decl.on_subject_blocks.each do |block|
          semantica_emit_for_(block.subject_lambda, block.predicates, graph)
        end
        decl.each_blocks.each do |each_block|
          semantica_emit_each_block_(decl.subject_lambda, each_block, graph)
        end
      end
      true
    end

    def semantica_retract_triples!
      decl = self.class.semantica_triples_declaration
      return unless decl

      with_bulk_buffer_if_bulk_mode_ do
        graph = decl.graph_iri
        semantica_retract_for_(decl.subject_lambda, decl.predicates, graph)
        decl.on_subject_blocks.each do |block|
          semantica_retract_for_(block.subject_lambda, block.predicates, graph)
        end
        decl.each_blocks.each do |each_block|
          semantica_retract_each_block_(decl.subject_lambda, each_block, graph)
        end
      end
      true
    end

    private

    def semantica_emit_for_(subject_lambda, predicates, graph = nil)
      subject_iri  = instance_exec(&subject_lambda)
      subject_term = TermSerializer.iri(subject_iri)
      predicates.each do |pred|
        next if pred.if_lambda && !instance_exec(&pred.if_lambda)
        value = instance_exec(&pred.value_lambda)
        predicate_term = TermSerializer.predicate(pred.iri)

        if value.nil?
          retract_predicate!(subject_term, predicate_term, graph)
          # If parent value is nil, prior annotations dangle on the
          # old quoted-triple subject — retract them via DELETE WHERE.
          semantica_retract_orphan_annotations_(subject_iri, pred, graph)
          next
        end

        # PLAN_0.8.0 Phase B — retract any orphan annotations on
        # the prior parent value's quoted-triple subject before
        # writing the new parent triple. Safe-idempotent (no-op
        # when the predicate carries no annotations, OR when the
        # store is empty for this subject+predicate).
        semantica_retract_orphan_annotations_(subject_iri, pred, graph)

        replace_predicate!(
          subject_term,
          predicate_term,
          TermSerializer.object(value),
          graph,
        )

        # Emit annotations on the new quoted-triple subject.
        semantica_emit_annotations_(subject_iri, pred, value, graph)
      end
    end

    def semantica_retract_for_(subject_lambda, predicates, graph = nil)
      subject_iri  = instance_exec(&subject_lambda)
      subject_term = TermSerializer.iri(subject_iri)
      predicates.each do |pred|
        retract_predicate!(subject_term, TermSerializer.predicate(pred.iri), graph)
        # Retract any annotations whose subject is the quoted-triple
        # form of this parent. The parent value at destroy time may
        # not match what was originally emitted (object could have
        # changed since); the safe pattern is `DELETE WHERE` against
        # the quoted-triple subject with the annotation predicate as
        # a variable.
        semantica_retract_orphan_annotations_(subject_iri, pred, graph)
      end
    end

    # PLAN_0.8.0 Phase B — emit one triple per annotation declared
    # on `pred`. Annotation subject = the quoted-triple form of the
    # just-emitted parent. Annotation predicate = the operator's
    # `annotate` IRI. Annotation object = the evaluator's result.
    #
    # Each annotation uses `replace_predicate!` so re-saves are
    # idempotent (same parent value + same annotation value = no-op).
    def semantica_emit_annotations_(parent_subject_iri, pred, parent_value, graph)
      return if pred.annotations.nil? || pred.annotations.empty?

      quoted_subject = ::Semantica::Sparql.quoted_triple(
        parent_subject_iri, pred.iri, parent_value,
      )
      quoted_term = TermSerializer.iri(quoted_subject)

      pred.annotations.each do |ann|
        next if ann.if_lambda && !instance_exec(&ann.if_lambda)
        ann_value = instance_exec(&ann.value_lambda)
        next if ann_value.nil?

        replace_predicate!(
          quoted_term,
          TermSerializer.predicate(ann.predicate_iri),
          TermSerializer.object(ann_value),
          graph,
        )
      end
    end

    # PLAN_0.8.0 Phase B — retract every annotation on the parent's
    # quoted-triple subject regardless of current object value.
    # SPARQL UPDATE: `DELETE { << s p ?o >> ?ap ?ao } WHERE { << s p ?o >> ?ap ?ao }`.
    # Routes through `Sparql.execute` so the engine handles the
    # quoted-triple match natively.
    def semantica_retract_orphan_annotations_(parent_subject_iri, pred, graph)
      return if pred.annotations.nil? || pred.annotations.empty?

      subject_iri_form   = TermSerializer.iri(parent_subject_iri)
      predicate_iri_form = TermSerializer.predicate(pred.iri)

      update = <<~SPARQL
        DELETE { << #{subject_iri_form} #{predicate_iri_form} ?__o >> ?__ap ?__ao }
        WHERE  { << #{subject_iri_form} #{predicate_iri_form} ?__o >> ?__ap ?__ao }
      SPARQL
      ::Semantica::Sparql.execute(update, graph: graph)
    end

    # PLAN_0.2.0 Phase B emission: walk the collection, accumulate
    # (iri, value) pairs, then for each unique predicate IRI retract
    # all current values for (subject, predicate) and insert the fresh set.
    #
    # Caveats documented in the plan:
    # - When the collection is empty this save, the predicate set is empty,
    #   so no retraction fires; stale triples from a prior non-empty save
    #   persist. v0.2.0 ships this limitation.
    # - Values returning nil are *skipped* (not emitted as nil-retraction);
    #   the surrounding read-replace per-predicate already cleared the slot.
    def semantica_emit_each_block_(subject_lambda, each_block, graph = nil)
      subject_term = TermSerializer.iri(instance_exec(&subject_lambda))
      collection = instance_exec(&each_block.collection_lambda)
      return if collection.nil? || (collection.respond_to?(:empty?) && collection.empty?)

      buffer = collect_each_predicates_(collection, each_block)

      by_predicate = Hash.new { |h, k| h[k] = [] }
      buffer.each do |pred|
        next if pred.if_lambda && !instance_exec(&pred.if_lambda)
        value = instance_exec(&pred.value_lambda)
        next if value.nil?
        by_predicate[pred.iri] << TermSerializer.object(value)
      end

      by_predicate.each do |iri, new_object_terms|
        replace_predicate_set!(
          subject_term,
          TermSerializer.predicate(iri),
          new_object_terms,
          graph,
        )
      end
    end

    # Destroy-path counterpart. Walks the collection one last time to
    # enumerate the predicate set; retracts each via dispatch-mode's
    # retract helper. If the collection is empty at destroy time, no
    # retraction fires — stale triples from prior saves survive.
    def semantica_retract_each_block_(subject_lambda, each_block, graph = nil)
      subject_term = TermSerializer.iri(instance_exec(&subject_lambda))
      collection = instance_exec(&each_block.collection_lambda)
      return if collection.nil? || (collection.respond_to?(:empty?) && collection.empty?)

      buffer = collect_each_predicates_(collection, each_block)
      buffer.map(&:iri).uniq.each do |iri|
        retract_predicate!(subject_term, TermSerializer.predicate(iri), graph)
      end
    end

    # Run the each block once per collection item, accumulating
    # Predicate records into a shared buffer.
    def collect_each_predicates_(collection, each_block)
      buffer = []
      collection.each do |item|
        item_recorder = EachItemRecorder.new(buffer)
        item_recorder.instance_exec(item, &each_block.block_proc)
      end
      buffer
    end

    def replace_predicate!(subject_term, predicate_term, new_object_term, graph = nil)
      replace_predicate_set!(subject_term, predicate_term, [new_object_term], graph)
    end

    def retract_predicate!(subject_term, predicate_term, graph = nil)
      if @semantica_bulk_buffer
        @semantica_bulk_buffer.add(subject_term, predicate_term, [], graph)
        return { ok: true }
      end

      case ::Semantica::Storable.dispatch_mode
      when :sparql_update
        retract_predicate_via_update!(subject_term, predicate_term, graph)
      else
        retract_predicate_per_call!(subject_term, predicate_term, graph)
      end
    end

    # PLAN_0.3.0 Phase B — replace a (subject, predicate) slot with
    # a (possibly multi-value) set of new object terms in one engine
    # round-trip when sparql_update is available; otherwise fall
    # back to the per-call SELECT+DELETE+INSERT path.
    #
    # PLAN_0.4.0 Phase B — when an outer bulk buffer is active
    # (:bulk dispatch mode), record into the buffer instead of
    # executing; flush_emit! issues one bulk_delete + one
    # bulk_insert at the end of the save.
    def replace_predicate_set!(subject_term, predicate_term, new_object_terms, graph = nil)
      if @semantica_bulk_buffer
        @semantica_bulk_buffer.add(subject_term, predicate_term, new_object_terms, graph)
        return { ok: true }
      end

      case ::Semantica::Storable.dispatch_mode
      when :sparql_update
        replace_predicate_set_via_update!(subject_term, predicate_term, new_object_terms, graph)
      else
        replace_predicate_set_per_call!(subject_term, predicate_term, new_object_terms, graph)
      end
    end

    # PLAN_0.4.0 Phase B — bulk-mode lifecycle wrapper. Captures
    # replace/retract operations across primary + on_subject + each
    # blocks; flushes via one combined bulk_delete (all current
    # values for affected (s, p, graph) keys) + one combined
    # bulk_insert (all new values). 2 + N round-trips per save where
    # N = unique (s, p, graph) keys: the engine SELECT count
    # dominates wall-clock for records with many predicates; the
    # bulk_delete + bulk_insert are constant.
    def with_bulk_buffer_if_bulk_mode_
      if ::Semantica::Storable.dispatch_mode == :bulk
        prior = @semantica_bulk_buffer
        @semantica_bulk_buffer = BulkEmitBuffer.new
        begin
          yield
          flush = @semantica_bulk_buffer.flush!
          raise_if_strict(flush, "bulk flush") if flush.is_a?(Hash) && !flush[:ok]
        ensure
          @semantica_bulk_buffer = prior
        end
      else
        yield
      end
    end

    def replace_predicate_set_via_update!(s, p, new_objects, graph)
      insert_clause =
        if new_objects.empty?
          ""
        else
          new_objects.map { |o| "#{s} #{p} #{o} ." }.join(" ")
        end

      update =
        if insert_clause.empty?
          "DELETE { #{s} #{p} ?o } WHERE { #{s} #{p} ?o }"
        else
          "DELETE { #{s} #{p} ?o }\n" \
            "INSERT { #{insert_clause} }\n" \
            "WHERE  { OPTIONAL { #{s} #{p} ?o } }"
        end

      result = ::Semantica::Sparql.execute(update, graph: graph)
      raise_if_strict(result, "DELETE/INSERT WHERE #{p}")
      result
    end

    def replace_predicate_set_per_call!(s, p, new_objects, graph)
      retract_predicate_per_call!(s, p, graph)
      return { ok: true, count: 0 } if new_objects.empty?

      body = new_objects.map { |o| "#{s} #{p} #{o} ." }.join("\n")
      result = ::Semantica::Sparql.execute("INSERT DATA { #{body} }", graph: graph)
      raise_if_strict(result, "INSERT DATA #{p}")
      result
    end

    def retract_predicate_via_update!(s, p, graph)
      result = ::Semantica::Sparql.execute(
        "DELETE { #{s} #{p} ?o } WHERE { #{s} #{p} ?o }",
        graph: graph,
      )
      raise_if_strict(result, "DELETE WHERE #{p}")
      result
    end

    def retract_predicate_per_call!(s, p, graph)
      current = ::Semantica::Sparql.select(
        "SELECT ?o WHERE { #{s} #{p} ?o }",
        graph: graph,
      )
      return current unless current[:ok]

      current[:results].each do |row|
        old_o = row["o"]
        next if old_o.nil? || old_o.empty?
        del = ::Semantica::Sparql.execute(
          "DELETE DATA { #{s} #{p} #{old_o} . }",
          graph: graph,
        )
        raise_if_strict(del, "DELETE DATA #{p}")
      end
      current
    end

    def raise_if_strict(envelope, context)
      return if envelope[:ok]
      return unless ENV["MM_SEMANTICA_STRICT"] == "1"
      raise "Semantica::Storable #{context} refused: #{envelope[:reason]} — #{envelope[:because]}"
    end

    # ── Bulk emit buffer (PLAN_0.4.0 Phase B) ───────────────────

    # Captures replace/retract intents across a single save,
    # flushes via one bulk_delete (current values) + one
    # bulk_insert (new values). add(s_term, p_term, new_objs, graph)
    # appends an entry; an entry with an empty new_objs array is a
    # pure retract.
    #
    # Group key is (subject_term, predicate_term, graph) so that
    # multiple adds to the same slot (e.g., from primary +
    # on_subject blocks accidentally touching the same predicate)
    # union their new objects.
    class BulkEmitBuffer
      Entry = Struct.new(:subject_term, :predicate_term, :new_objects, :graph) do
        def key
          [subject_term, predicate_term, graph]
        end
      end

      def initialize
        @entries = []
      end

      def add(subject_term, predicate_term, new_object_terms, graph)
        @entries << Entry.new(subject_term, predicate_term, new_object_terms.dup, graph)
      end

      def flush!
        return { ok: true } if @entries.empty?

        grouped = Hash.new { |h, k| h[k] = [] }
        @entries.each { |e| grouped[e.key].concat(e.new_objects) }

        delete_rows = []
        grouped.each_key do |(s_term, p_term, graph)|
          current = ::Semantica::Sparql.select(
            "SELECT ?o WHERE { #{s_term} #{p_term} ?o }",
            graph: graph,
          )
          next unless current[:ok]
          current[:results].each do |row|
            o_raw = row["o"]
            next if o_raw.nil? || o_raw.empty?
            delete_rows << build_row_(s_term, p_term, o_raw, graph)
          end
        end

        insert_rows = []
        grouped.each do |(s_term, p_term, graph), new_objects|
          new_objects.each do |o_term|
            insert_rows << build_row_(s_term, p_term, o_term, graph)
          end
        end

        unless delete_rows.empty?
          del = ::Semantica::Sparql.bulk_delete(delete_rows, raw: true)
          return del unless del[:ok]
        end
        unless insert_rows.empty?
          ins = ::Semantica::Sparql.bulk_insert(insert_rows, raw: true)
          return ins unless ins[:ok]
        end
        { ok: true }
      end

      private

      def build_row_(s_term, p_term, o_term, graph)
        s_bare = bare_(s_term)
        p_bare = bare_(p_term)
        o_engine = o_term.start_with?("<") ? bare_(o_term) : o_term
        if graph
          [s_bare, p_bare, o_engine, graph]
        else
          [s_bare, p_bare, o_engine]
        end
      end

      def bare_(term)
        return term unless term.is_a?(String) && term.start_with?("<") && term.end_with?(">")
        term[1..-2]
      end
    end

    # ── DSL recorder ────────────────────────────────────────────

    Declaration = Struct.new(:subject_lambda, :predicates, :on_subject_blocks, :each_blocks, :graph_iri) do
      def initialize(subject_lambda:, predicates:, on_subject_blocks: [], each_blocks: [], graph_iri: nil)
        super(subject_lambda, predicates, on_subject_blocks, each_blocks, graph_iri)
      end
    end

    # PLAN_0.8.0 Phase B — `annotate` block on a `triple` declaration
    # populates `annotations` with one Annotation per annotate call.
    # Empty array when the triple has no `annotate` block (the
    # common case).
    Predicate = Struct.new(:iri, :value_lambda, :if_lambda, :annotations) do
      def initialize(iri:, value_lambda:, if_lambda: nil, annotations: [])
        super(iri, value_lambda, if_lambda, annotations.freeze)
      end
    end

    # PLAN_0.8.0 Phase B — single annotation inside a `triple … do
    # annotate p, ->{...}; end` block. The validator's evaluator
    # is called at emission time with the parent triple's resolved
    # (s, p, o) so the annotation can attach to a
    # `Sparql.quoted_triple(s, p, o)` subject.
    Annotation = Struct.new(:predicate_iri, :value_lambda, :if_lambda) do
      def initialize(predicate_iri:, value_lambda:, if_lambda: nil)
        super(predicate_iri, value_lambda, if_lambda)
      end
    end

    OnSubjectBlock = Struct.new(:subject_lambda, :predicates) do
      def initialize(subject_lambda:, predicates:)
        super(subject_lambda, predicates)
      end
    end

    # PLAN_0.2.0 Phase B — per-collection block. block_proc receives
    # an item as its block param; inside the block, `triple` records
    # a (per-item interpolated IRI, value lambda closing over item).
    # The block_proc isn't evaluated at declaration time; emission
    # re-runs it once per current-collection item.
    EachBlock = Struct.new(:collection_lambda, :block_proc) do
      def initialize(collection_lambda:, block_proc:)
        super(collection_lambda, block_proc)
      end
    end

    # Shared triple-recording between the top-level Recorder and the
    # SubRecorder used inside `on_subject` blocks. Both maintain a
    # `@predicates` array; `triple` appends to it.
    module TripleRecording
      # triple "schema:name", -> { name }
      # triple "schema:gtin", -> { gtin }, if: -> { gtin.present? }
      # triple "rdf:type",    "<urn:mm:CategoryFolder>"          # literal value
      #
      # PLAN_0.8.0 Phase B — optional block with `annotate` calls
      # attaches RDF-star annotations to the parent triple:
      #
      #   triple "schema:gtin", -> { gtin } do
      #     annotate "mm:reportedBy", -> { "urn:mm:user:#{updater_id}" }
      #     annotate "mm:reportedAt", -> { updated_at.iso8601 }
      #   end
      #
      # The parent triple emits + each annotation emits a triple
      # whose subject is the quoted-triple form of the parent.
      # Parent `if:` false skips both the parent and all
      # annotations. Update-time changes to the parent object
      # orphan the prior quoted-triple subject — that's
      # SPARQL-star referential opacity semantics (StarExts.md §3).
      def triple(iri, value_or_lambda, **opts, &block)
        annotations =
          if block
            sub = AnnotationRecorder.new
            sub.instance_eval(&block)
            sub.annotations
          else
            []
          end
        @predicates << Predicate.new(
          iri: iri,
          value_lambda: as_callable(value_or_lambda),
          if_lambda: opts[:if],
          annotations: annotations,
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

    # PLAN_0.8.0 Phase B — recorder used inside a `triple … do …
    # end` block to capture `annotate` calls.
    class AnnotationRecorder
      attr_reader :annotations

      def initialize
        @annotations = []
      end

      # annotate "mm:reportedBy", -> { user_iri }
      # annotate "mm:confidence", -> { score }, if: -> { score.present? }
      def annotate(predicate_iri, value_or_lambda, **opts)
        @annotations << Annotation.new(
          predicate_iri: predicate_iri,
          value_lambda:  as_callable_annotation(value_or_lambda),
          if_lambda:     opts[:if],
        )
      end

      private

      def as_callable_annotation(value_or_lambda)
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

    # Per-collection-item recorder for `each` blocks. The block_proc
    # is instance_exec'd against an EachItemRecorder with the item
    # passed as the block param; inside the block, `triple` pushes
    # into a buffer shared across all items in the iteration.
    class EachItemRecorder
      include TripleRecording

      def initialize(buffer)
        @predicates = buffer
      end
    end

    class Recorder
      include TripleRecording

      def initialize
        @subject_lambda = nil
        @predicates = []
        @on_subject_blocks = []
        @each_blocks = []
        @graph_iri = nil
      end

      # subject -> { "urn:mm:product:#{sku}" }
      # subject { "urn:mm:product:#{sku}" }
      def subject(callable = nil, &block)
        @subject_lambda = callable || block
      end

      # PLAN_0.5.0 — declare the named graph every triple in the
      # block emits to. One graph per `triples do…end`; `on_subject`
      # and `each` blocks inherit it. Operators wanting cross-graph
      # emissions per record use `Sparql.execute` / `bulk_insert`
      # directly. Blank-node graphs refuse at the Sparql boundary
      # (REASON_INVALID_GRAPH); other invalid IRIs surface from the
      # engine's rdf_insert path.
      #
      #   triples do
      #     graph "urn:mm:graph:bhphoto"
      #     subject -> { "urn:mm:product:#{sku}" }
      #     # ...
      #   end
      def graph(name)
        @graph_iri = name
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

      # each -> { product_specs } do |spec|
      #   triple "mm:#{spec.name.camelize(:lower)}", -> { spec.value }
      # end
      #
      # The block_proc is stored as-is; emission re-evaluates the
      # collection_lambda each save + runs the block once per item.
      def each(collection_callable, &predicates_block)
        raise ArgumentError, "each requires a predicates block" unless predicates_block
        raise ArgumentError, "each requires a collection lambda" unless collection_callable

        @each_blocks << EachBlock.new(
          collection_lambda: collection_callable,
          block_proc: predicates_block,
        )
      end

      def finalize!
        raise ArgumentError, "triples block requires `subject`" unless @subject_lambda
        Declaration.new(
          subject_lambda: @subject_lambda,
          predicates: @predicates.freeze,
          on_subject_blocks: @on_subject_blocks.freeze,
          each_blocks: @each_blocks.freeze,
          graph_iri: @graph_iri,
        ).freeze
      end
    end

    # ── N-Triples term serialization ────────────────────────────

    module TermSerializer
      XSD = "http://www.w3.org/2001/XMLSchema"

      module_function

      # Wraps a value as an N-Triples IRI: `<iri>`. Pass-through if
      # already wrapped. PLAN_0.8.0 Phase B: `Sparql::QuotedTriple`
      # markers serialise to `<< s p o >>` N-Triples-star form.
      def iri(value)
        return value.to_ntriples_star if value.is_a?(::Semantica::Sparql::QuotedTriple)
        s = value.to_s
        return s if s.start_with?("<<") && s.end_with?(">>")
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
      #   Hash         → "{...JSON...}"^^<xsd:string>  (PLAN_0.2.0 Phase C)
      #   Array        → "[...JSON...]"^^<xsd:string>  (PLAN_0.2.0 Phase C)
      #   Other        → value.to_s as literal
      #
      # Operators wanting IRI objects pass already-wrapped strings
      # (e.g. `"<urn:other>"`) — those pass through unchanged.
      #
      # JSON dispatch uses xsd:string rather than rdf:JSON so the
      # engine's existing N-Triples parser round-trips the value
      # cleanly. Operators reading back via Sparql.select can
      # `JSON.parse` the resulting literal value.
      def object(value)
        return value.to_ntriples_star if value.is_a?(::Semantica::Sparql::QuotedTriple)
        case value
        when String
          if value.start_with?("<<") && value.end_with?(">>")
            value
          elsif value.start_with?("<") && value.end_with?(">")
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
        when Hash, Array
          typed_literal(::JSON.generate(value), "#{XSD}#string")
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
