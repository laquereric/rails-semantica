# Changelog

## Unreleased

- **PLAN_0.16.0 Phase A — `Vv::Graph::QueryIR` algebra + SPARQL
  backend.** A small frozen query algebra (`Find`, `Filter`,
  `FilterRange`, `FilterIn`, `Sort`, `Limit`, `Project`, `Count`,
  `Compare`) lowered by `Vv::Graph::Backend::Sparql` to the
  existing SPARQL facade. New entry point
  `Vv::Graph::QueryIR.run(ir, scope:, backend: nil, with_meta: false)`.
  Pinned refusal symbols: `:ir_invalid`, `:schema_field_unknown`,
  `:backend_missing_capability`, `:unknown_backend`. Minimal
  `Vv::Graph::Schema` adapter (prefix-based field → IRI
  resolution; AR introspection + `:schema` scope reads come in
  Phase B/D). The existing `Vv::Graph::Sparql.{select,ask,construct,execute}`
  facade is untouched; QueryIR is purely additive. Phase A always
  picks the SPARQL backend (router lands in Phase C).
- **Engine floor bumped to `sqlite-sparql ≥ 0.9.1`.** No live gem
  code changes — the Phase-B materialise loops in
  `Vv::Graph::Reasoner` / `Vv::Graph::Shacl` /
  `Vv::Graph::Shacl::Rules` stay on the per-rule `Sparql.execute`
  path. Engine 0.9.1 ships `rdf_owl_rl_materialise` — a native
  Rust OWL 2 RL fixpoint pass (15-rule subset matching
  `Vv::Graph::Reasoner::Rules::OwlRl` exactly). Reasoner can opt
  into it in a future phase; equivalence is pinned by the
  engine's `test_rdf_owl_rl_materialise_equivalence_with_vg` test.
  Plans PLAN_0.9.0 / PLAN_0.10.0 / PLAN_0.11.0 / PLAN_0.12.0 /
  PLAN_0.13.0 / PLAN_0.14.0 all bump their `engine ≥ …` floor
  docstring and the engine-CHANGELOG-section reference to 0.9.1.
- **PLAN_0.9.0 (OWL 2 RL Reasoner) — native opt-in shape
  documented.** Same "per-rule default + engine-native opt-in"
  split PLAN_0.12.0 introduced when engine 0.8.0 shipped
  `rdf_construct_many` for SHACL Rules. The OWL 2 RL Reasoner's
  Phase B per-rule path stays the default; the
  `rdf_owl_rl_materialise` route is opt-in pending telemetry.
  Engine and gem produce byte-identical inferred graphs +
  RDF-star annotations either way (engine defaults match
  `Reasoner::Rules` convention by design).
- **Engine v0.9.0 was the broken docs-only publication; v0.9.1
  is the actual native-OWL-2-RL release.** Anyone who pinned
  engine v0.9.0 directly should bump to v0.9.1 — v0.9.0 ships
  only the `CONSUMER_REQUIREMENT_*.md` doc updates with no
  `rdf_owl_rl_materialise` function exposed. See
  `sqlite-sparql/docs/plans/PLAN_0.9.1.md` for the incident
  write-up.

## 0.15.0 — 2026-05-25

**Rename: `rails-semantica` → `vv-graph`.** Four pinned breaking
changes; no capability surface added or removed. The
implementation is mechanically equivalent to v0.14.0; only the
names move. Operators upgrading from v0.14.0 follow the
migration recipe below.

The rename aligns the gem with the substrate's `Vv::*`
namespace convention (`vv-memory`, `vv-action-cable`,
`vv-browser-manager`, etc. — see `agent-os/rules/ruby.md`).
The prior name shipped v0.1.0 through v0.14.0; the
v0.14.0 release line is the last under `rails-semantica`.

### Breaking changes (pinned)

- **Gem name:** `rails-semantica` → `vv-graph`. Update
  `Gemfile`: `gem "rails-semantica", path: …` →
  `gem "vv-graph", path: …`.
- **Top-level constant:** `Semantica::*` → `Vv::Graph::*`
  across every public surface (`Vv::Graph::Sparql`,
  `Vv::Graph::Storable`, `Vv::Graph::Reasoner`,
  `Vv::Graph::Shacl`, `Vv::Graph::Shacl::Rules`,
  `Vv::Graph::Scope`, `Vv::Graph::ChangeSet`,
  `Vv::Graph::EtherealGraph`, `Vv::Graph::Loader`,
  `Vv::Graph::VERSION`, `Vv::Graph::CHECKPOINT_CONTENT_KINDS`,
  `Vv::Graph.rdf_star_writes_enabled?`,
  `Vv::Graph.facade_version`,
  `Vv::Graph.checkpoint_can_round_trip?`).
