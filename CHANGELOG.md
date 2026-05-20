# Changelog

## 0.3.0 — (unreleased)

PLAN_0.3.0 Phase B + C — `Storable.dispatch_mode` ladder.

- `Semantica::Storable.dispatch_mode` reader returns one of
  `:sparql_update` (engine ≥ 0.5.0), `:bulk` (engine ≥ 0.4.0, no
  `sparql_update`; the actual `:bulk` implementation ships in
  PLAN_0.4.0 — until then this rung falls through to `:per_call`),
  or `:per_call` (v0.2.0 baseline). The detection runs once on
  first call + caches; specs reset via `dispatch_mode_reset!`.
- `MM_SEMANTICA_DISPATCH_MODE` env var forces a specific mode for
  predictable behaviour across upgrades. Pinned as a long-lived
  contract (lifetime ≥ v1.0).
- `replace_predicate!` + `retract_predicate!` route through the
  ladder. The `:sparql_update` path collapses each predicate
  replacement from `2 + N` round-trips to a single
  `DELETE/INSERT WHERE` query. Multi-value (from `each` blocks)
  packs all new values into one INSERT clause; set semantics dedup
  the WHERE-induced repetition. Empty-collection retract uses
  `DELETE { … } WHERE { … }` (no OPTIONAL).
- `each`-block emission refactored to route every predicate-iri
  group through `replace_predicate_set!`; the dispatch ladder
  applies uniformly to single- and multi-value writes.
- 19 new specs (105 total): module-surface contract, env var
  override, cache invalidation, engine probe, round-trip parity
  across `:sparql_update` and `:per_call` for create/update/
  destroy/nil, multi-value collapse, and round-trip-count smoke
  comparing the two modes.

PLAN_0.3.0 Phase A — `Sparql.execute` arbitrary SPARQL UPDATE pass-through.

- `Sparql.execute` `else` branch now routes any UPDATE form that
  doesn't match the four fast paths (INSERT DATA / DELETE DATA /
  DELETE WHERE { <s> <p> ?o } / CLEAR ALL) through the engine's
  `sparql_update` scalar (sqlite-sparql 0.5.0). Returns the engine's
  signed net delta as `count:` (inserts − deletes). The DATA-form
  fast paths still return positive counts; the widening from
  unsigned to signed only affects callers opting into arbitrary
  UPDATE.
- New pinned `:reason` symbol `:sparql_eval_error`. The engine
  surfaces parse failures with `"SPARQL parse error:"` and
  evaluation failures with `"SPARQL evaluation error:"`;
  `classify_statement_error` branches on the prefix so callers can
  distinguish "the query didn't parse" from "the query parsed but
  referred to undefined predicates / bad IRIs / etc."
- `graph:` kwarg composes with the new fallback: when set,
  `WITH <graph>` is prepended to the query (SPARQL 1.1's
  graph-scoping prefix for INSERT / DELETE / INSERT WHERE / DELETE
  WHERE forms).
- 5 new specs (86 total): DELETE-with-WHERE signed-delta,
  INSERT-with-WHERE derivation, mixed-UPDATE net delta, malformed
  UPDATE → :sparql_parse_error, INSERT DATA fast-path regression
  guard. The old "unsupported UPDATE refusal" spec retires; that
  contract collapses with this phase.

## 0.2.0 — 2026-05-20

Closes PLAN_0.2.0 (multi-subject emission, collection iteration +
multi-value predicates, JSON / structured-literal object types).
Phase D (named graphs) moved to PLAN_0.5.0; Phase E (bulk write)
moved to PLAN_0.4.0; both ship under their own gem versions.

CONSUMER_REQUIREMENT_MM.md items #1–#4 graduate to "Surfaces MM
consumes" inline.

PLAN_0.2.0 Phase C — JSON / structured-literal object types.

- `TermSerializer.object` grows `when Hash, Array` branches: values
  are JSON-encoded via `JSON.generate(value)` and emitted as typed
  literals with `xsd:string` datatype.
