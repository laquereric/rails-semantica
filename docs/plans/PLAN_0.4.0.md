# PLAN_0.4.0 — `rails-semantica` bulk write surface

> *Closes the bulk-write performance ask MM listed as item #6 of
> "Requested extensions (toward v0.2.0)" in
> `CONSUMER_REQUIREMENT_MM.md`. Engine prerequisite landed in
> `sqlite-sparql 0.4.0` (`rdf_insert_many` / `rdf_delete_many`).
> v0.4.0 surfaces a Ruby-side `Sparql.bulk_insert` /
> `bulk_delete` facade, wires `Storable`'s `:bulk` dispatch mode
> (declared in `PLAN_0.3.0` but stubbed there), and gives
> operators a one-shot path for migration-scale loads.*

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `sqlite-sparql 0.4.0` CHANGELOG | engine repo | Pins the JSON-array argument shape, abort-batch-on-error semantics, dedup-aware return value, term-grammar parity with single-row `rdf_insert`. |
| `PLAN_0.2.0.md` Phase E | this dir | Original sketch of the gem-side surface. v0.4.0 supersedes it; Phase E in `PLAN_0.2.0` is now a one-line pointer to this plan. |
| `PLAN_0.3.0.md` Phase B | this dir | Declares `Storable.dispatch_mode :bulk` as one of three lifecycle implementations; v0.4.0 ships the actual implementation. |
| `CONSUMER_REQUIREMENT_MM.md` §6 | this dir | MM's batched-write convenience ask; `Sparql.bulk_insert` is the public-facing surface MM consumes. |
| `sqlite-sparql/CONSUMER_REQUIREMENT_RS.md` §"Batched insert" | engine repo | RS's expectations doc for the engine. v0.4.0 lands the gem-side half of that contract. |

## Current state

**Released as v0.4.0 (2026-05-20).** All four phases landed:

- Phase A — `Sparql.bulk_insert` / `Sparql.bulk_delete` facade
  (Hash + Array row forms; abort-batch-on-error; row-indexed
  refusal envelope).
- Phase B — `Storable.dispatch_mode == :bulk` lifecycle path:
  `BulkEmitBuffer` captures replace/retract intents across one
  save, flushes via one `bulk_delete` + one `bulk_insert`.
  `Sparql.bulk_*` grew a `raw:` kwarg for engine-form rows.
- Phase C — parity/set-semantics/malformed-batch specs landed
  alongside Phase A; perf-smoke benchmark deferred (release-mode-only,
  not a release gate).
- Phase D — VERSION → 0.4.0; CHANGELOG `0.4.0` heading dated;
  README + CONSUMER_REQUIREMENT_MM.md updated.

## Engine surface (already landed, sqlite-sparql 0.4.0)

```sql
-- Insert many quads in one FFI crossing.
SELECT rdf_insert_many(
  '[["http://example.org/alice", "http://xmlns.com/foaf/0.1/name", "\"Alice\""],
    ["http://example.org/bob",   "http://xmlns.com/foaf/0.1/name", "\"Bob\"",   "urn:mm:graph:bhphoto"]]'
);
-- => INTEGER — count of *newly* inserted quads; duplicates collapse under
--    RDF set semantics and don't count toward the return value.

SELECT rdf_delete_many('<same JSON shape>');
-- => INTEGER — count of removed quads; rows not present don't count.
```

Pinned engine behaviours RS leans on:

- **Argument shape**: single JSON-string argument; outer is an array
  of arrays. Each inner row is `[s, p, o]` (default graph) or
  `[s, p, o, graph]`. `null` in the graph slot = default graph.
- **Term grammar**: identical to single-row `rdf_insert(s, p, o)` —
  bare IRIs for `s` / `p` (no `<...>`), N-Triples form for `o`
  (literals in `"..."`, IRIs bare; blank nodes `_:label`). The
  engine pins this via `test_insert_many_parser_parity_with_single`.
- **Empty input**: `'[]'` returns `0`, no error.
- **Malformed input**: the **whole batch aborts** before any write
  touches the store. Error message includes the failing row index
  (e.g. `row 7: subject: <reason>`). RS surfaces this as the
  refusal envelope's `:because:` string verbatim.
- **Errors as SQLite error strings**, not panics — same discipline
  as the rest of the engine surface.

## Current state baseline (v0.3.0 once it ships)

- `Storable.dispatch_mode` reader returns one of `:sparql_update`
  (engine ≥ 0.5.0), `:bulk` (engine ≥ 0.4.0, no sparql_update),
  `:per_call` (v0.2.0 baseline).
