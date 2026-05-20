# rails-semantica

ActiveRecord integration for [sqlite-sparql](../sqlite-sparql/README.md) — RDF triples + SPARQL inside Rails 8.

> **Status: v0.x.x — surface evolves.** This gem ships as a path-sourced
> dependency inside the MagenticMarket monorepo. The substrate is the
> first consumer; the API stays operator-fluid until v1.0. Outside Rails
> apps can consume via a Git source at their own risk.

## What's in the box

Three small layers, each opt-in:

| Layer | Class | Responsibility |
|---|---|---|
| **Loader** | `Semantica::Loader` | Boots the sqlite-sparql extension across AR connection-pool restarts. Idempotent. |
| **Sparql facade** | `Semantica::Sparql` | `select` / `ask` / `construct` returning `{ ok:, results:/value:/ntriples: }` envelopes. Never raises. |
| **Storable concern** | `Semantica::Storable` | Per-model `triples do ... end` DSL. After-save / after-destroy lifecycle hooks emit / retract triples. |

## Prerequisites

This gem assumes the [sqlite-sparql](../sqlite-sparql/README.md) loadable
extension is built + available on disk. The gem ships only the Ruby
integration layer; operators build the `.dylib` / `.so` themselves:

```bash
# From the MagenticMarket repo root:
cd vendor/sqlite-sparql
cargo build --release
# Extension at: target/release/libsqlite_sparql.{dylib,so}
```

Set `MM_SQLITE_SPARQL_PATH` to point at the built extension.

## Quickstart

```ruby
# Gemfile
gem "rails-semantica", path: "vendor/rails-semantica"
```

```bash
rails generate semantica:setup
# Adds `extensions: ["${MM_SQLITE_SPARQL_PATH}"]` to config/database.yml.
# Emits a migration creating the triple-metadata side table (if needed).
```

```ruby
# Per-model opt-in:
class Product < ApplicationRecord
  include Semantica::Storable

  triples do
    subject       -> { "urn:mm:product:#{sku}" }
    triple "schema:name",     -> { name }
    triple "schema:category", -> { category }
    triple "schema:brand",    -> { brand }
    triple "schema:gtin",     -> { gtin }, if: -> { gtin.present? }
  end
end

Product.create!(sku: "EPET2850", name: "Epson EcoTank", category: "printer", brand: "Epson")
# After save: rdf_insert("urn:mm:product:EPET2850", "schema:name", "Epson EcoTank")
# After save: rdf_insert("urn:mm:product:EPET2850", "schema:category", "printer")
# ...

product.destroy
# After destroy: rdf_delete(subject, p, o) for every declared triple
```

### Multi-subject emission — `on_subject` (v0.2.0)

```ruby
class Product < ApplicationRecord
  include Semantica::Storable

  triples do
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }

    on_subject -> { "urn:mm:folder:category:#{category}" } do
      triple "rdf:type", "<urn:mm:CategoryFolder>"
      triple "schema:name", -> { category.titleize }
    end
  end
end
```

Each `on_subject` block emits alongside the primary subject; both
share the same read-replace per (subject, predicate) idempotency.
Literal-string predicate values (`"<urn:…>"`-wrapped) serialize as
IRI objects.

### Collection iteration + multi-value predicates — `each` (v0.2.0)

```ruby
triples do
  subject -> { "urn:mm:product:#{sku}" }

  each -> { product_specs } do |spec|
    triple "mm:#{spec.name.camelize(:lower)}", -> { spec.value }
  end

  # Multi-value via repeated each (same predicate, N values):
  each -> { feature_flags } do |feature|
    triple "mm:hasFeature", -> { feature.code }
  end
end
```

The predicate IRI may interpolate per-item state. Read-replace
adjusts: every triple matching (subject, predicate) for every
predicate the block emits this save is retracted before insert.
Empty collection this save → no retraction → stale triples from a
prior non-empty save persist; pair with explicit
`Sparql.execute("DELETE WHERE { <s> <p> ?o }")` if strict cleanup is
required.

### JSON / structured-literal object types (v0.2.0)

```ruby
triples do
  subject -> { "urn:mm:product:#{sku}" }
  triple "schema:offers", -> { { price: price_cents/100.0, currency: "USD" } }
end
```

`Hash` and `Array` values JSON-encode via `JSON.generate` and emit
as typed literals with `xsd:string` datatype. Read back via
`Sparql.select` + `JSON.parse` on the literal value.

