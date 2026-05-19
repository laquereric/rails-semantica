# PLAN_0.1.0 — `rails-semantica` first shippable release

> *Drives the gem from its current "Phase A + B landed" state to a
> 0.1.0 that the substrate (its first consumer) and rails-semantica's
> own spec suite both treat as load-bearing. Surface stays
> operator-fluid until v1.0 — v0.1.0 is the first version stable
> enough to call from production code without a parallel legacy
> path.*

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `vendor/sqlite-sparql/` (sibling) | `../sqlite-sparql/` | The Oxigraph-via-`sqlite-loadable-rs` SQLite extension this gem wraps. The `.dylib`/`.so`/`.dll` artifact at `target/release/` is the prerequisite the Loader resolves. v0.1.0 of *this* gem assumes the operator runs `cargo build --release` themselves; no auto-build, no bundled binary. |
| `docs/plans/PLAN_0_29_1.md` (substrate) | `../../docs/plans/PLAN_0_29_1.md` | The substrate's plan for extracting + adopting this gem. Phases B (Loader), E (substrate cutover), F (OntologyResolver Tier 0) all originate there. v0.1.0 of this gem closes the Ruby-side surface that plan needs. |
| `docs/research/Semantica.md` (substrate) | `../../docs/research/Semantica.md` | Architectural concept. Why three layers (Loader / Sparql / Storable) and not one. |
| `CHANGELOG.md` (this repo) | `./CHANGELOG.md` | Records Phase A + B as landed for `0.1.0 — unreleased`. PLAN_0.1.0 drives the remaining phases. |

## Current state (2026-05-19)

Landed:

- **Phase A — gem skeleton.** Bundler layout under `vendor/rails-semantica/`. `Semantica::VERSION = "0.1.0"`. Empty stubs for Loader / Sparql / Storable / Railtie. Spec scaffold. Substrate `Gemfile` adds the gem via path source.
- **Phase B — `Semantica::Loader`.** `ensure_extension_loaded!` walks `ActiveRecord::Base.connection`, probes via `SELECT rdf_count()`, calls `raw_connection.load_extension(path)`. `ExtensionMissing` raises with the verbatim `cd vendor/sqlite-sparql && cargo build --release` instructions and the `MM_SQLITE_SPARQL_PATH` override. Railtie hooks into `config.after_initialize`. Soft-fail via `MM_SEMANTICA_SOFT_FAIL=1` exists for the interim window; removed at Phase E cutover.
- **Phase C — `Semantica::Sparql` facade.** Four class methods (`select` / `ask` / `construct` / `execute`) returning structured envelopes; never raise. Reason symbols pinned. Belt-and-braces `Loader.ensure_extension_loaded!` per call. `execute` supports `INSERT DATA` / `DELETE DATA` / `CLEAR ALL`; arbitrary SPARQL UPDATE is post-0.1.0.
- **Phase D — `Semantica::Storable` concern + DSL.** `triples do ... end` block declares subject + predicates; `after_save` does read-replace per predicate (no stale values on update); `after_destroy` retracts everything declared. `TermSerializer` type-dispatches String/Integer/Float/Boolean/Time/Date to N-Triples literals; `"<...>"`-wrapped strings pass through as IRI objects. Strict mode via `MM_SEMANTICA_STRICT=1`; default is lenient.

Remaining for v0.1.0:

- **Phase G — extension-environment lifecycle for specs.** ✅ landed alongside C (`spec/support/extension_environment.rb`) and rounded out with `bin/check` — single operator-run pre-release script that locates the engine artifact + runs `bundle exec rspec`.
- **Phase H — docs accuracy.** ✅ README pinned the v0.1.0 surface, added the `execute` write path, listed the `:reason` symbol set, separated pinned-vs-fluid in the contract section, and cross-referenced `bin/check` + this PLAN.

