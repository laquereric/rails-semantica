# PLAN_0.11.0 — `rails-semantica` incremental reasoning + validation

> *PLAN_0.9.0 ships forward-chaining OWL 2 RL via full re-materialisation;
> PLAN_0.10.0 ships SHACL Core via full re-validation. Both are O(N) in
> the asserted graph size — fine for the explicit cron-job /
> batch-trigger shape MM exercises today, painful the moment MM wants
> "after every `Product.update!`, refresh the closure + report." v0.11.0
> closes that gap with the operationally-realistic shape: a **change-set**
> abstraction at the gem boundary, a **DRed (delete-and-rederive)**
> incremental reasoner over v0.8.0's RDF-star provenance graph, and a
> **focus-node-scoped** incremental SHACL validator. The dependency
> graph **is** the RDF-star `:derivedFrom` annotations v0.9.0 already
> emits; v0.11.0 doesn't introduce a parallel index — it learns to
> traverse the one that's already there. Engine-side dependency indices
> (faster but invasive) stay out of scope; revisit if MM hits workloads
> where DRed-via-SPARQL-UPDATE doesn't keep up.*

## Current state

**Draft (not yet started).** Strictly sequenced after PLAN_0.9.0 and
PLAN_0.10.0 — the incremental surface is "do less of the same work,"
which only exists once the full-pass shape exists. v0.11.0's plan
captures the gem-side seams now so the substrate-side consumer (MM's
reasoner subagent in vv-memory's Silver tier) can pin the shape before
the implementation lands.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `PLAN_0.9.0.md` | this dir | OWL 2 RL forward-chaining reasoner. v0.11.0 adds the incremental sibling to `Semantica::Reasoner` without replacing the full-pass `materialise!`. The two coexist — full-pass is the "rebuild from scratch" path; incremental is the "apply this change set" path. |
| `PLAN_0.10.0.md` | this dir | SHACL Core validator. v0.11.0 adds `Semantica::Shacl.validate_incremental!` alongside the full `validate!`. The validator's incremental surface is focus-node-scoped; the reasoner's incremental surface is rule-application-scoped. |
| `PLAN_0.8.0.md` | this dir | RDF-star. The `:derivedFrom << premise >>` annotations PLAN_0.9.0 emits **are** the dependency graph v0.11.0's DRed algorithm traverses. No parallel index. |
| `PLAN_0.5.0.md` | this dir | Named graphs. The change-set is itself a graph (`urn:semantica:changeset:<id>`) — operators can introspect, replay, or persist it. |
| `PLAN_0.3.0.md` | this dir | `sparql_update` arbitrary-UPDATE path the DRed delete + re-derive phases ride through. |
| W3C OWL 2 RL/RDF rules + DRed literature | spec + research | DRed (Delete-and-Rederive; Gupta, Mumick, Subrahmanian 1993) is the classical incremental-Datalog algorithm. v0.11.0 implements DRed over OWL 2 RL — the rules are the same; the *application strategy* changes. |
| Differential dataflow / RDFox semi-naive | research | The faster algorithm v0.11.0 deliberately *doesn't* implement. Out of scope; revive if DRed-via-SPARQL doesn't scale. |
| MM-side incremental research note | MM repo | **TBD** — companion to `magentic-market-ai/docs/research/StarExts.md`. Open questions: where does change-set capture wrap the AR write boundary? Is the Conformer's "extract triples from new episode" a natural change-set boundary? |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Drift target. v0.11.0 adds the incremental surface block once MM signals adoption. |

## Engine prerequisites (sqlite-sparql ≥ 0.9.1) — **already satisfied**

**No new engine surface.** DRed's two phases are both expressible in
SPARQL UPDATE:

1. **Over-deletion.** `DELETE { ?s ?p ?o } WHERE { << ?s ?p ?o >> :derivedFrom ?retracted . }`
   — drop every inferred triple whose `:derivedFrom` provenance
   touches the retracted assertion. Recursive (an inferred triple
   may itself be premise for another inferred triple); v0.11.0
   iterates to fixpoint.
2. **Re-derivation.** Re-apply the rule set restricted to triples
   that still match each rule's WHERE clause after over-deletion.
   The fixpoint is the new closure.

Both phases ride `sparql_update` (PLAN_0.3.0) + the RDF-star surface
(PLAN_0.8.0). v0.11.0's incremental SHACL validation rides
`sparql_query` + the named-graph scoping that PLAN_0.10.0 already
emits.

If DRed-via-SPARQL turns out to be CPU-bound for MM's workloads, two
engine-side acceleration paths would unlock more work — both deferred:

1. **Native dependency index.** Engine maintains a side-table mapping
   each inferred triple ID to its premise triple IDs. Skips the
   SPARQL pattern-match per provenance lookup. Substantial engine
   work; revisit if MM hits CPU bound.
2. **Differential dataflow at the store layer.** Multi-version
   concurrent dataflow over the asserted graph; the closure updates
   as a stream of deltas. Much further-out; an entirely different
   storage shape.

v0.11.0 ships the SPARQL-driven shape and reserves the engine-side
acceleration for whichever proves to be the real bottleneck.

## Why DRed (and not Counting, or Backward-Forward, or differential dataflow)

Three classical incremental-Datalog algorithms; v0.11.0 picks DRed.

- **DRed (Delete-and-Rederive).** Over-delete every inferred triple
  whose support included a retracted premise; then re-derive
  anything that still has alternative support. Simple, correct,
  worst-case quadratic in the affected closure slice. **Picked**
  because its two phases map cleanly to the two SPARQL UPDATE
  forms (`DELETE WHERE`, `INSERT WHERE`) the engine already
  exposes, *and* because the v0.8.0 RDF-star provenance is the
  exact dependency record DRed reads.
- **Counting Algorithm.** Maintain a derivation-count per inferred
  triple; decrement on premise retraction; remove the triple
  iff count hits zero. Faster than DRed for retraction-heavy
  workloads but requires per-triple counters as RDF statements,
  which blows up the graph size. **Rejected** — the storage
  overhead negates the wins on the workload sizes MM is likely
  to hit.
- **Backward-Forward chaining.** Compute support lazily on retract,
  then forward-chain to fixpoint. More work than DRed on first
  retract; less on subsequent retracts of nearby premises.
  **Rejected** for v0.11.0 — the lazy-support pass needs an
  in-memory rule-evaluation graph the gem doesn't currently have.
  Revisit if DRed proves the wrong choice.
- **Differential dataflow.** Stream-based; multi-version. The
  modern best-in-class for incremental Datalog (RDFox uses it).
  **Out of scope** — needs engine-level work the gem can't drive
  unilaterally.

DRed is the right ceiling for the v0.11.0 surface: implementable in
the engine surfaces that already exist, correct, well-understood,
and good enough for the workload sizes MM signals demand for.

## Gem-side scope

### Phase A — `Semantica::ChangeSet` surface

The change-set is the v0.11.0 boundary object: an operator-visible,
serialisable, introspectable record of "what assertions did this
unit of work add and retract." Inputs to both the incremental
reasoner and the incremental validator.

```ruby
changes = Semantica::ChangeSet.capture(scope: "urn:mm:graph:catalogue") do
  product.update!(gtin: "1234567890123")           # → +/- triples on the catalogue graph
  product.product_specs.create!(name: "color", value: "blue")
  Semantica::Sparql.execute(                       # ad-hoc writes also caught
    "INSERT DATA { <urn:mm:product:1> <mm:badge> <urn:mm:badge:hot> . }",
    graph: "urn:mm:graph:catalogue",
  )
end

changes.added     # => Array<[s, p, o, graph]>
changes.retracted # => Array<[s, p, o, graph]>
changes.scope     # => "urn:mm:graph:catalogue"
changes.id        # => "01J8X4..." — ULID; the change-set IRI is "urn:semantica:changeset:#{id}"
changes.persist!  # writes the change-set into its own named graph for later replay / audit
```

#### Implementation
- `Semantica::ChangeSet` is a value object holding a frozen
  add/retract delta + scope IRI + ULID identifier.
- `ChangeSet.capture(scope:) { ... }`:
  1. Push a thread-local recorder.
  2. The `Sparql.execute` / `bulk_insert` / `bulk_delete` /
     `Storable` lifecycle paths consult the recorder before
     returning; on success they append `(s, p, o, graph)`
     tuples to the corresponding add/retract bucket.
  3. Block runs; recorder pops.
  4. Returns the ChangeSet.
- The recorder hook is one new instance method on each write
  path — the methods themselves don't change shape.
- `ChangeSet#persist!` writes
  `_:cs a semantica:ChangeSet ; semantica:added ?t ; semantica:retracted ?t .` etc.
  into `urn:semantica:changeset:#{id}`. Operators may also pass
  a ChangeSet to `Reasoner.materialise_incremental!` directly
  without persisting.
- `ChangeSet.replay(id)` loads a persisted change-set back into
  memory. Useful for testing + for replaying a change-set
  against a different scope.

#### Refusal envelope additions
- `:no_active_changeset` — a write path consults the recorder
  outside a `capture` block (only relevant if operators wrap
  the recorder manually; the default path is no-op).
- `:changeset_scope_mismatch` — a write inside `capture(scope: "A")`
  targets graph B; refuse rather than mix scopes silently.

#### Exit criteria
- Spec: `capture` block wrapping a `Product.update!` produces
  a ChangeSet with the expected retracts (old gtin triple) +
  adds (new gtin triple).
- Spec: ad-hoc `Sparql.execute("INSERT DATA …")` inside
  `capture` is recorded.
- Spec: write to a graph other than `scope:` refuses with
  `:changeset_scope_mismatch`.
- Spec: nested `capture` blocks raise — operators flatten or
  use the outer scope explicitly.
- Spec: `persist!` round-trips through `ChangeSet.replay`.

### Phase B — Incremental reasoner (DRed over RDF-star provenance)

The incremental sibling of PLAN_0.9.0's `Reasoner.materialise!`.
Same rule set, same inferred-graph IRI, same provenance shape —
the difference is "rebuild only the affected slice."

```ruby
Semantica::Reasoner.materialise_incremental!(
  asserted:    "urn:mm:graph:catalogue",
  inferred:    "urn:mm:graph:catalogue:inferred",
  changes:     changes,                    # ChangeSet from Phase A
  rules:       :owl_2_rl,                  # same RuleSet as full pass
  provenance:  true,
  max_iterations: 50,
)
# => { ok: true,
#      over_deleted: 47,                   # inferred triples dropped by DRed phase 1
#      rederived:    52,                   # inferred triples re-added in phase 2
#      net_derived:  5,                    # net change vs. prior closure
#      iterations:   3,
#      fixpoint:     true }
```

#### Implementation
- DRed Phase 1 (over-delete): for each retracted-by-change
  assertion T, find inferred triples I such that
  `<< I.s I.p I.o >> :derivedFrom << T.s T.p T.o >> .`,
  retract I, and recurse on triples that had I as premise.
  Iterate to fixpoint (an inferred triple may be derived
  transitively through ≥2 hops).
- DRed Phase 2 (re-derive): re-apply the rule set restricted
  to triples touched in Phase 1 (premises *or* heads) and to
  the change-set's added assertions. The full `Rules::OwlRl`
  set runs, but the WHERE clauses are pre-scoped — most rules
  match nothing on the restricted input and exit cheaply.
- Phase 2 emits the same RDF-star annotations PLAN_0.9.0 does:
  `:derivedBy :Rule_X ; :derivedAt NOW() ; :derivedFrom << premise >>`.
  Re-derived triples get a fresh `:derivedAt` timestamp (the
  derivation **is** new in this pass — the prior derivation
  was dropped in Phase 1).
- Iteration limit + `:reasoner_diverged` refusal mirror
  PLAN_0.9.0's full-pass semantics.

#### Correctness pin
- DRed is well-known to be correct for *monotonic* Datalog —
  OWL 2 RL is monotonic (no negation), so the algorithm
  applies cleanly. v0.11.0 specs the
  full-pass-vs-incremental equivalence: a graph + change-set
  passed through full-pass `materialise!` (rebuild from scratch
  on the post-change graph) and through `materialise_incremental!`
  produces the **same** inferred-graph contents (modulo
  `:derivedAt` timestamps).

#### Refusal envelope additions
- `:changeset_scope_mismatch_for_reasoner` — change-set's
  `scope:` differs from `asserted:`; refuse rather than
  silently apply wrong slice.
- `:full_rebuild_required` — heuristic refusal when the
  change-set is so large (e.g., >50% of the asserted-graph
  triple count) that DRed is provably slower than a fresh
  full-pass. Operators handle by calling `materialise!`
  instead.

#### Exit criteria
- Spec: equivalence under DRed (full-pass equality).
- Spec: retracting `:a rdfs:subClassOf :b` over-deletes
  `:x rdf:type :b` for every `:x rdf:type :a`, then
  re-derives whatever's still supported.
- Spec: adding `:y :investigates :Case1` (with rule
  `?x :investigates ?c → ?x rdf:type :Detective`)
  derives `:y rdf:type :Detective` without touching
  unrelated closures.
- Spec: large change-set triggers `:full_rebuild_required`
  with a hint envelope ("change-set ≥ threshold; call
  `materialise!` instead").

### Phase C — Incremental validator (focus-node-scoped SHACL)

The incremental sibling of PLAN_0.10.0's `Shacl.validate!`. Re-runs
SHACL Core constraints only against focus nodes the change-set
touched.

```ruby
Semantica::Shacl.validate_incremental!(
  data_graph:   "urn:mm:graph:catalogue",
  shapes_graph: "urn:semantica:shapes:product",
  report_graph: "urn:mm:graph:catalogue:report",
  changes:      changes,
)
# => { ok: true, conforms: <bool>, violations: [...], report_graph: "..." }
```

#### Implementation
- Compute the **affected focus-node set**: every distinct
  subject in `changes.added` and `changes.retracted` is a
  candidate focus node (it may have become a violation or
  ceased to be one).
- Plus the **shape-targeting transitive set**: focus nodes
  reached through any shape's `sh:targetSubjectsOf` /
  `sh:targetObjectsOf` / `sh:node` reference whose other end
  changed. Computed via a SPARQL SELECT against the shapes
  graph + the change-set.
- For each affected focus node, re-evaluate every constraint
  on every shape it targets. Delete prior `sh:ValidationResult`
  entries in the report graph for that focus node; re-insert
  the new ones.
- The `sh:ValidationReport` root's `sh:conforms` flag is
  recomputed at the end of the incremental pass: true iff the
  report graph holds zero `sh:ValidationResult` nodes.

#### Correctness pin
- v0.11.0 specs full-pass-vs-incremental equivalence: the
  report graph after `validate_incremental!` (against the
  pre-change report) equals the report graph after a fresh
  `validate!` against the post-change data graph (modulo
  the `semantica:reportedAt` timestamp).
- Edge case the spec pins: a shape with `sh:closed true` and
  `sh:ignoredProperties (rdf:type)` — when a focus node *not*
  in the change-set has a constraint that depends on a node
  that *is* in the change-set (via `sh:node`), the
  shape-targeting transitive set must include it. v0.11.0's
  reachability computation handles this; the spec exercises
  it.

#### Refusal envelope additions
- `:changeset_scope_mismatch_for_validator` — same shape as
  the reasoner's mismatch envelope.
- `:report_graph_stale` — the change-set was computed against
  a state that doesn't match the current report graph's
  baseline. Operators handle by calling `validate!` (full
  pass) to rebaseline.

#### Exit criteria
- Spec: equivalence (full-pass-vs-incremental).
- Spec: a `Product.update!` that introduces a violation lands
  exactly one new `sh:ValidationResult` for that product's
  focus node; unrelated focus nodes are not re-evaluated
  (asserted via spy on `Sparql.execute` call count).
- Spec: a `Product.update!` that *clears* a prior violation
  removes the prior `sh:ValidationResult` from the report.
- Spec: a shape edit (operator authored `Product.shape do; …; end`
  changes) triggers `:report_graph_stale` — full-pass
  required.

### Phase D — `Storable` integration: auto-capture + lifecycle

Operators rarely want to manually `ChangeSet.capture { ... }` on
every save. The auto-capture path wires it to the lifecycle ladder
PLAN_0.9.0 and PLAN_0.10.0 already established.

```ruby
class Product < ApplicationRecord
  include Semantica::Storable
  include Semantica::Shacl::Shape

  ontology do
    materialise_on :incremental_save   # new mode — see below
  end

  shape do
    validate_on :incremental_save      # new mode — same trigger
  end
end
```

#### `:incremental_save` semantics
- `after_save`: a per-record `ChangeSet` captures the delta
  produced by the `Storable` emission (the same dispatch that
  emits the asserted triples knows what it changed).
- The change-set then drives one combined incremental pass:
  reasoner `materialise_incremental!` followed by validator
  `validate_incremental!`. Order pinned: reason first,
  validate after.
- If reasoner refuses with `:full_rebuild_required`, the gem
  falls back to full `materialise!` + `validate!` and logs
  a warning (operator-visible via the envelope's
  `because:` clause).
- The combined pass runs inside the same DB transaction as
  the AR save (Rails-default behaviour for `after_save`).
  If either incremental step fails, the AR save rolls back
  too — fail-closed.

#### Implementation
- `:incremental_save` registers an `after_save` that wraps
  the existing emission inside `ChangeSet.capture`.
- The captured set drives the two-step incremental pass.
- A new shared `Semantica::IncrementalPass` orchestrator
  composes the reasoner + validator calls; it's the
  module-level home for the fall-back-to-full logic.

#### Exit criteria
- Spec: `:incremental_save` after `Product.update!` produces
  an updated inferred graph + an updated validation report —
  both reflect the post-update state.
- Spec: fall-back to full rebuild fires when DRed's
  `:full_rebuild_required` threshold trips; both surfaces
  remain consistent.
- Spec: a save that introduces a SHACL violation under
  `validate_on :incremental_save` raises `ShapeViolation`
  (consistent with PLAN_0.10.0's full-pass behaviour) and
  the AR save rolls back.
- Spec: composing with `Storable` only (no `Shape` concern)
  runs the reasoner incrementally but skips the validator —
  the orchestrator handles the optional-concern case.

### Phase E — Lifecycle: when does the incremental pass fire?

Three opt-in policies extending the established ladder:

```ruby
ontology do
  materialise_on :explicit             # PLAN_0.9.0 default
  materialise_on :save                 # PLAN_0.9.0 full-pass after save
  materialise_on :incremental_save     # v0.11.0 incremental after save
end

shape do
  validate_on :explicit
  validate_on :save
  validate_on :validation
  validate_on :incremental_save        # v0.11.0 incremental after save
end
```

`:incremental_save` is the recommended production shape. `:save`
(full pass) stays available for operators who prefer the
"correctness-by-recomputation" stance or whose graphs are
small-enough that the incremental overhead isn't worth it.

#### Exit criteria
- Spec: each lifecycle mode's pinned behaviour (no-op,
  full-pass, incremental, raise-on-violation, Rails-errors,
  block) round-trips.
- Spec: the doc-comment for each mode names its order-of-magnitude
  cost so operators picking a mode see the trade-off at the
  call site.

### Phase F — Specs + bin/check

- New file `spec/semantica/changeset_spec.rb` covering Phase A.
- New file `spec/semantica/reasoner_incremental_spec.rb` covering
  Phase B + the full-pass-vs-incremental equivalence pin.
- New file `spec/semantica/shacl_incremental_spec.rb` covering
  Phase C + the equivalence pin.
- New file `spec/semantica/storable_incremental_save_spec.rb`
  covering Phase D + E.
- `bin/check` green against engine ≥ 0.9.1 (no new pin — DRed
  rides the existing `sparql_update` + RDF-star surfaces).

### Phase G — Docs

- `CHANGELOG.md` — `0.11.0` heading with per-phase entries.
- `README.md` — new "Incremental reasoning + validation"
  section after the SHACL section, with the `ChangeSet.capture`
  example, the `:incremental_save` lifecycle mode, the
  equivalence guarantee, and the four gotchas from "Risks"
  below.
- `CONSUMER_REQUIREMENT_MM.md` — promote the incremental
  surface to its own §9 block once MM signals adoption.
- `docs/plans/PLAN_0.11.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.11.0`.

## Out of scope for v0.11.0

- **Engine-side dependency index.** Native side-table mapping
  inferred-triple IDs to premise IDs. Substantial engine work;
  revive only if DRed-via-SPARQL is provably the bottleneck.
- **Differential dataflow / RDFox-style incremental.** Stream-
  based multi-version closure maintenance. Different storage
  shape; out of reach for this gem.
- **Counting / Backward-Forward variants.** Considered + rejected
  for v0.11.0 (see "Why DRed"). Operators wanting a different
  algorithm fork `Semantica::Reasoner::Incremental`.
- **Cross-graph incremental.** A change in graph A triggering
  re-evaluation in graph B (via inferred cross-graph triples).
  The `:derivedFrom` annotations carry no graph label
  (PLAN_0.8.0 Out-of-scope: "no quoting of quads"); v0.11.0's
  DRed scopes incremental passes to a single asserted-graph
  IRI. Cross-graph workflows fall back to per-graph full
  passes. Document.
- **Negation / non-monotonic rules.** DRed is correct only for
  monotonic Datalog; OWL 2 RL is monotonic, so v0.11.0 is fine
  with the v0.9.0 rule library. Operator-authored rules that
  introduce negation break the equivalence pin. Refuse with
  `:non_monotonic_rule_set` if a future extension to the rule
  library carries negation.
- **Change-set merge / replay across scopes.** Combining two
  change-sets into one, or replaying a change-set captured
  against scope A onto scope B. The `id` + `persist!` shape
  supports replay-into-same-scope; cross-scope replay is a
  v0.12.0+ candidate.
- **Concurrent incremental passes against the same scope.**
  Per-(inferred-graph-IRI) Mutex in `Semantica::IncrementalPass`
  serialises calls. Two threads racing on the same scope get
  serialised; cross-scope passes run in parallel. Engine-side
  multi-writer support is a separate question.
- **Time-travel / point-in-time queries.** "What did the
  closure look like as of yesterday?" needs persistent
  change-set history + replay-to-time. v0.11.0 ships the
  `persist!` primitive but doesn't ship the query-as-of facade.
- **Operator-authored DRed instrumentation.** Hooks to
  observe over-delete / re-derive counts per rule. v0.11.0
  exposes per-pass totals in the envelope (`over_deleted:`,
  `rederived:`); per-rule breakdowns are v0.12.0+ if MM
  signals demand.
- **Change-set capture inside `Sparql.execute("CLEAR GRAPH …")`.**
  Treats the clear as a bulk retract of *every* triple in the
  graph — the change-set bloats. Operators should call
  `materialise!` (full pass) after a `CLEAR GRAPH` rather than
  routing through the incremental surface. Refuse with
  `:full_rebuild_required` after detecting a bulk clear.

## Risks

| Risk | Mitigation |
|---|---|
| DRed has worst-case quadratic behaviour on dense provenance graphs. | The `over_deleted:` / `rederived:` envelope fields are the operator-visible signal. README documents the failure mode + recommends `:full_rebuild_required` threshold tuning. Substrate-side telemetry (via MM's Conformer logs) is the canary. |
| RDF-star provenance annotations are size-multiplicative on the inferred graph; incremental over-delete scans them. | PLAN_0.8.0 already documented the size implication. v0.11.0 specs the over-delete time complexity as O(inferred × premise-fan-in); operators wanting a smaller provenance footprint set `provenance: false` at full-pass time — incremental still works but without the RDF-star payload (over-delete becomes O(inferred × rule-count) and slightly slower). |
| Equivalence pin breaks under operator-authored extensions to `Rules::OwlRl` that introduce non-monotonicity. | Refuse with `:non_monotonic_rule_set`. Specs assert the refusal fires on a synthetic non-monotonic rule. |
| Forgotten changes — operator wrote via `Sparql.execute` outside `ChangeSet.capture { … }` — silently desync the closure. | The `:explicit` / `:save` lifecycle modes (PLAN_0.9.0) stay available as the fall-back; running `materialise!` (full pass) re-baselines. Document. Operators wanting strict change-tracking can wrap the entire AR connection in a `capture` block at the request boundary (per-request middleware). |
| `:incremental_save` raises in-place if the validator finds a violation, surprising operators who only enabled the reasoner. | The orchestrator's combined-pass behaviour is documented per concern: enabling `ontology do; materialise_on :incremental_save` without `shape do; validate_on …` only fires the reasoner; the validator runs only when its own concern is present + opted in. |
| Change-set capture adds overhead to write paths even when no incremental pass is active. | The recorder hook is a thread-local check; no-op when the hook is unset (the common case). Spec asserts the overhead is bounded. |
| `:full_rebuild_required` threshold is heuristic and may be wrong for some workloads. | Operators override via `Semantica::Reasoner.incremental_threshold = ...` (Float, fraction of asserted-graph triples; default 0.5). README documents tuning. |
| Provenance-graph drift: an external write to the `:derivedFrom` predicates would confuse DRed. | The provenance graph IRI is the same as the inferred graph IRI (annotations live with the triples they annotate). Operators editing the inferred graph directly already break the closure; v0.11.0 documents that the provenance annotations are gem-owned within that graph. |
| Concurrent `materialise!` and `materialise_incremental!` against the same scope race. | Per-(inferred-graph-IRI) Mutex in `Semantica::IncrementalPass`; serialises both kinds of passes. Spec asserts the serialisation. |
| Test-suite flake under transactional rollback — an `after_save`-driven incremental pass that fails mid-DRed leaves the AR save rolled back but the engine's named-graph state may not roll back (the engine's transactional semantics are SQLite-driven, not Oxigraph-driven). | v0.11.0 wraps the DRed phases in a single SQLite transaction at the engine boundary (engine 0.7.0 already supports this — the connection's autocommit is off during the pass). Spec asserts engine-state rollback. |

## Acceptance signal

1. Phases A/B/C/D/E land with passing specs.
2. Equivalence pin (full-pass-vs-incremental) green for both
   reasoner and validator.
3. `bin/check` green against engine ≥ 0.9.1.
4. CHANGELOG `0.11.0` heading drops `(unreleased)`.
5. `VERSION` → `0.11.0`.
6. README documents `ChangeSet.capture`, the
   `:incremental_save` lifecycle mode, the equivalence
   guarantee, and the gotchas.
7. CONSUMER_REQUIREMENT_MM.md §9 notes the new optional
   surface once MM signals adoption.

## v0.11.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Semantica::ChangeSet` value object (`#added`, `#retracted`, `#scope`, `#id`, `#persist!`) | class | **Pinned.** |
| `Semantica::ChangeSet.capture(scope:) { ... }` block API | module method | **Pinned.** |
| `Semantica::ChangeSet.replay(id)` | module method | **Pinned.** |
| `Semantica::Reasoner.materialise_incremental!(asserted:, inferred:, changes:, rules: :owl_2_rl, provenance: true, max_iterations: 50)` | module method | **Pinned.** |
| `Semantica::Shacl.validate_incremental!(data_graph:, shapes_graph:, report_graph: nil, changes:, provenance: true)` | module method | **Pinned.** |
| `Semantica::IncrementalPass` orchestrator (composes reasoner + validator) | module | **Pinned name.** Internal composition. |
| `materialise_on :incremental_save` DSL value | DSL extension to PLAN_0.9.0's lifecycle | **Pinned.** |
| `validate_on :incremental_save` DSL value | DSL extension to PLAN_0.10.0's lifecycle | **Pinned.** |
| `Semantica::Reasoner.incremental_threshold` accessor | gem-level Float | **Pinned.** Default 0.5. |
| `:changeset_scope_mismatch` reason symbol | refusal envelope | **Pinned.** |
| `:changeset_scope_mismatch_for_reasoner` reason symbol | refusal envelope | **Pinned.** |
| `:changeset_scope_mismatch_for_validator` reason symbol | refusal envelope | **Pinned.** |
| `:full_rebuild_required` reason symbol | refusal envelope (includes `because:` hint) | **Pinned.** |
| `:report_graph_stale` reason symbol | refusal envelope | **Pinned.** |
| `:non_monotonic_rule_set` reason symbol | refusal envelope | **Pinned.** |
| Envelope fields: `over_deleted:`, `rederived:`, `net_derived:` | reasoner-incremental return | **Pinned.** |
| Change-set graph IRI shape (`urn:semantica:changeset:<ulid>`) | derived | **Internal**; operators introspect via the value object's `#id` accessor. |

## Cross-references

- `./PLAN_0.3.0.md` — `sparql_update` carries both DRed phases.
- `./PLAN_0.5.0.md` — named graphs scope the change-set, the
  asserted graph, the inferred graph, and the validation report.
- `./PLAN_0.7.0.md` — EtherealGraph; change-sets can be
  persisted via Active Storage if operators want change history
  to survive process restarts.
- `./PLAN_0.8.0.md` — RDF-star; the `:derivedFrom` annotations
  PLAN_0.8.0 surfaces + PLAN_0.9.0 emits are the dependency
  graph v0.11.0's DRed traverses.
- `./PLAN_0.9.0.md` — OWL 2 RL full-pass reasoner; v0.11.0 is
  the incremental sibling.
- `./PLAN_0.10.0.md` — SHACL Core full-pass validator; v0.11.0
  is the incremental sibling.
- `../research/TripesQuadsEtc.md` — the motivating sketch's
  OWL rung. v0.11.0 makes the OWL+SHACL surface affordable to
  run on every save.
- DRed (Gupta, Mumick, Subrahmanian 1993) — *Maintaining views
  incrementally* — the algorithm v0.11.0 implements.
- RDFox / differential dataflow literature — the
  out-of-scope-for-now next horizon if DRed proves insufficient.
- `sqlite-sparql/CHANGELOG.md` § `0.9.1` — engine pin v0.11.0
  inherits from v0.8.0 / v0.9.1 / v0.10.0.
