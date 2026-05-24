# PLAN_0.10.0 — `rails-semantica` SHACL (constraint validation)

> *Sibling to PLAN_0.9.0's OWL 2 RL reasoner. OWL says **what
> follows** from what's asserted; SHACL says **what's required**
> of what's asserted. The two compose: a `Product` declares its
> ontology (OWL → inferred class memberships, derived properties),
> and a SHACL shape declares the integrity envelope (every Product
> must have exactly one `schema:gtin` matching a regex; every
> price must be a positive decimal; every supplier must
> participate in an `inverse partOf` chain). Oxigraph ships no
> SHACL validator, so v0.10.0 takes the same path PLAN_0.9.0 took
> for OWL 2 RL — implement **SHACL Core** as a library of SPARQL
> ASK/SELECT queries that materialise into a W3C-conformant
> `sh:ValidationReport`. SHACL-AF (Advanced Features — custom
> constraint components in JavaScript / arbitrary SPARQL),
> SHACL-JS, and the SHACL Rules extension are explicitly out of
> scope.*

## Current state

**Draft (not yet started).** Sequencing depends on PLAN_0.9.0 only
in framing — the SHACL surface doesn't *require* the reasoner, but
the two are designed to compose. Operators wanting "validate after
inference" run `Reasoner.materialise!` then `Shacl.validate!`;
operators wanting "validate raw assertions only" skip the reasoner.

v0.10.0 can ship in parallel with v0.9.0 — the gem-side work
doesn't overlap.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `docs/research/TripesQuadsEtc.md` | this repo | Sets up the OWL boundary; SHACL is the constraint-validation neighbour the OWL rung doesn't cover. v0.10.0 fills the "validation" side; v0.9.0 fills the "inference" side. |
| `PLAN_0.9.0.md` | this dir | OWL 2 RL reasoner. Sibling-by-design: same "library of SPARQL queries against an asserted graph" pattern, different W3C spec underneath. The two compose (`Storable + Ontology + Shape`). |
| `PLAN_0.5.0.md` | this dir | Named graphs. SHACL takes two named-graph inputs (`data_graph:`, `shapes_graph:`); the validation report is a third graph. |
| `PLAN_0.8.0.md` | this dir | RDF-star. Validation reports can optionally annotate each violation with `:reportedBy :Shape_X ; :reportedAt …`, mirroring v0.9.0's `:derivedBy` provenance pattern. |
| `PLAN_0.3.0.md` | this dir | `sparql_update` arbitrary-UPDATE path used to write the validation report (not for constraint *checking* — constraints are read-only via `sparql_query` / `sparql_ask`). |
| W3C SHACL (Recommendation, 20 July 2017) | spec | `<https://www.w3.org/TR/shacl/>`. The constraint component catalogue v0.10.0's `Shacl::Constraints` library transcribes. v0.10.0 implements **SHACL Core** — the Rec's normative section 4. |
| MM-side SHACL research note | MM repo | **TBD** — companion to `magentic-market-ai/docs/research/StarExts.md`. v0.10.0's gotchas / scope decisions land in an MM-side primer when MM signals adoption. |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Drift target. v0.10.0 adds `Semantica::Shacl` surface block once MM signals adoption. |

## Engine prerequisites (sqlite-sparql ≥ 0.7.0) — **already satisfied**

**No new engine surface.** Every SHACL Core constraint component
can be evaluated by a templated SPARQL ASK or SELECT query
against the data graph. `sparql_query` (PLAN_0.1.0) and the
named-graph `FROM` injection (PLAN_0.5.0) are the only engine
surfaces v0.10.0 touches on the read path; `sparql_update`
(PLAN_0.3.0) emits the validation report.

If SHACL evaluation later proves too slow at SPARQL-driven
speeds, an engine-side validator pass would unlock further work
— deferred and out of scope:

1. **Engine-side validator.** Move the constraint evaluation into
   a Rust pass that walks the Oxigraph store directly. Useful if
   MM hits SHACL workloads where the round-trip cost dominates.

v0.10.0 ships the SPARQL-driven shape; v0.11.0+ revisits if MM's
workloads demand it.

## Why SHACL Core (and not SHACL-AF, SHACL-JS, or SHACL Rules)

