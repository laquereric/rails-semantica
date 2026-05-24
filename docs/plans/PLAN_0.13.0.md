# PLAN_0.13.0 — `rails-semantica` cross-graph reasoning + validation

> *PLAN_0.9.0 / 0.10.0 / 0.11.0 / 0.12.0 all sized themselves
> against one asserted graph + one inferred graph + one shapes
> graph. That shape works when every operator scope lives
> independently — MM's catalogue scope, MM's tenant scope, the
> per-Workspace Silver graphs in vv-memory's research notes.
> The moment two scopes share data — a workspace's product
> classifications referencing a shared schema, a tenant's
> validation against a corporate-wide ontology, vv-memory's
> per-scope Silver graphs all reading from one shared `:CoreVocab`
> graph — the single-graph contract breaks. v0.13.0 introduces
> the **`Semantica::Scope`** value object, generalises the
> reasoner / validator / rules / DRed surfaces to accept a Scope
> rather than a string IRI, and grows the RDF-star provenance to
> carry the **`semantica:derivedFromGraph`** sibling annotation
> that PLAN_0.8.0's "no quoting of quads" footnote demanded.
> SHACL targets, OWL axioms, and SHACL Rule premises may now
> live in different graphs than the inferred output; DRed's
> dependency traversal walks the graph-aware provenance graph
> instead of the graph-less one.*

## Current state

**Draft (not yet started).** Sequenced after PLANs 0.8.0 / 0.9.0 /
0.10.0 / 0.11.0 / 0.12.0 — v0.13.0 generalises every surface they
introduced. v0.13.0 can be drafted in parallel with implementation
of those plans; the plan-only commit pins the multi-graph shape so
MM can choose between single-scope and multi-scope adoption when it
adopts any of the prior plans.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `PLAN_0.5.0.md` | this dir | Named graphs. v0.13.0 is the multi-graph generalisation; the `graph:` kwarg from v0.5.0 stays as the single-graph convenience shape, with `scope:` as the multi-graph successor. |
| `PLAN_0.8.0.md` | this dir | RDF-star. v0.13.0 grows `:derivedFromGraph` as the sibling annotation that lifts graph identity into an explicit predicate — exactly the workaround §7.6 of `magentic-market-ai/docs/research/StarExts.md` flagged ("no quoting of quads"). |
| `PLAN_0.9.0.md` | this dir | OWL 2 RL reasoner. `Reasoner.materialise!(asserted:, inferred:, …)` gains a `scope:` kwarg with multi-graph composition; the single-graph shape stays for backwards compatibility. |
| `PLAN_0.10.0.md` | this dir | SHACL Core validator. `Shacl.validate!(data_graph:, shapes_graph:, …)` gains a `scope:` kwarg. Shape `sh:targetClass` resolution may now span multiple data graphs. |
| `PLAN_0.11.0.md` | this dir | DRed incremental. v0.13.0 generalises the dependency-graph traversal to be graph-aware: a retracted premise in graph A only over-deletes inferred triples whose `:derivedFromGraph` actually names A. |
| `PLAN_0.12.0.md` | this dir | SHACL Rules. Rules attached to a shape in `shapes_graph: A` may derive into `inferred: B` from premises in `data_graph: C`. |
| W3C SPARQL 1.1 §13 (RDF Dataset) | spec | The dataset model SPARQL was always built for — multi-graph datasets with a default graph + named graphs, addressable via `FROM` / `FROM NAMED` / `GRAPH`. v0.13.0 is the gem catching up to what the engine + Oxigraph + Rec always supported. |
| vv-memory Silver research note (TBD in MM) | MM repo | The motivating substrate use case: per-scope Silver graphs all reading from one shared `:CoreVocab` graph. |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Drift target. v0.13.0 adds the `Scope` block to the surface list once MM signals adoption. |

## Engine prerequisites (sqlite-sparql ≥ 0.7.0) — **already satisfied**

