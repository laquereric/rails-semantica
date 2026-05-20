# PLAN_0.6.0 — `rails-semantica` shared-store posture

> *Adapts the gem to the engine's `sqlite-sparql 0.2.0` shared-
> process-wide store. The SQL surface didn't change, but visibility
> semantics did: writes from connection A are now seen by
> connection B in the same process. The gem's Loader sentinel,
> `Storable`'s concurrency contract, and the spec suite's
> isolation tactics all need to land on the new floor. Adds a
> `Sparql.store_size` helper backed by `rdf_count_all()` and pins
> the cross-connection visibility property with an explicit spec.*

## Current state

**Released as v0.6.0 (2026-05-20).** All seven phases landed:

- Phase A — Loader sentinel doc-comment refined; `engine_version`
  reader returns `:unknown` (engine probe not yet shipped).
- Phase B — `spec/semantica/cross_connection_visibility_spec.rb`
  pins same-thread / cross-thread / named-graph visibility.
- Phase C — `Sparql.store_size(graph: …)` helper backed by
  `rdf_count_all` / `rdf_count` / `rdf_count(graph)`.
- Phase D — `Storable.dispatch_mode` concurrency note added;
  README grows `## Concurrency` section recommending
  `:sparql_update` for overlapping-write workloads.
- Phase E — `spec/support/extension_environment.rb` comment block
  declares `reset_store!` mandatory for test isolation under
  shared-store; pin parallel-worker incompatibility.
- Phase F — 11 new specs (137 total).
- Phase G — VERSION → 0.6.0; CHANGELOG `0.6.0` heading dated;
  README + CONSUMER_REQUIREMENT_MM.md updated (the latter grows a
  `## Concurrency model` section).

With v0.6.0 released atop v0.2.0–v0.5.0, the gem's posture matches
the engine's full 0.5.x feature set. Further evolution is
gem-internal or engine-driven.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| Engine `PLAN_0.2.0` (`sqlite-sparql/docs/plans/PLAN_0.2.0.md`) | engine repo | The shared-store refactor: `OnceLock<Arc<Store>>` replaces `thread_local! { RefCell<Store> }`. Pinned at engine 0.2.0; current substrate pin is 0.5.0, so satisfied. |
| Engine `REVIEW_0.1.0.md` | engine repo | Motivates the shared-store fix: per-thread blow-up + cross-connection invisibility footgun. |
| `PLAN_0.1.0.md` Phase B | this dir | The Loader's `extension_loaded?` sentinel (`SELECT rdf_count()`) was built against the thread-local-store assumption. v0.6.0 revisits that assumption. |
| `PLAN_0.3.0.md` Phase B | this dir | The `dispatch_mode` ladder. v0.6.0 documents which mode is concurrency-safe under shared-store; `:sparql_update` becomes the recommended default for multi-threaded write loads. |
| `CONSUMER_REQUIREMENT_MM.md` §"Behaviours MM does NOT depend on" | this dir | MM pins only `ensure_extension_loaded!` being callable + idempotent. v0.6.0 keeps that contract; internal sentinel changes happen below MM's line. |

## What changed at the engine level (already shipped, pinned at 0.5.0)

Behaviours v0.6.0 builds on:

- **One Oxigraph Store per process**, shared by every SQLite
  connection on every thread. `Send + Sync` Store; mutating methods
  on `&Store`; Arc-shared indexes internally.
- **No SQL surface change.** All `rdf_*` / `sparql_*` functions
  keep their 0.1.0 signatures and envelope shapes.
- **No additional locking on the Ruby side.** The engine handles
  concurrency internally.
- **`rdf_count_all()`** (shipped in engine 0.3.0) counts across
  every graph. Combined with shared store, it's a true
  process-wide-total-triples reader.

What the gem currently assumes that's now wrong:

- `Semantica::Loader#extension_loaded?` calls `SELECT rdf_count()`
  and treats success as "extension loaded on this connection."
  Still works (`rdf_count` returns an integer on a fresh
  connection), but the sentinel's framing — "this query succeeded
  on this connection" — collapses correctly. The remaining nuance:
  the sentinel doesn't tell us whether the **store has data** from
  other connections. The Loader doesn't care about that; it only
  needs to know if the function is callable.
