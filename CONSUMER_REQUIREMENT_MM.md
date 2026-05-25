# Consumer requirements — MagenticMarket substrate

This file records the surface [MagenticMarket](https://github.com/laquereric/magentic-market-ai)
(the substrate; "MM" hereafter) consumes from `vv-graph`. It exists so
upstream changes can be checked against a written consumer expectation —
**drift** between this file and the gem's actual behaviour signals work that
needs to land in both repos lockstep.

This is the consumer's perspective, not the upstream spec. Other consumers
may keep their own analogous files; the upstream is free to evolve faster
than any single consumer.

- MM repo: <https://github.com/laquereric/magentic-market-ai>
- MM plan that introduced the dependency: `docs/plans/PLAN_0_29_1.md`
- MM architecture doc the dependency rides on: `docs/architecture/Vv::Graph.md`
  (promoted from `docs/research/Vv::Graph.md` during PLAN_0_29_1 Phase E)

## How MM pins this gem

```ruby
# MM's Gemfile — local development (submodule checkout)
gem "vv-graph", path: "../vendor/vv-graph"

# MM's Gemfile — CI / production (pinned SHA)
# gem "vv-graph", git: "https://github.com/laquereric/vv-graph",
#                 ref: "<sha>"
```

> *Per MM PLAN_0_81_0 Phase A — the gem was renamed from
> `rails-semantica` to `vv-graph` at v0.15.0; the Ruby namespace
> also moved from `Semantica::*` to `Vv::Graph::*`. Pre-rename CR
> revisions of this file referenced the old names; the substrate's
> surface inventory below uses the new names exclusively.*

MM's `Gemfile.lock` records the exact rev in use. When an MM PR bumps the
pin, the PR description references the upstream PR that motivated the bump.

## Surfaces MM consumes

### `Vv::Graph::Loader`

- `Vv::Graph::Loader.ensure_extension_loaded!` — idempotent. MM's Railtie
  calls this in `config.after_initialize`; MM expects the call to be safe
  to repeat on every new AR connection.
- Failure mode: raises `Vv::Graph::Loader::ExtensionMissing` with a
  structured because-clause naming the expected path + the `cargo build`
  command.
- Env var the Loader reads: `VV_GRAPH_SQLITE_SPARQL_PATH` (absolute path to
  `libsqlite_sparql.{dylib,so}`). If renamed upstream, MM's
  `config/database.yml` + `QuickStart_Developer.md` must update lockstep.

### `Vv::Graph::Sparql`

Four class methods. **All four return structured envelopes; none raise.**
This is load-bearing for MM's Architect's-No #18 discipline (every refusal
carries a verbatim because-clause).

```ruby
Vv::Graph::Sparql.select(query_string)
# => { ok: true,  results: [{ "var" => "value", ... }, ...] }
# => { ok: false, reason: <symbol>, because: <string> }

Vv::Graph::Sparql.ask(query_string)
# => { ok: true,  value: true|false }
# => { ok: false, reason: <symbol>, because: <string> }

Vv::Graph::Sparql.construct(query_string)
# => { ok: true,  ntriples: "<s> <p> <o> .\n..." }
# => { ok: false, reason: <symbol>, because: <string> }

Vv::Graph::Sparql.execute(update_query_string)
# => { ok: true,  count: <integer> }
# => { ok: false, reason: <symbol>, because: <string> }
# v0.1.0 supports INSERT DATA / DELETE DATA / CLEAR ALL forms.
# v0.2.0 adds DELETE WHERE { <s> <p> ?o } (read-replace by predicate).
# v0.3.0 routes any other UPDATE form through the engine's
# sparql_update scalar; `:count:` is the engine's signed net delta
# (inserts − deletes) for that path. The four fast paths still
# return positive counts.
```