The 2017 Rec splits cleanly into **SHACL Core** (the W3C
Recommendation; constraint components defined in section 4) and
**SHACL-SPARQL** (section 6; lets shapes embed raw SPARQL
constraint definitions). SHACL-AF (Advanced Features), SHACL-JS
(custom validators in JavaScript), and the SHACL Rules extension
are W3C Notes, not Recs — adoption is uneven.

v0.10.0 targets **SHACL Core** plus **the safe slice of
SHACL-SPARQL** (shapes that embed a `sh:select` query the engine
already understands):

- **In scope (SHACL Core, section 4).** Every constraint
  component in the Rec's normative catalogue: `sh:class`,
  `sh:datatype`, `sh:nodeKind`, `sh:minCount`, `sh:maxCount`,
  `sh:minExclusive`, `sh:minInclusive`, `sh:maxExclusive`,
  `sh:maxInclusive`, `sh:minLength`, `sh:maxLength`, `sh:pattern`,
  `sh:languageIn`, `sh:uniqueLang`, `sh:equals`, `sh:disjoint`,
  `sh:lessThan`, `sh:lessThanOrEquals`, `sh:not`, `sh:and`,
  `sh:or`, `sh:xone`, `sh:node`, `sh:property`, `sh:in`,
  `sh:hasValue`, `sh:closed`, `sh:ignoredProperties`,
  `sh:qualifiedValueShape` (+ `sh:qualifiedMinCount` /
  `sh:qualifiedMaxCount`), `sh:targetNode`, `sh:targetClass`,
  `sh:targetSubjectsOf`, `sh:targetObjectsOf`.
