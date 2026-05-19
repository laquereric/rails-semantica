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
- Failure mode: raises `Semantica::ExtensionMissing` with a structured
  because-clause naming the expected path + the `cargo build` command.
- Env var the Loader reads: `MM_SQLITE_SPARQL_PATH` (absolute path to
  `libsqlite_sparql.{dylib,so}`). If renamed upstream, MM's
  `config/database.yml` + `QuickStart_Developer.md` must update lockstep.

### `Semantica::Sparql`

Three class methods. **All three return structured envelopes; none raise.**
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
```

Envelope-shape stability MM depends on:

- `:ok` key always present, boolean.
- On `ok: true`, the result payload is in a single named key (`:results` /
  `:value` / `:ntriples`).
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

## Contact

For questions about MM's consumption pattern, see MM's
`docs/architecture/Semantica.md` or open an issue on the MM repo.