- **Require path:** `require "rails-semantica"` →
  `require "vv-graph"`. The internal `lib/semantica/*.rb` tree
  moved to `lib/vv/graph/*.rb`.
- **Active Storage attachment:** `:semantica_graph_blob` →
  `:vv_graph_blob`. `EtherealGraph` consumers with existing
  attachments must rename via a one-off migration:
  ```ruby
  ActiveStorage::Attachment
    .where(record_type: "YourModel", name: "semantica_graph_blob")
    .update_all(name: "vv_graph_blob")
  ```
  Documented in the rename migration recipe in README.
- **IRI namespace:** `urn:semantica:*` → `urn:vv-graph:*` for
  every gem-emitted IRI:
  - `urn:semantica:derivedBy` → `urn:vv-graph:derivedBy`
  - `urn:semantica:derivedAt` → `urn:vv-graph:derivedAt` (reserved)
  - `urn:semantica:derivedFrom` → `urn:vv-graph:derivedFrom` (reserved)
  - `urn:semantica:reasoner:rule:<id>` → `urn:vv-graph:reasoner:rule:<id>`
  - `urn:semantica:validation-report:<uuid>` → `urn:vv-graph:validation-report:<uuid>`
  - `urn:semantica:validation-result:<uuid>` → `urn:vv-graph:validation-result:<uuid>`
  - `urn:semantica:changeset:<ulid>` → `urn:vv-graph:changeset:<ulid>`
  - `urn:semantica:rules:transient-report:<uuid>` → `urn:vv-graph:rules:transient-report:<uuid>`
  - `urn:semantica:rules:transient-shapes:<uuid>` → `urn:vv-graph:rules:transient-shapes:<uuid>`

  Existing graphs in any operator's store carry the old IRIs.
  The rename release does NOT auto-migrate stored data;
  operators choosing to align IRIs run a SPARQL UPDATE
  rewriting their existing triples. The example migration is
  in the README's "Migration from rails-semantica 0.14.0"
  section.
- **Environment variable:** `MM_SQLITE_SPARQL_PATH` →
  `VV_GRAPH_SQLITE_SPARQL_PATH`. Update `bin/check`,
  `config/database.yml`, any CI / dev / production
  environment setup that pins the engine artifact path.

### What did NOT change

- **Engine pin** — sqlite-sparql ≥ 0.8.0, identical to v0.14.0.
- **Surface capability** — every method, kwarg, refusal
  envelope shape, `:reason` symbol, value object, and
  contract addition pinned at v0.7.0–v0.14.0 stays — only
  the namespace prefix changes.
- **Spec count + behaviour** — 336 examples (same as v0.14.0);
  every test continues to pass against the renamed code.
- **Documentation plans** — `docs/plans/PLAN_0.X.0.md` files
  documenting historical releases continue to use the
  `Semantica::*` names that shipped at those versions
  (faithful release history). Forward-facing plans
  (PLAN_0.14.0, PLAN_0.14.1) use the new `Vv::Graph::*`
  names.

### Migration recipe (from v0.14.0)

```ruby
# 1. Gemfile
- gem "rails-semantica", path: "vendor/rails-semantica"
+ gem "vv-graph",        path: "vendor/vv-graph"

# 2. Top-level requires (uncommon — usually auto-loaded by Railtie)
- require "rails-semantica"
+ require "vv-graph"

# 3. Code mentions (project-wide find/replace)
- Semantica::Sparql.select(...)
+ Vv::Graph::Sparql.select(...)
- include Semantica::Storable
+ include Vv::Graph::Storable
- include Semantica::EtherealGraph
+ include Vv::Graph::EtherealGraph
- Semantica.rdf_star_writes_enabled?
+ Vv::Graph.rdf_star_writes_enabled?
# … etc for every Semantica::* reference

# 4. Active Storage data migration (one-off, run once after upgrade)
ActiveStorage::Attachment
  .where(name: "semantica_graph_blob")
  .update_all(name: "vv_graph_blob")

# 5. IRI migration (optional — only if operators want fresh stored URIs)
Vv::Graph::Sparql.execute(<<~SPARQL)
  DELETE { ?s ?old_p ?o }
  INSERT { ?s ?new_p ?o }
  WHERE  {
    ?s ?old_p ?o .
    FILTER(STRSTARTS(STR(?old_p), "urn:semantica:"))
    BIND(IRI(REPLACE(STR(?old_p), "^urn:semantica:", "urn:vv-graph:")) AS ?new_p)
  }
SPARQL
# Repeat for subject + object positions; or skip and accept the
# semantic continuity ("urn:semantica:derivedBy" still means the
# same thing in your stored graphs — operators querying for it
# just use the old IRI).

# 6. Environment variable
- export MM_SQLITE_SPARQL_PATH=/path/to/libsqlite_sparql.dylib
+ export VV_GRAPH_SQLITE_SPARQL_PATH=/path/to/libsqlite_sparql.dylib

# 7. config/database.yml
- ${MM_SQLITE_SPARQL_PATH}
+ ${VV_GRAPH_SQLITE_SPARQL_PATH}
```

