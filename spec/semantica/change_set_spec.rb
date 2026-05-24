# frozen_string_literal: true

require "spec_helper"

# PLAN_0.11.0 Phase A — `Semantica::ChangeSet` + capture block API.
#
# Two layers:
#   1. Contract layer (always runs) — value object shape,
#      `capture` block lifecycle, recorder thread-locality,
#      manual `record_add` / `record_retract`, ScopeMismatch.
#   2. Round-trip layer (`:requires_extension`) — actual writes
#      via Sparql.bulk_insert / bulk_delete / execute(INSERT DATA)
#      observed by the recorder.
RSpec.describe Semantica::ChangeSet do
  let(:scope) do
    Semantica::Scope.new(
      data:     "urn:mm:graph:test_workspace",
      inferred: "urn:mm:graph:test_workspace:inferred",
      report:   "urn:mm:graph:test_workspace:report",
    )
  end

  describe "value object shape" do
    it "exposes added, retracted, scope, id" do
      cs = described_class.new(scope: scope)
      expect(cs.added).to eq([])
      expect(cs.retracted).to eq([])
      expect(cs.scope).to eq(scope)
      expect(cs.id).to be_a(String)
    end

    it ".graph_iri returns the change-set's IRI shape" do
      cs = described_class.new(scope: scope)
      expect(cs.graph_iri).to eq("urn:semantica:changeset:#{cs.id}")
    end
  end

  describe ".capture block API" do
    after { Thread.current[Semantica::ChangeSet::THREAD_KEY] = nil }

    it "returns a ChangeSet with whatever was recorded inside the block" do
      cs = described_class.capture(scope: scope) do
        Semantica::ChangeSet.record_add("urn:s", "urn:p", "urn:o", scope.data)
      end
      expect(cs.added).to eq([["urn:s", "urn:p", "urn:o", scope.data]])
      expect(cs.retracted).to eq([])
    end

    it "freezes the returned ChangeSet" do
      cs = described_class.capture(scope: scope) { }
      expect(cs).to be_frozen
      expect(cs.added).to be_frozen
      expect(cs.retracted).to be_frozen
    end

    it "is .active? while the block runs; not after" do
      ran_active = nil
      described_class.capture(scope: scope) do
        ran_active = described_class.active?
      end
      expect(ran_active).to be(true)
      expect(described_class.active?).to be(false)
    end

    it "raises NestedCaptureError if a capture is started inside another" do
      expect {
        described_class.capture(scope: scope) do
          described_class.capture(scope: scope) {}
        end
      }.to raise_error(Semantica::ChangeSet::NestedCaptureError)
    end

    it "clears the recorder even if the block raises" do
      expect {
        described_class.capture(scope: scope) { raise "boom" }
      }.to raise_error("boom")
      expect(described_class.active?).to be(false)
    end
  end

  describe ".record_add / .record_retract outside a capture block" do
    it "is a no-op (no exception, no state)" do
      expect {
        described_class.record_add("urn:s", "urn:p", "urn:o")
        described_class.record_retract("urn:s", "urn:p", "urn:o")
      }.not_to raise_error
    end
  end

  describe "scope graph membership" do
    after { Thread.current[Semantica::ChangeSet::THREAD_KEY] = nil }

    it "rejects writes to a graph outside the scope's read/write set" do
      expect {
        described_class.capture(scope: scope) do
          described_class.record_add("urn:s", "urn:p", "urn:o", "urn:rogue")
        end
      }.to raise_error(Semantica::ChangeSet::ScopeMismatch, /urn:rogue/)
    end

    it "accepts writes to the scope's write_graphs (inferred / report)" do
      cs = described_class.capture(scope: scope) do
        described_class.record_add("urn:s", "urn:p", "urn:o", scope.inferred)
        described_class.record_add("urn:s", "urn:p", "urn:o", scope.report)
      end
      expect(cs.added.length).to eq(2)
    end

    it "accepts writes to the scope's read_graphs (data)" do
      cs = described_class.capture(scope: scope) do
        described_class.record_add("urn:s", "urn:p", "urn:o", scope.data)
      end
      expect(cs.added.length).to eq(1)
    end

    it "accepts nil (default-graph) writes regardless of scope" do
      cs = described_class.capture(scope: scope) do
        described_class.record_add("urn:s", "urn:p", "urn:o", nil)
      end
      expect(cs.added).to contain_exactly(["urn:s", "urn:p", "urn:o", nil])
    end
  end

  describe "Sparql write-path integration", :requires_extension do
    after { Thread.current[Semantica::ChangeSet::THREAD_KEY] = nil }

    it "captures bulk_insert rows into added" do
      cs = described_class.capture(scope: scope) do
        Semantica::Sparql.bulk_insert([
          { s: "urn:mm:p:1", p: "schema:name", o: '"Foo"', graph: scope.data },
        ])
      end
      expect(cs.added.length).to eq(1)
      expect(cs.added.first[3]).to eq(scope.data)
    end

    it "captures bulk_delete rows into retracted" do
      Semantica::Sparql.bulk_insert([
        { s: "urn:mm:p:1", p: "schema:name", o: '"Foo"', graph: scope.data },
      ])
      cs = described_class.capture(scope: scope) do
        Semantica::Sparql.bulk_delete([
          { s: "urn:mm:p:1", p: "schema:name", o: '"Foo"', graph: scope.data },
        ])
      end
      expect(cs.retracted.length).to eq(1)
    end

    it "captures INSERT DATA bodies via N-Triples parsing" do
      cs = described_class.capture(scope: scope) do
        Semantica::Sparql.execute(
          'INSERT DATA { <urn:mm:p:2> <schema:name> "Bar" . }',
          graph: scope.data,
        )
      end
      expect(cs.added.length).to eq(1)
      s, p, o, g = cs.added.first
      expect(s).to eq("urn:mm:p:2")
      expect(p).to eq("schema:name")
      expect(o).to eq('"Bar"')
      expect(g).to eq(scope.data)
    end

    it "captures DELETE DATA bodies via N-Triples parsing" do
      Semantica::Sparql.execute(
        'INSERT DATA { <urn:mm:p:3> <schema:name> "Baz" . }',
        graph: scope.data,
      )
      cs = described_class.capture(scope: scope) do
        Semantica::Sparql.execute(
          'DELETE DATA { <urn:mm:p:3> <schema:name> "Baz" . }',
          graph: scope.data,
        )
      end
      expect(cs.retracted.length).to eq(1)
    end
  end
end
