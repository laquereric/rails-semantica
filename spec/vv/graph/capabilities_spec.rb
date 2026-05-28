# frozen_string_literal: true

require "spec_helper"

# PLAN_0.13.0 Phase A — capability predicates.
RSpec.describe Vv::Graph, "capability predicates (Phase A)" do
  describe ".rdf_star_writes_enabled?" do
    it "returns a Boolean" do
      expect([true, false]).to include(described_class.rdf_star_writes_enabled?)
    end

    it "tracks whether Sparql.quoted_triple is defined (PLAN_0.8.0 Phase B)" do
      # At v0.13.0 release: PLAN_0.8.0 Phase B not yet landed, so
      # Sparql.quoted_triple is undefined → predicate is false.
      defined_in_facade = Vv::Graph::Sparql.respond_to?(:quoted_triple)
      expect(described_class.rdf_star_writes_enabled?).to eq(defined_in_facade)
    end
  end

  describe ".facade_version" do
    it "returns a String parseable by Gem::Version" do
      v = described_class.facade_version
      expect(v).to be_a(String)
      expect { Gem::Version.new(v) }.not_to raise_error
    end

    it "matches Vv::Graph::VERSION at v0.13.0 release" do
      expect(described_class.facade_version).to eq(Vv::Graph::VERSION)
    end

    it "compares correctly against a known prior version via Gem::Version" do
      expect(Gem::Version.new(described_class.facade_version))
        .to be >= Gem::Version.new("0.7.0")
    end
  end

  describe ".checkpoint_can_round_trip?" do
    it "returns true for :plain_ntriples (shipped in v0.7.0)" do
      expect(described_class.checkpoint_can_round_trip?(content_kind: :plain_ntriples))
        .to be(true)
    end

    it "returns true|false for :ntriples_star (flips on once Phase B ships)" do
      result = described_class.checkpoint_can_round_trip?(content_kind: :ntriples_star)
      expect([true, false]).to include(result)
    end

    it "raises ArgumentError for an unknown content_kind" do
      expect {
        described_class.checkpoint_can_round_trip?(content_kind: :nope)
      }.to raise_error(ArgumentError, /content_kind/)
    end

    it "pins the known content_kinds list" do
      expect(Vv::Graph::CHECKPOINT_CONTENT_KINDS).to eq(%i[plain_ntriples ntriples_star])
    end
  end

  describe ".sparql_method_available?" do
    # PLAN_0.19.0 — CR-VVZ B2. Predicate over the SPARQL facade so
    # VVZ's tool catalogue can filter without reaching into
    # Sparql.respond_to? from consumer code.
    %i[select ask construct execute].each do |name|
      it "returns true for the four-method facade entry :#{name}" do
        expect(described_class.sparql_method_available?(name)).to be(true)
      end
    end

    it "accepts String input (coerced via to_sym)" do
      expect(described_class.sparql_method_available?("select")).to be(true)
    end

    it "returns false for an unknown facade method" do
      expect(described_class.sparql_method_available?(:nope_not_a_method)).to be(false)
    end
  end
end