The substrate's `vendor/rails-semantica/` directory
itself can be renamed at the operator's discretion (e.g.,
`git mv vendor/rails-semantica vendor/vv-graph` at the
parent repo level). The gem doesn't care about its on-disk
directory name; only the gem name + namespace matter.

## 0.14.0 — 2026-05-24

Lands PLAN_0.8.0 Phases B + C — the operator-facing RDF-star write
surface. v0.13.0's `Semantica.rdf_star_writes_enabled?` predicate
(which introspects `Sparql.respond_to?(:quoted_triple)`) now flips
to `true` automatically; VV's `Vv::Memory.rdf_star_writes_enabled?`
delegate inherits the flip without VV code changes.

- **PLAN_0.8.0 Phase B** — `Semantica::Sparql.quoted_triple(s, p, o)`
  module method returns a frozen `QuotedTriple` marker (Struct)
  with recursive `to_ntriples_star` for nested triples
  (`<< << s p o >> p o >>`). `Storable::TermSerializer.iri` /
  `.object` recognise the marker + emit the `<< s p o >>`
  N-Triples-star encoding; both also detect already-`<<…>>`-wrapped
  strings (preserves serialised round-trips).
- **PLAN_0.8.0 Phase B** — `Storable` DSL grows the `annotate`
  block inside `triple` declarations:

  ```ruby
  triples do
    subject -> { "urn:mm:product:#{sku}" }
    triple "schema:gtin", -> { gtin } do
      annotate "mm:reportedBy", -> { "<urn:mm:user:#{updater_id}>" }
      annotate "mm:confidence", -> { confidence },
               if: -> { confidence.present? }
    end
  end
  ```

  Predicate struct grows an `annotations:` field (frozen
  `Array<Annotation>`); empty when no block provided. New
  `AnnotationRecorder` captures `annotate` calls inside the
  block.

  Emission cycle per save:
    1. Retract orphan annotations on the prior parent value's
       quoted-triple subject via `DELETE { << s p ?o >> ?ap ?ao }
       WHERE …` (safe-idempotent for predicates without
       annotations or empty stores).
    2. Replace the parent triple via existing read-replace.
    3. Emit annotations on the new quoted-triple subject.

  Destroy retracts the parent triple AND every annotation on its
  quoted-triple subject via the same DELETE WHERE pattern. Parent
  `if:` false → both parent and annotations skip. Annotation
  `if:` false → only that annotation skips. Update-time changes
  to the parent object orphan the prior quoted-triple subject —
  SPARQL-star referential opacity semantics (StarExts.md §3).

- **PLAN_0.8.0 Phase C** — `Sparql.bulk_insert` / `bulk_delete`
  accept three RDF-star row shapes in `:s` / `:o` positions:
    1. `Sparql::QuotedTriple` marker (from Phase B).
    2. 3-element nested Array shorthand `[s, p, o]` — coerced
       to `Sparql.quoted_triple(*term)`.
    3. Pre-serialised `<< s p o >>` strings via `raw: true`
       (engine-native form).

  Predicate position stays IRI-only per the W3C SPARQL-star
  grammar — quoted-predicate refuses `:invalid_dsl` with
  `"predicate position must be an IRI"`. Malformed nested Arrays
  in `:s` / `:o` refuse `:invalid_dsl` with
  `"subject/object array form expects 3 elements"`. `graph:`
  kwarg composes (PLAN_0.5.0); `bulk_delete` symmetric.

  `unwrap_iri` now leaves `<<…>>` tokens untouched — engine ≥
  0.7.0's `rdf_insert_many` accepts them in subject/object
  positions verbatim; the outer-bracket strip would corrupt the
  N-Triples-star encoding.