- `Semantica::SpecSupport::ExtensionEnvironment.reset_store!` calls
  `rdf_clear` to wipe the store between examples. Under shared
  store, this is **still correct** (clearing the one process-wide
  store clears it for every connection) but the framing changes:
  "clear" was a per-thread no-op for cross-thread leaks; now it's
  the only mechanism preventing cross-example leakage. This makes
  test isolation more fragile under parallel test workers (none
  ship today, but spec frameworks like `rspec-parallel` would
  break).
- `Semantica::Storable` lifecycle hooks' read-replace per
  (subject, predicate) is non-atomic across multi-threaded writes
  to the same subject/predicate. In the old thread-local world,
  concurrent saves from two threads couldn't collide (they wrote
  to different stores). Now they can.

## Scope

### Phase A — Loader sentinel refinement

The `extension_loaded?` sentinel keeps probing via `SELECT
rdf_count()` (function-callability check). The semantic shift
needs documenting + an extra guard.

#### Implementation

- Keep the `SENTINEL_QUERY = "SELECT rdf_count()"` constant. It
  still proves the function exists on this SQLite connection.
- Update the doc comment to clarify: "Returns true if the
  extension is loaded into the current connection. Under engine
  ≥ 0.2.0 the store itself is process-wide and may already have
  data from other connections; that's expected, not a sign of
  re-loading."
- Add a defensive guard: if `SELECT rdf_count()` returns a value
  but `SELECT rdf_count_all()` raises `no such function`, the
  extension is loaded but is pre-0.3.0. Log a warning but don't
  fail; v0.6.0's required engine floor stays 0.2.0 (the
  shared-store fix).
