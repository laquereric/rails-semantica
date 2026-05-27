# frozen_string_literal: true

require "spec_helper"

# PLAN_0.17.0 Phase B — Sparql.explain + Sparql::Explain parser.
RSpec.describe Vv::Graph::Sparql::Explain do
  describe ".parse" do
    it "classifies SELECT" do
      out = described_class.parse("SELECT ?s WHERE { ?s a <mm:Product> }")
      expect(out[:kind]).to eq(:select)
      expect(out[:projection]).to eq(["?s"])
    end

    it "extracts BGP patterns from the WHERE block" do
      out = described_class.parse(<<~SPARQL)
        SELECT ?s ?p WHERE {
          ?s a <mm:Product> .
          ?s <mm:Product/price> ?p .
        }
      SPARQL
      patterns = out[:where][:patterns]
      expect(patterns).to include(["?s", "a", "<mm:Product>"])
      expect(patterns).to include(["?s", "<mm:Product/price>", "?p"])
    end

    it "captures FILTER expressions on the WHERE plan" do
      out = described_class.parse(<<~SPARQL)
        SELECT ?s WHERE {
          ?s a <mm:Product> .
          ?s <mm:price> ?p .
          FILTER(?p > 10)
        }
      SPARQL
      expect(out[:where][:filters]).to include({ expression: "?p > 10" })
    end

    it "captures modifiers (ORDER BY, LIMIT, OFFSET)" do
      out = described_class.parse(<<~SPARQL)
        SELECT ?s WHERE { ?s a <mm:Product> }
        ORDER BY DESC(?s) ASC(?p)
        LIMIT 10 OFFSET 20
      SPARQL
      mods = out[:modifiers]
      expect(mods[:limit]).to eq(10)
      expect(mods[:offset]).to eq(20)
      expect(mods[:order_by]).to eq([
        { var: "?s", dir: :desc },
        { var: "?p", dir: :asc }
      ])
    end

    it "classifies ASK" do
      out = described_class.parse("ASK WHERE { <urn:x> a <mm:Product> }")
      expect(out[:kind]).to eq(:ask)
    end

    it "classifies CONSTRUCT and captures template + where" do
      out = described_class.parse(<<~SPARQL)
        CONSTRUCT { ?s <mm:tier> <mm:VIP> }
        WHERE     { ?s <mm:total_orders> ?n . FILTER(?n > 100) }
      SPARQL
      expect(out[:kind]).to eq(:construct)
      expect(out[:template]).to include(["?s", "<mm:tier>", "<mm:VIP>"])
      expect(out[:where][:patterns]).to include(["?s", "<mm:total_orders>", "?n"])
      expect(out[:where][:filters]).to include({ expression: "?n > 100" })
    end

    it "classifies INSERT DATA + captures the data block" do
      out = described_class.parse("INSERT DATA { <urn:x> <urn:p> <urn:o> . }")
      expect(out[:kind]).to eq(:update)
      expect(out[:operation]).to eq(:insert_data)
      expect(out[:data]).to include(["<urn:x>", "<urn:p>", "<urn:o>"])
    end

    it "classifies DELETE DATA" do
      out = described_class.parse("DELETE DATA { <urn:x> <urn:p> <urn:o> . }")
      expect(out[:operation]).to eq(:delete_data)
    end

    it "classifies INSERT WHERE / DELETE WHERE" do
      out = described_class.parse("INSERT { ?s <urn:tag> <urn:hot> } WHERE { ?s <urn:n> ?n . FILTER(?n > 100) }")
      expect(out[:operation]).to eq(:insert_where)
      expect(out[:template]).to include(["?s", "<urn:tag>", "<urn:hot>"])
      expect(out[:where][:patterns]).to include(["?s", "<urn:n>", "?n"])

      out = described_class.parse("DELETE { ?s ?p ?o } WHERE { ?s ?p ?o }")
      expect(out[:operation]).to eq(:delete_where)
    end

    it "classifies CLEAR + captures target" do
      out = described_class.parse("CLEAR GRAPH <urn:g>")
      expect(out[:operation]).to eq(:clear)
      expect(out[:target]).to eq("<urn:g>")
    end

    it "returns :unknown kind for unparseable forms" do
      out = described_class.parse("totally not sparql")
      expect(out[:kind]).to eq(:unknown)
    end
  end

  describe "OPTIONAL / UNION / GRAPH wrappers in WHERE" do
    it "captures OPTIONAL blocks separately from BGP" do
      out = described_class.parse(<<~SPARQL)
        SELECT ?s ?n WHERE {
          ?s a <mm:Product> .
          OPTIONAL { ?s <mm:nickname> ?n }
        }
      SPARQL
      expect(out[:where][:optionals]).to be_an(Array)
      expect(out[:where][:optionals].first[:patterns]).to include(["?s", "<mm:nickname>", "?n"])
    end

    it "captures GRAPH wrappers" do
      out = described_class.parse(<<~SPARQL)
        SELECT ?s WHERE {
          GRAPH <urn:g> { ?s a <mm:Product> }
        }
      SPARQL
      expect(out[:where][:graphs]).to be_an(Array)
      expect(out[:where][:graphs].first[:iri]).to eq("<urn:g>")
    end
  end
end

RSpec.describe Vv::Graph::Sparql, "#explain" do
  it "returns the v0.17.0 envelope shape on a parseable query" do
    env = described_class.explain("SELECT ?s WHERE { ?s a <mm:Product> }")
    expect(env).to include(ok: true, estimated_rows: :unknown, from: :gem_parser)
    expect(env[:plan][:kind]).to eq(:select)
  end

  it "refuses with :sparql_parse_error when the parser can't classify" do
    env = described_class.explain("not sparql at all !!!")
    expect(env).to include(ok: false, reason: :sparql_parse_error)
  end

  it "passes through :invalid_graph refusals" do
    env = described_class.explain("SELECT ?s WHERE { ?s ?p ?o }", graph: "_:blank")
    expect(env).to include(ok: false, reason: :invalid_graph)
  end
end