- **Capability flip** — `Semantica.rdf_star_writes_enabled?`
  returns `true`. The predicate is introspection-driven (no
  version constants), so the flip is automatic.

Specs: 314 → 330 (+16 across Phases B + C). PLAN_0.8.0 is now
substantively complete (Phase A spec-only; B + C land the
operator surfaces). Phases D (degraded shape) / E (contract
additions) / F (specs) / G (docs) are housekeeping that piggybacks
on this release.

## 0.13.0 — 2026-05-24

Six PLANs land between 0.7.0 and 0.13.0 — every milestone in the
"triples → quads → RDF-star → OWL → SHACL → cross-graph" arc the
research notes (`docs/research/TripesQuadsEtc.md`,
`magentic-market-ai/docs/research/StarExts.md`) sketched.
PLAN_0.13.0 itself anchors the release on
`CONSUMER_REQUIREMENT_VV.md` — the vv-memory side of the bridge —
closing VV's B1 (load-bearing N-Triples-star hydrate fix) and B3
(`Scope` value object surface).

The engine floor moves to `sqlite-sparql ≥ 0.8.0`. No live gem
behaviour depends on 0.8.0's new `rdf_construct_many` yet
(PLAN_0.12.0's batched-execution path is opt-in and remains
deferred until telemetry surfaces a bottleneck), but the
materialise paths in `Semantica::Reasoner` /
`Semantica::Shacl` / `Semantica::Shacl::Rules` rely on engine
≥ 0.7.0's RDF-star + N-Triples-star round-trip, and the engine
CHANGELOG floor in every plan now reads 0.8.0 lockstep.

- **PLAN_0.8.0 Phase A** — SPARQL-star pass-through pin. Spec-only
  (no production code): `Sparql.{select,ask,construct,execute}`
  already pass quoted-triple syntax verbatim against engine 0.7.0.
  Bindings come back as N-Triples-star strings, not the W3C
  JSON-Results-for-RDF-star shape — operators destructure
  `<< s p o >>` form themselves or call the engine's
  `rdf_triple_subject` / `_predicate` / `_object` scalars.
  Documents the `rdf_load_ntriples` line-strict gotcha (multi-line
  `INSERT DATA` bodies must route through `INSERT WHERE`).
- **PLAN_0.9.0 Phase A** — `Semantica::Reasoner` facade skeleton.
  `materialise!(asserted:, inferred:, rules:, provenance:,
  max_iterations:)` returns the v0.9.0 envelope; refusal symbols
  `:invalid_graph`, `:invalid_dsl`, `:rule_set_unknown`,
  `:reasoner_diverged`. `Rule` + `RuleSet` value objects.
- **PLAN_0.9.0 Phase B** — OWL 2 RL core rule library + fixpoint
  iteration. Ships 15 rules covering T-Box transitive closures
  (`scm-sco`, `scm-spo`, `scm-eqc1`, `scm-eqp1`), A-Box propagation
  (`cax-sco`, `prp-spo1`), domain/range (`prp-dom`, `prp-rng`),
  property characteristics (`prp-trp`, `prp-symp`, `prp-inv1`,
  `prp-inv2`, `prp-fp`), and sameAs closure (`eq-sym`, `eq-trans`).
  The remaining ~55 W3C OWL 2 RL/RDF rules are catalogued in
  `Rules::PHASE_B_PENDING` as mechanical transcriptions deferred
  to Phase B.1/B.2. Each rule rewrites to the SPARQL 1.1 dataset
  shape (`WITH <inferred> INSERT … USING <asserted> USING
  <inferred> WHERE …`) via the iteration loop.
- **PLAN_0.10.0 Phase A** — `Semantica::Shacl` facade skeleton.
  `validate(data_graph:, shapes_graph:, report_graph:, provenance:)`
  returns the v0.10.0 envelope. Refusal symbols
  `:shape_parse_error`, `:unknown_constraint_component`,
  `:cycle_detected`. `Constraint` + `ConstraintLibrary` value
  objects.
- **PLAN_0.10.0 Phase B** — SHACL Core validator engine + 12
  constraint components (`sh:minCount`, `sh:maxCount`,
  `sh:datatype`, `sh:nodeKind`, `sh:class`, `sh:pattern`,
  `sh:minLength`, `sh:maxLength`, `sh:in`, `sh:hasValue`,
  `sh:minInclusive`, `sh:maxInclusive`). Validator walks
  shapes_graph, resolves targets via `sh:targetClass` /
  `sh:targetNode`, evaluates per-property-shape constraints via
  Ruby evaluator callables, writes a W3C-conformant
  `sh:ValidationReport` graph. ~18 remaining components in
  `Constraints::PHASE_B_PENDING`; the validator refuses
  `:unknown_constraint_component` against them rather than
  silently conforming.
