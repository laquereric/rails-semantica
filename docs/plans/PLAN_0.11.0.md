# PLAN_0.11.0 — `vv-graph` incremental reasoning + validation

> *PLAN_0.9.0 ships forward-chaining OWL 2 RL via full re-materialisation;
> PLAN_0.10.0 ships SHACL Core via full re-validation. Both are O(N) in
> the asserted graph size — fine for the explicit cron-job /
> batch-trigger shape MM exercises today, painful the moment MM wants
> "after every `Product.update!`, refresh the closure + report." v0.11.0
> closes that gap with the operationally-realistic shape: a **change-set**
> abstraction at the gem boundary, a **DRed (delete-and-rederive)**
> incremental reasoner, and a **focus-node-scoped** incremental SHACL
> validator. The original draft of this plan deferred any engine-side
> dependency index; in the meantime engine v0.12.0 shipped
> `rdf_dred_overdelete` + `track_dependencies`, so the gem-side DRed
> phase now has **two** dependency surfaces it can walk: the native
> in-memory side-table (fast, opt-in via `track_dependencies: true`, 5
> of 60 OWL 2 RL rules covered today) and the v0.8.0 RDF-star
> `:derivedFrom` annotation graph (slower SPARQL pattern match, every
> rule covered, no engine option required). v0.11.0 picks whichever
> surface answers the question and falls back to the other when it
> can't.*

## Current state

