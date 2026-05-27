# frozen_string_literal: true

require "spec_helper"

# PLAN_0.17.0 Phase A — Sparql.select(.., with_types: true) +
# Sparql::TermParser.
RSpec.describe Vv::Graph::Sparql::TermParser do
  describe ".parse_typed" do
    it "recognises IRIs" do
      out = described_class.parse_typed("<urn:mm:product:1>")
      expect(out).to include(value: "urn:mm:product:1", kind: :iri, datatype: nil, lang: nil)
    end

    it "recognises blank nodes" do
      out = described_class.parse_typed("_:b0")
      expect(out).to include(value: "_:b0", kind: :blank_node)
    end

    it "recognises plain literals" do
      out = described_class.parse_typed('"Alpha"')
      expect(out).to include(value: "Alpha", kind: :literal, datatype: nil, lang: nil)
    end

    it "recognises typed literals; captures the datatype IRI" do
      out = described_class.parse_typed('"42"^^<http://www.w3.org/2001/XMLSchema#integer>')
      expect(out).to include(
        value: "42",
        kind: :literal,
        datatype: "http://www.w3.org/2001/XMLSchema#integer"
      )
    end

    it "recognises language-tagged literals; captures the lang tag" do
      out = described_class.parse_typed('"bonjour"@fr')
      expect(out).to include(value: "bonjour", kind: :literal, datatype: nil, lang: "fr")
    end

    it "recognises BCP47 region-subtagged lang values" do
      out = described_class.parse_typed('"hello"@en-US')
      expect(out[:lang]).to eq("en-US")
    end

    it "recognises quoted triples (RDF-star) and returns the raw form" do
      raw = "<< <urn:s> <urn:p> <urn:o> >>"
      out = described_class.parse_typed(raw)
      expect(out).to include(value: raw, kind: :quoted_triple)
    end

    it "falls back to :unknown for unrecognised forms (engine quirks)" do
      out = described_class.parse_typed("weirdly-shaped-token")
      expect(out[:kind]).to eq(:unknown)
    end

    it "unescapes \\\" in literal bodies" do
      out = described_class.parse_typed('"she said \"hi\""')
      expect(out[:value]).to eq('she said "hi"')
    end
  end

  describe ".parse_plain (Backend::Sparql.unwrap_literal delegate)" do
    it "strips IRI brackets" do
      expect(described_class.parse_plain("<urn:x>")).to eq("urn:x")
    end

    it "coerces xsd:integer to Integer" do
      expect(described_class.parse_plain('"42"^^<http://www.w3.org/2001/XMLSchema#integer>')).to eq(42)
    end

    it "coerces xsd:double to Float" do
      expect(described_class.parse_plain('"3.14"^^<http://www.w3.org/2001/XMLSchema#double>')).to eq(3.14)
    end

    it "coerces xsd:boolean to Boolean" do
      expect(described_class.parse_plain('"true"^^<http://www.w3.org/2001/XMLSchema#boolean>')).to be(true)
      expect(described_class.parse_plain('"false"^^<http://www.w3.org/2001/XMLSchema#boolean>')).to be(false)
    end

    it "keeps xsd:dateTime as a string (no Time coercion)" do
      raw = '"2026-05-27T12:00:00Z"^^<http://www.w3.org/2001/XMLSchema#dateTime>'
      expect(described_class.parse_plain(raw)).to eq("2026-05-27T12:00:00Z")
    end

    it "leaves plain literals as Strings" do
      expect(described_class.parse_plain('"Alpha"')).to eq("Alpha")
    end
  end
end

# Round-trip: select(.., with_types: true) against a live store
RSpec.describe Vv::Graph::Sparql, "#select with_types:", :requires_extension do
  let(:rdf_type) { "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>" }

  before do
    described_class.execute(<<~SPARQL)
      INSERT DATA {
        <urn:wt:x> #{rdf_type} <mm:Product> .
        <urn:wt:x> <mm:Product/name>  "Alpha" .
        <urn:wt:x> <mm:Product/price> "42"^^<http://www.w3.org/2001/XMLSchema#integer> .
        <urn:wt:x> <mm:Product/note>  "bonjour"@fr .
      }
    SPARQL
  end

  it "with_types: false keeps the v0.1.0 flat-Hash shape" do
    env = described_class.select("SELECT ?n WHERE { <urn:wt:x> <mm:Product/name> ?n }")
    expect(env[:results].first["n"]).to be_a(String)
    expect(env[:results].first["n"]).to start_with('"')
  end

  it "with_types: true returns per-binding typed Hashes" do
    env = described_class.select(
      "SELECT ?n ?p WHERE { <urn:wt:x> <mm:Product/name> ?n ; <mm:Product/price> ?p }",
      with_types: true
    )
    name = env[:results].first["n"]
    price = env[:results].first["p"]
    expect(name).to include(value: "Alpha", kind: :literal, datatype: nil, lang: nil)
    expect(price).to include(
      value: "42",
      kind: :literal,
      datatype: "http://www.w3.org/2001/XMLSchema#integer"
    )
  end

  it "with_types: true captures lang tags" do
    env = described_class.select(
      "SELECT ?note WHERE { <urn:wt:x> <mm:Product/note> ?note }",
      with_types: true
    )
    note = env[:results].first["note"]
    expect(note).to include(value: "bonjour", kind: :literal, lang: "fr")
  end

  it "with_types: true classifies IRI subjects as :iri" do
    env = described_class.select(
      "SELECT ?s WHERE { ?s #{rdf_type} <mm:Product> }",
      with_types: true
    )
    s = env[:results].first["s"]
    expect(s).to include(value: "urn:wt:x", kind: :iri)
  end

  it "typed-row Hashes are frozen" do
    env = described_class.select(
      "SELECT ?n WHERE { <urn:wt:x> <mm:Product/name> ?n }",
      with_types: true
    )
    expect(env[:results].first["n"]).to be_frozen
  end
end