- **In scope (SHACL-SPARQL slice).** Operator-authored
  `sh:select` constraints — the gem passes the embedded query
  to `Sparql.select` with the focus-node binding pre-resolved.
  No JavaScript, no custom constraint *component* declarations
  (which require defining new IRIs the gem doesn't yet route).
- **Out of scope.** SHACL-AF (`sh:expression`, `sh:NodeExpression`,
  custom constraint components beyond SHACL-SPARQL), SHACL-JS
  (JavaScript-defined validators), SHACL Rules (`sh:rule` →
  triple derivation, which overlaps PLAN_0.9.0's reasoner).
  Deferred indefinitely; revive on first ask.

For MM's domain — Product/Category/Agent integrity envelopes,
gtin regex enforcement, price-positivity, ontology-derived
cardinality constraints — SHACL Core is the right ceiling.
Anything past it is OOS.

## Gem-side scope

### Phase A — `Semantica::Shacl` facade

The single entry point. Validates a data graph against a shapes
graph; returns a structured envelope **and** materialises a
W3C-conformant `sh:ValidationReport` into a paired named graph.

```ruby
Semantica::Shacl.validate(
  data_graph:   "urn:mm:graph:catalogue",
  shapes_graph: "urn:semantica:shapes:product",
  report_graph: "urn:mm:graph:catalogue:report",   # optional; defaults to <data>:report
  provenance:   true,                              # RDF-star annotation per violation
)
# Conforming graph:
# => { ok: true, conforms: true, violations: [], report_graph: "urn:..." }
#
# Non-conforming graph:
# => { ok: true, conforms: false,
#      violations: [
#        { focus_node:    "urn:mm:product:42",
#          path:          "schema:gtin",
#          source_shape:  "urn:semantica:shape:Product/gtin",
#          source_constraint_component: "http://www.w3.org/ns/shacl#MinCountConstraintComponent",
#          severity:      "http://www.w3.org/ns/shacl#Violation",
#          value:         nil,
#          message:       "Product must have exactly one gtin (cardinality: 0; expected 1)" },
#        ...
#      ],
#      report_graph: "urn:..." }
```

#### Implementation
- `Semantica::Shacl` is a module facade following the
  `Semantica::Sparql` / `Semantica::Reasoner` pattern (never
  raises; structured envelopes).
- `validate(...)`:
  1. Validate inputs — `data_graph:` and `shapes_graph:` must
     be non-blank-node IRIs; refuse `:invalid_graph`
     otherwise. `report_graph:` defaults to `"#{data_graph}:report"`.
  2. Pre-pass: CLEAR the report graph (validation reports
     are not additive; each `validate!` call replaces the
     prior report).
  3. Enumerate **target nodes** per shape — every shape's
     `sh:targetClass`, `sh:targetNode`, `sh:targetSubjectsOf`,
     `sh:targetObjectsOf` clauses resolve to a set of focus
     nodes via a SPARQL SELECT against the data graph.
  4. For each (shape, focus_node) pair, for each constraint
     component declared on the shape, evaluate the constraint
     by issuing the templated SPARQL ASK/SELECT against the
     data graph.
  5. Each constraint violation produces a `sh:ValidationResult`
     blank-node-style RDF block written into the report graph.
  6. Aggregate into a `sh:ValidationReport` root node with
     `sh:conforms` true|false, `sh:result` linking to each
     violation.
  7. Return envelope with the violations list (deserialised
     from the report graph for caller ergonomics).
- `provenance: true` annotates each `sh:ValidationResult` with
  `<< _:violation sh:value ?v >> :reportedAt "…" ; :reportedBy <shape_iri> .`
  via the v0.8.0 annotation surface.

#### Refusal envelope additions
- `:invalid_graph` — pre-existing.
- `:shape_parse_error` — a `sh:select` constraint in the shapes
  graph fails to parse as SPARQL; envelope includes the shape
  IRI + the engine's parse error.
- `:unknown_constraint_component` — a shape declares a constraint
  component IRI that v0.10.0 doesn't implement (e.g., SHACL-AF
  components). Envelope lists the unknown IRIs so operators can
  spot drift.
- `:cycle_detected` — shape references form a cycle through
  `sh:node` (operator authored `:A sh:node :B ; :B sh:node :A`).
  Refuse rather than loop.

#### Exit criteria
- Spec: data graph with one violating product → `conforms: false`,
  exactly one violation in the list with the pinned shape fields.
- Spec: conforming data graph → `conforms: true`, empty
  violations, but a `sh:ValidationReport` still lands in the
  report graph (with `sh:conforms true`).
- Spec: re-running `validate!` against the same inputs replaces
  the prior report (no additive duplication).
- Spec: a shape declaring an unimplemented constraint component
  refuses with `:unknown_constraint_component` + the IRI.

### Phase B — Constraint component library

Each SHACL Core constraint component maps to a templated SPARQL
query. v0.10.0's `Shacl::Constraints` is a faithful Ruby
transcription of the W3C SHACL Rec section 4 catalogue.

#### Rule organisation
Each component is a `Semantica::Shacl::Constraint` value object:

```ruby
Semantica::Shacl::Constraint.new(
  iri:   "http://www.w3.org/ns/shacl#MinCountConstraintComponent",
  name:  "sh:minCount",
  parameters: [:min_count],                              # the shape predicate(s) carrying the value
  validates: <<~SPARQL,
    # Returns the actual cardinality; the facade compares to min_count.
    SELECT (COUNT(?o) AS ?cardinality)
    WHERE { ?focus ?path ?o }
    GROUP BY ?focus
  SPARQL
  default_message: ->(min, actual) { "expected at least #{min} value(s) on path; got #{actual}" },
)
```

A `ConstraintLibrary` is an ordered registry mapping component
IRIs to `Constraint` objects. `Constraints::Core` holds the
~30 SHACL Core components, organised by section:

- **Cardinality** — `sh:minCount`, `sh:maxCount`.
- **Value type** — `sh:class`, `sh:datatype`, `sh:nodeKind`.
- **Value range** — `sh:minExclusive`, `sh:minInclusive`,
  `sh:maxExclusive`, `sh:maxInclusive`.
- **String-based** — `sh:minLength`, `sh:maxLength`,
  `sh:pattern` (+ `sh:flags`), `sh:languageIn`, `sh:uniqueLang`.
- **Property pair** — `sh:equals`, `sh:disjoint`, `sh:lessThan`,
  `sh:lessThanOrEquals`.
- **Logical** — `sh:not`, `sh:and`, `sh:or`, `sh:xone`.
- **Shape-based** — `sh:node`, `sh:property`,
  `sh:qualifiedValueShape` (+ qualified-min/max-count).
- **Other** — `sh:closed` (+ `sh:ignoredProperties`),
  `sh:hasValue`, `sh:in`.

#### Implementation
- `Semantica::Shacl::Constraint` — frozen value object.
- `Semantica::Shacl::ConstraintLibrary` — ordered registry;
  supports `register`, `[iri]`, `+` (concatenation for
  operator-authored extensions).
- `Semantica::Shacl::Constraints::Core` — class constant
  holding the Rec section-4 catalogue. Verbatim transcriptions;
  comments link each constraint to the Rec section.
- Operator-defined libraries compose by `Constraints::Core + my_extras`.

#### Exit criteria
- Spec: every SHACL Core constraint component evaluates against
  a triggering fixture and a clearing fixture (one violation
  case and one conforming case per component).
- Spec: the W3C SHACL test suite's Core subset (the
  non-AF / non-JS cases) passes. Document the exact test-suite
  rev v0.10.0 ships against.