**No new engine surface.** SPARQL 1.1's dataset model already supports
multi-graph reads via `FROM <g1> FROM <g2> …` (union default dataset)
and `FROM NAMED <g>` (addressable named graphs). The engine routes
arbitrary SPARQL through Oxigraph; the multi-graph patterns parse and
evaluate correctly today (pinned by the engine's
`test_sparql_query_default_dataset_isolates` and the multi-graph
fixtures the engine added in 0.5.0 / 0.6.0).

v0.13.0's write paths route through `sparql_update` (PLAN_0.3.0) with
`WITH <inferred_graph_iri>` and `GRAPH <…> { … }` patterns — both
already work.

The engine-side acceleration items that would matter for multi-graph
workloads (cross-graph dependency index, scope-aware bulk operations)
are listed in `sqlite-sparql/CONSUMER_REQUIREMENT_RS.md` as part of
the existing engine acceleration asks (#6–#10). v0.13.0 introduces
no *new* engine requirements; it just makes the multi-graph surface
of those asks more concrete.

## Gem-side scope

### Phase A — `Semantica::Scope` value object

The single boundary object that names the multi-graph relationship.
Replaces the bare-string `data_graph:` / `shapes_graph:` / `inferred:`
kwargs across every facade with a structured Scope.

```ruby
scope = Semantica::Scope.new(
  data:     "urn:mm:graph:workspace_42",         # primary data graph (asserted)
  schema:   "urn:mm:graph:shared:schema",        # OWL/RDFS axioms; read-only contribution
  shapes:   "urn:semantica:shapes:product",      # SHACL Core + Rules
  inferred: "urn:mm:graph:workspace_42:inferred",
  report:   "urn:mm:graph:workspace_42:report",
)

# All facades accept either an explicit Scope or per-kwarg graphs:
Semantica::Reasoner.materialise!(scope: scope, rules: [:owl_2_rl, :shacl_rules])
Semantica::Shacl.validate!(scope: scope)
Semantica::Shacl::Rules.materialise!(scope: scope)
Semantica::ChangeSet.capture(scope: scope) { ... }   # PLAN_0.11.0
```

#### Implementation
- `Semantica::Scope` is a frozen value object with five
  pinned roles: `data`, `schema`, `shapes`, `inferred`, `report`.
  Any of the last four may be `nil` (per-facade required-role
  validation refuses with `:scope_role_missing`).
- Operators may extend with additional named roles:
  `Scope.new(data: …, …, additional: { ontology: "urn:…" })`
  — addressable via `scope.additional[:ontology]`.
- `Scope` is comparable by value (`==`, `hash`, `eql?`). Two
  Scopes with the same five graph IRIs are the same Scope.
- `Scope#read_graphs` — the set of graphs the facades read
  from (every named role except `inferred:` / `report:`, plus
  any additional read-marked roles).
- `Scope#write_graphs` — the set of graphs the facades may
  write to (`inferred:` + `report:`).
- Backwards compatibility: every existing facade keeps its
  per-kwarg shape. When the gem detects both `scope:` and a
  kwarg that the Scope covers, refuses with `:scope_kwarg_conflict`.

#### Refusal envelope additions
- `:scope_role_missing` — facade needs a role the Scope doesn't
  declare (e.g., `Reasoner.materialise!` needs `data:` +
  `inferred:`; SHACL needs `shapes:` + `data:` + `report:`).
- `:scope_kwarg_conflict` — operator passed both a Scope and an
  overlapping kwarg.
- `:scope_read_write_overlap` — a write graph
  (`inferred`/`report`) is also declared as a read graph.
  Refuse rather than silently emit triples that the next read
  immediately picks up as input (would loop in the reasoner).

#### Exit criteria
- Spec: `Scope.new(...)` with all five roles round-trips equality.
- Spec: facades reject `scope:` + overlapping kwarg with
  `:scope_kwarg_conflict`.
- Spec: facade missing a required role refuses with
  `:scope_role_missing`.
- Spec: read/write overlap refuses with `:scope_read_write_overlap`.

### Phase B — Multi-graph OWL 2 RL reasoner

OWL 2 RL rules read from the union `data ∪ schema`, derive into
`inferred`. The RDF-star provenance grows the
`semantica:derivedFromGraph` predicate per premise so DRed can
attribute retractions back to the source graph.

```ruby
Semantica::Reasoner.materialise!(scope: scope, rules: :owl_2_rl)
# Reads premises from scope.data + scope.schema;
# emits inferred triples + provenance into scope.inferred.
```

#### Implementation
- Each OWL 2 RL rule (PLAN_0.9.0 Phase B) is rewritten at
  facade-init time to read from the multi-graph union:
  - `INSERT { ?c1 rdfs:subClassOf ?c3 } WHERE { ?c1 rdfs:subClassOf ?c2 . ?c2 rdfs:subClassOf ?c3 . }`
  - becomes
  - `INSERT { GRAPH <inferred> { ?c1 rdfs:subClassOf ?c3 } } WHERE { { GRAPH <data> { ?c1 rdfs:subClassOf ?c2 } UNION GRAPH <schema> { ?c1 rdfs:subClassOf ?c2 } } . { GRAPH <data> { ?c2 rdfs:subClassOf ?c3 } UNION GRAPH <schema> { ?c2 rdfs:subClassOf ?c3 } } }`
  - The rewrite is mechanical; per-rule `Rules::OwlRl`
    transcriptions stay in the PLAN_0.9.0 form, and the
    multi-graph rewriter handles the SPARQL surgery.
- Provenance grows to include the source graph IRI per
  premise:
  ```
  << ?c1 rdfs:subClassOf ?c3 >> :derivedBy :Rule_scm-sco ;
                                 :derivedAt NOW() ;
                                 :derivedFrom << ?c1 rdfs:subClassOf ?c2 >> ;
                                 :derivedFromGraph <urn:mm:graph:shared:schema> ;
                                 :derivedFrom << ?c2 rdfs:subClassOf ?c3 >> ;
                                 :derivedFromGraph <urn:mm:graph:shared:schema> .
  ```
  The pairing is positional: the N-th `:derivedFrom` matches
  the N-th `:derivedFromGraph`. (Spec asserts the pairing
  contract; document.)

#### Why positional and not nested
RDF-star doesn't natively nest reification — a `:derivedFrom`
attached to a quoted triple is just an annotation, not a
container. Operators wanting structured provenance (one
"premise" node per actual premise, each carrying the triple
and the graph as properties) can opt into the structured shape
via `provenance: :structured`:

```ruby
<< inferred-triple >> :derivedFrom [ :triple << s p o >> ; :inGraph <urn:...> ] .
```

`provenance: :positional` (the default; matches the v0.9.0 shape
extended with `:derivedFromGraph`) is cheaper to query; `:structured`
is cleaner for cross-graph audit trails. Pick once per scope.

#### Refusal envelope additions
- `:multi_graph_provenance_mismatch` — operator switched
  between `:positional` and `:structured` between
  `materialise!` calls on the same inferred graph. The new
  call refuses; operators clear the inferred graph + restart.
- `:cross_graph_cycle_detected` — schema graph contains
  axioms that, when applied to the data graph, derive
  triples that, when re-read in subsequent iterations,
  cycle infinitely. The reasoner refuses with the cycle
  trace; usually means the schema declares mutually-
  recursive equivalence axioms.

#### Exit criteria
- Spec: OWL 2 RL over `data + schema` derives the expected
  closure into `inferred`, with `:derivedFromGraph`
  annotations naming the actual source graph per premise.
- Spec: equivalence between full-pass single-graph (PLAN_0.9.0)
  and multi-graph with `schema: nil` and all axioms in
  `data:` — the multi-graph rewriter must be a no-op when
  there's only one read graph.
- Spec: cross-graph cycle refuses with
  `:cross_graph_cycle_detected`.
- Spec: `provenance: :positional` and `:structured` produce
  the same logical attribution (different RDF shapes).

### Phase C — Multi-graph SHACL Core validator

SHACL Core validation reads target nodes from `data`, reads
shape definitions from `shapes`, optionally consults `schema`
for class-membership constraints (`sh:class`), and writes the
report into `report`.

```ruby
Semantica::Shacl.validate!(scope: scope)
# Targets resolved against scope.data;
# constraints evaluated against scope.data ∪ scope.schema
#   (for class-membership-aware constraints like sh:class);
# report written to scope.report (cleared + rewritten).
```

#### Implementation
- Target-node resolution stays scoped to `data` only —
  shapes target instances, and an instance lives in the data
  graph. Schema graph is for the axioms instances are checked
  *against*, not where targets live.
- Constraint evaluation routes through the multi-graph read
  union for the constraints that need it:
  - `sh:class` checks for `rdf:type` chains that may go
    through schema-graph subClassOf axioms; reads from
    `data ∪ schema`.
  - `sh:datatype` / `sh:nodeKind` / `sh:minCount` etc.
    are data-graph-local.
  - `sh:node` references may point to shapes in either
    `shapes` (the primary shapes graph) or in
    `scope.additional[:shapes_library]` if operators
    declare a shape library.
- Validation report shape (PLAN_0.10.0 Phase E) gains one
  pinned predicate per result: `semantica:resultGraph`
  naming the graph the focus node lived in (always
  `scope.data` in v0.13.0; placeholder for v0.14.0's
  multi-data-graph extension if MM signals demand).

#### Exit criteria
- Spec: a `sh:class :EvilCorp` constraint where the focus
  node is `:product1` in `scope.data` and `:EvilCorp`'s
  subClassOf chain is in `scope.schema` validates correctly.
- Spec: a shape graph that doesn't exist in `scope.shapes`
  refuses with `:shapes_graph_empty` (new symbol).
- Spec: the report records `semantica:resultGraph` per result.

### Phase D — Multi-graph SHACL Rules

SHACL Rules derive triples just like OWL 2 RL: reads from
`data ∪ schema`, writes to `inferred`, attaches the same
`:derivedFromGraph` annotations.

```ruby
Semantica::Shacl::Rules.materialise!(scope: scope)
```

#### Implementation
- Rules' WHERE clauses are rewritten with the multi-graph
  union same way OWL 2 RL rules are (Phase B).
- `sh:condition` evaluation (PLAN_0.12.0) consults the
  multi-graph union — a condition shape's conformance
  check may need both `data` and `schema` triples.
- Per-rule `provenance:` mode propagates from the
  `Reasoner.materialise!` call (operators don't mix
  modes between OWL and SHACL Rules in one pass).

#### Exit criteria
- Spec: a `triple_rule` whose subject IRI computed from a
  data-graph triple references a schema-graph axiom
  derives correctly with `:derivedFromGraph` naming both
  source graphs.
- Spec: a `sparql_rule` with a CONSTRUCT body that reads
  from both `data` and `schema` materialises correctly.
- Spec: cross-graph SHACL Rules participate in the OWL +
  SHACL orchestration order (PLAN_0.12.0 Phase C).

### Phase E — Cross-graph DRed

The DRed dependency traversal becomes graph-aware: a retracted
premise in graph A only over-deletes inferred triples whose
`:derivedFromGraph` actually names A. Premises in graph B that
"look the same" (same `(s, p, o)`) don't trigger over-deletion
of A-derived triples.

```ruby
Semantica::Reasoner.materialise_incremental!(
  scope:   scope,
  changes: change_set,                    # may span multiple data graphs
)
```

#### Implementation
- The change-set (PLAN_0.11.0 Phase A) gains an optional
  `graph:` per recorded write, recording which graph the
  add/retract touched. The `ChangeSet#added` / `#retracted`
  arrays become `Array<[s, p, o, graph]>` rather than
  `Array<[s, p, o]>`.
- DRed Phase 1 (over-deletion):
  - `DELETE { ?s ?p ?o }
     WHERE { << ?s ?p ?o >> :derivedFrom << ?ps ?pp ?po >> ;
                            :derivedFromGraph ?pg .
             VALUES (?ps ?pp ?po ?pg) { (<retracted s> <retracted p> <retracted o> <retracted g>) ... } }`
  - The `(s, p, o, g)` 4-tuple match constrains over-deletion
    to triples whose actual provenance graph matches.
- DRed Phase 2 (re-derivation): re-applies the multi-graph
  union of rules, identical to Phase B but restricted to
  triples touched in Phase 1 + the change-set's adds.
- Cross-graph cycle detection identical to Phase B.

#### Correctness pin
- v0.13.0 specs full-pass-vs-incremental equivalence for the
  multi-graph case: a Scope + ChangeSet passed through full
  `materialise!` (rebuild from scratch) and through
  `materialise_incremental!` produces the same inferred-graph
  contents (modulo `:derivedAt` timestamps).
- An additional pin covers the *graph-attribution* correctness:
  a change-set that retracts `:foo` in graph A but leaves
  `:foo` in graph B intact must NOT over-delete inferences
  that were derived from graph B's `:foo`.

#### Exit criteria
- Spec: equivalence pin for multi-graph DRed.
- Spec: graph-attribution-correctness pin (above).
- Spec: a change-set spanning two data graphs runs DRed
  cleanly with `:derivedFromGraph` driving the right
  over-deletion subset.

### Phase F — Lifecycle: cross-scope orchestration

v0.13.0 does **not** auto-trigger cross-scope cascade — a
change in scope A's schema graph does NOT automatically
re-run materialisation in every scope B that consumes A's
schema. That's a v0.14.0+ orchestration question (substrate-
side; needs a registry of scope-to-scope dependencies).

