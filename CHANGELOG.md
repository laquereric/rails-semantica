# Changelog

## 0.6.0 — 2026-05-20

Closes PLAN_0.6.0. Adapts the gem to the engine's shared-store
posture (one Oxigraph store per process; engine ≥ 0.2.0).

- Loader sentinel doc-comment refined: clarifies that the
  process-wide store may already have data from other connections;
  the sentinel only proves the function is callable on this
  connection. `Loader.engine_version` reader returns the engine's
  `rdf_version()` string when present, `:unknown` otherwise
  (engine 0.5.0 doesn't yet ship the probe; shape pinned now,
  body grows when it does). New pinned constant
  `Loader::ENGINE_VERSION_UNKNOWN`.
- New `Sparql.store_size(graph: …)` helper. Omitted graph →
  `rdf_count_all()` (every graph including default). Explicit
  `graph: nil` → `rdf_count()` (default graph only). String →
  `rdf_count(graph)`.
- `Storable.dispatch_mode` doc-comment grows a concurrency note:
  `:sparql_update` is atomic per predicate (single
  `DELETE/INSERT WHERE` engine call); `:bulk` and `:per_call`
  race under concurrent writes to the same `(subject, predicate)`.
  README grows a `## Concurrency` section recommending
  `MM_SEMANTICA_DISPATCH_MODE=sparql_update` for overlapping-write
  workloads.
- `spec/support/extension_environment.rb` comment block updated —
  `reset_store!` is now mandatory for test isolation (not just
  hygiene); parallel test workers clobber under shared-store.
- 11 new specs (137 total): 3 cross-connection visibility
  (same-thread connection pair, cross-thread, named-graph
  visibility), 6 `store_size` (surface contract + AR-less refusal
  + rdf_count_all + default-only + named-graph + blank-node
  refusal), 2 `engine_version` (no-AR fallback + engine-lacks-
  probe fallback).

## 0.5.0 — 2026-05-20

Closes PLAN_0.5.0 against engine ≥ 0.3.0 (current pin 0.5.0
satisfies). Named-graph support:

- `Semantica::Sparql.{select,ask,construct,execute}` accept an
  optional `graph:` kwarg. Read paths textually insert `FROM <graph>`
  between projection and WHERE body (PREFIX preamble preserved;
  WHERE-less syntactic sugar handled). Writes route through the
  engine's 4-arg `rdf_insert(s,p,o,graph)` / `rdf_delete(s,p,o,graph)`
  (sqlite-sparql 0.3.0); arbitrary UPDATE paths prepend `WITH <graph>`.
- `Storable` `triples do; graph "<iri>"; … end` DSL declares the
  named graph every triple in the block emits to. `on_subject` and
  `each` blocks inherit the outer graph.
- All three dispatch modes (`:sparql_update` / `:bulk` /
  `:per_call`) produce equivalent end states for a graph-scoped
  model. The `:bulk` rung threads the graph through the 4-tuple
  row shape; the `:sparql_update` rung prepends `WITH <graph>`;
  the `:per_call` rung routes through the engine's 4-arg `rdf_*`
  scalars.
- Blank-node graph IRIs refuse at the gem boundary with the new
  `:invalid_graph` reason symbol. `execute("CLEAR ALL"/"CLEAR
  DEFAULT", graph: …)` refuses with the new `:invalid_dsl` reason
  (ambiguous scoping — use `execute("CLEAR GRAPH <urn:…>")`).
- 3 new specs (126 total): dispatch-mode-vs-graph equivalence
  parity loop across `:sparql_update` / `:bulk` / `:per_call`.

(Phase A and Phase B `:per_call` mode shipped earlier in commit
`03f8915`; this commit closes the dispatch-mode equivalence
contract once `:sparql_update` and `:bulk` paths landed via
PLAN_0.3.0 + PLAN_0.4.0.)

## 0.4.0 — 2026-05-20

