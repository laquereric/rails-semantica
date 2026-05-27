# Consumer requirements — `vv-grammar` (GM)

This file records the surface
[`vv-grammar`](https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-grammar)
("GM" hereafter) consumes from `vv-graph`. It exists so upstream
changes can be checked against a written consumer expectation —
**drift** between this file and the gem's actual behaviour signals
work that needs to land in both repos lockstep.

This is GM's perspective, not the upstream spec. MM and VV keep their
own analogous files (`CONSUMER_REQUIREMENT_MM.md`, `CONSUMER_REQUIREMENT_VV.md`);
the three consumption shapes differ:

- **MM** is the substrate. Uses `Storable` to emit per-record triples
  on AR lifecycle, queries via `Sparql.execute` directly.
- **VV** is the per-record named-graph layer. Uses `EtherealGraph` +
  `Sparql.execute` through a Scoped concern.
- **GM** is the *grammar-execution* layer. It lowers parsed AST nodes
  from three BASIC-flavoured mini-languages into vv-graph calls. GM
  does **not** declare its own `Storable` blocks; it consumes whatever
  triples MM and VV have produced, plus the schema/shapes scopes.

- GM repo: <https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-grammar>
- GM plan that pinned today's surface: `docs/plans/PLAN_0_1_0.md`
  (companion to the file you are reading).

## How GM pins this gem

```ruby
# vv-grammar.gemspec
spec.add_dependency "vv-graph", "~> 0.15"
```

GM pins at the rename floor (`0.15.0` — the `rails-semantica` →
`vv-graph` cutover). The minor pin floats with operator-fluid
0.x evolution. GM will move to `>= 1.0` at v1.0.

## The layering rule — load-bearing

> **GM consumes `vv-graph` directly.**
> **GM does NOT consume `sqlite-sparql` directly.**

Same rule as VV. The grammar's execution backend is vv-graph; the
fact that vv-graph happens to ride on sqlite-sparql (and that
sqlite-sparql happens to contain a Rust OWL 2 RL reasoner) is
visible to GM as **capability questions answered by vv-graph**,
never as direct calls into the Rust crate.

Concretely:

1. GM's gemspec declares `vv-graph`. It does **not** declare
   `sqlite-sparql`. The engine is vv-graph's private dependency.
2. GM's `lib/`, `spec/` may reference `Vv::Graph::*` constants
   freely. They may **not** reference `Sqlite::Sparql::*`,
   `rdf_*`, `sparql_*`, or any internal scalar by name.
3. When GM needs a new behaviour from the engine (e.g., a SPARQL
   form the Rust dispatcher doesn't yet route), the correct move is
   to file an upstream ask on vv-graph, not to reach past the
   facade.

## Surfaces GM consumes

### `Vv::Graph::Sparql` four-method facade — load-bearing

GM's three lowerers (`InventoryDbQuery`, `ElementAction`,
`ComponentRender`) all funnel through this facade. The lowerers emit
a SPARQL string + a `graph:` IRI, hand it to `Sparql.select` /
`.ask` / `.construct` / `.execute`, and propagate the envelope into
their own `BnfParser::Result.with_envelope(...)`.

```ruby
Vv::Graph::Sparql.select(query,    graph: scope_iri)
Vv::Graph::Sparql.ask(query,       graph: scope_iri)
Vv::Graph::Sparql.construct(query, graph: scope_iri)
Vv::Graph::Sparql.execute(update,  graph: scope_iri)
```

GM's pinned expectations:

- **Never raises.** Mirrors `BnfParser::Result`'s discipline. A
  refusal is `{ ok: false, reason: <symbol>, because: <string> }`;
  GM lifts this into its own Result so the grammar caller sees one
  refusal shape regardless of who refused (parser, lowerer, or engine).
- **Stable envelope keys** (`:ok`, single payload key, `:reason`,
  `:because`). Additive new keys safe; renames breaking.
- **`graph:` composes with all four.** GM lowers `IN bhphoto`,
  session IDs, and component-shape scopes to named graphs. Per-grammar
  isolation is the whole point.
- **SPARQL-star passes through unmangled.** GM's reward-annotation
  feature (PLAN_0_1_0 Phase E) writes
  `<< ?s mm:parsedAs ?lang >> mm:score ?score` via `execute`. The
  facade preserves quoted-triple syntax verbatim.
- **`SELECT (COUNT(?s) AS ?n)` works through `.select`.** GM's
  `COUNT` statement lowers to this form.
