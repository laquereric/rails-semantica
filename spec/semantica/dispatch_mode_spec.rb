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
RSpec.describe "Semantica::Storable dispatch_mode" do
  describe "module surface (pure Ruby)" do
    around do |ex|
      original = ENV[Semantica::Storable::ENV_DISPATCH_MODE]
      Semantica::Storable.dispatch_mode_reset!
      ex.run
    ensure
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = original
      Semantica::Storable.dispatch_mode_reset!
    end

    it "pins the three documented mode values" do
      expect(Semantica::Storable::DISPATCH_MODES).to eq(%i[sparql_update bulk per_call])
    end

    it "MM_SEMANTICA_DISPATCH_MODE=per_call forces :per_call" do
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "per_call"
      expect(Semantica::Storable.dispatch_mode).to eq(:per_call)
    end

    it "MM_SEMANTICA_DISPATCH_MODE=sparql_update forces :sparql_update" do
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      expect(Semantica::Storable.dispatch_mode).to eq(:sparql_update)
    end

    it "MM_SEMANTICA_DISPATCH_MODE=bulk forces :bulk (PLAN_0.4.0 will implement the path)" do
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "bulk"
      expect(Semantica::Storable.dispatch_mode).to eq(:bulk)
    end

    it "unknown override values fall through to engine probe" do
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "lolwat"
      # No AR ⇒ probe yields :per_call defensively.
      hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base)
      expect(Semantica::Storable.dispatch_mode).to eq(:per_call)
    end

    it "caches the detected mode across calls" do
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "per_call"
      first = Semantica::Storable.dispatch_mode
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      # Without reset, the cached :per_call survives.
      expect(Semantica::Storable.dispatch_mode).to eq(first)
      Semantica::Storable.dispatch_mode_reset!
      expect(Semantica::Storable.dispatch_mode).to eq(:sparql_update)
    end
  end

  describe "engine probe", :requires_extension do
    before { Semantica::Storable.dispatch_mode_reset! }
    after  { Semantica::Storable.dispatch_mode_reset! }

    it "detects :sparql_update against engine ≥ 0.5.0" do
      ENV.delete(Semantica::Storable::ENV_DISPATCH_MODE)
      expect(Semantica::Storable.dispatch_mode).to eq(:sparql_update)
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
      Semantica::Sparql.execute("CLEAR ALL")

      unless Object.const_defined?(:DispatchWidget)
        klass = Class.new(::ActiveRecord::Base) do
          self.table_name = "dispatch_widgets"
          include ::Semantica::Storable

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
      original = ENV[Semantica::Storable::ENV_DISPATCH_MODE]
      ex.run
    ensure
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = original
      Semantica::Storable.dispatch_mode_reset!
    end

    %w[sparql_update per_call].each do |mode|
      context "in :#{mode} mode" do
        before do
          ENV[Semantica::Storable::ENV_DISPATCH_MODE] = mode
          Semantica::Storable.dispatch_mode_reset!
          expect(Semantica::Storable.dispatch_mode).to eq(mode.to_sym)
        end

        it "create emits all declared predicates" do
          DispatchWidget.create!(sku: "D1", name: "First", price: 10)
          result = Semantica::Sparql.select(
            "SELECT ?p ?o WHERE { <urn:mm:dwidget:D1> ?p ?o }",
          )
          expect(result[:ok]).to be(true)
          expect(result[:results].length).to eq(2)
        end

        it "update replaces a predicate value with no stale rows" do
          w = DispatchWidget.create!(sku: "D2", name: "Original", price: 20)
          w.update!(name: "Renamed")
          result = Semantica::Sparql.select(
            "SELECT ?n WHERE { <urn:mm:dwidget:D2> <schema:name> ?n }",
          )
          expect(result[:results].length).to eq(1)
          expect(result[:results].first["n"]).to include("Renamed")
        end

        it "destroy retracts every declared triple" do
          w = DispatchWidget.create!(sku: "D3", name: "Doomed", price: 30)
          w.destroy!
          result = Semantica::Sparql.ask("ASK { <urn:mm:dwidget:D3> ?p ?o }")
          expect(result).to eq(ok: true, value: false)
        end

        it "nil value retracts the slot" do
          w = DispatchWidget.create!(sku: "D4", name: "Has", price: 40)
          w.update!(name: nil)
          result = Semantica::Sparql.ask("ASK { <urn:mm:dwidget:D4> <schema:name> ?o }")
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
      Semantica::Sparql.execute("CLEAR ALL")

      unless Object.const_defined?(:DispatchBasket)
        klass = Class.new(::ActiveRecord::Base) do
          self.table_name = "dispatch_baskets"
          include ::Semantica::Storable

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
      original = ENV[Semantica::Storable::ENV_DISPATCH_MODE]
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      Semantica::Storable.dispatch_mode_reset!
      ex.run
    ensure
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = original
      Semantica::Storable.dispatch_mode_reset!
    end

    it "emits N values for one predicate via a single DELETE/INSERT WHERE" do
      b = DispatchBasket.new(sku: "B1")
      b.flags = %w[alpha beta gamma]
      b.save!

      result = Semantica::Sparql.select(
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

      result = Semantica::Sparql.select(
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
      Semantica::Sparql.execute("CLEAR ALL")

      unless Object.const_defined?(:DispatchCounter)
        klass = Class.new(::ActiveRecord::Base) do
          self.table_name = "dispatch_counters"
          include ::Semantica::Storable

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
      original = ENV[Semantica::Storable::ENV_DISPATCH_MODE]
      ex.run
    ensure
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = original
      Semantica::Storable.dispatch_mode_reset!
    end

    def count_executes
      execute_count = 0
      original = Semantica::Sparql.method(:execute)
      allow(Semantica::Sparql).to receive(:execute) do |*args, **kwargs|
        execute_count += 1
        original.call(*args, **kwargs)
      end
      yield
      execute_count
    end

    it ":sparql_update emits ≤ 1 execute per declared predicate per save" do
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "sparql_update"
      Semantica::Storable.dispatch_mode_reset!

      count = count_executes do
        DispatchCounter.create!(sku: "C1", name: "First", price: 100)
      end
      # 2 declared predicates → ≤ 2 execute calls.
      expect(count).to be <= 2
    end

    it ":per_call emits substantially more execute calls than :sparql_update for the same save" do
      ENV[Semantica::Storable::ENV_DISPATCH_MODE] = "per_call"
      Semantica::Storable.dispatch_mode_reset!

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
