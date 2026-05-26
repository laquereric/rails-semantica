# PLAN_0.14.0 — `Vv::Graph::Storage` (configurable graph storage via Active Storage)

> *PLAN_0.7.0 shipped `Vv::Graph::EtherealGraph` — per-AR-record
> named graphs backed by an Active Storage attachment. That
> shape works when every named graph is owned by exactly one AR
> record (`WorkspaceContext`, `Workspace`, `Tenant`). The shape
> **breaks** the moment operators want: a shared schema graph
> owned by no AR record; the Rails-app database purged and
> restored to a different SQLite file; the engine's full
> named-graph state snapshotted to S3 for backup; a fresh
> developer machine hydrating its engine from a teammate's
> snapshot; the same Rails app moving between local disk / memory
> / S3 backends with one config flip.*
>
> *PLAN_0.14.0 introduces **`Vv::Graph::Storage`** — a
> gem-level facade for the graph-storage layer that uses Active
> Storage as the RDBMS ↔ object-store bridge. Operators
> configure once (via `config/storage.yml` like any Rails app);
> the gem snapshots the engine's named-graph state into blobs
> on the configured service (local / memory / S3 / GCS / Azure
> — every Active Storage backend) and restores it on demand.
> The 'strange' lifecycles — collect graphs, purge RDBMS, restore
> to a new RDBMS — become first-class workflows: a
> `Storage.snapshot_all` writes a manifest + per-graph blobs;
> `Storage.restore_all` reads them back into a freshly-empty
> engine.*
>
> *EtherealGraph stays — its per-AR-record shape is the right
> ergonomic for AR-coupled scopes. `Vv::Graph::Storage` is the
> **gem-wide** sibling: snapshot/restore semantics for the
> entire engine, ar-coupled and standalone graphs alike, with
> a unified manifest.*

## Current state

**Draft.** No code written. v0.13.0's 314-spec suite continues to
pass; v0.14.0 adds ~30–40 specs across phases. No engine pin
change.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `PLAN_0.7.0.md` | this dir | EtherealGraph — the per-AR-record blob durability model `Storage` generalises. EtherealGraph stays for AR-coupled scopes; `Storage` adds gem-wide snapshot/restore + standalone graphs. |
| `PLAN_0.5.0.md` | this dir | Named graphs — every graph `Storage` snapshots is identified by a named-graph IRI. The `graph:` kwarg + `graph "..."` DSL drive what gets snapshotted. |
| `PLAN_0.6.0.md` | this dir | `Sparql.store_size(graph: …)` is the size-reporting helper `Storage.list` decorates with byte-count info. |
| `PLAN_0.13.0.md` | this dir | `Vv::Graph::Scope` value object — `Storage.snapshot_scope(scope:)` ships the per-scope selective snapshot built on Scope's five-role partitioning. |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | MM substrate's consumption surface. Multi-tenant Workspace / Tenant scopes want per-tenant snapshot/restore; this plan formalises the surface. |
| `CONSUMER_REQUIREMENT_VV.md` | this repo | vv-memory's consumption surface. The Conformer Writer accumulates Silver-tier scoped graphs that must survive process restarts (B1 is the per-record blob case; this plan adds the engine-wide case for shared scope-independent graphs). |
| ActiveStorage docs (Rails 8) | external | Configured via `config/storage.yml` + `config.active_storage.service = :name`. Built-in Disk / Test / S3 / GCS / Azure services; operators-as-third-party services compose. |
| W3C SPARQL 1.1 — graph enumeration | spec | `SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }` — the engine surface `Storage.list_graphs_in_engine` drives. Oxigraph handles natively. |

## Engine prerequisites (sqlite-sparql ≥ 0.9.1) — **already satisfied**

**No new engine surface.** Every operation rides existing facades:

