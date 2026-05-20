# PLAN_0.5.0 — `rails-semantica` named-graph support

> *Closes the named-graph ask MM listed as item #5 of "Requested
> extensions (toward v0.2.0)" in `CONSUMER_REQUIREMENT_MM.md`.
> Engine prerequisite landed in `sqlite-sparql 0.3.0` (4-arg
> `rdf_insert` / `rdf_delete`, 1-arg `rdf_count`, native SPARQL
> `FROM` / `GRAPH` clauses). v0.5.0 surfaces the gem-side
> `graph:` kwarg on every `Sparql` method, adds a `graph "name"`
> declaration to the `Storable` DSL, and threads the graph
> parameter through all three dispatch modes (`:sparql_update`,
> `:bulk`, `:per_call`).*

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `sqlite-sparql 0.3.0` CHANGELOG | engine repo | Pins the 4-arg scalar surface, 1-arg `rdf_count`, native SPARQL `FROM`/`GRAPH` routing, blank-node-graph rejection, default-dataset isolation. |
| `PLAN_0.2.0.md` Phase D | this dir | Original sketch of the gem-side surface. v0.5.0 supersedes it; Phase D in PLAN_0.2.0 becomes a one-line pointer here. |
| `PLAN_0.3.0.md` Phase B | this dir | `:sparql_update` dispatch mode. v0.5.0 threads `graph:` through its DELETE/INSERT WHERE composition. |
| `PLAN_0.4.0.md` Phase A | this dir | `bulk_insert` / `bulk_delete` already accept a 4-tuple row shape with `graph` per row. v0.5.0 connects `Storable`'s graph declaration to that path. |
| `CONSUMER_REQUIREMENT_MM.md` §5 | this dir | MM's named-graph ask; `Sparql.{select,ask,construct,execute}` `graph:` kwarg + `triples do; graph "..."; end` are the surfaces MM consumes. |

## Engine surface (already landed, sqlite-sparql 0.3.0; refined further in 0.4.0 + 0.5.0)

Pinned by the engine since 0.3.0:

```sql
-- 4-arg scalar forms (additive; 3-arg forms unchanged):
SELECT rdf_insert(<s>, <p>, <o>, 'urn:mm:graph:bhphoto');
SELECT rdf_delete(<s>, <p>, <o>, 'urn:mm:graph:bhphoto');
SELECT rdf_count('urn:mm:graph:bhphoto');     -- 1-arg: count quads in named graph
SELECT rdf_count_all();                       -- across every graph
SELECT rdf_insert(<s>, <p>, <o>, NULL);       -- NULL = default graph

-- Blank-node graphs rejected with a clear error.

-- rdf_triples virtual table gains a HIDDEN graph column:
INSERT INTO triples(subject, predicate, object, graph) VALUES (..., 'urn:g:...');
SELECT * FROM triples WHERE graph IS NULL;     -- default graph only
SELECT * FROM triples WHERE graph = 'urn:g:bhphoto';
```

SPARQL routing through to Oxigraph: `FROM <g>`, `FROM NAMED <g>`,
and `GRAPH <g> { … }` clauses work natively in `sparql_query` /
`sparql_ask` / `sparql_construct`. Unqualified `?s ?p ?o` patterns
scope to the default graph only — named-graph triples don't leak
in. Pinned by the engine's
`test_sparql_query_default_dataset_isolates`.

`rdf_insert_many` (engine 0.4.0) and `sparql_update` (engine 0.5.0)
both already honour graphs:

- `rdf_insert_many` accepts `[s, p, o, graph]` 4-tuple rows (PLAN_0.4.0
  Phase A consumes this).
- `sparql_update` runs arbitrary SPARQL 1.1 UPDATE, including
  `WITH <g>`, `INSERT { GRAPH <g> { … } }`, `DELETE { GRAPH <g> { … } }`.

So **every dispatch mode the gem ships in v0.4.0 already has an
engine path to the named-graph functionality** — v0.5.0's work is
entirely gem-side: surface plumbing + DSL.

## Current state baseline (v0.4.0 once it ships)

- `Sparql.{select,ask,construct,execute}` operate against the
  default graph only. Operators wanting named-graph queries must
  hand-author `GRAPH <g> { … }` patterns inside their SPARQL string;
  the gem doesn't help.
- `Storable.triples do…end` emits to the default graph
  unconditionally. No per-DSL graph parameter.
- `bulk_insert` / `bulk_delete` already accept a 4-tuple row with
  graph per row (PLAN_0.4.0); operators use this path manually when
  they need named-graph batch loads. `Storable`'s `:bulk` dispatch
  currently always passes the default-graph 3-tuple.

## Scope

### Phase A — `Sparql` methods accept `graph:` kwarg