- xsd:string chosen over rdf:JSON for engine compatibility — the
  existing NT parser round-trips xsd:string cleanly; rdf:JSON
  support is post-0.2.0 if MM signals demand.
- N-Triples literal escaping composes correctly on top of
  JSON.generate output: JSON's `\"` becomes `\\\"` in the wire
  literal. Operators read back via `Sparql.select` and
  `JSON.parse` the resulting literal value.
- `require "json"` added to storable.rb.
- 4 new specs covering Hash / Array / embedded-quote escape /
  empty-collection JSON round-trips. 62 total green via `bin/check`.

PLAN_0.2.0 Phase B — `each` blocks (collection iteration + multi-value predicates).

- `Recorder#each(collection_lambda, &predicates_block)` declares a
  per-collection-item emission. The block_proc is **not** evaluated
  at declaration time; emission re-runs it once per current-collection
  item via an `EachItemRecorder` that pushes (per-item-interpolated
  IRI, value lambda closing over item) into a shared buffer.
- Multi-value predicates fall out naturally: a constant predicate
  IRI emitted N times across N items produces N triples (e.g.
  `mm:hasFeature` for N flags).
- Read-replace adjustment: before any emission for an each block,
  retract all triples matching (subject, predicate) for every
  unique predicate IRI the block emits this save. v0.2.0 ships the
  documented limitation: empty collection this save → no retraction
  → stale triples from prior non-empty save persist. Operators
  needing strict cleanup pair with explicit `Sparql.execute("DELETE
  WHERE …")`.
- nil-valued lambdas inside each blocks are **skipped** (not emitted
  as nil-retraction); the surrounding read-replace already cleared
  the predicate slot.
- `Sparql.execute` dispatcher grows a new branch:
  `DELETE WHERE { <s> <p> ?o }` → SELECT current values + rdf_delete
  each. Lifted onto the public `execute` surface so the envelope
  discipline holds. Returns `{ ok: true, count: <integer> }`.
- `Declaration` gains `each_blocks: Array<EachBlock>` (default `[]`).
- INSERT DATA body construction uses `\n`-separated triples (NT
  parser requires this; space-separated bodies only persisted the
  first triple in the engine round-trip).
- 8 new specs (58 total, up from 50): 3 pure-Ruby recorder cases
  (each capture, ArgumentError on missing block / missing
  collection) + 5 live-engine lifecycle cases (per-item-interpolated
  predicates; multi-value; update replaces predicate set; destroy
  retracts; public `DELETE WHERE` round-trip).

PLAN_0.2.0 Phase A — `on_subject` sub-blocks + literal-string predicate values.

- `Recorder#on_subject(subject_callable, &predicates_block)` declares
  a secondary subject IRI emitted alongside the primary subject in
  every `after_save`; retracted alongside in every `after_destroy`.
  Nested predicates use the same `triple` DSL (lambdas, `if:`
  guards, or literal-string predicate values).
- `triple "rdf:type", "<urn:mm:CategoryFolder>"` — literal-string
  values now pass through (wrapped internally into a constant
  lambda). `TermSerializer.object` already detects `<...>`-wrapped
  strings and emits them as IRI objects, so this just works.
- `Declaration` gains `on_subject_blocks: Array<OnSubjectBlock>` (default `[]`).
- Lifecycle paths split into `semantica_emit_for_(subject_lambda,
  predicates)` and `semantica_retract_for_(subject_lambda,
  predicates)` so they iterate primary then each block; both share
  the same read-replace-per-predicate idempotency contract from v0.1.0.
- 7 new specs (50 total, up from 43): 4 pure-Ruby recorder cases
  (on_subject capture, literal-string wrapping, ArgumentError on
  missing block / missing subject) + 3 live-engine lifecycle cases
  (primary + derived emit on create; both retract on destroy;
  literal-string predicate serializes as IRI).

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
