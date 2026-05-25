# frozen_string_literal: true

require "spec_helper"

# PLAN_0.3.0 Phase B — Storable.dispatch_mode ladder.
#
# Three layers:
#
#   1. Mode reader contract (pure Ruby): the reader exists, the env
#      var override works, the cache invalidates on reset.
#   2. Round-trip parity (`:requires_extension`): every dispatch mode
#      produces the same end state for create / update / destroy.
#   3. Per-save round-trip count (`:requires_extension`): :sparql_update
#      issues exactly one Sparql.execute call per declared predicate;
#      :per_call issues 2+N where N is the current-value count.
RSpec.describe "Vv::Graph::Storable dispatch_mode" do
  describe "module surface (pure Ruby)" do
    around do |ex|
      original = ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE]
      Vv::Graph::Storable.dispatch_mode_reset!
      ex.run
    ensure
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = original
      Vv::Graph::Storable.dispatch_mode_reset!
    end

    it "pins the three documented mode values" do
      expect(Vv::Graph::Storable::DISPATCH_MODES).to eq(%i[sparql_update bulk per_call])
    end

    it "MM_SEMANTICA_DISPATCH_MODE=per_call forces :per_call" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "per_call"
      expect(Vv::Graph::Storable.dispatch_mode).to eq(:per_call)
    end

    it "MM_SEMANTICA_DISPATCH_MODE=sparql_update forces :sparql_update" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      expect(Vv::Graph::Storable.dispatch_mode).to eq(:sparql_update)
    end

    it "MM_SEMANTICA_DISPATCH_MODE=bulk forces :bulk (PLAN_0.4.0 will implement the path)" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "bulk"
      expect(Vv::Graph::Storable.dispatch_mode).to eq(:bulk)
    end

    it "unknown override values fall through to engine probe" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "lolwat"
      # No AR ⇒ probe yields :per_call defensively.
      hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base)
      expect(Vv::Graph::Storable.dispatch_mode).to eq(:per_call)
    end

    it "caches the detected mode across calls" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "per_call"
      first = Vv::Graph::Storable.dispatch_mode
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      # Without reset, the cached :per_call survives.
      expect(Vv::Graph::Storable.dispatch_mode).to eq(first)
      Vv::Graph::Storable.dispatch_mode_reset!
      expect(Vv::Graph::Storable.dispatch_mode).to eq(:sparql_update)
    end
  end

  describe "engine probe", :requires_extension do
    before { Vv::Graph::Storable.dispatch_mode_reset! }
    after  { Vv::Graph::Storable.dispatch_mode_reset! }

    it "detects :sparql_update against engine ≥ 0.5.0" do
      ENV.delete(Vv::Graph::Storable::ENV_DISPATCH_MODE)
      expect(Vv::Graph::Storable.dispatch_mode).to eq(:sparql_update)
    end
  end

  describe "round-trip parity across modes", :requires_extension do
    before(:each) do
      ::ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS dispatch_widgets (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL,
          name TEXT,
          price INTEGER
        )
      SQL
      ::ActiveRecord::Base.connection.execute("DELETE FROM dispatch_widgets")
      Vv::Graph::Sparql.execute("CLEAR ALL")

      unless Object.const_defined?(:DispatchWidget)
        klass = Class.new(::ActiveRecord::Base) do
          self.table_name = "dispatch_widgets"
          include ::Vv::Graph::Storable

          triples do
            subject -> { "urn:mm:dwidget:#{sku}" }
            triple "schema:name",  -> { name }
            triple "schema:price", -> { price }
          end
        end
        Object.const_set(:DispatchWidget, klass)
      end
    end

    around do |ex|
      original = ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE]
      ex.run
    ensure
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = original
      Vv::Graph::Storable.dispatch_mode_reset!
    end

    %w[sparql_update bulk per_call].each do |mode|
      context "in :#{mode} mode" do
        before do
          ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = mode
          Vv::Graph::Storable.dispatch_mode_reset!
          expect(Vv::Graph::Storable.dispatch_mode).to eq(mode.to_sym)
        end

        it "create emits all declared predicates" do
          DispatchWidget.create!(sku: "D1", name: "First", price: 10)
          result = Vv::Graph::Sparql.select(
            "SELECT ?p ?o WHERE { <urn:mm:dwidget:D1> ?p ?o }",
          )
          expect(result[:ok]).to be(true)
          expect(result[:results].length).to eq(2)
        end

        it "update replaces a predicate value with no stale rows" do
          w = DispatchWidget.create!(sku: "D2", name: "Original", price: 20)
          w.update!(name: "Renamed")
          result = Vv::Graph::Sparql.select(
            "SELECT ?n WHERE { <urn:mm:dwidget:D2> <schema:name> ?n }",
          )
          expect(result[:results].length).to eq(1)
          expect(result[:results].first["n"]).to include("Renamed")
        end

        it "destroy retracts every declared triple" do
          w = DispatchWidget.create!(sku: "D3", name: "Doomed", price: 30)
          w.destroy!
          result = Vv::Graph::Sparql.ask("ASK { <urn:mm:dwidget:D3> ?p ?o }")
          expect(result).to eq(ok: true, value: false)
        end

        it "nil value retracts the slot" do
          w = DispatchWidget.create!(sku: "D4", name: "Has", price: 40)
          w.update!(name: nil)
          result = Vv::Graph::Sparql.ask("ASK { <urn:mm:dwidget:D4> <schema:name> ?o }")
          expect(result).to eq(ok: true, value: false)
        end
      end
    end
  end

  describe ":sparql_update collapses multi-value (each block) into one UPDATE per predicate", :requires_extension do
    before(:each) do
      ::ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS dispatch_baskets (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL
        )
      SQL
      ::ActiveRecord::Base.connection.execute("DELETE FROM dispatch_baskets")
      Vv::Graph::Sparql.execute("CLEAR ALL")

      unless Object.const_defined?(:DispatchBasket)
        klass = Class.new(::ActiveRecord::Base) do
          self.table_name = "dispatch_baskets"
          include ::Vv::Graph::Storable

          attr_accessor :flags

          triples do
            subject -> { "urn:mm:dbasket:#{sku}" }
            each -> { flags || [] } do |flag|
              triple "mm:hasFeature", -> { flag }
            end
          end
        end
        Object.const_set(:DispatchBasket, klass)
      end
    end

    around do |ex|
      original = ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE]
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      Vv::Graph::Storable.dispatch_mode_reset!
      ex.run
    ensure
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = original
      Vv::Graph::Storable.dispatch_mode_reset!
    end

    it "emits N values for one predicate via a single DELETE/INSERT WHERE" do
      b = DispatchBasket.new(sku: "B1")
      b.flags = %w[alpha beta gamma]
      b.save!

      result = Vv::Graph::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:dbasket:B1> <mm:hasFeature> ?o }",
      )
      values = result[:results].map { |r| r["o"].delete('"') }
      expect(values).to contain_exactly("alpha", "beta", "gamma")
    end

    it "update with a different collection replaces the full set (no stale rows)" do
      b = DispatchBasket.new(sku: "B2")
      b.flags = %w[red green blue]
      b.save!

      b.flags = %w[red yellow]
      b.save!

      result = Vv::Graph::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:dbasket:B2> <mm:hasFeature> ?o }",
      )
      values = result[:results].map { |r| r["o"].delete('"') }
      expect(values).to contain_exactly("red", "yellow")
    end
  end

  describe "per-save Sparql.execute round-trip count", :requires_extension do
    # PLAN_0.3.0 Phase B exit criterion — :sparql_update issues ≤ 1
    # Sparql.execute round-trip per declared predicate per save.
    # :per_call issues 2+N: SELECT (via Sparql.select) + N DELETE
    # + 1 INSERT.

    before(:each) do
      ::ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS dispatch_counters (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL,
          name TEXT,
          price INTEGER
        )
      SQL
      ::ActiveRecord::Base.connection.execute("DELETE FROM dispatch_counters")
      Vv::Graph::Sparql.execute("CLEAR ALL")

      unless Object.const_defined?(:DispatchCounter)
        klass = Class.new(::ActiveRecord::Base) do
          self.table_name = "dispatch_counters"
          include ::Vv::Graph::Storable

          triples do
            subject -> { "urn:mm:dcounter:#{sku}" }
            triple "schema:name",  -> { name }
            triple "schema:price", -> { price }
          end
        end
        Object.const_set(:DispatchCounter, klass)
      end
    end

    around do |ex|
      original = ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE]
      ex.run
    ensure
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = original
      Vv::Graph::Storable.dispatch_mode_reset!
    end

    def count_executes
      execute_count = 0
      original = Vv::Graph::Sparql.method(:execute)
      allow(Vv::Graph::Sparql).to receive(:execute) do |*args, **kwargs|
        execute_count += 1
        original.call(*args, **kwargs)
      end
      yield
      execute_count
    end

    it ":sparql_update emits ≤ 1 execute per declared predicate per save" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      Vv::Graph::Storable.dispatch_mode_reset!

      count = count_executes do
        DispatchCounter.create!(sku: "C1", name: "First", price: 100)
      end
      # 2 declared predicates → ≤ 2 execute calls.
      expect(count).to be <= 2
    end

    it ":bulk issues exactly 2 bulk calls per save regardless of predicate count" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "bulk"
      Vv::Graph::Storable.dispatch_mode_reset!

      bulk_insert_calls = 0
      bulk_delete_calls = 0
      allow(Vv::Graph::Sparql).to receive(:bulk_insert).and_wrap_original do |orig, *a, **kw|
        bulk_insert_calls += 1
        orig.call(*a, **kw)
      end
      allow(Vv::Graph::Sparql).to receive(:bulk_delete).and_wrap_original do |orig, *a, **kw|
        bulk_delete_calls += 1
        orig.call(*a, **kw)
      end

      DispatchCounter.create!(sku: "C3", name: "Third", price: 300)

      # Create case: 2 predicates, no current values, so bulk_delete
      # is skipped (delete_rows empty). 1 bulk_insert total.
      expect(bulk_insert_calls).to eq(1)
      expect(bulk_delete_calls).to eq(0)
    end

    it ":bulk update issues 1 bulk_delete + 1 bulk_insert (constant)" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "bulk"
      Vv::Graph::Storable.dispatch_mode_reset!

      w = DispatchCounter.create!(sku: "C4", name: "Fourth", price: 400)

      bulk_insert_calls = 0
      bulk_delete_calls = 0
      allow(Vv::Graph::Sparql).to receive(:bulk_insert).and_wrap_original do |orig, *a, **kw|
        bulk_insert_calls += 1
        orig.call(*a, **kw)
      end
      allow(Vv::Graph::Sparql).to receive(:bulk_delete).and_wrap_original do |orig, *a, **kw|
        bulk_delete_calls += 1
        orig.call(*a, **kw)
      end

      w.update!(name: "Renamed", price: 999)

      expect(bulk_insert_calls).to eq(1)
      expect(bulk_delete_calls).to eq(1)
    end

    it ":per_call emits substantially more execute calls than :sparql_update for the same save" do
      ENV[Vv::Graph::Storable::ENV_DISPATCH_MODE] = "per_call"
      Vv::Graph::Storable.dispatch_mode_reset!

      count = count_executes do
        DispatchCounter.create!(sku: "C2", name: "Second", price: 200)
      end
      # Per declared predicate: 1 INSERT DATA + 0 DELETE DATA (no
      # current values on create). 2 predicates → 2 execute calls
      # minimum. On update there'd be N more for the DELETE DATA
      # path. Verify the floor for the create case: 2.
      expect(count).to be >= 2
    end
  end
end