What v0.13.0 ships: the building blocks operators use to wire
that orchestration themselves.

```ruby
# At the Rails app level: a scope registry the operator owns.
SCOPES = [
  Semantica::Scope.new(data: "urn:mm:graph:workspace_42", ...),
  Semantica::Scope.new(data: "urn:mm:graph:workspace_43", ...),
  ...
]

# When the shared schema graph changes, the operator iterates:
SCOPES.each { |scope| Semantica::Reasoner.materialise!(scope: scope) }
```

`:incremental_save` (PLAN_0.11.0) stays single-scope per AR
model; operators wanting cross-scope cascade write the
orchestration code themselves.

#### Implementation
- `Semantica::Scope.registry` — optional gem-level registry
  operators can populate; iterable helpers (`Scope.each`,
  `Scope.find_by_data(iri)`) for the bookkeeping. Default
  empty; v0.13.0 does NOT auto-populate from `Storable`
  declarations (Storable's `graph "…"` DSL doesn't carry
  enough information to construct a full Scope).
- Documented pattern in README: a Rails initializer
  populates `Semantica::Scope.registry` from the operator's
  Workspace / Tenant / Scope AR table.
- Per-scope concurrency: the per-(inferred-graph-IRI) Mutex
  from PLAN_0.11.0's `IncrementalPass` stays; cross-scope
  passes run in parallel since they have distinct inferred
  graph IRIs.

