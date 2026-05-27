# frozen_string_literal: true

require "spec_helper"

# PLAN_0.16.0 Phase A — QueryIR algebra + run entry point.
#
# Contract layer only — the IR validation rules + the dispatch
# wiring. End-to-end round-trip through SPARQL is in
# spec/vv/graph/backend/sparql_spec.rb (which tags
# :requires_extension).
RSpec.describe Vv::Graph::QueryIR do
  describe "value objects" do
    it "Find freezes on construction; scope defaults to nil" do
      n = described_class::Find.new(type: :Product)
      expect(n).to be_frozen
      expect(n.type).to eq(:Product)
      expect(n.scope).to be_nil
    end

    it "Filter freezes; carries field/op/value" do
      n = described_class::Filter.new(field: :brand, op: :eq, value: "Epson")
      expect(n).to be_frozen
      expect(n.field).to eq(:brand)
      expect(n.op).to eq(:eq)
      expect(n.value).to eq("Epson")
    end

    it "FilterRange defaults inclusive: true" do
      n = described_class::FilterRange.new(field: :price, lo: 10, hi: 100)
      expect(n.inclusive).to be true
    end

    it "FilterIn freezes its values list" do
      n = described_class::FilterIn.new(field: :sku, values: %w[A B C])
      expect(n.values).to be_frozen
      expect(n.values).to eq(%w[A B C])
    end

    it "Sort defaults dir: :asc" do
      n = described_class::Sort.new(field: :name)
      expect(n.dir).to eq(:asc)
    end

    it "Limit + Project + Count + Compare freeze" do
      expect(described_class::Limit.new(n: 10)).to be_frozen
      expect(described_class::Project.new(fields: [:name, :sku])).to be_frozen
      expect(described_class::Count.new).to be_frozen
      expect(described_class::Compare.new(field: :price, left: "urn:a", right: "urn:b")).to be_frozen
    end
  end

  describe "REASON_* constants" do
    it "pins the v0.16.0 Phase A reason symbols" do
      expect(described_class::REASON_IR_INVALID).to                 eq(:ir_invalid)
      expect(described_class::REASON_SCHEMA_FIELD_UNKNOWN).to       eq(:schema_field_unknown)
      expect(described_class::REASON_BACKEND_MISSING_CAPABILITY).to eq(:backend_missing_capability)
      expect(described_class::REASON_UNKNOWN_BACKEND).to            eq(:unknown_backend)
    end
  end

  describe ".validate" do
    let(:find) { described_class::Find.new(type: :Product) }

    it "accepts a minimal one-node program" do
      expect(described_class.validate([find])).to eq(:ok)
    end

    it "refuses empty or non-Array input with :ir_invalid" do
      env = described_class.validate([])
      expect(env).to include(ok: false, reason: :ir_invalid)
      expect(described_class.validate(nil)).to include(ok: false, reason: :ir_invalid)
    end

    it "refuses when Find is missing" do
      env = described_class.validate([described_class::Limit.new(n: 10)])
      expect(env).to include(ok: false, reason: :ir_invalid)
      expect(env[:because]).to match(/exactly one Find/)
    end

    it "refuses when Find is not first" do
      env = described_class.validate([described_class::Limit.new(n: 10), find])
      expect(env[:because]).to match(/Find must be the first/)
    end

    it "refuses when more than one Find" do
      env = described_class.validate([find, find])
      expect(env[:because]).to match(/exactly one Find/)
    end

    it "refuses two Sort nodes (multi-sort additive in v0.17.0)" do
      env = described_class.validate([
        find,
        described_class::Sort.new(field: :a),
        described_class::Sort.new(field: :b)
      ])
      expect(env[:because]).to match(/at most one Sort/)
    end

    it "refuses two Limit nodes" do
      env = described_class.validate([
        find,
        described_class::Limit.new(n: 1),
        described_class::Limit.new(n: 2)
      ])
      expect(env[:because]).to match(/at most one Limit/)
    end

    it "refuses Count + Sort/Limit/Project combinations" do
      env = described_class.validate([
        find,
        described_class::Count.new,
        described_class::Sort.new(field: :a)
      ])
      expect(env[:because]).to match(/Count is incompatible/)
    end

    it "refuses Compare + Sort/Limit/Project/Count combinations" do
      env = described_class.validate([
        find,
        described_class::Compare.new(field: :p, left: "urn:a", right: "urn:b"),
        described_class::Limit.new(n: 1)
      ])
      expect(env[:because]).to match(/Compare is incompatible/)
    end

    it "refuses non-QueryIR values in the list" do
      env = described_class.validate([find, "not a node"])
      expect(env[:because]).to match(/not a QueryIR value object/)
    end
  end

  describe ".run dispatch" do
    let(:find) { described_class::Find.new(type: :Product) }

    it "returns the IR-invalid refusal envelope when validation fails" do
      env = described_class.run([])
      expect(env).to include(ok: false, reason: :ir_invalid)
    end

    it "refuses an unknown backend with :unknown_backend" do
      env = described_class.run([find], backend: :neo4j)
      expect(env).to include(ok: false, reason: :unknown_backend)
      expect(env[:because]).to match(/not registered/)
    end

    it "defaults backend to :sparql in Phase A" do
      allow(Vv::Graph::Backend::Sparql).to receive(:execute).and_return(
        { ok: true, results: [], from: :sparql, query: "SELECT ?s WHERE { ?s a <mm:Product> . }" }
      )
      env = described_class.run([find], scope: "urn:g:catalogue")
      expect(env).to include(ok: true, from: :sparql)
      expect(Vv::Graph::Backend::Sparql).to have_received(:execute).with([find], scope: "urn:g:catalogue")
    end

    it "with_meta: true grows the envelope with plan / backend / ms" do
      allow(Vv::Graph::Backend::Sparql).to receive(:execute).and_return(
        { ok: true, results: [], from: :sparql, query: "SELECT ?s WHERE { ... }" }
      )
      env = described_class.run([find], with_meta: true)
      expect(env).to include(:plan, :backend, :ms)
      expect(env[:backend]).to eq(:sparql)
      expect(env[:ms]).to be_a(Float)
    end

    it "passes refusal envelopes from the backend through verbatim" do
      allow(Vv::Graph::Backend::Sparql).to receive(:execute).and_return(
        { ok: false, reason: :sparql_parse_error, because: "boom" }
      )
      env = described_class.run([find])
      expect(env).to include(ok: false, reason: :sparql_parse_error, because: "boom")
    end
  end
end
