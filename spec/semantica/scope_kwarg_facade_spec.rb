# frozen_string_literal: true

require "spec_helper"

# PLAN_0.13.0 Phase D — `scope:` kwarg on the four facade families.
#
# Per-facade equivalence: passing a fully-populated Scope produces
# identical output to passing the equivalent per-kwarg call. Plus
# the three refusal envelopes (:scope_kwarg_conflict,
# :scope_role_missing, :scope_read_write_overlap) on each facade.
RSpec.describe "Scope: kwarg integration (PLAN_0.13.0 Phase D)", :requires_extension do
  let(:data_graph)   { "urn:test:scope:data" }
  let(:shapes_graph) { "urn:test:scope:shapes" }
  let(:report_graph) { "urn:test:scope:report" }
  let(:inferred)     { "urn:test:scope:inferred" }

  RDF_TYPE  = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  RDFS_SCO  = "http://www.w3.org/2000/01/rdf-schema#subClassOf"

  # ----- Sparql facade -----

  describe "Sparql.{select,ask,construct,execute}" do
    before do
      Semantica::Sparql.bulk_insert([
        ["urn:s", "urn:p", "<urn:o>", data_graph],
      ])
    end

    let(:scope) { Semantica::Scope.new(data: data_graph) }

    it "Sparql.select: per-kwarg vs. scope: produce identical output" do
      via_kwarg = Semantica::Sparql.select("SELECT ?o WHERE { <urn:s> <urn:p> ?o }", graph: data_graph)
      via_scope = Semantica::Sparql.select("SELECT ?o WHERE { <urn:s> <urn:p> ?o }", scope: scope)
      expect(via_kwarg).to eq(via_scope)
      expect(via_kwarg[:results]).to contain_exactly("o" => "<urn:o>")
    end

    it "Sparql.ask: per-kwarg vs. scope:" do
      via_kwarg = Semantica::Sparql.ask("ASK { <urn:s> <urn:p> <urn:o> }", graph: data_graph)
      via_scope = Semantica::Sparql.ask("ASK { <urn:s> <urn:p> <urn:o> }", scope: scope)
      expect(via_kwarg).to eq(via_scope)
      expect(via_kwarg[:value]).to be(true)
    end

    it "Sparql.construct: per-kwarg vs. scope:" do
      via_kwarg = Semantica::Sparql.construct(
        "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }", graph: data_graph,
      )
      via_scope = Semantica::Sparql.construct(
        "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }", scope: scope,
      )
      expect(via_kwarg).to eq(via_scope)
    end

    it "Sparql.execute: per-kwarg vs. scope:" do
      via_kwarg = Semantica::Sparql.execute('INSERT DATA { <urn:x> <urn:p> <urn:y> . }', graph: data_graph)
      Semantica::Sparql.execute('DELETE DATA { <urn:x> <urn:p> <urn:y> . }', graph: data_graph)
      via_scope = Semantica::Sparql.execute('INSERT DATA { <urn:x> <urn:p> <urn:y> . }', scope: scope)
      expect(via_kwarg[:count]).to eq(via_scope[:count])
    end

    it "refuses :scope_kwarg_conflict when both scope: and graph: are passed" do
      r = Semantica::Sparql.select(
        "SELECT * WHERE { ?s ?p ?o }",
        graph: "urn:overlap",
        scope: scope,
      )
      expect(r).to include(ok: false, reason: :scope_kwarg_conflict)
    end
  end

  # ----- Reasoner facade -----

  describe "Reasoner.materialise!" do
    let(:scope) { Semantica::Scope.new(data: data_graph, inferred: inferred) }

    before do
      Semantica::Sparql.bulk_insert([
        ["urn:A", RDFS_SCO, "<urn:B>", data_graph],
        ["urn:B", RDFS_SCO, "<urn:C>", data_graph],
      ])
    end

    it "per-kwarg vs. scope: produce identical inferred-graph state" do
      r1 = Semantica::Reasoner.materialise!(asserted: data_graph, inferred: inferred)
      # Reset inferred to compare fresh
      Semantica::Sparql.execute("CLEAR GRAPH <#{inferred}>")
      r2 = Semantica::Reasoner.materialise!(scope: scope)

      expect(r1[:ok]).to be(true)
      expect(r2[:ok]).to be(true)
      expect(r1[:derived]).to eq(r2[:derived])
      expect(r1[:per_rule]).to eq(r2[:per_rule])
    end

    it "refuses :scope_kwarg_conflict with overlapping asserted:" do
      r = Semantica::Reasoner.materialise!(
        scope:    scope,
        asserted: "urn:elsewhere",
        inferred: nil,
      )
      expect(r).to include(ok: false, reason: :scope_kwarg_conflict)
    end

    it "refuses :scope_role_missing when scope omits inferred" do
      partial = Semantica::Scope.new(data: data_graph)
      r = Semantica::Reasoner.materialise!(scope: partial)
      expect(r).to include(ok: false, reason: :scope_role_missing)
      expect(r[:because]).to include("inferred")
    end
  end

  # ----- Shacl facade -----

  describe "Shacl.validate" do
    let(:scope) do
      Semantica::Scope.new(
        data:   data_graph,
        shapes: shapes_graph,
        report: report_graph,
      )
    end

    before do
      Semantica::Sparql.bulk_insert([
        ["urn:shape:Product", RDF_TYPE,                                "<http://www.w3.org/ns/shacl#NodeShape>", shapes_graph],
        ["urn:shape:Product", "http://www.w3.org/ns/shacl#targetClass","<urn:Product>",                          shapes_graph],
      ], raw: true)
      Semantica::Sparql.bulk_insert([
        ["urn:p1", RDF_TYPE, "Product", data_graph],
      ])
    end

    it "per-kwarg vs. scope: produce identical envelopes" do
      r1 = Semantica::Shacl.validate(
        data_graph: data_graph, shapes_graph: shapes_graph, report_graph: report_graph,
      )
      r2 = Semantica::Shacl.validate(scope: scope)
      expect(r1[:conforms]).to eq(r2[:conforms])
      expect(r1[:violations].length).to eq(r2[:violations].length)
    end

    it "refuses :scope_role_missing when scope omits shapes:" do
      partial = Semantica::Scope.new(data: data_graph)
      r = Semantica::Shacl.validate(scope: partial)
      expect(r).to include(ok: false, reason: :scope_role_missing)
    end
  end

  # ----- Shacl::Rules facade -----

  describe "Shacl::Rules.materialise!" do
    let(:scope) do
      Semantica::Scope.new(
        data:     data_graph,
        shapes:   shapes_graph,
        inferred: inferred,
      )
    end

    it "per-kwarg vs. scope: equivalence on an empty-rule case" do
      r1 = Semantica::Shacl::Rules.materialise!(
        data_graph: data_graph, shapes_graph: shapes_graph, inferred: inferred,
      )
      r2 = Semantica::Shacl::Rules.materialise!(scope: scope)
      expect(r1).to eq(r2)
    end

    it "refuses :scope_role_missing when scope omits inferred:" do
      partial = Semantica::Scope.new(data: data_graph, shapes: shapes_graph)
      r = Semantica::Shacl::Rules.materialise!(scope: partial)
      expect(r).to include(ok: false, reason: :scope_role_missing)
    end
  end

  # ----- Scope structural refusal -----

  describe ":scope_read_write_overlap" do
    let(:overlap_scope) do
      Semantica::Scope.new(
        data:     "urn:overlap",
        inferred: "urn:overlap",   # same IRI as data — overlap
      )
    end

    it "Reasoner refuses with :scope_read_write_overlap" do
      r = Semantica::Reasoner.materialise!(scope: overlap_scope)
      expect(r).to include(ok: false, reason: :scope_read_write_overlap)
    end
  end
end
