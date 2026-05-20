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

# Write surface — INSERT DATA / DELETE DATA / CLEAR ALL.
# v0.2.0 also recognises `DELETE WHERE { <s> <p> ?o }` as a public
# form (read-replace by predicate). Arbitrary SPARQL UPDATE remains
# post-v0.2.0; reach for the scalar functions (rdf_insert /
# rdf_delete / etc.) directly if you need more.
Semantica::Sparql.execute(<<~SPARQL)
  INSERT DATA { <urn:mm:product:EPET2850> <schema:tag> "hot" . }
SPARQL
# => { ok: true, count: 1 }

Semantica::Sparql.execute(<<~SPARQL)
  DELETE WHERE { <urn:mm:product:EPET2850> <schema:tag> ?o }
SPARQL
# => { ok: true, count: <integer> }
```

Failure envelopes carry a verbatim because-clause:

```ruby
Semantica::Sparql.select("SELEC bogus") # malformed
# => { ok: false, reason: :sparql_parse_error, because: "..." }
```

Pinned `:reason` symbols (v0.1.0 contract):
`:sparql_parse_error`, `:extension_not_loaded`,
`:ar_connection_error`, `:unexpected_error`.

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
- [`vendor/sqlite-sparql/README.md`](../sqlite-sparql/README.md) — the
  Rust SQLite extension this gem wraps.
- [`docs/research/Semantica.md`](../../docs/research/Semantica.md) — the
  substrate-side architectural concept the gem implements.
- [`docs/plans/PLAN_0_29_1.md`](../../docs/plans/PLAN_0_29_1.md) — the
  substrate plan that introduces this gem + the substrate's cutover
  to it (Phases E + F live there, not in this gem's PLAN).