- **`ORDER BY ASC(?p) / DESC(?p)` and `LIMIT n`** in `.select` work.
  GM's `SORT BY` and `LIMIT` rely on them.

### `Vv::Graph::Reasoner.materialise!` — load-bearing for OWL leverage

This is the *headline feature* for GM. The whole reason grammars
ground to vv-graph (versus to plain ActiveRecord) is so an
`InventoryDbQuery` `FIND printer` lowers to `?p a mm:Printer` and
the **subclass closure** (`mm:InkTankPrinter rdfs:subClassOf mm:Printer`)
applies automatically, without the grammar code knowing the subclass
exists.

GM's expectation:

```ruby
Vv::Graph::Reasoner.materialise!(
  asserted: <schema_graph_iri>,
  inferred: <inferred_graph_iri>,
  scope: :schema,
)
# => { ok: true, derived: <integer>, fixpoint_iterations: <integer> }
```

- Runs OWL 2 RL forward-chaining to fixpoint.
- Writes derived triples to the `:inferred` scope; the asserted graph
  is read-only.
- Idempotent: running twice produces no new triples (delta = 0).
- Provenance via RDF-star: derived triples carry `:derivedBy` annotations.
- **GM does NOT call `materialise!` directly per-query.** The
  substrate boots and materialises the schema once at startup;
  GM's lowerers query the already-materialised `:inferred` scope.
  Drift if vv-graph removes the inferred-scope read path.

GM does **not** depend on:

- The specific OWL 2 RL rules supported (rdfs subclass + domain + range
  + property hierarchy is enough; if more land, GM benefits passively).
- The order of rule application or iteration count.
- The internal Rust function name (`rdf_owl_rl_materialise` or any
  successor). GM only sees `Reasoner.materialise!`.

### `Vv::Graph::Shacl` — load-bearing for ComponentRender validation

GM's PLAN_0_1_0 Phase D migrates `component_registry_validator.rb` and
`prop_validator.rb` from hand-rolled Ruby into a SHACL shapes graph.
`Vv::Graph::Shacl.validate` is then what runs per-render to score the
program.

```ruby
Vv::Graph::Shacl.validate(
  data_graph:   <ast_as_graph_iri>,
  shapes_graph: <component_shapes_iri>,
)
# => { ok: true, conforms: true|false, report: <ntriples sh:ValidationReport> }
```

- Returns a `sh:ValidationReport` in N-Triples form.
- `conforms: true` ⇒ component-render program scores 1.0 syntactically.
- `conforms: false` ⇒ GM extracts violations and lowers each into a
  scored AST error.
- Stable across vv-graph 0.x: report graph shape is W3C
  (`sh:ValidationReport`, `sh:result`, `sh:resultPath`,
  `sh:resultMessage`); GM parses by walking those predicates.

GM does **not** depend on `Vv::Graph::Shacl::Rules` (the
derivation-rule variant). Plain `validate` is enough.

### `Vv::Graph::Scope` — used at the boundary, not internally

GM does not construct `Scope` value objects itself. It passes
`scope: :data | :schema | :shapes | :inferred | :report` keyword
arguments to the facade and trusts vv-graph to route. The five-role
vocabulary is pinned; renames or additions that break dispatch are
breaking from GM's POV.

### `Vv::Graph::Loader.ensure_extension_loaded!` — boot only

GM does not call the Loader directly. The substrate (MM) boots
the loader; GM is loaded by the same Rails process and inherits the
loaded extension on every AR connection. GM's spec harness:

```ruby
# spec/spec_helper.rb
require "vv-graph"
Vv::Graph::Loader.ensure_extension_loaded!
```

— the single permitted Loader reference, mirroring VV's pattern.

## Surfaces GM does NOT consume

So upstream is free to change these:

- `Vv::Graph::Storable` — GM does not declare per-model `triples` blocks.
  MM owns model-level triple emission; GM only queries the resulting
  graph. If MM stops emitting a triple GM was querying, that is an
  MM ↔ GM contract issue, not an upstream issue.
- `Vv::Graph::EtherealGraph` — GM does not own named graphs per AR
  record. VV does. When GM needs a per-session graph for
  ElementAction history, it writes to the session IRI via
  `Sparql.execute(graph: …)` directly — no `EtherealGraph` concern.
- `Vv::Graph::ChangeSet` — GM lowers single programs at a time. No
  multi-step capture needed at v0.1.0.
