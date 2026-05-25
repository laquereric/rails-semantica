# frozen_string_literal: true

require "spec_helper"

# PLAN_0.9.0 Phase B — OWL 2 RL rule library + iteration loop.
#
# Two layers:
#   1. Per-rule round-trip — each rule, against a minimal fixture
#      exercising its triggering pattern, produces the expected
#      inferred triple.
#   2. Iteration semantics — fixpoint termination across the full
#      rule set, max_iterations guard, per-rule count tracking.
RSpec.describe Vv::Graph::Reasoner, "OWL 2 RL Phase B", :requires_extension do
  let(:asserted) { "urn:test:asserted" }
  let(:inferred) { "urn:test:inferred" }

  def insert_data(triples)
    # bulk_insert with explicit angle-bracketed IRIs in the object
    # column. The gem's TermSerializer.object treats bare strings
    # as literals by design (Storable's Name → "Name" literal
    # contract); reasoner fixtures need IRI objects everywhere
    # (subClassOf, type, etc. all point at class IRIs), so wrap.
    rows = triples.map { |s, p, o| [s, p, "<#{o}>", asserted] }
    r = Vv::Graph::Sparql.bulk_insert(rows)
    raise "fixture bulk_insert failed: #{r.inspect}" unless r[:ok]
  end

  def inferred_triples(predicate: nil)
    pattern = predicate ? "?s <#{predicate}> ?o" : "?s ?p ?o"
    r = Vv::Graph::Sparql.select("SELECT * WHERE { #{pattern} }", graph: inferred)
    raise "SELECT against inferred graph failed" unless r[:ok]
    r[:results].map { |row| [row["s"], row["p"] || "<#{predicate}>", row["o"]] }
  end

  # rdfs / rdf / owl URI shorthands used by the fixtures
  SUBCLASS_OF      = "http://www.w3.org/2000/01/rdf-schema#subClassOf"
  SUBPROPERTY_OF   = "http://www.w3.org/2000/01/rdf-schema#subPropertyOf"
  RDFS_DOMAIN      = "http://www.w3.org/2000/01/rdf-schema#domain"
  RDFS_RANGE       = "http://www.w3.org/2000/01/rdf-schema#range"
  RDF_TYPE         = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  OWL_EQ_CLASS     = "http://www.w3.org/2002/07/owl#equivalentClass"
  OWL_EQ_PROP      = "http://www.w3.org/2002/07/owl#equivalentProperty"
  OWL_INVERSE_OF   = "http://www.w3.org/2002/07/owl#inverseOf"
  OWL_TRANSITIVE   = "http://www.w3.org/2002/07/owl#TransitiveProperty"
  OWL_SYMMETRIC    = "http://www.w3.org/2002/07/owl#SymmetricProperty"
  OWL_FUNCTIONAL   = "http://www.w3.org/2002/07/owl#FunctionalProperty"
  OWL_SAME_AS      = "http://www.w3.org/2002/07/owl#sameAs"

  # -------- Per-rule round-trip specs --------

  it "scm-sco — transitive subClassOf" do
    insert_data [
      ["urn:A", SUBCLASS_OF, "urn:B"],
      ["urn:B", SUBCLASS_OF, "urn:C"],
    ]
    r = described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(r[:ok]).to be(true)
    expect(r[:per_rule]["scm-sco"]).to be >= 1
    expect(inferred_triples(predicate: SUBCLASS_OF))
      .to include(["<urn:A>", "<#{SUBCLASS_OF}>", "<urn:C>"])
  end

  it "scm-spo — transitive subPropertyOf" do
    insert_data [
      ["urn:p1", SUBPROPERTY_OF, "urn:p2"],
      ["urn:p2", SUBPROPERTY_OF, "urn:p3"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: SUBPROPERTY_OF))
      .to include(["<urn:p1>", "<#{SUBPROPERTY_OF}>", "<urn:p3>"])
  end

  it "scm-eqc1 — equivalentClass unfolds to mutual subClassOf" do
    insert_data [["urn:A", OWL_EQ_CLASS, "urn:B"]]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    derived = inferred_triples(predicate: SUBCLASS_OF)
    expect(derived).to include(["<urn:A>", "<#{SUBCLASS_OF}>", "<urn:B>"])
    expect(derived).to include(["<urn:B>", "<#{SUBCLASS_OF}>", "<urn:A>"])
  end

  it "scm-eqp1 — equivalentProperty unfolds to mutual subPropertyOf" do
    insert_data [["urn:p1", OWL_EQ_PROP, "urn:p2"]]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    derived = inferred_triples(predicate: SUBPROPERTY_OF)
    expect(derived).to include(["<urn:p1>", "<#{SUBPROPERTY_OF}>", "<urn:p2>"])
    expect(derived).to include(["<urn:p2>", "<#{SUBPROPERTY_OF}>", "<urn:p1>"])
  end

  it "cax-sco — rdf:type propagates via subClassOf" do
    insert_data [
      ["urn:x", RDF_TYPE,    "urn:Detective"],
      ["urn:Detective", SUBCLASS_OF, "urn:Person"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: RDF_TYPE))
      .to include(["<urn:x>", "<#{RDF_TYPE}>", "<urn:Person>"])
  end

  it "prp-spo1 — predicate propagates via subPropertyOf" do
    insert_data [
      ["urn:x", "urn:hasFather", "urn:y"],
      ["urn:hasFather", SUBPROPERTY_OF, "urn:hasParent"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: "urn:hasParent"))
      .to include(["<urn:x>", "<urn:hasParent>", "<urn:y>"])
  end

  it "prp-dom — rdfs:domain entailment" do
    insert_data [
      ["urn:hasFather", RDFS_DOMAIN, "urn:Person"],
      ["urn:x", "urn:hasFather", "urn:y"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: RDF_TYPE))
      .to include(["<urn:x>", "<#{RDF_TYPE}>", "<urn:Person>"])
  end

  it "prp-rng — rdfs:range entailment" do
    insert_data [
      ["urn:hasFather", RDFS_RANGE, "urn:Man"],
      ["urn:x", "urn:hasFather", "urn:y"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: RDF_TYPE))
      .to include(["<urn:y>", "<#{RDF_TYPE}>", "<urn:Man>"])
  end

  it "prp-trp — TransitiveProperty derives the transitive closure" do
    insert_data [
      ["urn:partOf", RDF_TYPE, OWL_TRANSITIVE],
      ["urn:finger", "urn:partOf", "urn:hand"],
      ["urn:hand",   "urn:partOf", "urn:arm"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: "urn:partOf"))
      .to include(["<urn:finger>", "<urn:partOf>", "<urn:arm>"])
  end

  it "prp-symp — SymmetricProperty derives the reverse" do
    insert_data [
      ["urn:knows", RDF_TYPE, OWL_SYMMETRIC],
      ["urn:alice", "urn:knows", "urn:bob"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: "urn:knows"))
      .to include(["<urn:bob>", "<urn:knows>", "<urn:alice>"])
  end

  it "prp-inv1 + prp-inv2 — inverseOf bidirectional" do
    insert_data [
      ["urn:hasFather", OWL_INVERSE_OF, "urn:fatherOf"],
      ["urn:alice", "urn:hasFather", "urn:bob"],
      ["urn:charlie", "urn:fatherOf",  "urn:dave"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: "urn:fatherOf"))
      .to include(["<urn:bob>", "<urn:fatherOf>", "<urn:alice>"])
    expect(inferred_triples(predicate: "urn:hasFather"))
      .to include(["<urn:dave>", "<urn:hasFather>", "<urn:charlie>"])
  end

  it "prp-fp — FunctionalProperty derives owl:sameAs" do
    insert_data [
      ["urn:hasGtin", RDF_TYPE, OWL_FUNCTIONAL],
      ["urn:product1", "urn:hasGtin", "urn:gtin-A"],
      ["urn:product1", "urn:hasGtin", "urn:gtin-B"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    expect(inferred_triples(predicate: OWL_SAME_AS))
      .to include(["<urn:gtin-A>", "<#{OWL_SAME_AS}>", "<urn:gtin-B>"])
  end

  it "eq-sym + eq-trans — owl:sameAs symmetric + transitive" do
    insert_data [
      ["urn:a", OWL_SAME_AS, "urn:b"],
      ["urn:b", OWL_SAME_AS, "urn:c"],
    ]
    described_class.materialise!(asserted: asserted, inferred: inferred)
    same_as = inferred_triples(predicate: OWL_SAME_AS)
    expect(same_as).to include(["<urn:b>", "<#{OWL_SAME_AS}>", "<urn:a>"])  # eq-sym
    expect(same_as).to include(["<urn:a>", "<#{OWL_SAME_AS}>", "<urn:c>"])  # eq-trans
  end

  # -------- Iteration semantics --------

  describe "iteration loop" do
    it "reaches fixpoint and reports per-rule deltas" do
      insert_data [
        ["urn:A", SUBCLASS_OF, "urn:B"],
        ["urn:B", SUBCLASS_OF, "urn:C"],
        ["urn:C", SUBCLASS_OF, "urn:D"],
        ["urn:x", RDF_TYPE,    "urn:A"],
      ]
      r = described_class.materialise!(asserted: asserted, inferred: inferred)
      expect(r[:ok]).to be(true)
      expect(r[:fixpoint]).to be(true)
      expect(r[:iterations]).to be >= 1
      expect(r[:derived]).to be > 0
      expect(r[:per_rule]).to be_a(Hash)
      expect(r[:per_rule]["scm-sco"]).to be >= 1
      expect(r[:per_rule]["cax-sco"]).to be >= 1
    end

    it "is idempotent — a second materialise! is a no-op" do
      insert_data [
        ["urn:A", SUBCLASS_OF, "urn:B"],
        ["urn:x", RDF_TYPE,    "urn:A"],
      ]
      described_class.materialise!(asserted: asserted, inferred: inferred)
      r2 = described_class.materialise!(asserted: asserted, inferred: inferred)
      expect(r2[:ok]).to be(true)
      expect(r2[:derived]).to eq(0)
      expect(r2[:fixpoint]).to be(true)
    end

    it "honours an empty asserted graph by fixpointing immediately" do
      r = described_class.materialise!(asserted: asserted, inferred: inferred)
      expect(r).to include(ok: true, derived: 0, fixpoint: true)
    end

    it "refuses with :reasoner_diverged when max_iterations is too low" do
      # Build a 5-deep subClassOf chain. The transitive closure
      # needs multiple iterations to find ?A subClassOf ?E.
      insert_data [
        ["urn:A", SUBCLASS_OF, "urn:B"],
        ["urn:B", SUBCLASS_OF, "urn:C"],
        ["urn:C", SUBCLASS_OF, "urn:D"],
        ["urn:D", SUBCLASS_OF, "urn:E"],
      ]
      r = described_class.materialise!(
        asserted:       asserted,
        inferred:       inferred,
        max_iterations: 1,
      )
      expect(r[:ok]).to be(false)
      expect(r[:reason]).to eq(:reasoner_diverged)
      expect(r[:iterations]).to eq(1)
      expect(r[:because]).to include("fixpoint not reached")
    end
  end

  # -------- Rule library shape --------

  describe "Rules::OwlRl library" do
    it "contains the Phase B core subset of 15 rules" do
      ids = Vv::Graph::Reasoner::Rules::OwlRl.map(&:id)
      expect(ids).to contain_exactly(
        "scm-sco", "scm-spo", "scm-eqc1", "scm-eqp1",
        "cax-sco", "prp-spo1", "prp-dom", "prp-rng",
        "prp-trp", "prp-symp", "prp-inv1", "prp-inv2", "prp-fp",
        "eq-sym", "eq-trans",
      )
    end

    it "names the W3C OWL 2 RL/RDF rules deferred to Phase B.1" do
      expect(Vv::Graph::Reasoner::Rules::PHASE_B_PENDING).to include(
        "eq-ref", "prp-key", "prp-ifp",
        "cls-int1", "cls-svf1", "cls-hv1", "cls-maxc1",
        "cax-dw", "scm-cls", "dt-type1",
      )
    end
  end
end