#### Exit criteria
- Spec: `Scope.registry` round-trips populated and queried.
- Spec: parallel `materialise!` calls against two scopes
  with the same `schema:` but different `data:` /
  `inferred:` succeed in parallel (asserted via thread
  spy).
- Spec: parallel `materialise!` calls against the same
  Scope serialise (asserted via the existing PLAN_0.11.0
  Mutex spec).

### Phase G — Specs + bin/check

- New file `spec/semantica/scope_spec.rb` covering Phase A.
- New file `spec/semantica/reasoner_multi_graph_spec.rb`
  covering Phase B + the single-graph equivalence pin.
- New file `spec/semantica/shacl_multi_graph_spec.rb`
  covering Phase C.
- New file `spec/semantica/shacl_rules_multi_graph_spec.rb`
  covering Phase D.
- New file `spec/semantica/reasoner_incremental_multi_graph_spec.rb`
  covering Phase E + the graph-attribution-correctness pin.
- `bin/check` green against engine ≥ 0.7.0 (no new pin —
  multi-graph rides existing engine surfaces).

### Phase H — Docs

- `CHANGELOG.md` — `0.13.0` heading with per-phase entries.
- `README.md` — new "Cross-graph scopes" section after the
  SHACL Rules section, with the `Scope.new(...)` example,
  the per-facade `scope:` kwarg, the per-scope orchestration
  pattern (initializer + registry), and the gotchas list.
