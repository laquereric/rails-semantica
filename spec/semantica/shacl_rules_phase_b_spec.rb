# frozen_string_literal: true

require "spec_helper"

# PLAN_0.12.0 Phase B — SHACL Rules materialisation against a
# live engine. Discovery + sh:order ordering + sh:deactivated
# skip + sh:condition gating + sh:TripleRule and sh:SPARQLRule
# round-trip + unknown rule type refusal.
RSpec.describe Semantica::Shacl::Rules, "Phase B", :requires_extension do
  let(:data_graph)   { "urn:test:rules:data" }
  let(:shapes_graph) { "urn:test:rules:shapes" }
  let(:inferred)     { "urn:test:rules:inferred" }

  RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  SH       = "http://www.w3.org/ns/shacl#"

  def insert_into(graph, triples)
    rows = triples.map do |s, p, o|
      object =
        if o.is_a?(String) && o.start_with?("<") && o.end_with?(">")
          o[1..-2]
        else
          o
        end
      [s, p, object, graph]
    end
    r = Semantica::Sparql.bulk_insert(rows, raw: true)
    raise "fixture insert failed: #{r.inspect}" unless r[:ok]
  end

  def inferred_triples(predicate:)
    r = Semantica::Sparql.select(
      "SELECT ?s ?o WHERE { ?s <#{predicate}> ?o }",
      graph: inferred,
    )
    r[:ok] ? r[:results].map { |row| [row["s"], "<#{predicate}>", row["o"]] } : []
  end

  describe "sh:TripleRule" do
    before do
      # Shape with one TripleRule:
      #   parent shape targets urn:Product
      #   rule: <focus> :computed "active"
      insert_into shapes_graph, [
        ["urn:shape:Product", RDF_TYPE,            "<#{SH}NodeShape>"],
        ["urn:shape:Product", "#{SH}targetClass",  "<urn:Product>"],
        ["urn:shape:Product", "#{SH}rule",         "<urn:rule:set-active>"],
        ["urn:rule:set-active", RDF_TYPE,          "<#{SH}TripleRule>"],
        ["urn:rule:set-active", "#{SH}subject",    "<#{SH}this>"],
        ["urn:rule:set-active", "#{SH}predicate",  "<urn:mm:status>"],
        ["urn:rule:set-active", "#{SH}object",     '"active"'],
      ]
    end

    it "fires once per focus node + writes the derived triple to inferred" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE, "<urn:Product>"],
        ["urn:p2", RDF_TYPE, "<urn:Product>"],
      ]
      r = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r[:ok]).to be(true)
      expect(r[:derived]).to eq(2)
      expect(r[:per_rule]["urn:rule:set-active"]).to eq(2)
      triples = inferred_triples(predicate: "urn:mm:status")
      expect(triples.map { |s, _, o| [s, o] }).to contain_exactly(
        ["<urn:p1>", '"active"'],
        ["<urn:p2>", '"active"'],
      )
    end

    it "is idempotent — second materialise! is a no-op" do
      insert_into data_graph, [["urn:p1", RDF_TYPE, "<urn:Product>"]]
      described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      r2 = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r2[:derived]).to eq(0)
      expect(r2[:fixpoint]).to be(true)
    end
  end

  describe "sh:SPARQLRule" do
    before do
      # CONSTRUCT-based rule: derive :tier mm:VIP for products with > 100 orders
      construct = 'CONSTRUCT { ?this <urn:mm:tier> <urn:mm:VIP> } ' \
                  'WHERE     { ?this <urn:mm:orders> ?n . FILTER(?n > 100) }'
      insert_into shapes_graph, [
        ["urn:shape:Product", RDF_TYPE,           "<#{SH}NodeShape>"],
        ["urn:shape:Product", "#{SH}targetClass", "<urn:Product>"],
        ["urn:shape:Product", "#{SH}rule",        "<urn:rule:vip>"],
        ["urn:rule:vip",      RDF_TYPE,           "<#{SH}SPARQLRule>"],
        ["urn:rule:vip",      "#{SH}construct",   "\"#{construct}\""],
      ]
    end

    it "fires when the WHERE clause matches the focus" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE, "<urn:Product>"],
        ["urn:p1", "urn:mm:orders", "\"150\"^^<http://www.w3.org/2001/XMLSchema#integer>"],
        ["urn:p2", RDF_TYPE, "<urn:Product>"],
        ["urn:p2", "urn:mm:orders", "\"5\"^^<http://www.w3.org/2001/XMLSchema#integer>"],
      ]
      r = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r[:ok]).to be(true)
      expect(r[:derived]).to eq(1)
      triples = inferred_triples(predicate: "urn:mm:tier")
      expect(triples).to contain_exactly(["<urn:p1>", "<urn:mm:tier>", "<urn:mm:VIP>"])
    end
  end

  describe "sh:order ordering" do
    before do
      insert_into shapes_graph, [
        ["urn:shape:Product", RDF_TYPE,           "<#{SH}NodeShape>"],
        ["urn:shape:Product", "#{SH}targetClass", "<urn:Product>"],
        # Rule A: order 2 — depends on rule B's output
        ["urn:shape:Product", "#{SH}rule",        "<urn:rule:A>"],
        ["urn:rule:A",        RDF_TYPE,           "<#{SH}SPARQLRule>"],
        ["urn:rule:A",        "#{SH}order",       "\"2\"^^<http://www.w3.org/2001/XMLSchema#integer>"],
        ["urn:rule:A",        "#{SH}construct",
          '"CONSTRUCT { ?this <urn:final> <urn:done> } WHERE { ?this <urn:intermediate> <urn:ready> }"'],
        # Rule B: order 1 — produces intermediate
        ["urn:shape:Product", "#{SH}rule",        "<urn:rule:B>"],
        ["urn:rule:B",        RDF_TYPE,           "<#{SH}TripleRule>"],
        ["urn:rule:B",        "#{SH}order",       "\"1\"^^<http://www.w3.org/2001/XMLSchema#integer>"],
        ["urn:rule:B",        "#{SH}subject",     "<#{SH}this>"],
        ["urn:rule:B",        "#{SH}predicate",   "<urn:intermediate>"],
        ["urn:rule:B",        "#{SH}object",      "<urn:ready>"],
      ]
    end

    it "fires rule B (order 1) before rule A (order 2) reaches fixpoint with both derived" do
      insert_into data_graph, [["urn:p1", RDF_TYPE, "<urn:Product>"]]
      r = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r[:ok]).to be(true)
      expect(r[:fixpoint]).to be(true)
      expect(r[:per_rule]["urn:rule:B"]).to eq(1)
      expect(r[:per_rule]["urn:rule:A"]).to eq(1)

      final = inferred_triples(predicate: "urn:final")
      expect(final).to contain_exactly(["<urn:p1>", "<urn:final>", "<urn:done>"])
    end
  end

  describe "sh:deactivated true" do
    before do
      insert_into shapes_graph, [
        ["urn:shape:Product", RDF_TYPE,           "<#{SH}NodeShape>"],
        ["urn:shape:Product", "#{SH}targetClass", "<urn:Product>"],
        ["urn:shape:Product", "#{SH}rule",        "<urn:rule:off>"],
        ["urn:rule:off",      RDF_TYPE,           "<#{SH}TripleRule>"],
        ["urn:rule:off",      "#{SH}deactivated", "\"true\"^^<http://www.w3.org/2001/XMLSchema#boolean>"],
        ["urn:rule:off",      "#{SH}subject",     "<#{SH}this>"],
        ["urn:rule:off",      "#{SH}predicate",   "<urn:x>"],
        ["urn:rule:off",      "#{SH}object",      "<urn:y>"],
      ]
    end

    it "skips the rule entirely" do
      insert_into data_graph, [["urn:p1", RDF_TYPE, "<urn:Product>"]]
      r = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r[:derived]).to eq(0)
      expect(r[:per_rule]).to be_empty
    end
  end

  describe "sh:condition gating" do
    before do
      # Condition shape: requires urn:status = "active"
      insert_into shapes_graph, [
        ["urn:cond:active", RDF_TYPE,           "<#{SH}NodeShape>"],
        ["urn:cond:active", "#{SH}property",    "<urn:cond:active/p>"],
        ["urn:cond:active/p", "#{SH}path",      "<urn:status>"],
        ["urn:cond:active/p", "#{SH}hasValue",  '"active"'],
        # Main shape with conditional rule
        ["urn:shape:Product", RDF_TYPE,           "<#{SH}NodeShape>"],
        ["urn:shape:Product", "#{SH}targetClass", "<urn:Product>"],
        ["urn:shape:Product", "#{SH}rule",        "<urn:rule:promote>"],
        ["urn:rule:promote",  RDF_TYPE,           "<#{SH}TripleRule>"],
        ["urn:rule:promote",  "#{SH}condition",   "<urn:cond:active>"],
        ["urn:rule:promote",  "#{SH}subject",     "<#{SH}this>"],
        ["urn:rule:promote",  "#{SH}predicate",   "<urn:promoted>"],
        ["urn:rule:promote",  "#{SH}object",      '"true"'],
      ]
    end

    it "fires only for focus nodes conforming to the condition shape" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,      "<urn:Product>"],
        ["urn:p1", "urn:status",  '"active"'],
        ["urn:p2", RDF_TYPE,      "<urn:Product>"],
        ["urn:p2", "urn:status",  '"retired"'],
      ]
      r = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r[:ok]).to be(true)
      expect(r[:derived]).to eq(1)
      promoted = inferred_triples(predicate: "urn:promoted")
      expect(promoted).to contain_exactly(["<urn:p1>", "<urn:promoted>", '"true"'])
    end
  end

  describe "sh:JSRule refusal" do
    before do
      insert_into shapes_graph, [
        ["urn:shape:Product", RDF_TYPE,           "<#{SH}NodeShape>"],
        ["urn:shape:Product", "#{SH}targetClass", "<urn:Product>"],
        ["urn:shape:Product", "#{SH}rule",        "<urn:rule:js>"],
        ["urn:rule:js",       RDF_TYPE,           "<#{SH}JSRule>"],
      ]
    end

    it "refuses with :unknown_rule_type" do
      r = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r[:ok]).to be(false)
      expect(r[:reason]).to eq(:unknown_rule_type)
      expect(r[:because]).to include("JSRule")
    end
  end

  describe "empty cases" do
    it "fixpoints immediately when shapes_graph has no sh:rule attachments" do
      r = described_class.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      expect(r).to include(ok: true, derived: 0, fixpoint: true)
    end
  end
end
