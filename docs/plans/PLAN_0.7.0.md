# PLAN_0.7.0 — `rails-semantica` ethereal graphs via Active Storage

> *Wraps named graphs in a Rails-lifecycle-managed concern. Each
> `EtherealGraph`-bearing AR record carries an Active Storage blob
> holding that graph's N-Triples; first SPARQL touch hydrates the
> blob into the engine's in-memory store, an explicit checkpoint
> flushes back, destroying the record retracts the graph + purges
> the blob. Lets operators scope graphs to Rails domain objects
> (Sessions, Tenants, Workspaces) with standard Active Storage
> durability + per-graph per-blob lifetime — without coupling the
> engine to a second persistent store.*

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `PLAN_0.5.0.md` | this dir | Named-graph surface ethereal graphs build on. `graph:` kwarg + `graph "…"` DSL. |
| `PLAN_0.4.0.md` | this dir | `bulk_insert(raw: true)` is the engine-side hydration target — one FFI crossing per batch of N-Triples lines. |
| `PLAN_0.6.0.md` | this dir | Shared-store posture: hydrate-once-per-process serves every connection / thread. Concurrency note constrains checkpoint discipline. |
| Active Storage docs | Rails | `has_one_attached` + `ActiveStorage::Blob` for the durability backbone. Operators must have the standard `active_storage_blobs` / `active_storage_attachments` migration. |

## Engine surface (no engine work)

v0.7.0 is purely gem-internal. The existing engine surfaces serve:

- `rdf_insert_many` — hydration target (Phase A).
- `sparql_construct(graph: …)` — dehydration source (Phase B).
- `sparql_update("CLEAR GRAPH <…>")` — retraction target (Phase C).

## Current state baseline (v0.6.0)

- Named graphs are first-class but unmanaged: operators emit with
  `graph: "urn:…"` (`Sparql.execute` / `bulk_insert`) or via the
  `graph "…"` DSL on `Storable`. The engine holds them in the
  process-wide store; process death wipes them.
- No declarative way to say "this graph belongs to *this* AR
  record's lifetime; persist it across restarts; collect it when
  the record is destroyed."
- Operators wanting persistence today dump/load N-Triples by hand.

## Scope

### Phase A — `Semantica::EtherealGraph` concern + hydration

DSL:

```ruby
class WorkspaceContext < ApplicationRecord
  include Semantica::EtherealGraph

  ethereal_graph do
    iri              -> { "urn:mm:workspace:#{id}:context" }
    checkpoint_on    :explicit       # :explicit (default) | :save
  end
end
```

The concern auto-registers `has_one_attached :semantica_graph_blob`.

#### Implementation
- `Semantica::EtherealGraph` = `ActiveSupport::Concern`.
- `included do; has_one_attached :semantica_graph_blob; end`.
- `class_attribute :semantica_ethereal_declaration`.
- `Recorder` (`Semantica::EtherealGraph::Recorder`) captures
  `iri_lambda` + `checkpoint_on`; finalizes to a frozen
  `Declaration` struct.
- Process-wide hydration cache:
  `Semantica::EtherealGraph::HYDRATED_IRIS = Set.new` (mutex-
  guarded). Pin operators force-clear via `evict!(iri)` for
  multi-process edge cases.
- Instance method `#hydrate_ethereal_graph!`:
  1. `iri = instance_exec(&decl.iri_lambda)`.
  2. Skip if `HYDRATED_IRIS.include?(iri)`.
  3. Skip with `{ ok: true, hydrated: 0, reason: :no_blob }` if
     `semantica_graph_blob.attached?` is false.
  4. `blob_text = semantica_graph_blob.download`.
  5. Parse N-Triples lines → batch rows for
     `Sparql.bulk_insert(rows, raw: true)`; chunk at 1000 lines.
  6. Mark IRI hydrated.
  7. Return `{ ok: true, hydrated: <integer> }`.

#### Exit criteria
- Spec: a `WorkspaceContext` with an N-Triples blob attached →
  `.hydrate_ethereal_graph!` returns `ok: true, hydrated: N`; the
  triples are queryable via `Sparql.select(..., graph: iri)`.
- Spec: re-hydration is a no-op (`hydrated: 0` second call).
- Spec: a record without a blob attached returns
  `{ ok: true, hydrated: 0, reason: :no_blob }` and skips engine
  calls entirely.