### Phase C — `Storable` composition: `Shape` concern + DSL

Most operators don't author bare SHACL shape RDF. They want to
declare on the AR class: "my Products must have exactly one gtin
matching `^\d{13}$`; my Categories must have a non-empty name."

```ruby
class Product < ApplicationRecord
  include Semantica::Storable
  include Semantica::Shacl::Shape

  triples do
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }
    triple "schema:gtin", -> { gtin }
  end

  shape do
    target_class "schema:Product"

    property "schema:name" do
      min_count 1
      max_count 1
      datatype  "xsd:string"
      min_length 1
      max_length 200
    end

    property "schema:gtin" do
      min_count 1
      max_count 1
      datatype  "xsd:string"
      pattern   '^\d{13}$'
      message   "gtin must be a 13-digit string"   # custom sh:message
    end

    closed true, ignored_properties: %w[rdf:type]
  end
end
```

#### Implementation
- New concern `Semantica::Shacl::Shape`. Composes with
  `Storable` and `EtherealGraph` orthogonally.
- `shape do … end` recorder, parallel to `triples do … end`
  and `ontology do … end`.
- Emits shape triples *once per process* into a dedicated
  shapes graph (`urn:semantica:shapes:<class_name>`). The
  emission is idempotent — same read-replace dispatch
  `Storable` uses.
- Class methods on the AR model:
  - `Product.validate_shape!(scope:)` — convenience wrapper
    for `Semantica::Shacl.validate(...)` against a
    scope-specific data graph + the model's shapes graph.
  - `Product.shapes_graph_iri` — reader for the shapes graph
    IRI (parallel to `ontology_graph_iri` from PLAN_0.9.0).
- Per-instance helper:
  - `product.valid_shape?` → `true|false` (issues a
    `validate!` scoped to the single focus node via
    `sh:targetNode` injection; returns true iff conforms).
- DSL keywords mirror the SHACL Core constraint catalogue
  (`min_count`, `max_count`, `datatype`, `pattern`,
  `node_kind`, etc.). The Recorder converts each call to its
  shape-graph triple representation.

#### Exit criteria
- Spec: declaring a shape emits the expected SHACL triples
  into the shapes graph (round-trippable through `Sparql.construct`).
- Spec: `Product.validate_shape!(scope:)` runs against a
  scope-specific data graph and returns the conformance
  envelope.
- Spec: `product.valid_shape?` returns true for a conforming
  product and false for a violating one.
- Spec: shape emission is idempotent across process restarts.
- Spec: a `Storable + Shacl::Shape` compose cleanly — the
  shape's `target_class` matches the Storable's emitted
  `rdf:type`, so the focus-node resolution lands on the
  records the gem emitted.

### Phase D — Lifecycle: when does validation run?

Three opt-in policies, mirroring the established
`:explicit` / `:save` / block pattern:

```ruby
shape do
  target_class "schema:Product"
  validate_on :explicit        # default — call validate_shape! manually
  # validate_on :save          # auto after every save; failures raise (see below)
  # validate_on { Rails.env.test? }
end
```

#### Implementation
- `:explicit` (default): no callbacks. Operators run
  `Product.validate_shape!(scope:)` on a schedule (ETL job /
  pre-flight check before publishing a catalogue snapshot).
- `:save`: registers `after_save :enforce_shape!`. Unlike
  the reasoner's `:save`, the validator is *enforcement* —
  a non-conforming record raises
  `Semantica::Shacl::ShapeViolation` (subclass of
  `ActiveRecord::RecordInvalid` so existing Rails error
  handling catches it). Documented loudly — this is a
  potentially-expensive opt-in that operators take on
  purpose.
