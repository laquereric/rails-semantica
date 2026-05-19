# Changelog

## 0.1.0 — 2026-05-19 (unreleased)

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