### Named graphs — `graph "…"` DSL + `graph:` kwarg (v0.5.0)

```ruby
class Product < ApplicationRecord
  include Semantica::Storable

  triples do
    graph "urn:mm:graph:bhphoto"
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }
    # on_subject + each blocks inherit the outer graph
  end
end

Semantica::Sparql.select("SELECT ?s WHERE { ?s ?p ?o }", graph: "urn:mm:graph:bhphoto")
Semantica::Sparql.execute("INSERT DATA { … }",            graph: "urn:mm:graph:bhphoto")
```

All three dispatch modes (`:sparql_update` / `:bulk` / `:per_call`)
produce equivalent end states for a graph-scoped model. Cross-graph
isolation: operations on `urn:mm:graph:bhphoto` leave triples for
the same subject in other graphs (including the default graph)
untouched. Blank-node graph IRIs refuse at the gem boundary with
`:invalid_graph`. `execute("CLEAR ALL"/"CLEAR DEFAULT", graph: …)`
refuses with `:invalid_dsl` (ambiguous scoping; use
`execute("CLEAR GRAPH <urn:…>")`).

```ruby
# SPARQL queries (structured envelopes; never raise):
Semantica::Sparql.select(<<~SPARQL)
  SELECT ?p WHERE { ?p <schema:category> "printer" }
SPARQL
# => { ok: true, results: [{ "p" => "urn:mm:product:EPET2850" }, ...] }

Semantica::Sparql.ask('ASK { ?p <schema:gtin> "01234567890123" }')
# => { ok: true, value: true }

Semantica::Sparql.construct(<<~SPARQL)
  CONSTRUCT { ?p <derived:hot> true }
  WHERE     { ?p <schema:category> "printer" }
SPARQL
# => { ok: true, ntriples: "<urn:mm:product:EPET2850> <derived:hot> true .\n..." }

# Write surface — INSERT DATA / DELETE DATA / CLEAR ALL fast paths.
# v0.2.0 added `DELETE WHERE { <s> <p> ?o }` as a public form.
# v0.3.0 unlocks arbitrary SPARQL 1.1 UPDATE via the engine's
# `sparql_update` scalar (signed net delta as `:count:`).
Semantica::Sparql.execute(<<~SPARQL)
  INSERT DATA { <urn:mm:product:EPET2850> <schema:tag> "hot" . }
SPARQL
# => { ok: true, count: 1 }  (DATA-form fast path; always positive)

Semantica::Sparql.execute(<<~SPARQL)
  DELETE WHERE { <urn:mm:product:EPET2850> <schema:tag> ?o }
SPARQL
# => { ok: true, count: <integer> }  (v0.2.0 fast path)

Semantica::Sparql.execute(<<~SPARQL)
  DELETE { ?s <schema:tag> "stale" }
  INSERT { ?s <schema:tag> "fresh" }
  WHERE  { ?s <schema:tag> "stale" }
SPARQL
# => { ok: true, count: 0 }  (signed net delta: -N delete + N insert)

# Bulk write — single FFI crossing per batch (v0.4.0).
Semantica::Sparql.bulk_insert([
  { s: "urn:mm:product:EPET2850", p: "schema:name",     o: "Epson EcoTank" },
  { s: "urn:mm:product:EPET2850", p: "schema:category", o: "printer" },
  ["urn:mm:product:EPET2851", "schema:name", "HP DeskJet", "urn:mm:graph:bhphoto"],
])
# => { ok: true, inserted: 3 }
# Abort-batch-on-error: any malformed row refuses the whole batch
# (store unchanged); refusal envelope's :because: carries `row <N>:`.

Semantica::Sparql.bulk_delete(rows)
# => { ok: true, deleted: <integer> }
```

Failure envelopes carry a verbatim because-clause:

```ruby
Semantica::Sparql.select("SELEC bogus") # malformed
# => { ok: false, reason: :sparql_parse_error, because: "..." }
```

Pinned `:reason` symbols (v0.1.0): `:sparql_parse_error`,
`:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`.
v0.3.0 adds `:sparql_eval_error` (semantically-invalid UPDATE — the
engine surfaces `"SPARQL evaluation error:"`). v0.5.0 adds
`:invalid_graph` (blank-node graph IRIs) and `:invalid_dsl`
(ambiguous DSL — e.g. `execute("CLEAR ALL", graph: …)`).

