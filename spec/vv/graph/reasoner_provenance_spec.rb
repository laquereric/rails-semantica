# frozen_string_literal: true

require "spec_helper"

# PLAN_0.9.0 Phase E (cut 1) — Reasoner :derivedBy provenance.
#
# Phase E ships in two cuts:
#   cut 1 (this commit): :derivedBy <rule_iri> per derived triple.
#     Idempotent (constant annotation triples dedupe via engine).
#   cut 2 (deferred): :derivedAt NOW() + :derivedFrom <<premise>>.
#     Needs FILTER NOT EXISTS guard for the timestamp idempotency
#     and explicit per-rule premise variable bookkeeping.
RSpec.describe Vv::Graph::Reasoner, "provenance Phase E", :requires_extension do
  let(:asserted) { "urn:test:prov:asserted" }
  let(:inferred) { "urn:test:prov:inferred" }

  SUBCLASS_OF    = "http://www.w3.org/2000/01/rdf-schema#subClassOf"
  RDF_TYPE_P     = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  OWL_EQ_CLASS_P = "http://www.w3.org/2002/07/owl#equivalentClass"

  def insert_data(triples)
    rows = triples.map { |s, p, o| [s, p, "<#{o}>", asserted] }
    r = Vv::Graph::Sparql.bulk_insert(rows)
    raise "fixture insert failed: #{r.inspect}" unless r[:ok]
  end

  describe "module surface" do
    it "pins the provenance predicate IRIs" do
      expect(described_class::PROV_DERIVED_BY).to   eq("urn:vv-graph:derivedBy")
      expect(described_class::PROV_DERIVED_AT).to   eq("urn:vv-graph:derivedAt")
      expect(described_class::PROV_DERIVED_FROM).to eq("urn:vv-graph:derivedFrom")
    end

    it "builds rule IRIs deterministically via .rule_iri" do
      expect(described_class.rule_iri("scm-sco"))
        .to eq("urn:vv-graph:reasoner:rule:scm-sco")
    end
  end

  describe "single-parent rule (scm-sco)" do
    before do
      insert_data [
        ["urn:A", SUBCLASS_OF, "urn:B"],
        ["urn:B", SUBCLASS_OF, "urn:C"],
      ]
    end

    it "emits the derived triple AND its :derivedBy annotation" do
      r = described_class.materialise!(asserted: asserted, inferred: inferred)
      expect(r[:ok]).to be(true)

      # The closure contains :A subClassOf :C
      derived = Vv::Graph::Sparql.ask(
        "ASK { <urn:A> <#{SUBCLASS_OF}> <urn:C> }",
        graph: inferred,
      )
      expect(derived[:value]).to be(true)

      # The derived triple carries :derivedBy <rule_iri> annotation
      prov = Vv::Graph::Sparql.select(
        <<~SPARQL,
          SELECT ?rule WHERE {
            << <urn:A> <#{SUBCLASS_OF}> <urn:C> >> <urn:vv-graph:derivedBy> ?rule
          }
        SPARQL
        graph: inferred,
      )
      expect(prov[:ok]).to be(true)
      expect(prov[:results]).to contain_exactly(
        "rule" => "<#{described_class.rule_iri("scm-sco")}>",
      )
    end
  end

  describe "multi-parent rule (scm-eqc1)" do
    before do
      insert_data [["urn:A", OWL_EQ_CLASS_P, "urn:B"]]
    end

    it "emits a :derivedBy annotation for each derived parent triple" do
      described_class.materialise!(asserted: asserted, inferred: inferred)

      # scm-eqc1 derives BOTH `:A subClassOf :B` AND `:B subClassOf :A`
      both = Vv::Graph::Sparql.select(
        <<~SPARQL,
          SELECT ?s ?o WHERE {
            ?s <#{SUBCLASS_OF}> ?o .
            << ?s <#{SUBCLASS_OF}> ?o >>
              <urn:vv-graph:derivedBy>
              <#{described_class.rule_iri("scm-eqc1")}>
          }
        SPARQL
        graph: inferred,
      )
      expect(both[:ok]).to be(true)
      pairs = both[:results].map { |row| [row["s"], row["o"]] }.sort
      expect(pairs).to eq([["<urn:A>", "<urn:B>"], ["<urn:B>", "<urn:A>"]])
    end
  end

  describe "provenance: false" do
    before do
      insert_data [
        ["urn:A", SUBCLASS_OF, "urn:B"],
        ["urn:B", SUBCLASS_OF, "urn:C"],
      ]
    end

    it "skips the annotation rewrite entirely" do
      described_class.materialise!(
        asserted: asserted, inferred: inferred, provenance: false,
      )

      # Parent triple still derived
      derived = Vv::Graph::Sparql.ask(
        "ASK { <urn:A> <#{SUBCLASS_OF}> <urn:C> }",
        graph: inferred,
      )
      expect(derived[:value]).to be(true)

      # But no :derivedBy annotation
      any_prov = Vv::Graph::Sparql.ask(
        "ASK { ?t <urn:vv-graph:derivedBy> ?r }",
        graph: inferred,
      )
      expect(any_prov[:value]).to be(false)
    end
  end

  describe "idempotency under re-materialisation" do
    before do
      insert_data [
        ["urn:A", SUBCLASS_OF, "urn:B"],
        ["urn:B", SUBCLASS_OF, "urn:C"],
      ]
    end

    it "re-running materialise! produces no net new annotation triples" do
      described_class.materialise!(asserted: asserted, inferred: inferred)
      size_after_first = Vv::Graph::Sparql.store_size(graph: inferred)[:count]

      r2 = described_class.materialise!(asserted: asserted, inferred: inferred)
      expect(r2[:derived]).to eq(0)

      size_after_second = Vv::Graph::Sparql.store_size(graph: inferred)[:count]
      expect(size_after_second).to eq(size_after_first)
    end
  end
end