- **Graph enumeration** — `SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }` via `Sparql.select`.
- **Per-graph serialisation** — `Sparql.construct("CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }", graph: iri)` returns N-Triples (plain or N-Triples-star post v0.13.0 split_ntriple fix).
- **Per-graph restoration** — Parse the blob via `Sparql.split_ntriple` (PLAN_0.13.0 Phase B's balanced-bracket version handles quoted triples), feed into `Sparql.bulk_insert(rows, raw: true)` with the target IRI as the graph column.
- **Empty-graph reset** — `Sparql.execute("CLEAR GRAPH <iri>")` for selective; `Sparql.execute("CLEAR ALL")` for nuclear pre-restore reset.
- **Default-graph handling** — the engine treats `nil` as the default graph; `Storage` maps it to the manifest entry `"@default"` (a JSON sentinel — not a valid IRI, so no collision risk).

The Rails-side Active Storage stack is the only new dependency
surface — and that's a Rails 8 standard library that operators
already use for any file attachment in their app.

## Concept — what `Vv::Graph::Storage` is

A small facade plus a manifest plus configuration plumbing.

**Configuration** — Operator declares an Active Storage service
in `config/storage.yml` (any of Disk / Test / S3 / GCS / Azure)
and points the gem at it via the `service:` config key.

**Manifest** — A single JSON document stored at a fixed key in
the configured service. Maps every named graph IRI to its
current blob (key + byte size + content type + optional AR
backing reference). Operators don't author the manifest; the
gem writes it on every `snapshot_all`.

**Blobs** — One N-Triples (or N-Triples-star) blob per named
graph. Content type `application/n-triples` (or
`application/n-triples-star` post-v0.13.0). Blob keys are
content-addressed (SHA-256 over the body) so identical graph
state across snapshots produces the same blob — useful for
incremental backups (Active Storage's `record_attached_to` /
`blob_id` plumbing handles dedup if the same blob is referenced
twice).

**Operations** — Three verb families, each accepting an
optional `scope:` (PLAN_0.13.0) for selective scoping:

1. **`snapshot_*`** — Read engine state → write to Active Storage.
2. **`restore_*`** — Read from Active Storage → write engine state.
3. **`list`** / **`diff`** / **`prune`** — Inspect the
   relationship between engine state and storage state.

## Configuration shape

```ruby
# config/initializers/semantica.rb (operator app)
Vv::Graph::Storage.configure do |config|
  # Active Storage service name (matches a key in config/storage.yml).
  config.service = Rails.env.production? ? :semantica_graphs_s3
                                         : :semantica_graphs_local

  # Where the manifest blob lives, relative to the service root.
  # JSONL format — one JSON object per line (header + per-graph
  # entries); see "Manifest format" below.
  config.manifest_key = "semantica/manifest.jsonl"

  # Blob serialisation format. v0.14.0 ships :ntriples (RDF 1.1)
  # and :ntriples_star (RDF-star, requires engine ≥ 0.7.0). Future
  # :nquads candidate is documented but out of scope.
  config.format = :ntriples_star

  # Optional namespace prefix for blob keys; useful for shared
  # services where multiple Rails apps write to the same bucket.
  config.key_prefix = "myapp/"
end
```

```yaml
# config/storage.yml — operator's Rails app

# Local disk for development
semantica_graphs_local:
  service: Disk
  root: <%= Rails.root.join("storage", "semantica") %>

# Test backend (memory; cleared per spec)
semantica_graphs_test:
  service: Test

# Production S3
semantica_graphs_s3:
  service: S3
  access_key_id:     <%= ENV["AWS_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["AWS_SECRET_ACCESS_KEY"] %>
  region:            <%= ENV["AWS_REGION"] %>
  bucket:            myapp-semantica-graphs
```

The gem itself ships zero hardcoded backend wiring — every
service mention rides Active Storage's existing
`ActiveStorage::Service.configurations[name]` lookup. Adding
GCS / Azure / a custom service is purely a `storage.yml` edit
on the operator's side; the gem sees only the configured
service name.

## Manifest format (pinned at v0.14.0)

**JSONL** — one JSON object per line. First line is the header
record (carries the manifest's global metadata + schema version);
every subsequent line is a per-graph entry. The `"type"` key
discriminates header vs. entry records. Filename:
`manifest.jsonl`.

```jsonl
{"type":"manifest_header","version":1,"snapshotted_at":"2026-05-25T14:23:00Z","engine_version":"0.8.0","format":"ntriples_star","key_prefix":"myapp/"}
{"type":"graph","iri":"urn:mm:graph:shared:schema","blob_key":"myapp/semantica/3a7f9c.nt","byte_size":14829,"triple_count":421,"ethereal":false,"snapshotted_at":"2026-05-25T14:23:00Z"}
{"type":"graph","iri":"urn:mm:workspace:42:silver","blob_key":"myapp/semantica/8b2e1a.nt","byte_size":8231,"triple_count":197,"ethereal":true,"ar_class":"Workspace","ar_id":42,"snapshotted_at":"2026-05-25T14:23:00Z"}
{"type":"graph","iri":"@default","blob_key":"myapp/semantica/default.nt","byte_size":1024,"triple_count":23,"ethereal":false,"snapshotted_at":"2026-05-25T14:23:00Z"}
```

### Why JSONL (not a single JSON document)

- **Streaming reads.** A 10k-graph manifest stays out of memory
  during restore — `read_manifest` yields each `GraphEntry`
  lazily via `each_line.lazy.map { JSON.parse(_1) }`. The whole
  manifest is never assembled.
- **Append-only friendly.** Per-graph snapshots (`snapshot_graph`)
  can append a single line to the existing manifest rather than
  rewriting the whole document. (v0.14.0 still rewrites
  whole-manifest on `snapshot_all` for simplicity; the
  append-mode optimisation is a v0.15.0+ candidate gated on
  telemetry.)
- **Operator tooling.** Easy to `tail -f` an in-progress
  snapshot, `grep` for a specific graph IRI, `jq -c`-process a
  subset, or `comm` two manifests for diff. Each line is
  individually-valid JSON.
- **Robust to partial reads.** A corrupted manifest with N good
  lines + a malformed line 51 surfaces "lines 1–50 valid, line
  51 corrupt at byte X" — operators recover the readable
  subset. Single-JSON-document manifests with a corrupt trailing
  brace lose the whole thing.
- **Per-line schema validation.** Each line independently
  validates against its `type:`'s pinned shape; errors localise
  to a line number.

### Header record (`type: "manifest_header"`)

Exactly one per manifest; must be the first line.

| Key | Required | Notes |
|---|---|---|
| `type` | yes | Always `"manifest_header"`. |
| `version` | yes | Manifest schema version (integer). v0.14.0 ships `1`; future schema changes bump + provide a `restore_all` upgrade path. |
| `snapshotted_at` | yes | ISO-8601 UTC of when the snapshot started. |
| `engine_version` | yes | Captured from `Loader.engine_version` at snapshot time. Restore against an older engine warns; against a newer engine proceeds. |
| `format` | yes | `"ntriples"` \| `"ntriples_star"`. Mismatch with the current engine surface refuses (`:format_unsupported`). |
| `key_prefix` | yes | Service-key prefix used by every blob in this manifest. Empty string allowed. |

### Graph entry record (`type: "graph"`)

One per named graph + optionally one per default-graph (`iri:
"@default"`).

| Key | Required | Notes |
|---|---|---|
| `type` | yes | Always `"graph"`. |
| `iri` | yes | Full named-graph IRI, OR the sentinel `"@default"` for the default graph. |
| `blob_key` | yes | Service-relative key for this graph's blob. |
| `byte_size` | yes | Blob size in bytes. |
| `triple_count` | yes | Number of triples in this graph at snapshot time. |
| `ethereal` | yes | `true` if the graph is currently attached to an AR record via `EtherealGraph`. Restore routes through the record's `hydrate_ethereal_graph!`; for standalone, direct bulk-insert. |
| `ar_class` | only if `ethereal: true` | AR class name (string) the graph is attached to. |
| `ar_id` | only if `ethereal: true` | AR record ID. |
| `snapshotted_at` | yes | ISO-8601 UTC of when *this graph* was snapshotted (may differ from the header's `snapshotted_at` if append-mode landed). |

### Future record types (forward-compat)

`read_manifest` ignores lines whose `type:` it doesn't recognise
(forward-compat for future schemas). Examples reserved for
future use:

- `type: "comment"` — operator-authored comment line; ignored.
- `type: "checksum"` — appended last; carries SHA-256 of all
  prior lines. (v0.15.0+ candidate for verify-on-restore.)
- `type: "blob_orphan"` — flag a blob known to be orphaned for
  later pruning. (v0.15.0+ candidate.)

Unknown `type:` values **do not** refuse — they're skipped with
an `unknown_record_types: [...]` entry in the read envelope's
diagnostics. Operators see drift; restore continues.

## Gem-side scope

### Phase A — `Vv::Graph::Storage` facade + `configure` block + manifest types

The bones. Configuration plumbing + value objects + the
line-streaming JSONL manifest read/write path.

```ruby
module Semantica
  module Storage
    Configuration = Struct.new(:service, :manifest_key, :format, :key_prefix, keyword_init: true)
    GraphEntry    = Struct.new(:iri, :blob_key, :byte_size, :triple_count,
                               :ethereal, :ar_class, :ar_id, :snapshotted_at,
                               keyword_init: true) do
      def to_jsonl
        ::JSON.generate(to_h.compact.merge(type: "graph"))
      end
    end
    ManifestHeader = Struct.new(:version, :snapshotted_at, :engine_version,
                                :format, :key_prefix, keyword_init: true) do
      def to_jsonl
        ::JSON.generate(to_h.merge(type: "manifest_header"))
      end
    end
    # Manifest is a header + a lazy/eager Array of GraphEntry. The
    # `graphs:` field accepts either Array<GraphEntry> (eager) or
    # an Enumerator yielding GraphEntry (lazy, for streaming reads).
    Manifest = Struct.new(:header, :graphs, :unknown_record_types, keyword_init: true)

    module_function

    def configure
      @configuration ||= Configuration.new(
        service:      :semantica_graphs,
        manifest_key: "semantica/manifest.jsonl",
        format:       :ntriples,
        key_prefix:   "",
      )
      yield @configuration if block_given?
      @configuration.freeze
    end

    def configuration
      @configuration ||= configure
    end

    def service
      ::ActiveStorage::Blob.services.fetch(configuration.service)
    rescue KeyError
      raise UnconfiguredService,
            "Active Storage service #{configuration.service.inspect} not found in config/storage.yml; " \
              "configure via Vv::Graph::Storage.configure { |c| c.service = :your_service }"
    end
  end
end
```

#### Refusal envelope additions
- `:storage_unconfigured` — `service:` config key names a
  service not declared in `config/storage.yml`.
- `:active_storage_missing` — `ActiveStorage::Blob` constant
  not defined; the operator hasn't added `activestorage` to
  their Gemfile.
- `:format_unsupported` — manifest declares
  `format: "ntriples_star"` but `Vv::Graph.checkpoint_can_round_trip?(content_kind: :ntriples_star)` returns false.
- `:manifest_parse_error` — manifest blob exists but a
  line fails JSON parse, OR the first non-blank line isn't a
  `type: "manifest_header"` record. The `because:` clause
  names the offending line number.
- `:manifest_version_unsupported` — manifest `"version"`
  greater than `Vv::Graph::Storage::CURRENT_MANIFEST_VERSION`.

#### Exit criteria
- Spec: default configuration shape pinned.
- Spec: `Vv::Graph::Storage.configure { |c| c.service = :nope }`
  followed by a call refuses `:storage_unconfigured`.
- Spec: `:format_unsupported` fires when the engine doesn't
  round-trip the configured format.
- Spec: Manifest serialise → deserialise round-trips through JSON.

### Phase B — Per-graph snapshot + restore

The two single-graph operations.

```ruby
# Snapshot a single named graph (or the default graph via nil/`"@default"`).
result = Vv::Graph::Storage.snapshot_graph("urn:mm:graph:shared:schema")
# => { ok: true, iri: "...", blob_key: "...", byte_size: 14829,
#      triple_count: 421 }

# Restore a single graph from its blob. If the blob doesn't exist,
# refuses with :blob_missing.
result = Vv::Graph::Storage.restore_graph("urn:mm:graph:shared:schema")
# => { ok: true, iri: "...", triple_count: 421, mode: :standalone }
```

#### Implementation
- `snapshot_graph(iri, format: nil)`:
  1. `format ||= configuration.format`
  2. Refuse `:format_unsupported` if engine can't round-trip.
  3. `ntriples = Sparql.construct("CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }", graph: iri)[:ntriples]`
  4. Compute `blob_key = "#{key_prefix}semantica/#{sha256(ntriples)}.nt"`.
  5. Upload via Active Storage:
     ```ruby
     io = StringIO.new(ntriples)
     blob = ActiveStorage::Blob.create_and_upload!(
       io: io, filename: "graph.nt",
       content_type: "application/n-triples",
       service_name: configuration.service,
       key: blob_key,
     )
     ```
  6. Return envelope with `triple_count: ntriples.lines.count`.
- `restore_graph(iri, blob: nil, mode: :auto)`:
  1. If `blob:` given, use it. Otherwise read the manifest +
     find the entry for `iri`; refuse `:blob_missing` if
     manifest entry missing.
  2. `ntriples = blob.download`.
  3. Restore mode:
     - `:auto` — if manifest entry has `ethereal: true`, locate
       the AR record via `ar_class.find(ar_id)` and call
       `record.hydrate_ethereal_graph!` (which already handles
       blob attachment + parse). Otherwise direct
       `bulk_insert` (standalone mode).
     - `:standalone` — always direct `bulk_insert`, even if
       manifest says ethereal.
     - `:ethereal` — always route via the AR record; refuses
       `:ethereal_record_missing` if the AR record can't be
       found.
  4. Direct restoration path:
     ```ruby
     rows = parse_ntriples_to_rows(ntriples, target_graph: iri)
     Sparql.bulk_insert(rows, raw: true)
     ```
- The default graph maps to manifest entry IRI `"@default"`;
  internally `graph: nil` for the Sparql calls.

#### Refusal envelope additions
- `:blob_missing` — manifest lacks an entry for the IRI.
- `:ethereal_record_missing` — manifest entry says
  `ethereal: true` but `ar_class.find(ar_id)` raises
  `ActiveRecord::RecordNotFound`. Distinct from
  `:blob_missing` so operators can decide whether to
  fall back to `:standalone` restore.

#### Exit criteria
- Spec: snapshot a populated graph → restore it into an
  empty engine → triple-set equality.
- Spec: snapshot includes RDF-star content (annotation triples)
  → restore round-trips through the v0.13.0 N-Triples-star
  parser without loss.
- Spec: restore an ethereal graph hydrates via the AR
  record's path.
- Spec: restoring against a non-empty engine merges
  additively (`Sparql.bulk_insert`'s set semantics dedupe).

### Phase C — `snapshot_all` + `restore_all` + manifest read/write

The bulk operations + the manifest blob itself.

```ruby
# Snapshot every named graph + default graph in the engine to the
# configured service, writing a fresh manifest.
result = Vv::Graph::Storage.snapshot_all
# => { ok: true, snapshotted: 7, manifest_key: "...",
#      graphs: [GraphEntry, GraphEntry, ...] }

# Restore every graph in the manifest into the engine. Engine
# pre-state isn't cleared automatically; pass `reset: true` for
# a CLEAR ALL first (the "purge RDBMS, restore from blobs" path).
result = Vv::Graph::Storage.restore_all(reset: true)
# => { ok: true, restored: 7, graphs: [...], reset_engine: true }
```

#### Implementation
- `snapshot_all(scope: nil, format: nil)`:
  1. Build a `StringIO` for the JSONL manifest body.
  2. Write the `ManifestHeader` line first
     (`io.puts(header.to_jsonl)`).
  3. Enumerate every named graph in the engine via
     `Sparql.select("SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }")`.
  4. Append the default graph entry if
     `Sparql.store_size(graph: nil)[:count] > 0`.
  5. For each, call `snapshot_graph(iri)` and append the
     `GraphEntry` line to the manifest IO
     (`io.puts(entry.to_jsonl)`). Lines streamed as they're
     produced — memory bounded by the largest graph's
     N-Triples body, not the whole manifest.
  6. For each ethereal graph (`HYDRATED_IRIS` set or
     `WorkspaceContext.find_each` etc. — operators register
     ethereal-bearing classes via `register_ethereal_class`,
     see Phase D), the GraphEntry is enriched with `ar_class:` +
     `ar_id:` before write.
  7. Upload manifest blob via Active Storage at
     `configuration.manifest_key` (content type
     `application/x-ndjson` — the W3C MIME type for JSONL).
  8. `scope:` kwarg restricts to a single Scope's read_graphs +
     write_graphs.
- `restore_all(reset: false, mode: :auto)`:
  1. Download manifest blob; stream-parse line-by-line via
     `each_line.lazy`. First non-blank line must be the
     `manifest_header` record; subsequent lines are
     graph entries (or unknown future record types — see
     "Future record types" above).
  2. Refuse `:manifest_version_unsupported` if header
     `version > CURRENT_MANIFEST_VERSION`.
  3. Refuse `:manifest_parse_error` (with line number) if any
     line fails JSON parse OR if the first non-blank line isn't
     the header. Per-graph-entry parse errors collect into
     `failures: [{ line: N, ... }]` rather than aborting —
     partial-restore semantics so a single corrupt line
     doesn't halt the whole restore.
  4. If `reset: true`, `Sparql.execute("CLEAR ALL")`.
  5. For each `type: "graph"` line, `restore_graph(iri,
     mode: mode)`. Per-graph failures append to
     `failures: [...]`.
  6. Return aggregate envelope; `unknown_record_types: [...]`
     captures any forward-compat record-type entries the
     restore skipped.

#### The "strange lifecycle" — purge + restore — pinned

```ruby
# Day 1 — Engine accumulates state through normal operation:
Workspace.create!(...)             # → EtherealGraph + emissions
Vv::Graph::Reasoner.materialise!(scope: my_scope)
# ...

# Day 2 — Take a snapshot. Manifest + blobs land on S3 (or local disk).
Vv::Graph::Storage.snapshot_all
# => { ok: true, snapshotted: 23, ... }

# Day 3 — The Rails app's RDBMS gets purged.
#   - `rails db:drop && rails db:create && rails db:migrate`
#   - OR a fresh dev machine starts from zero.
#   - The engine's in-memory state is gone.
#   - ActiveRecord tables are empty.
#   - The Active Storage blobs (S3 / local disk) survive.

# Day 4 — Restore against the fresh empty RDBMS:
Vv::Graph::Storage.restore_all(reset: true)
# => { ok: true, restored: 23, reset_engine: true,
#      failures: [...] (e.g., ethereal graphs whose AR records
#                       can't be found — see Phase D) }
```

The ethereal-graph subset is the trickiest case. After the
RDBMS purge, the AR records that *owned* those graphs no longer
exist. Phase D documents two recovery paths.

#### Exit criteria
- Spec: snapshot_all → CLEAR ALL → restore_all reconstructs
  the engine's full named-graph state (triple-set equality
  across every graph).
- Spec: scope-restricted snapshot only writes the scope's
  graphs to the manifest.
- Spec: restore_all with `reset: false` is additive (existing
  engine triples preserved).
- Spec: manifest with an unknown future `version: 99` refuses
  `:manifest_version_unsupported`.

### Phase D — `EtherealGraph` composition + ethereal record reconstruction

The "RDBMS purged, AR records gone" subset needs explicit
handling. Two paths:

#### Path 1 — AR records existed but were purged; restore can rebuild them

If the operator's app has a way to recreate the AR records
(seed data, migration, restored db backup), the AR records
come back THEN `Storage.restore_all` finds them by their stable
ID and hydrates. Operators sequence:

```ruby
# After db:create + db:migrate, restore AR seed data first:
load Rails.root.join("db/seeds.rb")

# Now the Workspace / WorkspaceContext records exist again with their
# original IDs.

# Then restore the engine state — ethereal records hydrate via their
# existing AR record's hydrate_ethereal_graph! path.
Vv::Graph::Storage.restore_all(reset: true)
```

#### Path 2 — AR records can't be recovered; restore as standalone

If the operator can't recreate the AR records, manifest entries
with `ethereal: true` can be restored as **standalone** graphs:
the named graph reappears in the engine but isn't attached to
any AR record. Operators flag this explicitly:

```ruby
# Restore everything, treating ethereal graphs as standalone.
Vv::Graph::Storage.restore_all(reset: true, mode: :standalone)

# Or: restore most things normally, but only specific ethereal
# graphs as standalone. Operators iterate the manifest and call
# restore_graph individually.
manifest = Vv::Graph::Storage.read_manifest
manifest.graphs.each do |entry|
  mode = entry.iri.start_with?("urn:mm:lost_workspace:") ? :standalone : :auto
  Vv::Graph::Storage.restore_graph(entry.iri, mode: mode)
end
```

#### Implementation
- Operators register classes that include `EtherealGraph` via
  `Vv::Graph::Storage.register_ethereal_class(klass)`. The
  registry lets `snapshot_all` enumerate ethereal-bearing
  records, and `restore_all(mode: :auto)` knows which manifest
  entries to route through which AR class. A Rails initializer
  or the Railtie picks this up.
- Failure surfaces for missing AR records: `restore_graph`
  with `mode: :auto` against a missing ethereal record returns
  `:ethereal_record_missing` per failure. The aggregate
  `restore_all` collects these into `failures: [...]` rather
  than aborting; operators decide how to recover.

#### Exit criteria
- Spec: snapshot a Workspace + its EtherealGraph; destroy the
  Workspace; restore_all with `mode: :auto` reports
  `:ethereal_record_missing`.
- Spec: same, with `mode: :standalone`, restores the graph
  contents to the engine despite no AR record.
- Spec: `register_ethereal_class` lets `snapshot_all`
  enumerate per-class ethereal records.

### Phase E — `list` + `diff` + `prune`

Inspection + maintenance verbs.

```ruby
# What's in storage right now?
listing = Vv::Graph::Storage.list
# => { ok: true,
#      manifest: Manifest{...},
#      orphan_blobs: ["myapp/semantica/abc123.nt", ...],  # blobs without manifest entry
#      missing_blobs: ["myapp/semantica/def456.nt"]       # manifest entry without blob
#    }

# What's the diff between engine state and stored manifest?
diff = Vv::Graph::Storage.diff
# => { ok: true,
#      only_in_engine: ["urn:graph:new"],
#      only_in_storage: ["urn:graph:purged"],
#      changed: [{ iri: "urn:graph:edited", engine_count: 421, manifest_count: 397 }]
#    }

# Drop orphan blobs (those not referenced by the current manifest).
Vv::Graph::Storage.prune
# => { ok: true, deleted: 3, orphan_blobs: [...] }
```

#### Implementation
- `list` reads the manifest + enumerates blob keys in the
  service (via `ActiveStorage::Blob.where(service_name: …)`)
  and computes the set difference. Useful for "did my storage
  drift from my engine?"
- `diff` runs `snapshot_all` "in dry-run mode" (computing
  per-graph SHA-256s without uploading) and compares to the
  stored manifest. Operators use this before `snapshot_all` to
  see what would change.
- `prune` deletes orphan blobs (those not referenced by the
  current manifest). Safe-by-default — refuses with
  `:prune_dry_run` if `dry_run: true` is set (default).
  Operators pass `dry_run: false` to actually delete.

#### Exit criteria
- Spec: `list` against a populated service returns the
  manifest + lists no orphans.
- Spec: `diff` after deleting a graph in the engine reports
  `only_in_storage: [iri]`.
- Spec: `prune(dry_run: false)` removes an orphan blob;
  `dry_run: true` (default) only reports.

### Phase F — Specs + bin/check

- New file `spec/semantica/storage_spec.rb` — Phase A
  configuration / manifest types (~10 examples).
- New file `spec/semantica/storage_snapshot_restore_spec.rb` —
  Phases B + C + the "strange lifecycle" round-trip
  (~15 examples).
- New file `spec/semantica/storage_ethereal_composition_spec.rb`
  — Phase D's ethereal + standalone modes (~6 examples).
- New file `spec/semantica/storage_inspection_spec.rb` —
  Phase E's list / diff / prune (~6 examples).
- Spec harness uses Active Storage's `Test` service (in-memory)
  by default; `:requires_extension` tag still applies for the
  engine-backed round-trip. Optional `:requires_disk` tag for
  Disk-service smoke tests; `:requires_s3` for opt-in S3 tests
  gated by env-var (`SEMANTICA_TEST_S3_BUCKET`).
- `bin/check` green against engine ≥ 0.9.1.
- Estimated total ~35–40 new specs; suite grows from 330+ → ~370.

### Phase G — Docs

- `README.md` — new "Graph storage configuration" section after
  "Ethereal graphs". `Vv::Graph::Storage.configure` block + the
  three usage patterns (per-graph, full snapshot/restore,
  strange-lifecycle purge-and-restore).
- `CHANGELOG.md` — `0.14.0` heading (replaces the v0.14.0
  release headline previously occupied by PLAN_0.8.0 Phases
  B + C; THOSE bullets graduate to a separate sub-section
  in the same heading). Per-phase bullets.
- `CONSUMER_REQUIREMENT_MM.md` — note that
  `Vv::Graph::Storage.snapshot_scope(scope: my_workspace_scope)`
  is the per-tenant backup primitive.
- `CONSUMER_REQUIREMENT_VV.md` — note that snapshot_all
  composes with the Conformer Writer's accumulated Silver
  graphs; the gem-wide snapshot is what survives process
  restarts for graphs not tied to a single AR record.
- `examples/initializers/semantica_storage.rb` — example
  Rails initializer + `config/storage.yml` snippets for the
  three backend cases (local / test / S3).
- `docs/plans/PLAN_0.14.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.14.0`. (See Versioning Note below.)

#### Versioning note

v0.14.0 has already been "released" as the marker for
PLAN_0.8.0 Phases B + C + PLAN_0.9.0 Phase E (cut 1). Two
options:

1. **Renumber this plan to `0.15.0`.** Cleaner; v0.14.0 keeps
   its current scope (RDF-star write surface). PLAN_0.15.0
   becomes "Vv::Graph::Storage". CHANGELOG already documents
   v0.14.0 as shipped; no rewrite.

2. **Keep this plan as 0.14.0; renumber the previously-released
   work to 0.14.0-rc1.** Lets this Storage plan claim the v0.14.0
   slot; the prior work moves to a release-candidate moniker.

The plan filename here is `PLAN_0.14.0.md` per the operator's
direction; the implementation phase finalises which versioning
posture lands.

## Out of scope for v0.14.0

- **N-Quads / TriG single-blob format.** v0.14.0 ships one
  blob per graph. A single all-graphs-in-one-blob option
  (`format: :nquads`) is a v0.15.0+ candidate; operators
  wanting it today can post-process the per-graph blobs
  with `cat` or jq.
- **Incremental / differential snapshots + append-mode
  manifest writes.** Each `snapshot_all` writes a fresh full
  JSONL manifest. JSONL's append-only-friendly structure makes
  per-graph append-mode (one new line per `snapshot_graph` call,
  no header rewrite) trivially implementable — deferred to
  v0.15.0+ gated on telemetry. Active Storage's content-addressed
  blob keys already dedupe unchanged graph blobs at the service
  layer (S3 / GCS / Azure all dedupe identical content by key);
  the manifest itself is small (~KB to ~MB scale) so the rewrite
  cost is negligible at thousand-graph scale.
- **Cross-service replication.** `snapshot_all` writes to
  one service. Cross-service backup (snapshot to S3, mirror
  to Azure) operators do via Active Storage's mirror service
  pattern (`config.active_storage.service = :mirror_chain`)
  — no gem-side support needed.
- **Encryption at rest.** Active Storage's service-level
  encryption (server-side S3 KMS, etc.) handles this. The
  gem does not encrypt blobs client-side. Operators wanting
  client-side encryption configure a custom Active Storage
  service wrapping the cipher.
- **Streaming snapshot for huge graphs.** v0.14.0 builds the
  full N-Triples body in memory before uploading. Graphs
  > ~100MB may need streaming; v0.15.0+ candidate.
- **Concurrent snapshot/restore safety.** Two processes
  calling `snapshot_all` simultaneously race the manifest
  write. v0.14.0 documents the limitation; operators
  serialise via their own locking mechanism.
- **Multi-engine restore.** Restoring a snapshot taken
  against engine 0.7.0 into an engine 0.5.0 is unsupported
  if the snapshot contains RDF-star content. The manifest's
  `engine_version` field warns the operator; the gem refuses
  `:format_unsupported` when content-kind ↔ engine-version
  mismatch is detectable.
- **Scoped restore-into-different-scope.** Snapshot of
  `urn:mm:workspace:42:silver` cannot be restored into
  `urn:mm:workspace:99:silver` directly — IRIs are pinned
  in the manifest. Operators wanting graph-IRI renaming run
  `Sparql.execute` with a `RENAME` pattern post-restore.
- **Backup verification / corruption detection.** The
  manifest carries `byte_size` + an implicit SHA-256 (via
  blob key); operators verify by re-snapshotting + diffing.
  A first-class `verify!` operation is a v0.15.0+ candidate.

## Risks

| Risk | Mitigation |
|---|---|
| `ActiveStorage` is operator-supplied (Gemfile add); the gem can't assume presence. | Phase A's `service` accessor refuses `:active_storage_missing` if the constant isn't defined. README documents `gem "activestorage"` as a prerequisite when including `Vv::Graph::Storage`. |
| Memory-service (`Test`) snapshots vanish on process restart — operator confusion if they expect persistence. | Documented loudly. `config.service = :semantica_graphs_test` is for spec harnesses only; production configs use `Disk` / `S3` / etc. |
| S3 / GCS / Azure costs at scale. | Operators tune via Active Storage's standard service options (storage class, lifecycle rules, retention). The gem doesn't override service config. Documented. |
| Snapshot of a 100k-triple graph could be tens of MB; in-memory build can pressure the host. | Documented limit; streaming is v0.15.0+ candidate. Operators with huge graphs scope via `Vv::Graph::Storage.snapshot_scope(scope: …)` to avoid all-at-once. |
| The "strange lifecycle" purge-then-restore loses ethereal records' AR backing. | Phase D's two paths cover both recovery modes. Manifest carries `ar_class` + `ar_id` so operators making informed choices can decide standalone-vs-ethereal per record. `:ethereal_record_missing` surfaces the gap actionably. |
| Manifest schema evolution (new fields) breaks restore against an older gem. | `version:` field in the header line. `CURRENT_MANIFEST_VERSION` constant. Future restore paths handle older versions; restoring a newer-version manifest refuses with `:manifest_version_unsupported`. Per-line schema means a future field addition on the `graph` record type can be ignored cleanly by older readers (Ruby's `JSON.parse` is permissive on unknown keys; the Struct constructor uses `keyword_init: true` so unknown keys would error — we add an explicit pluck step that ignores unknown keys per line for forward-compat). |
| Partial JSONL writes — upload interrupted mid-snapshot leaves a truncated manifest. | `snapshot_all` writes to a `StringIO` first, then uploads atomically (Active Storage's `create_and_upload!` is atomic per blob). The truncated case can't occur. Per-graph append-mode (v0.15.0+) would need explicit atomicity guarantees from the storage backend — out of scope here. |
| Operators hand-edit the JSONL manifest and break parse. | Per-line schema means the breakage localises — `:manifest_parse_error` carries the offending line number. Operators can usually `head`/`tail` around the bad line to recover. The header line is sacrosanct; hand-editing it isn't supported. |
| Concurrent `snapshot_all` from two processes races the manifest write. | Documented limit. Active Storage uses `create_and_upload!` which is atomic per blob, but the manifest itself isn't transactionally written. Operators serialise via app-level lock if needed. |
| Active Storage's `Service` API differs slightly across Rails 7 / 8 / future. | Gem pins minimum Rails version (`>= 8.0`) where the API is stable. Older Rails versions refuse with `:active_storage_missing` at configure time. |
| Standalone graph IRI collisions across operator apps sharing an S3 bucket. | `key_prefix:` configuration plus per-app bucket isolation. Documented — multi-app shared buckets aren't supported without an explicit `key_prefix:` per app. |
| `snapshot_all` triggers a full engine read; can be slow on large graphs. | Documented. Operators schedule snapshots in off-hours via cron / Sidekiq / etc. `Storage.snapshot_scope(scope:)` for incremental. |
| EtherealGraph's existing `:vv_graph_blob` Active Storage attachment vs. `Storage`'s blobs in the same service collide on keys. | The per-AR-record attachment uses Active Storage's auto-key (`ActiveStorage::Blob.generate_unique_secure_token`); `Vv::Graph::Storage`'s manifest blobs use the `key_prefix + sha256` form. The two key spaces don't overlap. |

## Acceptance signal

1. Phases A/B/C/D/E land with passing specs.
2. `bin/check` green against engine ≥ 0.9.1.
3. Active Storage `Test` service spec harness exercises every
   facade method.
4. Disk-service smoke test (tagged `:requires_disk`) round-trips
   a real Active Storage blob on local disk.
5. The "strange lifecycle" round-trip spec: snapshot →
   `Sparql.execute("CLEAR ALL")` → restore → triple-set
   equality across every graph.
6. CHANGELOG `0.14.0` heading dated; per-phase entries.
7. `VERSION` → `0.14.0` (or `0.15.0` per the Versioning Note
   under Phase G).
8. README documents `Storage.configure` block + the three
   usage patterns + the example `config/storage.yml` snippets.
9. CONSUMER_REQUIREMENT_MM.md notes the new optional surface;
   CONSUMER_REQUIREMENT_VV.md notes the per-scope snapshot
   primitive.

## v0.14.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Vv::Graph::Storage.configure { \|c\| c.service = :name; c.manifest_key = "…"; c.format = :ntriples\|:ntriples_star; c.key_prefix = "…" }` | configuration block | **Pinned.** |
| `Vv::Graph::Storage.configuration` | reader returning frozen Configuration | **Pinned.** |
| `Vv::Graph::Storage::Configuration` struct | value object | **Pinned.** |
| `Vv::Graph::Storage::Manifest` struct (`header:` + `graphs:` + `unknown_record_types:`) | value object | **Pinned.** |
| `Vv::Graph::Storage::ManifestHeader` struct (`version` / `snapshotted_at` / `engine_version` / `format` / `key_prefix`) + `#to_jsonl` | value object | **Pinned.** |
| `Vv::Graph::Storage::GraphEntry` struct + `#to_jsonl` | value object | **Pinned.** |
| JSONL line discriminator `"type": "manifest_header"\|"graph"` (+ forward-compat unknown types skipped, not refused) | wire format | **Pinned at v1.** |
| `Vv::Graph::Storage::CURRENT_MANIFEST_VERSION` constant | integer | **Pinned name.** Bumps on schema evolution. |
| `Vv::Graph::Storage.snapshot_graph(iri, format: nil, scope: nil)` → `{ ok:, iri:, blob_key:, byte_size:, triple_count: }` | module method | **Pinned.** |
| `Vv::Graph::Storage.restore_graph(iri, blob: nil, mode: :auto\|:standalone\|:ethereal)` → `{ ok:, iri:, triple_count:, mode: }` | module method | **Pinned.** |
| `Vv::Graph::Storage.snapshot_all(scope: nil, format: nil)` → `{ ok:, snapshotted:, manifest_key:, graphs: [...] }` | module method | **Pinned.** |
| `Vv::Graph::Storage.restore_all(reset: false, mode: :auto, scope: nil)` → `{ ok:, restored:, reset_engine:, graphs: [...], failures: [...] }` | module method | **Pinned.** |
| `Vv::Graph::Storage.list` / `.diff` / `.prune(dry_run: true)` | module methods | **Pinned.** |
| `Vv::Graph::Storage.read_manifest` / `.write_manifest(manifest)` | module methods | **Pinned.** |
| `Vv::Graph::Storage.register_ethereal_class(klass)` | module method | **Pinned.** |
| `Vv::Graph::Storage::UnconfiguredService` exception class | class | **Pinned.** |
| Manifest JSONL schema (the header + graph-entry key tables under "Manifest format") | wire format | **Pinned at v1.** Future schema versions bump `version:` in the header line. Unknown record types are skipped (forward-compat). |
| Manifest blob content type `application/x-ndjson` | wire format | **Pinned.** |
| Manifest filename suffix `.jsonl` | convention | **Pinned default**; operators override via `manifest_key:` configuration. |
| `:storage_unconfigured` reason symbol | refusal envelope | **Pinned.** |
| `:active_storage_missing` reason symbol | refusal envelope | **Pinned.** |
| `:format_unsupported` reason symbol | refusal envelope | **Pinned.** |
| `:manifest_parse_error` reason symbol | refusal envelope | **Pinned.** |
| `:manifest_version_unsupported` reason symbol | refusal envelope | **Pinned.** |
| `:blob_missing` reason symbol | refusal envelope | **Pinned.** |
| `:ethereal_record_missing` reason symbol | refusal envelope | **Pinned.** |
| `:prune_dry_run` reason symbol (informational, returned with `ok: true`) | envelope | **Pinned.** |
| `"@default"` manifest sentinel for the default graph | wire constant | **Pinned.** |

## Cross-references

- [`./PLAN_0.5.0.md`](./PLAN_0.5.0.md) — named graphs; every
  graph `Storage` snapshots is identified by an IRI per this
  plan's `graph:` kwarg / `graph "..."` DSL.
- [`./PLAN_0.7.0.md`](./PLAN_0.7.0.md) — EtherealGraph; the
  per-AR-record durability shape `Storage` generalises.
  EtherealGraph stays; `Storage` is the gem-wide sibling.
- [`./PLAN_0.13.0.md`](./PLAN_0.13.0.md) — Scope value
  object. `Storage.snapshot_scope(scope:)` rides the
  five-role partitioning.
- [`./PLAN_0.14.1.md`](./PLAN_0.14.1.md) — Path-A
  Decision Intelligence concern (separate plan; composes
  with Storage when Decisions get snapshotted/restored as
  part of the wider engine state).
- [Active Storage Guides (Rails 8)](https://guides.rubyonrails.org/active_storage_overview.html)
  — operator-side configuration via `config/storage.yml`;
  built-in Disk / Test / S3 / GCS / Azure services.
- [W3C SPARQL 1.1 §13](https://www.w3.org/TR/sparql11-query/#rdfDataset)
  — graph-enumeration query the `snapshot_all` enumerator
  rides on.
- [`CONSUMER_REQUIREMENT_MM.md`](../../CONSUMER_REQUIREMENT_MM.md)
  — multi-tenant Workspace / Tenant scopes drive the
  per-scope snapshot primitive.
- [`CONSUMER_REQUIREMENT_VV.md`](../../CONSUMER_REQUIREMENT_VV.md)
  — vv-memory's Conformer Writer accumulates Silver-tier
  scoped graphs that must survive process restarts; the
  gem-wide snapshot completes B1's hydrate-side fix at the
  engine-state level.
- [`sqlite-sparql/CHANGELOG.md`](../../sqlite-sparql/CHANGELOG.md)
  § `0.7.0` — RDF-star round-trip support, which
  `Storage.snapshot_all(format: :ntriples_star)` rides on.