- A block form passes through to a per-call decision —
  operators wire to their own config flag.
- A fourth opt-in not on this ladder: `validate_on :validation`
  — registers an AR `validate :enforce_shape_via_errors!` so
  shape violations land as `record.errors` entries rather
  than raises. This is the "Rails-native validation"
  ergonomics opt-in.

#### Exit criteria
- Spec: `:explicit` runs no callback.
- Spec: `:save` raises `ShapeViolation` on a violating save;
  the record is **not** persisted (the raise unwinds the
  transaction).
- Spec: `:validation` populates `record.errors` with one
  entry per violation; `record.save` returns false.
- Spec: block form invokes the block at save time; truthy
  triggers validation, falsy skips.

### Phase E — Validation report shape (RDF-conformant)

The report graph holds a W3C-spec-conformant `sh:ValidationReport`
RDF graph. v0.10.0 pins:

```turtle
@prefix sh: <http://www.w3.org/ns/shacl#> .
@prefix semantica: <http://laquereric.github.io/rails-semantica/ns#> .

_:report a sh:ValidationReport ;
  sh:conforms false ;
  semantica:reportedAt "2026-06-15T10:00:00Z"^^xsd:dateTime ;
  semantica:reportedBy <urn:semantica:shapes:product> ;
  sh:result _:v1, _:v2 .

_:v1 a sh:ValidationResult ;
  sh:focusNode <urn:mm:product:42> ;
  sh:resultPath <schema:gtin> ;
  sh:sourceShape <urn:semantica:shape:Product/gtin> ;
  sh:sourceConstraintComponent sh:MinCountConstraintComponent ;
  sh:resultSeverity sh:Violation ;
  sh:resultMessage "Product must have exactly one gtin (cardinality: 0; expected 1)" .
```

#### Implementation
- The facade serialises each violation into the
  `sh:ValidationResult` form via `Sparql.execute("INSERT DATA …")`.
- Severity defaults to `sh:Violation`. Operators set
  `sh:resultSeverity sh:Warning` (or `sh:Info`) on the shape;
  the validator respects it.
- `sh:resultMessage` defaults to the constraint component's
  default message (Phase B); operator-authored `sh:message`
  on the shape overrides.
- Per-violation `provenance: true` annotation rides
  v0.8.0's RDF-star surface — `<< _:v1 sh:resultMessage "…" >> :reportedAt … ; :reportedBy … .`.

#### Exit criteria
- Spec: the report graph contains a `sh:ValidationReport` with
  the right `sh:conforms` flag and one `sh:result` per
  violation.
- Spec: every `sh:ValidationResult` carries all six pinned
  predicates (`sh:focusNode`, `sh:resultPath`, `sh:sourceShape`,
  `sh:sourceConstraintComponent`, `sh:resultSeverity`,
  `sh:resultMessage`).
- Spec: operator-set `sh:resultSeverity sh:Warning` propagates.
- Spec: operator-set `sh:message` overrides the default.
- Spec: `provenance: true` adds the annotation block; `false` skips.

### Phase F — Specs + bin/check

- New file `spec/semantica/shacl_spec.rb` covering Phase A + E.
- New file `spec/semantica/shacl_constraints_core_spec.rb` —
  one example per SHACL Core constraint component
  (shared-examples table driven off `Constraints::Core`,
  asserting each component's evaluation against a minimal
  fixture).
- New file `spec/semantica/shacl_shape_concern_spec.rb`
  covering Phase C + D.
- `bin/check` green against engine ≥ 0.7.0 (no new pin —
  SHACL Core rides the existing read-side surfaces).

### Phase G — Docs

- `CHANGELOG.md` — `0.10.0` heading with per-phase entries.
- `README.md` — new "Validation (SHACL Core)" section after
  the OWL reasoning section, with the `shape do … end`
  example, the `validate!` shape, the four lifecycle policies,
  and the five gotchas from the "Risks" table below.
- `CONSUMER_REQUIREMENT_MM.md` — promote SHACL to a §8
  surface block once MM signals adoption.
- `docs/plans/PLAN_0.10.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.10.0`.

## Out of scope for v0.10.0

