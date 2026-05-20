# PLAN_0.2.0 — `rails-semantica` second release

> *Closes the six extensions MM listed as "Requested extensions
> (toward v0.2.0)" in `CONSUMER_REQUIREMENT_MM.md`. When all six
> land, MM deletes its substrate-side `Product#emit_complex_triples!`
> hybrid + inlines complex projections into the `triples do…end`
> block, then deletes `ProductTripler` + the `Triple` AR model and
> rewrites its Phase B.1 copy migration to use the new bulk write
> surface.*

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `CONSUMER_REQUIREMENT_MM.md` | `./CONSUMER_REQUIREMENT_MM.md` | The five requested extensions (#1–#5) are this plan's scope. Section "Acceptance signal" defines MM's cutover-readiness check. |
| `PLAN_0.1.0.md` | `./docs/plans/PLAN_0.1.0.md` | Closed shipping state v0.2.0 evolves from. v0.1.0's `Storable` read-replace model is the baseline; #2 + #3 rework it. |
| MM's `PLAN_0_29_1` Phase B.2 | `magentic-market-ai/docs/plans/PLAN_0_29_1.md` | The substrate-side cutover that consumes v0.2.0. Phase B.2 references this plan's eventual release SHA. |

## Current state (2026-05-19)

Shipped at v0.1.0:

- `Semantica::Loader`, `Semantica::Sparql.{select,ask,construct,execute}`,
  `Semantica::Storable.triples do…end` (single subject, single value
  per (subject, predicate), default graph only).
- `TermSerializer` type-dispatch: String / Integer / Float /
  Boolean / Time / DateTime / Date. Hash and Array fall through to
  `value.to_s` (the gap #4 closes).
- Read-replace semantics: `after_save` deletes any current
  (subject, predicate) → object triples then inserts the new
  one — assumes **one value per (subject, predicate)**.

Pinned engine surface (v0.1.0): rdf_count, rdf_load_ntriples,
rdf_delete, rdf_clear, sparql_query, sparql_ask, sparql_construct.
Default graph only. **#5 (named graphs) is engine-gated; cannot
ship until `sqlite-sparql` exposes a graph-aware insert/delete +
the `FROM <graph>` form rides through `sparql_query`.**

## Scope — six extensions

Implement in this order; each phase is independently shippable as a
v0.1.x point release if MM needs it sooner than v0.2.0. Phases D
and E are engine-gated and ship in v0.2.1 if the engine isn't ready
by v0.2.0 release.

### Phase A — Multi-subject emission (extension #1)

DSL:

```ruby
triples do
  subject -> { "urn:mm:product:#{sku}" }
  triple "schema:name", -> { name }

  on_subject -> { "urn:mm:folder:category:#{category}" } do
    triple "rdf:type", "<urn:mm:CategoryFolder>"
    triple "schema:name", -> { category.titleize }
  end
end
```

#### Implementation

- `Recorder` gains an `on_subject(callable = nil, &block) do … end`
  method that creates a **sub-recorder** scoped to a different
  subject lambda. Returns an `OnSubjectBlock` value object with
  `subject_lambda` + `predicates`.
- `Declaration` gets a new `on_subject_blocks` field
  (`Array<OnSubjectBlock>`). The primary `subject_lambda` +
  `predicates` keep their meaning unchanged from v0.1.0.
- `semantica_emit_triples!` first emits primary-subject triples
  (existing path), then iterates `on_subject_blocks` and emits each
  block's triples with that block's subject lambda. Each block's
  emissions use the **same read-replace per (subject, predicate)
  idempotency** as the primary path.
- `semantica_retract_triples!` iterates all blocks (primary +
  on_subject) and retracts each declared predicate.
- A literal-string predicate object (e.g. `triple "rdf:type",
  "<urn:mm:CategoryFolder>"` — the lambda position is replaced
  with a wrapped-IRI string literal) is supported. Detect:
  `value_lambda.respond_to?(:call) ? lambda : ->{ value_lambda }`.
  Document in the DSL guide.

#### Exit criteria

- Spec: a model with `triples do; subject ->{...}; triple ...;
  on_subject ->{...} do; triple ...; end; end` round-trips both
  subjects through `Sparql.select`.
- Spec: destroying retracts both subjects' triples.
- Spec: the literal-string predicate object form serializes
  correctly without a lambda.

### Phase B — Collection iteration + multi-value predicates (extensions #2 + #3)

These two coupled. #2 introduces the `each` block; #3 changes the
read-replace algorithm to handle the resulting multi-value
predicates.

DSL:

```ruby
triples do
  subject -> { "urn:mm:product:#{sku}" }

  each -> { product_specs } do |spec|
    triple "mm:#{spec.name.camelize(:lower)}", -> { spec.value }
  end

  # Multi-value via repeated each:
  each -> { feature_flags } do |feature|
    triple "mm:hasFeature", -> { feature.code }
  end
end
```

#### Implementation

- `Recorder` gains `each(collection_lambda, &block)`. Block yields
  an item context; inside the block, `triple "pred", -> { ... }`
  records an `EachPredicate` with: `collection_lambda`,
  `predicate_iri` (or predicate-IRI-lambda, since `"mm:#{spec.name.camelize(:lower)}"`
  must evaluate per item), `value_lambda`.
- The predicate IRI inside `each` may interpolate per-item state.
  Two patterns:
  - Literal string captured at recording time (`triple
    "mm:hasFeature", ...`) — predicate is constant.
  - Lambda or string interpolation referencing the block param
    (`triple "mm:#{spec.name.camelize(:lower)}", ...`) — predicate
    varies per item.
  Cleanest: the recorder always treats the predicate position as a
  callable. If the user passed a String, wrap it as
  `->{ literal_string }`. If they passed a lambda, use it directly.
  Inside `each`, the block-param interpolation is evaluated by
  calling the predicate lambda in the per-item scope.
- `Declaration` gets `each_blocks: Array<EachBlock>`.
- `semantica_emit_triples!` walks `each_blocks` after primary +
  on_subject emissions:
  1. Evaluates `collection_lambda` in instance scope → array.
  2. For each item, evaluates `predicate_lambda` + `value_lambda`
     in a scope where the item is bound.
  3. **Read-replace adjustment (#3):** before any emission for an
     `each` block, retract *all* triples matching `(subject,
     predicate)` where `predicate` is any of the predicates this
     block can emit. Then insert the freshly-computed item triples.
  4. Predicates produced by an `each` block whose value-lambda
     returns `nil` are skipped (not emitted as nil-retraction —
     because the surrounding `each` already cleared the predicate
     slot).
- New helper `Sparql.execute("DELETE WHERE { <s> <p> ?o }")` —
  retract every triple with the given subject + predicate
  regardless of object. v0.1.0's `execute` doesn't support this
  form; extend the dispatcher to recognise `DELETE WHERE { <s>
  <p> ?o }` and translate to: SELECT ?o → DELETE DATA per result.
  (Same shape `Storable#retract_predicate!` already uses
  internally; lift it onto the public `execute` so the audit-trail
  envelope discipline holds.)

#### Exit criteria

- Spec: a model with `each -> { items } do |i|; triple "mm:x",
  -> { i.value }; end` emits one triple per collection element +
  the count matches.
- Spec: re-saving with a different collection (added items,
  removed items, changed values) results in a store state matching
  the new collection exactly — no stale entries from a previous
  save.
- Spec: multi-value via repeated `each` for the same predicate
  works (e.g. `mm:hasFeature` fires N times for N feature flags).
- Spec: destroy retracts every triple emitted by any `each` block.

### Phase C — JSON / structured-literal object type (extension #4)

Approach: **extend `TermSerializer.object`** to JSON-encode `Hash`
and `Array`. Operators wanting non-JSON literal-encoding for a Hash
can fall back to `value.to_s.to_json`-style explicit construction.
The opt-in `as: :json` syntax is rejected for v0.2.0 as
over-engineering — if it surfaces a real need later (e.g. operators
need to send a Hash through *as* a stringified Hash, not JSON), a
v0.2.x bump can add it.

#### Implementation

- `TermSerializer.object`: add `when Hash, Array` branches that
  serialize via `JSON.generate(value)` then wrap as a typed literal
  with `xsd:string` datatype (default). Document that the resulting
  literal is the JSON text — operators can `JSON.parse` results on
  read.
- Optional refinement: emit `^^<rdf:JSON>` datatype instead of
  `xsd:string` (RDF 1.1 has a JSON datatype IRI). Decide based on
  what `sqlite-sparql` round-trips cleanly; default to `xsd:string`
  if the engine fights `rdf:JSON`.

#### Exit criteria

- Spec: `TermSerializer.object({a: 1, b: [2,3]})` returns
  `"{\"a\":1,\"b\":[2,3]}"^^<...>` — exact datatype TBD by engine
  compat.
- Spec: round-trip `Product` with a Hash predicate through
  `after_save` + `Sparql.select` recovers a JSON-parseable string.
- Spec: Array values serialize correctly + round-trip.

### Phase D — Named graph support (extension #5) — engine-gated

**Cannot ship until `sqlite-sparql` exposes named-graph-aware
insert/delete + graph-scoped query forms.** The engine's
`CONSUMER_REQUIREMENT_MM.md` (the sibling repo's file) carries the
upstream ask. Track engine readiness; this phase opens when the
engine ships.

#### When unblocked, the DSL becomes:

```ruby
triples do
  graph "bhphoto"
  subject -> { "urn:mm:product:#{sku}" }
  # ...
end

Semantica::Sparql.select(query, graph: "bhphoto")
Semantica::Sparql.ask(query, graph: "bhphoto")
Semantica::Sparql.construct(query, graph: "bhphoto")
Semantica::Sparql.execute("INSERT DATA { ... }", graph: "bhphoto")
```

#### Implementation sketch

- `Recorder#graph(name)` records the graph IRI on the
  `Declaration`. `Storable` lifecycle hooks rewrite the
  `INSERT DATA` / `DELETE DATA` payloads to wrap in
  `GRAPH <name> { ... }`.
- `Sparql.{select,ask,construct,execute}` gain an optional
  `graph:` kwarg. When passed, the query is rewritten or scoped to
  the named graph via the engine's graph-aware functions.
- `TermSerializer` gains nothing new — graph IRIs follow the same
  IRI-wrapping rules as subjects/predicates.
- v0.1.x callers that omit `graph:` keep the default-graph
  behaviour (back-compat).

#### Exit criteria

- Spec: a model with `graph "bhphoto"` emits triples that are
  retrievable via `Sparql.select(q, graph: "bhphoto")` but **not**
  retrievable via the default-graph `select(q)`.
- Spec: cross-graph round-trip with two models, two different
  graphs, no cross-contamination.

#### Blockers

- Engine surface: `rdf_load_ntriples` doesn't accept a graph
  arg. Engine must add either `rdf_load_ntriples_to_graph(text,
  graph)` or a graph-aware INSERT path. Same for `rdf_delete` /
  `sparql_query`.
- Until the engine ships, Phase D ships an `:engine_unsupported`
  refusal envelope when `graph:` is passed.

### Phase E — Bulk write surface (extension #6) — moved to PLAN_0.4.0

**Scope moved.** The bulk-write surface (`Sparql.bulk_insert` /
`bulk_delete` backed by engine `rdf_insert_many` /
`rdf_delete_many`) has its own canonical plan at
[`./PLAN_0.4.0.md`](./PLAN_0.4.0.md). The engine prerequisite
landed in `sqlite-sparql 0.4.0`; the gem-side surface ships as
v0.4.0 rather than as v0.2.0 Phase E. PLAN_0.4.0 pins the
implementation against the engine's actual JSON-array argument
shape and abort-batch-on-error semantics.

v0.2.0's contract additions table still lists `bulk_insert` /
`bulk_delete` for cross-reference, but the **implementation is
v0.4.0's responsibility** — those rows graduate from
`:engine_unsupported` stubs into pinned surfaces when PLAN_0.4.0
ships.

### Phase F — Spec + audit + bin/check

- Every extension above lands with `:requires_extension`-tagged
  round-trip specs.
- Pure-Ruby (Recorder + TermSerializer) specs land alongside,
  always-run.
- `bin/check` stays the single pre-release runner; green-against-
  live-engine is the v0.2.0 release gate.
- Drift signals MM cited (CONSUMER_REQUIREMENT_MM.md §"Drift
  signals") stay green: substrate's
  `semantica_substrate_audit_spec.rb` +
  `semantica_roundtrip_spec.rb` + `bin/mm-smoke`'s `semantica`
  step.

### Phase G — Docs

- `CHANGELOG.md` — per-phase entry as each lands; collected under
  a `0.2.0` heading at release.
- `README.md` — DSL surface section grows the `on_subject` + `each`
  + JSON-literal examples. `graph:` documented behind a "v0.2.x
  when engine support lands" note until Phase D opens.
- `CONSUMER_REQUIREMENT_MM.md` — graduate each landed extension
  from §"Requested extensions" into §"Surfaces MM consumes." MM
  bumps `Gemfile.lock` to the new SHA at each graduation.
- `docs/plans/PLAN_0.2.0.md` — update "Current state" as phases
  land.

## Out of scope for v0.2.0

- **Arbitrary SPARQL UPDATE** — still post-v0.2.0; Phase B's
  `DELETE WHERE { <s> <p> ?o }` is the only addition.
- **Per-record dirty-tracking optimisation** (skip read-replace
  when no value changed). v0.1.0's full-read-replace cost stays.
  v0.3.0 candidate.
- **Operator-defined custom serializers** (e.g. `as: :geojson`).
  Wait for a real need.
- **`rails-semantica`-side caching of compiled `Declaration`** —
  Recorder runs once at `triples do…end` call; no per-save
  recompile to optimise away.
- **Cross-graph queries** (`GRAPH ?g { ... }` patterns) — when
  Phase D opens, the consumer reads only single-graph queries;
  multi-graph reads are a v0.3.0 expansion if MM needs them.

## v0.2.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `triples do; on_subject(lambda) do; ...; end; end` | DSL block | **Pinned.** |
| `triples do; each(collection_lambda) do |item|; triple "pred", ->{...}; end; end` | DSL block; predicate may be String or lambda | **Pinned.** |
| `triple "pred", "<urn:literal-iri>"` (literal-string second arg) | DSL form | **Pinned.** |
| `TermSerializer.object(Hash | Array)` → JSON-encoded literal | type dispatch | **Pinned shape**; datatype IRI may evolve in v0.2.x. |
| `Semantica::Sparql.execute("DELETE WHERE { <s> <p> ?o }")` | envelope `{ ok:, count: }` | **Pinned**; new in v0.2.0. |
| `graph "name"` in DSL + `graph:` kwarg on Sparql methods | DSL + kwarg | **Pinned**; ships only when Phase D opens. |
| `Semantica::Sparql.bulk_insert(rows)` / `bulk_delete(rows)` | envelope `{ ok:, inserted: }` / `{ ok:, deleted: }` | **Pinned**; ships only when Phase E opens. Storable lifecycle hooks adopt the bulk path automatically when the engine surface is present. |

Refusal `reason:` additions: `:engine_unsupported` (Phase D + E's
gate before engine support lands), `:invalid_dsl` (Recorder
validation surfaces — e.g. `each` without a collection lambda).

## Risks

| Risk | Mitigation |
|---|---|
| Phase B's read-replace rework breaks v0.1.0 single-value semantics for callers not using `each`. | Preserve the v0.1.0 path verbatim when no `each` block is declared. The new "delete all by predicate" path only fires for predicates that appear inside an `each` block. |
| Predicate IRIs in `each` are evaluated per-item — if the lambda has side effects, those repeat. | Document. Standard Ruby semantics for lambda invocation; no surprise here. |
| #4's choice of `xsd:string` vs `rdf:JSON` datatype gets locked in by MM's first JSON-predicate save. | Ship `xsd:string` (engine-agnostic). If a later MM ask wants `rdf:JSON`, add an opt-in `as: :rdf_json` flag. |
| Phase D drags v0.2.0 release if the engine isn't ready. | Phases A–C ship as v0.2.0 even if D is stubbed (`:engine_unsupported`). v0.2.1 ships D when the engine catches up. |
| MM's substrate-side `Product#emit_complex_triples!` hybrid stays load-bearing if Phase D never opens. | Acceptable. The hybrid is documented interim; the substrate keeps it indefinitely if the engine never ships named graphs. |

## Cross-references

- `./CONSUMER_REQUIREMENT_MM.md` — the request that drives this plan.
- `./docs/plans/PLAN_0.1.0.md` — what v0.2.0 evolves from.
- `magentic-market-ai/docs/plans/PLAN_0_29_1.md` (Phase B.2) — the
  substrate cutover that consumes v0.2.0's full surface.
- Engine repo `laquereric/sqlite-sparql` — Phase D's blocker lives
  in the engine's own roadmap.
