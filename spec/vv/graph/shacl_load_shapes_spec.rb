# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# PLAN_0.17.0 Phase C — Vv::Graph::Shacl.load_shapes.
#
# Tagged :requires_extension since loading routes through
# `rdf_load_turtle_to_graph` / `Sparql.execute`.
RSpec.describe Vv::Graph::Shacl, "#load_shapes", :requires_extension do
  let(:shapes_graph) { "urn:vv-graph:shapes" }
  let(:meta_graph)   { "urn:vv-graph:shapes:meta" }

  let(:turtle_body) do
    <<~TTL
      @prefix sh:   <http://www.w3.org/ns/shacl#> .
      @prefix mm:   <http://example.org/mm#> .

      mm:ProductShape a sh:NodeShape ;
        sh:targetClass mm:Product ;
        sh:property [
          sh:path     mm:sku ;
          sh:minCount 1 ;
        ] .
    TTL
  end

  let(:ntriples_body) do
    <<~NT
      <urn:shapes:NT:1> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/shacl#NodeShape> .
      <urn:shapes:NT:1> <http://www.w3.org/ns/shacl#targetClass> <http://example.org/mm#WidgetNT> .
    NT
  end

  describe "REASON_* constants" do
    it "pins the v0.17.0 reason symbols" do
      expect(described_class::REASON_SHAPES_FILE_MISSING).to   eq(:shapes_file_missing)
      expect(described_class::REASON_SHAPES_FORMAT_UNKNOWN).to eq(:shapes_format_unknown)
      expect(described_class::REASON_SHAPES_PARSE_ERROR).to    eq(:shapes_parse_error)
    end
  end

  describe "format dispatch" do
    it "refuses :json with :shapes_format_unknown" do
      env = described_class.load_shapes("anything", format: :json)
      expect(env).to include(ok: false, reason: :shapes_format_unknown)
    end

    it "refuses a missing file path with :shapes_file_missing" do
      env = described_class.load_shapes("./nope.ttl", format: :ttl)
      expect(env).to include(ok: false, reason: :shapes_file_missing)
    end
  end

  describe "Turtle loading" do
    before { Vv::Graph::Sparql.execute("CLEAR GRAPH <#{shapes_graph}>") }
    before { Vv::Graph::Sparql.execute("CLEAR GRAPH <#{meta_graph}>") }

    it "loads turtle into the default shapes scope" do
      env = described_class.load_shapes(turtle_body, format: :ttl)
      expect(env).to include(ok: true, scope: shapes_graph)
      expect(env[:loaded]).to be > 0
    end

    it "round-trips via SELECT" do
      described_class.load_shapes(turtle_body, format: :ttl)
      result = Vv::Graph::Sparql.select(<<~SPARQL, graph: shapes_graph)
        SELECT ?s WHERE { ?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/shacl#NodeShape> }
      SPARQL
      expect(result[:results]).not_to be_empty
    end

    it "is idempotent — second load returns loaded: 0, reason: :unchanged" do
      first = described_class.load_shapes(turtle_body, format: :ttl)
      expect(first[:loaded]).to be > 0
      second = described_class.load_shapes(turtle_body, format: :ttl)
      expect(second).to include(ok: true, loaded: 0, reason: :unchanged)
    end

    it "re-loads when content changes" do
      described_class.load_shapes(turtle_body, format: :ttl)
      changed = turtle_body + "\nmm:ExtraShape a <http://www.w3.org/ns/shacl#NodeShape> .\n"
      env = described_class.load_shapes(changed, format: :ttl)
      expect(env).to include(ok: true)
      expect(env[:loaded]).to be > 0
      expect(env).not_to include(reason: :unchanged)
    end

    it "accepts a file path" do
      file = Tempfile.new(["shape", ".ttl"])
      begin
        file.write(turtle_body); file.flush
        env = described_class.load_shapes(file.path, format: :ttl)
        expect(env).to include(ok: true)
        expect(env[:loaded]).to be > 0
      ensure
        file.close!
      end
    end

    it "honours a custom scope: kwarg" do
      env = described_class.load_shapes(turtle_body, format: :ttl, scope: "urn:custom:shapes:product")
      expect(env).to include(ok: true, scope: "urn:custom:shapes:product")
    end
  end

  describe "N-triples loading" do
    before { Vv::Graph::Sparql.execute("CLEAR GRAPH <#{shapes_graph}>") }
    before { Vv::Graph::Sparql.execute("CLEAR GRAPH <#{meta_graph}>") }

    it "loads an NT body" do
      env = described_class.load_shapes(ntriples_body, format: :nt)
      expect(env).to include(ok: true)
      expect(env[:loaded]).to be > 0
    end

    it "skips blank lines + comments" do
      body = "# top comment\n\n#{ntriples_body}\n# trailing\n"
      env = described_class.load_shapes(body, format: :nt)
      expect(env).to include(ok: true)
    end
  end
end