- **SHACL-AF (Advanced Features).** `sh:expression`,
  `sh:NodeExpression`, custom constraint component declarations
  beyond SHACL-SPARQL. W3C Note, not Rec.
- **SHACL-JS.** JavaScript-defined validators. W3C Note;
  requires a JS runtime in-process; the gem won't take on
  the dependency.
- **SHACL Rules.** `sh:rule` → triple derivation. Overlaps
  PLAN_0.9.0's OWL 2 RL reasoner; if MM needs rule-based
  derivation, that's the surface to use. Revisit if SHACL Rules
  syntax becomes a hard MM requirement.
- **SHACL-SPARQL custom constraint components.** Operators
  declaring new constraint component IRIs via
  `sh:ConstraintComponent` definitions. v0.10.0 ships
  pre-defined constraint components only; operator-authored
  `sh:select` constraints (embedded in property shapes) ARE
  in scope — what's out is declaring new component IRIs.
- **Incremental / differential validation.** Re-validating
  only the affected focus nodes when an assertion changes.
  Substantial dependency-tracking cost; deferred to v0.11.0+
  if MM signals demand.
- **Validation reports under reasoning entailment.** SHACL
  spec's "SHACL on entailment-extended graphs" footnote. v0.10.0
  validates the raw asserted graph; operators wanting
  "validate the inferred closure" run `Reasoner.materialise!`
  first then pass the inferred graph as `data_graph:`.
- **Validator-as-service integration.** Proxying out to
  TopBraid SHACL / Apache Jena SHACL / pySHACL. The gem stays
  in-process.
- **Per-constraint cost estimation / optimisation.** v0.10.0
  evaluates every constraint against every target node;
  smart short-circuiting (skip remaining constraints on a
  failing `sh:property` shape) is a v0.11.0+ optimisation.
- **`sh:closed` over inferred triples.** `sh:closed true`
  means "the focus node has no triples beyond those allowed
  by `sh:property` shapes." v0.10.0 evaluates `sh:closed`
  against the raw `data_graph:` only — if the operator wants
  closed-world validation including inferred triples, they
  pass the inferred-graph IRI as `data_graph:` and the
  validator treats it as one graph.
- **W3C SHACL test suite cases marked "FAILS" or "MANIFEST_DEFERRED".**
  Documented in the spec rev v0.10.0 ships against.

## Risks

| Risk | Mitigation |
|---|---|
| SHACL Core has ~30 constraint components; the rule library is verbose. | The library transcription is mechanical; the W3C SHACL test suite is the integration safety net — every component has a Rec-defined fixture set. Spec drift is a CHANGELOG entry, not a silent fix. |
| Validating every focus node against every constraint is O(N × M) — slow on large graphs. | Document. Recommend cron / batch jobs as the canonical `:explicit` re-validation trigger. v0.11.0+ may add smart re-validation; v0.10.0 is the correctness-first cut. |
| `:save` lifecycle policy raises in-place — operators may not expect a SHACL violation to abort `Product.update!`. | Default to `:explicit`. README leads with the "validation is expensive; pick your trigger" framing. The `:validation` opt-in routes failures through Rails' `record.errors` for the ergonomics-first path. |
| `sh:closed` semantics are subtle (focus node has no triples beyond declared property shapes; `sh:ignoredProperties` is the escape hatch). | Spec each `sh:closed` case from the W3C test suite. README has a worked example with a "common gotcha: `rdf:type` should usually be in `sh:ignoredProperties`" callout. |
| Validation report blob can grow large on a non-conforming graph (every focus × every constraint × violation overhead). | Operators bound the report by scoping `data_graph:` to a specific named graph (a per-tenant / per-scope graph). The report graph is independently clearable via `CLEAR GRAPH`. |
| Operators expect SHACL Rules and don't get triple derivation. | README leads with the SHACL-Core-only framing + points at PLAN_0.9.0's reasoner for derivation. `:unknown_constraint_component` refusal makes the absence visible at validation time if a shape references `sh:rule`. |
| SHACL-SPARQL embedded `sh:select` constraints are a SQL-injection-shaped foot-gun if shapes come from untrusted sources. | Document loudly: shape graphs are operator-authored, NOT user input. `sh:select` constraints execute against the engine with whatever privileges the gem connection has. If MM ever sources shapes from untrusted input, the v0.10.0 contract is the wrong tool — that's a v0.11.0+ "sandboxed shapes" surface. |
| Composition with PLAN_0.9.0's reasoner: "validate before or after inference?" is ambiguous. | README explicitly documents both orderings + the trade-offs. Default recommendation: validate the asserted graph first (catch operator errors before they propagate through inference); re-validate the inferred graph if shapes constrain inferred properties. Pinned by spec. |
| `Semantica::Shacl::ShapeViolation` raising on `:save` cascades through autosave / accepts_nested_attributes. | Inherit from `ActiveRecord::RecordInvalid` so existing Rails handlers catch it; spec asserts the rollback works correctly with `accepts_nested_attributes_for`. |

