# frozen_string_literal: true

require "spec_helper"

# PLAN_0.9.0 Phase E.1 — `:derivedFrom << premise >>` per-premise
# annotation on the existing `:derivedBy` Phase E (cut 1) surface.
# Prerequisite for PLAN_0.11.0 Phase B's SPARQL-driven DRed
# over-delete pass.
RSpec.describe Vv::Graph::Reasoner, "Phase E.1 derivedFrom", :requires_extension do
  let(:asserted) { "urn:test:df:asserted" }
  let(:inferred) { "urn:test:df:inferred" }

  SUBCLASS_OF_PE1 = "http://www.w3.org/2000/01/rdf-schema#subClassOf"
  RDF_TYPE_PE1    = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

  def insert(triples)
    rows = triples.map { |s, p, o| [s, p, "<#{o}>", asserted] }
    r = Vv::Graph::Sparql.bulk_insert(rows)
    raise "fixture failed: #{r.inspect}" unless r[:ok]
  end

  describe "single-premise-per-derivation rules emit derivedFrom" do
    before do
      insert [
        ["urn:A", SUBCLASS_OF_PE1, "urn:B"],
        ["urn:B", SUBCLASS_OF_PE1, "urn:C"],
      ]
    end

    it "scm-sco emits two derivedFrom annotations per derived triple (one per WHERE pattern)" do
      described_class.materialise!(asserted: asserted, inferred: inferred)

      # Derived: <urn:A> rdfs:subClassOf <urn:C>
      # Premises: <urn:A> rdfs:subClassOf <urn:B>, <urn:B> rdfs:subClassOf <urn:C>
      env = Vv::Graph::Sparql.select(<<~SPARQL, graph: inferred)
        SELECT ?ps ?pp ?po WHERE {
          << <urn:A> <#{SUBCLASS_OF_PE1}> <urn:C> >>
            <urn:vv-graph:derivedFrom>
            << ?ps ?pp ?po >>
        }
      SPARQL
      premises = env[:results].map { |r| [r["ps"], r["pp"], r["po"]] }
      expect(premises).to include(["<urn:A>", "<#{SUBCLASS_OF_PE1}>", "<urn:B>"])
      expect(premises).to include(["<urn:B>", "<#{SUBCLASS_OF_PE1}>", "<urn:C>"])
    end
  end

  describe "cax-sco (a-box propagation through subClassOf)" do
    before do
      insert [
        ["urn:A", SUBCLASS_OF_PE1, "urn:B"],
        ["urn:x", RDF_TYPE_PE1,    "urn:A"],
      ]
    end

    it "annotates <urn:x rdf:type urn:B> with both premises" do
      described_class.materialise!(asserted: asserted, inferred: inferred)

      env = Vv::Graph::Sparql.select(<<~SPARQL, graph: inferred)
        SELECT ?ps ?pp ?po WHERE {
          << <urn:x> <#{RDF_TYPE_PE1}> <urn:B> >>
            <urn:vv-graph:derivedFrom>
            << ?ps ?pp ?po >>
        }
      SPARQL
      premises = env[:results].map { |r| [r["ps"], r["pp"], r["po"]] }
      expect(premises).to include(["<urn:x>", "<#{RDF_TYPE_PE1}>", "<urn:A>"])
      expect(premises).to include(["<urn:A>", "<#{SUBCLASS_OF_PE1}>", "<urn:B>"])
    end

    it "still emits :derivedBy alongside :derivedFrom" do
      described_class.materialise!(asserted: asserted, inferred: inferred)
      env = Vv::Graph::Sparql.select(<<~SPARQL, graph: inferred)
        SELECT ?rule WHERE {
          << <urn:x> <#{RDF_TYPE_PE1}> <urn:B> >>
            <urn:vv-graph:derivedBy> ?rule
        }
      SPARQL
      rules = env[:results].map { |r| r["rule"] }
      expect(rules).to include("<#{described_class.rule_iri('cax-sco')}>")
    end
  end

  describe "provenance: false skips both annotations" do
    before do
      insert [
        ["urn:A", SUBCLASS_OF_PE1, "urn:B"],
        ["urn:B", SUBCLASS_OF_PE1, "urn:C"],
      ]
    end

    it "no derivedBy, no derivedFrom on inferred triples" do
      described_class.materialise!(asserted: asserted, inferred: inferred, provenance: false)

      derived = Vv::Graph::Sparql.ask("ASK { <urn:A> <#{SUBCLASS_OF_PE1}> <urn:C> }", graph: inferred)
      expect(derived[:value]).to be(true)

      by_count = Vv::Graph::Sparql.select(
        "SELECT ?o WHERE { << ?s ?p ?o2 >> <urn:vv-graph:derivedBy> ?o }",
        graph: inferred
      )
      expect(by_count[:results]).to be_empty

      from_count = Vv::Graph::Sparql.select(
        "SELECT ?premise WHERE { << ?s ?p ?o >> <urn:vv-graph:derivedFrom> ?premise }",
        graph: inferred
      )
      expect(from_count[:results]).to be_empty
    end
  end

  describe "idempotency — re-running emits the same set of annotations" do
    before do
      insert [
        ["urn:A", SUBCLASS_OF_PE1, "urn:B"],
        ["urn:B", SUBCLASS_OF_PE1, "urn:C"],
      ]
    end

    it "second materialise! is a no-op on the derivedFrom annotations" do
      described_class.materialise!(asserted: asserted, inferred: inferred)
      first = Vv::Graph::Sparql.store_size(graph: inferred)[:count]
      described_class.materialise!(asserted: asserted, inferred: inferred)
      second = Vv::Graph::Sparql.store_size(graph: inferred)[:count]
      expect(second).to eq(first)
    end
  end
end
