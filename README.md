# vv-graph

ActiveRecord integration for [sqlite-sparql](../sqlite-sparql/README.md) — RDF triples + SPARQL inside Rails 8.

> **Status: v0.x.x — surface evolves.** This gem ships as a path-sourced
> dependency inside the MagenticMarket monorepo. The substrate is the
> first consumer; the API stays operator-fluid until v1.0. Outside Rails
> apps can consume via a Git source at their own risk.

## What's in the box

Three small layers, each opt-in:

| Layer | Class | Responsibility |
|---|---|---|
| **Loader** | `Vv::Graph::Loader` | Boots the sqlite-sparql extension across AR connection-pool restarts. Idempotent. |
| **Sparql facade** | `Vv::Graph::Sparql` | `select` / `ask` / `construct` / `execute` / `bulk_insert` / `bulk_delete` returning `{ ok:, results:/value:/ntriples:/count:/inserted:/deleted: }` envelopes. Never raises. `quoted_triple(s,p,o)` marker for RDF-star writes (v0.14.0). |
| **Storable concern** | `Vv::Graph::Storable` | Per-model `triples do ... end` DSL. After-save / after-destroy lifecycle hooks emit / retract triples. `annotate` block attaches RDF-star annotations to a `triple` (v0.14.0). |
| **EtherealGraph concern** | `Vv::Graph::EtherealGraph` | Per-AR-record named graphs with Active Storage durability (v0.7.0). |
| **Reasoner** | `Vv::Graph::Reasoner` | OWL 2 RL forward-chaining `materialise!` with rule library + fixpoint iteration + RDF-star `:derivedBy` provenance. |
| **Shacl validator** | `Vv::Graph::Shacl` | SHACL Core `validate` against a shapes graph; writes a W3C `sh:ValidationReport`. |
| **Shacl Rules** | `Vv::Graph::Shacl::Rules` | Shape-scoped derivation via `sh:TripleRule` / `sh:SPARQLRule`. |
| **Scope** | `Vv::Graph::Scope` | Five-role value object (`data` / `schema` / `shapes` / `inferred` / `report`) accepted as `scope:` kwarg on every facade. |
| **ChangeSet** | `Vv::Graph::ChangeSet` | `capture(scope:) { … }` block records adds + retracts from write paths. |
| **Capability predicates** | `Vv::Graph.*?` | `rdf_star_writes_enabled?`, `facade_version`, `checkpoint_can_round_trip?(content_kind:)` — operators ask "can this gem do X?" instead of parsing `VERSION`. |

## Prerequisites

This gem assumes the [sqlite-sparql](../sqlite-sparql/README.md) loadable
extension is built + available on disk. The gem ships only the Ruby
integration layer; operators build the `.dylib` / `.so` themselves:

```bash
# From the MagenticMarket repo root:
cd vendor/sqlite-sparql
cargo build --release
# Extension at: target/release/libsqlite_sparql.{dylib,so}
```

Set `VV_GRAPH_SQLITE_SPARQL_PATH` to point at the built extension.

## Quickstart

```ruby
# Gemfile
gem "vv-graph", path: "vendor/vv-graph"
```

```bash
rails generate semantica:setup
# Adds `extensions: ["${VV_GRAPH_SQLITE_SPARQL_PATH}"]` to config/database.yml.
# Emits a migration creating the triple-metadata side table (if needed).
```

```ruby
# Per-model opt-in:
class Product < ApplicationRecord
  include Vv::Graph::Storable

  triples do
    subject       -> { "urn:mm:product:#{sku}" }
    triple "schema:name",     -> { name }
    triple "schema:category", -> { category }
    triple "schema:brand",    -> { brand }
    triple "schema:gtin",     -> { gtin }, if: -> { gtin.present? }
  end
end

Product.create!(sku: "EPET2850", name: "Epson EcoTank", category: "printer", brand: "Epson")
# After save: rdf_insert("urn:mm:product:EPET2850", "schema:name", "Epson EcoTank")
# After save: rdf_insert("urn:mm:product:EPET2850", "schema:category", "printer")
# ...

product.destroy
# After destroy: rdf_delete(subject, p, o) for every declared triple
```

### Multi-subject emission — `on_subject` (v0.2.0)

```ruby
class Product < ApplicationRecord
  include Vv::Graph::Storable

  triples do
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }

    on_subject -> { "urn:mm:folder:category:#{category}" } do
      triple "rdf:type", "<urn:mm:CategoryFolder>"
      triple "schema:name", -> { category.titleize }
    end
  end
end
```

Each `on_subject` block emits alongside the primary subject; both
share the same read-replace per (subject, predicate) idempotency.
Literal-string predicate values (`"<urn:…>"`-wrapped) serialize as
IRI objects.

### Collection iteration + multi-value predicates — `each` (v0.2.0)

```ruby
triples do
  subject -> { "urn:mm:product:#{sku}" }

  each -> { product_specs } do |spec|
    triple "mm:#{spec.name.camelize(:lower)}", -> { spec.value }
  end

  # Multi-value via repeated each (same predicate, N values):
  each -> { feature_flags } do |feature|
    triple "mm:hasFeature", -> { feature.code }
  end
end
```

The predicate IRI may interpolate per-item state. Read-replace
adjusts: every triple matching (subject, predicate) for every
predicate the block emits this save is retracted before insert.
Empty collection this save → no retraction → stale triples from a
prior non-empty save persist; pair with explicit
`Sparql.execute("DELETE WHERE { <s> <p> ?o }")` if strict cleanup is
required.

### JSON / structured-literal object types (v0.2.0)

```ruby
triples do
  subject -> { "urn:mm:product:#{sku}" }
  triple "schema:offers", -> { { price: price_cents/100.0, currency: "USD" } }
end
```

`Hash` and `Array` values JSON-encode via `JSON.generate` and emit
as typed literals with `xsd:string` datatype. Read back via
`Sparql.select` + `JSON.parse` on the literal value.

