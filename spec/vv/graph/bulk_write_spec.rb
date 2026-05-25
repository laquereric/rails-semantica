# frozen_string_literal: true

require "spec_helper"

# PLAN_0.4.0 Phase A — Sparql.bulk_insert / Sparql.bulk_delete.
RSpec.describe "Vv::Graph::Sparql bulk write" do
  describe "module surface" do
    it "exposes bulk_insert and bulk_delete" do
      expect(Vv::Graph::Sparql).to respond_to(:bulk_insert, :bulk_delete)
    end
  end

  describe "empty input contract" do
    context "without a live extension" do
      before { hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base) }

      it "bulk_insert([]) returns an :ar_connection_error refusal" do
        # Empty input still goes through the with_extension belt-and-
        # braces guard, so AR-not-loaded refuses before reaching the
        # engine.
        result = Vv::Graph::Sparql.bulk_insert([])
        expect(result).to include(ok: false, reason: :ar_connection_error)
      end
    end
  end

  describe "round-trip against a live extension", :requires_extension do
    before { Vv::Graph::Sparql.execute("CLEAR ALL") }

    it "bulk_insert of N Hash-form rows inserts N quads" do
      rows = (1..50).map { |i|
        { s: "urn:mm:bulk:#{i}", p: "schema:name", o: "Name #{i}" }
      }
      result = Vv::Graph::Sparql.bulk_insert(rows)
      expect(result).to include(ok: true, inserted: 50)

      after = Vv::Graph::Sparql.select(
        "SELECT (COUNT(*) AS ?n) WHERE { ?s <schema:name> ?o }",
      )
      expect(after[:results].first["n"]).to include("50")
    end

    it "bulk_insert of Array-form rows yields identical engine state" do
      hash_rows = [
        { s: "urn:mm:p:1", p: "schema:name", o: "Alpha" },
        { s: "urn:mm:p:2", p: "schema:name", o: "Bravo" },
      ]
      array_rows = [
        ["urn:mm:p:1", "schema:name", "Alpha"],
        ["urn:mm:p:2", "schema:name", "Bravo"],
      ]

      Vv::Graph::Sparql.bulk_insert(hash_rows)
      hash_state = Vv::Graph::Sparql.select(
        "SELECT ?s ?o WHERE { ?s <schema:name> ?o }",
      )[:results].sort_by { |r| r["s"] }

      Vv::Graph::Sparql.execute("CLEAR ALL")
      Vv::Graph::Sparql.bulk_insert(array_rows)
      array_state = Vv::Graph::Sparql.select(
        "SELECT ?s ?o WHERE { ?s <schema:name> ?o }",
      )[:results].sort_by { |r| r["s"] }

      expect(array_state).to eq(hash_state)
    end

    it "empty array returns { ok: true, inserted: 0 }" do
      result = Vv::Graph::Sparql.bulk_insert([])
      expect(result).to eq(ok: true, inserted: 0)
    end

    it "duplicates within one batch collapse under set semantics" do
      rows = [
        { s: "urn:mm:dup:1", p: "schema:name", o: "Same" },
        { s: "urn:mm:dup:1", p: "schema:name", o: "Same" },
      ]
      result = Vv::Graph::Sparql.bulk_insert(rows)
      expect(result[:ok]).to be(true)
      # Engine returns newly-inserted-quads count; one of the two
      # collapses under RDF set semantics.
      expect(result[:inserted]).to eq(1)
    end

    it "bulk_delete removes exactly the curated row set" do
      Vv::Graph::Sparql.bulk_insert([
        ["urn:mm:keep:1", "schema:name", "Keep"],
        ["urn:mm:drop:1", "schema:name", "Drop"],
        ["urn:mm:drop:2", "schema:name", "Drop"],
      ])

      del = Vv::Graph::Sparql.bulk_delete([
        { s: "urn:mm:drop:1", p: "schema:name", o: "Drop" },
        { s: "urn:mm:drop:2", p: "schema:name", o: "Drop" },
      ])
      expect(del).to include(ok: true, deleted: 2)

      remaining = Vv::Graph::Sparql.select(
        "SELECT ?s WHERE { ?s <schema:name> ?o }",
      )
      expect(remaining[:results].map { |r| r["s"] }).to eq(["<urn:mm:keep:1>"])
    end

    it "graph-tagged rows route to the named graph" do
      rows = [
        ["urn:mm:gr:1", "schema:name", "Default-Graph"],
        ["urn:mm:gr:2", "schema:name", "Named-Graph", "urn:g:bhphoto"],
      ]
      Vv::Graph::Sparql.bulk_insert(rows)

      default_state = Vv::Graph::Sparql.select(
        "SELECT ?s WHERE { ?s <schema:name> ?o }",
      )[:results].map { |r| r["s"] }
      named_state = Vv::Graph::Sparql.select(
        "SELECT ?s WHERE { ?s <schema:name> ?o }",
        graph: "urn:g:bhphoto",
      )[:results].map { |r| r["s"] }

      expect(default_state).to eq(["<urn:mm:gr:1>"])
      expect(named_state).to eq(["<urn:mm:gr:2>"])
    end

    it "one malformed row aborts the whole batch; envelope carries row index" do
      Vv::Graph::Sparql.bulk_insert([
        ["urn:mm:pre:1", "schema:name", "Pre-existing"],
      ])
      before_count = Vv::Graph::Sparql.select(
        "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }",
      )[:results].first["n"]

      # Inject a bad row at index 2 — the engine validates each row;
      # an empty-string subject fails the IRI parser.
      result = Vv::Graph::Sparql.bulk_insert([
        ["urn:mm:ok:1",  "schema:name", "OK1"],
        ["urn:mm:ok:2",  "schema:name", "OK2"],
        ["",             "schema:name", "Bad"],
        ["urn:mm:ok:3",  "schema:name", "OK3"],
      ])
      expect(result[:ok]).to be(false)
      expect(result[:because]).to match(/row 2/i)

      # Store unchanged after the refused batch.
      after_count = Vv::Graph::Sparql.select(
        "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }",
      )[:results].first["n"]
      expect(after_count).to eq(before_count)
    end

    it "Hash row with :graph => nil collapses to the default-graph 3-tuple" do
      Vv::Graph::Sparql.bulk_insert([
        { s: "urn:mm:nil:1", p: "schema:name", o: "Nullable", graph: nil },
      ])
      result = Vv::Graph::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:nil:1> <schema:name> ?o }",
      )
      expect(result[:results].length).to eq(1)
    end

    it "TermSerializer type dispatch survives the bulk path (Integer, Boolean)" do
      Vv::Graph::Sparql.bulk_insert([
        ["urn:mm:ts:1", "schema:count",  42],
        ["urn:mm:ts:1", "schema:active", true],
      ])
      result = Vv::Graph::Sparql.select(
        "SELECT ?p ?o WHERE { <urn:mm:ts:1> ?p ?o }",
      )
      values = result[:results].map { |r| r["o"] }.sort
      # Engine round-trips with their typed-literal datatype suffix;
      # the integer "42" and boolean "true" round-trip cleanly.
      expect(values.any? { |v| v.include?("42") }).to be(true)
      expect(values.any? { |v| v.include?("true") }).to be(true)
    end
  end

  describe "validation" do
    before { hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base) }

    it "non-Array input refuses without raising" do
      result = Vv::Graph::Sparql.bulk_insert("not an array")
      # The validation only fires once we're past the with_extension
      # guard; without AR loaded, that's the first refusal.
      expect(result[:ok]).to be(false)
      expect([:ar_connection_error, :invalid_dsl]).to include(result[:reason])
    end
  end
end
