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
end