### Named graphs — `graph "…"` DSL + `graph:` kwarg (v0.5.0)

```ruby
class Product < ApplicationRecord
  include Vv::Graph::Storable

  triples do
    graph "urn:mm:graph:bhphoto"
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:name", -> { name }
    # on_subject + each blocks inherit the outer graph
  end
end

Vv::Graph::Sparql.select("SELECT ?s WHERE { ?s ?p ?o }", graph: "urn:mm:graph:bhphoto")
Vv::Graph::Sparql.execute("INSERT DATA { … }",            graph: "urn:mm:graph:bhphoto")
```

All three dispatch modes (`:sparql_update` / `:bulk` / `:per_call`)
produce equivalent end states for a graph-scoped model. Cross-graph
isolation: operations on `urn:mm:graph:bhphoto` leave triples for
the same subject in other graphs (including the default graph)
untouched. Blank-node graph IRIs refuse at the gem boundary with
`:invalid_graph`. `execute("CLEAR ALL"/"CLEAR DEFAULT", graph: …)`
refuses with `:invalid_dsl` (ambiguous scoping; use
`execute("CLEAR GRAPH <urn:…>")`).

```ruby
# SPARQL queries (structured envelopes; never raise):
Vv::Graph::Sparql.select(<<~SPARQL)
  SELECT ?p WHERE { ?p <schema:category> "printer" }
SPARQL
# => { ok: true, results: [{ "p" => "urn:mm:product:EPET2850" }, ...] }

Vv::Graph::Sparql.ask('ASK { ?p <schema:gtin> "01234567890123" }')
# => { ok: true, value: true }

Vv::Graph::Sparql.construct(<<~SPARQL)
  CONSTRUCT { ?p <derived:hot> true }
  WHERE     { ?p <schema:category> "printer" }
SPARQL
# => { ok: true, ntriples: "<urn:mm:product:EPET2850> <derived:hot> true .\n..." }

# Write surface — INSERT DATA / DELETE DATA / CLEAR ALL fast paths.
# v0.2.0 added `DELETE WHERE { <s> <p> ?o }` as a public form.
# v0.3.0 unlocks arbitrary SPARQL 1.1 UPDATE via the engine's
# `sparql_update` scalar (signed net delta as `:count:`).
Vv::Graph::Sparql.execute(<<~SPARQL)
  INSERT DATA { <urn:mm:product:EPET2850> <schema:tag> "hot" . }
SPARQL
# => { ok: true, count: 1 }  (DATA-form fast path; always positive)

Vv::Graph::Sparql.execute(<<~SPARQL)
  DELETE WHERE { <urn:mm:product:EPET2850> <schema:tag> ?o }
SPARQL
# => { ok: true, count: <integer> }  (v0.2.0 fast path)

Vv::Graph::Sparql.execute(<<~SPARQL)
  DELETE { ?s <schema:tag> "stale" }
  INSERT { ?s <schema:tag> "fresh" }
  WHERE  { ?s <schema:tag> "stale" }
SPARQL
# => { ok: true, count: 0 }  (signed net delta: -N delete + N insert)

# Bulk write — single FFI crossing per batch (v0.4.0).
Vv::Graph::Sparql.bulk_insert([
  { s: "urn:mm:product:EPET2850", p: "schema:name",     o: "Epson EcoTank" },
  { s: "urn:mm:product:EPET2850", p: "schema:category", o: "printer" },
  ["urn:mm:product:EPET2851", "schema:name", "HP DeskJet", "urn:mm:graph:bhphoto"],
])
# => { ok: true, inserted: 3 }
# Abort-batch-on-error: any malformed row refuses the whole batch
# (store unchanged); refusal envelope's :because: carries `row <N>:`.

Vv::Graph::Sparql.bulk_delete(rows)
# => { ok: true, deleted: <integer> }
```

Failure envelopes carry a verbatim because-clause:

```ruby
Vv::Graph::Sparql.select("SELEC bogus") # malformed
# => { ok: false, reason: :sparql_parse_error, because: "..." }
```

Pinned `:reason` symbols (v0.1.0): `:sparql_parse_error`,
`:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`.
v0.3.0 adds `:sparql_eval_error` (semantically-invalid UPDATE — the
engine surfaces `"SPARQL evaluation error:"`). v0.5.0 adds
`:invalid_graph` (blank-node graph IRIs) and `:invalid_dsl`
(ambiguous DSL — e.g. `execute("CLEAR ALL", graph: …)`).

### Ethereal graphs — `Vv::Graph::EtherealGraph` (v0.7.0)

Scope a named RDF graph to an Active Record record's lifetime.
The blob lives in Active Storage; the engine holds the graph
in-process; `hydrate` / `checkpoint` / `retract` are the three
explicit lifecycle hooks.

```ruby
class WorkspaceContext < ApplicationRecord
  include Vv::Graph::EtherealGraph

  ethereal_graph do
    iri           -> { "urn:mm:workspace:#{id}:context" }
    checkpoint_on :explicit   # :explicit (default) | :save
  end
end

ctx = WorkspaceContext.create!
ctx.hydrate_ethereal_graph!     # pulls blob → engine; idempotent
Vv::Graph::Sparql.execute(
  'INSERT DATA { <urn:item:1> <schema:name> "Hi" . }',
  graph: ctx.ethereal_graph_iri,
)
ctx.checkpoint_ethereal_graph!  # flushes engine → blob
# … process restart …
Vv::Graph::EtherealGraph.evict!(ctx.ethereal_graph_iri)
ctx.hydrate_ethereal_graph!     # restores from blob
ctx.destroy!                    # CLEAR GRAPH + purges blob
```

- `checkpoint_on: :save` registers an `after_save` callback so
  every save flushes the engine state to the blob. Paired with
  `Vv::Graph::Storable`, declare `triples do` *before*
  `ethereal_graph do` so the emit callback registers (and fires)
  before the checkpoint — otherwise the checkpoint captures stale
  state.