## Concurrency

Engine ≥ 0.2.0 holds one Oxigraph store per process, shared across
every SQLite connection on every thread. Writes from one connection
are visible from any other connection in the same process (pinned
by `spec/semantica/cross_connection_visibility_spec.rb`).

The three `Storable.dispatch_mode` rungs differ in their atomicity
under concurrent writes to the same `(subject, predicate)`:

- **`:sparql_update`** — issues a single `DELETE/INSERT WHERE` per
  predicate. The engine's Oxigraph store handles the
  delete-then-insert atomically within one engine call. Recommended
  for apps doing concurrent writes to overlapping data.
- **`:bulk`** — the lifecycle hook's SELECT-then-bulk-delete-then-
  bulk-insert is not atomic across threads. Races possible.
- **`:per_call`** — the SELECT-then-DELETE-then-INSERT pattern is
  not atomic across threads. Races possible.

Operators with concurrent writes pin via
`MM_SEMANTICA_DISPATCH_MODE=sparql_update`. Single-threaded apps
(the common Rails request-per-thread case) see no behavioural
difference between the modes.

Test isolation under shared store requires `rdf_clear` between
examples; parallel test workers (e.g. `rspec-parallel`) will
clobber each other's stores. Run gem-consuming specs serially.

## Why opt-in?

Rails apps that don't add this gem keep their existing ActiveRecord
queries unchanged. Apps that DO add this gem can mix — SPARQL for graph
traversal, AR for relational lookups, in the same model.

