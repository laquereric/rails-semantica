# PLAN_0.3.0 — `rails-semantica` SPARQL UPDATE unlock

> *Closes the post-v0.2.0 "Arbitrary SPARQL UPDATE" gap that
> PLAN_0.1.0 + PLAN_0.2.0 left open. Engine-prerequisite landed in
> sqlite-sparql 0.5.0 (`sparql_update(query TEXT) → INTEGER`).
> v0.3.0 routes any UPDATE-not-DATA form through that surface and
> takes the opportunity to simplify `Semantica::Storable`'s
> lifecycle hooks from "SELECT + per-result DELETE DATA + INSERT
> DATA" to a single `DELETE/INSERT WHERE` UPDATE per predicate.*

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `sqlite-sparql/CONSUMER_REQUIREMENT_RS.md` §"4. SPARQL UPDATE" | engine repo | The engine-side ask, now satisfied. Engine pinned at 0.5.0. |
| `PLAN_0.1.0.md` | this dir | `Sparql.execute` dispatcher introduced here; the `unsupported SPARQL UPDATE form` refusal that v0.3.0 retires lives here. |
| `PLAN_0.2.0.md` Phase E | this dir | Bulk write surface (`bulk_insert` / `bulk_delete`). Storable picks between the bulk path (0.2.0) and the UPDATE-with-WHERE path (0.3.0) at runtime — see Phase B below. |
| `CONSUMER_REQUIREMENT_MM.md` | this dir | MM has not (yet) listed UPDATE-WHERE forms as a requested extension. v0.3.0 is engine-unblock-driven, not MM-driven; MM's consumption follows once the gem-side surface lands. |

## Engine prerequisite (landed)

`sqlite-sparql 0.5.0` ships:

- `sparql_update(query TEXT) → INTEGER` — runs any SPARQL 1.1
  UPDATE. Returns **signed net delta** in store size: `+N` for net
  insert, `-N` for net delete, `inserts − deletes` for mixed
  operations.
- Errors prefixed with `SPARQL parse error: <detail>` or
  `SPARQL evaluation error: <detail>`. RS pattern-matches the
  prefix when classifying refusals.

## Current state baseline (v0.2.0 once it ships)

- `Sparql.execute` dispatches `INSERT DATA` / `DELETE DATA` /
  `CLEAR ALL` to scalar engine functions. Anything else: refusal
  envelope `{ ok: false, reason: :sparql_parse_error, because:
  "unsupported SPARQL UPDATE form ..." }`.
- `Storable` read-replace per predicate:
  1. `SELECT ?o WHERE { <s> <p> ?o }` (the SELECT).
  2. For each result: `DELETE DATA { <s> <p> <old_o> . }` (per
     result; one round-trip each).
  3. `INSERT DATA { <s> <p> <new_o> . }`.
  Cost: 2 + N round-trips per predicate replacement.

## Scope

### Phase A — `Sparql.execute` arbitrary UPDATE pass-through

Extend the existing dispatcher's `else` branch to call
`sparql_update(query)` instead of refusing.

#### Implementation

- `Semantica::Sparql.execute`:
  - Keep the existing `INSERT DATA` / `DELETE DATA` / `CLEAR
    ALL` fast paths (they map cleanly to scalar functions; no
    reason to round-trip them through `sparql_update`).
  - Replace the `unsupported SPARQL UPDATE` raise in the `else`
    branch with: `connection.select_value("SELECT sparql_update(#{connection.quote(query)})")`.
  - Coerce the result to an Integer; return `{ ok: true, count:
    delta }` where `delta` is the signed net delta the engine
    returns.
- Error classification: extend `classify_statement_error` to
  recognise the new engine prefixes:
  - `"SPARQL parse error:"` → `:sparql_parse_error` (existing).
  - `"SPARQL evaluation error:"` → `:sparql_eval_error` (new — see Phase C).
- The `count:` field stays the same key the v0.1.0 envelope
  used; semantics widen (was unsigned, now signed). This is the
  one breaking-shape decision in v0.3.0; the alternative is a new
  `:delta:` key. Reasoning for keeping `:count:`: `INSERT DATA`
  always returns a positive count and `DELETE DATA` always
  returns positive count (it's a count of triples deleted, not a
  negative number), so callers using v0.1.0's `execute` see no
  behaviour change. Only the new arbitrary-UPDATE branch returns
  potentially-negative integers, and those callers are opting in.

#### Exit criteria

- Spec: `Sparql.execute("DELETE { ?s <p> ?o } WHERE { ?s <p>
  ?o }")` removes matching triples + returns
  `{ ok: true, count: -N }` where N is the number deleted.
- Spec: `Sparql.execute("INSERT { ?s <derived:p> "x" } WHERE
  { ?s <schema:type> <foo> }")` inserts derived triples; count
  matches.
- Spec: a mixed UPDATE (`DELETE { ... } INSERT { ... } WHERE
  { ... }`) returns the signed net delta.
