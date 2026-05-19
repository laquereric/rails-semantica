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
# Arbitrary SPARQL UPDATE is post-0.1.0; reach for the scalar
# functions (rdf_insert / rdf_delete / etc.) directly if you need
# more. Storable's lifecycle hooks use the two DATA forms below.
Semantica::Sparql.execute(<<~SPARQL)
  INSERT DATA { <urn:mm:product:EPET2850> <schema:tag> "hot" . }
SPARQL
# => { ok: true, count: 1 }
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

## What's stable at v0.1.0 vs. still mutable

**Pinned at v0.1.0** (renames or removals will earn a CHANGELOG
heading + a coordinated substrate bump):

- `Semantica::Sparql.{select,ask,construct,execute}` method names + envelope shape (additive fields safe).
- `Semantica::Sparql` `:reason` symbols (`:sparql_parse_error`, `:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`).
- `Semantica::Loader.{ensure_extension_loaded!,extension_path,searched_paths}` surface + `ExtensionMissing` class.
- `MM_SQLITE_SPARQL_PATH` env var.
- N-Triples object encoding from `TermSerializer` (String/Integer/Float/Boolean/Time/Date type-dispatch).

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
- [`vendor/sqlite-sparql/README.md`](../sqlite-sparql/README.md) — the
  Rust SQLite extension this gem wraps.
- [`docs/research/Semantica.md`](../../docs/research/Semantica.md) — the
  substrate-side architectural concept the gem implements.
- [`docs/plans/PLAN_0_29_1.md`](../../docs/plans/PLAN_0_29_1.md) — the
  substrate plan that introduces this gem + the substrate's cutover
  to it (Phases E + F live there, not in this gem's PLAN).
