# frozen_string_literal: true

require "spec_helper"

# PLAN_0.8.0 Phase C — bulk_insert / bulk_delete accept
# QuotedTriple markers + 3-element nested Array shorthand in
# :s / :o positions. Predicate position stays IRI-only per the
# W3C SPARQL-star grammar.
RSpec.describe "PLAN_0.8.0 Phase C — bulk_insert RDF-star rows", :requires_extension do
  describe "Hash row with QuotedTriple marker in :s" do
    it "inserts and round-trips via SELECT pattern" do
      qt = Semantica::Sparql.quoted_triple("urn:p:1", "schema:gtin", "1234567890123")
      r = Semantica::Sparql.bulk_insert([
        { s: qt, p: "mm:reportedBy", o: "<urn:user:42>" },
      ])
      expect(r).to include(ok: true, inserted: 1)

      sel = Semantica::Sparql.select(<<~SPARQL)
        SELECT ?u WHERE {
          << <urn:p:1> <schema:gtin> "1234567890123" >> <mm:reportedBy> ?u
        }
      SPARQL
      expect(sel[:results]).to contain_exactly("u" => "<urn:user:42>")
    end
  end

  describe "Hash row with nested 3-element Array shorthand in :s" do
    it "treats [s, p, o] as quoted_triple(s, p, o)" do
      r = Semantica::Sparql.bulk_insert([
        { s: ["urn:p:2", "schema:gtin", "2222222222222"],
          p: "mm:reportedAt",
          o: "2026-05-24T00:00:00Z" },
      ])
      expect(r).to include(ok: true, inserted: 1)

      ask = Semantica::Sparql.ask(<<~SPARQL)
        ASK {
          << <urn:p:2> <schema:gtin> "2222222222222" >> <mm:reportedAt> ?t
        }
      SPARQL
      expect(ask[:value]).to be(true)
    end
  end

  describe "Hash row with QuotedTriple in :o" do
    it "inserts and round-trips" do
      qt = Semantica::Sparql.quoted_triple("urn:p:3", "schema:gtin", "3333333333333")
      r = Semantica::Sparql.bulk_insert([
        { s: "urn:Watson", p: "mm:asserted", o: qt },
      ])
      expect(r).to include(ok: true, inserted: 1)

      sel = Semantica::Sparql.select(<<~SPARQL)
        SELECT ?t WHERE { <urn:Watson> <mm:asserted> ?t . FILTER(isTRIPLE(?t)) }
      SPARQL
      expect(sel[:results].length).to eq(1)
      expect(sel[:results].first["t"]).to start_with("<<")
    end
  end

  describe "graph: kwarg composes with quoted-triple shapes" do
    let(:graph_iri) { "urn:test:phase_c:graph" }

    it "scopes the inserted quoted-triple statement to the named graph" do
      qt = Semantica::Sparql.quoted_triple("urn:p:4", "schema:gtin", "4444444444444")
      r = Semantica::Sparql.bulk_insert(
        [{ s: qt, p: "mm:reportedBy", o: "<urn:user:7>", graph: graph_iri }],
      )
      expect(r).to include(ok: true, inserted: 1)

      in_graph = Semantica::Sparql.ask(
        'ASK { << <urn:p:4> <schema:gtin> "4444444444444" >> <mm:reportedBy> ?u }',
        graph: graph_iri,
      )
      expect(in_graph[:value]).to be(true)

      # Default graph remains empty for that quoted-triple subject
      default = Semantica::Sparql.ask(
        'ASK { << <urn:p:4> <schema:gtin> "4444444444444" >> <mm:reportedBy> ?u }',
      )
      expect(default[:value]).to be(false)
    end
  end

  describe "bulk_delete symmetry" do
    it "retracts a quoted-triple-subject row inserted via bulk_insert" do
      qt = Semantica::Sparql.quoted_triple("urn:p:5", "schema:gtin", "5555555555555")
      Semantica::Sparql.bulk_insert([{ s: qt, p: "mm:reportedBy", o: "<urn:user:1>" }])
      r = Semantica::Sparql.bulk_delete([{ s: qt, p: "mm:reportedBy", o: "<urn:user:1>" }])
      expect(r).to include(ok: true, deleted: 1)

      ask = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:p:5> <schema:gtin> "5555555555555" >> <mm:reportedBy> <urn:user:1> }
      SPARQL
      expect(ask[:value]).to be(false)
    end
  end

  describe "refusal envelopes" do
    it "2-element nested Array in :s raises :invalid_dsl via the bulk facade" do
      r = Semantica::Sparql.bulk_insert([
        { s: ["urn:p:6", "schema:gtin"], p: "mm:reportedBy", o: "<urn:u>" },
      ])
      expect(r).to include(ok: false, reason: :invalid_dsl)
      expect(r[:because]).to include("subject array form expects 3 elements")
    end

    it "QuotedTriple in :p refuses with :invalid_dsl (W3C SPARQL-star contract)" do
      qt = Semantica::Sparql.quoted_triple("urn:s", "urn:p", "urn:o")
      r = Semantica::Sparql.bulk_insert([
        { s: "urn:foo", p: qt, o: "<urn:bar>" },
      ])
      expect(r).to include(ok: false, reason: :invalid_dsl)
      expect(r[:because]).to include("predicate position must be an IRI")
    end
  end

  describe "raw: true row shape (operators pre-serialised)" do
    it "accepts pre-serialised `<< … >>` strings verbatim" do
      # raw: true expects engine-native form: bare IRIs for s/p/o
      # (no angle brackets), N-Triples-star strings for quoted
      # triples in s/o.
      r = Semantica::Sparql.bulk_insert([
        ['<< <urn:p:9> <schema:gtin> "9999999999999" >>',
         "mm:reportedBy",
         "urn:user:99"],
      ], raw: true)
      expect(r).to include(ok: true, inserted: 1)

      ask = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:p:9> <schema:gtin> "9999999999999" >> <mm:reportedBy> <urn:user:99> }
      SPARQL
      expect(ask[:value]).to be(true)
    end
  end
end