- The `:bulk` branch is **declared but stubbed**: it falls through
  to `:per_call` until v0.4.0 ships the implementation.
- `Sparql.bulk_insert` / `bulk_delete` do not exist; PLAN_0.2.0
  Phase E sketched them, v0.4.0 actually implements them.

## Scope

### Phase A — `Sparql.bulk_insert` / `bulk_delete` facade

Public Ruby surface:

```ruby
Semantica::Sparql.bulk_insert([
  { s: "urn:mm:product:EPET2850", p: "schema:name",     o: "Epson EcoTank" },
  { s: "urn:mm:product:EPET2850", p: "schema:category", o: "printer" },
  { s: "urn:mm:product:EPET2851", p: "schema:name",     o: "HP DeskJet",       graph: "urn:mm:graph:bhphoto" },
])
# => { ok: true, inserted: 3 }
# => { ok: false, reason: :sparql_parse_error,    because: "row 1: subject: ..." }   (engine row-indexed)
# => { ok: false, reason: :extension_not_loaded,  because: "..." }
# => { ok: false, reason: :ar_connection_error,   because: "..." }

# Positional shape — same semantics:
Semantica::Sparql.bulk_insert([
  ["urn:mm:product:EPET2850", "schema:name",     "Epson EcoTank"],
  ["urn:mm:product:EPET2850", "schema:category", "printer"],
  ["urn:mm:product:EPET2851", "schema:name",     "HP DeskJet", "urn:mm:graph:bhphoto"],
])

Semantica::Sparql.bulk_delete(rows)
# => { ok: true, deleted: <integer> }
# Same row shapes + same refusal envelope semantics.
```

#### Implementation

- Accept rows as `Array<Hash>` (`s:`/`p:`/`o:`/optional `graph:`) or
  `Array<Array>` (3- or 4-tuple). Normalise to a uniform internal
  shape before serialization.
- Each row's `s`, `p` run through `TermSerializer.iri` then
  immediately unwrap the angle brackets (engine wants bare IRIs).
  Reuse `Semantica::Sparql#unwrap_iri` (factored out of v0.1.0's
  `delete_each_triple`).
- Each row's `o` runs through `TermSerializer.object` (full
  type-dispatch). If the result is angle-bracketed (IRI object),
  unwrap; if it's a literal `"..."` / `"..."@en` / `"..."^^<dt>`,
  pass through unchanged. Blank nodes (`_:label`) pass through.
- Graph slot: same unwrap-if-IRI treatment; `nil` → JSON `null` →
  default graph.
- Marshal rows to a JSON array; one `connection.select_value("SELECT
  rdf_insert_many(#{connection.quote(json)})")` call per batch.
- Coerce the engine's integer return into the envelope's
  `:inserted` (or `:deleted`) field.