- `Vv::Graph::Sparql.bulk_insert` / `bulk_delete` — possible future
  use for batch program ingestion; not 0.1.0.
- The `dispatch_mode` ladder. GM treats `execute` as opaque.

## Behaviours GM does NOT depend on

- Internal SQL emitted by any path.
- Oxigraph version pinned by `sqlite-sparql`.
- Names of `:reason` symbols beyond the ones currently documented in
  MM's CR (`:sparql_parse_error`, `:sparql_eval_error`,
  `:extension_not_loaded`, `:ar_connection_error`, `:invalid_graph`,
  `:invalid_dsl`, `:unexpected_error`). GM lifts the symbol into its
  own envelope verbatim; new symbols safe to add.

## Requested extensions (toward vv-graph 0.16.x / 0.17.x)

These are GM-side asks. None block PLAN_0_1_0 Phase A; **Phase F is
gated on ask #3 below.** Each ask describes the shape GM wants, why,
and what GM would do until it lands.

### 1. `Vv::Graph::Sparql.select` returns optional column metadata — **LANDED in 0.17.0 (Phase A)**

Live as the `with_types: true` kwarg on `Vv::Graph::Sparql.select`.
Per-binding cells become frozen Hashes
`{ value:, kind:, datatype:, lang: }`. Pinned `:kind` values:
`:iri`, `:literal`, `:blank_node`, `:quoted_triple`, `:unknown`
(engine-quirk forms). `with_types: false` (default) preserves
the v0.1.0 flat-Hash shape byte-for-byte. The shared
`Vv::Graph::Sparql::TermParser` is the single parser
implementation; Backend::Sparql (v0.16.0) now delegates its
`unwrap_literal` to it. Original ask preserved below.

---

**Today.** `select` returns `{ ok: true, results: [{ "p" => "...", ... }] }`.
Column types (literal vs IRI, datatype IRIs) are not surfaced — GM
re-parses each value string to guess.

**Ask.** Optional `with_types: true` kwarg flips on a per-binding
typed payload:

```ruby
Vv::Graph::Sparql.select(query, graph: iri, with_types: true)
# => { ok: true, results: [{ "p" => { value: "...", kind: :iri | :literal,
#                                     datatype: "xsd:string", lang: nil } }] }
```

**Why.** GM's lowerers need to know whether a returned `?price` is
`xsd:decimal` vs `xsd:string` to format the result correctly into the
Result struct. Today GM regex-sniffs; that's brittle.

**Until it lands.** GM keeps the regex sniffer; a comment cites this CR.

### 2. `Vv::Graph::Sparql.explain(query, graph:)` — **LANDED in 0.17.0 (Phase B)**

Live. Returns `{ ok: true, plan: { kind:, projection:, where:,
modifiers:, ... }, estimated_rows: :unknown, from: :gem_parser }`.
The gem-side parser (`Vv::Graph::Sparql::Explain`) handles the
SPARQL slice vv-graph's own surfaces emit: SELECT, ASK,
CONSTRUCT, and the v0.3.0 UPDATE forms (INSERT DATA, DELETE
DATA, INSERT WHERE, DELETE WHERE, CLEAR, LOAD, DROP).
Unparseable forms refuse with `:sparql_parse_error`. Three
notes on how the landed shape differs from the original ask:

- **`estimated_rows: :unknown` is pinned for v0.17.0.** The
  engine has no cardinality estimator. The shape leaves room
  for an integer once a future engine release ships
  `rdf_sparql_plan`; `from:` flips `:gem_parser` →
  `:engine_planner` as the observable change. Consumers wanting
  real numbers today fall back to the
  "all-semantic-to-SPARQL, all-exact-match-to-AR" heuristic
  the original ask described.
- **The parser is intentionally narrow.** SPARQL forms outside
  the gem's own emission slice (e.g. nested SELECTs, complex
  GROUP_CONCAT aggregations) return `:sparql_parse_error`
  rather than a partially-populated plan. Consumers needing
  richer coverage file a follow-up ask.
- **Read-only.** `explain` never executes the query. Engine
  validity is not checked — operators who want syntax linting
  run the query.

Original ask preserved below.

---

**Today.** No way to ask vv-graph what the engine would actually do
with a query before running it.

**Ask.** A read-only `explain` that returns a structured plan
(`{ ok: true, plan: { kind: :bgp, patterns: [...], estimated_rows: 42 } }`)
or, if the engine can't plan, falls back to an opaque-string echo.

