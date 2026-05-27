# PLAN_0.16.0 — vv-graph: QueryIR, storage backends, capability router

**Status.** Draft.
**Target gem version.** `vv-graph` v0.16.0.
**Author.** Architect (Eric).
**Date.** 2026-05-26.
**Sibling plan.** `vendor/vv-grammar/docs/plans/PLAN_0_1_0.md` — the
downstream consumer; its Phase D and Phase E depend on this plan.

## Intent

vv-graph today exposes a SPARQL facade
(`Vv::Graph::Sparql.{select,ask,construct,execute}`) over the
`sqlite-sparql` extension. That facade is the *only* read path; every
consumer that wants storage-agnostic reads has to either compose
SPARQL strings (coupling them to RDF semantics) or reach around
vv-graph into ActiveRecord (defeating the abstraction).

This plan introduces a small, frozen **query algebra** (`QueryIR`)
plus **two backends** — the existing SPARQL plane and a new
ActiveRecord/SQL plane — selected by a **capability-aware router**.
Consumers (vv-grammar today, vv-learn future) lower to `QueryIR`;
vv-graph executes. The day vv-learn decides the substrate's source of
truth moves from RDF to RDBMS — or runs both side-by-side — that
decision flips a router default and nothing else.

vv-graph remains the storage-substitutability boundary VV's
[CONSUMER_REQUIREMENT_VV.md](../../CONSUMER_REQUIREMENT_VV.md) pinned.
QueryIR widens that boundary from "abstract over RDF stores" to
"abstract over storage planes." The SPARQL facade is **unchanged**;
QueryIR is purely additive.

## Why this lives in vv-graph (not in any consumer)

- vv-graph already owns the AR connection lifecycle (Loader) and the
  five-role `Vv::Graph::Scope` vocabulary (including `:schema`).
- vv-graph already wraps every concern QueryIR needs as a
  capability: OWL closure (`Reasoner`), SHACL (`Shacl`), named graphs
  (`graph:` kwarg), envelope discipline. Cataloguing those into a
  capability map is a natural extension of the gem's existing role.
- Multiple consumers want the same algebra. vv-grammar lowers three
  grammars (soon N) to it; vv-learn will lower its own DSL to it;
  MM may simplify some of its raw `Sparql.execute` call sites by
  going through it. Putting the IR in any one consumer forces the
  others to either depend on that consumer or duplicate the work.
- The relational backend needs deep AR awareness (column types,
  associations, scopes, transactions). vv-graph already lives next
  to AR; pushing this into a consumer gem would push that coupling
  too.

## QueryIR — frozen algebra for v0.16.0

```ruby
Vv::Graph::QueryIR::Find         (type:, scope:)
Vv::Graph::QueryIR::Filter       (field:, op:, value:)
Vv::Graph::QueryIR::FilterRange  (field:, lo:, hi:, inclusive: true)
Vv::Graph::QueryIR::FilterIn     (field:, values:)
Vv::Graph::QueryIR::Sort         (field:, dir: :asc | :desc)
Vv::Graph::QueryIR::Limit        (n:)
Vv::Graph::QueryIR::Project      (fields:)
Vv::Graph::QueryIR::Count        ()
Vv::Graph::QueryIR::Compare      (field:, left:, right:)
```

Composition is a flat list. `Find` is required and comes first; one
`Limit` max; one `Sort` max for v0.16.0 (multi-sort additive in
v0.17.0); `Project` defaults to all schema-known fields.

**Field references are symbolic.** Consumers pass `field: :brand`,
not `field: "mm:Product/brand"` or `field: "products.brand"`. The
backend resolves via `Vv::Graph::Schema` at execute time. This is
what lets the same IR run on both planes without consumer changes.

## Execution surface