- The blob is an `application/n-triples` Active Storage
  attachment named `vv_graph_blob`. Active Storage is
  opt-in — add `gem "activestorage"` to your Gemfile if you
  include the concern. Operators without AS can omit it and
  supply `vv_graph_blob` themselves (any object responding
  to `attached?` / `download` / `attach(io:, filename:,
  content_type:)` / `purge`).
- Hydration is process-wide via `HYDRATED_IRIS`. Multi-process
  operators accept last-writer-wins on checkpoints;
  `Vv::Graph::EtherealGraph.evict!(iri)` is the explicit escape
  hatch.

### RDF-star — `annotate` DSL + `Sparql.quoted_triple` (v0.14.0)

Attach metadata to a single triple — provenance, confidence,
attribution, timestamps — without standard-reification's
four-triple verbose pattern. Engine ≥ 0.7.0 round-trips
quoted-triple terms (`<< s p o >>`) across every read and write
path; v0.14.0 surfaces the operator-facing seams.

```ruby
class Product < ApplicationRecord
  include Vv::Graph::Storable

  triples do
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:gtin", -> { gtin } do
      annotate "mm:reportedBy", -> { "<urn:mm:user:#{updater_id}>" }
      annotate "mm:confidence", -> { confidence },
               if: -> { confidence.present? }
    end
  end
end

Product.create!(sku: "P1", gtin: "1234567890123", updater_id: 42, confidence: 0.87)

# Annotation reachable via the quoted-triple pattern:
Vv::Graph::Sparql.select(<<~SPARQL)
  SELECT ?u WHERE {
    << <urn:mm:product:P1> <schema:gtin> "1234567890123" >> <mm:reportedBy> ?u
  }
SPARQL
# => { ok: true, results: [{ "u" => "<urn:mm:user:42>" }] }
```

Emission cycle per save:

1. **Retract** orphan annotations on the prior parent value's
   quoted-triple subject (catches `update!` that changes the
   parent object — referential opacity orphans prior annotations
   per the SPARQL-star spec).
2. **Replace** the parent triple via the existing read-replace.
3. **Emit** annotations on the new quoted-triple subject.

Destroy retracts the parent triple AND every annotation. Parent
`if:` false → both skip. Annotation `if:` false → only that
annotation skips.

Bulk write also accepts RDF-star rows:

```ruby
Vv::Graph::Sparql.bulk_insert([
  # Hash form with a nested 3-element Array as the quoted triple:
  { s: ["urn:mm:p:1", "schema:gtin", "1234567890123"],
    p: "mm:reportedBy",
    o: "<urn:mm:user:42>" },

  # Or with the explicit marker:
  { s: Vv::Graph::Sparql.quoted_triple("urn:mm:p:1", "schema:gtin", "1234567890123"),
    p: "mm:reportedAt",
    o: "2026-05-24T00:00:00Z" },
])
# Predicate position stays IRI-only per the W3C SPARQL-star contract;
# quoted-triple in :p refuses :invalid_dsl.
```

### OWL 2 RL reasoning — `Vv::Graph::Reasoner` (v0.9.0)

Forward-chaining `materialise!` over an asserted graph; emits
the closure into a paired inferred graph. The Phase B core rule
library ships 15 rules covering the most-used OWL 2 RL patterns
(subClassOf / subPropertyOf transitive closures, instance-type
propagation, domain / range entailment, transitive / symmetric /
inverse / functional property characteristics, sameAs closure).
The remaining ~55 W3C rules are catalogued in
`Rules::PHASE_B_PENDING` as mechanical transcriptions deferred
to follow-up phases.

```ruby
Vv::Graph::Reasoner.materialise!(
  asserted:  "urn:mm:graph:catalogue",
  inferred:  "urn:mm:graph:catalogue:inferred",
  rules:     :owl_2_rl,
  provenance: true,            # default; emits :derivedBy annotations
  max_iterations: 50,
)
# => { ok: true, iterations: 3, derived: 7, fixpoint: true,
#      per_rule: { "scm-sco" => 4, "cax-sco" => 3, ... } }
```

When `provenance: true` (default), each derived triple carries
a `<< s p o >> <urn:vv-graph:derivedBy> <rule_iri>` annotation
(rule IRI shape: `urn:vv-graph:reasoner:rule:<id>`). Operators
audit the closure by querying the annotation:

```ruby
Vv::Graph::Sparql.select(<<~SPARQL, graph: "urn:mm:graph:catalogue:inferred")
  SELECT ?inferred WHERE {
    ?inferred ?p ?o .
    << ?inferred ?p ?o >> <urn:vv-graph:derivedBy>
                          <urn:vv-graph:reasoner:rule:scm-sco>
  }
SPARQL
```

`:derivedAt NOW()` + `:derivedFrom << premise >>` are
documented as deferred (idempotency guard + per-rule premise
binding pending). `provenance: false` skips the rewrite entirely.

Refusal: `:reasoner_diverged` when `max_iterations` hits without
fixpoint — envelope includes `iterations:` + `per_rule:` for
diagnostics.

### SHACL Core validation — `Vv::Graph::Shacl` (v0.10.0)

Walks `shapes_graph` for `sh:NodeShape` declarations, resolves
focus nodes via `sh:targetClass` / `sh:targetNode` against
`data_graph`, evaluates 12 SHACL Core constraint components on
each property shape, writes a W3C-conformant `sh:ValidationReport`
graph.

```ruby
Vv::Graph::Shacl.validate(
  data_graph:   "urn:mm:graph:catalogue",
  shapes_graph: "urn:vv-graph:shapes:product",
  report_graph: "urn:mm:graph:catalogue:report",
)
# => { ok: true, conforms: false,
#      violations: [
#        { focus_node: "<urn:mm:product:1>", path: "<schema:gtin>",
#          source_constraint_component: "<…#MinCountConstraintComponent>",
#          severity: "<…#Violation>", value: nil,
#          message: "expected at least 1 value(s); got 0" },
#        ...
#      ],
#      report_graph: "urn:mm:graph:catalogue:report" }
```