- **PLAN_0.11.0 Phase A** — `Semantica::ChangeSet` value object +
  `capture(scope:) { ... }` block API. Records adds and retracts
  from `Sparql.execute INSERT DATA / DELETE DATA` and
  `bulk_insert` / `bulk_delete` write paths via a thread-local
  recorder. Arbitrary SPARQL UPDATE forms (`INSERT WHERE`,
  `MOVE`, `COPY`, etc.) cannot be observed without re-querying —
  operators call `ChangeSet.record_add` / `record_retract`
  manually for those, or upgrade to a future phase. Storable
  lifecycle integration deferred. Nested captures refuse with
  `NestedCaptureError`; cross-scope writes raise `ScopeMismatch`
  (swallowed silently in the Sparql notify path — observational,
  never blocks the primary write).
- **PLAN_0.12.0 Phase A** — `Semantica::Shacl::Rules` facade
  skeleton. `materialise!` envelope shape; refusal symbols
  `:rule_parse_error`, `:unknown_rule_type`,
  `:condition_shape_missing`. `Rule` / `TripleRule` / `SparqlRule`
  value-object hierarchy.
- **PLAN_0.12.0 Phase B** — SHACL Rules materialisation engine.
  Rule discovery via `?shape sh:rule ?rule . ?rule rdf:type ?type`
  against shapes_graph. `sh:TripleRule` (with `sh:this` / IRI /
  literal terms) and `sh:SPARQLRule` (with `?this` textual
  substitution in CONSTRUCT + WHERE blocks) both ride the same
  SPARQL 1.1 dataset shape as PLAN_0.9.0's reasoner
  (`WITH <inferred> INSERT … USING <data_graph> USING <inferred>
  WHERE …`). `sh:order` ordering, `sh:deactivated` skip,
  `sh:condition` gating via recursive `Shacl.validate` against a
  transient shapes graph carrying `sh:targetNode <focus>`.
  `sh:JSRule` refuses with `:unknown_rule_type`. Fixpoint
  iteration with `max_iterations` guard matches the reasoner
  pattern. Per-rule provenance annotations deferred to Phase E.
- **PLAN_0.13.0 Phase A** — predicate-shaped capability
  advertisements (`lib/semantica/capabilities.rb`):
  `Semantica.rdf_star_writes_enabled?` (introspects whether
  `Sparql.quoted_triple` is defined — flips automatically when
  PLAN_0.8.0 Phase B lands), `Semantica.facade_version`
  (capability epoch; currently identical to `VERSION`),
  `Semantica.checkpoint_can_round_trip?(content_kind:)`
  (`:plain_ntriples` / `:ntriples_star`; raises `ArgumentError`
  for unknown kinds). VV's `Vv::Memory.rdf_star_writes_enabled?`
  delegates to the upstream predicate.
- **PLAN_0.13.0 Phase B** — `EtherealGraph.parse_ntriples`
  N-Triples-star round-trip (closes `CONSUMER_REQUIREMENT_VV.md`
  B1). `Sparql.split_ntriple` becomes balanced-bracket-aware on
  `<<` / `>>` pairs via the new `take_quoted_triple_term` helper
  (additive — single-bracket IRI logic unchanged).
  `EtherealGraph#strip_brackets_` leaves `<< s p o >>` tokens
  alone so they reach `rdf_insert_many` via
  `bulk_insert(raw: true)`. VV's `silver_star_passthrough`
  hydrate test un-pends against this release.
  `Semantica.checkpoint_can_round_trip?(:ntriples_star)` flips
  to `true`.
- **PLAN_0.13.0 Phase C** — Scope contract formalisation. The
  five-role `Semantica::Scope` value object (shipped in commit
  `2e44f35`) is pinned at v0.13.0 release. New
  `Semantica::Scope.from_(graph_iri)` factory returns a
  degenerate single-graph Scope; per-facade required-role
  validation still applies on subsequent facade calls.
