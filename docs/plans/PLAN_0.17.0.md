# PLAN_0.17.0 — vv-graph: SPARQL ergonomics + QueryIR additives

**Status.** Shipped (Phases A/B/C/D landed; see `CHANGELOG.md` § 0.17.0).
**Target gem version.** `vv-graph` v0.17.0.
**Author.** Architect (Eric).
**Date.** 2026-05-27.
**Sibling plan.** `vendor/vv-grammar/docs/plans/PLAN_0_1_0.md` Phase F —
the lowerers that consume `with_types:` and the schema lookup that
replaces the hand-written `FIELD_IRI_MAP` tables.

## Intent

PLAN_0.16.0 shipped the QueryIR algebra, two storage backends, the
capability router, and `Loader.normalize_schema!`. It satisfied
CR-GM asks #3 (schema normalization) and #4 (capability predicate).
Three CR-GM asks remain open — #1 (column metadata on
`Sparql.select`), #2 (`Sparql.explain`), and #5 (SHACL shapes
loader) — plus two QueryIR algebra additives the 0.16.0 plan
flagged as "deferred": multi-sort + `OFFSET`. None of them need a
new engine surface; all five land gem-side against the existing
`sqlite-sparql ≥ 0.12.0` floor.

v0.17.0's posture is **complete the consumer-driven backlog**,
not introduce a new architecture. The SPARQL facade and QueryIR
surfaces stay shape-compatible — new behaviour rides opt-in kwargs
(`with_types:`), new methods (`Sparql.explain`, `Shacl.load_shapes`),
and additive IR nodes (`Sort` allowed multiple times,
`QueryIR::Offset`). MM and VV pins remain valid throughout.

## Why this lives in vv-graph

- All three CR-GM asks already pinned vv-graph as the right home
  in `CONSUMER_REQUIREMENT_GM.md`. CR-GM is the input; this plan
  is the response.
- The QueryIR additives extend a surface vv-graph already owns
  (PLAN_0.16.0 froze the v0.16.0 algebra slice; v0.17.0 names the
  v0.17.0 additions explicitly).
- No new gem boundary is crossed. The SPARQL facade, the QueryIR
  algebra, the router, and the Schema adapter are all
  vv-graph-owned. Nothing here belongs in a consumer gem or in
  the engine.

## Surfaces (additive to v0.16.0)

### `Vv::Graph::Sparql.select(query, graph:, scope:, with_types: false)`

The `with_types: true` kwarg flips the result row shape from a
flat `{ "var" => "raw-string" }` Hash to a typed Hash:

```ruby
Vv::Graph::Sparql.select("SELECT ?p ?o WHERE { <urn:x> ?p ?o }",
                         with_types: true)
# => { ok: true,
#      results: [
#        { "p" => { value: "mm:Product/price",
#                   kind: :iri,
#                   datatype: nil,
#                   lang: nil },
#          "o" => { value: "42",
#                   kind: :literal,
#                   datatype: "http://www.w3.org/2001/XMLSchema#integer",
#                   lang: nil } },
#        ...
#      ] }
```

`with_types: false` (default) keeps the v0.1.0 flat-Hash shape
verbatim. Operators who don't opt in see zero behaviour change.

### `Vv::Graph::Sparql.explain(query, graph: nil, scope: nil)`

```ruby
Vv::Graph::Sparql.explain("SELECT ?s WHERE { ?s a <mm:Product> . ?s <mm:price> ?p . FILTER(?p > 10) }")
# => { ok: true,
#      plan: { kind: :select,
#              projection: ["?s"],
#              where: { kind: :bgp,
#                       patterns: [["?s", "a", "<mm:Product>"],
#                                  ["?s", "<mm:price>", "?p"]] },
#              filters: [{ expression: "?p > 10" }],
#              modifiers: { order_by: nil, limit: nil, offset: nil } },
#      estimated_rows: :unknown,
#      from: :gem_parser }
```

`estimated_rows: :unknown` is a pin: the engine doesn't expose a
cardinality estimator in v0.12.0, and v0.17.0 doesn't ask it to.
The shape leaves room for `estimated_rows: <integer>` once a
future engine ships a planner probe — the gem flips it on by
introspection.

