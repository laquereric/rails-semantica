# frozen_string_literal: true

require "spec_helper"

# PLAN_0.16.0 Phase D — Loader.normalize_schema! + schema_normalized?
# capability predicate.
#
# Needs the engine artifact: the normaliser emits RDF into the
# :schema named graph via Vv::Graph::Sparql.execute.
RSpec.describe "Vv::Graph::Loader.normalize_schema!", :requires_extension do
  before(:all) do
    unless Vv::Graph::SpecSupport::ExtensionEnvironment.available?
      skip Vv::Graph::SpecSupport::ExtensionEnvironment.skip_reason
    end

    ::ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS norm_authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        created_at DATETIME
      )
    SQL
    ::ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS norm_books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        price INTEGER,
        norm_author_id INTEGER
      )
    SQL

    unless Object.const_defined?(:NormAuthor)
      Object.const_set(:NormAuthor, Class.new(::ActiveRecord::Base) { self.table_name = "norm_authors" })
    end
    unless Object.const_defined?(:NormBook)
      Object.const_set(:NormBook, Class.new(::ActiveRecord::Base) { self.table_name = "norm_books" })
    end
  end

  before do
    Vv::Graph.reset_schema_normalization!
    Vv::Graph::Schema.reset!
  end

  describe "capability predicate" do
    it "starts false; flips true after normalize_schema!" do
      expect(Vv::Graph.schema_normalized?).to be(false)

      Vv::Graph::Loader.normalize_schema!(include: %w[norm_authors norm_books])

      expect(Vv::Graph.schema_normalized?).to be(true)
      info = Vv::Graph.schema_normalization_info
      expect(info[:schema_graph]).to eq("urn:vv-graph:schema")
      expect(info[:iri_prefix]).to eq("mm:")
    end
  end

  describe "emitted RDF" do
    let(:schema_graph) { "urn:vv-graph:schema" }
    let(:rdf_type) { "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>" }
    let(:owl_class) { "<http://www.w3.org/2002/07/owl#Class>" }
    let(:owl_datatype) { "<http://www.w3.org/2002/07/owl#DatatypeProperty>" }
    let(:owl_object) { "<http://www.w3.org/2002/07/owl#ObjectProperty>" }

    before do
      Vv::Graph::Loader.normalize_schema!(include: %w[norm_authors norm_books])
    end

    it "emits owl:Class triples for each model" do
      result = Vv::Graph::Sparql.select(<<~SPARQL, graph: schema_graph)
        SELECT ?c WHERE { ?c #{rdf_type} #{owl_class} }
      SPARQL
      classes = result[:results].map { |r| r["c"] }
      expect(classes).to include("<mm:NormAuthor>", "<mm:NormBook>")
    end

    it "emits owl:DatatypeProperty triples for plain columns" do
      result = Vv::Graph::Sparql.select(<<~SPARQL, graph: schema_graph)
        SELECT ?p WHERE { ?p #{rdf_type} #{owl_datatype} }
      SPARQL
      properties = result[:results].map { |r| r["p"] }
      expect(properties).to include("<mm:NormAuthor/name>", "<mm:NormBook/title>", "<mm:NormBook/price>")
    end

    it "emits owl:ObjectProperty for FK columns" do
      result = Vv::Graph::Sparql.select(<<~SPARQL, graph: schema_graph)
        SELECT ?p WHERE { ?p #{rdf_type} #{owl_object} }
      SPARQL
      properties = result[:results].map { |r| r["p"] }
      expect(properties).to include("<mm:NormBook/norm_author_id>")
    end

    it "returns counts in the envelope" do
      env = Vv::Graph::Loader.normalize_schema!(include: %w[norm_authors norm_books])
      expect(env).to include(ok: true, schema_graph: schema_graph)
      expect(env[:classes]).to eq(2)
      expect(env[:object_properties]).to eq(1)
      expect(env[:datatype_properties]).to be >= 5
    end

    it "is idempotent — re-running clears and re-emits identical triples" do
      first  = Vv::Graph::Sparql.store_size(graph: schema_graph)[:count]
      Vv::Graph::Loader.normalize_schema!(include: %w[norm_authors norm_books])
      second = Vv::Graph::Sparql.store_size(graph: schema_graph)[:count]
      expect(second).to eq(first)
    end

    it "default-excludes ar_internal_metadata + schema_migrations" do
      Vv::Graph::Loader.normalize_schema!  # no include filter
      result = Vv::Graph::Sparql.select(<<~SPARQL, graph: schema_graph)
        SELECT ?c WHERE { ?c #{rdf_type} #{owl_class} }
      SPARQL
      classes = result[:results].map { |r| r["c"] }
      expect(classes).not_to include("<mm:ArInternalMetadatum>", "<mm:SchemaMigration>")
    end
  end

  describe "Schema.field interaction" do
    it "supports_closure: flips true once schema_normalized?" do
      before_fd = Vv::Graph::Schema.field(model: :NormBook, name: :title)
      expect(before_fd[:supports_closure]).to be(false)

      Vv::Graph::Loader.normalize_schema!(include: %w[norm_authors norm_books])

      after_fd = Vv::Graph::Schema.field(model: :NormBook, name: :title)
      expect(after_fd[:supports_closure]).to be(true)
    end
  end
end
