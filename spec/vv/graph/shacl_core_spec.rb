# frozen_string_literal: true

require "spec_helper"

# PLAN_0.10.0 Phase B — SHACL Core constraint component coverage.
#
# Each constraint component has a triggering fixture (produces a
# violation) and a clearing fixture (conforms). Plus iteration
# semantics: re-validation replaces the prior report; an unknown
# constraint component refuses with :unknown_constraint_component;
# the validation report's shape matches PLAN_0.10.0 Phase E's pin.
RSpec.describe Vv::Graph::Shacl, "SHACL Core Phase B", :requires_extension do
  let(:data_graph)   { "urn:test:shacl:data" }
  let(:shapes_graph) { "urn:test:shacl:shapes" }
  let(:report_graph) { "urn:test:shacl:report" }

  # ----- Fixture helpers -----

  # bulk_insert(raw: true) — every column is engine-N-Triples-encoded
  # already; the gem does not wrap or escape. Subjects/predicates are
  # bare IRIs (no angle brackets); objects may be bare IRIs, N-Triples
  # literals (`"foo"`, `"42"^^<xsd:int>`), or blank nodes (`_:b1`).
  # The helper strips angle brackets from objects so spec fixtures can
  # write `"<urn:foo>"` ergonomically and have it normalised.
  def insert_into(graph, triples)
    rows = triples.map do |s, p, o|
      object =
        if o.is_a?(String) && o.start_with?("<") && o.end_with?(">")
          o[1..-2]   # IRI — strip brackets for raw engine form
        else
          o          # literal / bnode / bare IRI — pass through
        end
      [s, p, object, graph]
    end
    r = Vv::Graph::Sparql.bulk_insert(rows, raw: true)
    raise "fixture insert failed: #{r.inspect}" unless r[:ok]
  end

  RDF_TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  SH       = "http://www.w3.org/ns/shacl#"

  def define_node_shape(shape_iri, target_class:, properties: [])
    triples = [
      [shape_iri, RDF_TYPE,             "<#{SH}NodeShape>"],
      [shape_iri, "#{SH}targetClass",   "<#{target_class}>"],
    ]
    properties.each_with_index do |prop, i|
      ps_iri = "#{shape_iri}/p#{i}"
      triples << [shape_iri, "#{SH}property", "<#{ps_iri}>"]
      triples << [ps_iri,    "#{SH}path",     "<#{prop[:path]}>"]
      prop[:constraints].each do |param_iri, value|
        triples << [ps_iri, param_iri, value]
      end
    end
    insert_into(shapes_graph, triples)
  end

  describe "module surface (Phase B)" do
    it "Constraints::Core ships the 12 Phase B core components" do
      ids = Vv::Graph::Shacl::Constraints::Core.map(&:name)
      expect(ids).to include(
        "sh:minCount", "sh:maxCount", "sh:datatype", "sh:nodeKind",
        "sh:class",    "sh:pattern",  "sh:minLength", "sh:maxLength",
        "sh:hasValue", "sh:in",       "sh:minInclusive", "sh:maxInclusive",
      )
    end

    it "names the SHACL Core components deferred to Phase B.1" do
      expect(Vv::Graph::Shacl::Constraints::PHASE_B_PENDING).to include(
        "#{SH}NotConstraintComponent",
        "#{SH}AndConstraintComponent",
        "#{SH}ClosedConstraintComponent",
      )
    end
  end

  # ----- Per-constraint round-trip specs -----

  describe "sh:minCount" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{ path: "urn:name", constraints: { "#{SH}minCount" => '"1"' } }],
      )
    end

    it "conforms when minCount is met" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,    "<urn:Product>"],
        ["urn:p1", "urn:name",  '"Alpha"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:ok]).to be(true)
      expect(r[:conforms]).to be(true)
      expect(r[:violations]).to be_empty
    end

    it "violates when minCount is not met" do
      insert_into data_graph, [["urn:p1", RDF_TYPE, "<urn:Product>"]]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
      expect(r[:violations].length).to eq(1)
      v = r[:violations].first
      expect(v[:focus_node]).to eq("<urn:p1>")
      expect(v[:path]).to eq("<urn:name>")
      expect(v[:source_constraint_component]).to eq("<#{SH}MinCountConstraintComponent>")
      expect(v[:message]).to include("expected at least 1")
    end
  end

  describe "sh:maxCount" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{ path: "urn:tag", constraints: { "#{SH}maxCount" => '"2"' } }],
      )
    end

    it "violates when maxCount is exceeded" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE, "<urn:Product>"],
        ["urn:p1", "urn:tag", '"a"'],
        ["urn:p1", "urn:tag", '"b"'],
        ["urn:p1", "urn:tag", '"c"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
      expect(r[:violations].first[:message]).to include("at most 2")
    end
  end

  describe "sh:datatype" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{
          path: "urn:gtin",
          constraints: { "#{SH}datatype" => "<http://www.w3.org/2001/XMLSchema#string>" },
        }],
      )
    end

    it "conforms when the datatype matches" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE, "<urn:Product>"],
        ["urn:p1", "urn:gtin", '"1234567890123"'],   # xsd:string by default
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(true)
    end

    it "violates on a wrong-typed literal" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE, "<urn:Product>"],
        ["urn:p1", "urn:gtin", '"123"^^<http://www.w3.org/2001/XMLSchema#integer>'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
      expect(r[:violations].first[:message]).to include("sh:datatype")
    end
  end

  describe "sh:pattern" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{
          path: "urn:gtin",
          constraints: { "#{SH}pattern" => '"^\\d{13}$"' },
        }],
      )
    end

    it "conforms when the regex matches" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,   "<urn:Product>"],
        ["urn:p1", "urn:gtin", '"1234567890123"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(true)
    end

    it "violates when the regex doesn't match" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,   "<urn:Product>"],
        ["urn:p1", "urn:gtin", '"abc"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
      expect(r[:violations].first[:message]).to include("sh:pattern")
    end
  end

  describe "sh:minLength + sh:maxLength" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{
          path: "urn:name",
          constraints: {
            "#{SH}minLength" => '"2"',
            "#{SH}maxLength" => '"10"',
          },
        }],
      )
    end

    it "conforms within length range" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE, "<urn:Product>"],
        ["urn:p1", "urn:name", '"Bob"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(true)
    end

    it "violates on too-short literal" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,   "<urn:Product>"],
        ["urn:p1", "urn:name", '"A"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
      messages = r[:violations].map { |v| v[:message] }
      expect(messages.any? { |m| m.include?("minLength") }).to be(true)
    end

    it "violates on too-long literal" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,   "<urn:Product>"],
        ["urn:p1", "urn:name", '"This is way too long"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
      messages = r[:violations].map { |v| v[:message] }
      expect(messages.any? { |m| m.include?("maxLength") }).to be(true)
    end
  end

  describe "sh:minInclusive + sh:maxInclusive" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{
          path: "urn:price",
          constraints: {
            "#{SH}minInclusive" => '"0"',
            "#{SH}maxInclusive" => '"1000"',
          },
        }],
      )
    end

    it "conforms inside range" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,    "<urn:Product>"],
        ["urn:p1", "urn:price", '"42"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(true)
    end

    it "violates below minInclusive" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,    "<urn:Product>"],
        ["urn:p1", "urn:price", '"-5"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
    end

    it "violates above maxInclusive" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,    "<urn:Product>"],
        ["urn:p1", "urn:price", '"9999"'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
    end
  end

  describe "sh:nodeKind" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{
          path: "urn:manufacturer",
          constraints: { "#{SH}nodeKind" => "<#{SH}IRI>" },
        }],
      )
    end

    it "conforms when the value is an IRI" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,           "<urn:Product>"],
        ["urn:p1", "urn:manufacturer", "<urn:acme>"],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(true)
    end

    it "violates when the value is a literal" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,           "<urn:Product>"],
        ["urn:p1", "urn:manufacturer", '"Acme Inc."'],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
    end
  end

  describe "sh:hasValue" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{
          path: "urn:status",
          constraints: { "#{SH}hasValue" => "<urn:active>" },
        }],
      )
    end

    it "conforms when the required value is present" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,     "<urn:Product>"],
        ["urn:p1", "urn:status", "<urn:active>"],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(true)
    end

    it "violates when the required value is absent" do
      insert_into data_graph, [
        ["urn:p1", RDF_TYPE,     "<urn:Product>"],
        ["urn:p1", "urn:status", "<urn:retired>"],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
    end
  end

  describe "sh:class" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{
          path: "urn:manufacturer",
          constraints: { "#{SH}class" => "<urn:Company>" },
        }],
      )
    end

    it "conforms when the value has the required rdf:type" do
      insert_into data_graph, [
        ["urn:p1",   RDF_TYPE,           "<urn:Product>"],
        ["urn:p1",   "urn:manufacturer", "<urn:acme>"],
        ["urn:acme", RDF_TYPE,           "<urn:Company>"],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(true)
    end

    it "violates when the value lacks the required rdf:type" do
      insert_into data_graph, [
        ["urn:p1",   RDF_TYPE,           "<urn:Product>"],
        ["urn:p1",   "urn:manufacturer", "<urn:acme>"],
      ]
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:conforms]).to be(false)
    end
  end

  # ----- Iteration / report semantics -----

  describe "validation report (Phase E shape)" do
    before do
      define_node_shape(
        "urn:shape:Product",
        target_class: "urn:Product",
        properties: [{ path: "urn:name", constraints: { "#{SH}minCount" => '"1"' } }],
      )
    end

    it "writes a sh:ValidationReport with sh:conforms + sh:result links" do
      insert_into data_graph, [["urn:p1", RDF_TYPE, "<urn:Product>"]]
      described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                               report_graph: report_graph)

      report_check = Vv::Graph::Sparql.select(
        "SELECT ?conforms WHERE { ?r <#{SH}conforms> ?conforms . ?r a <#{SH}ValidationReport> }",
        graph: report_graph,
      )
      expect(report_check[:ok]).to be(true)
      expect(report_check[:results]).not_to be_empty
      conforms_lit = report_check[:results].first["conforms"]
      expect(conforms_lit).to include("false")

      result_check = Vv::Graph::Sparql.select(
        "SELECT ?focus ?path WHERE { ?r a <#{SH}ValidationResult> . ?r <#{SH}focusNode> ?focus . ?r <#{SH}resultPath> ?path }",
        graph: report_graph,
      )
      expect(result_check[:results].length).to eq(1)
      expect(result_check[:results].first["focus"]).to eq("<urn:p1>")
    end

    it "replaces the prior report on re-validation (no additive duplication)" do
      insert_into data_graph, [["urn:p1", RDF_TYPE, "<urn:Product>"]]
      described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                               report_graph: report_graph)
      described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                               report_graph: report_graph)

      count_check = Vv::Graph::Sparql.select(
        "SELECT (COUNT(?r) AS ?n) WHERE { ?r a <#{SH}ValidationResult> }",
        graph: report_graph,
      )
      expect(count_check[:results].first["n"]).to include('"1"')
    end
  end

  describe ".validate envelope (Phase A refusals still apply)" do
    it "refuses blank-node data_graph: with :invalid_graph" do
      r = described_class.validate(data_graph: "_:bad", shapes_graph: "urn:s")
      expect(r).to include(ok: false, reason: :invalid_graph)
    end

    it "defaults report_graph: to <data_graph>:report" do
      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph)
      expect(r[:report_graph]).to eq("#{data_graph}:report")
    end
  end

  describe "unknown constraint component refusal" do
    it "refuses with :unknown_constraint_component when shape uses a PHASE_B_PENDING parameter" do
      # sh:closed is in PHASE_B_PENDING — declare it on a shape
      shape_iri = "urn:shape:WithClosed"
      ps_iri    = "urn:shape:WithClosed/p"
      insert_into shapes_graph, [
        [shape_iri, RDF_TYPE,           "<#{SH}NodeShape>"],
        [shape_iri, "#{SH}targetClass", "<urn:Product>"],
        [shape_iri, "#{SH}property",    "<#{ps_iri}>"],
        [ps_iri,    "#{SH}path",        "<urn:name>"],
        [ps_iri,    "#{SH}closed",      '"true"^^<http://www.w3.org/2001/XMLSchema#boolean>'],
      ]
      insert_into data_graph, [["urn:p1", RDF_TYPE, "<urn:Product>"]]

      r = described_class.validate(data_graph: data_graph, shapes_graph: shapes_graph,
                                   report_graph: report_graph)
      expect(r[:ok]).to be(false)
      expect(r[:reason]).to eq(:unknown_constraint_component)
      expect(r[:because]).to include("sh:closed").or include("#{SH}closed")
    end
  end
end