## Acceptance signal

1. Phases A/B/C/D/E land with passing specs.
2. `bin/check` green against engine ≥ 0.7.0.
3. CHANGELOG `0.10.0` heading drops `(unreleased)`.
4. `VERSION` → `0.10.0`.
5. README documents the `shape do … end` block + the
   `validate!` shape + the four lifecycle policies + the
   five headline gotchas.
6. CONSUMER_REQUIREMENT_MM.md §8 notes the new optional
   surface once MM signals adoption.
7. The W3C SHACL Core test suite's relevant subset passes —
   every constraint component in `Constraints::Core` has a
   triggering fixture and an expected-conformance / expected-
   violation assertion.

## v0.10.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Semantica::Shacl.validate(data_graph:, shapes_graph:, report_graph: nil, provenance: true)` | module method | **Pinned.** |
| `Semantica::Shacl::Constraint` value object (`iri:`, `name:`, `parameters:`, `validates:`, `default_message:`) | frozen struct | **Pinned.** |
| `Semantica::Shacl::ConstraintLibrary` enumerable | class | **Pinned.** |
| `Semantica::Shacl::Constraints::Core` constant | ordered ConstraintLibrary | **Pinned set membership** (drift is a CHANGELOG entry). |
| `Semantica::Shacl::Shape` concern | concern | **Pinned.** |
| `Storable::DSL` `shape do; target_class "…"; property "…" do …; closed true; validate_on :explicit\|:save\|:validation\|{block}; end` | DSL keywords | **Pinned.** |
| `Semantica::Shacl::ShapeViolation < ActiveRecord::RecordInvalid` | exception class | **Pinned.** |
| `:shape_parse_error` reason symbol | refusal envelope | **Pinned.** |
| `:unknown_constraint_component` reason symbol | refusal envelope (includes IRI list) | **Pinned.** |
| `:cycle_detected` reason symbol | refusal envelope (includes shape cycle) | **Pinned.** |
| Report-graph IRI default (`<data_graph>:report`) | derived | **Internal**; operators pass explicit `report_graph:` to introspect. |
| Shapes-graph IRI shape (`urn:semantica:shapes:<class_name>`) | derived | **Internal**; do not introspect. |

## Cross-references

- `./PLAN_0.3.0.md` — `sparql_update` writes the validation
  report; `sparql_query` evaluates constraints.
- `./PLAN_0.5.0.md` — named graphs scope the data, shapes,
  and report inputs.
- `./PLAN_0.7.0.md` — EtherealGraph; the report graph can be
  persisted via Active Storage if operators want the
  validation history to survive process restarts.
- `./PLAN_0.8.0.md` — RDF-star; the per-violation provenance
  annotations use v0.8.0's annotation surface.
- `./PLAN_0.9.0.md` — OWL 2 RL reasoner; sibling-by-design
  with v0.10.0. The two compose for "validate the inferred
  closure" workflows.
- `../research/TripesQuadsEtc.md` — the motivating sketch's
  OWL rung. v0.10.0 fills the constraint-validation neighbour
  the OWL rung doesn't cover.
- W3C SHACL (20 July 2017 Recommendation) <https://www.w3.org/TR/shacl/>
  — the spec v0.10.0's constraint library transcribes.
- W3C SHACL test suite <https://w3c.github.io/data-shapes/data-shapes-test-suite/>
  — the integration safety net for Phase B.
- `sqlite-sparql/CHANGELOG.md` § `0.7.0` — engine pin v0.10.0
  inherits from v0.8.0 / v0.9.0.