The gem's surface follows MagenticMarket's structured-envelope
discipline: every refusal carries `{ ok: false, reason:, because: }`
verbatim because-clauses (Architect's-No #18). Operators branch on
`result[:ok]` rather than rescuing.

## What's stable vs. still mutable

**Pinned at v0.1.0** (renames or removals will earn a CHANGELOG
heading + a coordinated substrate bump):

- `Semantica::Sparql.{select,ask,construct,execute}` method names + envelope shape (additive fields safe).
- `Semantica::Sparql` `:reason` symbols (`:sparql_parse_error`, `:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`).
- `Semantica::Loader.{ensure_extension_loaded!,extension_path,searched_paths}` surface + `ExtensionMissing` class.
- `MM_SQLITE_SPARQL_PATH` env var.
- N-Triples object encoding from `TermSerializer` (String/Integer/Float/Boolean/Time/Date type-dispatch).

**Pinned at v0.2.0** (additive on top of v0.1.0):

- `triples do; on_subject(lambda) do; … end; end` DSL block.
- `triples do; each(collection_lambda) do |item|; triple "pred", ->{...}; end; end` DSL block; predicate may be String or lambda.
- `triple "pred", "<urn:literal-iri>"` literal-string second arg.
- `TermSerializer.object(Hash | Array)` → JSON-encoded `xsd:string` literal.
- `Semantica::Sparql.execute("DELETE WHERE { <s> <p> ?o }")` envelope `{ ok:, count: }`.

**Pinned at v0.3.0** (additive on top of v0.2.0):

- `Semantica::Sparql.execute(arbitrary_sparql_update)` envelope `{ ok:, count: <signed integer> }`. The four fast paths still return positive counts; the widening from unsigned to signed only affects the arbitrary-UPDATE fallback.
- `Semantica::Sparql` `:reason` symbol `:sparql_eval_error`.
- `Semantica::Storable.dispatch_mode` reader → `:sparql_update | :bulk | :per_call`. One-shot probe; cached process-wide; reset via `dispatch_mode_reset!`.
- `MM_SEMANTICA_DISPATCH_MODE` env var forces a mode for predictable behaviour across upgrades (lifetime ≥ v1.0).

**Pinned at v0.4.0** (additive on top of v0.3.0):

- `Semantica::Sparql.bulk_insert(rows)` → `{ ok:, inserted: <integer> }`. `:inserted:` reflects engine set semantics (dedup-aware).
- `Semantica::Sparql.bulk_delete(rows)` → `{ ok:, deleted: <integer> }`.
- Row shapes: `Array<Hash{s:, p:, o:, graph:?}>` and `Array<Array>` 3/4-tuple — equivalent.
- Abort-batch-on-error semantics: any malformed row refuses the whole batch; `:because:` carries `"row <N>: …"`.
- `Storable.dispatch_mode == :bulk` lights up: 1 `bulk_delete` + 1 `bulk_insert` per save regardless of declared-predicate count.

**Pinned at v0.5.0** (additive on top of v0.4.0):

- `Semantica::Sparql.{select,ask,construct,execute}(query, graph: nil_or_iri_string)` optional kwarg. `nil` (or omitted) = default graph; String = named graph.
- `triples do; graph "<iri>"; … end` DSL declaration. One graph per declaration; `on_subject` + `each` blocks inherit. Captured at recording time.
- `Storable.dispatch_mode` graph-equivalence: all three modes produce identical end states for a graph-scoped model.
- `Semantica::Sparql` `:reason` symbols `:invalid_graph` (blank-node graph IRIs) + `:invalid_dsl` (ambiguous `CLEAR` + `graph:`).

**Pinned at v0.6.0** (additive on top of v0.5.0):

- `Semantica::Sparql.store_size(graph: …)` → `{ ok:, count: <integer> }`. Omitted graph = `rdf_count_all` (every graph); explicit `nil` = default-graph only; String = named-graph.
- `Semantica::Loader.engine_version` reader → `String` or `Semantica::Loader::ENGINE_VERSION_UNKNOWN` (`:unknown`). Shape pinned; underlying probe grows when the engine ships `rdf_version()`.
- Cross-connection visibility property: a write from connection A is visible from connection B (same process), across threads, across named-graph scopes. Pinned by spec.
- `Storable.dispatch_mode` concurrency contract: `:sparql_update` is atomic per predicate; `:bulk` and `:per_call` race under concurrent writes to the same `(subject, predicate)`. See `## Concurrency`.

**Still operator-fluid** (may change without deprecation cycle
during v0.x.x):

- The `triples do ... end` DSL helper set — new helpers (e.g.
  `triples_from:`) may appear; `subject` / `triple` / `if:` stay.
- `MM_SEMANTICA_SOFT_FAIL` (interim-window boot escape) — removed
  when the substrate's Phase E cutover lands.
- The relative ordering of `OntologyResolver` cascade tiers when
  consumed by the substrate.

When the substrate's consumption settles, the operator-fluid list
empties + the v1.0 contract is published.

## License

MIT OR Apache-2.0 at the operator's option. See `LICENSE-MIT` and `LICENSE-APACHE`.

## Pre-release check

```bash
cd vendor/sqlite-sparql && cargo build --release
cd ../rails-semantica && bin/check
```

`bin/check` locates the engine artifact (or warns + continues) and
runs `bundle exec rspec`. Contract specs run unconditionally;
round-trip specs skip with a build hint when the `.dylib` / `.so`
isn't on disk.

## Cross-references

- [`docs/plans/PLAN_0.1.0.md`](docs/plans/PLAN_0.1.0.md) — this gem's
  own roadmap to a shippable 0.1.0.
- [`docs/plans/PLAN_0.2.0.md`](docs/plans/PLAN_0.2.0.md) — the v0.2.0
  DSL extensions (multi-subject, each blocks, JSON literals).
- [`docs/plans/PLAN_0.3.0.md`](docs/plans/PLAN_0.3.0.md) — the v0.3.0
  arbitrary-UPDATE pass-through + dispatch-mode ladder.
- [`docs/plans/PLAN_0.4.0.md`](docs/plans/PLAN_0.4.0.md) — the v0.4.0
  bulk-write surface + `:bulk` dispatch implementation.
- [`docs/plans/PLAN_0.5.0.md`](docs/plans/PLAN_0.5.0.md) — the v0.5.0
  named-graph support (`graph:` kwarg + `graph "…"` DSL).
- [`docs/plans/PLAN_0.6.0.md`](docs/plans/PLAN_0.6.0.md) — the v0.6.0
  shared-store posture (`store_size` helper, `engine_version` reader,
  cross-connection visibility, concurrency note).
- [`vendor/sqlite-sparql/README.md`](../sqlite-sparql/README.md) — the
  Rust SQLite extension this gem wraps.
- [`docs/research/Semantica.md`](../../docs/research/Semantica.md) — the
  substrate-side architectural concept the gem implements.
- [`docs/plans/PLAN_0_29_1.md`](../../docs/plans/PLAN_0_29_1.md) — the
  substrate plan that introduces this gem + the substrate's cutover
  to it (Phases E + F live there, not in this gem's PLAN).