At this point the gem is ready to be tagged `0.1.0` once the
substrate's Phase E cutover lands and the round-trip specs run
green against a freshly-built `sqlite-sparql` artifact.

## Out of scope for this plan

These are downstream of v0.1.0 — they consume the gem rather than
ship inside it, and they are tracked in the **substrate's**
plan tree, not the gem's:

- **Substrate cutover** (delete `Triple` AR model + `ProductTripler`; rewire `Product` to `include Semantica::Storable`; data migration). Tracked as Phase E of substrate `PLAN_0_29_1`.
- **OntologyResolver Tier 0 wiring** (graph-traversal cascade tier). Tracked as Phase F of substrate `PLAN_0_29_1`.
- **`sqlite-sparql` extension's own build readiness** (resolving `sqlite-loadable 0.0.5` API drift, getting `cargo test` green). Lives in `vendor/sqlite-sparql/`; this gem's specs assume that artifact exists and exit-codes early if it doesn't. If `cargo build --release` is currently broken, fix it under the sibling repo's own roadmap — not here.
- **Publishing to rubygems.org.** Stays path-sourced under `vendor/rails-semantica/` for the entire v0.x.x line.

## Phase C — `Semantica::Sparql` facade

Three class methods, all returning structured envelopes; **never raises**. Refusal envelopes carry verbatim because-clauses (substrate Architect's-No #18 inheritance).

```ruby
Semantica::Sparql.select(query)
# success → { ok: true,  results: [{ "var" => "value", ... }, ...] }
# failure → { ok: false, reason: <symbol>, because: <verbatim engine message> }

Semantica::Sparql.ask(query)
# success → { ok: true,  value: true|false }
# failure → { ok: false, reason: <symbol>, because: <verbatim engine message> }

Semantica::Sparql.construct(query)
# success → { ok: true,  ntriples: "<s> <p> <o> .\n..." }
# failure → { ok: false, reason: <symbol>, because: <verbatim engine message> }
```

### Implementation

- Call into the extension via `ActiveRecord::Base.connection.select_value("SELECT sparql_query(?)", nil, [[nil, query]])` for SELECT (already sketched in sqlite-sparql/CLAUDE.md), `sparql_ask`, `sparql_construct` for the other two.
- Parse SELECT's JSON-array result with `JSON.parse`; treat blank/null as `[]`.
- ASK returns `0`/`1` — coerce to `true`/`false`.
- CONSTRUCT returns N-Triples text — passthrough verbatim into the envelope.
- Wrap every call in a tight `rescue StandardError => e` that maps:
  - SPARQL parse errors → `reason: :sparql_parse_error`
  - SQLite "no such function" (extension not loaded) → `reason: :extension_not_loaded`
  - Connection errors → `reason: :ar_connection_error`
  - Anything else → `reason: :unexpected_error`, `because: e.message`
- Lazy-call `Semantica::Loader.ensure_extension_loaded!` at the top of each facade method as a belt-and-braces guard (the Railtie already did it at boot; this re-arms after connection-pool churn or in non-Railtie hosts).

### Exit criteria

- `spec/semantica/sparql_spec.rb` round-trips a fixture set of triples through all three methods + the JSON envelope shape pins.
- Refusal cases asserted: malformed SPARQL, extension absent, AR connection nil.
- No `raise` in production paths — verified by an `expect { ... }.not_to raise_error` in the failure-mode specs.

## Phase D — `Semantica::Storable` concern + DSL

Per-model triple-emission DSL. ActiveRecord concern; opt-in via
`include Semantica::Storable`.

```ruby
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
```

### Implementation

- `triples do ... end` evaluates its block against an internal DSL recorder that captures `subject` (one lambda) and `triple` (an ordered list of `[predicate, value_lambda, opts]`).
- The recorded declaration is stored on the class (`class_attribute :semantica_triples_declaration` or similar).
- Lifecycle hooks installed by `included do`:
  - `after_save :semantica_emit_triples!` — evaluates `subject` on the instance, then for each declared triple: skips if `if:` lambda returns falsy, else evaluates the value lambda and calls `Semantica::Sparql.execute(<<~SPARQL) INSERT DATA { ... } SPARQL`. (Add `Semantica::Sparql.execute` for UPDATE-style operations alongside the SELECT/ASK/CONSTRUCT trio. It's the one piece of write surface needed for the DSL; gate it behind the same envelope discipline.)
  - `after_destroy :semantica_retract_triples!` — same shape, `DELETE DATA { ... }`.
- N-Triples term serialization helpers (literal escaping, IRI bracketing, blank-node prefixing) live in `Semantica::Storable::TermSerializer` so the DSL stays terse + the serialization is testable in isolation.
- Idempotency: `after_save` runs on both create and update. Re-emitting an identical triple is a no-op at the Oxigraph level (set semantics). Updates that change a value retract-then-insert? **No** — Oxigraph's INSERT DATA is non-replacing; we'd accumulate stale triples on updates. v0.1.0's contract: `after_save` issues a `DELETE { ?s <p> ?o }` per declared predicate then `INSERT DATA { <s> <p> "new" }`. Document the read-replace cost in the spec and the README.

### Exit criteria

- `spec/semantica/storable_spec.rb` covers: declarative recording (no AR needed), create → triples appear, update → triples replaced, destroy → triples retracted, conditional `if:` lambdas honored, term serialization edge cases (literals with quotes, IRIs with reserved chars, nil values skipped).
- `Semantica::Sparql.execute` joins the facade with the same envelope shape (refused gracefully on parse/extension errors).

## Phase G — Specs + audits

Beyond the per-module specs above, the gem ships:

- `spec/spec_helper.rb` — boots a minimal sqlite3 in-memory connection, loads the extension via `Semantica::Loader.ensure_extension_loaded!`, skips the suite with a clear message if the extension isn't built (don't fail-the-build for missing prerequisite; explicitly skip with a one-line `cargo build --release` hint).
- `spec/semantica/loader_spec.rb` — already scaffolded in Phase B; flesh out: idempotent re-load, `ExtensionMissing` message contains the build command verbatim, `MM_SQLITE_SPARQL_PATH` override respected, all three platform paths probed in `searched_paths`.
- `spec/semantica/sparql_spec.rb` — Phase C exit criteria.
- `spec/semantica/storable_spec.rb` — Phase D exit criteria.
- `spec/integration/round_trip_spec.rb` — single end-to-end: define a throwaway AR model with `include Semantica::Storable`, create an instance, query via `Semantica::Sparql.select`, retract via destroy, assert the triples are gone.

### CI / pre-release check

A `bin/check` shell script that:

1. Asserts `../sqlite-sparql/target/release/libsqlite_sparql.dylib` (or `.so`) exists.
2. Runs `bundle exec rspec`.
3. Reports green/red.

Not a CI pipeline (gem is path-vendored, no remote CI yet) — a single
script the operator runs before bumping the version.

## Phase H — Docs accuracy at 0.1.0

- **README.md** — already largely correct (matches the intended surface). Remove the `0.x.x — surface evolves` qualifier from the *function signatures* (`select` / `ask` / `construct` / `execute` envelopes are pinned at 0.1.0); keep it on the `triples do ... end` DSL since the helper set may grow.
- **CHANGELOG.md** — append a `0.1.0 — <date>` heading at release time naming Phases C / D / G / H. Drop the `(unreleased)` qualifier from the existing entry.
- **`docs/plans/PLAN_0.1.0.md`** — this file. Update its "Current state" section as phases land.
- **`docs/plans/`** — directory established by this plan. Future per-version PLANs (PLAN_0.2.0 covering named graphs once `sqlite-sparql` exposes them; PLAN_1.0.0 covering RubyGems publication + semver pin) live here. Substrate plan tree (`../../docs/plans/`) stays substrate-owned; cross-references go both ways.

## v0.1.0 surface contract (frozen at end of Phase H)

| Surface | Shape | Mutability |
|---|---|---|
| `Semantica::Loader.ensure_extension_loaded!` | `() → :loaded | :already_loaded | :no_active_record` | **Pinned.** |
| `Semantica::Loader.extension_path` | `() → String | nil` | **Pinned.** |
| `Semantica::Loader.searched_paths` | `() → Array<String>` | **Pinned.** |
| `Semantica::Loader::ExtensionMissing` | exception class with `searched_paths` reader | **Pinned.** |
| `Semantica::Sparql.select(q)` | envelope `{ ok:, results: } / { ok: false, reason:, because: }` | **Pinned shape.** Additive fields allowed. |
| `Semantica::Sparql.ask(q)` | envelope `{ ok:, value: } / { ok: false, reason:, because: }` | **Pinned shape.** |
| `Semantica::Sparql.construct(q)` | envelope `{ ok:, ntriples: } / { ok: false, reason:, because: }` | **Pinned shape.** |
| `Semantica::Sparql.execute(q)` | envelope `{ ok:, count: } / { ok: false, reason:, because: }` | **Pinned shape.** New in 0.1.0 (added during Phase D). |
| `Semantica::Storable.triples { ... }` | DSL with `subject`, `triple`, `if:` | **Operator-fluid** until v1.0 — helper set may grow (e.g. `triples_from:` for derived sets). |
| `MM_SQLITE_SPARQL_PATH` env var | path override | **Pinned.** |
| `MM_SEMANTICA_SOFT_FAIL` env var | `"1"` → log + continue | **Pinned**, but **expected lifetime = until substrate Phase E lands.** Document in CHANGELOG when removed. |

Refusal `reason:` symbols are part of the contract: `:sparql_parse_error`, `:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`. New reasons may be added; existing ones stay.

## Risks

| Risk | Mitigation |
|---|---|
| `vendor/sqlite-sparql/` doesn't currently produce a `target/release/` artifact (only `target/debug/` exists). | Phase G's `spec_helper.rb` skips the suite with a clear `cd vendor/sqlite-sparql && cargo build --release` hint rather than failing. Substrate boot under `MM_SEMANTICA_SOFT_FAIL=1` works without the artifact during interim. The `sqlite-loadable 0.0.5` API drift inside sqlite-sparql is **not** this plan's problem — escalate to whoever owns the sibling repo if blocked. |
| Phase D's read-replace pattern (DELETE+INSERT on every save) doubles write cost for unchanged records. | v0.1.0 ships the correct-but-slow path. A "dirty-tracking" optimization (only re-emit predicates whose value lambdas would produce different output) is post-0.1.0; doesn't block. |
| `Semantica::Sparql` envelope shape diverges from `Mm::Tool` envelopes once the substrate adopts it (Phase E in substrate's plan). | Keep this gem's envelopes minimal + stable; if substrate needs more fields, adapt in the substrate's adapter, not by mutating the gem's envelope. |
| Connection-pool churn under Rails 8 high-load leaves some connections without the extension loaded. | Phase C's belt-and-braces `ensure_extension_loaded!` at every facade call covers this. Cost is one cheap sentinel `SELECT rdf_count()` per call; acceptable for v0.1.0. |

## Cross-references

- `../../../docs/plans/PLAN_0_29_1.md` — substrate's extraction-and-adoption plan. Phase E (substrate cutover) + Phase F (OntologyResolver Tier 0) are tracked there, not here.
- `../../../docs/research/Semantica.md` — architectural rationale.
- `../sqlite-sparql/README.md` — engine surface this gem wraps.
- `../sqlite-sparql/CLAUDE.md` — engine design decisions; the "Completing the Implementation" list there is the engine's roadmap, not this gem's.
- `../../CHANGELOG.md` — per-version landed-work record.