Pinned `:reason` symbols (v0.1.0): `:sparql_parse_error`,
`:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`.
v0.3.0 adds `:sparql_eval_error` (semantically-invalid UPDATE; engine
prefix `"SPARQL evaluation error:"`).
v0.5.0 (named-graph) adds `:invalid_graph` and `:invalid_dsl`; see §5.

Envelope-shape stability MM depends on:

- `:ok` key always present, boolean.
- On `ok: true`, the result payload is in a single named key (`:results` /
  `:value` / `:ntriples` / `:count`).
- On `ok: false`, both `:reason` (symbol) and `:because` (human-readable
  string) are present.
- Additive fields are safe; renames or removals are breaking from MM's POV.

### `Vv::Graph::Storable` concern + DSL

```ruby
class Product < ApplicationRecord
  include Vv::Graph::Storable

  triples do
    subject       -> { "urn:mm:product:#{sku}" }
    triple "schema:name",     -> { name }
    triple "schema:category", -> { category }
    triple "schema:gtin",     -> { gtin }, if: -> { gtin.present? }
  end
end
```

MM depends on:

- `triples do … end` block-DSL ergonomics: `subject`, `triple` keywords;
  `if:` conditional gating; lambdas evaluated in instance scope.
- Lifecycle hooks: `after_save` emits idempotently (updates re-emit; same
  subject/predicate/object combo is a no-op the second time). `after_destroy`
  retracts every declared triple.
- Term serialization: N-Triples spec — IRI brackets, literal escaping,
  blank-node IDs — handled by the gem; MM never serializes terms by hand.
- An `emit_triples!` instance method for bulk re-emission
  (`Product.find_each(&:emit_triples!)` is MM's data-migration shape).

### `Vv::Graph::EtherealGraph` concern + DSL (v0.7.0) — optional

Surface MM may consume for scopes that need a named RDF graph
tied to an AR record's lifetime (e.g. Session, Workspace, Tenant
contexts).

- `include Vv::Graph::EtherealGraph` — pinned name.
- `ethereal_graph do; iri ->{...}; checkpoint_on :explicit|:save; end` — pinned DSL.
- `#hydrate_ethereal_graph!` → `{ ok:, hydrated: <integer>, reason?: :no_blob | :already_hydrated | :empty_blob }`.
- `#checkpoint_ethereal_graph!` → `{ ok:, written: <byte_count> }`.
- `#retract_ethereal_graph!` registered as `before_destroy`; clears the named graph + evicts the IRI from `HYDRATED_IRIS`. Blob purges via `has_one_attached … dependent: :purge_later`.
- `Vv::Graph::EtherealGraph.evict!(iri)` — escape hatch for multi-process operators.
- `has_one_attached :vv_graph_blob` — pinned attachment name (auto-registered when Active Storage is available).
- Active Storage is operator-supplied; MM's `Gemfile` must declare `activestorage ~> 8.0` for any scope that includes the concern.
- Composes with `Vv::Graph::Storable`: declare `triples do` *before* `ethereal_graph do` so the emit callback fires before checkpoint. Pinned by the composition spec.

### Versioning expectation

While the gem is v0.x.x, surface refinements MM needs travel as upstream PRs
authored by MM. MM does **not** ship in-substrate monkey-patches against
this gem; if MM's needs would require one, that's a signal the upstream PR
needs to land first.

At v1.0 the surfaces above are pinned by semver. MM will switch from path
to RubyGems consumption at v1.0.

## Behaviours MM does NOT depend on

So upstream is free to change these without notifying MM:

- The exact internal SQL emitted by `Storable` lifecycle hooks (MM observes
  the SPARQL-visible outcome, not the SQL). v0.3.0's `dispatch_mode`
  ladder (`:sparql_update` / `:bulk` / `:per_call`) is upstream-internal;
  MM exercises only the SPARQL-visible outcome, which is invariant across
  modes. Operators wanting predictable behaviour across upgrades pin via
  `MM_SEMANTICA_DISPATCH_MODE`; the env var contract has lifetime ≥ v1.0.
