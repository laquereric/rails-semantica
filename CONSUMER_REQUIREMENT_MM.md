# Consumer requirements — MagenticMarket substrate

This file records the surface [MagenticMarket](https://github.com/laquereric/magentic-market-ai)
(the substrate; "MM" hereafter) consumes from `rails-semantica`. It exists so
upstream changes can be checked against a written consumer expectation —
**drift** between this file and the gem's actual behaviour signals work that
needs to land in both repos lockstep.

This is the consumer's perspective, not the upstream spec. Other consumers
may keep their own analogous files; the upstream is free to evolve faster
than any single consumer.

- MM repo: <https://github.com/laquereric/magentic-market-ai>
- MM plan that introduced the dependency: `docs/plans/PLAN_0_29_1.md`
- MM architecture doc the dependency rides on: `docs/architecture/Semantica.md`
  (promoted from `docs/research/Semantica.md` during PLAN_0_29_1 Phase E)

## How MM pins this gem

```ruby
# MM's Gemfile — local development (submodule checkout)
gem "rails-semantica", path: "vendor/rails-semantica"

# MM's Gemfile — CI / production (pinned SHA)
# gem "rails-semantica", git: "https://github.com/laquereric/rails-semantica",
#                       ref: "<sha>"
```

MM's `Gemfile.lock` records the exact rev in use. When an MM PR bumps the
pin, the PR description references the upstream PR that motivated the bump.

## Surfaces MM consumes

### `Semantica::Loader`

- `Semantica::Loader.ensure_extension_loaded!` — idempotent. MM's Railtie
  calls this in `config.after_initialize`; MM expects the call to be safe
  to repeat on every new AR connection.
- Failure mode: raises `Semantica::Loader::ExtensionMissing` with a
  structured because-clause naming the expected path + the `cargo build`
  command.
- Env var the Loader reads: `MM_SQLITE_SPARQL_PATH` (absolute path to
  `libsqlite_sparql.{dylib,so}`). If renamed upstream, MM's
  `config/database.yml` + `QuickStart_Developer.md` must update lockstep.

### `Semantica::Sparql`

Four class methods. **All four return structured envelopes; none raise.**
This is load-bearing for MM's Architect's-No #18 discipline (every refusal
carries a verbatim because-clause).

```ruby
Semantica::Sparql.select(query_string)
# => { ok: true,  results: [{ "var" => "value", ... }, ...] }
# => { ok: false, reason: <symbol>, because: <string> }

Semantica::Sparql.ask(query_string)
# => { ok: true,  value: true|false }
# => { ok: false, reason: <symbol>, because: <string> }

Semantica::Sparql.construct(query_string)
# => { ok: true,  ntriples: "<s> <p> <o> .\n..." }
# => { ok: false, reason: <symbol>, because: <string> }

Semantica::Sparql.execute(update_query_string)
# => { ok: true,  count: <integer> }
# => { ok: false, reason: <symbol>, because: <string> }
# v0.1.0 supports INSERT DATA / DELETE DATA / CLEAR ALL forms.
# v0.2.0 adds DELETE WHERE { <s> <p> ?o } (read-replace by predicate).
# Arbitrary SPARQL UPDATE is post-v0.2.0 (ships as PLAN_0.3.0 against
# engine sparql_update — see rails-semantica/docs/plans/PLAN_0.3.0.md
# and the engine's CONSUMER_REQUIREMENT_RS.md).
```

Pinned `:reason` symbols (v0.1.0): `:sparql_parse_error`,
`:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`.
v0.5.0 (named-graph) adds `:invalid_graph` and `:invalid_dsl`; see §5.

Envelope-shape stability MM depends on:

- `:ok` key always present, boolean.
- On `ok: true`, the result payload is in a single named key (`:results` /
  `:value` / `:ntriples` / `:count`).
- On `ok: false`, both `:reason` (symbol) and `:because` (human-readable
  string) are present.
- Additive fields are safe; renames or removals are breaking from MM's POV.

### `Semantica::Storable` concern + DSL

```ruby
class Product < ApplicationRecord
  include Semantica::Storable

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
  the SPARQL-visible outcome, not the SQL).
- The Oxigraph version pinned by `sqlite-sparql` (MM tolerates Oxigraph
  bumps as long as the SPARQL semantics MM exercises stay stable — see
  `sqlite-sparql/CONSUMER_REQUIREMENT_MM.md`).
- The shape of `Loader`'s internal connection-pool hooks. MM only depends
  on `ensure_extension_loaded!` being callable + idempotent.
- The class names of internal helpers (e.g., term serializers). MM only
  references the documented public surface.

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
model + `ProductTripler` service — needs the following `Semantica::Storable`
DSL extensions before the cutover is doctrine-pure. Until they land,
MM ships a substrate-side hybrid: simple per-record predicates via
`Storable`; complex emissions via direct `Semantica::Sparql.execute`
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
Semantica::Sparql.select(query, graph: "urn:mm:graph:bhphoto")
Semantica::Sparql.ask(query, graph: "urn:mm:graph:bhphoto")
Semantica::Sparql.construct(query, graph: "urn:mm:graph:bhphoto")
Semantica::Sparql.execute(update, graph: "urn:mm:graph:bhphoto")

# Storable DSL — graph "..." declaration in the triples block
class Product < ApplicationRecord
  include Semantica::Storable

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
- `Storable` lifecycle hooks (`after_save` / `after_destroy`) thread the declared graph through the per-call dispatch path (`:bulk` and `:sparql_update` dispatch modes are post-PLAN_0.5.0; not yet shipped).
- Cross-graph isolation: ops on a graph leave triples for the same subject in other graphs untouched.

New pinned reason symbols (additive on top of v0.1.0): `:invalid_graph`, `:invalid_dsl`.

### 6. Batched-write convenience (`Sparql.bulk_insert`)

Current write surfaces are all per-call: `Sparql.execute("INSERT DATA
{ <s> <p> <o> . }")` for ad-hoc emission; `Storable`'s `after_save`
emits one `SELECT + DELETE + INSERT DATA` round-trip per declared
predicate. For PLAN_0_29_1 Phase B.1's copy migration (one-shot,
thousands of triples) and for `Storable`'s per-save lifecycle hooks
(every Product save re-emits multiple predicates), Rust-side batching
beats per-call work. The substrate would consume:

```ruby
Semantica::Sparql.bulk_insert([
  { s: "urn:mm:product:EPET2850", p: "schema:name",     o: "Epson EcoTank" },
  { s: "urn:mm:product:EPET2850", p: "schema:category", o: "printer" },
  { s: "urn:mm:product:EPET2850", p: "schema:gtin",     o: "01234567890123" },
])
# => { ok: true, inserted: 3 }
# => { ok: false, reason:, because: }

# Or the positional shape:
Semantica::Sparql.bulk_insert([
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
- Symmetric `Semantica::Sparql.bulk_delete(rows)` would be natural; same
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
   `Semantica::Sparql.bulk_insert` in ~1000-row batches.
6. Updates this file: each requested extension graduates from
   "Requested" into "Surfaces MM consumes."

The PLAN_0_29_1 Phase B.2 cutover commit references this section's
commit hash for traceability.

## Contact

For questions about MM's consumption pattern, see MM's
`docs/architecture/Semantica.md` or open an issue on the MM repo.
