# frozen_string_literal: true

require "spec_helper"

# PLAN_0.1.0 Phase C — Semantica::Sparql contract.
#
# Two layers:
#
#   1. Contract layer (always runs) — envelope shape, refusal
#      semantics, never-raises discipline. Exercised without a live
#      extension via the AR-not-loaded path.
#
#   2. Round-trip layer (`:requires_extension`) — actual SELECT /
#      ASK / CONSTRUCT / execute against a live sqlite-sparql binary.
#      Skipped with a build hint when the binary isn't on disk.
RSpec.describe Semantica::Sparql do
  describe "module surface" do
    it "exposes the four documented class methods" do
      expect(Semantica::Sparql).to respond_to(:select, :ask, :construct, :execute)
    end

    it "pins the v0.1.0 reason symbols" do
      expect(Semantica::Sparql::REASON_SPARQL_PARSE_ERROR).to   eq(:sparql_parse_error)
      expect(Semantica::Sparql::REASON_EXTENSION_NOT_LOADED).to eq(:extension_not_loaded)
      expect(Semantica::Sparql::REASON_AR_CONNECTION_ERROR).to  eq(:ar_connection_error)
      expect(Semantica::Sparql::REASON_UNEXPECTED_ERROR).to     eq(:unexpected_error)
    end

    it "pins the v0.3.0 reason symbol additions" do
      expect(Semantica::Sparql::REASON_SPARQL_EVAL_ERROR).to eq(:sparql_eval_error)
    end
  end

  describe "contract — envelopes never raise" do
    context "when ActiveRecord::Base is not defined" do
      before do
        hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base)
      end

      it ".select returns an :ar_connection_error refusal" do
        result = Semantica::Sparql.select("SELECT ?s WHERE { ?s ?p ?o }")
        expect(result).to include(ok: false, reason: :ar_connection_error)
        expect(result[:because]).to be_a(String).and(include("ActiveRecord::Base"))
      end

      it ".ask returns an :ar_connection_error refusal" do
        result = Semantica::Sparql.ask("ASK { ?s ?p ?o }")
        expect(result).to include(ok: false, reason: :ar_connection_error)
      end

      it ".construct returns an :ar_connection_error refusal" do
        result = Semantica::Sparql.construct("CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }")
        expect(result).to include(ok: false, reason: :ar_connection_error)
      end

      it ".execute returns an :ar_connection_error refusal" do
        result = Semantica::Sparql.execute("INSERT DATA { <urn:s> <urn:p> <urn:o> . }")
        expect(result).to include(ok: false, reason: :ar_connection_error)
      end
    end
  end

  describe "round-trip against a live extension", :requires_extension do
    it "SELECT returns an array of binding hashes" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA { <urn:mm:alice> <http://xmlns.com/foaf/0.1/name> "Alice" . }
      SPARQL

      result = Semantica::Sparql.select(<<~SPARQL)
        SELECT ?n WHERE { <urn:mm:alice> <http://xmlns.com/foaf/0.1/name> ?n }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:results]).to be_an(Array)
      expect(result[:results].first).to be_a(Hash)
    end

    it "SELECT against an empty store returns ok: true with an empty array" do
      result = Semantica::Sparql.select("SELECT ?s WHERE { ?s ?p ?o }")
      expect(result).to eq(ok: true, results: [])
    end

    it "ASK returns ok + boolean value" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA { <urn:mm:bob> <http://xmlns.com/foaf/0.1/name> "Bob" . }
      SPARQL

      yes = Semantica::Sparql.ask("ASK { <urn:mm:bob> ?p ?o }")
      no  = Semantica::Sparql.ask("ASK { <urn:mm:no-one> ?p ?o }")

      expect(yes).to eq(ok: true, value: true)
      expect(no).to  eq(ok: true, value: false)
    end

    it "CONSTRUCT returns ok + N-Triples text" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA { <urn:mm:carol> <http://xmlns.com/foaf/0.1/name> "Carol" . }
      SPARQL

      result = Semantica::Sparql.construct(<<~SPARQL)
        CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:ntriples]).to be_a(String).and(include("carol"))
    end

    it "execute INSERT DATA + DELETE DATA round-trips" do
      ins = Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA { <urn:mm:dave> <http://xmlns.com/foaf/0.1/name> "Dave" . }
      SPARQL
      expect(ins[:ok]).to be(true)
      expect(ins[:count]).to be >= 1

      ask_before = Semantica::Sparql.ask("ASK { <urn:mm:dave> ?p ?o }")
      expect(ask_before).to eq(ok: true, value: true)

      del = Semantica::Sparql.execute(<<~SPARQL)
        DELETE DATA { <urn:mm:dave> <http://xmlns.com/foaf/0.1/name> "Dave" . }
      SPARQL
      expect(del[:ok]).to be(true)
      expect(del[:count]).to eq(1)

      ask_after = Semantica::Sparql.ask("ASK { <urn:mm:dave> ?p ?o }")
      expect(ask_after).to eq(ok: true, value: false)
    end

    it "execute CLEAR ALL empties the store" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA { <urn:mm:eve> <http://xmlns.com/foaf/0.1/name> "Eve" . }
      SPARQL

      result = Semantica::Sparql.execute("CLEAR ALL")
      expect(result[:ok]).to be(true)

      after = Semantica::Sparql.select("SELECT ?s WHERE { ?s ?p ?o }")
      expect(after).to eq(ok: true, results: [])
    end

    it "SELECT with malformed SPARQL refuses without raising" do
      expect {
        @result = Semantica::Sparql.select("SELEC ?bogus WHRE { malformed }")
      }.not_to raise_error
      expect(@result[:ok]).to be(false)
      expect([:sparql_parse_error, :unexpected_error]).to include(@result[:reason])
      expect(@result[:because]).to be_a(String)
    end

    it "execute INSERT DATA still returns a positive count via the fast path" do
      # PLAN_0.3.0 Phase A regression guard — widening :count to a
      # signed delta for the arbitrary-UPDATE fallback must not
      # change the DATA-form contract.
      Semantica::Sparql.execute("CLEAR ALL")
      result = Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA { <urn:mm:p3a> <urn:p> "v" . }
      SPARQL
      expect(result[:ok]).to be(true)
      expect(result[:count]).to be >= 1
    end
  end

  describe "PLAN_0.3.0 Phase A — arbitrary SPARQL UPDATE pass-through", :requires_extension do
    before { Semantica::Sparql.execute("CLEAR ALL") }

    it "DELETE-with-WHERE removes matching triples + returns signed net delta" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA {
          <urn:mm:p1> <urn:p> "v1" .
          <urn:mm:p2> <urn:p> "v2" .
        }
      SPARQL

      result = Semantica::Sparql.execute(<<~SPARQL)
        DELETE { ?s <urn:p> ?o } WHERE { ?s <urn:p> ?o }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:count]).to eq(-2)

      after = Semantica::Sparql.select("SELECT ?s WHERE { ?s ?p ?o }")
      expect(after[:results]).to eq([])
    end

    it "INSERT-with-WHERE derives triples from existing ones" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA {
          <urn:mm:x1> <urn:type> <urn:foo> .
          <urn:mm:x2> <urn:type> <urn:foo> .
        }
      SPARQL

      result = Semantica::Sparql.execute(<<~SPARQL)
        INSERT { ?s <urn:derived> "yes" } WHERE { ?s <urn:type> <urn:foo> }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:count]).to eq(2)

      derived = Semantica::Sparql.select(
        "SELECT ?s WHERE { ?s <urn:derived> \"yes\" }",
      )
      expect(derived[:results].length).to eq(2)
    end

    it "DELETE/INSERT/WHERE mixed UPDATE returns signed net delta" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA {
          <urn:mm:mix> <urn:tag> "old" .
        }
      SPARQL

      # Net delta: -1 (delete) + 1 (insert) = 0
      result = Semantica::Sparql.execute(<<~SPARQL)
        DELETE { ?s <urn:tag> "old" }
        INSERT { ?s <urn:tag> "new" }
        WHERE  { ?s <urn:tag> "old" }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:count]).to eq(0)

      after = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:mix> <urn:tag> ?o }",
      )
      expect(after[:results].map { |r| r["o"] }).to eq(["\"new\""])
    end

    it "malformed UPDATE returns :sparql_parse_error" do
      expect {
        @result = Semantica::Sparql.execute("DELET { ?s ?p ?o } WHERE { ?s ?p ?o }")
      }.not_to raise_error
      expect(@result[:ok]).to be(false)
      expect(@result[:reason]).to eq(:sparql_parse_error)
      expect(@result[:because]).to be_a(String)
    end
  end

  describe "PLAN_0.5.0 — graph: kwarg" do
    describe "validation (no live extension required)" do
      it "blank-node graph IRIs refuse with :invalid_graph" do
        result = Semantica::Sparql.select("SELECT ?s WHERE { ?s ?p ?o }", graph: "_:bnode")
        expect(result[:ok]).to be(false)
        expect(result[:reason]).to eq(:invalid_graph)
        expect(result[:because]).to include("blank-node")
      end

      it "blank-node refusal fires for all four methods" do
        %i[select ask construct execute].each do |m|
          result = Semantica::Sparql.public_send(m, "ASK { ?s ?p ?o }", graph: "_:b0")
          expect(result[:reason]).to eq(:invalid_graph), -> { "#{m} should refuse blank-node graphs" }
        end
      end

      it "GraphScoping inserts FROM <graph> between SELECT projection and WHERE body" do
        scoped = Semantica::Sparql::GraphScoping.scope_read(
          "SELECT ?s WHERE { ?s ?p ?o }",
          "urn:mm:graph:bhphoto",
        )
        # Expected shape: SELECT ?s\nFROM <graph>\nWHERE { ?s ?p ?o }
        expect(scoped).to match(/SELECT \?s\s+FROM <urn:mm:graph:bhphoto>\s+WHERE \{/)
      end

      it "GraphScoping handles WHERE-less body (SELECT ?s { ... })" do
        scoped = Semantica::Sparql::GraphScoping.scope_read(
          "SELECT ?s { ?s ?p ?o }",
          "urn:g",
        )
        expect(scoped).to match(/SELECT \?s\s+FROM <urn:g>\s+WHERE \{/)
      end

      it "GraphScoping handles ASK { ... }" do
        scoped = Semantica::Sparql::GraphScoping.scope_read(
          "ASK { <urn:s> <urn:p> ?o }",
          "urn:g",
        )
        expect(scoped).to match(/ASK\s+FROM <urn:g>\s+WHERE \{/)
      end

      it "GraphScoping handles CONSTRUCT (skips template, anchors on body brace)" do
        scoped = Semantica::Sparql::GraphScoping.scope_read(
          "CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }",
          "urn:g",
        )
        # Template `{ ?s ?p ?o }` survives intact; FROM lands before body's WHERE.
        expect(scoped).to match(/CONSTRUCT \{ \?s \?p \?o \}\s+FROM <urn:g>\s+WHERE \{ \?s \?p \?o \}/)
      end

      it "GraphScoping is a no-op when graph is nil or empty" do
        expect(Semantica::Sparql::GraphScoping.scope_read("SELECT ?s WHERE { ?s ?p ?o }", nil))
          .to eq("SELECT ?s WHERE { ?s ?p ?o }")
        expect(Semantica::Sparql::GraphScoping.scope_read("SELECT ?s WHERE { ?s ?p ?o }", ""))
          .to eq("SELECT ?s WHERE { ?s ?p ?o }")
      end

      it "GraphScoping preserves PREFIX preamble" do
        scoped = Semantica::Sparql::GraphScoping.scope_read(
          "PREFIX foaf: <http://xmlns.com/foaf/0.1/>\nSELECT ?s WHERE { ?s foaf:name ?n }",
          "urn:g",
        )
        expect(scoped).to start_with("PREFIX foaf: <http://xmlns.com/foaf/0.1/>")
        expect(scoped).to include("FROM <urn:g>")
      end
    end

    describe "round-trip against a live extension", :requires_extension do
      before { Semantica::Sparql.execute("CLEAR ALL") }

      it "execute INSERT DATA with graph: routes to the named graph" do
        Semantica::Sparql.execute(
          "INSERT DATA { <urn:p:1> <urn:p:name> \"named\" . }",
          graph: "urn:mm:graph:bhphoto",
        )
        Semantica::Sparql.execute(
          "INSERT DATA { <urn:p:2> <urn:p:name> \"default\" . }",
        )

        bhphoto = Semantica::Sparql.select(
          "SELECT ?s WHERE { ?s <urn:p:name> ?o }",
          graph: "urn:mm:graph:bhphoto",
        )
        # Engine returns IRIs N-Triples-wrapped.
        expect(bhphoto[:results].map { |r| r["s"] }).to contain_exactly("<urn:p:1>")

        default = Semantica::Sparql.select("SELECT ?s WHERE { ?s <urn:p:name> ?o }")
        expect(default[:results].map { |r| r["s"] }).to contain_exactly("<urn:p:2>")
      end

      it "execute DELETE DATA with graph: scopes to that graph" do
        Semantica::Sparql.execute(
          "INSERT DATA { <urn:p:1> <urn:p:name> \"X\" . }",
          graph: "urn:mm:graph:bhphoto",
        )
        Semantica::Sparql.execute(
          "INSERT DATA { <urn:p:1> <urn:p:name> \"X\" . }",
        )

        Semantica::Sparql.execute(
          "DELETE DATA { <urn:p:1> <urn:p:name> \"X\" . }",
          graph: "urn:mm:graph:bhphoto",
        )

        expect(
          Semantica::Sparql.ask(
            "ASK { <urn:p:1> <urn:p:name> \"X\" }",
            graph: "urn:mm:graph:bhphoto",
          )[:value]
        ).to be(false), "named-graph triple should be gone"

        expect(
          Semantica::Sparql.ask("ASK { <urn:p:1> <urn:p:name> \"X\" }")[:value]
        ).to be(true), "default-graph triple must survive"
      end

      it "DELETE WHERE { <s> <p> ?o } with graph: only touches the named graph" do
        Semantica::Sparql.execute(
          "INSERT DATA { <urn:p:1> <urn:p:n> \"a\" . <urn:p:1> <urn:p:n> \"b\" . }",
          graph: "urn:g:bhphoto",
        )
        Semantica::Sparql.execute(
          "INSERT DATA { <urn:p:1> <urn:p:n> \"survivor\" . }",
        )

        Semantica::Sparql.execute(
          "DELETE WHERE { <urn:p:1> <urn:p:n> ?o }",
          graph: "urn:g:bhphoto",
        )

        bhphoto = Semantica::Sparql.select(
          "SELECT ?o WHERE { <urn:p:1> <urn:p:n> ?o }",
          graph: "urn:g:bhphoto",
        )
        expect(bhphoto[:results]).to be_empty

        default = Semantica::Sparql.select(
          "SELECT ?o WHERE { <urn:p:1> <urn:p:n> ?o }",
        )
        # Engine returns literals N-Triples-quoted.
        expect(default[:results].map { |r| r["o"] }).to contain_exactly('"survivor"')
      end

      it "CLEAR ALL + graph: refuses with :invalid_dsl" do
        result = Semantica::Sparql.execute("CLEAR ALL", graph: "urn:g:bhphoto")
        expect(result[:ok]).to be(false)
        expect(result[:reason]).to eq(:invalid_dsl)
        expect(result[:because]).to include("CLEAR ALL")
      end

      it "omitting graph: keeps v0.4.0 behaviour bit-for-bit" do
        Semantica::Sparql.execute(
          "INSERT DATA { <urn:plain> <urn:p> \"v\" . }",
        )
        expect(
          Semantica::Sparql.ask("ASK { <urn:plain> <urn:p> \"v\" }")[:value]
        ).to be(true)
      end
    end
  end
end
