# frozen_string_literal: true

require "spec_helper"

# PLAN_0.10.0 Phase A — Shacl facade skeleton.
# Phase A pins envelope shape + refusal symbols; Phase B will
# add per-constraint specs once the Core library lands.
RSpec.describe Semantica::Shacl do
  describe "module surface" do
    it "exposes the validate facade method" do
      expect(described_class).to respond_to(:validate)
    end

    it "pins the v0.10.0 Phase A reason symbols" do
      expect(described_class::REASON_INVALID_GRAPH).to                eq(:invalid_graph)
      expect(described_class::REASON_SHAPE_PARSE_ERROR).to            eq(:shape_parse_error)
      expect(described_class::REASON_UNKNOWN_CONSTRAINT_COMPONENT).to eq(:unknown_constraint_component)
      expect(described_class::REASON_CYCLE_DETECTED).to               eq(:cycle_detected)
    end

    it "exposes Constraint + ConstraintLibrary + an empty Constraints::Core" do
      expect(described_class::Constraint).to be_a(Class)
      expect(described_class::ConstraintLibrary).to be_a(Class)
      expect(described_class::Constraints::Core).to be_a(described_class::ConstraintLibrary)
      expect(described_class::Constraints::Core).to be_empty
    end
  end

  describe "Constraint value object" do
    it "is keyword-init + frozen" do
      c = described_class::Constraint.new(
        iri:        "http://www.w3.org/ns/shacl#MinCountConstraintComponent",
        name:       "sh:minCount",
        parameters: [:min_count],
        validates:  "SELECT (COUNT(?o) AS ?n) WHERE { ?focus ?path ?o } GROUP BY ?focus",
        default_message: ->(min, n) { "expected ≥ #{min}; got #{n}" },
      )
      expect(c).to be_frozen
      expect(c.iri).to include("MinCount")
    end
  end

  describe "ConstraintLibrary value object" do
    it "is composable by + and keyed by IRI" do
      c1 = described_class::Constraint.new(
        iri: "urn:mc:A", name: "A", parameters: [], validates: "ASK { }",
        default_message: ->(*) { "a" },
      )
      c2 = described_class::Constraint.new(
        iri: "urn:mc:B", name: "B", parameters: [], validates: "ASK { }",
        default_message: ->(*) { "b" },
      )
      a = described_class::ConstraintLibrary.new([c1])
      b = described_class::ConstraintLibrary.new([c2])
      combined = a + b
      expect(combined.length).to eq(2)
      expect(combined["urn:mc:A"]).to eq(c1)
      expect(combined["urn:mc:B"]).to eq(c2)
    end

    it "is frozen after construction" do
      expect(described_class::ConstraintLibrary.new([])).to be_frozen
    end
  end

  describe ".validate envelope contract" do
    it "refuses blank-node data_graph: with :invalid_graph" do
      r = described_class.validate(data_graph: "_:b", shapes_graph: "urn:s")
      expect(r).to include(ok: false, reason: :invalid_graph)
    end

    it "refuses blank-node shapes_graph: with :invalid_graph" do
      r = described_class.validate(data_graph: "urn:d", shapes_graph: "_:b")
      expect(r).to include(ok: false, reason: :invalid_graph)
    end

    it "defaults report_graph to <data_graph>:report" do
      r = described_class.validate(data_graph: "urn:d", shapes_graph: "urn:s")
      expect(r[:report_graph]).to eq("urn:d:report")
    end

    it "uses operator-supplied report_graph when set" do
      r = described_class.validate(
        data_graph:   "urn:d",
        shapes_graph: "urn:s",
        report_graph: "urn:custom-report",
      )
      expect(r[:report_graph]).to eq("urn:custom-report")
    end

    it "trivially conforms against the empty Constraints::Core (Phase A)" do
      r = described_class.validate(data_graph: "urn:d", shapes_graph: "urn:s")
      expect(r).to include(ok: true, conforms: true, violations: [])
    end
  end
end
