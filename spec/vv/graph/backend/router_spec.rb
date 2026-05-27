# frozen_string_literal: true

require "spec_helper"

# PLAN_0.16.0 Phase C — capability-aware backend router.
RSpec.describe Vv::Graph::Backend::Router do
  let(:find) { Vv::Graph::QueryIR::Find.new(type: :Product) }
  let(:ir) { [find] }

  before do
    Vv::Graph.reset_config!
    ENV.delete("VV_GRAPH_QUERY_BACKEND")
  end

  describe ".pick precedence" do
    it "Layer 1: explicit hint wins over everything" do
      Vv::Graph.config.default_query_backend = :relational
      ENV["VV_GRAPH_QUERY_BACKEND"] = "relational"
      result = described_class.pick(ir, hint: :sparql)
      expect(result).to include(ok: true, backend: :sparql)
    end

    it "Layer 2: env override wins over capability fit + default" do
      Vv::Graph.config.default_query_backend = :sparql
      ENV["VV_GRAPH_QUERY_BACKEND"] = "relational"
      result = described_class.pick(ir)
      expect(result).to include(ok: true, backend: :relational)
    end

    it "Layer 3: capability fit picks the only able backend" do
      allow(Vv::Graph::Backend::Relational).to receive(:supports?).and_return({ missing: [:owl_closure] })
      allow(Vv::Graph::Backend::Sparql).to receive(:supports?).and_return(true)
      Vv::Graph.config.default_query_backend = :relational # would lose to capability fit
      result = described_class.pick(ir)
      expect(result).to include(ok: true, backend: :sparql)
    end

    it "Layer 4: configured default wins when both backends can run it" do
      Vv::Graph.config.default_query_backend = :relational
      result = described_class.pick(ir)
      expect(result).to include(ok: true, backend: :relational)
    end

    it "default-default is :sparql when nothing else is set" do
      result = described_class.pick(ir)
      expect(result).to include(ok: true, backend: :sparql)
    end
  end

  describe "refusal envelopes" do
    it "refuses with :backend_missing_capability when neither backend supports the IR" do
      allow(Vv::Graph::Backend::Sparql).to     receive(:supports?).and_return({ missing: [:fts] })
      allow(Vv::Graph::Backend::Relational).to receive(:supports?).and_return({ missing: [:fts] })
      result = described_class.pick(ir)
      expect(result).to include(ok: false, reason: :backend_missing_capability)
      expect(result[:missing]).to include(:fts)
      expect(result[:available_backends]).to eq([:sparql, :relational])
    end

    it "refuses with :backend_missing_capability when explicit hint targets a backend that lacks the capability" do
      allow(Vv::Graph::Backend::Relational).to receive(:supports?).and_return({ missing: [:owl_closure] })
      result = described_class.pick(ir, hint: :relational)
      expect(result).to include(ok: false, reason: :backend_missing_capability)
      expect(result[:missing]).to include(:owl_closure)
      expect(result[:available_backends]).to eq([:relational])
      expect(result[:because]).to match(/hint backend/)
    end

    it "refuses with :unknown_backend when hint names a non-registered backend" do
      result = described_class.pick(ir, hint: :neo4j)
      expect(result).to include(ok: false, reason: :unknown_backend)
      expect(result[:because]).to match(/hint requested backend :neo4j/)
    end

    it "refuses with :unknown_backend when env override names a non-registered backend" do
      ENV["VV_GRAPH_QUERY_BACKEND"] = "neo4j"
      result = described_class.pick(ir)
      expect(result).to include(ok: false, reason: :unknown_backend)
      expect(result[:because]).to match(/env override/)
    end
  end

  describe "integration with QueryIR.run" do
    it "honours an :sparql hint and dispatches through the SPARQL backend" do
      allow(Vv::Graph::Backend::Sparql).to receive(:execute).and_return({ ok: true, results: [], from: :sparql })
      env = Vv::Graph::QueryIR.run(ir, backend: :sparql)
      expect(env).to include(ok: true, from: :sparql)
      expect(Vv::Graph::Backend::Sparql).to have_received(:execute)
    end

    it "honours an env override" do
      ENV["VV_GRAPH_QUERY_BACKEND"] = "relational"
      allow(Vv::Graph::Backend::Relational).to receive(:execute).and_return({ ok: true, results: [], from: :relational })
      env = Vv::Graph::QueryIR.run(ir)
      expect(env).to include(ok: true, from: :relational)
      expect(Vv::Graph::Backend::Relational).to have_received(:execute)
    end

    it "surfaces a :backend_missing_capability refusal through .run" do
      allow(Vv::Graph::Backend::Sparql).to     receive(:supports?).and_return({ missing: [:fts] })
      allow(Vv::Graph::Backend::Relational).to receive(:supports?).and_return({ missing: [:fts] })
      env = Vv::Graph::QueryIR.run(ir)
      expect(env).to include(ok: false, reason: :backend_missing_capability)
    end
  end
end
