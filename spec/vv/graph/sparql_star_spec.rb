# frozen_string_literal: true

require "spec_helper"

# PLAN_0.8.0 Phase A — SPARQL-star pass-through pin.
#
# Engine ≥ 0.7.0 round-trips quoted-triple terms across every
# read and write path. PLAN_0.8.0 Phase A is spec-only — there is
# no new gem-side production code; the existing `Vv::Graph::Sparql`
# facade simply does not mangle SPARQL-star syntax. The specs
# below pin that contract.
#
# Bindings come back as N-Triples-star strings (`"<< <s> <p> <o> >>"`),
# not the W3C SPARQL-Results-for-RDF-star structured JSON. That
# distinction matters for the Phase B/C surfaces (PLAN_0.8.0
# pinned the structured shape as "passes engine output verbatim"
# — engine 0.7.0 returns strings, so operators destructuring
# bindings parse the `<< … >>` form themselves or call the
# engine's `rdf_triple_subject` / `_predicate` / `_object` scalars
# on the SQL side).
#
# Gotcha pinned by the specs: `INSERT DATA { … }` routes through
# the engine's `rdf_load_ntriples` scalar (per `Sparql#dispatch_update`),
# which is a line-strict N-Triples parser. Quoted-triple statements
# must fit on a single line; multi-line heredocs break with
# "line jumps are not allowed in the middle of triples." Operators
# wanting multi-line ergonomics route through `INSERT { … } WHERE { … }`
# (the engine's `sparql_update` fallback), which Oxigraph parses
# tolerantly. Specs use both shapes.
RSpec.describe Vv::Graph::Sparql, "SPARQL-star pass-through (PLAN_0.8.0 Phase A)", :requires_extension do
  QUOTED_INSERT = '<< <urn:mm:product:1> <schema:gtin> "1234567890123" >> <mm:reportedBy> <urn:mm:user:42> .'

  describe ".execute INSERT DATA with a quoted-triple subject" do
    it "accepts << s p o >> in subject position via rdf_load_ntriples and reports count: 1" do
      result = Vv::Graph::Sparql.execute("INSERT DATA { #{QUOTED_INSERT} }")

      expect(result[:ok]).to be(true)
      expect(result[:count]).to be >= 1
    end

    it "accepts << s p o >> via the sparql_update fallback (INSERT WHERE) for multi-line ergonomics" do
      result = Vv::Graph::Sparql.execute(<<~SPARQL)
        INSERT { << <urn:mm:product:1> <schema:gtin> "1234567890123" >>
                   <mm:reportedBy> <urn:mm:user:42> . }
        WHERE  { }
      SPARQL

      expect(result[:ok]).to be(true)
    end
  end

  describe ".select with a quoted-triple WHERE pattern" do
    before { Vv::Graph::Sparql.execute("INSERT DATA { #{QUOTED_INSERT} }") }

    it "binds variables outside the quoted triple" do
      result = Vv::Graph::Sparql.select(<<~SPARQL)
        SELECT ?user
        WHERE { << <urn:mm:product:1> <schema:gtin> "1234567890123" >>
                  <mm:reportedBy> ?user }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:results]).to contain_exactly("user" => "<urn:mm:user:42>")
    end

    it "binds the focus triple itself via isTRIPLE filter as an N-Triples-star string" do
      result = Vv::Graph::Sparql.select(<<~SPARQL)
        SELECT ?meta ?user
        WHERE { ?meta <mm:reportedBy> ?user . FILTER(isTRIPLE(?meta)) }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:results].length).to eq(1)
      meta = result[:results].first["meta"]
      expect(meta).to start_with("<<").and(end_with(">>"))
      expect(meta).to include("<urn:mm:product:1>")
      expect(meta).to include("<schema:gtin>")
    end
  end

  describe ".ask over a quoted-triple pattern" do
    before { Vv::Graph::Sparql.execute("INSERT DATA { #{QUOTED_INSERT} }") }

    it "returns ok: true / value: true when the quoted pattern matches" do
      result = Vv::Graph::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:product:1> <schema:gtin> "1234567890123" >>
                <mm:reportedBy> <urn:mm:user:42> }
      SPARQL

      expect(result).to eq(ok: true, value: true)
    end

    it "returns ok: true / value: false when the quoted triple is not asserted" do
      result = Vv::Graph::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:product:1> <schema:gtin> "0000000000000" >>
                <mm:reportedBy> <urn:mm:user:42> }
      SPARQL

      expect(result).to eq(ok: true, value: false)
    end
  end

  describe ".construct emitting quoted-triple subjects" do
    before { Vv::Graph::Sparql.execute("INSERT DATA { #{QUOTED_INSERT} }") }

    it "round-trips N-Triples-star output through :ntriples" do
      result = Vv::Graph::Sparql.construct(<<~SPARQL)
        CONSTRUCT { << <urn:mm:product:1> <schema:gtin> "1234567890123" >>
                     <mm:reportedBy> ?u }
        WHERE     { << <urn:mm:product:1> <schema:gtin> "1234567890123" >>
                     <mm:reportedBy> ?u }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:ntriples]).to include("<< <urn:mm:product:1> <schema:gtin> \"1234567890123\" >>")
      expect(result[:ntriples]).to include("<mm:reportedBy>")
      expect(result[:ntriples]).to include("<urn:mm:user:42>")
    end
  end

  describe "SPARQL-star + named graphs compose (PLAN_0.5.0 graph: kwarg)" do
    let(:graph_iri) { "urn:mm:graph:rdfstar_compose_test" }

    it "INSERTs a quoted-triple statement into a named graph and SELECTs it back" do
      insert = Vv::Graph::Sparql.execute(
        <<~SPARQL,
          INSERT { << <urn:mm:product:9> <schema:gtin> "9999999999999" >>
                     <mm:reportedBy> <urn:mm:user:7> . }
          WHERE  { }
        SPARQL
        graph: graph_iri,
      )
      expect(insert[:ok]).to be(true)

      result = Vv::Graph::Sparql.select(
        <<~SPARQL,
          SELECT ?u WHERE { << <urn:mm:product:9> <schema:gtin> "9999999999999" >>
                              <mm:reportedBy> ?u }
        SPARQL
        graph: graph_iri,
      )
      expect(result[:ok]).to be(true)
      expect(result[:results]).to contain_exactly("u" => "<urn:mm:user:7>")
    end
  end
end