- Spec: malformed UPDATE returns `:sparql_parse_error` refusal
  envelope; semantically-invalid UPDATE (e.g. naming a non-IRI
  predicate) returns `:sparql_eval_error` refusal envelope.
- Spec: `Sparql.execute("INSERT DATA { ... }")` still returns
  positive `:count:` via the existing fast path (no regression).

### Phase B — `Storable` lifecycle simplification

The hot path is `after_save`'s read-replace. With `sparql_update`
available, each predicate replacement collapses from `2 + N`
round-trips to a single UPDATE-with-WHERE round-trip:

```sparql
DELETE { <urn:mm:product:W3> <schema:name> ?o }
INSERT { <urn:mm:product:W3> <schema:name> "Renamed" }
WHERE  { OPTIONAL { <urn:mm:product:W3> <schema:name> ?o } }
```

Semantics:

- Atomic: the DELETE and INSERT happen in one engine pass.
- Idempotent: if no current value exists, the DELETE matches
  nothing and the INSERT still fires.
- nil → retraction: when the value lambda returns nil, emit
  `DELETE { <s> <p> ?o } WHERE { <s> <p> ?o }` (no INSERT). The
  existing nil-handling path stays, just gets simpler internally.

#### Implementation

- `Storable#replace_predicate!` is rewritten to compose the
  UPDATE-with-WHERE query and call `Sparql.execute`. The internal
  `retract_predicate!` helper survives only for the destroy path
  (delete all matching, no insert).
- `Storable` chooses its lifecycle implementation at boot via a
  runtime probe:

  ```ruby
  Semantica::Storable.dispatch_mode
  # => :sparql_update      (engine ≥ 0.5.0, sparql_update present)
  # => :bulk               (engine ≥ 0.4.0, rdf_insert_many present, no sparql_update)
  # => :per_call           (v0.2.0 baseline; INSERT DATA / DELETE DATA scalar)
  ```

  Probe: a single `SELECT sparql_update('SELECT ?s WHERE { ?s ?p ?o } LIMIT 0')`
  call on first emission; cache the result. Cheap one-shot
  detection. Operators can pin via `MM_SEMANTICA_DISPATCH_MODE` if
  they want predictable behaviour across upgrades.
- Multi-value predicates (the case PLAN_0.2.0 Phase B introduced
  via `each` blocks): the same single-query approach works —
  `DELETE { <s> <p> ?o } INSERT { <s> <p> "v1" . <s> <p> "v2" . ... }
  WHERE { OPTIONAL { ... } }`. One round-trip regardless of
  cardinality.

#### Exit criteria

- Spec: `Widget.create!` + `Widget.update!` round-trips via
  `:sparql_update` dispatch mode; behaviour identical to v0.2.0's
  per-call mode (same `Sparql.select` results, same destroy
  retraction).
- Spec: forcing `:per_call` mode via env var still works
  (back-compat for environments where the operator wants the
  v0.2.0 path).
- Spec: `:sparql_update` dispatch round-trips multi-value
  predicates (`each` block from PLAN_0.2.0 Phase B) in one
  UPDATE per predicate-iri group.
- Performance smoke: a benchmark spec asserts the
  `:sparql_update` mode issues ≤ 1 engine round-trip per declared
  predicate per save (vs. ≥ 2 + N for `:per_call`).

### Phase C — Contract additions

New pinned `:reason` symbol: `:sparql_eval_error`. Distinct from
`:sparql_parse_error` so callers can branch on "the query was
syntactically valid but referred to undefined predicates / bad
IRIs / etc." vs. "the query didn't parse." Engine surfaces this
distinction via the `SPARQL parse error:` vs. `SPARQL evaluation
error:` message prefix.

`Sparql.execute` `:count:` semantics widen from "unsigned count"
to "signed net delta when the query is an arbitrary UPDATE; same
unsigned positive count for the `INSERT DATA` / `DELETE DATA` /
`CLEAR ALL` fast paths." Document the widening in README +
CHANGELOG; mark in CONSUMER_REQUIREMENT_MM.md.

`Storable.dispatch_mode` is a new public reader. Pin its three
values (`:sparql_update`, `:bulk`, `:per_call`) as the v0.3.0
contract.

### Phase D — Specs + bin/check

- `spec/semantica/sparql_spec.rb` grows arbitrary-UPDATE
  round-trip cases (Phase A exit criteria above).
- `spec/semantica/storable_spec.rb` grows dispatch-mode coverage
  (Phase B exit criteria above).
- A new spec file `spec/semantica/dispatch_mode_spec.rb` covers
  the probe logic + env-var override + caching.
- `bin/check` stays the release gate — green against the live
  engine ≥ 0.5.0.

### Phase E — Docs

- `CHANGELOG.md` — per-phase entry; collected under `0.3.0` at
  release.
- `README.md` — `execute` section grows the arbitrary-UPDATE
  example + signed-delta semantics note. `dispatch_mode` reader
  documented.
