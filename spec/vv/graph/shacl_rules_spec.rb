# frozen_string_literal: true

require "spec_helper"

# PLAN_0.12.0 Phase A — Shacl::Rules facade skeleton.
RSpec.describe Vv::Graph::Shacl::Rules do
  describe "module surface" do
    it "exposes the materialise! facade method" do
      expect(described_class).to respond_to(:materialise!)
    end

    it "pins the v0.12.0 Phase A reason symbols" do
      expect(described_class::REASON_INVALID_GRAPH).to           eq(:invalid_graph)
      expect(described_class::REASON_RULE_PARSE_ERROR).to        eq(:rule_parse_error)
      expect(described_class::REASON_UNKNOWN_RULE_TYPE).to       eq(:unknown_rule_type)
      expect(described_class::REASON_CONDITION_SHAPE_MISSING).to eq(:condition_shape_missing)
    end

    it "exposes Rule + TripleRule + SparqlRule value objects" do
      expect(described_class::Rule).to be_a(Class)
      expect(described_class::TripleRule).to be_a(Class)
      expect(described_class::SparqlRule).to be_a(Class)
      expect(described_class::TripleRule.ancestors).to include(described_class::Rule)
      expect(described_class::SparqlRule.ancestors).to include(described_class::Rule)
    end
  end

  describe "Rule base value object" do
    it "carries the iri / order / condition / deactivated / description fields" do
      r = described_class::Rule.new(
        iri: "urn:r:1", order: 2, condition: "urn:cond", deactivated: true,
        description: "test rule",
      )
      expect(r.iri).to eq("urn:r:1")
      expect(r.order).to eq(2)
      expect(r.condition).to eq("urn:cond")
      expect(r.deactivated?).to be(true)
      expect(r.description).to eq("test rule")
      expect(r).to be_frozen
    end

    it "defaults order to 0 / condition to nil / deactivated to false" do
      r = described_class::Rule.new(iri: "urn:r:1")
      expect(r.order).to eq(0)
      expect(r.condition).to be_nil
      expect(r.deactivated?).to be(false)
    end
  end

  describe "TripleRule subclass" do
    it "carries subject / predicate / object node expressions plus Rule fields" do
      r = described_class::TripleRule.new(
        iri:       "urn:r:t",
        subject:   :focus_node,
        predicate: "mm:availability",
        object:    { sparql: "IF(?n > 0, 'in_stock', 'out_of_stock')" },
        order:     1,
      )
      expect(r.subject).to   eq(:focus_node)
      expect(r.predicate).to eq("mm:availability")
      expect(r.object).to    eq(sparql: "IF(?n > 0, 'in_stock', 'out_of_stock')")
      expect(r.order).to     eq(1)
    end
  end

  describe "SparqlRule subclass" do
    it "carries a CONSTRUCT string plus Rule fields" do
      construct = "CONSTRUCT { ?f mm:tier mm:VIP } WHERE { ?f mm:orders ?n . FILTER(?n > 100) }"
      r = described_class::SparqlRule.new(iri: "urn:r:s", construct: construct, order: 2)
      expect(r.construct).to eq(construct)
      expect(r.order).to     eq(2)
    end
  end

  describe ".materialise! envelope contract" do
    it "refuses blank-node data_graph: with :invalid_graph" do
      r = described_class.materialise!(
        data_graph: "_:b", shapes_graph: "urn:s", inferred: "urn:i",
      )
      expect(r).to include(ok: false, reason: :invalid_graph)
    end

    it "refuses blank-node shapes_graph: with :invalid_graph" do
      r = described_class.materialise!(
        data_graph: "urn:d", shapes_graph: "_:b", inferred: "urn:i",
      )
      expect(r).to include(ok: false, reason: :invalid_graph)
    end

    it "refuses blank-node inferred: with :invalid_graph" do
      r = described_class.materialise!(
        data_graph: "urn:d", shapes_graph: "urn:s", inferred: "_:b",
      )
      expect(r).to include(ok: false, reason: :invalid_graph)
    end

    it "trivially fixpoints with empty rule-discovery (Phase A)" do
      r = described_class.materialise!(
        data_graph: "urn:d", shapes_graph: "urn:s", inferred: "urn:i",
      )
      expect(r).to eq(
        ok:          true,
        iterations:  0,
        rules_fired: 0,
        derived:     0,
        per_rule:    {},
        fixpoint:    true,
      )
    end
  end
end
