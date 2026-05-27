# frozen_string_literal: true

require "spec_helper"

# PLAN_0.16.0 Phase A — IR → SPARQL compiler.
#
# Compiler-only tests run without the engine artifact (no
# :requires_extension tag). Round-trip tests through
# Vv::Graph::Sparql.select tag :requires_extension and skip when
# the binary isn't present.
RSpec.describe Vv::Graph::Backend::Sparql do
  before do
    Vv::Graph::Schema.reset!
  end

  describe ".capabilities" do
    it "advertises the v0.16.0 SPARQL capability map" do
      caps = described_class.capabilities
      expect(caps).to include(
        owl_closure: true,
        shacl: true,
        joins: :rdf,
        datetime_filter: true,
        fts: false,
        named_graphs: true
      )
    end

    it "is frozen" do
      expect(described_class.capabilities).to be_frozen
    end
  end

  describe ".supports?" do
    it "accepts any well-formed IR in Phase A" do
      ir = [Vv::Graph::QueryIR::Find.new(type: :Product)]
      expect(described_class.supports?(ir)).to be true
    end
  end

  describe "compilation (contract layer; no engine needed)" do
    let(:find) { Vv::Graph::QueryIR::Find.new(type: :Product) }

    def run_compile(ir)
      query = nil
      allow(Vv::Graph::Sparql).to receive(:select) do |q, **_|
        query = q
        { ok: true, results: [] }
      end
      described_class.execute(ir, scope: nil)
      query
    end

    it "Find alone emits `?s a <ClassIRI>`" do
      q = run_compile([find])
      expect(q).to match(/SELECT \?s WHERE \{ \?s a <mm:Product> \. \}/)
    end

    it "Filter eq compiles to a triple pattern + FILTER(?v = \"value\")" do
      q = run_compile([find, Vv::Graph::QueryIR::Filter.new(field: :brand, op: :eq, value: "Epson")])
      expect(q).to include('?s <mm:Product/brand> ?brand .')
      expect(q).to include('FILTER(?brand = "Epson")')
    end

    it "FilterRange (inclusive default) emits >= && <=" do
      q = run_compile([find, Vv::Graph::QueryIR::FilterRange.new(field: :price, lo: 10, hi: 100)])
      expect(q).to include('FILTER(?price >= 10 && ?price <= 100)')
    end

    it "FilterRange (inclusive: false) emits > && <" do
      q = run_compile([find, Vv::Graph::QueryIR::FilterRange.new(field: :price, lo: 10, hi: 100, inclusive: false)])
      expect(q).to include('FILTER(?price > 10 && ?price < 100)')
    end

    it "FilterIn emits FILTER(?v IN (...))" do
      q = run_compile([find, Vv::Graph::QueryIR::FilterIn.new(field: :sku, values: %w[A B])])
      expect(q).to include('FILTER(?sku IN ("A", "B"))')
    end

    it "Sort emits ORDER BY ASC(?v) / DESC(?v)" do
      q = run_compile([find, Vv::Graph::QueryIR::Sort.new(field: :name)])
      expect(q).to include("ORDER BY ASC(?name)")

      q = run_compile([find, Vv::Graph::QueryIR::Sort.new(field: :name, dir: :desc)])
      expect(q).to include("ORDER BY DESC(?name)")
    end

    it "Limit emits LIMIT N" do
      q = run_compile([find, Vv::Graph::QueryIR::Limit.new(n: 10)])
      expect(q).to include("LIMIT 10")
    end

    it "Project narrows the SELECT variable list to ?s + projected fields" do
      q = run_compile([
        find,
        Vv::Graph::QueryIR::Filter.new(field: :brand, op: :eq, value: "Epson"),
        Vv::Graph::QueryIR::Project.new(fields: [:name])
      ])
      expect(q).to match(/SELECT \?s \?name WHERE/)
      expect(q).to include('?s <mm:Product/brand> ?brand .')
    end

    it "Count emits SELECT (COUNT(?s) AS ?count) WHERE" do
      query = nil
      allow(Vv::Graph::Sparql).to receive(:select) do |q, **_|
        query = q
        { ok: true, results: [{ "count" => "5" }] }
      end
      env = described_class.execute([find, Vv::Graph::QueryIR::Count.new], scope: nil)
      expect(query).to include("SELECT (COUNT(?s) AS ?count) WHERE")
      expect(env).to include(ok: true, count: 5, from: :sparql)
    end

    it "Compare issues two SELECT queries and reports left/right/equal" do
      compare = Vv::Graph::QueryIR::Compare.new(field: :price, left: "urn:a", right: "urn:b")
      calls = []
      allow(Vv::Graph::Sparql).to receive(:select) do |q, **_|
        calls << q
        { ok: true, results: [{ "val" => calls.size == 1 ? "10" : "10" }] }
      end
      env = described_class.execute([find, compare], scope: nil)
      expect(calls.size).to eq(2)
      expect(calls.first).to include("<urn:a>")
      expect(calls.last).to include("<urn:b>")
      expect(env[:results].first).to include("left" => "10", "right" => "10", "equal" => true)
    end

    it "Schema overrides take precedence over the default <prefix><Model>/<field> shape" do
      Vv::Graph::Schema.override(model: :Product, name: :brand, iri: "mm:Product/brandName")
      q = run_compile([find, Vv::Graph::QueryIR::Filter.new(field: :brand, op: :eq, value: "Epson")])
      expect(q).to include('?s <mm:Product/brandName> ?brand .')
    end

    it "passes scope through to Vv::Graph::Sparql.select as graph:" do
      received_graph = nil
      allow(Vv::Graph::Sparql).to receive(:select) do |_q, **kw|
        received_graph = kw[:graph]
        { ok: true, results: [] }
      end
      described_class.execute([find], scope: "urn:g:catalogue")
      expect(received_graph).to eq("urn:g:catalogue")
    end

    it "stamps from: :sparql on success envelopes" do
      allow(Vv::Graph::Sparql).to receive(:select).and_return({ ok: true, results: [] })
      env = described_class.execute([find], scope: nil)
      expect(env).to include(from: :sparql)
    end

    it "passes refusal envelopes from the SPARQL facade through, with from: :sparql stamped" do
      allow(Vv::Graph::Sparql).to receive(:select).and_return(
        { ok: false, reason: :sparql_parse_error, because: "boom" }
      )
      env = described_class.execute([find], scope: nil)
      expect(env).to include(ok: false, reason: :sparql_parse_error, because: "boom", from: :sparql)
    end
  end

  describe "term serialisation" do
    it "quotes strings; bare-emits numerics; bare-emits booleans" do
      expect(described_class.send(:term, "foo")).to eq('"foo"')
      expect(described_class.send(:term, 42)).to eq("42")
      expect(described_class.send(:term, 3.14)).to eq("3.14")
      expect(described_class.send(:term, true)).to eq("true")
    end

    it "typed-literals Time as xsd:dateTime" do
      t = Time.utc(2026, 5, 27, 12, 0, 0)
      out = described_class.send(:term, t)
      expect(out).to include("2026-05-27T12:00:00Z")
      expect(out).to include("XMLSchema#dateTime")
    end

    it "typed-literals Date as xsd:date" do
      d = Date.new(2026, 5, 27)
      out = described_class.send(:term, d)
      expect(out).to include("2026-05-27")
      expect(out).to include("XMLSchema#date")
    end

    it "passes through pre-bracketed IRI strings" do
      expect(described_class.send(:term, "<urn:mm:product:1>")).to eq("<urn:mm:product:1>")
    end

    it "quotes bare prefix-form strings as literals (no PREFIX declarations emitted)" do
      expect(described_class.send(:term, "mm:Product")).to eq('"mm:Product"')
    end
  end
end
