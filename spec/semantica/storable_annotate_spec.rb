# frozen_string_literal: true

require "spec_helper"

# PLAN_0.8.0 Phase B — `annotate` DSL on `Storable.triple` blocks
# + `Sparql.quoted_triple` operator-facing marker.
RSpec.describe "PLAN_0.8.0 Phase B — annotate DSL", :requires_extension do
  describe "Sparql.quoted_triple marker" do
    it "round-trips an annotated triple via TermSerializer" do
      qt = Semantica::Sparql.quoted_triple(
        "urn:mm:product:1", "schema:gtin", "1234567890123",
      )
      term = Semantica::Storable::TermSerializer.iri(qt)
      expect(term).to start_with("<<").and(end_with(">>"))
      expect(term).to include("<urn:mm:product:1>")
      expect(term).to include("<schema:gtin>")
      expect(term).to include('"1234567890123"')
    end

    it "supports nested quoted triples" do
      inner = Semantica::Sparql.quoted_triple("urn:s", "urn:p", "urn:o")
      outer = Semantica::Sparql.quoted_triple(inner, "urn:meta", "<urn:m>")
      term = Semantica::Storable::TermSerializer.iri(outer)
      # Outer: << <inner-quoted-triple> <urn:meta> <urn:m> >>
      expect(term).to start_with("<< << ")
      expect(term).to end_with(">>")
      # The inner triple's `>>` closes before the outer's predicate
      expect(term).to include(" >> <urn:meta> ")
      expect(term).to include("<urn:m>")
    end
  end

  describe "Semantica.rdf_star_writes_enabled? now flips to true" do
    it "is true once Sparql.quoted_triple is defined" do
      expect(Semantica.rdf_star_writes_enabled?).to be(true)
    end
  end

  describe "Storable + annotate" do
    before(:each) do
      ::ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS annot_products (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sku TEXT NOT NULL,
          gtin TEXT,
          updater_id INTEGER,
          confidence REAL
        )
      SQL
      ::ActiveRecord::Base.connection.execute("DELETE FROM annot_products")

      unless Object.const_defined?(:AnnotProduct)
        klass = Class.new(::ActiveRecord::Base) do
          self.table_name = "annot_products"
          include ::Semantica::Storable

          triples do
            subject -> { "urn:mm:annprod:#{sku}" }
            triple "schema:gtin", -> { gtin } do
              annotate "mm:reportedBy", -> { "<urn:mm:user:#{updater_id}>" }
              annotate "mm:confidence", -> { confidence },
                       if: -> { confidence.present? }
            end
          end
        end
        Object.const_set(:AnnotProduct, klass)
      end
    end

    after(:each) { ::ActiveRecord::Base.connection.execute("DELETE FROM annot_products") }

    it "emits the parent triple + each annotation against the quoted-triple subject" do
      AnnotProduct.create!(sku: "P1", gtin: "1234567890123",
                           updater_id: 42, confidence: 0.87)

      # Annotation reachable via the quoted-triple pattern
      query = <<~SPARQL
        SELECT ?u WHERE {
          << <urn:mm:annprod:P1> <schema:gtin> "1234567890123" >> <mm:reportedBy> ?u
        }
      SPARQL
      r = Semantica::Sparql.select(query)
      expect(r[:ok]).to be(true)
      expect(r[:results]).to contain_exactly("u" => "<urn:mm:user:42>")
    end

    it "honors annotation `if:` — skips the annotation when the guard is falsy" do
      AnnotProduct.create!(sku: "P2", gtin: "1111111111111",
                           updater_id: 7, confidence: nil)

      # reportedBy emits (no guard)
      yes = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:annprod:P2> <schema:gtin> "1111111111111" >> <mm:reportedBy> ?u }
      SPARQL
      expect(yes[:value]).to be(true)

      # confidence guarded — skipped
      no = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:annprod:P2> <schema:gtin> "1111111111111" >> <mm:confidence> ?c }
      SPARQL
      expect(no[:value]).to be(false)
    end

    it "destroy retracts the parent triple AND every annotation on its quoted-triple subject" do
      p = AnnotProduct.create!(sku: "P3", gtin: "2222222222222",
                               updater_id: 9, confidence: 0.5)

      # Confirm setup
      pre = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:annprod:P3> <schema:gtin> "2222222222222" >> <mm:reportedBy> ?u }
      SPARQL
      expect(pre[:value]).to be(true)

      p.destroy!

      parent = Semantica::Sparql.ask("ASK { <urn:mm:annprod:P3> <schema:gtin> ?o }")
      expect(parent[:value]).to be(false)

      ann = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:annprod:P3> <schema:gtin> "2222222222222" >> ?ap ?ao }
      SPARQL
      expect(ann[:value]).to be(false)
    end

    it "update! that changes the parent object orphans the prior annotations" do
      p = AnnotProduct.create!(sku: "P4", gtin: "3333333333333",
                               updater_id: 1, confidence: 0.5)

      # Annotation present on old quoted-triple subject
      old_pre = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:annprod:P4> <schema:gtin> "3333333333333" >> <mm:reportedBy> ?u }
      SPARQL
      expect(old_pre[:value]).to be(true)

      p.update!(gtin: "4444444444444", updater_id: 2)

      # Old quoted-triple subject lost its annotations (parent-object
      # change orphans prior annotations — pinned by SPARQL-star
      # referential opacity, see StarExts.md §3).
      # The DELETE WHERE retract that runs alongside the parent
      # replace_predicate! clears `<< … "3333333333333" >> ?ap ?ao`.
      old_post = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:annprod:P4> <schema:gtin> "3333333333333" >> ?ap ?ao }
      SPARQL
      expect(old_post[:value]).to be(false)

      # New quoted-triple subject carries the fresh annotations
      new_post = Semantica::Sparql.ask(<<~SPARQL)
        ASK { << <urn:mm:annprod:P4> <schema:gtin> "4444444444444" >> <mm:reportedBy> <urn:mm:user:2> }
      SPARQL
      expect(new_post[:value]).to be(true)
    end

    it "re-save with identical state is idempotent (annotations stay)" do
      p = AnnotProduct.create!(sku: "P5", gtin: "5555555555555",
                               updater_id: 3, confidence: 0.7)
      p.update!(updater_id: 3)   # no-op on the parent gtin, no-op on updater_id

      r = Semantica::Sparql.select(<<~SPARQL)
        SELECT ?u WHERE {
          << <urn:mm:annprod:P5> <schema:gtin> "5555555555555" >> <mm:reportedBy> ?u
        }
      SPARQL
      expect(r[:results]).to contain_exactly("u" => "<urn:mm:user:3>")
    end
  end
end