**Draft (not yet started).** Strictly sequenced after PLAN_0.9.0 and
PLAN_0.10.0 — the incremental surface is "do less of the same work,"
which only exists once the full-pass shape exists. v0.11.0's plan
captures the gem-side seams now so the substrate-side consumer (MM's
reasoner subagent in vv-memory's Silver tier) can pin the shape before
the implementation lands.

This revision (the second draft) reflects two shifts:

1. **Engine v0.12.0** shipped `rdf_dred_overdelete` + the
   `track_dependencies` option on `rdf_owl_rl_materialise` — driven
   by `CONSUMER_REQUIREMENT_VvGraph.md` § "Requested extensions"
   item **#8** which this plan emitted. The over-delete phase that
   the original draft routed through `sparql_update` over RDF-star
   annotations now has a native single-FFI-crossing path for the
   five core derivation rules (`scm-sco`, `scm-spo`, `eq-trans`,
   `cax-sco`, `prp-spo1`) and a SPARQL-driven fall-back for the
   other 55.
2. **The rename to `vv-graph`** (v0.15.0) moved every public surface
   from `Semantica::*` to `Vv::Graph::*`. This plan was drafted
   before the rename; this revision uses the post-rename namespace.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `PLAN_0.9.0.md` | this dir | OWL 2 RL forward-chaining reasoner. v0.11.0 adds the incremental sibling to `Vv::Graph::Reasoner` without replacing the full-pass `materialise!`. The two coexist — full-pass is the "rebuild from scratch" path; incremental is the "apply this change set" path. |
| `PLAN_0.10.0.md` | this dir | SHACL Core validator. v0.11.0 adds `Vv::Graph::Shacl.validate_incremental!` alongside the full `validate!`. The validator's incremental surface is focus-node-scoped; the reasoner's incremental surface is rule-application-scoped. |
| `PLAN_0.8.0.md` | this dir | RDF-star. The `:derivedFrom << premise >>` annotations PLAN_0.9.0 emits are the **fall-back** dependency surface v0.11.0's DRed traverses for any rule the engine's native index doesn't yet cover. |
| `PLAN_0.5.0.md` | this dir | Named graphs. The change-set is itself a graph (`urn:vv-graph:changeset:<id>`) — operators can introspect, replay, or persist it. |
| `PLAN_0.3.0.md` | this dir | `sparql_update` arbitrary-UPDATE path the SPARQL-driven DRed fall-back rides through. |
| `../research/DRed.md` | research | One-page primer on Delete-and-Rederive — over-deletion + rederivation, drawbacks (the "many independent derivations" cost the per-derivation index in engine 0.12.0 directly addresses). The reading every reviewer needs before the "Why DRed" section below. |
| W3C OWL 2 RL/RDF rules + DRed literature | spec + research | DRed (Delete-and-Rederive; Gupta, Mumick, Subrahmanian 1993) is the classical incremental-Datalog algorithm. v0.11.0 implements DRed over OWL 2 RL — the rules are the same; the *application strategy* changes. |
| Differential dataflow / RDFox semi-naive | research | The faster algorithm v0.11.0 deliberately *doesn't* implement. Out of scope; revive if both DRed paths combined still don't keep up. |
| MM-side incremental research note | MM repo | **TBD** — companion to `magentic-market-ai/docs/research/StarExts.md`. Open questions: where does change-set capture wrap the AR write boundary? Is the Conformer's "extract triples from new episode" a natural change-set boundary? |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Drift target. v0.11.0 adds the incremental surface block once MM signals adoption. |
| `CONSUMER_REQUIREMENT_VvGraph.md` § "Requested extensions" item #8 | engine repo (`vendor/sqlite-sparql/`) | The driver behind engine v0.12.0's `rdf_dred_overdelete`. Already marked **LANDED in 0.12.0** on the engine side; v0.11.0 is the gem-side integration that consumes it. |

## Engine prerequisites (sqlite-sparql ≥ 0.12.0) — **bumped from ≥ 0.9.1**

Engine v0.12.0 ships the two surfaces v0.11.0's gem-side DRed wants:

1. **`rdf_owl_rl_materialise(asserted, inferred, options_json)`** with
   the new option `{"track_dependencies": true}`. When tracking is on
   the engine populates an in-memory `DependencyIndex` mapping each
   inferred quad to a per-derivation `Vec<HashSet<Quad>>` of premises.
   Only 5 of the 60 OWL 2 RL rules (`scm-sco`, `scm-spo`, `eq-trans`,
   `cax-sco`, `prp-spo1`) write through to the index today; the
   remaining 55 fire normally but produce no index entries.
2. **`rdf_dred_overdelete(inferred_iri, retracted_premises_json) →
   INTEGER`** — given a JSON array of retracted asserted-graph
   premises, walks the dependency index transitively (an
   over-deleted inferred quad is treated as a retracted premise for
   downstream derivations until the worklist empties), removes the
   over-deleted quads from the store, and returns the count. The
   cascade decides multi-derivation correctness locally
   ("remove only when *every* derivation has been broken") using the
   per-derivation list — pinned by the engine's
   `test_rdf_dred_overdelete_multi_derivation` test.

The index is in-memory and process-scoped; `rdf_clear()` clears it
in lockstep. Persistence across process restarts ties to the
deferred RocksDB backend — until then every cold start needs a
fresh `rdf_owl_rl_materialise(... track_dependencies: true)` to
repopulate the index before `rdf_dred_overdelete` can do anything
useful. v0.11.0's gem-side code treats this as a startup invariant:
if `track_dependencies` is on for a model, the first incremental
pass after a process boot does a full-pass `materialise!` with
tracking on to rebuild the index, then incremental from there.

**SPARQL-driven fall-back path stays live.** DRed's two phases are
both expressible in pure SPARQL UPDATE over v0.8.0's RDF-star
annotations:

1. **Over-deletion (SPARQL fall-back).**
   `DELETE { ?s ?p ?o } WHERE { << ?s ?p ?o >> :derivedFrom ?retracted . }`
   — drop every inferred triple whose `:derivedFrom` provenance
   touches the retracted assertion. Recursive (an inferred triple
   may itself be premise for another); the gem iterates to fixpoint.
2. **Re-derivation.** Re-apply the rule set restricted to triples
   that still match each rule's WHERE clause after over-deletion.

The fall-back is correct for every OWL 2 RL rule; it's slower per
retracted premise because each premise becomes a SPARQL pattern
match against the annotation graph rather than an O(log N) index
lookup. v0.11.0 uses the fall-back automatically when a rule that
derived the affected inferred slice isn't in the engine's
index-covered set, or when `provenance: true` wasn't on at
materialise time, or when `track_dependencies: false` (e.g.,
operators who don't want the per-derivation allocation cost).

If either path turns out to be CPU-bound for MM's workloads at
scale, two further engine-side accelerations remain on the table:

1. **Tracking the remaining 55 OWL 2 RL rules.** Mechanical —
   each rule mirrors its premise-collecting helper to retain
   source `Quad`s. Documented as out-of-scope in engine
   `CHANGELOG.md` § 0.12.0 ("Out of scope (revisit on consumer
   signal)"). v0.11.0's gem-side adoption is the consumer signal
   that drives it once we measure which of the 55 actually
   matter on MM's workloads.
2. **Differential dataflow at the store layer.** Multi-version
   concurrent dataflow over the asserted graph; the closure
   updates as a stream of deltas. Much further-out; an entirely
   different storage shape. Pinned at "out of scope; revisit if
   DRed-with-native-index isn't enough" per the engine plan's
   posture.

## Why DRed (and not Counting, or Backward-Forward, or differential dataflow)

Three classical incremental-Datalog algorithms; v0.11.0 picks DRed.
The DRed primer at `../research/DRed.md` is the prerequisite read.

- **DRed (Delete-and-Rederive).** Over-delete every inferred triple
  whose support included a retracted premise; then re-derive
  anything that still has alternative support. Simple, correct,
  worst-case quadratic in the affected closure slice. The
  drawback the literature flags ("when a derived fact has many
  independent derivations, over-deletion forces expensive
  re-evaluation to put validly-inferred information back") is
  exactly what engine v0.12.0's per-derivation index addresses:
  the cascade locally decides "this quad still has another
  derivation, leave it alone" rather than over-deleting and then
  re-deriving. **Picked** because (a) its two phases map cleanly
  to the engine surfaces that already exist, (b) the v0.12.0
  per-derivation index removes the worst of DRed's classical
  drawback, and (c) the v0.8.0 RDF-star provenance is the
  fall-back dependency record for the 55 rules the index doesn't
  cover yet — same algorithm, two implementation surfaces.
- **Counting Algorithm.** Maintain a derivation-count per inferred
  triple; decrement on premise retraction; remove the triple
  iff count hits zero. Faster than DRed for retraction-heavy
  workloads but requires per-triple counters as RDF statements,
  which blows up the graph size. **Rejected** — the storage
  overhead negates the wins on the workload sizes MM is likely
  to hit. (Engine v0.12.0's per-derivation list is structurally
  similar but stays in native memory rather than spreading into
  the RDF graph.)
- **Backward-Forward chaining.** Compute support lazily on retract,
  then forward-chain to fixpoint. More work than DRed on first
  retract; less on subsequent retracts of nearby premises.
  **Rejected** for v0.11.0 — the lazy-support pass needs an
  in-memory rule-evaluation graph the gem doesn't currently have
  (and that the engine doesn't expose).
- **Differential dataflow.** Stream-based; multi-version. The
  modern best-in-class for incremental Datalog (RDFox uses it).
  **Out of scope** — needs engine-level work the gem can't drive
  unilaterally. Revisit if DRed-with-native-index isn't enough.

DRed is the right ceiling for the v0.11.0 surface: implementable
against engine surfaces that exist today, correct, well-understood,
its classical drawback already mitigated by the per-derivation
index, and good enough for the workload sizes MM signals demand for.

## Gem-side scope

### Phase A — `Vv::Graph::ChangeSet` surface

The change-set is the v0.11.0 boundary object: an operator-visible,
serialisable, introspectable record of "what assertions did this
unit of work add and retract." Inputs to both the incremental
reasoner and the incremental validator.

```ruby
changes = Vv::Graph::ChangeSet.capture(scope: "urn:mm:graph:catalogue") do
  product.update!(gtin: "1234567890123")           # → +/- triples on the catalogue graph
  product.product_specs.create!(name: "color", value: "blue")
  Vv::Graph::Sparql.execute(                       # ad-hoc writes also caught
    "INSERT DATA { <urn:mm:product:1> <mm:badge> <urn:mm:badge:hot> . }",
    graph: "urn:mm:graph:catalogue",
  )
end

changes.added     # => Array<[s, p, o, graph]>
changes.retracted # => Array<[s, p, o, graph]>
changes.scope     # => "urn:mm:graph:catalogue"
changes.id        # => "01J8X4..." — ULID; the change-set IRI is "urn:vv-graph:changeset:#{id}"
changes.persist!  # writes the change-set into its own named graph for later replay / audit
```

#### Implementation
- `Vv::Graph::ChangeSet` is a value object holding a frozen
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
  `_:cs a vg:ChangeSet ; vg:added ?t ; vg:retracted ?t .` etc.
  into `urn:vv-graph:changeset:#{id}`. Operators may also pass
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

### Phase B — Incremental reasoner (DRed over the dependency index, with SPARQL fall-back)

The incremental sibling of PLAN_0.9.0's `Reasoner.materialise!`.
Same rule set, same inferred-graph IRI, same provenance shape —
the difference is "rebuild only the affected slice."

```ruby
Vv::Graph::Reasoner.materialise_incremental!(
  asserted:    "urn:mm:graph:catalogue",
  inferred:    "urn:mm:graph:catalogue:inferred",
  changes:     changes,                    # ChangeSet from Phase A
  rules:       :owl_2_rl,                  # same RuleSet as full pass
  provenance:  true,                       # writes RDF-star annotations (fall-back surface)
  dependency_index: :native,               # :native (default), :sparql, or :auto
  max_iterations: 50,
)
# => { ok: true,
#      over_deleted: 47,                   # inferred quads dropped by DRed phase 1
#      over_deleted_via_index: 41,         # how many came from the native cascade
#      over_deleted_via_sparql: 6,         # how many came from the SPARQL fall-back
#      rederived:    52,                   # inferred quads re-added in phase 2
#      net_derived:  5,                    # net change vs. prior closure
#      iterations:   3,
#      fixpoint:     true,
#      index_dirty:  false }               # true if any rule fired outside the index-covered set
```

`Vv::Graph::Reasoner.dred!` is a thin alias to
`materialise_incremental!` for operators who want the algorithm
name at the call site (mirrors the engine's `rdf_dred_overdelete`
naming).

#### Implementation
- DRed Phase 1 (over-delete) chooses its surface per call:
  - `dependency_index: :native` — call `rdf_dred_overdelete(
    inferred, JSON.dump(changes.retracted_premises))` once per
    pass. The engine returns the over-deleted count; the gem
    increments `over_deleted_via_index`. Any rule outside the
    5-covered set that contributed to the inferred slice gets
    missed by the native cascade — the gem detects this by
    inspecting the post-cascade inferred graph for orphaned
    derivations (an inferred quad whose `:derivedFrom` no longer
    has any live premise) via a follow-up SPARQL pattern match
    and over-deletes them via `Sparql.execute("DELETE WHERE …")`.
    The follow-up count flows into `over_deleted_via_sparql`.
    `index_dirty: true` flags that the fall-back fired.
  - `dependency_index: :sparql` — skip the native call entirely;
    rely on the RDF-star annotation graph. Slower; correct for
    every rule including operator-authored extensions. The
    default when `track_dependencies: true` wasn't passed at
    materialise time (the gem checks via a sentinel
    `:vg:index_tracked` annotation it emits on the inferred
    graph at full-pass time).
  - `dependency_index: :auto` — prefer `:native`; gracefully
    degrade to `:sparql` if the native call returns the
    `"no dependency index"` envelope.
- DRed Phase 2 (re-derive): re-apply the rule set restricted
  to triples touched in Phase 1 (premises *or* heads) and to
  the change-set's added assertions. The full `Rules::OwlRl`
  set runs, but the WHERE clauses are pre-scoped — most rules
  match nothing on the restricted input and exit cheaply.
  When the native index path is active, Phase 2 calls
  `rdf_owl_rl_materialise(..., {"track_dependencies": true})`
  so the index stays warm for the next pass.
- Phase 2 emits the same RDF-star annotations PLAN_0.9.0 does:
  `:derivedBy :Rule_X ; :derivedAt NOW() ; :derivedFrom << premise >>`.
  Re-derived triples get a fresh `:derivedAt` timestamp (the
  derivation **is** new in this pass — the prior derivation
  was dropped in Phase 1).
- Iteration limit + `:reasoner_diverged` refusal mirror
  PLAN_0.9.0's full-pass semantics.

#### Cold-start invariant (process restart with native index)
- The native `DependencyIndex` is in-memory + process-scoped.
  After a process restart it's empty; `rdf_dred_overdelete`
  returns 0 for any retracted premise and the gem's
  `:auto` heuristic would silently degrade to `:sparql` —
  correct but slow, and the index never warms up.
- `Vv::Graph::Reasoner.warm_dependency_index!(inferred:)` rebuilds
  the index by re-running `rdf_owl_rl_materialise(...
  track_dependencies: true)` against the already-asserted graph.
  Operators with `materialise_on :incremental_save` and
  `dependency_index: :native` call this once at boot (Rails
  initializer); subsequent saves use the warmed index.
- The `:incremental_save` lifecycle mode in Phase D auto-calls
  `warm_dependency_index!` on first save after process boot
  (using a `Concurrent::AtomicBoolean` per inferred-graph IRI).
  Operators with hot-restart latency budgets warm explicitly.

#### Correctness pin
- DRed is well-known to be correct for *monotonic* Datalog —
  OWL 2 RL is monotonic (no negation), so the algorithm
  applies cleanly. v0.11.0 specs the
  full-pass-vs-incremental equivalence: a graph + change-set
  passed through full-pass `materialise!` (rebuild from scratch
  on the post-change graph) and through `materialise_incremental!`
  produces the **same** inferred-graph contents (modulo
  `:derivedAt` timestamps).
- The equivalence pin runs **three times** — once per
  `dependency_index:` value (`:native`, `:sparql`, `:auto`).
  All three converge on the same closure; the
  `over_deleted_via_*` envelope fields differ.
- Multi-derivation correctness pin: a synthetic graph where
  one inferred quad has two independent derivations; retracting
  one premise leaves the inferred quad in place; retracting
  the other (then the first) drops it. Mirrors the engine's
  `test_rdf_dred_overdelete_multi_derivation`.

#### Refusal envelope additions
- `:changeset_scope_mismatch_for_reasoner` — change-set's
  `scope:` differs from `asserted:`; refuse rather than
  silently apply wrong slice.
- `:full_rebuild_required` — heuristic refusal when the
  change-set is so large (e.g., >50% of the asserted-graph
  triple count) that DRed is provably slower than a fresh
  full-pass. Operators handle by calling `materialise!`
  instead.
- `:dependency_index_unavailable` — `dependency_index: :native`
  was requested but the engine's index was never populated for
  this `inferred:` IRI (either `track_dependencies` was never
  passed at materialise time, or `rdf_clear` was called since).
  Envelope carries a hint pointing at
  `warm_dependency_index!`. The `:auto` path swallows this
  and falls back; `:native` surfaces it explicitly.

#### Exit criteria
- Spec: equivalence under DRed (full-pass equality), across all
  three `dependency_index:` values.
- Spec: retracting `:a rdfs:subClassOf :b` over-deletes
  `:x rdf:type :b` for every `:x rdf:type :a`, then
  re-derives whatever's still supported.
- Spec: native-index cascade pins multi-derivation correctness
  (inferred quad with two derivations survives a partial
  retract; drops on full retract).
- Spec: adding `:y :investigates :Case1` (with rule
  `?x :investigates ?c → ?x rdf:type :Detective`)
  derives `:y rdf:type :Detective` without touching
  unrelated closures.
- Spec: large change-set triggers `:full_rebuild_required`
  with a hint envelope ("change-set ≥ threshold; call
  `materialise!` instead").
- Spec: rule fires outside the engine's 5-covered set →
  `index_dirty: true` in the envelope; the SPARQL fall-back
  catches the orphaned derivations; correctness unchanged.
- Spec: cold-start (`rdf_clear`-then-`materialise_incremental!`)
  with `dependency_index: :native` either auto-warms (via the
  `:incremental_save` first-call path) or refuses with
  `:dependency_index_unavailable`.

### Phase C — Incremental validator (focus-node-scoped SHACL)

The incremental sibling of PLAN_0.10.0's `Shacl.validate!`. Re-runs
SHACL Core constraints only against focus nodes the change-set
touched.

```ruby
Vv::Graph::Shacl.validate_incremental!(
  data_graph:   "urn:mm:graph:catalogue",
  shapes_graph: "urn:vv-graph:shapes:product",
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
  on every shape it targets. The validator routes through
  engine v0.11.0's `rdf_shacl_core_validate` when available
  (the 12 native constraint components) and falls back to the
  per-constraint `sparql_ask` path for the remaining ~18.
  Delete prior `sh:ValidationResult` entries in the report
  graph for that focus node; re-insert the new ones.
- The `sh:ValidationReport` root's `sh:conforms` flag is
  recomputed at the end of the incremental pass: true iff the
  report graph holds zero `sh:ValidationResult` nodes.

#### Correctness pin
- v0.11.0 specs full-pass-vs-incremental equivalence: the
  report graph after `validate_incremental!` (against the
  pre-change report) equals the report graph after a fresh
  `validate!` against the post-change data graph (modulo
  the `vg:reportedAt` timestamp).
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
  include Vv::Graph::Storable
  include Vv::Graph::Shacl::Shape

  ontology do
    materialise_on :incremental_save,
                   dependency_index: :native     # default; :sparql for the fall-back-only path
  end

  shape do
    validate_on :incremental_save                # same trigger
  end
end
```

#### `:incremental_save` semantics
- `after_save`: a per-record `ChangeSet` captures the delta
  produced by the `Storable` emission (the same dispatch that
  emits the asserted triples knows what it changed).
- First save after process boot: if `dependency_index: :native`
  was selected and the index hasn't been warmed for this
  inferred-graph IRI, the orchestrator calls
  `warm_dependency_index!` (one full-pass `materialise!` with
  `track_dependencies: true`) before running the DRed cycle.
  Subsequent saves skip the warm.
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
- A new shared `Vv::Graph::IncrementalPass` orchestrator
  composes the reasoner + validator calls; it's the
  module-level home for the fall-back-to-full logic and the
  first-call warm-up.
- Per-(inferred-graph-IRI) `Concurrent::AtomicBoolean` tracks
  index-warm state across the process; thread-safe boot.

#### Exit criteria
- Spec: `:incremental_save` after `Product.update!` produces
  an updated inferred graph + an updated validation report —
  both reflect the post-update state.
- Spec: first save after process boot with
  `dependency_index: :native` warms the index automatically;
  second save skips the warm (spy on `Sparql.execute`).
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

- New file `spec/vv/graph/changeset_spec.rb` covering Phase A.
- New file `spec/vv/graph/reasoner_incremental_spec.rb` covering
  Phase B + the full-pass-vs-incremental equivalence pin
  (run once per `dependency_index:` value).
- New file `spec/vv/graph/reasoner_dred_native_spec.rb` covering
  the engine v0.12.0 cascade integration + the multi-derivation
  correctness pin.
- New file `spec/vv/graph/shacl_incremental_spec.rb` covering
  Phase C + the equivalence pin.
- New file `spec/vv/graph/storable_incremental_save_spec.rb`
  covering Phase D + E.
- `bin/check` green against engine ≥ 0.12.0 (new pin — the
  native DRed surfaces require it).

### Phase G — Docs

- `CHANGELOG.md` — `0.11.0` heading with per-phase entries.
  Includes a "Engine floor bumped to sqlite-sparql ≥ 0.12.0"
  callout matching the floor bump convention used by the
  v0.9.1 bump.
- `README.md` — new "Incremental reasoning + validation"
  section after the SHACL section, with the `ChangeSet.capture`
  example, the `:incremental_save` lifecycle mode, the
  `dependency_index:` knob (and the rule-coverage caveat),
  the cold-start warm-up convention, the equivalence
  guarantee, and the gotchas from "Risks" below.
- `CONSUMER_REQUIREMENT_MM.md` — promote the incremental
  surface to its own §9 block once MM signals adoption.
- `CONSUMER_REQUIREMENT_VvGraph.md` (in the engine repo) —
  item #8 already reads "LANDED in 0.12.0". v0.11.0's release
  notes file a follow-up ask under that item: "expand
  tracking to the remaining 55 OWL 2 RL rules" gated on
  MM-side telemetry from the v0.11.0 rollout. The ask lands
  as a new bullet under the existing item rather than a new
  numbered item.
- `docs/plans/PLAN_0.11.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.11.0`.

## Out of scope for v0.11.0

- **Engine-side coverage of the remaining 55 OWL 2 RL rules in
  the dependency index.** Engine v0.12.0 covers 5; the gem
  carries the SPARQL fall-back for the other 55 transparently.
  Expansion is mechanical; gated on telemetry from MM about
  which of the 55 actually appear on retraction-heavy paths.
  Tracked in `CONSUMER_REQUIREMENT_VvGraph.md` as a v0.11.0
  follow-up ask.
- **SHACL Rules-derived triples participating in the
  dependency index.** Engine v0.12.0 explicitly defers
  `rdf_construct_many → index write-through`. PLAN_0.12.0
  (SHACL Rules) ships those derivations via the per-rule path
  with RDF-star annotations; DRed over SHACL-Rules-derived
  triples uses the SPARQL fall-back. A future engine release
  closes this; this plan documents the seam.
- **Differential dataflow / RDFox-style incremental.** Stream-
  based multi-version closure maintenance. Different storage
  shape; out of reach for this gem. Revisit only if both DRed
  surfaces combined still don't keep up.
- **Counting / Backward-Forward variants.** Considered + rejected
  for v0.11.0 (see "Why DRed"). Operators wanting a different
  algorithm fork `Vv::Graph::Reasoner::Incremental`.
- **Cross-graph incremental.** A change in graph A triggering
  re-evaluation in graph B (via inferred cross-graph triples).
  The `:derivedFrom` annotations carry no graph label
  (PLAN_0.8.0 Out-of-scope: "no quoting of quads"); v0.11.0's
  DRed scopes incremental passes to a single asserted-graph
  IRI. The engine's `DependencyIndex` is also scoped to one
  `inferred_iri`. Cross-graph workflows fall back to per-graph
  full passes. Document.
- **Negation / non-monotonic rules.** DRed is correct only for
  monotonic Datalog; OWL 2 RL is monotonic, so v0.11.0 is fine
  with the v0.9.0 rule library. Operator-authored rules that
  introduce negation break the equivalence pin. Refuse with
  `:non_monotonic_rule_set` if a future extension to the rule
  library carries negation. (PLAN_0.12.0's SHACL Rules surface
  reuses this refusal symbol.)
- **Change-set merge / replay across scopes.** Combining two
  change-sets into one, or replaying a change-set captured
  against scope A onto scope B. The `id` + `persist!` shape
  supports replay-into-same-scope; cross-scope replay is a
  v0.12.0+ candidate.
- **Concurrent incremental passes against the same scope.**
  Per-(inferred-graph-IRI) Mutex in `Vv::Graph::IncrementalPass`
  serialises calls. Two threads racing on the same scope get
  serialised; cross-scope passes run in parallel. Engine-side
  multi-writer support is a separate question.
- **Time-travel / point-in-time queries.** "What did the
  closure look like as of yesterday?" needs persistent
  change-set history + replay-to-time. v0.11.0 ships the
  `persist!` primitive but doesn't ship the query-as-of facade.
- **Cross-process / cross-restart dependency-index persistence.**
  Engine v0.12.0's index is in-memory and process-scoped; it
  dies with the worker. The cold-start warm-up is the gem-side
  answer until the engine's deferred RocksDB backend lands.
  Document the boot-cost trade-off.
- **Operator-authored DRed instrumentation.** Hooks to
  observe over-delete / re-derive counts per rule. v0.11.0
  exposes per-pass totals in the envelope (`over_deleted:`,
  `over_deleted_via_index:`, `over_deleted_via_sparql:`,
  `rederived:`, `index_dirty:`); per-rule breakdowns are
  v0.12.0+ if MM signals demand.
- **Change-set capture inside `Sparql.execute("CLEAR GRAPH …")`.**
  Treats the clear as a bulk retract of *every* triple in the
  graph — the change-set bloats. Operators should call
  `materialise!` (full pass) after a `CLEAR GRAPH` rather than
  routing through the incremental surface. Refuse with
  `:full_rebuild_required` after detecting a bulk clear. Note
  that engine v0.12.0's `rdf_clear()` *also* clears the
  `DependencyIndex` — a `CLEAR GRAPH` followed by an
  `:incremental_save` triggers the cold-start warm-up path.

## Risks

| Risk | Mitigation |
|---|---|
| DRed has worst-case quadratic behaviour on dense provenance graphs. | The `over_deleted:` / `rederived:` envelope fields are the operator-visible signal. The native dependency index's per-derivation cascade addresses the "many independent derivations" sub-case of this risk directly. README documents the failure mode + recommends `:full_rebuild_required` threshold tuning. Substrate-side telemetry (via MM's Conformer logs) is the canary. |
| Engine v0.12.0's `DependencyIndex` covers only 5 of 60 OWL 2 RL rules — a retract that touches inferred slices derived by an uncovered rule silently misses the native cascade. | The gem's post-cascade orphan sweep catches it via SPARQL fall-back and sets `index_dirty: true` in the envelope. Correctness is preserved; the operator-visible signal is the dirty flag + the `over_deleted_via_sparql` count. README documents which 5 rules are fast and the v0.11.0 follow-up plan to expand. |
| Cold-start: the native index dies with the process; first incremental call after boot is silently incorrect if the operator forgets to warm. | The `:incremental_save` orchestrator auto-warms on first call per-process via an atomic boolean. Explicit `Reasoner.warm_dependency_index!(inferred:)` is also available for operators with hot-restart latency budgets who want the warm to happen at Rails initializer time. The `:native` mode (without the `:auto` fall-back) surfaces `:dependency_index_unavailable` if the warm never ran. |
| RDF-star provenance annotations are size-multiplicative on the inferred graph; incremental over-delete scans them. | PLAN_0.8.0 already documented the size implication. v0.11.0 specs the SPARQL-fall-back over-delete time complexity as O(inferred × premise-fan-in); operators wanting a smaller provenance footprint set `provenance: false` + `dependency_index: :native` (the native index doesn't require the RDF-star annotations — it's a parallel structure). Trade-off: losing provenance also loses auditability. |
| Equivalence pin breaks under operator-authored extensions to `Rules::OwlRl` that introduce non-monotonicity. | Refuse with `:non_monotonic_rule_set`. Specs assert the refusal fires on a synthetic non-monotonic rule. |
| Forgotten changes — operator wrote via `Sparql.execute` outside `ChangeSet.capture { … }` — silently desync the closure. | The `:explicit` / `:save` lifecycle modes (PLAN_0.9.0) stay available as the fall-back; running `materialise!` (full pass) re-baselines. Document. Operators wanting strict change-tracking can wrap the entire AR connection in a `capture` block at the request boundary (per-request middleware). |
| `:incremental_save` raises in-place if the validator finds a violation, surprising operators who only enabled the reasoner. | The orchestrator's combined-pass behaviour is documented per concern: enabling `ontology do; materialise_on :incremental_save` without `shape do; validate_on …` only fires the reasoner; the validator runs only when its own concern is present + opted in. |
| Change-set capture adds overhead to write paths even when no incremental pass is active. | The recorder hook is a thread-local check; no-op when the hook is unset (the common case). Spec asserts the overhead is bounded. |
| `:full_rebuild_required` threshold is heuristic and may be wrong for some workloads. | Operators override via `Vv::Graph::Reasoner.incremental_threshold = ...` (Float, fraction of asserted-graph triples; default 0.5). README documents tuning. |
| Provenance-graph drift: an external write to the `:derivedFrom` predicates would confuse the SPARQL-fall-back DRed. | The provenance graph IRI is the same as the inferred graph IRI (annotations live with the triples they annotate). Operators editing the inferred graph directly already break the closure; v0.11.0 documents that the provenance annotations are gem-owned within that graph. |
| Concurrent `materialise!` and `materialise_incremental!` against the same scope race. | Per-(inferred-graph-IRI) Mutex in `Vv::Graph::IncrementalPass`; serialises both kinds of passes. Spec asserts the serialisation. The native `DependencyIndex` is process-wide behind a `Mutex` in the engine — the gem-side per-IRI Mutex stacks on top to avoid the FFI-level contention surfacing as latency spikes. |
| Test-suite flake under transactional rollback — an `after_save`-driven incremental pass that fails mid-DRed leaves the AR save rolled back but the engine's named-graph state or the dependency index may not roll back (the engine's transactional semantics are SQLite-driven; the index is a separate in-memory structure). | v0.11.0 wraps the DRed phases in a single SQLite transaction at the engine boundary (engine 0.7.0 already supports this — the connection's autocommit is off during the pass). The dependency index is not transactional; on rollback the gem-side orchestrator calls `warm_dependency_index!` to rebuild from the rolled-back asserted state. Spec asserts both rollback paths. |

## Acceptance signal

1. Phases A/B/C/D/E land with passing specs.
2. Equivalence pin (full-pass-vs-incremental) green for both
   reasoner and validator. The reasoner pin runs three times,
   once per `dependency_index:` value.
3. Multi-derivation correctness pin green (mirrors the engine's
   `test_rdf_dred_overdelete_multi_derivation`).
4. `bin/check` green against engine ≥ 0.12.0.
5. CHANGELOG `0.11.0` heading drops `(unreleased)`.
6. `VERSION` → `0.11.0`.
7. README documents `ChangeSet.capture`, the
   `:incremental_save` lifecycle mode, the `dependency_index:`
   knob + rule-coverage caveat, the cold-start warm-up
   convention, the equivalence guarantee, and the gotchas.
8. CONSUMER_REQUIREMENT_MM.md §9 notes the new optional
   surface once MM signals adoption.
9. CONSUMER_REQUIREMENT_VvGraph.md (engine repo) item #8
   already reads "LANDED in 0.12.0"; v0.11.0's notes file
   the remaining-55-rules expansion as a follow-up bullet
   under that item, gated on telemetry from the v0.11.0
   rollout.

## v0.11.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Vv::Graph::ChangeSet` value object (`#added`, `#retracted`, `#scope`, `#id`, `#persist!`) | class | **Pinned.** |
| `Vv::Graph::ChangeSet.capture(scope:) { ... }` block API | module method | **Pinned.** |
| `Vv::Graph::ChangeSet.replay(id)` | module method | **Pinned.** |
| `Vv::Graph::Reasoner.materialise_incremental!(asserted:, inferred:, changes:, rules: :owl_2_rl, provenance: true, dependency_index: :native, max_iterations: 50)` | module method | **Pinned.** |
| `Vv::Graph::Reasoner.dred!` alias to `materialise_incremental!` | module method | **Pinned.** |
| `Vv::Graph::Reasoner.warm_dependency_index!(inferred:)` | module method | **Pinned.** |
| `Vv::Graph::Shacl.validate_incremental!(data_graph:, shapes_graph:, report_graph: nil, changes:, provenance: true)` | module method | **Pinned.** |
| `Vv::Graph::IncrementalPass` orchestrator (composes reasoner + validator; manages cold-start warm-up) | module | **Pinned name.** Internal composition. |
| `materialise_on :incremental_save, dependency_index: :native\|:sparql\|:auto` DSL value + kwarg | DSL extension to PLAN_0.9.0's lifecycle | **Pinned.** |
| `validate_on :incremental_save` DSL value | DSL extension to PLAN_0.10.0's lifecycle | **Pinned.** |
| `Vv::Graph::Reasoner.incremental_threshold` accessor | gem-level Float | **Pinned.** Default 0.5. |
| `:changeset_scope_mismatch` reason symbol | refusal envelope | **Pinned.** |
| `:changeset_scope_mismatch_for_reasoner` reason symbol | refusal envelope | **Pinned.** |
| `:changeset_scope_mismatch_for_validator` reason symbol | refusal envelope | **Pinned.** |
| `:full_rebuild_required` reason symbol | refusal envelope (includes `because:` hint) | **Pinned.** |
| `:report_graph_stale` reason symbol | refusal envelope | **Pinned.** |
| `:non_monotonic_rule_set` reason symbol | refusal envelope | **Pinned.** |
| `:dependency_index_unavailable` reason symbol | refusal envelope (includes warm-up hint) | **Pinned.** |
| Envelope fields: `over_deleted:`, `over_deleted_via_index:`, `over_deleted_via_sparql:`, `rederived:`, `net_derived:`, `index_dirty:` | reasoner-incremental return | **Pinned.** |
| Change-set graph IRI shape (`urn:vv-graph:changeset:<ulid>`) | derived | **Internal**; operators introspect via the value object's `#id` accessor. |

## Cross-references

- `./PLAN_0.3.0.md` — `sparql_update` carries both phases of the
  SPARQL-driven DRed fall-back.
- `./PLAN_0.5.0.md` — named graphs scope the change-set, the
  asserted graph, the inferred graph, and the validation report.
- `./PLAN_0.7.0.md` — EtherealGraph; change-sets can be
  persisted via Active Storage if operators want change history
  to survive process restarts.
- `./PLAN_0.8.0.md` — RDF-star; the `:derivedFrom` annotations
  PLAN_0.8.0 surfaces + PLAN_0.9.0 emits are the fall-back
  dependency graph for the 55 OWL 2 RL rules engine v0.12.0
  doesn't index-cover yet.
- `./PLAN_0.9.0.md` — OWL 2 RL full-pass reasoner; v0.11.0 is
  the incremental sibling.
- `./PLAN_0.10.0.md` — SHACL Core full-pass validator; v0.11.0
  is the incremental sibling.
- `./PLAN_0.12.0.md` — SHACL Rules; reuses v0.11.0's
  `:non_monotonic_rule_set` refusal and the change-set
  abstraction. SHACL-Rules-derived triples don't yet
  participate in engine v0.12.0's dependency index (out-of-
  scope in the engine release); they ride the SPARQL fall-back.
- `../research/TripesQuadsEtc.md` — the motivating sketch's
  OWL rung. v0.11.0 makes the OWL+SHACL surface affordable to
  run on every save.
- `../research/DRed.md` — one-page primer on Delete-and-Rederive.
  The "drawback" section ("many independent derivations") is
  exactly what the engine v0.12.0 per-derivation index
  addresses.
- DRed (Gupta, Mumick, Subrahmanian 1993) — *Maintaining views
  incrementally* — the algorithm v0.11.0 implements.
- RDFox / differential dataflow literature — the
  out-of-scope-for-now next horizon if DRed-with-native-index
  proves insufficient.
- `sqlite-sparql/CHANGELOG.md` § `0.12.0` — engine pin v0.11.0
  inherits. Ships `rdf_dred_overdelete` + `track_dependencies`
  on `rdf_owl_rl_materialise`; the native dependency surfaces
  this plan integrates.
