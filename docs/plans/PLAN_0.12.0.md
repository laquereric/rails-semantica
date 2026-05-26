# PLAN_0.12.0 — `rails-semantica` SHACL Rules (shape-scoped derivation)

> *PLAN_0.9.0 shipped OWL 2 RL — broad, schema-driven inference
> ("anyone who investigates a case is a detective"). PLAN_0.10.0
> shipped SHACL Core — shape-scoped *validation* ("every Product
> must have exactly one gtin matching `^\d{13}$`"). Operators now
> have a hole in the middle: shape-scoped *derivation* — "for
> every Product whose inventory > 0, derive `mm:availability
> "in_stock"`." OWL 2 RL is too coarse (it's ontology-shaped, not
> business-logic-shaped); SHACL Core validates but doesn't
> derive. v0.12.0 closes the gap with the W3C SHACL Rules
> extension — `sh:TripleRule` and `sh:SPARQLRule` plugged into
> the existing `Shape` concern, materialising into the inferred
> graph alongside OWL 2 RL output, sharing the v0.8.0 RDF-star
> provenance shape, and riding v0.11.0's DRed incremental
> machinery.*

## Current state

**Draft (not yet started).** Sequenced after PLAN_0.10.0 (the
SHACL Core surface the Rules extension plugs into) and PLAN_0.11.0
(the incremental machinery the rule derivations participate in).
v0.12.0 can be drafted in parallel with v0.10.0 / v0.11.0; the
plan-only commit pins the shape so MM can choose between
OWL-2-RL-driven and SHACL-Rules-driven derivation when it adopts
either.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `PLAN_0.10.0.md` | this dir | SHACL Core. v0.12.0 extends the `Shape` concern's `shape do … end` DSL with `rule do … end` recorders. The constraint catalogue from PLAN_0.10.0 stays in place — v0.12.0 is purely additive on the derivation side. |
| `PLAN_0.9.0.md` | this dir | OWL 2 RL reasoner. **Sibling, not replacement.** Operators pick between ontology-driven OWL inference and shape-driven SHACL derivation per axiom; the two can coexist in one model. v0.12.0's `Semantica::Reasoner.materialise!` grows a `rules:` value `:shacl_rules` that runs SHACL Rules; passing both runs OWL first, then SHACL Rules (sh:order respected within SHACL). |
| `PLAN_0.11.0.md` | this dir | Incremental reasoning. SHACL Rule derivations emit the same `:derivedFrom << premise >>` provenance triples OWL 2 RL emits; DRed traversal is identical. The `:incremental_save` lifecycle mode covers SHACL Rules out of the box. |
| `PLAN_0.8.0.md` | this dir | RDF-star. Provenance on rule-derived triples uses the v0.8.0 annotation surface; pinned by the equivalence spec. |
| `PLAN_0.5.0.md` | this dir | Named graphs. SHACL Rules derive into the same inferred-graph IRI OWL 2 RL writes; operators distinguish the source by inspecting `:derivedBy` on the RDF-star annotation. |
| `PLAN_0.3.0.md` | this dir | `sparql_update` arbitrary-UPDATE path the `sh:SPARQLRule` CONSTRUCT-INSERT form rides through. |
| W3C SHACL Advanced Features (Working Group Note, 8 June 2017) | spec | `<https://www.w3.org/TR/shacl-af/>`. The Note v0.12.0 implements **the rules slice of** — `sh:TripleRule`, `sh:SPARQLRule`, `sh:order`, `sh:condition`, `sh:deactivated`. SHACL-AF's other features (`sh:expression`, `sh:NodeExpression` outside of TripleRule, custom constraint components) stay out of scope per PLAN_0.10.0. |
| MM-side derivation research note | MM repo | **TBD.** Open question for MM: which derivations are "ontological" (OWL 2 RL) and which are "business-logic" (SHACL Rules)? A companion note in `magentic-market-ai/docs/research/` should walk the dividing line. |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Drift target. v0.12.0 adds the SHACL Rules surface block once MM signals adoption. |

## Engine prerequisites (sqlite-sparql ≥ 0.9.1) — **already satisfied**