- The Oxigraph version pinned by `sqlite-sparql` (MM tolerates Oxigraph
  bumps as long as the SPARQL semantics MM exercises stay stable — see
  `sqlite-sparql/CONSUMER_REQUIREMENT_MM.md`).
- The shape of `Loader`'s internal connection-pool hooks. MM only depends
  on `ensure_extension_loaded!` being callable + idempotent.
- The class names of internal helpers (e.g., term serializers). MM only
  references the documented public surface.

## Concurrency model

PLAN_0.6.0 (v0.6.0) pinned the shared-store contract MM relies on:

- The engine holds one Oxigraph store per process; writes from one
  AR connection are visible from any other connection in the same
  process, including across threads. (Pre-engine-0.2.0 thread-local
  storage was a footgun; v0.6.0 documents the now-correct contract.)
- For multi-threaded writes to overlapping `(subject, predicate)`
  pairs, MM pins `MM_SEMANTICA_DISPATCH_MODE=sparql_update` —
  that's the only dispatch mode that's atomic per predicate
  replacement (single engine call). `:bulk` and `:per_call` race.
- Test isolation: substrate-side specs that exercise `Storable`
  must run serially. Parallel test workers clobber the shared
  process-wide store; MM's RSpec config doesn't enable parallel
  workers for the same reason.

## Drift signals

A drift between this file and the gem's behaviour is detectable in these
places:

- MM's `server/spec/architecture/semantica_substrate_audit_spec.rb` —
  fails when the envelope shape, Storable surface, or Loader semantics
  drift.
- MM's `server/spec/integration/semantica_roundtrip_spec.rb` — fails when
  a real `Product.create!` → `Sparql.select` round-trip stops returning
  the expected triples.
- MM's `bin/mm-smoke` — its `semantica` step probes Loader + a tiny SPARQL
  round-trip; goes red when the gem is broken at the pinned rev.

When drift is detected, the fix path is:

1. Open an upstream PR with the corrected behaviour + a new upstream spec.
2. Land it; record the new SHA.
3. Bump MM's `Gemfile.lock` to the new SHA + update this file if the
   consumer expectation changed.

Never fix drift by patching the gem from within MM. The boundary stays
bright in both directions.

## Requested extensions (toward v0.2.0)

PLAN_0_29_1 Phase B.2 — MM's full deletion of the legacy `Triple` AR
model + `ProductTripler` service — needs the following `Vv::Graph::Storable`
DSL extensions before the cutover is doctrine-pure. Until they land,
MM ships a substrate-side hybrid: simple per-record predicates via
`Storable`; complex emissions via direct `Vv::Graph::Sparql.execute`
calls in a `Product#emit_complex_triples!` instance method. The
hybrid is explicitly interim — when v0.2.0 ships these extensions,
that substrate-side method is deleted + the logic inlines into the
`triples do…end` block.

### 1. Multi-subject emission — **SHIPPED (PLAN_0.2.0 Phase A, v0.2.0)**

MM's product projection emits triples on derived URIs in addition to
the primary record URI. Example: a `Product` save also emits triples
on the category-folder URI (`urn:mm:folder:category:printer`)
declaring its `rdf:type` + `schema:name`. Shipped DSL:

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

Semantics: each `on_subject` block runs after the primary subject's
emissions; the same read-replace per (subject, predicate) idempotency
applies; `after_destroy` retracts every block's emissions. Literal-
string predicate values (`"<urn:…>"`-wrapped) serialize as IRI
objects without a lambda wrapper.

### 2. Variable-cardinality emission via collection iteration — **SHIPPED (PLAN_0.2.0 Phase B, v0.2.0)**

MM's product projection emits one triple per `product.product_specs`
row. The collection's size varies per record. Shipped DSL:

