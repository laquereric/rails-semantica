# frozen_string_literal: true

require "spec_helper"
require "stringio"

# PLAN_0.7.0 Phase A + B — Semantica::EtherealGraph concern.
#
# These specs exercise the concern's logic against a minimal
# duck-typed attachment stub rather than booting Active Storage.
# Real Active Storage integration is the operator's responsibility
# — their AR model, the auto-registered `has_one_attached` (when
# AS is in their bundle), their AS service config. The concern
# only requires `semantica_graph_blob` to respond to `attached?`
# / `download` / `attach(io:, filename:, content_type:)` / `purge`.
class FakeBlobAttachment
  def initialize(initial_text: nil)
    @text = initial_text
  end

  def attached?
    !@text.nil?
  end

  def download
    @text
  end

  def attach(io:, filename:, content_type:)
    @text = io.read
    @filename = filename
    @content_type = content_type
  end

  def purge
    @text = nil
  end

  def byte_size
    @text.to_s.bytesize
  end
end

RSpec.describe Semantica::EtherealGraph do
  describe "module surface (pure Ruby)" do
    it "exposes the documented reason symbols" do
      expect(described_class::REASON_NO_BLOB).to eq(:no_blob)
      expect(described_class::REASON_ALREADY_HYDRATED).to eq(:already_hydrated)
      expect(described_class::REASON_EMPTY_BLOB).to eq(:empty_blob)
    end

    it "tracks hydrated IRIs in a thread-safe process-wide set" do
      described_class.reset!
      expect(described_class.hydrated?("urn:test:1")).to be(false)
      described_class.mark_hydrated!("urn:test:1")
      expect(described_class.hydrated?("urn:test:1")).to be(true)
      described_class.evict!("urn:test:1")
      expect(described_class.hydrated?("urn:test:1")).to be(false)
    end
  end

  describe Semantica::EtherealGraph::Recorder do
    it "captures the iri lambda" do
      r = described_class.new
      r.instance_eval do
        iri -> { "urn:test:foo" }
      end
      decl = r.finalize!
      expect(decl.iri_lambda.call).to eq("urn:test:foo")
      expect(decl.checkpoint_on).to eq(:explicit)
    end

    it "captures checkpoint_on :save" do
      r = described_class.new
      r.instance_eval do
        iri -> { "urn:test:bar" }
        checkpoint_on :save
      end
      decl = r.finalize!
      expect(decl.checkpoint_on).to eq(:save)
    end

    it "rejects an unknown checkpoint_on mode" do
      r = described_class.new
      expect {
        r.instance_eval { checkpoint_on :nightly_cron }
      }.to raise_error(ArgumentError, /checkpoint_on expects/)
    end

    it "raises if `iri` is missing" do
      r = described_class.new
      expect { r.finalize! }.to raise_error(ArgumentError, /requires `iri`/)
    end
  end

  describe ".parse_ntriples" do
    it "produces 4-tuple rows scoped to the graph IRI" do
      text = <<~NT
        <urn:s:1> <urn:p> "Alpha" .
        <urn:s:2> <urn:p> "Bravo" .
      NT
      rows = described_class.parse_ntriples(text, "urn:g:test")
      expect(rows).to eq([
        ["urn:s:1", "urn:p", '"Alpha"', "urn:g:test"],
        ["urn:s:2", "urn:p", '"Bravo"', "urn:g:test"],
      ])
    end

    it "skips blank lines and comment lines" do
      text = <<~NT

        # commentary
        <urn:s> <urn:p> "v" .

      NT
      rows = described_class.parse_ntriples(text, "urn:g:c")
      expect(rows.length).to eq(1)
    end

    it "strips angle brackets on IRI objects but preserves literals" do
      text = %(<urn:s> <urn:p> <urn:o> .\n<urn:s> <urn:p> "lit" .\n)
      rows = described_class.parse_ntriples(text, "urn:g:m")
      expect(rows.map { |r| r[2] }).to eq(["urn:o", '"lit"'])
    end
  end

  describe "round-trip against a live extension", :requires_extension do
    before(:each) do
      Semantica::Sparql.execute("CLEAR ALL")
      Semantica::EtherealGraph.reset!
    end

    # A POROesque host that mimics an AR record + AS attachment.
    # No AR / AS dependency; specs prove the concern's hydrate /
    # checkpoint / retract logic against a duck-typed attachment.
    let(:host_class) do
      Class.new do
        include ::Semantica::EtherealGraph

        attr_accessor :id

        ethereal_graph do
          iri -> { "urn:mm:host:#{id}:ctx" }
        end

        def initialize(id:, blob_text: nil)
          @id = id
          @fake_attachment = FakeBlobAttachment.new(initial_text: blob_text)
        end

        def semantica_graph_blob
          @fake_attachment
        end
      end
    end

    it "hydrates the attached blob into the named graph" do
      host = host_class.new(id: 1, blob_text: <<~NT)
        <urn:item:1> <schema:name> "Alpha" .
        <urn:item:2> <schema:name> "Bravo" .
      NT

      result = host.hydrate_ethereal_graph!
      expect(result[:ok]).to be(true)
      expect(result[:hydrated]).to eq(2)

      query = Semantica::Sparql.select(
        "SELECT ?o WHERE { ?s <schema:name> ?o }",
        graph: "urn:mm:host:1:ctx",
      )
      values = query[:results].map { |r| r["o"].delete('"') }
      expect(values).to contain_exactly("Alpha", "Bravo")
    end

    it "re-hydration is a no-op (HYDRATED_IRIS cache hit)" do
      host = host_class.new(id: 2, blob_text: %(<urn:x> <urn:p> "v" .\n))

      first  = host.hydrate_ethereal_graph!
      second = host.hydrate_ethereal_graph!

      expect(first).to  include(ok: true, hydrated: 1)
      expect(second).to include(ok: true, hydrated: 0, reason: :already_hydrated)
    end

    it "a record without an attached blob returns :no_blob and skips engine calls" do
      host = host_class.new(id: 3)

      execute_calls = 0
      bulk_calls = 0
      allow(Semantica::Sparql).to receive(:execute).and_wrap_original do |orig, *a, **kw|
        execute_calls += 1
        orig.call(*a, **kw)
      end
      allow(Semantica::Sparql).to receive(:bulk_insert).and_wrap_original do |orig, *a, **kw|
        bulk_calls += 1
        orig.call(*a, **kw)
      end

      result = host.hydrate_ethereal_graph!
      expect(result).to include(ok: true, hydrated: 0, reason: :no_blob)
      expect(execute_calls).to eq(0)
      expect(bulk_calls).to eq(0)
    end

    it "an empty / whitespace-only blob marks hydrated with :empty_blob" do
      host = host_class.new(id: 4, blob_text: "\n\n   \n")

      result = host.hydrate_ethereal_graph!
      expect(result).to include(ok: true, hydrated: 0, reason: :empty_blob)
      expect(Semantica::EtherealGraph.hydrated?(host.ethereal_graph_iri)).to be(true)
    end

    it "malformed blob refuses via bulk_insert envelope; IRI stays unhydrated" do
      # An empty subject string fails the engine's IRI parser; the
      # whole batch aborts.
      host = host_class.new(id: 5, blob_text: "<> <urn:p> \"bad\" .\n")

      result = host.hydrate_ethereal_graph!
      expect(result[:ok]).to be(false)
      expect(Semantica::EtherealGraph.hydrated?(host.ethereal_graph_iri)).to be(false)
    end

    # ── Phase B — checkpoint ─────────────────────────────────────

    it "checkpoint → evict → re-hydrate round-trips engine state" do
      host = host_class.new(id: 6)
      iri = host.ethereal_graph_iri

      Semantica::Sparql.execute(
        %(INSERT DATA { <urn:item:cp1> <schema:name> "Persisted" }),
        graph: iri,
      )

      cp = host.checkpoint_ethereal_graph!
      expect(cp[:ok]).to be(true)
      expect(cp[:written]).to be > 0
      expect(host.semantica_graph_blob.attached?).to be(true)

      Semantica::Sparql.execute("CLEAR GRAPH <#{iri}>")
      Semantica::EtherealGraph.evict!(iri)

      result = host.hydrate_ethereal_graph!
      expect(result[:ok]).to be(true)
      expect(result[:hydrated]).to be >= 1

      query = Semantica::Sparql.select(
        "SELECT ?o WHERE { <urn:item:cp1> <schema:name> ?o }",
        graph: iri,
      )
      values = query[:results].map { |r| r["o"].delete('"') }
      expect(values).to include("Persisted")
    end

    it "empty-graph checkpoint produces a 0-byte blob; re-hydrate is a no-op" do
      host = host_class.new(id: 7)
      iri = host.ethereal_graph_iri

      cp = host.checkpoint_ethereal_graph!
      expect(cp).to include(ok: true, written: 0)
      expect(host.semantica_graph_blob.attached?).to be(true)
      expect(host.semantica_graph_blob.byte_size).to eq(0)

      Semantica::EtherealGraph.evict!(iri)

      bulk_calls = 0
      allow(Semantica::Sparql).to receive(:bulk_insert).and_wrap_original do |orig, *a, **kw|
        bulk_calls += 1
        orig.call(*a, **kw)
      end

      result = host.hydrate_ethereal_graph!
      expect(result).to include(ok: true, hydrated: 0, reason: :empty_blob)
      expect(bulk_calls).to eq(0)
    end

    it "propagates a refusal envelope from Sparql.construct without touching the blob" do
      original_text = %(<urn:guard> <urn:p> "kept" .\n)
      host = host_class.new(id: 8, blob_text: original_text)

      refusal = { ok: false, reason: :extension_not_loaded, because: "stub" }
      allow(Semantica::Sparql).to receive(:construct).and_return(refusal)

      result = host.checkpoint_ethereal_graph!
      expect(result).to eq(refusal)
      expect(host.semantica_graph_blob.download).to eq(original_text)
    end
  end
end
