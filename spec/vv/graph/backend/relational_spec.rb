# frozen_string_literal: true

require "spec_helper"

# PLAN_0.16.0 Phase B — IR → ActiveRecord compiler.
#
# Boots active_record + sqlite3 directly (no engine artifact
# required), sets up an in-memory `products` table, and exercises
# each IR node type against a dynamically-defined Product AR class.
#
# Skips when active_record / sqlite3 aren't loadable (matches the
# spirit of :requires_extension, but the predicate is narrower —
# the engine binary is not needed here).
RSpec.describe Vv::Graph::Backend::Relational do
  AR_LOADABLE = begin
    require "active_record"
    require "sqlite3"
    true
  rescue LoadError
    false
  end

  before(:all) do
    skip "active_record / sqlite3 not loadable" unless AR_LOADABLE

    ::ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ::ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sku TEXT NOT NULL,
        brand TEXT,
        name TEXT,
        price INTEGER,
        created_at TEXT
      )
    SQL

    unless Object.const_defined?(:Product)
      Object.const_set(:Product, Class.new(::ActiveRecord::Base) { self.table_name = "products" })
    end
  end

  before do
    skip "active_record / sqlite3 not loadable" unless AR_LOADABLE
    ::ActiveRecord::Base.connection.execute("DELETE FROM products")
    Vv::Graph::Schema.reset!
    Product.create!(sku: "A1", brand: "Epson", name: "Alpha", price: 100)
    Product.create!(sku: "A2", brand: "Epson", name: "Beta",  price: 200)
    Product.create!(sku: "B1", brand: "Canon", name: "Gamma", price: 150)
  end

  let(:find) { Vv::Graph::QueryIR::Find.new(type: :Product) }

  describe ".capabilities" do
    it "advertises the v0.16.0 Relational capability map" do
      expect(described_class.capabilities).to include(
        owl_closure: false,
        shacl: false,
        joins: :ar,
        datetime_filter: true,
        fts: false,
        named_graphs: false
      )
    end

    it "is frozen" do
      expect(described_class.capabilities).to be_frozen
    end
  end

  describe "Find alone" do
    it "returns every row with all columns projected" do
      env = described_class.execute([find], scope: nil)
      expect(env).to include(ok: true, from: :relational)
      expect(env[:results].size).to eq(3)
      expect(env[:results].first.keys).to include("s", "sku", "brand", "name", "price")
      expect(env[:results].first["s"]).to be_a(String)
    end
  end

  describe "Filter (eq / neq / lt / lte / gt / gte)" do
    it "Filter eq narrows by equality" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::Filter.new(field: :brand, op: :eq, value: "Epson")],
        scope: nil
      )
      expect(env[:results].size).to eq(2)
      expect(env[:results].map { |r| r["brand"] }.uniq).to eq(["Epson"])
    end

    it "Filter neq excludes" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::Filter.new(field: :brand, op: :neq, value: "Epson")],
        scope: nil
      )
      expect(env[:results].size).to eq(1)
      expect(env[:results].first["brand"]).to eq("Canon")
    end

    it "Filter lt / lte / gt / gte work on numeric columns" do
      lt = described_class.execute(
        [find, Vv::Graph::QueryIR::Filter.new(field: :price, op: :lt, value: 200)],
        scope: nil
      )
      expect(lt[:results].size).to eq(2)

      gte = described_class.execute(
        [find, Vv::Graph::QueryIR::Filter.new(field: :price, op: :gte, value: 150)],
        scope: nil
      )
      expect(gte[:results].size).to eq(2)
    end
  end

  describe "FilterRange / FilterIn" do
    it "FilterRange (inclusive) bounds with lo..hi" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::FilterRange.new(field: :price, lo: 100, hi: 150)],
        scope: nil
      )
      expect(env[:results].size).to eq(2)
    end

    it "FilterRange (exclusive) bounds with lo...hi" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::FilterRange.new(field: :price, lo: 100, hi: 200, inclusive: false)],
        scope: nil
      )
      expect(env[:results].size).to eq(1)
      expect(env[:results].first["price"]).to eq(150)
    end

    it "FilterIn matches any of values" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::FilterIn.new(field: :sku, values: %w[A1 B1])],
        scope: nil
      )
      expect(env[:results].size).to eq(2)
    end
  end

  describe "Sort + Limit + Project" do
    it "Sort orders results" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::Sort.new(field: :price, dir: :desc)],
        scope: nil
      )
      expect(env[:results].map { |r| r["price"] }).to eq([200, 150, 100])
    end

    it "Limit caps row count" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::Sort.new(field: :price, dir: :asc), Vv::Graph::QueryIR::Limit.new(n: 2)],
        scope: nil
      )
      expect(env[:results].size).to eq(2)
      expect(env[:results].map { |r| r["price"] }).to eq([100, 150])
    end

    it "Project narrows result keys" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::Project.new(fields: [:sku, :brand])],
        scope: nil
      )
      expect(env[:results].first.keys).to match_array(%w[s sku brand])
    end
  end

  describe "Count" do
    it "returns { ok:, count: }" do
      env = described_class.execute([find, Vv::Graph::QueryIR::Count.new], scope: nil)
      expect(env).to include(ok: true, count: 3, from: :relational)
    end

    it "honours filters" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::Filter.new(field: :brand, op: :eq, value: "Epson"),
         Vv::Graph::QueryIR::Count.new],
        scope: nil
      )
      expect(env[:count]).to eq(2)
    end
  end

  describe "Compare" do
    it "returns left / right / equal" do
      epson_id = Product.find_by(sku: "A1").id
      canon_id = Product.find_by(sku: "B1").id
      compare = Vv::Graph::QueryIR::Compare.new(field: :brand, left: epson_id, right: canon_id)
      env = described_class.execute([find, compare], scope: nil)
      expect(env[:results].first).to include("left" => "Epson", "right" => "Canon", "equal" => false)
    end

    it "equal: true when fields match" do
      ids = Product.where(brand: "Epson").pluck(:id)
      compare = Vv::Graph::QueryIR::Compare.new(field: :brand, left: ids.first, right: ids.last)
      env = described_class.execute([find, compare], scope: nil)
      expect(env[:results].first["equal"]).to be true
    end
  end

  describe "refusal envelopes" do
    it "refuses unknown model with :model_unknown" do
      env = described_class.execute([Vv::Graph::QueryIR::Find.new(type: :NotAModel)], scope: nil)
      expect(env).to include(ok: false, reason: :model_unknown, from: :relational)
    end

    it "refuses AR query errors with :ar_query_error" do
      env = described_class.execute(
        [find, Vv::Graph::QueryIR::Filter.new(field: :no_such_column, op: :eq, value: "x")],
        scope: nil
      )
      expect(env).to include(ok: false, reason: :ar_query_error, from: :relational)
    end
  end
end