Public surface:

```ruby
Semantica::Sparql.select(query, graph: "urn:mm:graph:bhphoto")
Semantica::Sparql.ask(query, graph: "urn:mm:graph:bhphoto")
Semantica::Sparql.construct(query, graph: "urn:mm:graph:bhphoto")
Semantica::Sparql.execute(update_query, graph: "urn:mm:graph:bhphoto")
# graph: nil  (or omitted)  → default graph (v0.4.0 behaviour, unchanged)
# graph: "..."              → scopes to that named graph
```

#### Semantics

- For `select` / `ask` / `construct`: the gem wraps the operator's
  query in a `FROM <graph>` clause (for `select`) or scopes via the
  query's existing `GRAPH` patterns if any. The simplest mechanism:
  textually prepend `FROM <graph>\n` immediately after the
  `SELECT` / `ASK` / `CONSTRUCT` keyword. Operators who hand-author
  `GRAPH <g> { … }` keep working; the kwarg layers on top.
- For `execute("INSERT DATA { ... }")`: rewrite the body to
  `INSERT DATA { GRAPH <graph> { ... } }`. Same for `DELETE DATA`.
- For `execute(arbitrary_UPDATE)` via the v0.3.0 `sparql_update`
  path: prepend `WITH <graph>` to the query string (SPARQL 1.1's
  graph-scoping prefix for UPDATE forms; valid for `INSERT`,
  `DELETE`, `INSERT WHERE`, `DELETE WHERE`).
- For `execute("CLEAR ALL" / "CLEAR DEFAULT")`: the `graph:` kwarg
  is **rejected** with `:invalid_dsl` because those forms target
  specific graphs explicitly. Use `execute("CLEAR GRAPH <urn:g>")`
  for named-graph clear, or `execute("CLEAR ALL")` to wipe
  everything.

#### Implementation

- Add `**opts` to each facade method signature; extract `graph:`.
- Validate the graph IRI at the gem boundary: blank-node graphs
  (`_:foo`) refuse with `:invalid_graph` (new reason symbol;
  cheaper than waiting for the engine's rejection round-trip).
- Query rewriting helpers live in
  `Semantica::Sparql::GraphScoping` (new module) so all four
  methods share the same prepend logic.
- `:graph:` is reflected in the refusal envelope's `:because:`
  when relevant ("query against graph <urn:...>: ...").

#### Exit criteria

- Spec: `Sparql.select(q, graph: "urn:g")` returns only triples in
  that graph; the same query without `graph:` returns only
  default-graph triples (engine's
  `test_sparql_query_default_dataset_isolates` already pins
  isolation).
- Spec: `Sparql.execute("INSERT DATA { ... }", graph: "urn:g")`
  routes to the named graph; observable via
  `rdf_count("urn:g")` vs. `rdf_count()`.
- Spec: blank-node `graph:` refuses with `:invalid_graph` before
  reaching the engine.
- Spec: omitting `graph:` keeps v0.4.0 behaviour bit-for-bit.

### Phase B — `Storable` DSL: `graph "name"` declaration

DSL:

```ruby
class Product < ApplicationRecord
  include Semantica::Storable

  triples do
    graph "urn:mm:graph:bhphoto"
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }
    # ...
  end
end
```

#### Semantics

- `graph "..."` declares the named graph every triple in the block
  emits to. The declaration is captured at recording time; one
  graph per `triples do…end`.
- `Storable`'s `after_save` / `after_destroy` hooks thread the
  graph IRI through whichever dispatch mode is active:
  - `:sparql_update` → prepends `WITH <graph>` to the
    DELETE/INSERT WHERE composition (PLAN_0.3.0 Phase B path
    extended).
  - `:bulk` → fills the 4th tuple element on every row passed to
    `bulk_insert` / `bulk_delete` (PLAN_0.4.0 path; no new code on
    the bulk side).
  - `:per_call` → uses the engine's 4-arg `rdf_insert(s,p,o,graph)`
    and 4-arg `rdf_delete(s,p,o,graph)` forms; the gem's
    `dispatch_update` and `delete_each_triple` helpers grow a
    graph-aware branch.
- `on_subject` blocks (PLAN_0.2.0 Phase A) inherit the outer
  graph. There's no per-block graph override in v0.5.0 — operators
  who need cross-graph emissions in one save author two models or
  use `Sparql.bulk_insert` directly.
- `each` blocks (PLAN_0.2.0 Phase B) inherit the outer graph
  identically.
- Lifecycle hooks scoping a graph operate **only on that graph**:
  reading current values via `SELECT ?o WHERE { GRAPH <g> { <s> <p>
  ?o } }`; retracting via the graph-scoped delete path. Triples
  for the same (subject, predicate) in a different graph are
  untouched.

#### Implementation

- `Recorder` gains a `graph(name)` method that records the graph
  IRI on the `Declaration`.
- `Declaration` gains a `graph_iri` field (`nil` = default graph).
- `semantica_emit_triples!` + `semantica_retract_triples!` pass
  `decl.graph_iri` through to `replace_predicate!` /
  `retract_predicate!`, which in turn pass it to
  `Sparql.execute` / `Sparql.bulk_insert` / `Sparql.bulk_delete`
  via the `graph:` kwarg.
- Storable's per-call dispatch helpers (`dispatch_update`,
  `delete_each_triple`) grow graph-aware branches: when graph is
  not nil, route to the engine's 4-arg `rdf_insert` /
  `rdf_delete` instead of `rdf_load_ntriples`.
