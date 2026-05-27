# frozen_string_literal: true

require "spec_helper"

# PLAN_0.17.0 Phase D — multi-sort + Offset.
RSpec.describe "QueryIR multi-sort + Offset (composition + compilers)" do
  let(:find) { Vv::Graph::QueryIR::Find.new(type: :Product) }

  describe "composition rules (Vv::Graph::QueryIR.validate)" do
    it "permits multiple Sort nodes" do
      ir = [find,
            Vv::Graph::QueryIR::Sort.new(field: :brand),
            Vv::Graph::QueryIR::Sort.new(field: :price, dir: :desc)]
      expect(Vv::Graph::QueryIR.validate(ir)).to eq(:ok)
    end

    it "refuses two Offset nodes" do
      ir = [find,
            Vv::Graph::QueryIR::Offset.new(n: 10),
            Vv::Graph::QueryIR::Offset.new(n: 20),
            Vv::Graph::QueryIR::Limit.new(n: 5)]
      env = Vv::Graph::QueryIR.validate(ir)
      expect(env[:because]).to match(/at most one Offset/)
    end

    it "refuses Offset without Limit" do
      ir = [find, Vv::Graph::QueryIR::Offset.new(n: 10)]
      env = Vv::Graph::QueryIR.validate(ir)
      expect(env[:because]).to match(/Offset requires a Limit/)
    end

    it "Offset + Limit is fine" do
      ir = [find,
            Vv::Graph::QueryIR::Sort.new(field: :brand),
            Vv::Graph::QueryIR::Limit.new(n: 5),
            Vv::Graph::QueryIR::Offset.new(n: 10)]
      expect(Vv::Graph::QueryIR.validate(ir)).to eq(:ok)
    end

    it "still rejects Count + Offset" do
      ir = [find,
            Vv::Graph::QueryIR::Count.new,
            Vv::Graph::QueryIR::Offset.new(n: 10),
            Vv::Graph::QueryIR::Limit.new(n: 5)]
      env = Vv::Graph::QueryIR.validate(ir)
      expect(env[:because]).to match(/Count is incompatible/)
    end
  end

  describe "Backend::Sparql compiler" do
    def compile(ir)
      query = nil
      allow(Vv::Graph::Sparql).to receive(:select) do |q, **_|
        query = q
        { ok: true, results: [] }
      end
      Vv::Graph::Backend::Sparql.execute(ir, scope: nil)
      query
    end

    it "emits ORDER BY with multiple keys in IR order" do
      q = compile([find,
                   Vv::Graph::QueryIR::Sort.new(field: :brand),
                   Vv::Graph::QueryIR::Sort.new(field: :price, dir: :desc)])
      expect(q).to match(/ORDER BY ASC\(\?brand\) DESC\(\?price\)/)
    end

    it "emits OFFSET N after LIMIT N" do
      q = compile([find,
                   Vv::Graph::QueryIR::Sort.new(field: :brand),
                   Vv::Graph::QueryIR::Limit.new(n: 5),
                   Vv::Graph::QueryIR::Offset.new(n: 10)])
      expect(q).to match(/LIMIT 5 OFFSET 10/)
    end
  end
end

# Round-trip + parity (the relational chain + the engine SPARQL both
# need to be live; tag :requires_extension)
RSpec.describe "QueryIR multi-sort + Offset round-trip", :requires_extension do
  AR_LOADABLE = begin
    require "active_record"; require "sqlite3"; true
  rescue LoadError
    false
  end

  before(:all) do
    skip "active_record / sqlite3 not loadable" unless AR_LOADABLE
    unless Vv::Graph::SpecSupport::ExtensionEnvironment.available?
      skip Vv::Graph::SpecSupport::ExtensionEnvironment.skip_reason
    end

    ::ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS ms_products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sku TEXT, brand TEXT, price INTEGER
      )
    SQL

    unless Object.const_defined?(:MsProduct)
      Object.const_set(:MsProduct, Class.new(::ActiveRecord::Base) { self.table_name = "ms_products" })
    end
  end

  before do
    ::ActiveRecord::Base.connection.execute("DELETE FROM ms_products")
    MsProduct.create!(sku: "A1", brand: "Epson", price: 100)
    MsProduct.create!(sku: "A2", brand: "Epson", price: 200)
    MsProduct.create!(sku: "B1", brand: "Canon", price: 150)
    MsProduct.create!(sku: "B2", brand: "Canon", price: 50)
  end

  let(:find) { Vv::Graph::QueryIR::Find.new(type: :MsProduct) }

  it "Relational backend: multi-sort orders by primary then secondary key" do
    env = Vv::Graph::Backend::Relational.execute(
      [find,
       Vv::Graph::QueryIR::Sort.new(field: :brand,  dir: :asc),
       Vv::Graph::QueryIR::Sort.new(field: :price, dir: :desc),
       Vv::Graph::QueryIR::Project.new(fields: [:sku])],
      scope: nil
    )
    skus = env[:results].map { |r| r["sku"] }
    # Canon first (brand asc); within Canon, higher price first
    expect(skus.first(2)).to eq(%w[B1 B2])
    expect(skus.last(2)).to eq(%w[A2 A1])
  end

  it "Relational backend: Offset skips rows after Limit" do
    env = Vv::Graph::Backend::Relational.execute(
      [find,
       Vv::Graph::QueryIR::Sort.new(field: :price, dir: :asc),
       Vv::Graph::QueryIR::Limit.new(n: 2),
       Vv::Graph::QueryIR::Offset.new(n: 1),
       Vv::Graph::QueryIR::Project.new(fields: [:sku])],
      scope: nil
    )
    # Sorted asc: B2(50), A1(100), B1(150), A2(200). Offset 1 limit 2 → [A1, B1]
    expect(env[:results].map { |r| r["sku"] }).to eq(%w[A1 B1])
  end
end
