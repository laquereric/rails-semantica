# frozen_string_literal: true

require "spec_helper"

# PLAN_0.11.0 Phase B — Vv::Graph::Reasoner.materialise_incremental!
# (DRed over PLAN_0.9.0 Phase E.1's :derivedFrom annotations).
RSpec.describe Vv::Graph::Reasoner, "Phase B materialise_incremental!", :requires_extension do
  let(:asserted) { "urn:test:dred:asserted" }
  let(:inferred) { "urn:test:dred:inferred" }

  SUBCLASS_OF_DR = "http://www.w3.org/2000/01/rdf-schema#subClassOf"
  RDF_TYPE_DR    = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  def insert_asserted(triples)
    rows = triples.map { |s, p, o| [s, p, "<#{o}>", asserted] }
    r = Vv::Graph::Sparql.bulk_insert(rows)
    raise "fixture failed: #{r.inspect}" unless r[:ok]
  end

  def delete_asserted(triples)
    rows = triples.map { |s, p, o| [s, p, "<#{o}>", asserted] }
    Vv::Graph::Sparql.bulk_delete(rows)
  end

  describe "REASON_* constants" do
    it "pins the v0.11.0 Phase B reason symbols" do
      expect(described_class::REASON_CHANGESET_SCOPE_MISMATCH).to     eq(:changeset_scope_mismatch_for_reasoner)
      expect(described_class::REASON_DEPENDENCY_INDEX_UNAVAILABLE).to eq(:dependency_index_unavailable)
      expect(described_class::REASON_FULL_REBUILD_REQUIRED).to        eq(:full_rebuild_required)
      expect(described_class::REASON_NON_MONOTONIC_RULE_SET).to       eq(:non_monotonic_rule_set)
    end
  end

  describe "envelope shape" do
    before do
      insert_asserted [
        ["urn:A", SUBCLASS_OF_DR, "urn:B"],
        ["urn:B", SUBCLASS_OF_DR, "urn:C"],
      ]
      described_class.materialise!(asserted: asserted, inferred: inferred)
    end

    it "returns the v0.11.0 envelope fields" do
      cs = Vv::Graph::ChangeSet.new(scope: Vv::Graph::Scope.new(data: asserted, inferred: inferred))
      env = described_class.materialise_incremental!(
        asserted: asserted, inferred: inferred, changes: cs
      )
      expect(env).to include(
        :ok, :over_deleted, :over_deleted_via_index, :over_deleted_via_sparql,
        :rederived, :net_derived, :iterations, :fixpoint, :index_dirty
      )
      expect(env[:over_deleted_via_index]).to eq(0)
    end
  end

  describe "single-hop over-deletion (scm-sco)" do
    before do
      insert_asserted [
        ["urn:A", SUBCLASS_OF_DR, "urn:B"],
        ["urn:B", SUBCLASS_OF_DR, "urn:C"],
      ]
      described_class.materialise!(asserted: asserted, inferred: inferred)
    end

    it "retracting A subClassOf B over-deletes the derived A subClassOf C" do
      # Verify derivation exists pre-retract.
      pre = Vv::Graph::Sparql.ask("ASK { <urn:A> <#{SUBCLASS_OF_DR}> <urn:C> }", graph: inferred)
      expect(pre[:value]).to be(true)

      # Capture a change-set that retracts <urn:A subClassOf urn:B>.
      cs = Vv::Graph::ChangeSet.capture(
        scope: Vv::Graph::Scope.new(data: asserted, inferred: inferred)
      ) do
        delete_asserted [["urn:A", SUBCLASS_OF_DR, "urn:B"]]
      end

      env = described_class.materialise_incremental!(
        asserted: asserted, inferred: inferred, changes: cs
      )
      expect(env[:ok]).to be(true)
      expect(env[:over_deleted_via_sparql]).to be > 0

      # Post-retract: derived A→C should be gone.
      post = Vv::Graph::Sparql.ask("ASK { <urn:A> <#{SUBCLASS_OF_DR}> <urn:C> }", graph: inferred)
      expect(post[:value]).to be(false)
    end
  end

  describe "cax-sco (a-box over-deletion)" do
    before do
      insert_asserted [
        ["urn:A", SUBCLASS_OF_DR, "urn:B"],
        ["urn:x", RDF_TYPE_DR,    "urn:A"],
      ]
      described_class.materialise!(asserted: asserted, inferred: inferred)
    end

    it "retracting x type A over-deletes x type B (derived via cax-sco)" do
      pre = Vv::Graph::Sparql.ask("ASK { <urn:x> <#{RDF_TYPE_DR}> <urn:B> }", graph: inferred)
      expect(pre[:value]).to be(true)

      cs = Vv::Graph::ChangeSet.capture(
        scope: Vv::Graph::Scope.new(data: asserted, inferred: inferred)
      ) do
        delete_asserted [["urn:x", RDF_TYPE_DR, "urn:A"]]
      end

      env = described_class.materialise_incremental!(
        asserted: asserted, inferred: inferred, changes: cs
      )
      expect(env[:ok]).to be(true)

      post = Vv::Graph::Sparql.ask("ASK { <urn:x> <#{RDF_TYPE_DR}> <urn:B> }", graph: inferred)
      expect(post[:value]).to be(false)
    end
  end

  describe "rederive phase re-adds when a still-supported derivation exists" do
    before do
      insert_asserted [
        ["urn:A", SUBCLASS_OF_DR, "urn:B"],
        ["urn:B", SUBCLASS_OF_DR, "urn:C"],
        ["urn:A", SUBCLASS_OF_DR, "urn:C"],  # explicit
      ]
      described_class.materialise!(asserted: asserted, inferred: inferred)
    end

    it "retracting the transitive premise still leaves the explicit triple in place" do
      # Asserted triple <urn:A subClassOf urn:C> exists independently
      # of the transitive derivation through <urn:B>. The asserted
      # graph isn't touched by Phase 1 over-delete — and Phase 2
      # re-derive re-adds the inferred copy from the still-asserted
      # transitive chain.
      cs = Vv::Graph::ChangeSet.capture(
        scope: Vv::Graph::Scope.new(data: asserted, inferred: inferred)
      ) do
        delete_asserted [["urn:B", SUBCLASS_OF_DR, "urn:C"]]
      end

      env = described_class.materialise_incremental!(
        asserted: asserted, inferred: inferred, changes: cs
      )
      expect(env[:ok]).to be(true)

      # The asserted A → C survives.
      asserted_check = Vv::Graph::Sparql.ask(
        "ASK { <urn:A> <#{SUBCLASS_OF_DR}> <urn:C> }", graph: asserted
      )
      expect(asserted_check[:value]).to be(true)
    end
  end

  describe "dred! alias" do
    before do
      insert_asserted [["urn:A", SUBCLASS_OF_DR, "urn:B"]]
      described_class.materialise!(asserted: asserted, inferred: inferred)
    end

    it "delegates to materialise_incremental!" do
      cs = Vv::Graph::ChangeSet.new(scope: Vv::Graph::Scope.new(data: asserted, inferred: inferred))
      env = described_class.dred!(asserted: asserted, inferred: inferred, changes: cs)
      expect(env[:ok]).to be(true)
    end
  end

  describe ":native / :auto fall back to :sparql in this cut" do
    before do
      insert_asserted [["urn:A", SUBCLASS_OF_DR, "urn:B"]]
      described_class.materialise!(asserted: asserted, inferred: inferred)
    end

    it "flags index_dirty: true when :native is requested" do
      cs = Vv::Graph::ChangeSet.new(scope: Vv::Graph::Scope.new(data: asserted, inferred: inferred))
      env = described_class.materialise_incremental!(
        asserted: asserted, inferred: inferred,
        changes: cs, dependency_index: :native
      )
      expect(env[:ok]).to be(true)
      expect(env[:index_dirty]).to be(true)
    end

    it "flags index_dirty: false when :sparql is requested" do
      cs = Vv::Graph::ChangeSet.new(scope: Vv::Graph::Scope.new(data: asserted, inferred: inferred))
      env = described_class.materialise_incremental!(
        asserted: asserted, inferred: inferred,
        changes: cs, dependency_index: :sparql
      )
      expect(env[:ok]).to be(true)
      expect(env[:index_dirty]).to be(false)
    end
  end
end