- `:sparql_update` dispatch: the DELETE/INSERT WHERE composition
  gets a `WITH <graph>` prefix when graph is not nil.

#### Exit criteria

- Spec: `Widget.triples do; graph "urn:g"; ... end` create →
  triples appear in graph `urn:g`, not in default graph.
- Spec: update / destroy of the same `Widget` only touches `urn:g`;
  unrelated triples for the same subject in other graphs survive.
- Spec: all three dispatch modes (`:per_call`, `:bulk`,
  `:sparql_update`) produce equivalent end states for a
  `graph "..."` model. The dispatch-mode parity spec from
  PLAN_0.3.0 Phase B extends to cover the graph case.
- Spec: `each` and `on_subject` blocks inherit the outer graph.

### Phase C — Multi-graph queries (operator opt-in only)

v0.5.0 **does not** auto-rewrite operator SPARQL to scan across
multiple named graphs. Operators wanting that author the SPARQL
explicitly with `FROM NAMED <g1> FROM NAMED <g2> ... GRAPH ?g { ... }`
patterns; those go through `Sparql.select` unchanged.

The `graph:` kwarg is a single-graph convenience. Cross-graph
needs are advanced enough that operators should hand-author the
SPARQL.

This phase is **documentation only** — no implementation work —
but pinning the boundary here prevents the question reopening in
v0.5.x.

### Phase D — Specs + bin/check

- `spec/semantica/sparql_spec.rb` grows `graph:` kwarg coverage
  for all four methods (Phase A exit criteria).
- `spec/semantica/storable_spec.rb` grows graph-scoped DSL
  lifecycle coverage (Phase B exit criteria).
- A new `spec/semantica/graph_scoping_spec.rb` covers the
  rewrite helpers in isolation (no live engine required for the
  pure-Ruby parts).
- `spec/semantica/dispatch_mode_spec.rb` (from PLAN_0.3.0 Phase B)
  grows a graph-equivalence section: all three modes produce the
  same end state for a graph-scoped model.
- `bin/check` stays the release gate.

### Phase E — Docs

- `CHANGELOG.md` — per-phase entry; collected under `0.5.0` at
  release.
- `README.md` — Sparql surface map grows `graph:` examples; DSL
  surface map grows `graph "..."` examples; pinned reason symbol
  list grows `:invalid_graph`.
- `CONSUMER_REQUIREMENT_MM.md` — graduate §5 from §"Requested"
  into §"Surfaces MM consumes." MM bumps `Gemfile.lock` at
  graduation; PLAN_0_29_1 Phase B.2 cutover commit references
  this graduation point.
- `PLAN_0.2.0.md` Phase D — replace section body with a one-line
  pointer to `PLAN_0.5.0.md` (mirrors what PLAN_0.4.0 did for
  Phase E).
- `docs/plans/PLAN_0.5.0.md` — this file. Update "Current state"
  as phases land.

## Out of scope for v0.5.0

- **Per-block graph override** inside `triples do…end` (e.g.,
  `on_subject` block with its own graph). Operators with that
  need authoring two models or going through `Sparql.bulk_insert`
  directly. Defer to a hypothetical v0.6.x if real demand
  surfaces.
- **Implicit cross-graph reads** in `Sparql.select(graph: nil)`.
  Default-graph isolation stays; cross-graph reads require
  hand-authored `FROM NAMED` / `GRAPH ?g` patterns. Pinned by
  the engine; the gem doesn't second-guess.
- **Graph aliases** (a Ruby-side mapping from short names to
  full IRIs). YAGNI; operators use full IRIs.
- **`SERVICE` federation across graphs in remote stores.** v0.5.0
  is single-engine. Defer.
- **`graph(callable_or_lambda)`** for dynamic per-record graph
  selection. v0.5.0 captures graph at recording time only.
  Future v0.5.x could relax this if MM's hybrid migration shape
  needs it.