- **PLAN_0.13.0 Phase D** — `scope:` kwarg on the four facade
  families. `Sparql.{select,ask,construct,execute}`,
  `Reasoner.materialise!`, `Shacl.validate`,
  `Shacl::Rules.materialise!` all accept either the existing
  per-graph kwargs or a `scope:` (`Semantica::Scope`) alternative.
  New `Semantica::Scope::FacadeAdapter` shared resolver. Refusal
  symbols pinned: `:scope_kwarg_conflict`, `:scope_role_missing`,
  `:scope_read_write_overlap`. Per-facade equivalence specs
  assert identical output across both calling conventions.
- **Engine floor** bumped to `sqlite-sparql ≥ 0.8.0`. PLAN_0.12.0
  (SHACL Rules) — batched-execution shape no longer deferred at
  the engine side. Engine v0.8.0 ships `rdf_construct_many`, the
  surface PLAN_0.12.0's "deferred batched rule execution" note
  pencilled in as a future engine ask. The plan's "Engine
  prerequisites" section now documents two implementation
  shapes — the per-rule path (`sparql_update` per rule per
  iteration, default for Phase B) and the batched path
  (`rdf_construct_many` once per iteration, opt-in, worthwhile
  at ~20+ rules per shape). Adoption stays gated on a concrete
  bottleneck signal from MM. Both shapes will produce identical
  asserted graphs + RDF-star annotations once batched lands; the
  equivalence is pinned by a planned cross-shape spec.

Specs: 159 → 314 (+155 across all six plans' Phase A/B work).
`bin/check` green against engine ≥ 0.8.0.

## 0.7.0 — 2026-05-20

Closes PLAN_0.7.0. Adds `Semantica::EtherealGraph`, a
Rails-lifecycle-managed wrapper that scopes a named RDF graph to
an AR record via Active Storage durability — without coupling the
engine to a second persistent store.

- **Phase A** — `Semantica::EtherealGraph` concern.
  `ethereal_graph do; iri ->{...}; checkpoint_on :explicit|:save;
  end` DSL captured via Recorder → frozen Declaration struct.
  `has_one_attached :semantica_graph_blob` registered automatically
  when Active Storage is available; operators without AS can supply
  their own duck-typed attachment (any object responding to
  `attached?` / `download` / `attach(io:, filename:, content_type:)`
  / `purge`). `#hydrate_ethereal_graph!` parses the blob's
  N-Triples body and batches into `Sparql.bulk_insert(raw: true)`
  at 1000 rows/crossing; idempotent via a process-wide
  `HYDRATED_IRIS` Set guarded by a Mutex. Early-returns
  `:no_blob` / `:already_hydrated` / `:empty_blob` without engine
  calls when appropriate.
- **Phase B** — `#checkpoint_ethereal_graph!`. CONSTRUCTs every
  triple in the scoped graph via `Sparql.construct(graph: iri)`,
  purges the prior attachment, attaches a fresh
  `application/n-triples` blob. Thread-local re-entrancy guard
  breaks the callback loop the auto-flush would otherwise create
  when `attach` itself fires `after_save`. `checkpoint_on: :save`
  registers `after_save` so the blob flushes after every
  successful save.
- **Phase C** — `#retract_ethereal_graph!` registered as
  `before_destroy`. Issues `CLEAR GRAPH <iri>` against the engine
  and evicts the IRI from `HYDRATED_IRIS`. The standard
  `has_one_attached … dependent: :purge_later` semantics handle
  blob deletion. Retracting one record's graph leaves sibling
  named graphs and the default graph untouched.
- **Phase D** — `Semantica::Storable + EtherealGraph` composition.
  No new production code; the composition is what falls out of
  A + B + C. Spec asserts the round-trip (emit → checkpoint →
  evict → re-hydrate → SPARQL sees every Storable-emitted
  predicate) and pins the callback ordering — declare `triples do`
  *before* `ethereal_graph do` so emit registers (and fires)
  before checkpoint.
- Active Storage is **not** added as a runtime gemspec dependency
  — operators that include `Semantica::EtherealGraph` add
  `activestorage` to their own Gemfile. The concern detects AS at
  load time via `begin / rescue LoadError` and gracefully skips
  `has_one_attached` wiring if absent.
- New pinned `:reason` symbols: `:no_blob`, `:already_hydrated`,
  `:empty_blob`, `:ethereal_graph_undeclared`. New pinned escape
  hatch `Semantica::EtherealGraph.evict!(iri)` for multi-process
  operators.
- 22 new specs (159 total). Spec suite uses a duck-typed
  `FakeBlobAttachment` rather than booting Active Storage
  standalone — the concern is duck-typed against the attachment,
  real Active Storage integration is the operator's app
  responsibility.

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