- `CONSUMER_REQUIREMENT_MM.md` — note arbitrary UPDATE now
  available; document that Storable's internal dispatch may
  change without notice (operators only depend on the SPARQL-
  visible outcome, per the existing "Behaviours MM does NOT
  depend on" section — `:sparql_update` mode honours that).
- `docs/plans/PLAN_0.3.0.md` — update "Current state" as phases
  land.

## Out of scope for v0.3.0

- **SERVICE federation** (querying remote SPARQL endpoints). Even
  if the engine grows it, v0.3.0 doesn't surface it. Defer.
- **Transactional multi-statement UPDATE** (`UPDATE { ... } ;
  UPDATE { ... }` semicolon-chained). Per-call dispatch only; one
  query per `Sparql.execute` call. Defer.
- **Returning the actual deleted/inserted bindings** (some
  engines expose this; Oxigraph doesn't today). Defer.
- **Migration of `Sparql.execute("DELETE DATA")` to go through
  `sparql_update`.** The scalar fast paths stay because they're
  cheaper for the common case. Don't fix what isn't broken.

## v0.3.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Sparql.execute(arbitrary_sparql_update)` | envelope `{ ok:, count: <signed integer> }` | **Pinned.** Count is signed only for arbitrary UPDATE paths; the four fast paths still return positive counts. |
| Refusal `:reason:` symbol `:sparql_eval_error` | symbol | **Pinned.** |
| `Semantica::Storable.dispatch_mode` reader → `:sparql_update | :bulk | :per_call` | class method | **Pinned**; values list extensible. |
| `MM_SEMANTICA_DISPATCH_MODE` env var | string forcing one of the three modes | **Pinned**; lifetime ≥ v1.0. |

## Risks

| Risk | Mitigation |
|---|---|
| Engine `sparql_update` returns a signed delta in a SQLite scalar context where the consumer expected unsigned. | The engine's CONSUMER_REQUIREMENT_RS.md pins this contract at 0.5.0. RS coerces via `to_i`; signed Integer is native Ruby. No widening on the SQLite wire level — SQLite INTEGER carries signed 64-bit values natively. |
| Storable's dispatch-mode probe runs once + caches; if the engine version changes mid-process, the cached value goes stale. | Acceptable. SQLite extensions don't hot-reload; `load_extension` happens once per AR-connection thread. If operators swap dylibs mid-process they're in dragons-territory and Storable's cache is the least of their concerns. |
| Operators relying on the v0.1.0 `execute("DELETE DATA")` `:count:` being a positive integer get surprised when v0.3.0 starts returning negatives for arbitrary UPDATE. | The DATA forms still return positives — only opt-in arbitrary UPDATE paths return signed. Document in CHANGELOG; the surface contract additions table is the canonical reference. |
| Phase B's UPDATE-with-WHERE composition gets the WHERE clause subtly wrong (e.g. missing OPTIONAL when there's no current value), losing the new insert. | Spec: cover the "predicate not yet present" path explicitly. Use `OPTIONAL { ... }` so the WHERE always has a solution. |
| `:bulk` dispatch mode (PLAN_0.2.0 Phase E) and `:sparql_update` mode coexist in the dispatch-mode probe — neither obviously dominates. | Document the choice ladder: `:sparql_update` is preferred when present (more declarative, atomic per predicate); `:bulk` is the fallback when `sparql_update` isn't available but `rdf_insert_many` is; `:per_call` is the v0.2.0 baseline. Operators forcing a mode via env var override the ladder. |

## Acceptance signal

When all phases land:

1. `Sparql.execute` round-trips arbitrary SPARQL 1.1 UPDATE forms
   against engine ≥ 0.5.0.
2. `Storable` lifecycle hooks dispatch via `:sparql_update` by
   default; the v0.2.0 `:per_call` and `:bulk` modes survive as
   forced-via-env-var fallbacks.
3. `bin/check` passes green against engine 0.5.0+.
4. CHANGELOG `0.3.0` heading drops the `(unreleased)` qualifier.
5. The root `VERSION` file bumps to `0.3.0`. The version constant
   is read from there by `lib/semantica/version.rb` (substrate
   convention; reconciled prior to v0.3.0 work).
6. CONSUMER_REQUIREMENT_MM.md graduates "arbitrary SPARQL UPDATE"
   from absence into a documented surface.

## Cross-references

- `./PLAN_0.1.0.md` — the dispatcher whose `else` branch v0.3.0
  retires.
- `./PLAN_0.2.0.md` Phase E — bulk write path; coexists with
  `:sparql_update` in `Storable.dispatch_mode`.
- Engine repo `laquereric/sqlite-sparql` 0.5.0 — the prerequisite
  release.
- `magentic-market-ai/docs/plans/PLAN_0_29_x` — substrate
  consumes the new dispatch path transparently; no substrate-side
  plan needed.
