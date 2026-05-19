# Changelog

## 0.1.0 — 2026-05-19 (unreleased)

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