**Why.** GM's hybrid lowerer (SPARQL vs ActiveRecord) wants to make
the SPARQL-vs-AR decision based on estimated cost, not heuristics.

**Until it lands.** GM lowers all "semantic" queries (OWL-leveraging,
subclass-aware, type-typed) to SPARQL and lowers all "exact-match
indexed-column" queries to AR. The cost-aware path is deferred.

### 3. **SQL schema normalization on boot.** ⭐ *Headline ask.* — **LANDED in 0.16.0 (Phase D)**

Live as `Vv::Graph::Loader.normalize_schema!(iri_prefix:, include:,
exclude:, schema_graph:)`. Emits the deterministic RDF mapping
below into the `:schema` named graph (default
`urn:vv-graph:schema`). Idempotent (CLEAR GRAPH runs first).
Default-excluded: `ar_internal_metadata`, `schema_migrations`,
`active_storage_*`, `action_text_*`. Return envelope:
`{ ok: true, classes:, datatype_properties:, object_properties:,
schema_graph: }`. Two notes on how the landed shape differs from
the original ask:

- **No `iri_separator:` knob in 0.16.0.** The separator is
  hard-coded as `/`. Revisit on operator signal — the field-IRI
  convention `<prefix><Model>/<column>` is a published contract
  the moment a downstream lowerer reads from `:schema`.
- **No `xsd_mapping:` override.** The default mapping ships
  hard-coded (`AR_TYPE_TO_XSD_IRI`); operators wanting a
  different `xsd:dateTime`-shape register a `Schema.override(
  model:, name:, xsd: …)` per field rather than swapping the
  whole table. Revisit if the per-field shape proves too granular.
- **`rdfs:label` triples not emitted.** Tables and columns are
  typed but not labelled. Revisit on a grammar that needs the
  display string.

See `docs/plans/PLAN_0.16.0.md` Phase D and
`lib/vv/graph/loader.rb` (`normalize_schema!`) for the full
contract. Original ask preserved below for historical context.

---

**Today.** vv-graph's loader probes the extension, then idles. The AR
schema (`ActiveRecord::Base.connection.tables` + column types + FKs)
is **not** read into the graph. Consumers wanting a triple-shaped view
of their tables must hand-write `Storable` blocks per model.

**Ask.** A new `Vv::Graph::SchemaNormalizer` (or
`Vv::Graph::Loader.normalize_schema!`) that runs at boot **after**
the loader, reads the AR connection's schema, and emits a deterministic
RDF mapping into the `:schema` scope:

```turtle
# For each AR model class:
mm:Product a owl:Class ;
  rdfs:label "Product" ;
  rdfs:subClassOf mm:DbBackedEntity .

# For each column:
mm:Product/sku a owl:DatatypeProperty ;
  rdfs:domain mm:Product ;
  rdfs:range  xsd:string ;
  rdfs:label  "sku" .

# For each FK:
mm:LineItem/product_id a owl:ObjectProperty ;
  rdfs:domain mm:LineItem ;
  rdfs:range  mm:Product .
```

Configuration knobs the normalizer should accept:

- `iri_prefix:` (default `mm:`), `iri_separator:` (default `/`).
- `include_models: [...]` / `exclude_models: [...]` for selective
  emission (don't normalize internal Rails tables like
  `ar_internal_metadata`, `schema_migrations`).
- `xsd_mapping:` — operator-overridable `ar_type → xsd_datatype`
  table. Default: standard mapping (`:string` → `xsd:string`,
  `:datetime` → `xsd:dateTime`, etc.).

Output shape:

```ruby
Vv::Graph::Loader.normalize_schema!(iri_prefix: "mm:")
# => { ok: true, classes: <int>, datatype_props: <int>, object_props: <int> }
```

**Why this is the headline ask.** Without it, every grammar that
wants to reference `price` or `brand` carries a hand-written
`field → property_iri` table that drifts from the AR schema the
first time someone runs a migration. GM v0.1.0 ships these tables
*reluctantly*. Schema normalization is the milestone that makes
"ground ALL grammars" tractable without a Storable march across
every AR model in the substrate.

**Why this belongs in vv-graph, not vv-grammar or MM.** vv-graph
already owns the AR connection lifecycle (via Loader). It already
owns the `:schema` scope. It is the single place where "this graph
reflects this database" can live without crossing the
engine-substitutability boundary VV pinned in
CONSUMER_REQUIREMENT_VV.md. If a future vv-graph swaps sqlite-sparql
for Oxigraph-embedded, schema normalization moves with the gem.

