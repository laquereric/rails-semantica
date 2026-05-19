# Changelog

## 0.1.0 — 2026-05-19 (unreleased)

PLAN_0.1.0 Phase G + H — pre-release check + docs accuracy.

- `bin/check` — single operator-run pre-release script. Locates the
  sqlite-sparql release artifact (`MM_SQLITE_SPARQL_PATH` first,
  then the three platform candidates under
  `../sqlite-sparql/target/release/`); warns + continues if absent
  (contract specs still run, round-trip specs skip). Then runs
  `bundle exec rspec` and reports green / red.
- `README.md` — added the `Semantica::Sparql.execute` write surface,
  listed the four `:reason` symbols verbatim, separated the v0.1.0
  pinned surface from what's still operator-fluid, added a
  Pre-release check section pointing at `bin/check`, and
  cross-referenced this gem's `docs/plans/PLAN_0.1.0.md`.

PLAN_0.1.0 Phase D — Semantica::Storable concern + DSL.

- `Semantica::Storable` is an `ActiveSupport::Concern`; per-model
  `include Semantica::Storable` + `triples do ... end` declares
  the subject lambda + ordered predicate emissions.
- DSL surface: `subject -> { ... }` (or `subject { ... }` block),
  `triple "<pred>", -> { value }`, `triple "<pred>", -> { value }, if: -> { guard }`.
- Lifecycle: `after_save` emits via read-replace per predicate
  (SELECT current → DELETE DATA each → INSERT DATA new). This
  prevents stale values accumulating across updates. Re-saving an
  unchanged record is a no-op at the store level (Oxigraph set
  semantics) but still costs SELECT + DELETE + INSERT per
  predicate; dirty-tracking optimisation is post-0.1.0.
- Lifecycle: `after_destroy` retracts every declared predicate
  (DELETE DATA for the subject across all declared predicates).
- Nil value handling: a value lambda returning `nil` retracts the
  predicate rather than emitting an empty literal.
- `Semantica::Storable::TermSerializer` — N-Triples serialization
  for `iri` / `predicate` / `object`. Type-dispatch: String →
  literal (quotes escaped), Integer → `xsd:integer`, Float →
  `xsd:double`, Boolean → `xsd:boolean`, Time/DateTime →
  `xsd:dateTime`, Date → `xsd:date`. Operator escape hatch: pass
  `"<...>"`-wrapped strings to emit IRI objects.
- Strict mode: `MM_SEMANTICA_STRICT=1` re-raises any refusal
  envelope from `Semantica::Sparql` during emission as
  `RuntimeError`. Default is lenient (swallow + continue), matching
  the substrate's interim-window discipline.
- `spec/semantica/storable_spec.rb` covers: TermSerializer
  type-dispatch + escaping, Recorder capture + validation
  (subject required), lifecycle (create / update / destroy / nil →
  retract / `if:` guards), under `:requires_extension`.

PLAN_0.1.0 Phase C — Semantica::Sparql facade.

- Four class methods, all returning structured envelopes; **never
  raises**:
  - `Semantica::Sparql.select(query)` → `{ ok:, results: [{...}] }`
  - `Semantica::Sparql.ask(query)`    → `{ ok:, value: bool }`
  - `Semantica::Sparql.construct(q)`  → `{ ok:, ntriples: "..." }`
  - `Semantica::Sparql.execute(q)`    → `{ ok:, count: int }`
    (covers `INSERT DATA` / `DELETE DATA` / `CLEAR ALL`; arbitrary
    SPARQL UPDATE is post-0.1.0.)
- Refusal reason symbols pinned: `:sparql_parse_error`,
  `:extension_not_loaded`, `:ar_connection_error`,
  `:unexpected_error`. Every refusal carries a verbatim
  because-clause (substrate Architect's-No #18 inheritance).
- Each facade method belt-and-braces-calls
  `Semantica::Loader.ensure_extension_loaded!` to cover
  connection-pool churn and non-Railtie hosts.
- `spec/support/extension_environment.rb` boots ActiveRecord +
  sqlite3, loads the extension, and tracks availability. Specs
  tagged `:requires_extension` round-trip real SPARQL; the suite
  skips them with the verbatim `cargo build --release` hint when
  the `.dylib` / `.so` isn't on disk rather than failing the build.

PLAN_0_29_1 Phase B — Semantica::Loader implementation.

- `Semantica::Loader.ensure_extension_loaded!` walks
  `ActiveRecord::Base.connection` + loads sqlite-sparql via
  `raw_connection.load_extension`. Idempotent: probes a sentinel
  query (`SELECT rdf_count()`) to decide skip-vs-load.
- `Semantica::Loader::ExtensionMissing` raised with a structured
  message naming the searched paths + the verbatim
  `cd vendor/sqlite-sparql && cargo build --release` command + the
  `MM_SQLITE_SPARQL_PATH` override.
- `Semantica::Loader.searched_paths` returns the three platform
  candidates (macOS .dylib, Linux .so, Windows .dll) as absolute
  paths anchored at the substrate repo root.
- Railtie's `config.after_initialize` calls the loader; substrate
  boot hard-fails by default when the extension is missing.
- Opt-out: `MM_SEMANTICA_SOFT_FAIL=1` logs a warning + continues.
  Used by the substrate during the Phase B → Phase E interim
  window; removed when Phase E lands the cutover (substrate
  genuinely requires the extension from that point on).

PLAN_0_29_1 Phase A — gem skeleton.

- `vendor/rails-semantica/` Bundler layout established.
- `Semantica::VERSION` = `"0.1.0"`.
- Empty class stubs for `Semantica::Loader`, `Semantica::Sparql`,
  `Semantica::Storable`, and the Railtie.
- Spec scaffold in place (`spec/spec_helper.rb` + per-module stubs).
- MagenticMarket substrate `Gemfile` adds the gem via path source
  (`gem 'rails-semantica', path: 'vendor/rails-semantica'`).

Phases B → H implement the loader, Sparql facade, Storable DSL,
substrate cutover, OntologyResolver Tier 0 wiring, audits, docs.
v1.0 ships when the substrate's consumption settles + the surface
stabilises enough to invite outside Rails consumers + publication
to RubyGems.