Core library ships: `sh:minCount`, `sh:maxCount`, `sh:datatype`,
`sh:nodeKind`, `sh:class`, `sh:pattern`, `sh:minLength`,
`sh:maxLength`, `sh:in`, `sh:hasValue`, `sh:minInclusive`,
`sh:maxInclusive`. The remaining ~18 components are catalogued
in `Constraints::PHASE_B_PENDING`; shapes using a pending
parameter refuse `:unknown_constraint_component` rather than
silently conforming.

### SHACL Rules — shape-scoped derivation (v0.12.0)

Operator-authored derivation via `sh:rule` attachments on a
`sh:NodeShape`. Supports `sh:TripleRule` (single-triple
derivation) and `sh:SPARQLRule` (embedded CONSTRUCT). `sh:order`
ordering, `sh:deactivated` skip, `sh:condition` gating via
recursive `Shacl.validate`.

```ruby
Vv::Graph::Shacl::Rules.materialise!(
  data_graph:   "urn:mm:graph:catalogue",
  shapes_graph: "urn:vv-graph:shapes:product",
  inferred:     "urn:mm:graph:catalogue:inferred",
)
# => { ok: true, iterations: 1, rules_fired: 2,
#      derived: 5, per_rule: { "urn:rule:1" => 3, ... },
#      fixpoint: true }
```

`?this` in `sh:SPARQLRule`'s CONSTRUCT + WHERE blocks resolves
to the focus node. `sh:JSRule` refuses
`:unknown_rule_type` (no JS runtime in-process).

### Change-set capture — `Vv::Graph::ChangeSet` (v0.11.0)

Boundary object for incremental reasoning / validation. Records
adds and retracts from `Sparql.execute INSERT DATA / DELETE DATA`
and `bulk_insert` / `bulk_delete` write paths.

```ruby
scope = Vv::Graph::Scope.new(
  data:     "urn:mm:graph:catalogue",
  inferred: "urn:mm:graph:catalogue:inferred",
)

changes = Vv::Graph::ChangeSet.capture(scope: scope) do
  Vv::Graph::Sparql.bulk_insert([
    ["urn:p:1", "schema:gtin", '"1234567890123"', scope.data],
  ])
end

changes.added      # => [["urn:p:1", "schema:gtin", '"…"', "urn:mm:graph:catalogue"]]
changes.retracted  # => []
```

Arbitrary SPARQL UPDATE forms (INSERT WHERE, MOVE, COPY) cannot
be observed without re-querying — operators call
`ChangeSet.record_add` / `record_retract` manually for those.
Nested `capture` blocks refuse `NestedCaptureError`.

### Cross-graph scopes — `Vv::Graph::Scope` (v0.13.0)

The five-role value object every facade accepts as `scope:`:

```ruby
scope = Vv::Graph::Scope.new(
  data:     "urn:mm:graph:workspace_42",
  schema:   "urn:mm:graph:shared:schema",
  shapes:   "urn:vv-graph:shapes:product",
  inferred: "urn:mm:graph:workspace_42:inferred",
  report:   "urn:mm:graph:workspace_42:report",
)

Vv::Graph::Reasoner.materialise!(scope: scope, rules: :owl_2_rl)
Vv::Graph::Shacl.validate(scope: scope)
Vv::Graph::Shacl::Rules.materialise!(scope: scope)
Vv::Graph::Sparql.select("SELECT * WHERE { ?s ?p ?o }", scope: scope)
```

`Vv::Graph::Scope.from_(graph_iri)` returns a degenerate
single-graph Scope (for ergonomic porting of per-kwarg call
sites). Refusal envelopes pinned: `:scope_kwarg_conflict` (both
`scope:` + an overlapping per-graph kwarg), `:scope_role_missing`
(facade needs a role the Scope omits), `:scope_read_write_overlap`
(`inferred` / `report` shares an IRI with a read role).

### Capability predicates (v0.13.0)

Operators ask "can this gem do X?" via a predicate rather than
parsing the `VERSION` string. The predicates are
introspection-driven — they reflect runtime state, not a static
flag — so capabilities flip automatically when their backing
surface ships.

```ruby
Vv::Graph.rdf_star_writes_enabled?
# => true (Sparql.quoted_triple is defined since v0.14.0)

Vv::Graph.facade_version
# => "0.14.0" — capability epoch; compare via Gem::Version

Vv::Graph.checkpoint_can_round_trip?(content_kind: :plain_ntriples)
# => true (since v0.7.0)
Vv::Graph.checkpoint_can_round_trip?(content_kind: :ntriples_star)
# => true (since v0.13.0 Phase B's split_ntriple balanced-bracket fix)

Vv::Graph.checkpoint_can_round_trip?(content_kind: :nope)
# => raises ArgumentError naming the known content_kinds

# v0.19.0 — predicate over the SPARQL facade methods. Lets a
# consumer (e.g. vv-visualize's tool catalogue) filter on
# backing-method availability without reaching into
# Vv::Graph::Sparql.respond_to? from consumer code.
Vv::Graph.sparql_method_available?(:select)    # => true
Vv::Graph.sparql_method_available?(:ask)       # => true
Vv::Graph.sparql_method_available?(:construct) # => true
Vv::Graph.sparql_method_available?(:execute)   # => true
Vv::Graph.sparql_method_available?(:nope)      # => false
```

`Vv::Graph.schema_normalized?` lands in v0.16.0 — see the
schema-normalization section below.

### Schema normalization — `Vv::Graph::Loader.normalize_schema!` (v0.16.0)

Reads ActiveRecord's schema and emits a deterministic RDF mapping
into the `:schema` named graph (default `urn:vv-graph:schema`).
Per AR class: `mm:Model a owl:Class`. Per plain column:
`mm:Model/col a owl:DatatypeProperty ; rdfs:domain mm:Model ;
rdfs:range <xsd:type>`. Per FK column (ends in `_id` with a known
target reflection): `mm:Model/col a owl:ObjectProperty` with the
target class as `rdfs:range`. Idempotent — `CLEAR GRAPH` runs
first, so re-running converges on the current AR state.
Default-excludes `ar_internal_metadata`, `schema_migrations`,
`active_storage_*`, `action_text_*`.

