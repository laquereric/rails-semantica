# frozen_string_literal: true

require "spec_helper"

# PLAN_0.13.0 Phase A — `Semantica::Scope` value object.
#
# Pins the five-role shape (data / schema / shapes / inferred /
# report) + the `additional:` Hash escape hatch + read/write
# graph partitioning + value equality + the gem-level registry.
#
# Cross-facade contract checks (`:scope_role_missing`,
# `:scope_kwarg_conflict`, `:scope_read_write_overlap`) belong on
# the facade side — Scope's own `read_write_overlap?` is the
# predicate facades consult, not the refusal envelope itself.
RSpec.describe Semantica::Scope do
  let(:full_scope) do
    described_class.new(
      data:     "urn:mm:graph:workspace_42",
      schema:   "urn:mm:graph:shared:schema",
      shapes:   "urn:semantica:shapes:product",
      inferred: "urn:mm:graph:workspace_42:inferred",
      report:   "urn:mm:graph:workspace_42:report",
    )
  end

  describe "construction" do
    it "accepts all five pinned roles + an additional Hash" do
      scope = described_class.new(
        data:       "urn:a",
        schema:     "urn:b",
        shapes:     "urn:c",
        inferred:   "urn:d",
        report:     "urn:e",
        additional: { ontology: "urn:f" },
      )
      expect(scope.data).to eq("urn:a")
      expect(scope.schema).to eq("urn:b")
      expect(scope.shapes).to eq("urn:c")
      expect(scope.inferred).to eq("urn:d")
      expect(scope.report).to eq("urn:e")
      expect(scope.additional).to eq(ontology: "urn:f")
    end

    it "requires only :data — every other role defaults to nil" do
      scope = described_class.new(data: "urn:a")
      expect(scope.data).to eq("urn:a")
      expect(scope.schema).to be_nil
      expect(scope.shapes).to be_nil
      expect(scope.inferred).to be_nil
      expect(scope.report).to be_nil
      expect(scope.additional).to eq({})
    end

    it "freezes the Scope + its additional Hash" do
      expect(full_scope).to be_frozen
      expect(full_scope.additional).to be_frozen
    end
  end

  describe "#read_graphs / #write_graphs" do
    it "partitions roles by read vs. write contribution" do
      expect(full_scope.read_graphs).to contain_exactly(
        "urn:mm:graph:workspace_42",
        "urn:mm:graph:shared:schema",
        "urn:semantica:shapes:product",
      )
      expect(full_scope.write_graphs).to contain_exactly(
        "urn:mm:graph:workspace_42:inferred",
        "urn:mm:graph:workspace_42:report",
      )
    end

    it "omits nil roles from both partitions" do
      scope = described_class.new(data: "urn:a", inferred: "urn:b")
      expect(scope.read_graphs).to contain_exactly("urn:a")
      expect(scope.write_graphs).to contain_exactly("urn:b")
    end
  end

  describe "#read_write_overlap?" do
    it "is false when read + write graphs are disjoint" do
      expect(full_scope.read_write_overlap?).to be(false)
    end

    it "is true when a read role IRI also names a write role" do
      scope = described_class.new(
        data:     "urn:overlap",
        inferred: "urn:overlap",
      )
      expect(scope.read_write_overlap?).to be(true)
    end
  end

  describe "value equality" do
    it "two Scopes constructed with the same IRIs are ==" do
      a = described_class.new(data: "urn:a", inferred: "urn:b")
      b = described_class.new(data: "urn:a", inferred: "urn:b")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "Scopes differing in any role are not ==" do
      a = described_class.new(data: "urn:a")
      b = described_class.new(data: "urn:a", schema: "urn:b")
      expect(a).not_to eq(b)
    end

    it "non-Scope objects are not ==" do
      expect(full_scope).not_to eq("urn:mm:graph:workspace_42")
    end

    it "Scopes survive as Set members by value" do
      require "set"
      a = described_class.new(data: "urn:a")
      b = described_class.new(data: "urn:a")
      set = Set.new([a, b])
      expect(set.length).to eq(1)
    end
  end

  describe ".registry" do
    before { described_class.registry.clear }
    after  { described_class.registry.clear }

    it "is empty by default" do
      expect(described_class.registry).to be_empty
    end

    it "operator-populated; iterable; preserves Set semantics (no duplicates)" do
      described_class.registry << full_scope
      described_class.registry << full_scope    # idempotent — Set dedup
      expect(described_class.registry.length).to eq(1)
    end

    it ".find_by_data returns the matching scope or nil" do
      described_class.registry << full_scope
      expect(described_class.find_by_data("urn:mm:graph:workspace_42")).to eq(full_scope)
      expect(described_class.find_by_data("urn:nope")).to be_nil
    end
  end

  describe ".from_ factory (Phase C)" do
    it "returns a degenerate Scope with that IRI as data: and other roles nil" do
      scope = described_class.from_("urn:foo")
      expect(scope.data).to eq("urn:foo")
      expect(scope.schema).to be_nil
      expect(scope.shapes).to be_nil
      expect(scope.inferred).to be_nil
      expect(scope.report).to be_nil
      expect(scope.additional).to eq({})
    end

    it "is read-graphs = {data} and write-graphs = empty" do
      scope = described_class.from_("urn:foo")
      expect(scope.read_graphs).to contain_exactly("urn:foo")
      expect(scope.write_graphs).to be_empty
    end

    it "is value-equal to an explicit Scope.new(data: iri)" do
      expect(described_class.from_("urn:foo")).to eq(described_class.new(data: "urn:foo"))
    end
  end
end