```ruby
Vv::Graph::QueryIR.run(ir, scope:, backend: nil, with_meta: false)
# ir       : Array<QueryIR::*>
# scope    : graph IRI (sparql) or model namespace (relational); both safe
# backend  : :sparql | :relational | nil (router decides)
# with_meta: include { plan:, backend:, ms: } in envelope
# =>
# { ok: true,  results: [...], from: :sparql | :relational, ... }
# { ok: false, reason: <symbol>, because: <string>, ... }
```

Never raises. Same envelope discipline as the existing SPARQL
facade. New `:reason` symbols pinned by this plan:

- `:backend_missing_capability` — query needs a capability the
  routed backend lacks (e.g. OWL closure on relational v0.16.0).
- `:schema_field_unknown` — `field:` symbol not in the Schema adapter.
- `:ir_invalid` — IR list violates the composition rules above.

## Backend interface

```ruby
module Vv::Graph::Backend
  def execute(ir, scope:)        # => envelope
  def capabilities               # => { owl_closure:, shacl:, joins:,
                                  #      datetime_filter:, fts:, ... }
  def supports?(ir)              # => true | { missing: [...] }
end
```

Two concrete backends ship in v0.16.0:

### `Vv::Graph::Backend::Sparql`

Wraps the existing facade verbatim. Lowers `QueryIR` to SPARQL
strings; runs through `Vv::Graph::Sparql.{select,ask}` with
appropriate `graph:` routing. Inherits OWL closure (when the
`:inferred` scope is populated by `Reasoner.materialise!`) and
SHACL (capability flag `shacl: true` even though `QueryIR` doesn't
expose SHACL directly — it composes with `Vv::Graph::Shacl.validate`
on the same data graph).

Capability defaults (v0.16.0):

```ruby
{ owl_closure: true, shacl: true, joins: :rdf, datetime_filter: true,
  fts: false, named_graphs: true }
```

### `Vv::Graph::Backend::Relational`

Lowers `QueryIR` to ActiveRecord scopes. `Find(type: :Product)` →
`Product.all`; `Filter(field: :brand, op: :eq, value: "Epson")` →
`.where(brand: "Epson")`; `Sort` → `.order(...)`; `Limit` →
`.limit(...)`; `Count` → `.count`; `Compare` → two `find_by` calls
paired in Ruby. Field resolution via `Schema.field(...).ar_column`.

Capability defaults (v0.16.0):

```ruby
{ owl_closure: false, shacl: false, joins: :ar, datetime_filter: true,
  fts: false, named_graphs: false }
```

`owl_closure: false` is the headline gap. vv-learn's future plan
will lift it (either via materialised closure tables, an
ontology-aware view layer, or by leaving closure on the sparql
plane and routing only closure-requiring queries there).

## Router

```ruby
Vv::Graph::Backend::Router.pick(ir, hint: nil)
# Picks via, in order:
# 1. Explicit hint (`backend: :sparql | :relational` on the call).
# 2. Env override (`VV_GRAPH_QUERY_BACKEND=sparql|relational`).
# 3. Capability fit (does the IR need anything one backend lacks?).
# 4. Configured default (`Vv::Graph.config.default_query_backend`,
#    default `:sparql` until vv-learn flips it).
```

When step 3 produces an unambiguous winner, the router prefers it
even if step 4 disagrees. When step 3 says "both can run it," step 4
wins.

When an IR needs capabilities **neither** backend has, the router
returns `{ ok: false, reason: :backend_missing_capability, because:
"... missing: [owl_closure]", available_backends: [:sparql, :relational] }`.
Consumers can re-attempt with a different `hint:` or lift the
refusal.

## Schema adapter

```ruby
Vv::Graph::Schema.field(model:, name:)
# => { iri: "mm:Product/brand", ar_column: "brand",
#      xsd: "xsd:string", supports_closure: false }
```

Read sources, in order of preference:

1. The `:schema` scope (if populated by the normalizer below).
2. The AR schema (`ActiveRecord::Base.connection.columns` + reflections).
3. A configurable override table (operator-supplied for non-default
   mappings).