### `Vv::Graph::Shacl.load_shapes(source, format: :ttl, scope: nil)`

```ruby
Vv::Graph::Shacl.load_shapes("config/shapes/product.ttl")
# => { ok: true, loaded: 18, scope: "urn:vv-graph:shapes" }

Vv::Graph::Shacl.load_shapes(<<~TTL, format: :ttl)
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  <urn:shapes:Product> a sh:NodeShape ; sh:targetClass <mm:Product> .
TTL
# => { ok: true, loaded: 2, scope: "urn:vv-graph:shapes" }
```

Accepts a file path or a string body. Default `:ttl`; `:nt`
recognised as the loader passes through the existing
`Sparql.execute("INSERT DATA …")` path with whichever serialisation
the engine accepts. Idempotent — re-loading the same content is a
no-op (the loader hashes the canonicalised input + compares against
a metadata triple on the scope; mismatch triggers a re-load).

Scope IRI default: `urn:vv-graph:shapes` (matches the
`Vv::Graph::Scope` `shapes` role's default vocabulary).

### QueryIR — multi-sort + `Offset`

```ruby
ir = [
  Vv::Graph::QueryIR::Find.new(type: :Product),
  Vv::Graph::QueryIR::Sort.new(field: :brand,  dir: :asc),   # v0.17.0
  Vv::Graph::QueryIR::Sort.new(field: :price,  dir: :desc),  # v0.17.0
  Vv::Graph::QueryIR::Offset.new(n: 20),                     # v0.17.0
  Vv::Graph::QueryIR::Limit.new(n: 10),
]
```

`QueryIR::Offset` is a new value object (frozen Struct, parallel
to `Limit`). The v0.16.0 composition rule "one Sort max" relaxes
to "any number of Sort nodes; order in IR is order of ORDER BY
keys." The "one Limit max" rule stays; new rule "one Offset max."

## Phases

Five phases. Each is independently mergeable, ends green, and
bumps a sub-version inside the v0.17.0 window. SPARQL facade
public surface stays shape-compatible throughout (the
`with_types:` opt-in is additive).

### Phase A — `Sparql.select(..., with_types: true)`

- `lib/vv/graph/sparql.rb` — add the `with_types:` kwarg; when
  false (default), short-circuit to the v0.1.0 path.
- New private helper `Vv::Graph::Sparql::TermParser` parses the
  engine's N-triples-ish return values into `{ value:, kind:,
  datatype:, lang: }` Hashes. Same logic the v0.16.0
  `Backend::Sparql.unwrap_literal` uses, refactored as a
  shared parser; the unwrap helper continues to call into it
  but discards the typing metadata when its consumer doesn't
  need it.
- Pinned `:kind` values: `:iri`, `:literal`, `:blank_node`,
  `:quoted_triple` (the v0.8.0 RDF-star surface). Unknown
  forms (an engine quirk the parser doesn't recognise) return
  `:unknown` rather than raising.

**Tests.** Unit tests for the parser covering all four `:kind`
values + the v0.16.0 typed-literal datatypes
(`xsd:string/integer/double/decimal/boolean/dateTime/date`).
End-to-end spec issuing a SELECT against a live store with
`with_types: true` and asserting the per-binding shape.

**Exit.** GM's "regex-sniffs the value string" workaround can be
deleted (CR-GM ask #1 satisfied).

### Phase B — `Sparql.explain(query, graph:, scope:)`

- `lib/vv/graph/sparql/explain.rb` — a gem-side SPARQL parser
  for the slice operators send through this gem (SELECT, ASK,
  CONSTRUCT, UPDATE). The parser is intentionally narrow: it
  recognises the same syntactic forms the SPARQL facade has
  always accepted, returning the structural plan above. It does
  NOT execute the query.
- `lib/vv/graph/sparql.rb` — adds the public `explain` method.
  Returns `{ ok: true, plan: <Hash>, estimated_rows: :unknown,
  from: :gem_parser }` on success, the same refusal envelope
  shape as `select`/`ask`/`construct` (`:sparql_parse_error`,
  `:invalid_dsl`, etc.) on failure.
- `estimated_rows: :unknown` is pinned. When a future engine
  release ships a `rdf_sparql_plan(query) → JSON` surface,
  `explain` flips `from: :engine_planner` + populates
  `estimated_rows:`. The gem-side parser stays as the fall-back
  (engine planning is an optimisation, not a contract).
- The `plan:` Hash shape is **pinned** at v0.17.0:
  - `kind:` — `:select | :ask | :construct | :update`
  - `projection:` — Array of `?var` strings or `["*"]`
  - `where:` — recursive `{ kind:, ... }` structure covering
    `:bgp`, `:union`, `:optional`, `:graph` (named-graph),
    `:filter`, `:bind`
  - `modifiers:` — `{ order_by:, limit:, offset:, group_by:,
    having: }`
  - For `:construct`: `template:` — Array of triple patterns
  - For `:update`: `operation:` — `:insert_data | :delete_data |
    :insert_where | :delete_where | :clear | :load | ...`

**Tests.** Per-operator parse tests; one round-trip spec
demonstrating `explain` + `select` agree on the structure for
a representative query.

**Exit.** GM's hybrid lowerer has a cost-aware signal (CR-GM
ask #2 satisfied).

### Phase C — `Shacl.load_shapes(source, format:, scope:)`

- `lib/vv/graph/shacl/loader.rb` — file-or-string reader +
  format dispatcher. `format: :ttl` (default) routes through
  the engine's `rdf_load_turtle` (engine ≥ 0.14.0 ships
  `SqliteSparql::Store#load_turtle` natively; the gem calls the
  underlying SQL function directly). `format: :nt` routes
  through `Vv::Graph::Sparql.execute("INSERT DATA { … }")` after
  reading the file into a single INSERT block.
