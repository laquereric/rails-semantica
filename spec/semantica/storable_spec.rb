# frozen_string_literal: true

require "spec_helper"

# PLAN_0.1.0 Phase D — Semantica::Storable contract.
#
# Three layers:
#
#   1. TermSerializer (pure Ruby, always runs) — N-Triples escaping,
#      type dispatch, IRI wrapping.
#
#   2. Recorder + Declaration (pure Ruby, always runs) — the
#      `triples do ... end` block records subject + predicates.
#
#   3. Live emission (`:requires_extension`) — a throwaway AR model
#      includes Storable, saves trigger emission, destroys retract,
#      updates replace.
RSpec.describe Semantica::Storable do
  describe Semantica::Storable::TermSerializer do
    describe ".iri" do
      it "wraps a bare string in angle brackets" do
        expect(described_class.iri("urn:mm:product:123")).to eq("<urn:mm:product:123>")
      end

      it "passes through already-wrapped IRIs unchanged" do
        expect(described_class.iri("<urn:mm:product:123>")).to eq("<urn:mm:product:123>")
      end
    end

    describe ".object" do
      it "serializes a plain string as a literal" do
        expect(described_class.object("Alice")).to eq('"Alice"')
      end

      it "escapes embedded quotes + backslashes in literals" do
        expect(described_class.object('she said "hi"')).to eq('"she said \\"hi\\""')
        expect(described_class.object("c:\\path")).to eq('"c:\\\\path"')
      end

      it "serializes integers with xsd:integer datatype" do
        expect(described_class.object(42))
          .to eq('"42"^^<http://www.w3.org/2001/XMLSchema#integer>')
      end

      it "serializes floats with xsd:double datatype" do
        expect(described_class.object(3.14))
          .to eq('"3.14"^^<http://www.w3.org/2001/XMLSchema#double>')
      end

      it "serializes booleans with xsd:boolean datatype" do
        expect(described_class.object(true))
          .to eq('"true"^^<http://www.w3.org/2001/XMLSchema#boolean>')
        expect(described_class.object(false))
          .to eq('"false"^^<http://www.w3.org/2001/XMLSchema#boolean>')
      end

      it "passes already-wrapped IRI strings through unchanged (operator escape hatch)" do
        expect(described_class.object("<urn:other>")).to eq("<urn:other>")
      end
    end
  end

  describe Semantica::Storable::Recorder do
    it "captures subject + ordered predicates" do
      recorder = described_class.new
      recorder.instance_eval do
        subject -> { "urn:s" }
        triple "schema:name", -> { "n" }
        triple "schema:age",  -> { 7 }, if: -> { true }
      end
      decl = recorder.finalize!

      expect(decl.subject_lambda).to be_a(Proc)
      expect(decl.predicates.map(&:iri)).to eq(["schema:name", "schema:age"])
      expect(decl.predicates.last.if_lambda).to be_a(Proc)
    end

    it "raises ArgumentError if no subject was declared" do
      recorder = described_class.new
      recorder.instance_eval do
        triple "schema:name", -> { "n" }
      end
      expect { recorder.finalize! }.to raise_error(ArgumentError, /subject/)
    end

    it "accepts subject as a block, not just a lambda" do
      recorder = described_class.new
      recorder.instance_eval do
        subject { "urn:from-block" }
      end
      decl = recorder.finalize!
      expect(decl.subject_lambda.call).to eq("urn:from-block")
    end

    describe "PLAN_0.2.0 Phase A — on_subject sub-blocks + literal-string predicate values" do
      it "captures on_subject blocks alongside the primary subject + predicates" do
        recorder = described_class.new
        recorder.instance_eval do
          subject -> { "urn:s" }
          triple "schema:name", -> { "n" }

          on_subject -> { "urn:other" } do
            triple "rdf:type",    "<urn:other:Type>"
            triple "schema:name", -> { "other-name" }
          end
        end
        decl = recorder.finalize!

        expect(decl.on_subject_blocks.length).to eq(1)
        block = decl.on_subject_blocks.first
        expect(block.subject_lambda.call).to eq("urn:other")
        expect(block.predicates.map(&:iri)).to eq(["rdf:type", "schema:name"])
      end

      it "literal-string predicate object is wrapped as a callable" do
        recorder = described_class.new
        recorder.instance_eval do
          subject -> { "urn:s" }
          triple "rdf:type", "<urn:Foo>"
        end
        decl = recorder.finalize!

        expect(decl.predicates.first.value_lambda).to respond_to(:call)
        expect(decl.predicates.first.value_lambda.call).to eq("<urn:Foo>")
      end

      it "raises ArgumentError if on_subject is called without a block" do
        recorder = described_class.new
        expect { recorder.on_subject(-> { "urn:other" }) }
          .to raise_error(ArgumentError, /predicates block/)
      end

      it "raises ArgumentError if on_subject is called without a subject lambda" do
        recorder = described_class.new
        expect { recorder.on_subject(nil) { triple "schema:name", -> { "n" } } }
          .to raise_error(ArgumentError, /subject lambda/)
      end
    end

    describe "PLAN_0.2.0 Phase B — `each` blocks (collection iteration + multi-value predicates)" do
      it "captures each blocks as (collection_lambda, block_proc) pairs" do
        recorder = described_class.new
        recorder.instance_eval do
          subject -> { "urn:s" }
          each -> { [:a, :b] } do |item|
            triple "mm:item", -> { item }
          end
        end
        decl = recorder.finalize!

        expect(decl.each_blocks.length).to eq(1)
        expect(decl.each_blocks.first.collection_lambda.call).to eq([:a, :b])
        expect(decl.each_blocks.first.block_proc).to be_a(Proc)
      end

      it "raises ArgumentError if each is called without a block" do
        recorder = described_class.new
        expect { recorder.each(-> { [] }) }
          .to raise_error(ArgumentError, /predicates block/)
      end

      it "raises ArgumentError if each is called without a collection lambda" do
        recorder = described_class.new
        expect { recorder.each(nil) { triple "mm:x", -> { 1 } } }
          .to raise_error(ArgumentError, /collection lambda/)
      end
    end
  end

  describe "lifecycle integration", :requires_extension do
    # Throwaway AR model defined inline. Setup is at `:each` level
    # (idempotent CREATE / DELETE) rather than `:all` so the
    # `:requires_extension` skip hook fires first when the engine
    # binary isn't on disk.
    before(:each) do
      ::ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS widgets (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL,
          name TEXT,
          price INTEGER
        )
      SQL
      ::ActiveRecord::Base.connection.execute("DELETE FROM widgets")

      unless Object.const_defined?(:Widget)
        widget_class = Class.new(::ActiveRecord::Base) do
          self.table_name = "widgets"
          include ::Semantica::Storable

          triples do
            subject -> { "urn:mm:widget:#{sku}" }
            triple "schema:name",  -> { name }
            triple "schema:price", -> { price }, if: -> { price && price > 0 }
          end
        end
        Object.const_set(:Widget, widget_class)
      end
    end

    it "emits triples on create" do
      Widget.create!(sku: "W1", name: "Widget One", price: 100)

      result = Semantica::Sparql.select(<<~SPARQL)
        SELECT ?n WHERE { <urn:mm:widget:W1> <schema:name> ?n }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:results].length).to eq(1)
      expect(result[:results].first["n"]).to include("Widget One")
    end

    it "honors `if:` guards (skips predicates whose guard is falsy)" do
      Widget.create!(sku: "W2", name: "Widget Two", price: 0)

      yes = Semantica::Sparql.ask("ASK { <urn:mm:widget:W2> <schema:name>  ?o }")
      no  = Semantica::Sparql.ask("ASK { <urn:mm:widget:W2> <schema:price> ?o }")

      expect(yes).to eq(ok: true, value: true)
      expect(no).to  eq(ok: true, value: false)
    end

    it "replaces values on update (no stale triples)" do
      w = Widget.create!(sku: "W3", name: "Original", price: 100)
      w.update!(name: "Renamed")

      result = Semantica::Sparql.select(<<~SPARQL)
        SELECT ?n WHERE { <urn:mm:widget:W3> <schema:name> ?n }
      SPARQL

      expect(result[:ok]).to be(true)
      expect(result[:results].length).to eq(1)
      expect(result[:results].first["n"]).to include("Renamed")
      expect(result[:results].first["n"]).not_to include("Original")
    end

    it "retracts triples on destroy" do
      w = Widget.create!(sku: "W4", name: "Doomed", price: 50)

      Semantica::Sparql.ask("ASK { <urn:mm:widget:W4> ?p ?o }").tap do |before|
        expect(before).to eq(ok: true, value: true)
      end

      w.destroy!

      after = Semantica::Sparql.ask("ASK { <urn:mm:widget:W4> ?p ?o }")
      expect(after).to eq(ok: true, value: false)
    end

    it "treats nil values as retraction (predicate cleared)" do
      Widget.create!(sku: "W5", name: "Named", price: 10)

      w = Widget.find_by(sku: "W5")
      w.update!(name: nil)

      result = Semantica::Sparql.ask("ASK { <urn:mm:widget:W5> <schema:name> ?o }")
      expect(result).to eq(ok: true, value: false)
    end
  end

  describe "PLAN_0.2.0 Phase A — on_subject lifecycle integration", :requires_extension do
    before(:each) do
      ::ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS gadgets (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL,
          name TEXT,
          category TEXT
        )
      SQL
      ::ActiveRecord::Base.connection.execute("DELETE FROM gadgets")

      unless Object.const_defined?(:Gadget)
        gadget_class = Class.new(::ActiveRecord::Base) do
          self.table_name = "gadgets"
          include ::Semantica::Storable

          triples do
            subject -> { "urn:mm:gadget:#{sku}" }
            triple "schema:name", -> { name }

            on_subject -> { "urn:mm:folder:category:#{category}" } do
              triple "rdf:type",    "<urn:mm:CategoryFolder>"
              triple "schema:name", -> { category.to_s.capitalize }
            end
          end
        end
        Object.const_set(:Gadget, gadget_class)
      end
    end

    it "emits primary-subject + on_subject triples on create" do
      Gadget.create!(sku: "G1", name: "Gadget One", category: "printer")

      primary = Semantica::Sparql.ask(
        "ASK { <urn:mm:gadget:G1> <schema:name> ?o }",
      )
      derived_type = Semantica::Sparql.select(
        "SELECT ?t WHERE { <urn:mm:folder:category:printer> <rdf:type> ?t }",
      )
      derived_name = Semantica::Sparql.select(
        "SELECT ?n WHERE { <urn:mm:folder:category:printer> <schema:name> ?n }",
      )

      expect(primary).to eq(ok: true, value: true)
      expect(derived_type[:ok]).to be(true)
      expect(derived_type[:results].first["t"]).to include("urn:mm:CategoryFolder")
      expect(derived_name[:ok]).to be(true)
      expect(derived_name[:results].first["n"]).to include("Printer")
    end

    it "retracts both primary + on_subject triples on destroy" do
      g = Gadget.create!(sku: "G2", name: "Gadget Two", category: "scanner")

      before = Semantica::Sparql.ask(
        "ASK { <urn:mm:folder:category:scanner> ?p ?o }",
      )
      expect(before).to eq(ok: true, value: true)

      g.destroy!

      after_primary = Semantica::Sparql.ask("ASK { <urn:mm:gadget:G2> ?p ?o }")
      after_folder  = Semantica::Sparql.ask(
        "ASK { <urn:mm:folder:category:scanner> ?p ?o }",
      )
      expect(after_primary).to eq(ok: true, value: false)
      expect(after_folder).to  eq(ok: true, value: false)
    end

    it "literal-string predicate object serializes as an IRI (not as a literal)" do
      Gadget.create!(sku: "G3", name: "Gadget Three", category: "camera")

      # The literal-string "<urn:mm:CategoryFolder>" passes through as
      # an IRI object (TermSerializer.object detects the wrapping).
      result = Semantica::Sparql.select(<<~SPARQL)
        SELECT ?s WHERE { ?s <rdf:type> <urn:mm:CategoryFolder> }
      SPARQL
      expect(result[:ok]).to be(true)
      expect(result[:results].map { |r| r["s"] }.join).to include("camera")
    end
  end

  describe "PLAN_0.2.0 Phase B — each blocks lifecycle integration", :requires_extension do
    # A model whose triple emissions come from a per-row collection
    # plus a multi-value feature flag predicate.
    before(:each) do
      ::ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS thingies (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL,
          specs TEXT,
          flags TEXT
        )
      SQL
      ::ActiveRecord::Base.connection.execute("DELETE FROM thingies")

      unless Object.const_defined?(:Thingy)
        thingy_class = Class.new(::ActiveRecord::Base) do
          self.table_name = "thingies"
          include ::Semantica::Storable

          # `specs` is a JSON-encoded array of {"name":..., "value":...}.
          # `flags` is a JSON-encoded array of strings (feature codes).
          def specs_array
            return [] if specs.nil? || specs.empty?
            require "json"
            ::JSON.parse(specs).map { |h| OpenStruct.new(name: h["name"], value: h["value"]) }
          end

          def flags_array
            return [] if flags.nil? || flags.empty?
            require "json"
            ::JSON.parse(flags)
          end

          triples do
            subject -> { "urn:mm:thingy:#{sku}" }

            each -> { specs_array } do |spec|
              triple "mm:#{spec.name}", -> { spec.value }
            end

            each -> { flags_array } do |flag|
              triple "mm:hasFeature", -> { flag }
            end
          end
        end
        Object.const_set(:Thingy, thingy_class)
        require "ostruct"
      end
    end

    it "emits one triple per collection item with per-item-interpolated predicates" do
      Thingy.create!(
        sku: "T1",
        specs: '[{"name":"weight","value":"500g"},{"name":"color","value":"red"}]',
      )

      weight = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:thingy:T1> <mm:weight> ?o }",
      )
      color = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:thingy:T1> <mm:color> ?o }",
      )

      expect(weight[:ok]).to be(true)
      expect(weight[:results].first["o"]).to include("500g")
      expect(color[:ok]).to be(true)
      expect(color[:results].first["o"]).to include("red")
    end

    it "emits multi-value via repeated each (one triple per flag)" do
      Thingy.create!(
        sku: "T2",
        flags: '["bluetooth","wifi","usb-c"]',
      )

      result = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:thingy:T2> <mm:hasFeature> ?o }",
      )
      expect(result[:ok]).to be(true)
      expect(result[:results].length).to eq(3)
      values = result[:results].map { |r| r["o"] }.join
      expect(values).to include("bluetooth").and include("wifi").and include("usb-c")
    end

    it "replaces the each-block predicate set on update (no stale triples)" do
      t = Thingy.create!(
        sku: "T3",
        flags: '["bluetooth","wifi"]',
      )

      before = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:thingy:T3> <mm:hasFeature> ?o }",
      )
      expect(before[:results].length).to eq(2)

      t.update!(flags: '["usb-c"]')

      after = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:thingy:T3> <mm:hasFeature> ?o }",
      )
      expect(after[:results].length).to eq(1)
      expect(after[:results].first["o"]).to include("usb-c")
    end

    it "retracts each-block triples on destroy" do
      t = Thingy.create!(
        sku: "T4",
        specs: '[{"name":"weight","value":"100g"}]',
        flags: '["a","b"]',
      )

      before = Semantica::Sparql.ask(
        "ASK { <urn:mm:thingy:T4> <mm:hasFeature> ?o }",
      )
      expect(before).to eq(ok: true, value: true)

      t.destroy!

      after = Semantica::Sparql.ask(
        "ASK { <urn:mm:thingy:T4> ?p ?o }",
      )
      expect(after).to eq(ok: true, value: false)
    end

    it "Sparql.execute('DELETE WHERE { <s> <p> ?o }') retracts all matching triples" do
      Semantica::Sparql.execute(<<~SPARQL)
        INSERT DATA {
          <urn:mm:thingy:T5> <mm:x> "a" .
          <urn:mm:thingy:T5> <mm:x> "b" .
          <urn:mm:thingy:T5> <mm:x> "c" .
        }
      SPARQL
      before = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:thingy:T5> <mm:x> ?o }",
      )
      expect(before[:results].length).to eq(3)

      result = Semantica::Sparql.execute(
        "DELETE WHERE { <urn:mm:thingy:T5> <mm:x> ?o }",
      )
      expect(result[:ok]).to be(true)
      expect(result[:count]).to eq(3)

      after = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:mm:thingy:T5> <mm:x> ?o }",
      )
      expect(after[:results]).to be_empty
    end
  end
end