`iri:` is computed from a configurable prefix (default `mm:`) when
the `:schema` scope is absent. `supports_closure:` is true only when
the field's property is declared in the `:schema` scope **and** the
reasoner has been run.

## Schema normalization (CR-GM ask #3, satisfied here)

`Vv::Graph::Loader.normalize_schema!(iri_prefix: "mm:", include: [...],
exclude: [...])` reads AR's schema on demand and emits a deterministic
RDF mapping into the `:schema` scope:

- For each AR model class: `mm:Product a owl:Class`.
- For each column: `mm:Product/sku a owl:DatatypeProperty ; rdfs:domain
  mm:Product ; rdfs:range xsd:string`.
- For each FK: `mm:LineItem/product_id a owl:ObjectProperty ;
  rdfs:domain mm:LineItem ; rdfs:range mm:Product`.

Idempotent. Schema-only — no row materialisation. Default-excluded
internal tables: `ar_internal_metadata`, `schema_migrations`,
`active_storage_*`, `action_text_*`.

Pairs with a capability predicate:

```ruby
Vv::Graph.schema_normalized?   # => true | false
```

This satisfies CR-GM asks #3 and #4 in one go.

## Phases

Four phases. Each is independently mergeable, ends green, and bumps a
sub-version inside the v0.16.0 window. The SPARQL facade is untouched;
existing MM/VV pins remain valid throughout.

### Phase A — QueryIR + Sparql backend

- `lib/vv/graph/query_ir/*.rb` — frozen algebra value objects.
- `lib/vv/graph/backend.rb` — interface + capability map type.
- `lib/vv/graph/backend/sparql.rb` — IR → SPARQL string compiler;
  delegates execution to existing `Vv::Graph::Sparql.{select,ask}`.
- `lib/vv/graph/query_ir.rb` — `.run` entry point. Phase A always
  picks the sparql backend (router not yet wired).

**Tests.** Compiler unit tests for each IR node → SPARQL fragment.
End-to-end specs for the 8 representative IR programs introduced in
PLAN_0_1_0 Phase A — same suite that vv-grammar imports.

**Exit.** `Vv::Graph::QueryIR.run` works for any IR program on the
sparql backend. Envelope shape matches the existing facade.

### Phase B — Relational backend + Schema adapter + parity harness

- `lib/vv/graph/backend/relational.rb` — IR → AR scope compiler.
- `lib/vv/graph/schema.rb` — AR-introspection-first adapter.
- `spec/parity/query_ir_parity_spec.rb` — the load-bearing test
  suite. Each example runs the same IR through both backends and
  asserts row-identity (sorted, projected the same way). Capability
  gaps are recorded as `pending` with the IR's missing-capability
  list.

**Tests.** Parity suite green for every IR program that doesn't
require OWL closure or SHACL. Closure-requiring IRs are `pending
"needs vv-learn relational closure plane"`, citing this plan.

**Exit.** Two backends; one envelope; one parity suite. vv-grammar
Phase D unblocked.

### Phase C — Router + capability gating + env override

- `lib/vv/graph/backend/router.rb` — the picker described above.
- `lib/vv/graph/config.rb` extensions — `default_query_backend`,
  `query_backend_override_env`.
- `Vv::Graph::QueryIR.run` wires the router in; `backend:` hint
  param works; env override works; capability refusals work.

**Tests.** Router unit tests for each precedence layer. End-to-end
refusal spec for an OWL-closure query routed to relational.

**Exit.** Backend selection is observable, testable, and operator-
controllable.

### Phase D — Schema normalizer + capability predicate

- `lib/vv/graph/loader.rb` extension —
  `Vv::Graph::Loader.normalize_schema!`.
- `Vv::Graph.schema_normalized?` capability predicate.
- Schema adapter starts reading from `:schema` scope when
  `schema_normalized?` is true.

