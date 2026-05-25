# frozen_string_literal: true

require "spec_helper"

# PLAN_0.13.0 Phase B — `EtherealGraph.parse_ntriples` N-Triples-star
# round-trip. Closes CONSUMER_REQUIREMENT_VV.md B1.
#
# Two layers:
#   1. `Sparql.split_ntriple` tokenizer — handles `<< s p o >>` as a
#      single token in subject and object position; nesting works.
#   2. End-to-end via EtherealGraph: blob with quoted-triple content
#      → checkpoint → evict → re-hydrate → triples survive.
RSpec.describe "N-Triples-star round-trip (PLAN_0.13.0 Phase B)" do
  describe "Sparql.split_ntriple" do
    it "recognises `<< s p o >>` in subject position as a single token" do
      result = Vv::Graph::Sparql.send(
        :split_ntriple,
        '<< <urn:s> <urn:p> <urn:o> >> <urn:reportedBy> <urn:Watson>',
      )
      expect(result).to eq([
        '<< <urn:s> <urn:p> <urn:o> >>',
        '<urn:reportedBy>',
        '<urn:Watson>',
      ])
    end

    it "recognises `<< s p o >>` in object position" do
      result = Vv::Graph::Sparql.send(
        :split_ntriple,
        '<urn:Watson> <urn:asserted> << <urn:s> <urn:p> <urn:o> >>',
      )
      expect(result).to eq([
        '<urn:Watson>',
        '<urn:asserted>',
        '<< <urn:s> <urn:p> <urn:o> >>',
      ])
    end

    it "handles nested quoted triples (depth ≥ 2)" do
      result = Vv::Graph::Sparql.send(
        :split_ntriple,
        '<< << <urn:s> <urn:p> <urn:o> >> <urn:meta> <urn:m> >> <urn:reportedBy> <urn:W>',
      )
      expect(result).to eq([
        '<< << <urn:s> <urn:p> <urn:o> >> <urn:meta> <urn:m> >>',
        '<urn:reportedBy>',
        '<urn:W>',
      ])
    end

    it "passes through plain N-Triples (no `<<`) unchanged" do
      result = Vv::Graph::Sparql.send(
        :split_ntriple,
        '<urn:s> <urn:p> "literal value"',
      )
      expect(result).to eq(['<urn:s>', '<urn:p>', '"literal value"'])
    end

    it "returns nil on unbalanced `<<` (no closing `>>`)" do
      result = Vv::Graph::Sparql.send(
        :split_ntriple,
        '<< <urn:s> <urn:p> <urn:o> <urn:p> <urn:o>',
      )
      expect(result).to be_nil
    end
  end

  describe "EtherealGraph hydrate of N-Triples-star content", :requires_extension do
    let(:test_class) do
      Class.new do
        include Vv::Graph::EtherealGraph

        attr_reader :id, :vv_graph_blob

        def initialize(id, blob_attachment)
          @id = id
          @vv_graph_blob = blob_attachment
        end

        ethereal_graph do
          iri -> { "urn:test:scope:#{id}" }
        end

        def self.name
          "EtherealStarRoundTripTestModel"
        end
      end
    end

    # Duck-typed blob attachment matching the PLAN_0.7.0 Phase A
    # FakeBlobAttachment in the existing ethereal_graph_spec.
    let(:fake_blob_class) do
      Class.new do
        attr_reader :content
        def initialize(content = nil); @content = content; end
        def attached?; !@content.nil?; end
        def download; @content; end
        def purge; @content = nil; end
        def attach(io:, **); @content = io.is_a?(String) ? io : io.read; end
      end
    end

    it "round-trips a blob containing quoted-triple subjects through hydrate" do
      blob_content = [
        # Plain triple (sanity)
        "<urn:plain> <urn:p> <urn:o> .",
        # Quoted-triple subject (the Conformer-emitted shape)
        "<< <urn:p1> <urn:gtin> <urn:1234567890123> >> <urn:reportedBy> <urn:user42> .",
        # Quoted-triple object
        "<urn:Watson> <urn:asserted> << <urn:s2> <urn:p2> <urn:o2> >> .",
      ].join("\n")

      blob = fake_blob_class.new.tap { |b| b.attach(io: blob_content) }
      record = test_class.new(99, blob)

      result = record.hydrate_ethereal_graph!
      expect(result[:ok]).to be(true)
      expect(result[:hydrated]).to eq(3)

      # All three triples queryable in the scope's graph
      size = Vv::Graph::Sparql.store_size(graph: "urn:test:scope:99")
      expect(size[:count]).to eq(3)

      # Specifically: the quoted-triple-subject statement survives
      meta_query = Vv::Graph::Sparql.select(
        'SELECT ?u WHERE { << <urn:p1> <urn:gtin> <urn:1234567890123> >> <urn:reportedBy> ?u }',
        graph: "urn:test:scope:99",
      )
      expect(meta_query[:ok]).to be(true)
      expect(meta_query[:results]).to contain_exactly("u" => "<urn:user42>")

      Vv::Graph::EtherealGraph.evict!("urn:test:scope:99")
    end
  end

  describe "Vv::Graph.checkpoint_can_round_trip?(:ntriples_star)" do
    it "now returns true (Phase B flipped the capability)" do
      expect(Vv::Graph.checkpoint_can_round_trip?(content_kind: :ntriples_star)).to be(true)
    end
  end
end
