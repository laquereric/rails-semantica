# frozen_string_literal: true

require "securerandom"

module Vv; end

module Vv::Graph
  # PLAN_0.11.0 Phase A — `Vv::Graph::ChangeSet` value object +
  # `capture(scope:) { ... }` block API.
  #
  # The boundary object for incremental reasoning / validation
  # (PLAN_0.11.0 + PLAN_0.13.0): an operator-visible, introspectable
  # record of "what assertions did this unit of work add and
  # retract." The reasoner's DRed pass + the validator's
  # focus-node-scoped re-evaluation both consume ChangeSets.
  #
  # Usage:
  #
  #   changes = Vv::Graph::ChangeSet.capture(scope: scope) do
  #     Vv::Graph::Sparql.bulk_insert([ ["urn:s", "urn:p", "urn:o", scope.data] ])
  #     Vv::Graph::Sparql.execute("INSERT DATA { <urn:s2> <urn:p> <urn:o> . }",
  #                               graph: scope.data)
  #   end
  #
  #   changes.added      # => Array<[s, p, o, graph]>
  #   changes.retracted  # => Array<[s, p, o, graph]>
  #   changes.scope      # => the Scope passed to capture
  #
  # Phase A wire-up:
  #   - `Sparql.bulk_insert(rows)` / `bulk_delete(rows)` notify the
  #     active recorder with their row tuples.
  #   - `Sparql.execute("INSERT DATA { … }")` / `DELETE DATA` notify
  #     with parsed N-Triples bodies.
  #   - Arbitrary UPDATE forms (INSERT WHERE, DELETE WHERE, MOVE,
  #     COPY, etc.) cannot be observed without re-querying the
  #     store; **Phase A does not record them**. Operators wanting
  #     change-set capture against those forms call
  #     `ChangeSet.record_add` / `record_retract` manually inside
  #     the capture block — or upgrade to a future phase that wires
  #     deeper observation.
  #   - Storable lifecycle integration is **Phase D** (PLAN_0.11.0);
  #     Phase A keeps the bones minimal.
  #
  # Concurrency:
  #   - The active recorder lives in `Thread.current[:semantica_change_set]`.
  #   - Nested `capture` blocks raise `NestedCaptureError` — operators
  #     flatten or use the outer scope explicitly.
  #   - Across threads, each thread sees its own recorder (or none).
  #
  # Refusal contract (lives on facade methods that consume ChangeSet,
  # not on ChangeSet itself):
  #   - `:changeset_scope_mismatch` — a write inside
  #     `capture(scope: A)` targeted a graph outside A's `read_graphs`
  #     ∪ `write_graphs`. Phase A surfaces this via the
  #     `ScopeMismatch` exception raised by `record_add` / `record_retract`
  #     when the graph IRI doesn't belong to the scope.
  class ChangeSet
    class NestedCaptureError < StandardError; end
    class ScopeMismatch      < StandardError; end

    THREAD_KEY = :semantica_change_set

    attr_reader :added, :retracted, :scope, :id

    def initialize(scope:)
      @scope     = scope
      @id        = SecureRandom.uuid
      @added     = []
      @retracted = []
    end

    # The change-set's graph IRI (where `persist!` writes its RDF
    # serialisation if/when the persist path lands). Phase A
    # exposes the IRI shape; persistence itself is Phase B+.
    def graph_iri
      "urn:vv-graph:changeset:#{id}"
    end

    class << self
      # Capture every add / retract the gem's write paths perform
      # during the block, attributed to `scope:`.
      #
      # @return [ChangeSet] frozen-after-block; the returned
      #   ChangeSet's `added` / `retracted` arrays are frozen.
      def capture(scope:)
        raise NestedCaptureError, "ChangeSet.capture blocks may not nest" if active?

        recorder = new(scope: scope)
        Thread.current[THREAD_KEY] = recorder
        begin
          yield recorder
        ensure
          Thread.current[THREAD_KEY] = nil
        end
        recorder.send(:freeze_arrays!)
        recorder
      end

      # `true` while inside a `capture` block.
      def active?
        !Thread.current[THREAD_KEY].nil?
      end

      # The active recorder, or nil.
      def active
        Thread.current[THREAD_KEY]
      end

      # Notify the active recorder of an add. No-op when no
      # recorder is active. Raises ScopeMismatch when the graph
      # IRI doesn't belong to the active recorder's scope.
      def record_add(subject, predicate, object, graph = nil)
        notify(:added, subject, predicate, object, graph)
      end

      # Notify the active recorder of a retract.
      def record_retract(subject, predicate, object, graph = nil)
        notify(:retracted, subject, predicate, object, graph)
      end

      # Notify many adds in one go (used by `Sparql.bulk_insert`).
      # Each row is `[s, p, o]` or `[s, p, o, graph]`.
      def record_adds(rows)
        rows.each { |row| record_add(*row) }
      end

      def record_retracts(rows)
        rows.each { |row| record_retract(*row) }
      end

      private

      def notify(bucket, subject, predicate, object, graph)
        recorder = active
        return unless recorder

        unless scope_accepts?(recorder.scope, graph)
          raise ScopeMismatch,
                "write to graph #{graph.inspect} is outside the active ChangeSet's scope (#{recorder.scope.inspect})"
        end

        recorder.public_send(bucket) << [subject, predicate, object, graph]
      end

      def scope_accepts?(scope, graph)
        return true if scope.nil?

        # A nil graph means the default graph — accept it if the
        # scope's `data:` role is itself the default-graph stand-in,
        # which the gem doesn't currently model. For Phase A, nil
        # graphs always pass — operators using the default graph
        # for change-tracking are accepting the looseness.
        return true if graph.nil?

        # Graph IRI must belong to read OR write set. (Writes to
        # `inferred:` / `report:` during a capture are legitimate
        # — the reasoner / validator may be running inside the
        # capture block.)
        (scope.read_graphs.include?(graph) || scope.write_graphs.include?(graph))
      end
    end

    private

    def freeze_arrays!
      @added.freeze
      @retracted.freeze
      freeze
    end
  end
end