- `lib/vv/graph/shacl.rb` — exposes the public
  `Shacl.load_shapes(source, format: :ttl, scope: nil)` entry
  point. `scope: nil` defaults to `urn:vv-graph:shapes` (the
  canonical `Scope` shapes-role IRI). Operators pass
  `scope: "urn:custom:shapes:product"` for per-shape-family
  scoping.
- Idempotency: the loader writes one metadata triple per load —
  `<scope> :loaded-from "<source>" ; :content-hash "<sha256>" .`
  in a sibling `urn:vv-graph:shapes:meta` graph. Re-loading
  checks the hash; on match, returns `{ ok: true, loaded: 0,
  reason: :unchanged }` without touching the shapes scope.
- New refusal symbols:
  - `:shapes_file_missing` — `format: :ttl` source path doesn't
    exist on disk.
  - `:shapes_format_unknown` — `format:` value isn't
    `:ttl | :nt`.
  - `:shapes_parse_error` — engine refuses the input.

**Tests.** Round-trip a small `product_shapes.ttl` file;
re-load returns `loaded: 0`; explicit format mismatch refuses;
content-hash drift triggers re-load.

**Exit.** GM's per-spec `parse-and-insert` boilerplate can be
deleted (CR-GM ask #5 satisfied).

### Phase D — QueryIR additives: multi-sort + `Offset`

- `lib/vv/graph/query_ir/nodes.rb` — adds the
  `Offset = Struct.new(:n, keyword_init: true)` value object.
- `lib/vv/graph/query_ir.rb` — composition validator:
  - Drops the "at most one Sort node" rule (still permits zero).
  - Adds "at most one Offset node" rule.
  - Keeps "at most one Limit node."
  - When Offset is present without Limit, the validator
    refuses with `:ir_invalid` (operator-friendly: SPARQL spec
    permits LIMIT-less OFFSET but most engines treat the
    combination as a no-op or undefined-row-order).
- `lib/vv/graph/backend/sparql.rb` — compiler emits
  `ORDER BY <key1> <key2> ...` for multi-sort, `OFFSET N` for
  the offset node.
- `lib/vv/graph/backend/relational.rb` — chains
  `.order(...).order(...)` (AR appends; semantics align with
  SPARQL's "first key is primary"), and `.offset(n)`.

**Tests.** Compiler unit tests for both backends; parity spec
under `spec/parity/` runs a multi-sort + offset IR through
both backends and asserts row-identity.

**Exit.** v0.16.0's "additive in v0.17.0" note retired.

### Phase E — Specs + bin/check + docs

- `spec/vv/graph/sparql_with_types_spec.rb` — Phase A coverage.
- `spec/vv/graph/sparql_explain_spec.rb` — Phase B coverage.
- `spec/vv/graph/shacl_load_shapes_spec.rb` — Phase C coverage.
- `spec/vv/graph/query_ir_multi_sort_spec.rb` — Phase D
  algebra-extension coverage.
- `spec/parity/query_ir_multi_sort_offset_parity_spec.rb` —
  Phase D parity.
- `CHANGELOG.md` — `0.17.0` heading with per-phase entries.
- `README.md` — short section per new surface; no architecture
  overhaul.
- `CONSUMER_REQUIREMENT_GM.md` — flip asks #1 + #2 + #5 to
  **LANDED in 0.17.0** with the same "how the landed shape
  differs" note convention v0.16.0 used.
- `docs/plans/PLAN_0.17.0.md` — this file. Update "Status" as
  phases land.
- `VERSION` → `0.17.0`.

## Out of scope for v0.17.0

- **Engine-side SPARQL planner.** `Sparql.explain`'s
  `estimated_rows: :unknown` is the v0.17.0 contract. If a
  future engine release (likely v0.13.x+) ships
  `rdf_sparql_plan(query) → JSON`, the gem can flip
  `estimated_rows:` to a real integer without a contract
  break — `from: :gem_parser` → `:engine_planner` is the
  observable change. File a `CONSUMER_REQUIREMENT_VvGraph.md`
  follow-up ask if GM's hybrid lowerer turns out to need real
  cost numbers in practice.
- **Backend-split execution for mixed-capability IRs.** PLAN_0.16.0
  Open Question #1 — when one IR mixes a SHACL-/OWL-requiring
  filter with an indexed-column equality filter, do we split the
  IR and route halves to different backends or refuse outright?
  v0.16.0 chose refuse (`:backend_split_unsupported`). v0.17.0
  keeps that posture; revisit if vv-learn or GM hits the case in
  practice. Splitting would need a sub-IR algebra
  (`QueryIR::Compose(left, right, mode: :and|:or|:join)`)
  that's a bigger lift than v0.17.0's "complete the backlog"
  remit.
- **YAML override file for `Schema.field`.** PLAN_0.16.0 Open
  Question #3 — Ruby config block stays the only override
  surface in v0.17.0. The case for YAML is "non-Ruby ops
  edit it"; nobody has filed that signal yet.
- **Write IR.** Writes continue through `Vv::Graph::Sparql.execute`
  and `Vv::Graph::Storable`. Consumers asking for a write IR
  should open a CR ask; v0.17.0 doesn't speculate.
- **Full-text-search.** Capability flag `fts: false` stays on
  both backends. The engine has no FTS surface; v0.17.0
  doesn't ask for one.
- **Sub-queries / nested SELECTs in QueryIR.** Adding
  `QueryIR::Subquery(ir)` is a v0.18.x+ candidate. The current
  algebra is flat by design; nesting needs the composition
  semantics that the backend-split question circles around.
- **OWL closure on the Relational backend.** vv-learn's plan
  owns this. v0.17.0's Router still refuses an OWL-closure-
  requiring IR routed to Relational with
  `:backend_missing_capability` — same behaviour as v0.16.0.
- **SHACL on the Relational backend.** Same — vv-learn's plan.
- **A SQL `Sparql.execute` variant that accepts AR query
  fragments.** Out of scope. Operators with hybrid needs use
  the existing `Sparql.execute` for SPARQL writes + the AR
  surface directly for SQL writes.
- **Cross-graph shapes loader.** `Shacl.load_shapes` loads into
  *one* scope per call. Operators wanting "split the file
  across N graphs by shape name" call the loader N times with
  pre-split source strings.
- **Format auto-detection in `load_shapes`.** Operators pass
  `format:` explicitly. Filename-suffix sniffing is a v0.18.x+
  ergonomic.

## Consumer impact

- **GM** (`CONSUMER_REQUIREMENT_GM.md`): Phase A satisfies #1,
  Phase B satisfies #2, Phase C satisfies #5. All five CR-GM
  asks are now closed across v0.16.0 + v0.17.0. PLAN_0_1_0 Phase
  F (the lowerer cleanup) gets:
  - `with_types: true` → typed result formatting; the regex
    sniffer's gone.
  - `Sparql.explain` → cost-aware backend-pick in the hybrid
    lowerer.
  - `Shacl.load_shapes` → component_shapes.ttl loads in one
    line; the spec-support boilerplate's gone.
- **MM** (`CONSUMER_REQUIREMENT_MM.md`): no break. Existing
  surfaces unchanged. MM *may* adopt `with_types:` on its raw
  `Sparql.select` call sites if it wants typed result
  formatting; not required.
- **VV** (`CONSUMER_REQUIREMENT_VV.md`): no break. VV doesn't
  consume any of the new surfaces directly. The
  storage-substitutability contract VV pinned remains intact —
  all new surfaces stay within the existing four roles
  (`Sparql.*`, `Shacl.*`, `QueryIR.*`, `Loader.*`).

## Open questions

1. **Should `Sparql.explain` accept a SPARQL UPDATE?** Today's
   draft says yes — the plan structure for an UPDATE is the
   `operation:` Hash above. The question: does GM need it?
   PLAN_0_1_0 Phase F lowers writes through `Sparql.execute`
   directly without explaining them. Lean: ship the surface for
   UPDATE since the parser already covers it; document it as
   "you probably won't need this."

2. **Should the SHACL loader's content-hash live in a sibling
   `:meta` graph or as an RDF-star annotation on the scope IRI?**
   v0.17.0 picks sibling graph (simpler; doesn't require RDF-star
   writes from `Vv::Graph::Sparql.quoted_triple` which lands
   later). Revisit when v0.13.0's RDF-star write surface is
   first-class on the gem side.

3. **`Sparql.explain`'s `:gem_parser` accuracy.** The gem-side
   parser is the v0.17.0 shape; it won't catch every engine-side
   eval quirk (e.g., the engine refusing `a` shorthand in
   INSERT DATA — see the PLAN_0.16.0 Phase D investigation).
   Should `explain` issue a probe `select` to validate the
   query is engine-acceptable, or stay parse-only? Lean:
   parse-only — `explain` is a planning aid, not a syntax
   linter; operators worried about engine compatibility run
   the query.

4. **Multi-sort secondary-key direction.** SPARQL allows
   `ORDER BY ?a DESC(?b) ?c`. The v0.17.0 multi-sort IR carries
   per-Sort `dir:`; the compiler emits the dir wrapper per key.
   No semantic change vs v0.16.0 single-sort; calling it out as
   a pinned shape so future ASC-as-default-without-wrapper
   optimisations don't break consumers.

## Related documents

- `./PLAN_0.16.0.md` — QueryIR + backends + router. v0.17.0
  extends the algebra (multi-sort, Offset) and the SPARQL
  facade (with_types:, explain) without changing the v0.16.0
  contracts.
- `./PLAN_0.10.0.md` — SHACL Core. The shapes loader feeds
  validation; no change to the validator itself in v0.17.0.
- `../../CONSUMER_REQUIREMENT_GM.md` — vv-grammar's asks; Phase
  A/B/C satisfy #1/#2/#5 (the remaining open asks after v0.16.0).
- `../../CONSUMER_REQUIREMENT_MM.md` — no change.
- `../../CONSUMER_REQUIREMENT_VV.md` — no change.
- `vendor/sqlite-sparql/CONSUMER_REQUIREMENT_VvGraph.md` — no
  new engine ask in v0.17.0. The standing follow-ups under #8
  (expand DRed dependency tracking to the remaining 55 rules)
  + the deferred `rdf_construct_many → index write-through`
  remain on the v0.18.x+ horizon, gated on MM-side telemetry.
- `vendor/vv-grammar/docs/plans/PLAN_0_1_0.md` Phase F — the
  downstream cleanup that consumes Phase A + Phase C + the
  v0.16.0 schema normalizer all at once.