**Note on materialisation cost.** Normalization emits *schema*
triples only (one per table + one per column + one per FK). It does
**not** materialise a triple per row. Row-level mapping is either
left in SQL (queried via AR by GM's escape-hatch path) or addressed
by a future virtual-graph / SQL-vtab integration on the sqlite-sparql
side. The schema-only normalization is cheap and finite (~hundreds
of triples for a substrate-sized schema).

**Until it lands.** GM ships hand-written
`InventoryDbQueryLowerer::FIELD_IRI_MAP` etc. per lowerer.
PLAN_0_1_0 Phase F deletes those maps the day this ships.

### 4. Capability predicate: `Vv::Graph.schema_normalized?` — **LANDED in 0.16.0 (Phase D)**

Live. Flips to `true` after the first successful
`Vv::Graph::Loader.normalize_schema!`. Pairs with a richer
introspection accessor `Vv::Graph.schema_normalization_info →
{ schema_graph:, iri_prefix: }` for consumers needing the
captured graph IRI / prefix. Behaviour matches the original ask
shape verbatim. Original ask preserved below for historical
context.

---

Pairs with ask #3. GM's lowerers want to ask "is the schema scope
populated?" without parsing version strings or counting triples:

```ruby
if Vv::Graph.schema_normalized?
  # query :schema scope for the field's IRI
else
  # fall back to hardcoded FIELD_IRI_MAP
end
```

Add to the existing capability-predicate set on the `Vv::Graph` module.

### 5. SHACL shapes loader — **LANDED in 0.17.0 (Phase C)**

Live as `Vv::Graph::Shacl.load_shapes(source, format: :ttl,
scope: nil)`. Accepts a file path, an inline string body, or
an IO. `format: :ttl` (default) routes through engine
`rdf_load_turtle_to_graph`; `format: :nt` routes through
`Sparql.execute("INSERT DATA …")` after a line-based normalise.
Default scope `urn:vv-graph:shapes`. Idempotent — SHA-256 of
the canonicalised input lives in `urn:vv-graph:shapes:meta`;
matching hash returns `{ ok: true, loaded: 0, reason:
:unchanged }` without touching the shapes scope. Pinned refusal
symbols `:shapes_file_missing`, `:shapes_format_unknown`,
`:shapes_parse_error`. Original ask preserved below.

---

**Today.** Shapes are loaded by N-triples insert into the `:shapes`
scope. Each consumer reinvents the loader.

**Ask.** `Vv::Graph::Shacl.load_shapes(path_or_string, format: :ttl | :nt)`
that reads a shapes file and inserts into the `:shapes` scope,
returning `{ ok: true, loaded: <int> }`. Idempotent (re-load is a
no-op if checksums match).

**Why.** GM ships a `component_shapes.ttl` file with v0.1.0.
Without a loader, every spec example reinvents the parse-and-insert
dance. Phase D specs become 6× longer than they need to be.

**Until it lands.** GM ships an inline loader in
`spec/support/shape_loader.rb` and a TODO citing this ask.

## Drift signals

A drift between this file and vv-graph's behaviour is detectable in:

- GM's `spec/lowerers/inventory_db_query_lowerer_spec.rb` (Phase B) —
  fails when `Sparql.select` envelope shape or `:schema`-scope OWL
  closure semantics drift.
- GM's `spec/lowerers/element_action_lowerer_spec.rb` (Phase C) —
  fails when SPARQL-star `INSERT DATA` through `Sparql.execute`
  loses quoted-triple syntax.
- GM's `spec/lowerers/component_render_lowerer_spec.rb` (Phase D) —
  fails when `Shacl.validate` report graph shape drifts from W3C.

Drift fix path:

1. Open an upstream PR on vv-graph with the corrected behaviour +
   a new upstream spec.
2. Land it; record the new SHA in the substrate's `Gemfile.lock`.
3. Bump GM's pin + update this file if the consumer expectation
   changed.

Never fix drift by patching vv-graph from inside vv-grammar. The
boundary stays bright in both directions.

## Versioning expectation

While vv-graph is v0.x.x, GM ships surface refinements as upstream
PRs authored against vv-graph. GM does not monkey-patch vv-graph
from inside its own gem; if GM's needs would require that, the
upstream PR needs to land first.

At vv-graph v1.0 these surfaces are pinned by semver. GM will move
its dependency line from `~> 0.15` to `~> 1.0` at that point and
delete the asks above that landed.