**Tests.** Normalize a 3-model AR schema; assert classes + datatype
properties + object properties land in `:schema`; re-running is a
no-op; the adapter's `field(...)` switches its `iri:` source.

**Exit.** v0.16.0 ships. CR-GM asks #1 (column metadata — note
QueryIR's `with_meta:` partially covers; full coverage of `with_types:`
on the legacy `Sparql.select` remains separate), #3 (schema
normalization), and #4 (capability predicate) are satisfied.

## Out of scope for v0.16.0

- Multi-sort, `OFFSET`, full-text-search, sub-queries, joins beyond
  the trivial `rdfs:domain`/`rdfs:range` traversal. All additive in
  v0.17.x.
- `Sparql.explain` (CR-GM ask #2). Still a separate plan; QueryIR's
  `with_meta: true` returns a structured plan for QueryIR programs,
  but the legacy SPARQL facade is untouched here.
- Write IR. Writes continue through `Vv::Graph::Sparql.execute` and
  `Vv::Graph::Storable`. When vv-learn ships the relational plane,
  `Sparql.execute` may grow router-routed dispatch internally — but
  its public surface stays the four-method envelope. Consumers do
  not need a new write API.
- SHACL on the relational backend. Capability flag stays `shacl:
  false` for relational v0.16.0; lifting it is vv-learn's plan.
- A relational OWL closure plane. Same — vv-learn's plan.

## Consumer impact

- **MM** (CONSUMER_REQUIREMENT_MM.md): no break. Existing surfaces
  unchanged. MM *may* migrate some hand-composed `Sparql.execute`
  reads to `QueryIR.run` opportunistically; not required.
- **VV** (CONSUMER_REQUIREMENT_VV.md): no break. VV uses
  `EtherealGraph` + `Sparql.execute`, both unchanged. The "lean
  harder on vv-graph surfaces" doctrine in VV's CR points toward
  eventual QueryIR adoption but is not gated.
- **GM** (CONSUMER_REQUIREMENT_GM.md): Phase B + D directly satisfy
  asks #3 and #4. vv-grammar Phase D pins `~> 0.16` to consume
  `Vv::Graph::QueryIR.run`. Asks #1 (column metadata on `Sparql.select`)
  and #5 (SHACL shapes loader) remain — not addressed here.

## Open questions

1. **Backend selection for mixed-capability programs.** When a
   single IR has both an OWL-closure-requiring filter and an
   indexed-column equality filter, does the router split execution
   or refuse? v0.16.0: refuse with `:backend_split_unsupported`;
   v0.17.0 may add split execution if vv-learn needs it.
2. **Compare semantics across backends.** `QueryIR::Compare` on
   sparql does two `?val WHERE { <urn:A> mm:field ?val }` queries.
   On relational it's two `find_by`. When the two backends disagree
   (e.g. relational returns `nil` for a missing column, sparql
   returns an empty result set), does the envelope normalize?
   Decide before Phase B.
3. **Where does `Schema.field`'s override table live?** A Ruby
   config block on `Vv::Graph.config`, a YAML file, or both?
   Lean: Ruby config block only for v0.16.0; YAML is sugar for
   v0.17.x if anyone asks.

## Related documents

- `vendor/vv-grammar/docs/plans/PLAN_0_1_0.md` — downstream plan;
  Phase D and Phase E consume this gem's QueryIR surface.
- `vendor/vv-graph/CONSUMER_REQUIREMENT_GM.md` — vv-grammar's
  asks; Phase B + D here satisfy #3 and #4.
- `vendor/vv-graph/CONSUMER_REQUIREMENT_MM.md` — MM's pins; nothing
  in this plan changes them.
- `vendor/vv-graph/CONSUMER_REQUIREMENT_VV.md` — VV's pins; same.
- `vendor/sqlite-sparql/CONSUMER_REQUIREMENT_VvGraph.md` — engine
  contract that the sparql backend rides on; no engine-side change
  required for this plan.