```ruby
triples do
  subject -> { "urn:mm:product:#{sku}" }

  each -> { product_specs } do |spec|
    triple "mm:#{spec.name.camelize(:lower)}", -> { spec.value }
  end
end
```

Semantics: on `after_save`, the gem walks the collection at save time
+ emits one triple per element. Read-replace adjusts per #3.
Limitation pinned at v0.2.0: an empty collection this save does not
retract triples emitted by a prior non-empty save; operators pair
with explicit `Sparql.execute("DELETE WHERE { <s> <p> ?o }")` when
strict cleanup is required.

### 3. Multi-value predicates — **SHIPPED (PLAN_0.2.0 Phase B, v0.2.0)**

MM's `hasFeature` predicate fires once per feature flag present on a
`Product`. Storable v0.1.0's read-replace assumed one value per
(subject, predicate); v0.2.0 allows multiple inside an `each` block.
Semantics: multiple values under the same predicate emit as separate
triples; read-replace becomes "delete every triple matching (subject,
predicate); insert all new values."

### 4. JSON literal / structured-literal object type — **SHIPPED (PLAN_0.2.0 Phase C, v0.2.0)**

MM's `schema:offers` triple packs a multi-field hash into a JSON
string literal. `TermSerializer.object` grows `when Hash, Array`
branches: values JSON-encode via `JSON.generate` and emit as typed
literals with `xsd:string` datatype. Operators read back via
`Sparql.select` + `JSON.parse` on the literal value. The opt-in
`as: :json` syntax was rejected as over-engineering; if a real need
surfaces for a Hash-as-stringified-Hash literal, a v0.2.x bump can
add it.

### 5. Named graph parameter — **SHIPPED (PLAN_0.5.0)**

Both surfaces MM asked for landed:

```ruby
# Sparql methods — graph: kwarg on all four
Vv::Graph::Sparql.select(query, graph: "urn:mm:graph:bhphoto")
Vv::Graph::Sparql.ask(query, graph: "urn:mm:graph:bhphoto")
Vv::Graph::Sparql.construct(query, graph: "urn:mm:graph:bhphoto")
Vv::Graph::Sparql.execute(update, graph: "urn:mm:graph:bhphoto")

# Storable DSL — graph "..." declaration in the triples block
class Product < ApplicationRecord
  include Vv::Graph::Storable

  triples do
    graph "urn:mm:graph:bhphoto"
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }
    # `on_subject` and `each` blocks inherit the outer graph.
  end
end
```

Semantics:

- `graph: nil` (or omitted) = default graph (v0.4.0 behaviour, unchanged).
- Read methods textually insert `FROM <graph>` between the projection and WHERE (handles SELECT / ASK / CONSTRUCT; PREFIX preamble preserved; WHERE-less syntactic sugar `SELECT ?s { ... }` also handled).
- `execute("INSERT DATA { ... }", graph: ...)` routes through the engine's 4-arg `rdf_insert(s,p,o,graph)` (sqlite-sparql 0.3.0). `execute("DELETE DATA { ... }", graph: ...)` and `execute("DELETE WHERE { <s> <p> ?o }", graph: ...)` route through 4-arg `rdf_delete`.
- Blank-node graph IRIs (`_:foo`) refuse with `:invalid_graph` at the gem boundary.
- `execute("CLEAR ALL", graph: ...)` and `execute("CLEAR DEFAULT", graph: ...)` refuse with `:invalid_dsl` (ambiguous scoping); operators use `execute("CLEAR GRAPH <urn:...>")` for named-graph clear.
- `Storable` lifecycle hooks (`after_save` / `after_destroy`) thread the declared graph through all three dispatch modes (`:sparql_update` / `:bulk` / `:per_call`); all produce equivalent end states for a graph-scoped model. Pinned by `spec/semantica/storable_spec.rb`'s dispatch-mode-vs-graph parity loop.
- Cross-graph isolation: ops on a graph leave triples for the same subject in other graphs untouched.