`sh:TripleRule` expands to an `INSERT { ?focus <p> ?o } WHERE
{ … }` form already routed through `sparql_update` (PLAN_0.3.0).
`sh:SPARQLRule` embeds a CONSTRUCT query that v0.12.0 rewrites to
an INSERT WHERE — also routed through `sparql_update` for the
per-rule shape, or through `rdf_construct_many` (engine v0.8.0)
for the batched shape (see below). RDF-star provenance annotations
ride PLAN_0.8.0's surface.

### Per-rule vs. batched execution

Two implementation shapes are live as of engine v0.8.0; pick at
Phase B time:

1. **Per-rule (default — ships in v0.12.0 Phase B).**
   `materialise!` iterates rules and issues one `Sparql.execute`
   per rule per fixpoint iteration. N rules × M iterations =
   N×M FFI crossings + N×M SQL parses + N×M SPARQL parses.
   Simplest to reason about; honest about cost; the natural
   shape for low-rule-count shapes (~10 rules per shape).

2. **Batched (opt-in, engine v0.8.0).** `materialise!` collects
   all CONSTRUCT-shaped rules' queries into one
   `rdf_construct_many(queries_json)` call per iteration, parses
   the JSON-array result, attaches `:derivedBy <rule_iri>`
   annotations gem-side using the position-in-array convention
   (the `i`-th blob is the `i`-th rule's output), then
   bulk-inserts via `Sparql.bulk_insert` (engine
   `rdf_insert_many`). N rules × M iterations collapses to
   roughly **2 × M** FFI crossings (one construct_many + one
   bulk_insert per iteration), regardless of N. The per-rule
   SPARQL parse cost still happens N× (Oxigraph parses each
   query at evaluation time); savings are SQL/FFI overhead, not
   the SPARQL parser. Worthwhile when N ≥ ~20 rules per shape.

The two paths produce identical asserted graphs + identical
RDF-star annotations — the equivalence is pinned by a spec that
runs the same shape through both paths and `sameTerm`-compares
the inferred graphs.

The `sh:TripleRule` form does **not** fit `rdf_construct_many`
(it's an INSERT, not a CONSTRUCT). `sh:TripleRule` rules stay on
the per-rule `Sparql.execute` path even when the batched mode is
enabled; `sh:SPARQLRule` rules opt in. Mixing the two shapes
within a shape is fine — they iterate independently within each
fixpoint pass.

Phase B ships the per-rule path; Phase D (or a later phase, gated
on telemetry from MM) adds the batched opt-in. The engine surface
is ready today; gem-side adoption waits for a concrete
bottleneck signal per RS's posture on the engine's "Requested
extensions" section.

## Why SHACL Rules (and not "just use OWL 2 RL")

The research doc's OWL examples ("Anyone investigating a case is a
detective"; "A case has exactly one culprit") look like the same
shape as what an operator might write as a SHACL Rule. They're not.
Three axes the two derivation surfaces differ on:

| Axis | OWL 2 RL (PLAN_0.9.0) | SHACL Rules (PLAN_0.12.0) |
|---|---|---|
| **Scope of declaration** | Schema-level (ontology graph, declared in `ontology do … end`). One axiom applies to every instance of a class globally. | Shape-scoped. A rule attaches to a `sh:NodeShape`; it fires per focus node the shape targets. |
| **Authoring style** | RDF axioms over OWL vocabulary (`owl:equivalentClass`, `owl:TransitiveProperty`, `rdfs:subClassOf`). The rule set is fixed (W3C OWL 2 RL/RDF table). | Operator-authored. Each rule names its own derivation — `sh:TripleRule` with `subject`/`predicate`/`object` node expressions, or `sh:SPARQLRule` with arbitrary CONSTRUCT. |
| **Ordering + conditions** | No explicit order — rules fire to fixpoint, monotonic semantics. | `sh:order` orders rule application within a shape; `sh:condition` gates a rule on a referenced shape's conformance. Fixpoint applies *across* rules but not *within* an ordered set. |

For MM, the dividing line is roughly:

- **OWL 2 RL** for "things that follow from the schema's structure."
  A product is a schema:Product. schema:Product is a schema:Thing.
  So the product is a schema:Thing. (`rdfs:subClassOf` chase.)
- **SHACL Rules** for "things that follow from the focus node's
  state." A product has 10 inventory units. So the product is
  `mm:availability "in_stock"`. (A conditional formula whose
  inputs aren't ontological axioms.)

Operators don't have to pick — both surfaces compose in one
model. The orchestrator runs OWL first (the closure over the
schema), then SHACL Rules (the focus-node-scoped derivations).

## Gem-side scope

### Phase A — `Semantica::Shacl::Rules` derivation surface

The single entry point. Materialises SHACL Rules' derivations
into the same inferred graph PLAN_0.9.0's reasoner writes.

```ruby
Semantica::Shacl::Rules.materialise!(
  data_graph:   "urn:mm:graph:catalogue",
  shapes_graph: "urn:semantica:shapes:product",
  inferred:     "urn:mm:graph:catalogue:inferred",
  rules:        :all,                              # or :rule_iris, see below
  provenance:   true,
  max_iterations: 50,
)
# => { ok: true,
#      iterations: 2,
#      rules_fired: 8,                             # per-rule fire counts in :per_rule
#      derived:    34,
#      per_rule:   { "urn:...#productAvailability" => 18, ... },
#      fixpoint:   true }
```

Alternatively via the unified facade:

```ruby
Semantica::Reasoner.materialise!(
  asserted:    "urn:mm:graph:catalogue",
  inferred:    "urn:mm:graph:catalogue:inferred",
  rules:       [:owl_2_rl, :shacl_rules],          # both passes; OWL first
  shapes_graph: "urn:semantica:shapes:product",    # required for :shacl_rules
)
```

#### Implementation
- `Semantica::Shacl::Rules` is a module facade parallel to
  `Semantica::Reasoner` and `Semantica::Shacl`. Never raises;
  structured envelopes.
- `materialise!`:
  1. Validate inputs — same `:invalid_graph` /
     `:invalid_dsl` envelope shape as PLAN_0.9.0's reasoner.
  2. Enumerate rules from `shapes_graph:`: every node typed
     `sh:TripleRule` or `sh:SPARQLRule`, attached via
     `sh:rule` to a `sh:NodeShape`. Skip rules with
     `sh:deactivated true`.
  3. Topological-sort rules by `sh:order` (default: 0;
     stable within a tied order).
  4. For each rule, resolve target focus nodes via the
     parent shape's `sh:target*` clauses (reuse PLAN_0.10.0's
     focus-node resolution).
  5. For each (rule, focus_node), evaluate `sh:condition`
     (if present): only fire if the focus node conforms to
     the referenced condition shape. The condition shape's
     conformance check rides PLAN_0.10.0's validator.
  6. Materialise the rule's output as a SPARQL UPDATE:
     - `sh:TripleRule` → `INSERT { ?focus <p_expr> ?o_expr } WHERE { … }`
     - `sh:SPARQLRule` → rewrite `CONSTRUCT { … } WHERE { … }`
       to `INSERT { … } WHERE { … }` with the focus binding
       pre-resolved.
  7. Iterate to fixpoint within the rules list. Cross-rule
     dependencies (rule B's premise was rule A's head)
     trigger another pass until no rule inserts anything new.
  8. `max_iterations` guards non-termination; refuse
     `:reasoner_diverged` (reusing PLAN_0.9.0's symbol).
- `provenance: true` annotates each derived triple via
  PLAN_0.8.0's annotation shorthand:
  `<derived_triple> {| :derivedBy <rule_iri> ; :derivedAt NOW() ; :derivedFrom << premise >> |} .`

#### Refusal envelope additions
- `:invalid_graph` — pre-existing.
- `:rule_parse_error` — `sh:SPARQLRule`'s embedded CONSTRUCT
  fails to parse. Envelope includes the rule IRI + the engine's
  parse error.
- `:unknown_rule_type` — a shape declares a rule with a
  `rdf:type` v0.12.0 doesn't implement (most likely
  `sh:JSRule`). Envelope lists the unknown IRIs.
- `:condition_shape_missing` — a rule's `sh:condition` references
  a shape IRI that doesn't exist in `shapes_graph:`.

#### Exit criteria
- Spec: a shape with one `sh:TripleRule` materialises the
  expected derivation against each focus node.
- Spec: a shape with one `sh:SPARQLRule` materialises the
  CONSTRUCT-output triples against the data graph.
- Spec: rule ordering — two rules with `sh:order` 1 + 2 fire
  in order; the second can see the first's output.
- Spec: `sh:deactivated true` skips the rule entirely.
- Spec: `sh:condition` gates the rule; non-conforming focus
  nodes don't trigger.
- Spec: unknown rule type refuses with
  `:unknown_rule_type` + the IRI list.

### Phase B — DSL: `rule do … end` recorders on the `Shape` concern

Operators declare rules on the AR class via the same `shape do … end`
block PLAN_0.10.0 introduced for validation.

```ruby
class Product < ApplicationRecord
  include Semantica::Storable
  include Semantica::Shacl::Shape

  triples do
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }
    triple "mm:inventory", -> { inventory_count }
  end

  shape do
    target_class "schema:Product"

    property "schema:gtin" do
      min_count 1
      max_count 1
      pattern '^\d{13}$'
    end

    # Triple rule — single-triple derivation per focus node
    triple_rule do
      description "Derive availability flag from inventory"
      order       1
      subject     :focus_node
      predicate   "mm:availability"
      object      sparql: "IF(?inv > 0, 'in_stock', 'out_of_stock')",
                  bind:   { inv: "mm:inventory" }
    end

    # SPARQL rule — full CONSTRUCT
    sparql_rule do
      description "Promote products with >100 orders to VIP"
      order       2
      condition   "urn:semantica:shape:Product"    # only validating products
      construct <<~SPARQL
        CONSTRUCT { ?focus mm:tier mm:VIP . }
        WHERE   { ?focus mm:total_orders ?n . FILTER(?n > 100) }
      SPARQL
    end
  end
end
```

#### Implementation
- New DSL keywords on the `Shape` recorder:
  - `triple_rule do … end` — captures
    `description`, `order`, `condition`, `deactivated`,
    `subject`, `predicate`, `object` (with `sparql:` /
    `bind:` for derived-value expressions, or a plain string
    for static IRIs/literals).
  - `sparql_rule do … end` — captures
    `description`, `order`, `condition`, `deactivated`, and
    a `construct` string (the embedded CONSTRUCT).
- Both recorders finalize to a frozen `Rule` value object
  (`Semantica::Shacl::Rule`) and emit the corresponding RDF
  triples into the shapes graph (idempotent — same
  read-replace dispatch the rest of `Shape` uses).
- Each rule is emitted with a stable IRI:
  `urn:semantica:rule:<class_name>/<rule_index>`.
- The two recorder types share a base — `Rule::TripleRule` and
  `Rule::SparqlRule` both subclass `Semantica::Shacl::Rule`.
- Class methods on the AR model:
  - `Product.materialise_rules!(scope:)` — convenience
    wrapper for `Semantica::Shacl::Rules.materialise!`
    against the model's shapes graph.
  - `Product.rule_iris` — list of rule IRIs declared on the
    model (useful for selective derivation:
    `Rules.materialise!(rules: Product.rule_iris)`).

#### `subject :focus_node` semantics
- `:focus_node` is the special symbol resolving to the rule's
  current focus node binding. Other allowed shapes:
  - `:focus_node` — the focus node itself.
  - `String` (IRI) — a constant subject (rare; the rule
    derives a single global triple if every focus node
    matches).
  - `sparql: "…", bind: { … }` — a derived IRI from a SPARQL
    expression.
- Same options apply to `object`. `predicate` is always a
  static IRI (matching the W3C SHACL Rules constraint that
  predicate position is IRI-only).

#### Exit criteria
- Spec: declaring a `triple_rule` block emits the W3C-conformant
  `sh:TripleRule` triple set into the shapes graph
  (round-trippable through `Sparql.construct`).
- Spec: declaring a `sparql_rule` block emits a
  `sh:SPARQLRule` triple set with the embedded CONSTRUCT
  string serialised correctly.
- Spec: rule emission is idempotent across process restarts.
- Spec: `Product.materialise_rules!(scope:)` runs against a
  scope-specific data graph and returns the envelope.

### Phase C — Composition with OWL 2 RL: orchestration order

When operators declare *both* an `ontology do … end` (OWL 2 RL)
and a `shape do … end` with `rule_do`s (SHACL Rules) on the same
model, the orchestrator runs them in a pinned order.

#### Pinned order
1. **OWL 2 RL** materialises first — schema-level closure over
   `rdfs:subClassOf`, `owl:TransitiveProperty`, etc.
2. **SHACL Rules** runs second — focus-node-scoped derivations
   may reference OWL-derived classes (e.g., `target_class
   :Detective` where `:Detective` was OWL-derived).
3. **SHACL validation** runs last (PLAN_0.10.0) — both
   asserted and inferred triples participate in constraint
   evaluation.

#### Implementation
- `Semantica::Reasoner.materialise!` accepts `rules:` as an
  array; values `:owl_2_rl` and `:shacl_rules` (with a
  required `shapes_graph:` kwarg when the latter is present)
  run the two passes in array order.
- The combined-pass orchestrator (`Semantica::IncrementalPass`
  from PLAN_0.11.0) gets a new pinned default ordering:
  `[:owl_2_rl, :shacl_rules]` followed by validation.
- Operators with circular dependencies between the two surfaces
  (an OWL axiom whose result is a SHACL Rule's premise that
  derives a triple the OWL axiom re-fires on) hit the
  outer-loop fixpoint detection: `materialise!` iterates over
  the whole pipeline until fixpoint.

#### Exit criteria
- Spec: a model with both `ontology do … end` and
  `shape do; triple_rule do …; end; end` produces the
  combined closure: OWL-derived classes used by SHACL Rules'
  target resolution.
- Spec: cross-surface circular dependency hits the outer
  fixpoint (or `:reasoner_diverged` if it doesn't terminate).
- Spec: validation runs against the **combined** closure
  (asserted + OWL-derived + SHACL-Rules-derived), per
  PLAN_0.10.0's full-pass semantics.

### Phase D — Incremental composition with DRed (PLAN_0.11.0)

SHACL Rules derivations participate in DRed identically to OWL 2
RL derivations — same `:derivedFrom << premise >>` annotation,
same over-delete-then-rederive cycle.

#### Implementation
- The orchestrator's incremental path
  (`Semantica::IncrementalPass.materialise_incremental!`) calls
  `Shacl::Rules.materialise_incremental!` after
  `Reasoner.materialise_incremental!` — same pinned order as
  full-pass.
- `Shacl::Rules.materialise_incremental!(asserted:, inferred:,
  shapes_graph:, changes:, …)` runs DRed Phase 1 + 2 over
  rule-derived triples:
  - Phase 1: drop every triple whose `:derivedBy` annotation
    names a SHACL rule IRI **and** whose `:derivedFrom`
    touches a retracted premise.
  - Phase 2: re-evaluate every rule whose triggering pattern
    matches the changed slice.
- Equivalence pin (PLAN_0.11.0's spec template): incremental
  vs. full-pass produces identical SHACL-Rules-derived triples
  modulo `:derivedAt` timestamps.

#### Exit criteria
- Spec: equivalence pin under DRed for SHACL Rules.
- Spec: a `Product.update!` changing `inventory_count` from
  10 to 0 over-deletes the prior `:in_stock` derivation and
  re-derives `:out_of_stock` without recomputing unrelated
  rules.
- Spec: a `Product.update!` whose only effect is on triples
  *not* referenced by any SHACL Rule's WHERE clause performs
  zero rule re-applications (asserted by spying on rule fire
  counts).

### Phase E — Lifecycle: extending the established ladder

No new lifecycle modes — SHACL Rules participate in the
existing `:explicit` / `:save` / `:incremental_save` policies
declared on the `shape do … end` block.

```ruby
shape do
  target_class "schema:Product"

  validate_on :incremental_save                     # PLAN_0.10.0 / PLAN_0.11.0
  derive_on   :incremental_save                     # v0.12.0 — sibling to validate_on

  triple_rule do …; end
end
```

#### Implementation
- `derive_on` is the new DSL keyword on the `Shape` recorder,
  shape-parallel to `validate_on`. Accepts `:explicit` (default),
  `:save` (full-pass derivation after every save),
  `:incremental_save` (DRed-driven incremental after every
  save), or a block.
- `:explicit` runs nothing automatically — operators call
  `Product.materialise_rules!(scope:)` on a schedule.
- `:save` calls `Shacl::Rules.materialise!` after each save.
- `:incremental_save` calls
  `Shacl::Rules.materialise_incremental!` driven by the
  change-set the `:incremental_save` mode in PLAN_0.11.0
  already captures. Falls back to full-pass when DRed exceeds
  the threshold (`:full_rebuild_required`).

#### Exit criteria
- Spec: each `derive_on` mode's pinned behaviour round-trips.
- Spec: `derive_on :incremental_save` shares the
  PLAN_0.11.0 change-set with `validate_on :incremental_save`
  + `materialise_on :incremental_save` — one `ChangeSet`
  drives all three.

### Phase F — Specs + bin/check

- New file `spec/semantica/shacl_rules_spec.rb` covering Phase A.
- New file `spec/semantica/shacl_rule_dsl_spec.rb` covering
  Phase B.
- New file `spec/semantica/shacl_rules_owl_composition_spec.rb`
  covering Phase C — the pinned ordering + cross-surface
  derivation interactions.
- New file `spec/semantica/shacl_rules_incremental_spec.rb`
  covering Phase D + the equivalence pin.
- W3C SHACL-AF test suite's rules slice — every test case
  exercising `sh:TripleRule` or `sh:SPARQLRule` (excluding
  the JS / NodeExpression cases) passes.
- `bin/check` green against engine ≥ 0.9.1 (no new pin — SHACL
  Rules rides the existing surfaces).

### Phase G — Docs

- `CHANGELOG.md` — `0.12.0` heading with per-phase entries.
- `README.md` — new "Derivation rules (SHACL Rules)" section
  after the SHACL Core section, with the `triple_rule` +
  `sparql_rule` examples, the OWL-vs-SHACL-Rules dividing line
  ("when to pick which"), and the five gotchas from "Risks"
  below.
- `CONSUMER_REQUIREMENT_MM.md` — promote SHACL Rules to a
  §10 surface block once MM signals adoption.
- `docs/plans/PLAN_0.12.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.12.0`.

## Out of scope for v0.12.0

- **`sh:JSRule`.** JavaScript-defined rules. W3C Note; needs
  a JS runtime in-process; gem won't take on the dependency.
  Same posture as PLAN_0.10.0's SHACL-JS exclusion.
- **SHACL-AF Node Expressions outside `sh:TripleRule`.**
  `sh:expression`, full path-expression evaluators, custom
  constraint components built on node expressions. Deferred
  indefinitely; revive on first ask.
- **Negation in SHACL Rules.** SHACL Rules are inherently
  forward-chaining and v0.12.0 enforces monotonicity (no
  `MINUS` / `FILTER NOT EXISTS` / `OPTIONAL` patterns whose
  removal of a premise would retract a derived triple — those
  break DRed correctness). Refuse with `:non_monotonic_rule_set`
  (reusing PLAN_0.11.0's symbol).
- **Rule priority across shapes.** `sh:order` orders rules
  *within* a shape; v0.12.0 does NOT define an ordering
  across rules belonging to different shapes. Operators
  authoring inter-shape rule dependencies must use
  `sh:condition` to express the dependency or accept
  the orchestrator's fixpoint behaviour.
- **Cross-graph rule derivation.** A rule attached to a shape
  in `shapes_graph: A` deriving into `inferred: B` where the
  premises come from `data_graph: C`. v0.12.0 ships
  single-asserted-graph / single-inferred-graph rule
  evaluation; multi-graph rules are a v0.13.0+ candidate.
- **Per-rule cost estimation.** v0.12.0 fires every rule
  every iteration; smart short-circuiting of unproductive
  rules is a v0.13.0+ optimisation.
- **Rule debugging hooks.** Per-rule fire counts are in the
  envelope (`per_rule:`); deeper introspection (e.g., "which
  focus nodes did this rule fire for and what did it derive?")
  is documented as a workaround via SPARQL queries against
  the `:derivedBy <rule_iri>` annotations on the inferred
  graph.
- **Rule deactivation via runtime flag.** `sh:deactivated true`
  in the shapes graph is the only deactivation surface. No
  per-call kwarg to skip a rule by IRI at `materialise!` time
  (operators rewrite the shapes graph if they want runtime
  control — or maintain two shapes graphs).
- **W3C SHACL-AF tests marked "FAILS" or "MANIFEST_DEFERRED"
  in the rules slice.** Documented in the spec rev v0.12.0
  ships against.

## Risks

| Risk | Mitigation |
|---|---|
| Operators confuse OWL 2 RL and SHACL Rules — pick the wrong derivation surface. | README opens with the OWL-vs-SHACL-Rules dividing-line table + the "schema-level" / "focus-node-level" framing. CONSUMER_REQUIREMENT_MM.md §10 mirrors the framing. The error path leads to "derivation works but the wrong tool" — not silent breakage. |
| Cross-surface circular dependencies blow up the outer fixpoint. | The outer fixpoint guard reuses PLAN_0.9.0's `max_iterations` semantics; `:reasoner_diverged` envelope includes `iterations:` so operators can spot it. README documents the failure mode + recommends decoupling via explicit rule ordering. |
| `sh:SPARQLRule` embedded CONSTRUCTs are a SQL-injection-shaped foot-gun if shapes come from untrusted sources. | Same posture as PLAN_0.10.0's `sh:select` risk. Document loudly: shape graphs are operator-authored, NOT user input. If MM ever sources shapes from untrusted sources, this v0.12.0 contract is the wrong tool. |
| `sh:order` semantics are subtle (within-shape ordering, no cross-shape ordering). | Spec each ordering case from the W3C SHACL-AF test suite. README has a worked example with a "common gotcha: order across shapes is undefined; use `sh:condition` for cross-shape dependencies" callout. |
| Operators expect `sh:JSRule` / `sh:expression` and don't get them. | README leads with the "rules slice only" framing + `:unknown_rule_type` refusal envelope. |
| Non-monotonic rules (MINUS / FILTER NOT EXISTS) break DRed correctness silently. | v0.12.0 statically inspects rule bodies for `MINUS` / `FILTER NOT EXISTS` / `OPTIONAL`-with-bind tokens; refuses with `:non_monotonic_rule_set`. False positives possible (some FILTER NOT EXISTS uses are monotonic in context); document the workaround as "rewrite to UNION + binding-then-filter" or use OWL 2 RL where applicable. |
| Per-rule fire counts blow up the envelope for shapes with hundreds of rules. | `per_rule:` is a Hash; operators worried about envelope size pass `per_rule: false` (default `true` for ergonomics). Documented. |
| Rule IRI naming (`urn:semantica:rule:<class_name>/<rule_index>`) becomes unstable when operators reorder rules in source. | The IRI uses *index* — reordering the source changes the IRI, which makes prior `:derivedBy` annotations point at "moved" rules. v0.12.0 documents the indexing convention; operators wanting IRI stability set `rule_iri "urn:..."` explicitly on the rule recorder. |
| Operators forget that SHACL Rules can be deactivated via `sh:deactivated true` (vs. removing them from the shape entirely). | Doc-only. README's "tune your shapes" section lists `sh:deactivated true` as the canonical way to toggle a rule off without deleting it. |
| Order of operations (OWL → SHACL Rules → SHACL validation) is opinionated and may surprise operators expecting a different order. | Pinned by spec; documented in CONSUMER_REQUIREMENT_MM.md. Operators wanting a different order author the orchestration manually via direct calls to `Reasoner.materialise!`, `Shacl::Rules.materialise!`, and `Shacl.validate!` in their preferred order. |

## Acceptance signal

1. Phases A/B/C/D/E land with passing specs.
2. Equivalence pin (incremental vs. full-pass for SHACL Rules)
   green.
3. Cross-surface composition spec (OWL 2 RL → SHACL Rules)
   green.
4. `bin/check` green against engine ≥ 0.9.1.
5. CHANGELOG `0.12.0` heading drops `(unreleased)`.
6. `VERSION` → `0.12.0`.
7. README documents the `triple_rule` + `sparql_rule` DSL,
   the OWL-vs-SHACL-Rules dividing line, the orchestration
   order, and the five headline gotchas.
8. CONSUMER_REQUIREMENT_MM.md §10 notes the new optional
   surface once MM signals adoption.
9. The W3C SHACL-AF test suite's rules slice (non-JS,
   non-NodeExpression cases) passes.

## v0.12.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Semantica::Shacl::Rules.materialise!(data_graph:, shapes_graph:, inferred:, rules:, provenance:, max_iterations:)` | module method | **Pinned.** |
| `Semantica::Shacl::Rules.materialise_incremental!(asserted:, inferred:, shapes_graph:, changes:, …)` | module method | **Pinned.** |
| `Semantica::Shacl::Rule` value object base | class | **Pinned.** |
| `Semantica::Shacl::Rule::TripleRule` + `::SparqlRule` subclasses | classes | **Pinned.** |
| `Storable::DSL` `shape do; triple_rule do; subject :focus_node; predicate "…"; object …; order N; condition "…"; deactivated true; end; sparql_rule do; construct "…"; …; end; end` | DSL keywords | **Pinned.** |
| `Storable::DSL` `shape do; derive_on :explicit\|:save\|:incremental_save\|{block}; end` | DSL keyword | **Pinned.** |
| `Semantica::Reasoner.materialise!` `rules:` accepts array `[:owl_2_rl, :shacl_rules]` | shape extension | **Pinned.** |
| `:rule_parse_error` reason symbol | refusal envelope | **Pinned.** |
| `:unknown_rule_type` reason symbol | refusal envelope (includes IRI list) | **Pinned.** |
| `:condition_shape_missing` reason symbol | refusal envelope | **Pinned.** |
| Envelope fields: `rules_fired:`, `per_rule:` (Hash<IRI, Int>) | rules-materialise! return | **Pinned.** |
| Rule IRI convention (`urn:semantica:rule:<class_name>/<rule_index>`) | derived default | **Pinned**. Operators set `rule_iri "..."` for stability. |

## Cross-references

- `./PLAN_0.3.0.md` — `sparql_update` carries both
  `sh:TripleRule` INSERT WHERE and `sh:SPARQLRule`
  CONSTRUCT-rewritten-as-INSERT.
- `./PLAN_0.5.0.md` — named graphs scope data / shapes /
  inferred / report.
- `./PLAN_0.7.0.md` — EtherealGraph; rule-derived graphs
  persist via Active Storage if operators want the closure
  to survive process restarts.
- `./PLAN_0.8.0.md` — RDF-star; the `:derivedBy <rule_iri> ;
  :derivedFrom << premise >>` annotations on rule-derived
  triples use the v0.8.0 annotation surface.
- `./PLAN_0.9.0.md` — OWL 2 RL reasoner; sibling-by-design.
  v0.12.0's composition section pins the order.
- `./PLAN_0.10.0.md` — SHACL Core. v0.12.0 extends the
  `Shape` concern's DSL with `triple_rule` + `sparql_rule`.
- `./PLAN_0.11.0.md` — DRed incremental. SHACL Rules
  derivations participate in the same dependency-graph
  traversal as OWL 2 RL derivations.
- `../research/TripesQuadsEtc.md` — the motivating sketch's
  OWL rung. v0.12.0 closes the focus-node-derivation gap
  the OWL rung doesn't cover.
- W3C SHACL Advanced Features (8 June 2017 Note)
  <https://www.w3.org/TR/shacl-af/> — the spec the rules
  slice transcribes.
- W3C SHACL test suite <https://w3c.github.io/data-shapes/data-shapes-test-suite/>
  — the integration safety net for Phase B + Phase F.
- DRed (Gupta, Mumick, Subrahmanian 1993) — incremental
  Datalog over the unified dependency graph.
- `sqlite-sparql/CHANGELOG.md` § `0.9.1` — engine pin v0.12.0
  inherits from v0.8.0 / v0.9.1 / v0.10.0 / v0.11.0. The 0.8.0
  release landed `rdf_construct_many` — the batched-execution
  surface v0.12.0's opt-in shape rides on.