```ruby
Vv::Graph::Loader.normalize_schema!(iri_prefix: "mm:")
# => { ok: true, classes: 12, datatype_properties: 84,
#      object_properties: 11, schema_graph: "urn:vv-graph:schema" }

Vv::Graph.schema_normalized?           # => true after the first call
Vv::Graph.schema_normalization_info    # => { schema_graph:, iri_prefix: }
```

`Vv::Graph::Schema.field(model:, name:)` resolves symbolic field
references via the captured prefix (`<prefix><Model>/<col>`) and
AR introspection (`ar_column:`, `xsd:`); operators override
per-field via `Schema.override(...)`.

### QueryIR — storage-agnostic query algebra (v0.16.0)

A small frozen algebra (`Find`, `Filter`, `FilterRange`,
`FilterIn`, `Sort`, `Limit`, `Project`, `Count`, `Compare` +
v0.17.0's `Offset`) lowered to either SPARQL or ActiveRecord
scopes. Consumers compose a flat list; the gem picks the
backend.

```ruby
ir = [
  Vv::Graph::QueryIR::Find.new(type: :Product),
  Vv::Graph::QueryIR::Filter.new(field: :brand, op: :eq, value: "Epson"),
  Vv::Graph::QueryIR::Sort.new(field: :price, dir: :desc),
  Vv::Graph::QueryIR::Limit.new(n: 10),
]

Vv::Graph::QueryIR.run(ir, scope: "urn:mm:graph:catalogue")
# => { ok: true, results: [...], from: :sparql }

Vv::Graph::QueryIR.run(ir, backend: :relational)
# => { ok: true, results: [...], from: :relational }
```

The router picks via four-layer precedence: explicit `backend:`
hint > `ENV["VV_GRAPH_QUERY_BACKEND"]` > capability fit (when
one backend lacks a needed capability) > configured default
(`Vv::Graph.config.default_query_backend`, default `:sparql`).
Capability gaps surface as `:backend_missing_capability`
refusals with `missing:` + `available_backends:` fields.

### Typed result rows — `Sparql.select(with_types: true)` (v0.17.0)

Opt-in cell-shape change. Each result cell becomes a frozen
`{ value:, kind:, datatype:, lang: }` Hash instead of the flat
N-triples-ish string. Pinned `:kind` values: `:iri`, `:literal`,
`:blank_node`, `:quoted_triple`, `:unknown`.

```ruby
Vv::Graph::Sparql.select(
  "SELECT ?p ?o WHERE { <urn:x> ?p ?o }",
  with_types: true,
)
# => { ok: true,
#      results: [
#        { "p" => { value: "mm:Product/price",
#                   kind: :iri, datatype: nil, lang: nil },
#          "o" => { value: "42",
#                   kind: :literal,
#                   datatype: "http://www.w3.org/2001/XMLSchema#integer",
#                   lang: nil } } ] }
```

`with_types: false` (default) preserves the v0.1.0 flat-Hash
shape byte-for-byte.

### Query plan — `Sparql.explain` (v0.17.0)

Read-only structured plan for the SPARQL slice the gem accepts
(SELECT / ASK / CONSTRUCT plus the v0.3.0 UPDATE forms).

```ruby
Vv::Graph::Sparql.explain(
  "SELECT ?s WHERE { ?s a <mm:Product> . FILTER(?s != <urn:x>) } LIMIT 10",
)
# => { ok: true,
#      plan: { kind: :select,
#              projection: ["?s"],
#              where: { kind: :bgp,
#                       patterns: [["?s", "a", "<mm:Product>"]],
#                       filters: [{ expression: "?s != <urn:x>" }] },
#              modifiers: { order_by: nil, limit: 10, offset: nil,
#                           group_by: nil, having: nil } },
#      estimated_rows: :unknown,
#      from: :gem_parser }
```

`estimated_rows: :unknown` is pinned for v0.17.0 — the engine
has no cardinality estimator. When a future engine release ships
`rdf_sparql_plan`, `from:` flips `:gem_parser` →
`:engine_planner` by introspection and an integer populates.
Never executes the query; unparseable forms refuse with
`:sparql_parse_error`.

### SHACL shapes loader — `Shacl.load_shapes` (v0.17.0)

File-or-string SHACL shapes loader. Default scope
`urn:vv-graph:shapes`. Idempotent — SHA-256 of the canonicalised
input lives in `urn:vv-graph:shapes:meta`; matching hash returns
`{ loaded: 0, reason: :unchanged }` without touching the shapes
scope.

```ruby
Vv::Graph::Shacl.load_shapes("config/shapes/product.ttl")
# => { ok: true, loaded: 18, scope: "urn:vv-graph:shapes" }

Vv::Graph::Shacl.load_shapes(<<~TTL, format: :ttl)
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  <urn:shapes:Product> a sh:NodeShape ; sh:targetClass <mm:Product> .
TTL
# => { ok: true, loaded: 2, scope: "urn:vv-graph:shapes" }
```

`format: :ttl` (default) routes through the engine's
`rdf_load_turtle_to_graph`; `format: :nt` routes through
`Sparql.execute("INSERT DATA …")` after a line-based normalise.
Path-like strings (`.ttl`, `.nt`, `.n3`, `.rdf`, `.shapes`,
`.shacl` suffix) are treated as file paths — a missing file
refuses with `:shapes_file_missing` rather than handing the
literal string to the engine.

### Extension path resolution under Combustion (v0.18.0)

`Vv::Graph::Loader.extension_path` resolves the sqlite-sparql binary
via a **walk-up-to-first-match** from `Rails.root` (or `Dir.pwd`
when Rails isn't loaded). The pre-v0.18.0 resolver did a single-level
`Rails.root.parent` walk, which landed one directory short of
`vendor/sqlite-sparql/` under Combustion (where `Rails.root` is a
deep `spec/internal` subtree of the gem under test).

```ruby
# Precedence (unchanged): env var wins if set + on disk.
ENV["VV_GRAPH_SQLITE_SPARQL_PATH"] = "/path/to/libsqlite_sparql.dylib"

# Otherwise: walk upward from Rails.root (or Dir.pwd) until
# `vendor/sqlite-sparql/target/release/libsqlite_sparql.{dylib,so,dll}`
# exists. Falls back to the start-dir-relative path when nothing
# matches, so `ExtensionMissing` still names a concrete location.
Vv::Graph::Loader.extension_path
# => "/abs/path/to/substrate/vendor/sqlite-sparql/target/release/libsqlite_sparql.dylib"
```

Consumer gems running specs under Combustion (e.g. `vv-visualize`)
can drop their `VV_GRAPH_SQLITE_SPARQL_PATH` resolve-and-export
workarounds once they pin `vv-graph >= 0.18`.

## Concurrency

Engine ≥ 0.2.0 holds one Oxigraph store per process, shared across
every SQLite connection on every thread. Writes from one connection
are visible from any other connection in the same process (pinned
by `spec/semantica/cross_connection_visibility_spec.rb`).

The three `Storable.dispatch_mode` rungs differ in their atomicity
under concurrent writes to the same `(subject, predicate)`:

- **`:sparql_update`** — issues a single `DELETE/INSERT WHERE` per
  predicate. The engine's Oxigraph store handles the
  delete-then-insert atomically within one engine call. Recommended
  for apps doing concurrent writes to overlapping data.
- **`:bulk`** — the lifecycle hook's SELECT-then-bulk-delete-then-
  bulk-insert is not atomic across threads. Races possible.
- **`:per_call`** — the SELECT-then-DELETE-then-INSERT pattern is
  not atomic across threads. Races possible.

Operators with concurrent writes pin via
`MM_SEMANTICA_DISPATCH_MODE=sparql_update`. Single-threaded apps
(the common Rails request-per-thread case) see no behavioural
difference between the modes.

Test isolation under shared store requires `rdf_clear` between
examples; parallel test workers (e.g. `rspec-parallel`) will
clobber each other's stores. Run gem-consuming specs serially.

## Why opt-in?

Rails apps that don't add this gem keep their existing ActiveRecord
queries unchanged. Apps that DO add this gem can mix — SPARQL for graph
traversal, AR for relational lookups, in the same model.

The gem's surface follows MagenticMarket's structured-envelope
discipline: every refusal carries `{ ok: false, reason:, because: }`
verbatim because-clauses (Architect's-No #18). Operators branch on
`result[:ok]` rather than rescuing.

## What's stable vs. still mutable

**Pinned at v0.1.0** (renames or removals will earn a CHANGELOG
heading + a coordinated substrate bump):

- `Vv::Graph::Sparql.{select,ask,construct,execute}` method names + envelope shape (additive fields safe).
- `Vv::Graph::Sparql` `:reason` symbols (`:sparql_parse_error`, `:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`).
- `Vv::Graph::Loader.{ensure_extension_loaded!,extension_path,searched_paths}` surface + `ExtensionMissing` class.
- `VV_GRAPH_SQLITE_SPARQL_PATH` env var.
- N-Triples object encoding from `TermSerializer` (String/Integer/Float/Boolean/Time/Date type-dispatch).

**Pinned at v0.2.0** (additive on top of v0.1.0):

- `triples do; on_subject(lambda) do; … end; end` DSL block.
- `triples do; each(collection_lambda) do |item|; triple "pred", ->{...}; end; end` DSL block; predicate may be String or lambda.
- `triple "pred", "<urn:literal-iri>"` literal-string second arg.
- `TermSerializer.object(Hash | Array)` → JSON-encoded `xsd:string` literal.
- `Vv::Graph::Sparql.execute("DELETE WHERE { <s> <p> ?o }")` envelope `{ ok:, count: }`.

**Pinned at v0.3.0** (additive on top of v0.2.0):

- `Vv::Graph::Sparql.execute(arbitrary_sparql_update)` envelope `{ ok:, count: <signed integer> }`. The four fast paths still return positive counts; the widening from unsigned to signed only affects the arbitrary-UPDATE fallback.
- `Vv::Graph::Sparql` `:reason` symbol `:sparql_eval_error`.
- `Vv::Graph::Storable.dispatch_mode` reader → `:sparql_update | :bulk | :per_call`. One-shot probe; cached process-wide; reset via `dispatch_mode_reset!`.
- `MM_SEMANTICA_DISPATCH_MODE` env var forces a mode for predictable behaviour across upgrades (lifetime ≥ v1.0).

**Pinned at v0.4.0** (additive on top of v0.3.0):

- `Vv::Graph::Sparql.bulk_insert(rows)` → `{ ok:, inserted: <integer> }`. `:inserted:` reflects engine set semantics (dedup-aware).
- `Vv::Graph::Sparql.bulk_delete(rows)` → `{ ok:, deleted: <integer> }`.
- Row shapes: `Array<Hash{s:, p:, o:, graph:?}>` and `Array<Array>` 3/4-tuple — equivalent.
- Abort-batch-on-error semantics: any malformed row refuses the whole batch; `:because:` carries `"row <N>: …"`.
- `Storable.dispatch_mode == :bulk` lights up: 1 `bulk_delete` + 1 `bulk_insert` per save regardless of declared-predicate count.

**Pinned at v0.5.0** (additive on top of v0.4.0):

- `Vv::Graph::Sparql.{select,ask,construct,execute}(query, graph: nil_or_iri_string)` optional kwarg. `nil` (or omitted) = default graph; String = named graph.
- `triples do; graph "<iri>"; … end` DSL declaration. One graph per declaration; `on_subject` + `each` blocks inherit. Captured at recording time.
- `Storable.dispatch_mode` graph-equivalence: all three modes produce identical end states for a graph-scoped model.
- `Vv::Graph::Sparql` `:reason` symbols `:invalid_graph` (blank-node graph IRIs) + `:invalid_dsl` (ambiguous `CLEAR` + `graph:`).

**Pinned at v0.6.0** (additive on top of v0.5.0):

- `Vv::Graph::Sparql.store_size(graph: …)` → `{ ok:, count: <integer> }`. Omitted graph = `rdf_count_all` (every graph); explicit `nil` = default-graph only; String = named-graph.
- `Vv::Graph::Loader.engine_version` reader → `String` or `Vv::Graph::Loader::ENGINE_VERSION_UNKNOWN` (`:unknown`). Shape pinned; underlying probe grows when the engine ships `rdf_version()`.
- Cross-connection visibility property: a write from connection A is visible from connection B (same process), across threads, across named-graph scopes. Pinned by spec.
- `Storable.dispatch_mode` concurrency contract: `:sparql_update` is atomic per predicate; `:bulk` and `:per_call` race under concurrent writes to the same `(subject, predicate)`. See `## Concurrency`.

**Pinned at v0.7.0** (additive on top of v0.6.0):

- `Vv::Graph::EtherealGraph` concern.
- `ethereal_graph do; iri ->{...}; checkpoint_on :explicit|:save; end` DSL.
- `has_one_attached :vv_graph_blob` (auto-registered when Active Storage is available; opt-in dependency).
- `#hydrate_ethereal_graph!` → `{ ok:, hydrated: <integer>, reason?: :no_blob | :already_hydrated | :empty_blob }`.
- `#checkpoint_ethereal_graph!` → `{ ok:, written: <byte_count> }`.
- `#retract_ethereal_graph!` (registered as `before_destroy`).
- `Vv::Graph::EtherealGraph.evict!(iri)` escape hatch.
- New `:reason` symbols: `:no_blob`, `:already_hydrated`, `:empty_blob`, `:ethereal_graph_undeclared`.

**Pinned at v0.13.0** (additive on top of v0.7.0; six PLANs land between):

- **SPARQL-star pass-through** (v0.8.0 Phase A) — `Sparql.{select,ask,construct,execute}` accept `<< s p o >>` quoted-triple syntax verbatim; bindings come back as N-Triples-star strings. Multi-line `INSERT DATA` bodies route through `INSERT WHERE` (the `rdf_load_ntriples` fast path is line-strict).
- **`Vv::Graph::Reasoner`** (v0.9.0) — `materialise!(asserted:, inferred:, rules:, provenance:, max_iterations:)` envelope `{ ok:, iterations:, derived:, fixpoint:, per_rule: }`. `Rules::OwlRl` (15 core W3C OWL 2 RL rules); `Rules::PHASE_B_PENDING` lists the deferred ~55. Refusals: `:invalid_graph`, `:invalid_dsl`, `:rule_set_unknown`, `:reasoner_diverged`.
- **`Vv::Graph::Shacl`** (v0.10.0) — `validate(data_graph:, shapes_graph:, report_graph:, provenance:)` envelope `{ ok:, conforms:, violations:, report_graph: }`. `Constraints::Core` (12 SHACL Core components); `Constraints::PHASE_B_PENDING` lists the deferred ~18. Validation report is a W3C-conformant `sh:ValidationReport` graph with the six pinned predicates per `sh:ValidationResult`. Refusals: `:shape_parse_error`, `:unknown_constraint_component`, `:cycle_detected`.
- **`Vv::Graph::ChangeSet`** (v0.11.0) — value object + `capture(scope:) { … }` block API. Records adds/retracts from `Sparql.execute INSERT DATA / DELETE DATA` and `bulk_insert` / `bulk_delete`. Nested captures raise `NestedCaptureError`; cross-scope writes raise `ScopeMismatch`.
- **`Vv::Graph::Shacl::Rules`** (v0.12.0) — `materialise!(data_graph:, shapes_graph:, inferred:, rules:, provenance:, max_iterations:)` envelope `{ ok:, iterations:, rules_fired:, derived:, per_rule:, fixpoint: }`. `Rule` / `TripleRule` / `SparqlRule` value-object hierarchy. `sh:order` ordering, `sh:deactivated` skip, `sh:condition` gating via recursive `Shacl.validate`. Refusals: `:rule_parse_error`, `:unknown_rule_type`, `:condition_shape_missing`.
- **`Vv::Graph::Scope`** value object (v0.13.0) — five roles (`data` / `schema` / `shapes` / `inferred` / `report`) + `additional:` Hash; `#read_graphs` / `#write_graphs` / `#read_write_overlap?` / value equality / `Scope.registry`; `Scope.from_(iri)` factory; `Scope::FacadeAdapter` shared resolver.
- **`scope:` kwarg** on every facade (v0.13.0) — `Sparql.{select,ask,construct,execute}`, `Reasoner.materialise!`, `Shacl.validate`, `Shacl::Rules.materialise!`, `ChangeSet.capture`. Refusals: `:scope_kwarg_conflict`, `:scope_role_missing`, `:scope_read_write_overlap`.
- **`Sparql.split_ntriple`** (v0.13.0) recognises `<< s p o >>` as a single token (balanced-bracket on `<<` / `>>` pairs); `EtherealGraph` hydrate round-trips N-Triples-star blob contents.
- **Capability predicates** (v0.13.0) — `Vv::Graph.rdf_star_writes_enabled?`, `Vv::Graph.facade_version`, `Vv::Graph.checkpoint_can_round_trip?(content_kind:)`. Introspection-driven (no version constants); content_kind: `:plain_ntriples` / `:ntriples_star`; unknown kinds raise `ArgumentError`.
- **Engine floor** bumped to `sqlite-sparql ≥ 0.8.0`.

**Pinned at v0.14.0** (additive on top of v0.13.0):

- **`Vv::Graph::Sparql.quoted_triple(s, p, o)`** — operator-facing marker (frozen `QuotedTriple` Struct) with recursive `to_ntriples_star` for nested quoted triples (`<< << s p o >> p o >>`). Accepted in `Sparql.bulk_insert` / `bulk_delete` row `:s` and `:o` positions; recognised by `Storable::TermSerializer.iri` / `.object`.
- **`Storable` `annotate` block** inside `triple` declarations — attaches RDF-star annotations to the parent triple's quoted-triple form. Annotation `if:` falsy skips; parent `if:` falsy skips both. Update-time parent-object changes orphan prior annotations (SPARQL-star referential opacity); destroy retracts the whole chain.
- **`bulk_insert` row shapes for RDF-star** — `QuotedTriple` marker OR 3-element nested Array `[s, p, o]` shorthand in `:s` / `:o`. Predicate position stays IRI-only; quoted-predicate refuses `:invalid_dsl`. Pre-serialised `<< s p o >>` strings work via `raw: true`.
- **`Reasoner` `:derivedBy` provenance** — every derived triple gets `<< s p o >> <urn:vv-graph:derivedBy> <urn:vv-graph:reasoner:rule:<id>>` when `provenance: true` (default). `Vv::Graph::Reasoner.rule_iri(rule_id)` factory. `:derivedAt` + `:derivedFrom` predicate IRIs reserved; values deferred to a follow-up phase. `Vv::Graph.rdf_star_writes_enabled?` flips to `true`.

**Still operator-fluid** (may change without deprecation cycle
during v0.x.x):

- The `triples do ... end` DSL helper set — new helpers (e.g.
  `triples_from:`) may appear; `subject` / `triple` / `if:` stay.
- `MM_SEMANTICA_SOFT_FAIL` (interim-window boot escape) — removed
  when the substrate's Phase E cutover lands.
- The relative ordering of `OntologyResolver` cascade tiers when
  consumed by the substrate.

When the substrate's consumption settles, the operator-fluid list
empties + the v1.0 contract is published.

## License

MIT OR Apache-2.0 at the operator's option. See `LICENSE-MIT` and `LICENSE-APACHE`.

## Pre-release check

```bash
cd vendor/sqlite-sparql && cargo build --release
cd ../vv-graph && bin/check
```

`bin/check` locates the engine artifact (or warns + continues) and
runs `bundle exec rspec`. Contract specs run unconditionally;
round-trip specs skip with a build hint when the `.dylib` / `.so`
isn't on disk.

## Cross-references

- [`docs/plans/PLAN_0.1.0.md`](docs/plans/PLAN_0.1.0.md) — this gem's
  own roadmap to a shippable 0.1.0.
- [`docs/plans/PLAN_0.2.0.md`](docs/plans/PLAN_0.2.0.md) — the v0.2.0
  DSL extensions (multi-subject, each blocks, JSON literals).
- [`docs/plans/PLAN_0.3.0.md`](docs/plans/PLAN_0.3.0.md) — the v0.3.0
  arbitrary-UPDATE pass-through + dispatch-mode ladder.
- [`docs/plans/PLAN_0.4.0.md`](docs/plans/PLAN_0.4.0.md) — the v0.4.0
  bulk-write surface + `:bulk` dispatch implementation.
- [`docs/plans/PLAN_0.5.0.md`](docs/plans/PLAN_0.5.0.md) — the v0.5.0
  named-graph support (`graph:` kwarg + `graph "…"` DSL).
- [`docs/plans/PLAN_0.6.0.md`](docs/plans/PLAN_0.6.0.md) — the v0.6.0
  shared-store posture (`store_size` helper, `engine_version` reader,
  cross-connection visibility, concurrency note).
- [`docs/plans/PLAN_0.7.0.md`](docs/plans/PLAN_0.7.0.md) — the v0.7.0
  ethereal graphs (Active Storage-backed per-record named graphs).
- [`docs/plans/PLAN_0.8.0.md`](docs/plans/PLAN_0.8.0.md) — RDF-star
  (quoted triples + `annotate` DSL + `bulk_insert` row shape).
- [`docs/plans/PLAN_0.9.0.md`](docs/plans/PLAN_0.9.0.md) — OWL 2 RL
  reasoning (rule library + fixpoint iteration + `:derivedBy`
  provenance).
- [`docs/plans/PLAN_0.10.0.md`](docs/plans/PLAN_0.10.0.md) — SHACL
  Core constraint validation.
- [`docs/plans/PLAN_0.11.0.md`](docs/plans/PLAN_0.11.0.md) —
  incremental reasoning + validation via DRed (Phase A:
  `ChangeSet`; later phases gated on `:derivedFrom`).
- [`docs/plans/PLAN_0.12.0.md`](docs/plans/PLAN_0.12.0.md) — SHACL
  Rules (`sh:TripleRule` / `sh:SPARQLRule` shape-scoped
  derivation).
- [`docs/plans/PLAN_0.13.0.md`](docs/plans/PLAN_0.13.0.md) —
  VV-driven consumer alignment (capability predicates +
  N-Triples-star hydrate fix + Scope + `scope:` kwarg).
- [`CONSUMER_REQUIREMENT_MM.md`](CONSUMER_REQUIREMENT_MM.md) — MM
  substrate's consumption surface.
- [`CONSUMER_REQUIREMENT_VV.md`](CONSUMER_REQUIREMENT_VV.md) —
  vv-memory's consumption surface (Silver-tier ethereal graphs
  + Conformer Writer).
- [`vendor/sqlite-sparql/README.md`](../sqlite-sparql/README.md) — the
  Rust SQLite extension this gem wraps.
- [`docs/research/Vv::Graph.md`](../../docs/research/Vv::Graph.md) — the
  substrate-side architectural concept the gem implements.
- [`docs/plans/PLAN_0_29_1.md`](../../docs/plans/PLAN_0_29_1.md) — the
  substrate plan that introduces this gem + the substrate's cutover
  to it (Phases E + F live there, not in this gem's PLAN).