New pinned reason symbols (additive on top of v0.1.0): `:invalid_graph`, `:invalid_dsl`.

### 6. Batched-write convenience (`Sparql.bulk_insert`) — **SHIPPED (PLAN_0.4.0, v0.4.0)**

Shipped surfaces: `Vv::Graph::Sparql.bulk_insert(rows)` /
`bulk_delete(rows)` accept both Hash and Array row forms; single
FFI crossing per batch via the engine's `rdf_insert_many` /
`rdf_delete_many` scalars. Abort-batch-on-error: any malformed row
refuses the whole batch (`:because:` carries the row index);
`Storable.dispatch_mode == :bulk` lights up — lifecycle hooks
collapse to one combined `bulk_delete` + one combined `bulk_insert`
per save regardless of declared-predicate count. The substrate
consumes:

```ruby
Vv::Graph::Sparql.bulk_insert([
  { s: "urn:mm:product:EPET2850", p: "schema:name",     o: "Epson EcoTank" },
  { s: "urn:mm:product:EPET2850", p: "schema:category", o: "printer" },
  { s: "urn:mm:product:EPET2850", p: "schema:gtin",     o: "01234567890123" },
])
# => { ok: true, inserted: 3 }
# => { ok: false, reason:, because: }

# Or the positional shape:
Vv::Graph::Sparql.bulk_insert([
  ["urn:mm:product:EPET2850", "schema:name",     "Epson EcoTank"],
  # ...
])
```

Semantics:

- Each row is `{ s:, p:, o: }` (or a 3- or 4-tuple `[s, p, o(, graph)]`).
- Values pass through `TermSerializer` (same dispatch the `triples
  do…end` DSL uses), so `s` is wrapped as IRI, `o` dispatches by Ruby
  type (String/Integer/Float/Date/etc.). Operators wanting raw
  N-Triples terms can pre-wrap (`"<urn:…>"` or `"\"value\""`); those
  pass through unchanged.
- Dispatches under the hood to `sqlite-sparql`'s `rdf_insert_many`
  (see
  [`sqlite-sparql/CONSUMER_REQUIREMENT_MM.md`](https://github.com/laquereric/sqlite-sparql/blob/main/CONSUMER_REQUIREMENT_MM.md#array-argument-batched-insert-rdf_insert_many)).
  Single FFI crossing per batch; Rust loops in-engine.
- Returns a structured envelope; never raises.
- Symmetric `Vv::Graph::Sparql.bulk_delete(rows)` would be natural; same
  shape.

`Storable` then batches its per-save emissions: instead of N
`SELECT + DELETE + INSERT DATA` round-trips per record, one bulk
delete (all current values for the declared (subject, predicate)
pairs) + one bulk insert (all new values). Idempotency contract from
the current Storable docs stays unchanged; only the dispatch shape
changes.

### Acceptance signal

When all six extensions land (single v0.2.0 or incrementally across
v0.1.x → v0.2.0), MM:

1. Bumps `Gemfile.lock` to the new rev.
2. Deletes `Product#emit_complex_triples!`.
3. Inlines the complex projection into `Product`'s `triples do…end` block.
4. Deletes `ProductTripler` + `Triple` AR model + drops the `triples` SQL table.
5. Rewrites the PLAN_0_29_1 Phase B.1 copy migration to call
   `Vv::Graph::Sparql.bulk_insert` in ~1000-row batches.
6. Updates this file: each requested extension graduates from
   "Requested" into "Surfaces MM consumes."

The PLAN_0_29_1 Phase B.2 cutover commit references this section's
commit hash for traceability.

## Contact

For questions about MM's consumption pattern, see MM's
`docs/architecture/Vv::Graph.md` or open an issue on the MM repo.

## Last reviewed

2026-05-25 against MM substrate commit `e66aa9d` per `docs/plans/PLAN_0_91_0.md` (Phase A).