Closes PLAN_0.4.0 against engine ≥ 0.4.0 (current pin 0.5.0
satisfies). Bulk-write facade exposes `Sparql.bulk_insert` /
`Sparql.bulk_delete`; `Storable`'s `:bulk` dispatch lights up,
giving the dispatch ladder its full three-rung surface.


PLAN_0.4.0 Phase B — `Storable.dispatch_mode == :bulk` implementation.

- The `:bulk` rung of the dispatch ladder (declared but stubbed in
  PLAN_0.3.0 Phase B) is now live. Lifecycle hooks capture all
  replace/retract intents during emission via an internal
  `BulkEmitBuffer`; on flush, one `Sparql.bulk_delete` (current
  values for affected (s, p, graph) keys) + one `Sparql.bulk_insert`
  (all new values) per save — 2 + N round-trips where N is the
  number of unique (subject, predicate, graph) keys touched
  (the SELECTs for current-value enumeration).
- `Sparql.bulk_insert` / `Sparql.bulk_delete` grow a `raw:` kwarg
  (default `false`). When `true`, rows skip `TermSerializer`
  normalization — used by `Storable`'s `:bulk` path which assembles
  already-engine-form rows from SELECT results.
- `replace_predicate_set!` / `retract_predicate!` now redirect into
  the bulk buffer when one is active on the instance; otherwise
  route through the existing `:sparql_update` / `:per_call`
  branches. on_subject + each blocks compose under the buffer with
  no special-casing.
- 6 new specs (123 total): dispatch-mode parity loop grows the
  `:bulk` case (create / update / destroy / nil); two
  round-trip-count smokes pin `:bulk` at exactly 1 `bulk_insert` on
  create and 1+1 on update regardless of predicate count.

PLAN_0.4.0 Phase A — `Sparql.bulk_insert` / `Sparql.bulk_delete` facade.

- Two new public methods on `Semantica::Sparql`. Accept rows as
  `Array<Hash>` (`s:`/`p:`/`o:`/optional `graph:`) or `Array<Array>`
  (3- or 4-tuple). Hash and Array forms are equivalent.
- Each row's terms run through `TermSerializer.iri` /
  `TermSerializer.predicate` / `TermSerializer.object`; subjects,
  predicates, and IRI objects get unwrapped to bare IRIs (the engine
  wants bare for `s`/`p`, N-Triples form for literal `o`). Single
  FFI crossing per batch via `rdf_insert_many` / `rdf_delete_many`
  (engine ≥ 0.4.0; current pin 0.5.0 satisfies).
- Envelopes: `{ ok: true, inserted: <integer> }` / `{ ok: true,
  deleted: <integer> }` on success; existing refusal envelope
  semantics on failure. Counts reflect engine set semantics
  (`:inserted:` is newly-inserted; duplicates within one batch
  collapse).
- Abort-batch-on-error: any malformed row aborts the whole batch
  before any write touches the store; refusal envelope's
  `:because:` carries the engine's row-indexed detail
  (`"row <N>: …"`).
- Blank-node graphs in a row refuse with row-indexed `:because:`
  before reaching the engine.
- 12 new specs (117 total): N-row insert, Hash↔Array form parity,
  empty input, set-semantics dedup, bulk_delete round-trip,
  graph-tagged rows, abort-batch-on-error, nullable graph slot,
  TermSerializer dispatch parity, non-Array input refusal.

## 0.3.0 — 2026-05-20

Closes PLAN_0.3.0 against engine ≥ 0.5.0. Arbitrary SPARQL UPDATE
unlocks via the engine's `sparql_update` scalar; `Storable`'s
lifecycle hooks gain a three-mode dispatch ladder (`:sparql_update`
collapses each predicate replacement to one round-trip). New pinned
reason symbol `:sparql_eval_error`; new pinned reader
`Storable.dispatch_mode`; new pinned env var
`MM_SEMANTICA_DISPATCH_MODE`.


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
