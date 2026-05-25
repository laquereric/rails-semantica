# frozen_string_literal: true

require "spec_helper"

# PLAN_0.9.0 Phase A — Reasoner facade skeleton.
# Spec pins the contract (envelope shape + refusal symbols);
# Phase B will add the per-rule materialisation specs against
# the populated Rules::OwlRl.
RSpec.describe Vv::Graph::Reasoner do
  describe "module surface" do
    it "exposes the materialise! facade method" do
      expect(described_class).to respond_to(:materialise!)
    end

    it "pins the v0.9.0 Phase A reason symbols" do
      expect(described_class::REASON_INVALID_GRAPH).to     eq(:invalid_graph)
      expect(described_class::REASON_INVALID_DSL).to       eq(:invalid_dsl)
      expect(described_class::REASON_RULE_SET_UNKNOWN).to  eq(:rule_set_unknown)
      expect(described_class::REASON_REASONER_DIVERGED).to eq(:reasoner_diverged)
    end

    it "exposes Rule + RuleSet value objects + a populated Rules::OwlRl (Phase B)" do
      expect(described_class::Rule).to be_a(Class)
      expect(described_class::RuleSet).to be_a(Class)
      expect(described_class::Rules::OwlRl).to be_a(described_class::RuleSet)
      expect(described_class::Rules::OwlRl.length).to be >= 15
    end
  end

  describe "Rule value object" do
    it "is keyword-init + frozen" do
      r = described_class::Rule.new(
        id: "scm-sco", name: "Transitive subClassOf",
        description: "If A ⊑ B and B ⊑ C then A ⊑ C.",
        sparql: "INSERT { ?a rdfs:subClassOf ?c } WHERE { ?a rdfs:subClassOf ?b . ?b rdfs:subClassOf ?c }",
      )
      expect(r).to be_frozen
      expect(r.id).to eq("scm-sco")
    end
  end

  describe "RuleSet value object" do
    it "is Enumerable and composable by +" do
      a = described_class::RuleSet.new([
        described_class::Rule.new(id: "a", name: "A", description: "a", sparql: "INSERT { } WHERE { }"),
      ])
      b = described_class::RuleSet.new([
        described_class::Rule.new(id: "b", name: "B", description: "b", sparql: "INSERT { } WHERE { }"),
      ])
      combined = a + b
      expect(combined.length).to eq(2)
      expect(combined.map(&:id)).to eq(%w[a b])
      expect(combined["b"]).not_to be_nil
    end

    it "is frozen after construction" do
      expect(described_class::RuleSet.new([])).to be_frozen
    end
  end

  describe ".materialise! envelope contract" do
    it "refuses asserted == inferred with :invalid_dsl" do
      r = described_class.materialise!(asserted: "urn:a", inferred: "urn:a")
      expect(r).to include(ok: false, reason: :invalid_dsl)
      expect(r[:because]).to include("must differ")
    end

    it "refuses blank-node asserted: with :invalid_graph" do
      r = described_class.materialise!(asserted: "_:blank", inferred: "urn:b")
      expect(r).to include(ok: false, reason: :invalid_graph)
    end

    it "refuses unknown rules: symbol with :rule_set_unknown" do
      r = described_class.materialise!(asserted: "urn:a", inferred: "urn:b", rules: :nope)
      expect(r).to include(ok: false, reason: :rule_set_unknown)
      expect(r[:because]).to include(":owl_2_rl")
    end

    it "accepts a custom RuleSet — empty set fixpoints immediately" do
      empty_set = described_class::RuleSet.new([])
      r = described_class.materialise!(asserted: "urn:a", inferred: "urn:b", rules: empty_set)
      expect(r).to include(ok: true, iterations: 0, derived: 0, fixpoint: true)
    end

    # The "non-empty rule set returns a structured envelope"
    # contract is exercised against a live engine in
    # spec/semantica/reasoner_owl_rl_spec.rb. Here we only pin
    # that the envelope shape on a no-AR-extension call is
    # the existing :ar_connection_error refusal from Sparql.execute.
  end
end