## v0.5.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Sparql.{select,ask,construct,execute}(query, graph: nil_or_iri_string)` | optional kwarg | **Pinned.** `nil` is the documented default-graph sentinel. |
| `triples do; graph "<iri>"; … end` | DSL declaration | **Pinned.** Captured once per declaration; no per-block override in v0.5.0. |
| Refusal `:reason:` symbol `:invalid_graph` | symbol | **Pinned.** Surfaces for blank-node graphs and other gem-side validation failures before the engine sees the query. |
| `Storable.dispatch_mode` graph-equivalence contract | all three modes produce identical end states for a graph-scoped model | **Pinned.** Operators force a mode via env var without changing semantic outcomes. |

`rdf_count(graph)` 1-arg engine form is **not** surfaced directly in
the gem's public API in v0.5.0 — operators querying counts use
`Sparql.select("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }",
graph: "...")` instead. The 1-arg `rdf_count` stays available via
raw SQL for operators that need it.

## Risks

| Risk | Mitigation |
|---|---|
| Textual prepend of `FROM <g>` to a `SELECT` doesn't compose well with operator queries that already use `FROM` clauses. | Phase A spec covers both paths. If composition is brittle, fall back to wrapping the entire query in a `GRAPH <g> { … }` block instead; either approach satisfies the contract. |
| `:per_call` dispatch with graph routes through 4-arg `rdf_insert` / `rdf_delete`; the engine's `rdf_delete` 4-arg form still requires the bare-IRI subject + predicate (the v0.1.0 asymmetry RS already accommodates). | The same `unwrap_iri` helper that handled the 3-arg case handles the 4-arg case; pass the graph through unwrapped if it's IRI-shaped, leave bare if already bare. Single code path. |
| Storable's `:sparql_update` dispatch with graph uses `WITH <graph>`; this prefix sometimes interacts oddly with `OPTIONAL` patterns in the WHERE clause. | Test the empty-current-value path explicitly (Storable's read-replace uses OPTIONAL to handle "predicate not yet present"). If `WITH` conflicts, switch the rewrite to inline `GRAPH <g> { … }` in DELETE / INSERT / WHERE blocks. Either valid SPARQL 1.1. |
| Cross-graph leakage if a future `Sparql.select` query accidentally targets the default graph when the operator meant a named graph. | Default-graph isolation is engine-pinned. The kwarg explicit-or-omit contract makes operator intent unambiguous. |
| Multiple consumers (MM today; outside Rails apps post-v1.0) want different graph defaults. | v0.5.0 ships with no global default. Operators thread `graph:` per call or per `triples do` block. No process-wide setting. |

## Acceptance signal

When all phases land:

1. `Sparql.{select,ask,construct,execute}` accept `graph:` kwarg
   against engine ≥ 0.3.0.
2. `Storable.triples do; graph "..."; end` round-trips lifecycle
   hooks against the named graph; all three dispatch modes
   produce identical outcomes.
3. `bin/check` green against engine 0.5.0+ (engine prerequisite
   for v0.5.0 is 0.3.0; current pin is 0.5.0 so satisfied).
4. CHANGELOG `0.5.0` heading drops `(unreleased)`.
5. Root `VERSION` bumps to `0.5.0` (single source of truth per
   commit `8489ee1`).
6. CONSUMER_REQUIREMENT_MM.md §5 graduates from "Requested" into
   "Surfaces MM consumes."
7. PLAN_0.2.0.md Phase D shrinks to a one-line pointer to this
   plan.
8. With v0.2.0 (DSL extensions), v0.3.0 (SPARQL UPDATE), v0.4.0
   (bulk write), and v0.5.0 (named graphs) all released, MM's
   PLAN_0_29_1 Phase B.2 cutover unblocks: delete
   `Product#emit_complex_triples!`, inline all complex
   projections into `triples do…end`, drop the legacy `Triple` AR
   model + `ProductTripler`, rewrite the Phase B.1 copy
   migration onto `bulk_insert`.

## Cross-references

- `./PLAN_0.1.0.md` — `unwrap_iri` helper reused for 4-arg path.
- `./PLAN_0.2.0.md` Phase D — supersedes with one-line pointer.
- `./PLAN_0.3.0.md` Phase B — `:sparql_update` dispatch gets
  `WITH <g>` prefix when graph is set.
- `./PLAN_0.4.0.md` Phase A — `bulk_insert` / `bulk_delete`
  already accept 4-tuple rows; Storable's `:bulk` mode now uses
  them.
- Engine repo `laquereric/sqlite-sparql` 0.3.0 — the prerequisite
  release.
- `magentic-market-ai/docs/plans/PLAN_0_29_1` Phase B.2 — MM's
  cutover that v0.5.0 unblocks (when combined with v0.2.0–v0.4.0).
