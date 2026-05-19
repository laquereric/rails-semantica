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

    it "execute with an unsupported UPDATE form refuses without raising" do
      expect {
        @result = Semantica::Sparql.execute("INSERT { ?s ?p ?o } WHERE { ?s ?p ?o }")
      }.not_to raise_error
      expect(@result[:ok]).to be(false)
      expect(@result[:because]).to include("unsupported SPARQL UPDATE")
    end
  end
end