- Spec: malformed blob lines refuse via the existing
  `bulk_insert` abort-batch envelope; the partial-hydration
  flag stays cleared (HYDRATED_IRIS does *not* include the IRI
  after a failed hydrate).

### Phase B — Checkpoint discipline

```ruby
ctx.checkpoint_ethereal_graph!
# => { ok: true, written: <byte_count> }
```

Plus the `checkpoint_on: :save` mode auto-registers an
`after_save` callback that flushes after every successful save.

#### Implementation
- Instance method `#checkpoint_ethereal_graph!`:
  1. `iri = instance_exec(&decl.iri_lambda)`.
  2. `Sparql.construct("CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }", graph: iri)`
     → N-Triples string.
  3. Detach any existing blob; attach a new
     `ActiveStorage::Blob` built from the string (filename
     `<iri-slug>.nt`, content type `application/n-triples`).
  4. Return envelope.
- `Recorder#checkpoint_on(mode)` writes to declaration; the
  concern's `included` block conditionally registers
  `after_save :checkpoint_ethereal_graph!` when the declaration
  asks for `:save`.

#### Exit criteria
- Spec: hydrate → mutate via `Sparql.execute` → checkpoint → call
  `evict!(iri)` to simulate process restart → re-hydrate → all
  mutations survive.
- Spec: empty-graph checkpoint produces a 0-byte blob; subsequent
  re-hydration is a no-op without engine writes.
- Spec: `checkpoint_on: :save` auto-flushes after `update!`.

### Phase C — Destroy semantics (graph retraction)

When the AR record is destroyed, drop the graph from the engine
and let Active Storage purge the blob.

#### Implementation
- The concern registers `before_destroy :retract_ethereal_graph!`.
- `#retract_ethereal_graph!`:
  1. `iri = instance_exec(&decl.iri_lambda)`.
  2. `Sparql.execute("CLEAR GRAPH <#{iri}>")` (routes through
     PLAN_0.3.0's arbitrary-UPDATE path).
  3. `HYDRATED_IRIS.delete(iri)`.
  4. Active Storage's `has_one_attached` defaults to
     `dependent: :purge_later`; the blob purges with the record.
  5. Return envelope.

#### Exit criteria
- Spec: destroy an ethereal-graph-attached record → graph IRI is
  empty in the engine; the attached blob is purged.
- Spec: destruction retracts only the named graph; default-graph
  triples + other named-graph triples at the same subject IRI
  survive.

### Phase D — Storable composition

If the same AR model `include Semantica::Storable` + `include
Semantica::EtherealGraph` and the Storable's `graph "…"`
declaration matches the EtherealGraph's `iri` lambda, the two
compose cleanly:

- The EtherealGraph's `before_save` hook (registered when
  `checkpoint_on: :save`) runs *after* Storable's emit (default
  AS callback ordering); the checkpoint then captures the
  Storable-emitted state.
- Lifecycle on first save of a fresh record: emit → checkpoint
  (writes blob).
- Lifecycle on update of a re-hydrated record: hydrate (explicit
  caller responsibility) → emit (replace_predicate via
  `:sparql_update` dispatch) → checkpoint.
