# PLAN_0.9.0 — `rails-semantica` OWL reasoning (OWL 2 RL materialisation)

> *Picks up the fourth rung from `docs/research/TripesQuadsEtc.md`.
> Triples (0.1.0), quads (0.5.0 / 0.7.0), RDF-star (0.8.0) all
> answered "what do we **know**?" — provenance, scope, attribution.
> OWL answers "what can we **conclude**?" — class membership,
> property characteristics, equivalences, hierarchies. Oxigraph
> ships no DL reasoner, so v0.9.0 takes the operationally-realistic
> path: implement the **OWL 2 RL profile** as forward-chaining
> SPARQL UPDATE rules, materialise inferred triples into a
> dedicated named graph, attach RDF-star provenance to each
> derivation. Full DL classification (T-Box reasoning beyond OWL 2
> RL, SAT/tableau-based consistency checking, ABox realisation
> with negation) is **out of scope** — that needs a real reasoner
> (HermiT / Pellet / FaCT++ via JNI, or RDFox) and a substantial
> dependency decision the gem won't make unilaterally.*

## Current state

**Draft (not yet started).** v0.8.0 is the immediate predecessor —
RDF-star is the substrate v0.9.0's provenance-on-inferred-triples
rides on. v0.9.0 cannot start in earnest until v0.8.0 ships, but
the plan can land in parallel so the substrate-side consumer
(MM's Conformer + reasoner subagent) sees the shape early.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `docs/research/TripesQuadsEtc.md` | this repo | The motivating sketch's fourth rung. Frames OWL as the boundary between **storing** facts and **reasoning** about them. The "Anyone investigating a case is a detective" / "A case has exactly one culprit" examples are the v0.9.0 motivating shape. |
| `PLAN_0.8.0.md` | this dir | RDF-star. v0.9.0 annotates every inferred triple with `<< s p o >> :derivedBy :Rule_scm-sco ; :derivedAt "…" ; :derivedFrom << :a rdfs:subClassOf :b >> .`. The annotation shorthand is the v0.9.0 provenance surface. |
| `PLAN_0.5.0.md` | this dir | Named graphs. v0.9.0 materialises into a sibling graph per scope (`urn:mm:graph:<scope>:inferred`) so the inferred closure is distinguishable from the asserted base — and retractable in one CLEAR GRAPH. |
| `PLAN_0.7.0.md` | this dir | EtherealGraph. The inferred graph composes with EtherealGraph the same way an asserted one does — operators can persist a materialised closure across restarts or treat it as recomputable. |
| `PLAN_0.3.0.md` | this dir | `sparql_update` arbitrary-UPDATE path. Every OWL 2 RL rule is a SPARQL UPDATE `INSERT … WHERE …` form — no new engine surface needed. |
| W3C OWL 2 Profiles (Second Edition, 2012) | spec | The OWL 2 RL profile that v0.9.0 implements. The "Reasoning in OWL 2 RL and RDF Graphs using Rules" section enumerates the rule set verbatim — v0.9.0's `Reasoner::Rules` is a faithful Ruby/SPARQL transcription of that table. |
| MM-side reasoner research note | MM repo | **TBD** — companion to `magentic-market-ai/docs/research/StarExts.md`. v0.9.0's gotchas / scope decisions should land in an MM-side primer the way v0.8.0's did. Open question for MM: where does the reasoner subagent live, and what does it call into? |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Drift target. v0.9.0 adds `Semantica::Reasoner` surface block once MM signals adoption. |

## Engine prerequisites (sqlite-sparql ≥ 0.9.1) — **already satisfied**

Every OWL 2 RL rule is a SPARQL UPDATE form (`INSERT { … } WHERE
{ … }`) that already routes through `sparql_update` (PLAN_0.3.0).
RDF-star annotations on inferred triples ride the v0.8.0 surface.
Named-graph scoping for the materialised closure rides PLAN_0.5.0.

### Per-rule vs. native (engine-side) execution

Two implementation shapes are live as of engine v0.9.1; pick at
Phase B time:

1. **Per-rule (default — ships in v0.9.0 Phase B).** `materialise!`
   iterates rules and issues one `Sparql.execute` per rule per
   fixpoint iteration. N rules × M iterations = N×M FFI crossings
   + N×M SQL parses + N×M SPARQL parses. Simplest to reason
   about; honest about cost; the natural shape for small rule
   sets (the 15-rule `Rules::OwlRl` library).

2. **Native engine pass (opt-in, engine v0.9.1).** `materialise!`
   delegates to `Sparql.execute("SELECT rdf_owl_rl_materialise(?, ?, ?)")`
   — one FFI crossing per materialise call. The engine walks
   the Oxigraph store directly per rule, skipping the SPARQL
   parser per rule. Engine-side rule coverage matches gem-side
   `Rules::OwlRl` exactly (the engine equivalence test pins
   this), so both paths produce identical inferred graphs. The
   engine emits the same `:derivedBy <urn:semantica:rule:scm-sco> ;
   :derivedAt …` RDF-star annotations the gem does (engine
   defaults match VG's convention; overridable via the
   options-JSON if needed).

The two paths produce identical asserted graphs + identical
RDF-star annotations — the equivalence is pinned by the engine's
`test_rdf_owl_rl_materialise_equivalence_with_vg` test and
mirror-pinned by a planned gem-side cross-path spec.

Phase B ships the per-rule path; a later phase (gated on
telemetry from MM) adds the native opt-in. The engine surface is
ready today; gem-side adoption waits for a concrete bottleneck
signal per VG's posture on the engine's "Requested extensions"
section.

If MM-side telemetry someday shows the native pass isn't enough
(e.g., a multi-million-triple closure needs incremental
recomputation), a further engine-level horizon is still on the
table:

- **Differential/incremental reasoning.** Maintain a delta-based
  inference index so adding a triple recomputes only the
  affected closure slice. Substantial engine work
  (PLAN_0.12.0-equivalent on the engine side, plus more). ABox-
  only forward-chaining over OWL 2 RL doesn't need it for the
  sizes MM is likely to hit; revive when telemetry says
  otherwise. The engine CR (`sqlite-sparql/CONSUMER_REQUIREMENT_VvGraph.md`
  item #10) names this as "genuinely out-of-reach for incremental
  engine work" — engine-side substrate is missing.

## Why OWL 2 RL (and not full OWL DL)

The research doc shows the OWL-DL "Manchester syntax" examples —
`Class: Detective EquivalentTo: Person and investigates some Case`.
Implementing that fully needs tableau reasoning (HermiT, Pellet,
FaCT++) which is a research-grade Java/C++ dependency the gem
won't take on. **OWL 2 RL** is the W3C-blessed pragmatic subset:

- Forward-chaining only — every entailment is a finite rule
  application.
- Implementable in any rule engine, including SPARQL UPDATE
  (the W3C published the rule set in this form).
- Covers the constructs operators actually reach for: class
  hierarchies, property hierarchies, domain/range, inverse /
  transitive / symmetric / functional / inverse-functional
  properties, sameAs propagation, equivalence (subClassOf both
  ways), `someValuesFrom` / `allValuesFrom` (limited), key
  axioms.
- **Excludes** what makes DL hard: `not` (complement classes),
  cardinality restrictions other than 0 / 1 in specific
  positions, full `someValuesFrom` over disjunctions,
  classification (computing the class hierarchy from a T-Box
  that isn't already explicit).

For MM's domain — product/category/agent ontologies with explicit
class hierarchies, transitive `partOf`-style relations, symmetric
`knows`-style relations, functional `hasGtin` keys — OWL 2 RL is
the right ceiling. Anything past it is out-of-scope.

## Gem-side scope

### Phase A — `Semantica::Reasoner` facade

The single entry point. Idempotent forward-chaining pass over an
asserted graph; emits the closure into a paired named graph.

```ruby
Semantica::Reasoner.materialise!(
  asserted:    "urn:mm:graph:catalogue",
  inferred:    "urn:mm:graph:catalogue:inferred",
  rules:       :owl_2_rl,             # or a custom RuleSet
  provenance:  true,                  # RDF-star annotations on each derivation
  max_iterations: 50,                 # fixpoint guard
)
# => { ok: true,
#      iterations: 7,
#      derived:    1842,
#      fixpoint:   true }
```

#### Implementation
- `Semantica::Reasoner` is a module facade following the
  `Semantica::Sparql` pattern (never raises; structured
  envelopes).
- `materialise!`:
  1. Validate inputs — both `asserted:` and `inferred:`
     must be non-blank-node IRIs; refuse `:invalid_graph`
     otherwise. `asserted:` and `inferred:` must differ;
     refuse `:invalid_dsl` if same (the closure would loop
     trivially).
  2. Resolve `rules:` — a symbol like `:owl_2_rl` looks up
     `Semantica::Reasoner::Rules::OwlRl`; a `RuleSet`
     instance passes through.
  3. Iterate: for each rule, issue the `INSERT … WHERE …`
     against `Sparql.execute` scoping the read side with
     `FROM <asserted> FROM <inferred> FROM NAMED <asserted>
     FROM NAMED <inferred>` (so rules can read from either
     graph and write only to inferred). Track `count:` per
     rule.
  4. Fixpoint when no rule inserts anything new in a full
     pass, or `max_iterations` hits (return
     `fixpoint: false` then so callers can spot
     non-termination).
  5. Return envelope.
- `provenance: true` wraps each rule's INSERT in the v0.8.0
  RDF-star annotation form — see Phase E below.

#### Refusal envelope additions
- `:invalid_graph` — pre-existing.
- `:invalid_dsl` — asserted/inferred collision.
- `:rule_set_unknown` — symbol that doesn't resolve.
- `:reasoner_diverged` — `max_iterations` hit without fixpoint;
  envelope includes `iterations:` so callers can re-run with a
  higher cap.

#### Exit criteria
- Spec: a graph with `:a rdfs:subClassOf :b` + `:b rdfs:subClassOf :c`
  + `:x rdf:type :a` materialises `:x rdf:type :b` and
  `:x rdf:type :c` into the inferred graph.
- Spec: rerunning `materialise!` on the same input is a no-op
  (the closure is idempotent — every INSERT that would re-derive
  an existing triple lands as a 0-delta on `Sparql.execute`).
- Spec: a deliberately-broken rule set that diverges hits
  `max_iterations` and returns `:reasoner_diverged`.

### Phase B — Rule library: OWL 2 RL transcribed to SPARQL UPDATE

The W3C OWL 2 Profiles document publishes the OWL 2 RL rule
table in a form that's almost-but-not-quite SPARQL. v0.9.0's
`Rules::OwlRl` is a faithful, named, individually-testable
transcription of those rules into SPARQL UPDATE `INSERT … WHERE …`
forms.

#### Rule organisation
Each rule is a `Semantica::Reasoner::Rule` value object:

```ruby
Semantica::Reasoner::Rule.new(
  id:    "scm-sco",                              # OWL 2 RL rule ID
  name:  "Transitive subClassOf",
  description: "If ?c1 rdfs:subClassOf ?c2 and ?c2 rdfs:subClassOf ?c3, then ?c1 rdfs:subClassOf ?c3.",
  sparql: <<~SPARQL,
    INSERT { ?c1 rdfs:subClassOf ?c3 }
    WHERE  { ?c1 rdfs:subClassOf ?c2 . ?c2 rdfs:subClassOf ?c3 . }
  SPARQL
)
```

A `RuleSet` is an ordered collection of `Rule`s. `Rules::OwlRl`
holds the W3C-defined ~70-rule set, organised by section:

- **prp-** prefix — property-axiom rules (subPropertyOf, domain,
  range, inverse, symmetric, transitive, functional,
  inverse-functional, sameAs propagation, equivalentProperty).
- **cls-** prefix — class-axiom rules (subClassOf,
  equivalentClass, someValuesFrom, allValuesFrom-limited,
  hasValue, oneOf, hasKey, intersectionOf, unionOf, disjointWith).
- **cax-** prefix — class-assertion rules (rdf:type
  propagation).
- **scm-** prefix — schema rules (T-Box transitive closure).
- **eq-** prefix — equality rules (sameAs, differentFrom,
  AllDifferent).
- **dt-** prefix — datatype reasoning (only the trivial cases
  expressible in SPARQL UPDATE; full datatype reasoning needs
  a DL reasoner).

#### Implementation
- `Semantica::Reasoner::Rule` — frozen value object.
- `Semantica::Reasoner::RuleSet` — ordered enumerable; supports
  `each_rule`, `[id]`, `+` (concatenation).
- `Semantica::Reasoner::Rules::OwlRl` — class constant holding
  the full set. Verbatim transcriptions; comments link each
  rule to the W3C spec section.
- Operator-defined rule sets compose by `Rules::OwlRl + my_extra_rules`.

#### Exit criteria
- Spec: every named rule in `Rules::OwlRl` parses through
  `Sparql.execute` (loaded engine must accept the SPARQL UPDATE
  syntax of every rule).
- Spec: each rule, run in isolation against a fixture exercising
  its triggering pattern, produces the expected inferred triple
  and only that triple.
- Spec: the W3C OWL 2 RL test suite's relevant subset (the
  rules-implementable cases — not the DL classification cases)
  passes.

### Phase C — `Storable` DSL: declarative ontology hooks

Most operators don't author bare T-Box triples. They want to
declare on the AR class: "instances of `Product` are
`schema:Product`s; the `manufacturer` association is
`schema:manufacturer`; that property has domain `schema:Product`
and range `schema:Organization`."

```ruby
class Product < ApplicationRecord
  include Semantica::Storable

  triples do
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }
  end

  ontology do
    class_iri      "schema:Product"
    subclass_of    "schema:Thing"

    property "schema:manufacturer",
             domain: "schema:Product",
             range:  "schema:Organization"
    property "schema:gtin",
             range:    "xsd:string",
             functional: true
    property "schema:knows",
             symmetric: true
  end
end
```

#### Implementation
- New concern method `ontology do … end` recorder, parallel to
  `triples do … end`.
- Emits T-Box triples *once per process* into a dedicated
  schema graph (`urn:semantica:ontology:<class_name>`). The
  emission is idempotent (uses the same read-replace dispatch
  the asserted-graph emission uses).
- A-Box assertions (`?p rdf:type schema:Product`) emit
  through the existing `triples do … end` block — the
  `ontology` block does not duplicate them.
- Class methods on the AR model:
  - `Product.materialise_inferences!(scope:)` — convenience
    wrapper for `Semantica::Reasoner.materialise!` against
    a scope-specific asserted/inferred graph pair.
  - `Product.ontology_graph_iri` — reader for the schema
    graph IRI.

#### Exit criteria
- Spec: declaring `class_iri` + `subclass_of` emits
  `<class_iri> rdfs:subClassOf <super_iri>` into the schema
  graph; subsequent `materialise!` derives the expected
  `rdf:type` propagations.
- Spec: declaring `property … functional: true` emits the
  appropriate `owl:FunctionalProperty` typing.
- Spec: ontology emission is idempotent across process restarts.
- Spec: the `triples do … end` block continues to emit only
  A-Box triples — `ontology do … end`'s T-Box doesn't leak
  into the data graph.

### Phase D — Lifecycle: when does the closure re-materialise?

OWL 2 RL is forward-chaining: the closure can grow stale when
asserted triples change. Three opt-in policies, mirroring
`Storable`'s and `EtherealGraph`'s `:explicit` / `:save` choices:

```ruby
ontology do
  class_iri "schema:Product"
  materialise_on :explicit         # default — call materialise! manually
  # materialise_on :save           # auto after every save (expensive!)
  # materialise_on { Rails.application.config.semantica_auto_materialise }
end
```

#### Implementation
- `:explicit` (default): no callbacks. Operators run
  `Product.materialise_inferences!(scope:)` on a schedule
  (Rails cron / Sidekiq job).
- `:save`: registers `after_save :materialise_inferences!`.
  The `Reasoner` is idempotent so this is correct, but
  expensive — running the full rule set after every save is
  almost never what operators want. Documented loudly.
- A block form passes through to a per-call decision —
  operators wire to their own config flag, dev-only switch,
  etc.

#### Exit criteria
- Spec: `:explicit` runs no callback; manual `materialise!`
  works.
- Spec: `:save` re-materialises after `update!`; the inferred
  graph reflects the new closure.
- Spec: block form invokes the block at save time; truthy
  triggers materialisation, falsy skips.

### Phase E — Provenance on inferred triples (RDF-star integration)

Every derived triple gets an RDF-star annotation block recording
which rule fired, when, and against which premises. This is the
v0.9.0 surface that makes the materialised closure *audit-able*
— operators can trace any inferred triple back to the rule + the
asserted triples that triggered it.

```
:x rdf:type :Detective {|
  :derivedBy   :Rule_cax-sco ;
  :derivedAt   "2026-06-01T14:23:00Z"^^xsd:dateTime ;
  :derivedFrom << :x :investigates :Case1234 >> ;
  :derivedFrom << :Detective owl:equivalentClass [ ... ] >>
|} .
```

#### Implementation
- The `Reasoner` rewrites each `INSERT { ?s ?p ?o } WHERE { … }`
  to its annotation-shorthand form when `provenance: true`:
  `INSERT { ?s ?p ?o {| :derivedBy :Rule_X ; :derivedAt NOW() ; :derivedFrom << … >> |} } WHERE { … }`.
- `:derivedFrom` annotations point at the triggering premises
  as quoted triples; multiple `:derivedFrom`s when a rule has
  multiple premises.
- `NOW()` in the rule body is the engine's SPARQL `NOW()`
  function — fires per rule application, so derivations within
  one fixpoint pass share the timestamp.
- Provenance can be **toggled off** at `materialise!` time —
  `provenance: false` runs the bare rule set. Useful for
  benchmarking and for closures where the audit trail isn't
  needed.

#### Exit criteria
- Spec: a single derivation produces both the inferred triple
  and the annotation block; the block contains exactly the
  pinned predicates.
- Spec: multi-premise rule emits one `:derivedFrom` per premise.
- Spec: `provenance: false` produces only the bare inferred
  triple, no annotation block.
- Spec: re-materialisation under `provenance: true` does **not**
  duplicate annotation blocks — the `:derivedAt` timestamp on an
  already-inferred triple is preserved by the read-replace
  idempotency.

### Phase F — Specs + bin/check

- New file `spec/semantica/reasoner_spec.rb` covering Phase A.
- New file `spec/semantica/reasoner_rules_owl_rl_spec.rb` — one
  example per OWL 2 RL rule (a `shared_examples` table driven
  off the `Rules::OwlRl` set, asserting each rule's expected
  derivation against a minimal fixture).
- New file `spec/semantica/storable_ontology_spec.rb` covering
  Phase C.
- Extend `spec/semantica/sparql_star_spec.rb` (or sibling)
  with the provenance shape from Phase E.
- `bin/check` green against engine ≥ 0.9.1 (no new engine
  pin — OWL 2 RL rides on the existing surfaces).

### Phase G — Docs

- `CHANGELOG.md` — `0.9.0` heading with per-phase entries.
- `README.md` — new "Reasoning (OWL 2 RL)" section after the
  RDF-star section, with the `ontology do … end` example, the
  `materialise!` shape, and the four gotchas from the "Risks"
  table below.
- `CONSUMER_REQUIREMENT_MM.md` — promote OWL reasoning to a
  §7 surface block once MM signals adoption.
- `docs/plans/PLAN_0.9.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.9.0`.

## Out of scope for v0.9.0

- **Full OWL DL / OWL 2 DL classification.** Tableau reasoning
  (HermiT, Pellet, FaCT++, ELK) is a Java/C++ dependency the
  gem won't take on. Operators needing full DL ship triples to
  Jena Fuseki or Stardog out-of-process.
- **OWL 2 EL / OWL 2 QL profiles.** OWL 2 EL is biomedical-
  ontology shaped and needs polynomial-time TBox classification
  the gem can't do in SPARQL; OWL 2 QL is query-rewriting-shaped
  and needs SPARQL-query-rewriting middleware that doesn't yet
  exist in the gem. Both deferred indefinitely.
- **SHACL / SHACL-SPARQL constraint validation.** Adjacent but
  distinct — SHACL is a *constraint* language, OWL is an
  *inference* language. A future `PLAN_0.10.0` or sibling plan
  covers SHACL; the two surfaces would compose
  (`Storable + Ontology + ShaclShape`).
- **Negation as failure / closed-world reasoning.** OWL 2 RL is
  open-world; `owl:complementOf` is one of the rules the
  profile excludes. Operators wanting closed-world need a
  different inference model entirely (Datalog with negation,
  Prolog).
- **Reasoner consistency checking.** Detecting that a graph is
  inconsistent ("`:x rdf:type :Person ; rdf:type :NotAPerson`")
  needs reasoning over `owl:disjointWith` + `owl:complementOf`
  which OWL 2 RL handles only partially. v0.9.0 ships the
  derivable-from-RL-rules slice; structural consistency checks
  beyond that are out.
- **Incremental / differential reasoning.** Recomputing only the
  affected closure slice when an assertion changes. Requires a
  dependency tracker mapping derived triples to premise triples
  — substantial design + storage cost, deferred to v0.10.0+ if
  MM's workloads demand it.
- **Reasoner-as-service integration.** Proxying out to Fuseki /
  Stardog / GraphDB. The gem stays in-process.
- **DL queries / SPARQL with entailment regimes.** Query
  rewriting under OWL entailment is the OWL 2 QL profile's
  territory; out of scope here.
- **Custom inference languages.** SWRL, Notation3 (N3) rules,
  RIF. Operators stay on SPARQL UPDATE; if they need richer
  rules they author their own `Reasoner::Rule` instances and
  compose with `Rules::OwlRl`.
- **Per-rule cost estimation / optimisation.** v0.9.0 runs the
  full rule set every iteration; rules that don't fire are
  cheap-because-no-match. Smart rule ordering / dependency-
  graph rule scheduling is a v0.10.0+ optimisation.

## Risks

| Risk | Mitigation |
|---|---|
| Forward-chaining over a large asserted graph blows out the closure size (~10× the asserted size is plausible for richly-typed data). | The inferred graph is in its own named graph; operators retract it in one `CLEAR GRAPH` and re-run. Document. `materialise!` returns `derived:` so operators can monitor closure growth. |
| `:save` lifecycle policy is a footgun (re-running the full rule set after every `Product.update!` is O(N) per save). | Default to `:explicit`. `:save` documented loudly. README example uses cron / batch jobs as the canonical re-materialisation trigger. |
| Operators expect full DL reasoning (`Detective EquivalentTo: Person and investigates some Case`) and get OWL-2-RL-only. | README leads with the OWL 2 RL framing + the explicit "not full DL" callout. The `:rule_set_unknown` refusal on a hypothetical `:owl_dl` makes the absence visible at call sites. |
| `NOW()` in the rule body is engine-dependent (Oxigraph implements `NOW()` but the cached value may surprise operators). | Pin the semantics — `NOW()` returns the rule-application timestamp, identical for all derivations within one `materialise!` invocation. Spec asserts this. Operators wanting per-triple timestamps annotate the asserted triple instead, and the derivation references it via `:derivedFrom`. |
| Rule library drift from the W3C spec (a future spec revision could renumber or refine rules). | Each rule carries its W3C ID + spec section in the `description:` field. Drift is a CHANGELOG entry, not a silent fix. |
| RDF-star provenance balloons the inferred graph 3-5× (each derivation gets ~3 annotation triples). | `provenance: false` is the escape hatch. Document the size implication next to the `provenance:` kwarg. Operators wanting both small *and* audit-able pick named-graph-per-rule instead — out of scope for v0.9.0 but documented as a hand-rolled pattern. |
| `materialise!` is not transactional — partial closure if an iteration fails halfway. | Run inside a single SQLite transaction at the engine level; on failure roll back the entire `materialise!` (leaving the prior closure intact). Spec asserts the rollback. |
| Concurrent `materialise!` invocations against the same `(asserted, inferred)` pair race. | Per-(inferred-graph-IRI) `Mutex` in the gem-side `Reasoner` module; second caller waits. Spec asserts serialisation. |
| OWL 2 RL rule set includes some rules that explode trivially on common patterns (e.g., `owl:sameAs` propagation can multiply triple count quickly). | The `Rules::OwlRl` set is one constant; operators can subtract the explosive rules via `Rules::OwlRl - [:eq-rep-s, :eq-rep-p, :eq-rep-o]`. Document the pattern. |

## Acceptance signal

1. Phases A/B/C/D/E land with passing specs.
2. `bin/check` green against engine ≥ 0.9.1.
3. CHANGELOG `0.9.0` heading drops `(unreleased)`.
4. `VERSION` → `0.9.0`.
5. README documents the `ontology do … end` block + the
   `materialise!` shape + the four headline gotchas.
6. CONSUMER_REQUIREMENT_MM.md §7 notes the new optional
   surface once MM signals adoption.
7. The W3C OWL 2 RL rule-coverage spec passes — every rule in
   `Rules::OwlRl` has a triggering fixture and an expected-
   derivation assertion.

## v0.9.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Semantica::Reasoner.materialise!(asserted:, inferred:, rules: :owl_2_rl, provenance: true, max_iterations: 50)` | module method | **Pinned.** |
| `Semantica::Reasoner::Rule` value object (`id:`, `name:`, `description:`, `sparql:`) | frozen struct | **Pinned.** |
| `Semantica::Reasoner::RuleSet` enumerable | class | **Pinned.** |
| `Semantica::Reasoner::Rules::OwlRl` constant | ordered RuleSet | **Pinned set membership** (drift is a CHANGELOG entry). |
| `Storable::DSL` `ontology do; class_iri "…"; subclass_of "…"; property "…", domain:, range:, functional:, symmetric:, transitive:, inverse_of:; materialise_on :explicit\|:save\|{block}; end` | DSL keywords | **Pinned.** |
| `:rule_set_unknown` reason symbol | refusal envelope | **Pinned.** |
| `:reasoner_diverged` reason symbol | refusal envelope (includes `iterations:`) | **Pinned.** |
| Provenance annotation predicate IRIs (`semantica:derivedBy`, `semantica:derivedAt`, `semantica:derivedFrom`) | namespace | **Pinned.** Operators introspecting these in queries: do so. |
| Schema-graph IRI shape (`urn:semantica:ontology:<class_name>`) | derived | **Internal**; do not introspect. |

## Cross-references

- `./PLAN_0.3.0.md` — `sparql_update` is the engine surface every
  OWL 2 RL rule rides through.
- `./PLAN_0.5.0.md` — named graphs scope the materialised
  closure.
- `./PLAN_0.7.0.md` — EtherealGraph; persisting the inferred
  graph across restarts uses the same hydrate/checkpoint
  surface.
- `./PLAN_0.8.0.md` — RDF-star; the provenance annotations on
  inferred triples are v0.8.0's `annotate` shorthand applied to
  rule output.
- `../research/TripesQuadsEtc.md` — the motivating sketch's
  fourth rung; v0.9.0 implements the OWL 2 RL slice of it.
- W3C OWL 2 Web Ontology Language Profiles (Second Edition,
  2012) <https://www.w3.org/TR/owl2-profiles/> — the spec
  v0.9.0's rule library transcribes.
- W3C OWL 2 RL/RDF rules table <https://www.w3.org/TR/owl2-profiles/#Reasoning_in_OWL_2_RL_and_RDF_Graphs_using_Rules>
  — the exact rule set `Rules::OwlRl` implements.
- `sqlite-sparql/CHANGELOG.md` § `0.9.1` — engine pin v0.9.0
  inherits from v0.8.0. (v0.9.0 was the broken docs-only
  publication; v0.9.1 is the actual native-OWL-2-RL release
  Vv::Graph::Reasoner could opt into — see the "Engine-side
  native pass available" note below.)
