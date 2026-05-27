# frozen_string_literal: true

require "spec_helper"

# PLAN_0.16.0 Phase B — parity harness.
#
# Seeds the same data into both planes — an `products` AR table
# *and* the same rows emitted as RDF triples via Vv::Graph::Storable
# — then runs each representative IR program through both backends
# and asserts row-identity (after sort, after projection).
#
# Tagged :requires_extension because the SPARQL side needs the
# engine artifact. Skips with the standard build hint when absent.
RSpec.describe "QueryIR parity (sparql vs. relational)", :requires_extension do
  before(:all) do
    unless Vv::Graph::SpecSupport::ExtensionEnvironment.available?
      skip Vv::Graph::SpecSupport::ExtensionEnvironment.skip_reason
    end

    ::ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS parity_products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sku TEXT NOT NULL,
        brand TEXT,
        name TEXT,
        price INTEGER
      )
    SQL

    unless Object.const_defined?(:ParityProduct)
      klass = Class.new(::ActiveRecord::Base) do
        self.table_name = "parity_products"
        include ::Vv::Graph::Storable

        triples do
          subject -> { "urn:parity:product:#{id}" }
          triple "<mm:Product/sku>",   -> { sku }
          triple "<mm:Product/brand>", -> { brand }
          triple "<mm:Product/name>",  -> { name }
          triple "<mm:Product/price>", -> { price }
        end
      end
      Object.const_set(:ParityProduct, klass)
    end

    Vv::Graph::Schema.override(model: :ParityProduct, name: :sku,   iri: "mm:Product/sku")
    Vv::Graph::Schema.override(model: :ParityProduct, name: :brand, iri: "mm:Product/brand")
    Vv::Graph::Schema.override(model: :ParityProduct, name: :name,  iri: "mm:Product/name")
    Vv::Graph::Schema.override(model: :ParityProduct, name: :price, iri: "mm:Product/price")
  end

  before do
    ::ActiveRecord::Base.connection.execute("DELETE FROM parity_products")
    # reset_store! lives on the engine-environment helper and
    # `rdf_clear`s the SPARQL store.
    Vv::Graph::SpecSupport::ExtensionEnvironment.reset_store!

    # Issue the `?s a <mm:Product>` triple separately — Storable
    # emits per-predicate triples but doesn't auto-emit rdf:type
    # for the Find target class.
    ParityProduct.create!(sku: "A1", brand: "Epson", name: "Alpha", price: 100)
    ParityProduct.create!(sku: "A2", brand: "Epson", name: "Beta",  price: 200)
    ParityProduct.create!(sku: "B1", brand: "Canon", name: "Gamma", price: 150)

    rdf_type = "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>"
    ParityProduct.all.each do |p|
      env = Vv::Graph::Sparql.execute(<<~SPARQL)
        INSERT DATA { <urn:parity:product:#{p.id}> #{rdf_type} <mm:ParityProduct> . }
      SPARQL
      raise "type INSERT failed: #{env.inspect}" unless env[:ok]
    end
  end

  let(:find) { Vv::Graph::QueryIR::Find.new(type: :ParityProduct) }

  def normalize(rows, fields)
    rows.map do |row|
      fields.each_with_object({}) { |f, h| h[f.to_s] = row[f.to_s] }
    end.sort_by { |r| fields.map { |f| r[f.to_s].to_s } }
  end

  shared_examples "parity" do |label, ir, fields|
    it "matches across sparql + relational — #{label}" do
      sparql_env     = Vv::Graph::QueryIR.run(ir, backend: :sparql)
      relational_env = Vv::Graph::QueryIR.run(ir, backend: :relational)

      expect(sparql_env[:ok]).to     be(true), "sparql refused: #{sparql_env.inspect}"
      expect(relational_env[:ok]).to be(true), "relational refused: #{relational_env.inspect}"

      sparql_rows     = normalize(sparql_env[:results],     fields)
      relational_rows = normalize(relational_env[:results], fields)

      expect(relational_rows).to eq(sparql_rows)
    end
  end

  include_examples "parity",
    "find + project brand only",
    [
      Vv::Graph::QueryIR::Find.new(type: :ParityProduct),
      Vv::Graph::QueryIR::Project.new(fields: [:brand])
    ],
    [:brand]

  include_examples "parity",
    "filter brand=Epson, project sku",
    [
      Vv::Graph::QueryIR::Find.new(type: :ParityProduct),
      Vv::Graph::QueryIR::Filter.new(field: :brand, op: :eq, value: "Epson"),
      Vv::Graph::QueryIR::Project.new(fields: [:sku])
    ],
    [:sku]

  include_examples "parity",
    "filter range on price, project sku",
    [
      Vv::Graph::QueryIR::Find.new(type: :ParityProduct),
      Vv::Graph::QueryIR::FilterRange.new(field: :price, lo: 100, hi: 150),
      Vv::Graph::QueryIR::Project.new(fields: [:sku])
    ],
    [:sku]

  include_examples "parity",
    "filter in on sku, project name",
    [
      Vv::Graph::QueryIR::Find.new(type: :ParityProduct),
      Vv::Graph::QueryIR::FilterIn.new(field: :sku, values: %w[A1 B1]),
      Vv::Graph::QueryIR::Project.new(fields: [:name])
    ],
    [:name]

  it "Count: parity on row counts" do
    ir = [find, Vv::Graph::QueryIR::Count.new]
    s = Vv::Graph::QueryIR.run(ir, backend: :sparql)
    r = Vv::Graph::QueryIR.run(ir, backend: :relational)
    expect([s[:ok], r[:ok]]).to eq([true, true])
    expect(r[:count]).to eq(s[:count])
  end
end