- Destroy fires `retract` on both concerns in callback order; the
  net effect is the graph empties twice (once via Storable's
  `after_destroy`, once via EtherealGraph's `before_destroy`).
  Idempotent at the engine level; no semantic issue.

No new code in Phase D — the composition is what falls out of
A + B + C. Phase D's deliverable is the composition spec + the
documented gotchas.

#### Exit criteria
- Spec: a `Storable + EtherealGraph` model round-trips create →
  evict (simulate restart) → re-hydrate → SPARQL queries see
  every Storable-emitted predicate.
- Spec: callback ordering documented; the spec asserts checkpoint
  fires after Storable's `after_save`.

### Phase E — Specs + bin/check
- New file `spec/semantica/ethereal_graph_spec.rb` covering
  Phases A/B/C/D exit criteria.
- `bin/check` green.

### Phase F — Docs
- `CHANGELOG.md` — `0.7.0` heading with per-phase entries.
- `README.md` — new "Ethereal graphs" section with the
  `WorkspaceContext` example + the hydrate/checkpoint/destroy
  lifecycle diagram.
- `CONSUMER_REQUIREMENT_MM.md` — note the new optional surface;
  MM may consume for Workspace/Session/Tenant-lifetime graphs.
- `docs/plans/PLAN_0.7.0.md` — this file. Update "Current state"
  as phases land.
- `VERSION` → `0.7.0`.

## Out of scope for v0.7.0

- **Multi-process coordination.** Process A's checkpoint vs.
  process B's stale `HYDRATED_IRIS` cache: last-writer-wins; no
  cache invalidation across processes. Document loudly.
- **Automatic dirty-tracking → checkpoint.** Magical and
  expensive (would have to instrument every `Sparql.execute`).
  v0.7.0 ships explicit `checkpoint_ethereal_graph!` + opt-in
  `checkpoint_on: :save`.
- **Lazy hydration on `Sparql.select(graph: …)`.** Implicit
  hydration would need a registry mapping IRIs back to AR
  records; that's a v0.7.x candidate if the explicit-call shape
  proves cumbersome.
- **Format negotiation.** v0.7.0 ships N-Triples only.
  Turtle / N-Quads / JSON-LD are post-v0.7.0 if MM signals demand.
- **Cache eviction policy.** `HYDRATED_IRIS` grows for the
  process lifetime. Operators wanting GC call `evict!(iri)`
  manually.
- **Concurrent-checkpoint protection.** Two threads checkpointing
  the same graph simultaneously: last-writer-wins. Per-instance
  Mutex is a v0.7.x candidate if real demand surfaces.

## v0.7.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `include Semantica::EtherealGraph` | concern | **Pinned.** |
| `ethereal_graph do; iri ->{...}; checkpoint_on :explicit_or_:save; end` | DSL | **Pinned.** |
| `has_one_attached :semantica_graph_blob` (auto) | Active Storage attachment | **Pinned name.** |
| `#hydrate_ethereal_graph!` → `{ ok:, hydrated: <integer>, reason?: :no_blob }` | instance method | **Pinned.** Idempotent. |
| `#checkpoint_ethereal_graph!` → `{ ok:, written: <byte_count> }` | instance method | **Pinned.** |
| `#retract_ethereal_graph!` → envelope | instance method | **Pinned.** |
| `Semantica::EtherealGraph.evict!(iri)` | module method | **Pinned escape hatch.** |
| `HYDRATED_IRIS` (set) | process-wide cache | **Internal**; do not introspect. |

No new `:reason:` symbols; existing envelope semantics cover the
failure modes (`:ar_connection_error`, `:extension_not_loaded`,
`:sparql_parse_error` for malformed-blob refusals via
`bulk_insert`).

## Risks

| Risk | Mitigation |
|---|---|
| Hydration parses N-Triples line-by-line — slow for large graphs. | `bulk_insert` chunks at 1000 lines per FFI crossing; benchmark in Phase E if needed. |
| `HYDRATED_IRIS` cache grows forever. | Acceptable for v0.7.0; `evict!` escape hatch for long-running processes. |
| Storable composition callback order is fragile. | Spec asserts the order; if AS reorders callbacks under us, the spec fails first. |
| Operators forget to checkpoint after Sparql.execute mutations — process restart loses data. | Document. `checkpoint_on: :save` covers the Storable-only case; ad-hoc Sparql.execute mutations are the operator's responsibility. |
| Blob format lock-in (N-Triples). | The blob is operator-visible — they can transcode later if format evolves. Pin shape, leave format extensible. |
| Two processes mutating the same graph race their blob writes. | Single-process is the v0.7.0 contract. Document. |

## Acceptance signal

1. Phases A/B/C land with passing specs; Phase D composition spec
   pins callback ordering.
2. `bin/check` green against engine ≥ 0.5.0 (current pin).
3. CHANGELOG `0.7.0` heading drops `(unreleased)`.
4. `VERSION` → `0.7.0`.
5. README documents the EtherealGraph surface.
6. CONSUMER_REQUIREMENT_MM.md notes the new optional surface.

## Cross-references

- `./PLAN_0.4.0.md` — `bulk_insert(raw: true)` hydration target.
- `./PLAN_0.5.0.md` — named-graph DSL the concern builds on.
- `./PLAN_0.6.0.md` — shared-store posture: hydrate-once-per-process
  is correct; checkpoint discipline is the operator's responsibility.
- Active Storage documentation — `has_one_attached`, blob purge
  semantics.