- `Semantica::Loader.engine_version` (new) — best-effort engine
  version probe via a dedicated `rdf_version()` scalar **if the
  engine exposes one** (engine 0.5.x doesn't yet). Until it does,
  the method returns `:unknown` and operators read the substrate's
  submodule pin for ground truth. Pin the contract;
  implementation can grow when the engine ships a version probe.

#### Exit criteria

- Spec: `Loader.ensure_extension_loaded!` is idempotent across
  multiple AR connections (already pinned by v0.1.0's
  `loader_spec.rb`; extend to assert no extra side effects under
  shared-store).
- Spec: `Loader.engine_version` returns either a string (when
  engine ships the probe) or `:unknown` (today); the contract
  reader test pins the symbol.
- Spec: when the extension is loaded once and then a second AR
  connection joins, `ensure_extension_loaded!` skips the load on
  the second connection and probes successfully (already
  exercised by v0.1.0's idempotent-load test; reframe under
  shared-store).

### Phase B — Cross-connection visibility pin (spec only, no code)

The gem's contract grows a property: a write from one connection
is visible from another. Pin it explicitly so future engine
regressions trip the gem's spec suite first.

#### Implementation

- New spec file `spec/semantica/cross_connection_visibility_spec.rb`,
  `:requires_extension` tagged.
- Test: open `ActiveRecord::Base.connection`, write a triple, open
  a second connection on the same thread (`ActiveRecord::Base.connection_pool.with_connection { ... }`
  or similar), read the triple back. Assert visibility.
- Test: same, across threads (spin up a second Ruby thread,
  acquire a connection there, read). Assert visibility. Document
  if AR's thread-per-connection-pool model adds noise.
- Test: a write to a named graph from connection A is visible
  from connection B via a `Sparql.select(query, graph:)` call —
  combines PLAN_0.5.0's `graph:` with shared-store visibility.

#### Exit criteria

- All three visibility specs pass against the live engine.
- Spec failure under a hypothetical engine regression that
  reverted to thread-local would be unambiguous.

### Phase C — `Sparql.store_size` helper

Expose `rdf_count_all()` as a Ruby-side convenience method.
Operators querying "how many triples in this engine?" today have
to either call `Sparql.select("SELECT (COUNT(*) AS ?n) WHERE { ?s
?p ?o }")` (default graph only) or hand-write
`connection.select_value("SELECT rdf_count_all()")`. v0.6.0 adds:

```ruby
Semantica::Sparql.store_size
# => { ok: true, count: <integer> }
# Counts every quad in every graph, default included. Cheap;
# routed straight to the engine's rdf_count_all() scalar.

Semantica::Sparql.store_size(graph: "urn:mm:graph:bhphoto")
# => { ok: true, count: <integer> }
# Routed to rdf_count(graph) for a specific graph.

Semantica::Sparql.store_size(graph: nil)
# => { ok: true, count: <integer> }
# rdf_count() — default graph only. Explicit nil opts out of
# the cross-graph default.
```

#### Implementation

- Same envelope discipline as the other `Sparql` methods.
- Refusal envelopes on the usual failure modes
  (`:extension_not_loaded`, `:ar_connection_error`).
- Default behaviour (no `graph:` kwarg) calls `rdf_count_all()`.
  Operators who want the default-graph-only count pass
  `graph: nil` explicitly.

#### Exit criteria

- Spec: `Sparql.store_size` returns total count including named-
  graph triples (paired with PLAN_0.5.0 named-graph spec
  scaffolding).
- Spec: `Sparql.store_size(graph: "urn:g")` returns count for that
  graph only; `Sparql.store_size(graph: nil)` returns default
  graph only.
- Spec: extension-not-loaded surfaces as a refusal envelope.

### Phase D — `Storable` concurrency contract (docs + dispatch-mode recommendation)

Code-light phase. The shared-store world makes concurrent saves
to the same `(subject, predicate)` from two threads collide. The
gem can't lock around this without coordinating across the entire
process. Document the contract; recommend `:sparql_update`
dispatch mode as the atomic-per-predicate path.

#### Implementation

- Add a `## Concurrency` section to the README documenting:
  - Single-threaded use (the common Rails case): no change from
    v0.5.0. Read-replace per predicate is correct.
  - Multi-threaded writes to the **same** (subject, predicate):
    races possible under `:per_call` and `:bulk` (the
    SELECT-then-DELETE-then-INSERT pattern isn't atomic across
    threads). `:sparql_update` mode uses
    `DELETE/INSERT WHERE` in one engine pass; the engine's
    internal Arc-shared store handles concurrency atomically.
  - Recommend `MM_SEMANTICA_DISPATCH_MODE=sparql_update` for
    apps doing concurrent writes to overlapping data.
- Add a doc-comment on `Storable.dispatch_mode` reader noting
  the concurrency property.
- Add a CHANGELOG entry naming the recommended dispatch mode.

#### Exit criteria

- README's `## Concurrency` section lands.
- `Storable.dispatch_mode` doc-comment names the concurrency
  property.
- No spec code (the engine's own internals pin the atomicity;
  spec-suite-induced races would be flaky and add little).

### Phase E — Test infrastructure update

`ExtensionEnvironment.reset_store!` already calls `rdf_clear`
between examples. Under shared store this is **mandatory** for
test isolation, not just hygiene. Make the dependency explicit;
document parallel-test-worker incompatibility.

#### Implementation

- Update `spec/support/extension_environment.rb` comment block to
  clearly state: "Under engine ≥ 0.2.0 the store is shared
  process-wide. `reset_store!` is required between examples;
  parallel test workers (e.g. `rspec-parallel`) will clobber each
  other's stores. Run specs serially in this gem."
- Add a `:requires_extension` guard that's even tighter: if
  multiple examples are running in parallel (detect via
  `ENV["RSPEC_FORKS"]` or similar), refuse to run with a clear
  error. (Defer if YAGNI.)

#### Exit criteria

- Comment updates land.
- `bin/check` stays green (serial execution by default).

### Phase F — Specs + bin/check

Per-phase specs covered above. `bin/check` is the release gate.

### Phase G — Docs

- `CHANGELOG.md` — per-phase entries; `0.6.0` heading at release.
- `README.md` — `## Concurrency` section (Phase D); `store_size`
  example in the Sparql surface map; engine-version probe
  documented under Loader.
- `CONSUMER_REQUIREMENT_MM.md` — add a §"Concurrency model" entry
  documenting:
  - The shared-store visibility contract MM now relies on (was
    explicitly bug-territory before).
  - The dispatch-mode recommendation for multi-threaded writes.
  - The test-isolation requirement for substrate-side specs that
    exercise the gem.
- `docs/plans/PLAN_0.6.0.md` — this file. Update "Current state"
  as phases land.

## Out of scope for v0.6.0

- **Process-wide locking primitives** in Ruby. Pure overhead; the
  engine's Arc-shared Store handles concurrency. Don't add a
  Mutex.
- **Cross-process coordination.** Today's substrate runs one
  Rails process per Tauri/Hotwire shell; cross-process semantics
  are out of scope. If the substrate ever runs multi-process
  with a shared SQLite file backend, the engine's persistence
  story dictates the contract; v0.6.0 doesn't pre-build for it.
- **Automatic dispatch-mode promotion** (gem detects concurrent
  writes and switches modes). Operators decide via env var; the
  gem doesn't second-guess.
- **A `Sparql.transaction` block.** SQLite's `BEGIN ... COMMIT`
  is a connection-level construct; it doesn't atomicize multiple
  `rdf_*` calls under shared store the way the operator might
  expect. Defer until a clear semantic is established.
- **Engine-level snapshot isolation hooks.** Not exposed by the
  engine today; nothing for the gem to surface.

## v0.6.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Sparql.store_size(graph: <iri_or_nil_or_omitted>)` | envelope `{ ok:, count: <integer> }` | **Pinned.** Omitted graph = all-graphs (rdf_count_all). Explicit `nil` = default graph only (rdf_count). String = named graph (rdf_count graph). |
| `Loader.engine_version` reader | `String` or `:unknown` | **Pinned shape.** Underlying probe grows when the engine ships `rdf_version()`. |
| Cross-connection visibility property | spec contract, no API change | **Pinned.** A regression in the engine that breaks visibility breaks the gem's spec suite first. |
| `Storable.dispatch_mode` concurrency contract | docs note + reader stays the same | **Pinned via docs.** `:sparql_update` recommended for concurrent overlapping-write workloads. |

No new `:reason:` symbols. Loader semantics change is internal.

## Risks

| Risk | Mitigation |
|---|---|
| `rdf_version()` doesn't exist in the engine yet; `Loader.engine_version` returns `:unknown`. | Pinned as `:unknown` in v0.6.0's contract. When the engine ships the probe, the gem's `engine_version` method body grows a real call; the contract surface stays. |
| MM's substrate has spec suites assuming thread-local visibility (writes invisible across threads). | The engine `REVIEW_0.1.0.md` already established that nobody was leaning on the old behaviour deliberately; it was a bug. MM's audit + roundtrip specs (PLAN_0_29_1 Phase D) don't rely on isolation. If any substrate spec breaks under shared store, it was always-already-broken. |
| Test isolation requires `rdf_clear` between examples; parallel test workers would clobber. | Documented loudly in the test infrastructure; serial execution is the default; an explicit refusal-on-parallel guard is optional v0.6.x. |
| Storable's non-`:sparql_update` modes can race under concurrent overlapping writes. | Documented in README §"Concurrency." Recommendation: `:sparql_update`. The race is an engine-level (Oxigraph) atomicity property — `:sparql_update` runs the DELETE/INSERT WHERE in a single Oxigraph call which the store handles atomically. |
| `Sparql.store_size` is just sugar over a `connection.select_value`; some operators might prefer the raw SQL. | Both paths remain available. The helper is a convenience; not load-bearing. |

## Acceptance signal

When all phases land:

1. Loader's sentinel works under shared-store with no
   functional regression.
2. Cross-connection visibility spec passes against engine ≥ 0.2.0;
   regression test in place.
3. `Sparql.store_size` returns sensible counts across the three
   graph modes.
4. README documents concurrency, dispatch-mode recommendation,
   and test isolation.
5. CHANGELOG `0.6.0` heading drops `(unreleased)`.
6. Root `VERSION` bumps to `0.6.0` (single source of truth per
   commit `8489ee1`).
7. CONSUMER_REQUIREMENT_MM.md grows a §"Concurrency model"
   entry describing the contract; substrate-side specs follow
   the test-isolation guidance.
8. `bin/check` green against engine 0.5.0+.

With v0.6.0 released atop v0.2.0–v0.5.0, the gem's posture matches
the engine's full 0.5.x feature set. The gem becomes a clean
consumer of every engine surface; further evolution is
gem-internal (operator ergonomics, performance) or engine-driven
(new SQL surfaces) but doesn't require another posture shift.

## Cross-references

- `./PLAN_0.1.0.md` — Loader's `extension_loaded?` sentinel
  whose framing v0.6.0 updates.
- `./PLAN_0.3.0.md` Phase B — `dispatch_mode` ladder; v0.6.0
  recommends `:sparql_update` for concurrent workloads.
- `./PLAN_0.5.0.md` Phase B — named-graph DSL; v0.6.0's
  cross-connection visibility spec extends to graph-scoped
  reads.
- Engine repo `laquereric/sqlite-sparql` 0.2.0 — the
  prerequisite. Pinned 0.5.0 = satisfied.
- Engine `REVIEW_0.1.0.md` — the motivation for the engine's
  shared-store fix.
- `magentic-market-ai/docs/plans/PLAN_0_29_x` — substrate
  consumes the shared-store contract through `bin/mm-smoke`'s
  semantica step + the audit/roundtrip specs that already pin
  visibility implicitly.