- `CONSUMER_REQUIREMENT_MM.md` — promote multi-graph scopes
  to a §11 surface block once MM signals adoption.
- `docs/plans/PLAN_0.13.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.13.0`.

## Out of scope for v0.13.0

- **Federated SPARQL** (queries across remote SPARQL
  endpoints via `SERVICE`). Different problem space; needs
  HTTP-aware engine surface. Out indefinitely.
- **Dynamic scope composition at query time.** Operators
  must declare Scopes statically (in an initializer or per
  call site); the gem does not infer scope membership from
  query patterns. Out indefinitely.
- **Cross-scope cascade.** Automatically re-running
  materialisation in every scope that consumes a shared
  schema when the schema changes. v0.13.0 ships
  `Scope.registry` + the per-scope `materialise!` shape;
  operators wire the cascade themselves. v0.14.0+ candidate
  if substrate-side telemetry shows the boilerplate is
  enough cost to justify gem-level orchestration.
- **Multi-data-graph scopes.** A single Scope whose `data:`
  is itself a list of graphs (e.g., "the workspace's data
  is the union of `:workspace_42:catalogue` and
  `:workspace_42:agents`"). The `semantica:resultGraph`
  predicate is the placeholder; v0.13.0 ships
  single-data-graph Scopes only. v0.14.0+ candidate.
- **Scope inheritance / overrides.** "Scope B inherits all
  of Scope A's roles except `data:`." Out — operators
  compose by hand via `Scope.new(...)`'s explicit kwargs.
- **Graph-versioning / time-travel within scopes.** PLAN_0.11.0
  already lists time-travel as v0.12.0+ horizon; v0.13.0
  doesn't add to it.
- **Auto-population of `Scope.registry` from Storable.** The
  Storable `graph "…"` DSL declares one graph per model; it
  doesn't know about schema / shapes / inferred / report.
  v0.13.0 ships the registry as operator-populated.
- **Permission model.** v0.13.0 does NOT enforce
  read-vs-write ACLs on the per-Scope graphs (e.g., "scope B
  can read scope A's schema but not write to it"). That's a
  multi-tenant security question outside the gem's scope.
  Operators enforce ACLs at the Rails authorisation layer
  (`Pundit` / `CanCan` / etc.) before reaching the gem.
- **Cross-graph SHACL Rules with multiple inferred outputs.**
  A rule that derives into two different inferred graphs
  based on the focus node's source graph. Operators
  duplicate the rule with different shapes-graph
  attachments. v0.14.0+ candidate.

## Risks

| Risk | Mitigation |
|---|---|
| `:derivedFromGraph` doubles or triples the provenance graph size on dense closures. | Operators opt into `provenance: false` for memory-bound workloads (PLAN_0.9.0's existing escape hatch). The `:structured` provenance mode is more verbose but easier to query; `:positional` mode is cheaper. Doc the trade-off. |
| Cross-graph dependency tracking requires the change-set graph attribution (`[s, p, o, graph]` rows); operators on pre-v0.13.0 ChangeSet captures break. | Auto-migration: a v0.13.0 ChangeSet with no `graph:` per row treats every row as belonging to `scope.data` — backward-compatible. Operators who upgrade and want true multi-graph capture explicitly opt in via `ChangeSet.capture(scope: scope)` (already the recommended shape). |
| Shared schema graphs become a concurrency hot-spot — every scope's `materialise!` reads from it. | Reads are concurrent (the engine's read paths don't serialise). Writes to the schema graph go through the same per-(inferred-graph-IRI) Mutex which doesn't help if multiple operators write the schema. Substrate-side: shared schema graphs should be write-rare / read-frequent; if MM hits write contention, that's a Workspace-management problem upstream. |
| Cross-graph cycle detection has false positives — some axioms look mutually-recursive but converge (e.g., `:A owl:equivalentClass :B` + `:B owl:equivalentClass :C`). | The `max_iterations` guard (PLAN_0.9.0) bounds the failure mode; `:cross_graph_cycle_detected` only fires on actual non-termination. Spec asserts the false-positive avoidance. |
| The positional `:derivedFrom` / `:derivedFromGraph` pairing is fragile — easy for operators to mis-introspect. | Pin the pairing contract in the README. Provide a helper: `Semantica::Provenance.parse(<< … >>)` returns a structured Array<{ triple:, graph: }> regardless of which provenance mode the closure used. Spec asserts the round-trip. |
| Scope role names (`data:`, `schema:`, `shapes:`, `inferred:`, `report:`) don't cover every conceivable composition. | The `additional: { ... }` Hash escape hatch handles edge cases. Substrate-side operators wanting more named roles add to the additional map. If a role becomes universally-useful, it graduates to a first-class Scope role in a future version. |
| Multi-graph rewriter is verbose; an operator-written SPARQL inside `sh:SPARQLRule` may also need rewriting and the gem may not catch every case. | v0.13.0's rewriter inspects `sh:SPARQLRule` queries for `FROM` / `GRAPH` patterns; queries that already declare their own dataset are left alone (operator opted in to manual scope management). Queries with no `FROM`/`GRAPH` get the multi-graph union prepended. Doc the heuristic. |
| Equivalence pin (full-pass-vs-incremental for multi-graph) is harder to establish than the single-graph case. | The spec uses the same equivalence harness as PLAN_0.11.0's spec, parameterised over Scopes; the harness asserts inferred-graph triple-set equality (modulo `:derivedAt`). |
| Cross-graph SHACL Rules with `sh:condition` referencing a shape in a different shapes graph than the rule. | v0.13.0 ships single-`shapes`-graph Scopes; multi-shape-graph composition is OOS. `sh:condition` references must resolve in `scope.shapes`. Refuse with `:condition_shape_missing` (PLAN_0.12.0's symbol) if the reference doesn't resolve. |
| `Scope.registry` is gem-level mutable state; tests need teardown. | The registry is per-process; tests reset it via `Semantica::Scope.registry.clear` in `before(:each)`. Spec helper documented in the README's testing section. |

## Acceptance signal

1. Phases A/B/C/D/E/F land with passing specs.
2. Equivalence pin (full-pass-vs-incremental, multi-graph) green.
3. Single-graph equivalence pin (multi-graph rewriter is no-op
   when only `data:` is read) green.
4. `bin/check` green against engine ≥ 0.7.0.
5. CHANGELOG `0.13.0` heading drops `(unreleased)`.
6. `VERSION` → `0.13.0`.
7. README documents the Scope value object, the per-facade
   `scope:` kwarg, the per-scope orchestration pattern, and
   the five headline gotchas.
8. CONSUMER_REQUIREMENT_MM.md §11 notes the new optional
   surface once MM signals adoption.

## v0.13.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Semantica::Scope.new(data:, schema: nil, shapes: nil, inferred: nil, report: nil, additional: {})` | value object | **Pinned.** Roles additive (new roles in future minor versions). |
| `Semantica::Scope#read_graphs` / `#write_graphs` / `#==` / `#hash` | instance methods | **Pinned.** |
| `Semantica::Scope.registry` | gem-level Set | **Pinned.** Operator-populated. |
| `scope:` kwarg on every facade (`Reasoner.materialise!`, `Reasoner.materialise_incremental!`, `Shacl.validate!`, `Shacl.validate_incremental!`, `Shacl::Rules.materialise!`, `Shacl::Rules.materialise_incremental!`, `ChangeSet.capture`) | kwarg | **Pinned.** |
| `semantica:derivedFromGraph` predicate IRI | namespace | **Pinned.** |
| `semantica:resultGraph` predicate IRI | namespace | **Pinned.** |
| `provenance:` kwarg accepts `:positional` (default) / `:structured` / `false` | shape extension | **Pinned.** |
| `Semantica::Provenance.parse(quoted_term)` helper | module method | **Pinned.** Returns structured Array. |
| `ChangeSet#added` / `#retracted` row shape grows from `[s, p, o]` to `[s, p, o, graph]` | shape extension | **Pinned.** Backward-compatible (graph defaults to `scope.data`). |
| `:scope_role_missing` reason symbol | refusal envelope | **Pinned.** |
| `:scope_kwarg_conflict` reason symbol | refusal envelope | **Pinned.** |
| `:scope_read_write_overlap` reason symbol | refusal envelope | **Pinned.** |
| `:multi_graph_provenance_mismatch` reason symbol | refusal envelope | **Pinned.** |
| `:cross_graph_cycle_detected` reason symbol | refusal envelope | **Pinned.** |
| `:shapes_graph_empty` reason symbol | refusal envelope | **Pinned.** |

## Cross-references

- `./PLAN_0.5.0.md` — named-graph DSL; `graph:` single-graph
  kwarg stays as the convenience shape, `scope:` is the
  multi-graph successor.
- `./PLAN_0.7.0.md` — EtherealGraph; per-Scope inferred graphs
  can be persisted via Active Storage individually.
- `./PLAN_0.8.0.md` — RDF-star; `:derivedFromGraph` is the
  sibling annotation §7.6 of `StarExts.md` flagged ("no
  quoting of quads") and v0.13.0 introduces.
- `./PLAN_0.9.0.md` — OWL 2 RL reasoner; multi-graph rewriter
  generalises every rule mechanically.
- `./PLAN_0.10.0.md` — SHACL Core validator; multi-graph
  generalisation adds `semantica:resultGraph` to report
  results.
- `./PLAN_0.11.0.md` — DRed incremental; graph-aware
  dependency traversal is v0.13.0's core technical work.
- `./PLAN_0.12.0.md` — SHACL Rules; multi-graph rules ride
  the same rewriter as OWL 2 RL.
- `../research/TripesQuadsEtc.md` — the motivating sketch;
  named graphs were always the cross-scope shape; v0.13.0
  is the gem catching up.
- `magentic-market-ai/docs/research/StarExts.md` §7.6 — the
  "no quoting of quads" gotcha that `:derivedFromGraph`
  answers.
- W3C SPARQL 1.1 §13 (RDF Dataset) <https://www.w3.org/TR/sparql11-query/#rdfDataset>
  — the dataset model v0.13.0's multi-graph rewriter rides
  on.
- `sqlite-sparql/CHANGELOG.md` § `0.7.0` — engine pin v0.13.0
  inherits.
- `sqlite-sparql/CONSUMER_REQUIREMENT_RS.md` §"Requested
  extensions" — the engine acceleration asks v0.13.0
  makes more concrete (cross-graph dependency index, native
  multi-graph rule pass).
