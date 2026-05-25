# frozen_string_literal: true

require "spec_helper"

# PLAN_0.6.0 Phase C — Sparql.store_size envelope contract.
RSpec.describe "Vv::Graph::Sparql.store_size" do
  describe "module surface" do
    it "exposes store_size" do
      expect(Vv::Graph::Sparql).to respond_to(:store_size)
    end
  end

  describe "contract (no live extension required)" do
    before { hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base) }

    it "returns an :ar_connection_error refusal without AR loaded" do
      result = Vv::Graph::Sparql.store_size
      expect(result).to include(ok: false, reason: :ar_connection_error)
    end
  end

  describe "round-trip against a live extension", :requires_extension do
    before { Vv::Graph::Sparql.execute("CLEAR ALL") }

    it "with no kwarg counts every quad in every graph (rdf_count_all)" do
      Vv::Graph::Sparql.execute(
        %(INSERT DATA { <urn:mm:ss:1> <schema:name> "Default" . }),
      )
      Vv::Graph::Sparql.execute(
        %(INSERT DATA { <urn:mm:ss:2> <schema:name> "Named" . }),
        graph: "urn:mm:graph:ss",
      )

      result = Vv::Graph::Sparql.store_size
      expect(result[:ok]).to be(true)
      expect(result[:count]).to be >= 2
    end

    it "with explicit graph: nil counts default graph only (rdf_count)" do
      Vv::Graph::Sparql.execute(
        %(INSERT DATA { <urn:mm:ss:3> <schema:name> "Default" . }),
      )
      Vv::Graph::Sparql.execute(
        %(INSERT DATA { <urn:mm:ss:4> <schema:name> "NamedNotMe" . }),
        graph: "urn:mm:graph:ss2",
      )

      default_only = Vv::Graph::Sparql.store_size(graph: nil)
      expect(default_only[:ok]).to be(true)
      # Only the default-graph triple should be counted.
      expect(default_only[:count]).to eq(1)
    end

    it "with graph: '<iri>' counts that named graph only (rdf_count graph)" do
      Vv::Graph::Sparql.execute(
        %(INSERT DATA { <urn:mm:ss:5> <schema:name> "Default" . }),
      )
      Vv::Graph::Sparql.execute(
        %(INSERT DATA { <urn:mm:ss:6> <schema:name> "InG" . }),
        graph: "urn:mm:graph:ss3",
      )
      Vv::Graph::Sparql.execute(
        %(INSERT DATA { <urn:mm:ss:7> <schema:name> "InG" . }),
        graph: "urn:mm:graph:ss3",
      )

      named = Vv::Graph::Sparql.store_size(graph: "urn:mm:graph:ss3")
      expect(named[:ok]).to be(true)
      expect(named[:count]).to eq(2)
    end

    it "blank-node graph refuses with :invalid_graph" do
      result = Vv::Graph::Sparql.store_size(graph: "_:bnode")
      expect(result[:ok]).to be(false)
      expect(result[:reason]).to eq(:invalid_graph)
    end
  end
end