- Error classification: the engine surfaces malformed-batch errors
  as SQLite errors with `row <N>: ...` text. RS's existing
  `classify_statement_error` maps these to `:sparql_parse_error`
  (because they're term-grammar / structural validation failures),
  preserving the row-index detail in `:because:`.
- **No partial-success path**. The engine aborts the whole batch on
  any malformed row; the RS envelope mirrors that: either all rows
  land (`ok: true, inserted: N`) or none do (`ok: false, ...`). MM's
  bulk migrations need to handle this contract; the consumer doc
  graduates the surface accordingly.

#### Exit criteria

- Spec: `bulk_insert` of 1000 mixed-graph rows in one call inserts
  1000 quads; observable via `Sparql.select`.
- Spec: `bulk_delete` of a curated row set removes exactly those.
- Spec: Hash-form and Array-form rows produce identical engine
  state.
- Spec: empty array → `{ ok: true, inserted: 0 }` (or
  `:deleted: 0`).
- Spec: one bad row in a 100-row batch → whole batch refused;
  store unchanged; envelope `:because:` contains `row <index>:`.
- Spec: duplicates collapse — inserting the same row twice in one
  batch returns `inserted: 1` (engine set semantics).

### Phase B — `Storable` `:bulk` dispatch mode

PLAN_0.3.0 declared the dispatch-mode ladder. v0.4.0 fills in the
`:bulk` branch.

#### Implementation

- `Storable` lifecycle hooks, when `dispatch_mode == :bulk`:
  1. Build the full set of (subject, predicate, new_value) triples
     for the record (primary subject + on_subject blocks + each
     blocks; PLAN_0.2.0 Phase A + B).
  2. For each unique (subject, predicate) pair in the new set,
     issue a `Sparql.select("SELECT ?o WHERE { <s> <p> ?o }")` to
     enumerate current values. (Open question: a single
     multi-pattern SELECT for all pairs; benchmark this against the
     N-pair approach during the implementation.)
  3. Aggregate all current values into a single `bulk_delete` call.
  4. Aggregate all new values into a single `bulk_insert` call.
  5. Two engine round-trips per save (delete + insert) regardless
     of how many predicates the record declares.
- `:bulk` dispatch retains the same idempotency contract as
  `:per_call`: re-saving an unchanged record is a no-op at the
  store level (set semantics; the bulk_insert dedups, the
  bulk_delete removes-and-restores the same quads).
- nil-valued lambdas: the value is dropped from the `bulk_insert`
  payload entirely (just like in `:per_call`); the `bulk_delete`
  still retracts any current value for that (subject, predicate).
- Destroy path: gather every declared (subject, predicate, current
  value) tuple via SELECT, hand to `bulk_delete`.

#### Trade-offs vs. `:sparql_update`

`:sparql_update` (PLAN_0.3.0 Phase B) collapses each predicate's
replacement into one round-trip via `DELETE/INSERT WHERE`. For a
record with N declared predicates, `:sparql_update` = N round-trips;
`:bulk` = 2 round-trips. So:

- **For records with many predicates** (≥ 3): `:bulk` is faster.
- **For records with few predicates** (1 or 2): `:sparql_update`
  has lower constant overhead.
- **For the `each` block case** (multi-value): both modes handle
  it; `:bulk` aggregates one combined batch per direction.

Dispatch-mode ladder default ordering stays: prefer
`:sparql_update` (more declarative, atomic per predicate; better
for the typical 1–3 predicate case). Operators wanting the bulk
path force it via `MM_SEMANTICA_DISPATCH_MODE=bulk`.

#### Exit criteria

- Spec: forcing `:bulk` mode via env var, `Widget.create!` round-
  trips identically to `:per_call`.
- Spec: forcing `:bulk` mode, `Widget.update!` produces no stale
  triples (delete-then-insert preserves correctness).
- Spec: forcing `:bulk` mode, `Widget.destroy!` retracts every
  declared triple in two engine round-trips total (one SELECT
  burst + one bulk_delete).
- Performance smoke: a `:bulk` save of a record with ≥ 3
  predicates issues exactly 2 + (#unique-predicate-pairs)
  round-trips; benchmark spec asserts this.

### Phase C — Spec: parity-with-single, perf smoke, malformed batch

Three classes of spec land alongside Phases A + B:

- **Parity**: a small generated set (Hash-form rows × Array-form
  rows × all term types from TermSerializer) round-trips
  identically through `bulk_insert` and through N single-row
  `Sparql.execute("INSERT DATA { ... }")` calls. The store ends
  in the same state regardless of path. Mirrors the engine's own
  `test_insert_many_parser_parity_with_single` from the gem side.
- **Perf smoke**: `release_mode: true` skip-by-default benchmark
  spec — 1000-row `bulk_insert` completes in under 250ms wall-clock
  (the engine's own smoke targets 100ms; the gem adds JSON marshal
  + AR round-trip overhead). Skipped in normal `bin/check` runs;
  exercised explicitly when measuring.
- **Malformed batch**: a row with an invalid IRI mid-batch — the
  whole batch refuses, the refusal envelope's `:because:` contains
  `row <index>:`, and the store is unchanged afterwards (asserted
  via `Sparql.select` count before vs. after).

### Phase D — Docs

- `CHANGELOG.md` — per-phase entry; collected under `0.4.0` at
  release.
- `README.md` — Sparql surface map grows the `bulk_insert` /
  `bulk_delete` examples + the "no partial success" + dedup-aware-
  return-value notes. `Storable.dispatch_mode` table notes that
  `:bulk` is implemented as of v0.4.0.
- `CONSUMER_REQUIREMENT_MM.md` — graduate the §6 "Batched-write
  convenience" extension from §"Requested" into §"Surfaces MM
  consumes." Note the abort-batch-on-error contract so MM's
  migration shape (PLAN_0_29_1 Phase B.1 copy migration) accounts
  for it. MM bumps `Gemfile.lock` at this graduation.
- `PLAN_0.2.0.md` Phase E — replace the section body with a
  one-line pointer to `PLAN_0.4.0.md`. PLAN_0.2.0's scope
  contracts from six extensions to five (multi-subject, each /
  multi-value, JSON literals, named graphs, contract additions).
- `docs/plans/PLAN_0.4.0.md` — this file. Update "Current state"
  as phases land.

## Out of scope for v0.4.0

- **Streaming bulk insert** (process rows in chunks, yield
  per-chunk progress). The engine's contract is "whole batch, all
  or nothing"; streaming would require chunking on the RS side
  and breaking atomicity. Defer; rare need.
- **Per-row pre-validation** before sending to the engine. The
  engine validates + reports the failing row index; mirroring that
  validation on the RS side is duplicated work without a
  consumer-visible benefit. Defer.
- **Insert / delete in the same call.** The engine surface ships
  them separate; combining them in one call is what
  `Sparql.execute(sparql_update_query)` already does via
  PLAN_0.3.0. No additional gem surface needed.
- **Storable-side dirty-tracking before the bulk_delete + bulk_
  insert pair.** Optimisation candidate for v0.5.0+; v0.4.0
  always full-replaces.

## v0.4.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Sparql.bulk_insert(rows)` | envelope `{ ok:, inserted: <integer> }` / `{ ok: false, reason:, because: }` | **Pinned.** `:inserted:` reflects engine set semantics (dedup-aware). |
| `Sparql.bulk_delete(rows)` | envelope `{ ok:, deleted: <integer> }` / `{ ok: false, reason:, because: }` | **Pinned.** |
| Row shapes: `Array<Hash{s:, p:, o:, graph:?}>` and `Array<Array>` 3/4-tuple | dispatched internally | **Pinned.** Both forms are equivalent. |
| Abort-batch-on-error semantics | engine-driven; mirrored in envelope | **Pinned**, follows engine. |
| `Storable.dispatch_mode == :bulk` implementation | 2-round-trip lifecycle per save | **Pinned algorithmic shape**; exact SELECT pattern (single vs. N) may evolve in v0.4.x as benchmarking informs. |

No new `:reason:` symbols. Malformed batches surface via the
existing `:sparql_parse_error`.

## Risks

| Risk | Mitigation |
|---|---|
| TermSerializer round-trip through the bulk path produces a different on-wire form than the single-row path. | Phase C parity spec is the gate. Engine pins parity on its side via `test_insert_many_parser_parity_with_single`; RS pins it on the gem side. |
| JSON marshaling cost dominates for small batches, making `:bulk` slower than `:per_call` for 1–2 predicates. | Dispatch ladder defaults to `:sparql_update` when present; `:bulk` is the engine ≥ 0.4.0 fallback when sparql_update isn't available. Operators with predominantly 1–2-predicate records can pin `:per_call` via env var. |
| Abort-batch contract surprises operators expecting partial success. | Document loudly in README + the bulk_insert section's docstring. The refusal envelope's `:because:` carries the row-index detail; operators bisect or pre-validate. |
| `Storable`'s `:bulk` implementation issues one SELECT per unique (subject, predicate) pair, multiplying round-trips. | Benchmark during Phase B; if N-SELECT dominates wall-clock, collapse into a single multi-pattern `SELECT ?o WHERE { { <s1> <p1> ?o } UNION { <s2> <p2> ?o } ... }` BGP query. Decide via the perf smoke result. |
| The engine's `:inserted:` return value (newly-inserted; deduping under set semantics) confuses callers expecting "rows submitted." | Document. Add a spec showing the dedup behaviour explicitly. |

## Acceptance signal

When all phases land:

1. `Sparql.bulk_insert` / `bulk_delete` round-trip mixed-graph
   batches against engine ≥ 0.4.0.
2. `Storable.dispatch_mode == :bulk` produces a 2-round-trip
   lifecycle save indistinguishable in outcome from `:per_call`.
3. `bin/check` green; the perf-smoke spec stays explicit (run on
   demand, not in the default suite).
4. CHANGELOG `0.4.0` heading drops `(unreleased)`.
5. Root `VERSION` bumps to `0.4.0` (single source of truth per
   the reconciliation at commit `8489ee1`).
6. CONSUMER_REQUIREMENT_MM.md §6 graduates from "Requested" into
   "Surfaces MM consumes."
7. PLAN_0.2.0.md Phase E shrinks to a one-line pointer to this
   plan.

## Cross-references

- `./PLAN_0.1.0.md` — the `unwrap_iri` helper this plan reuses.
- `./PLAN_0.2.0.md` Phase E — the original sketch v0.4.0
  supersedes; that phase becomes a pointer.
- `./PLAN_0.3.0.md` Phase B — the dispatch-mode ladder v0.4.0
  fills in.
- Engine repo `laquereric/sqlite-sparql` 0.4.0 — the prerequisite
  release. Engine pinned at 0.5.0 since `8489ee1`; v0.4.0's
  prerequisite is already satisfied.
- `magentic-market-ai/docs/plans/PLAN_0_29_1` Phase B.1 — MM's
  copy migration that consumes `bulk_insert` directly (not via
  Storable; one-shot data load).
