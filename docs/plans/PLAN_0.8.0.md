# PLAN_0.8.0 — `rails-semantica` RDF-star (quoted triples + statement metadata)

> *Picks up where PLAN_0.5.0 (named graphs / quads) left off. Quads
> answered "where does this triple live?"; RDF-star answers "what
> do we know **about** this triple?" — provenance, confidence,
> timestamps, source attribution — without materialising a fresh
> reification graph by hand. The Oxigraph store underneath
> `sqlite-sparql` already parses SPARQL-star natively; v0.8.0
> surfaces the operator-facing seams: a quoted-triple term form on
> the `Storable` DSL, an `annotate` block on emissions for
> per-statement metadata, and a SPARQL-star-aware shape on
> `Sparql.{select,construct,execute}`. OWL reasoning (DL queries,
> SHACL, entailment regimes) is the **next** boundary and is
> explicitly out of scope here — see "Out of scope" below.*

## Current state

**Substantively shipped across v0.13.0–v0.15.0 (Phase D deferred).**

- **Phase A (read-path pass-through specs)** — ✅ shipped.
  `spec/vv/graph/sparql_star_spec.rb` (146 lines) pins
  `INSERT DATA { << … >> … }`, `SELECT … WHERE { << … >> … }`,
  `FILTER(isTriple(?x))`, and `graph:` composition. No gem-side
  production code; the existing facade passes SPARQL-star through
  to Oxigraph verbatim.
- **Phase B (`Sparql.quoted_triple` + `Storable::DSL annotate`)** —
  ✅ shipped in v0.14.0. `lib/vv/graph/sparql.rb:98` exposes the
  marker; `lib/vv/graph/storable.rb:680` adds the `annotate` block.
  TermSerializer recognises the marker and emits `<< … >>`. Save
  emits/replaces; destroy retracts parent + annotations.
  Dispatch-mode equivalence pinned by spec.
- **Phase C (`bulk_insert` / `bulk_delete` quoted-triple rows)** —
  ✅ shipped in v0.14.0. Accepts `QuotedTriple` marker, 3-element
  Array shorthand, or pre-serialised `<< … >>` strings via
  `raw: true`. Predicate position refuses with `:invalid_dsl`.
- **Phase D (degraded shape / `:rdf_star_unsupported` refusal)** —
  **deferred.** Engine 0.7.0 ships all six prereqs, so the
  critical path doesn't need the fallback. Re-open if a future
  Oxigraph or `sqlite-sparql` bump regresses one of the prereqs.
- **Phase E (contract additions)** — ✅ pinned. Every surface in
  the Phase E table below is reachable + spec'd.
- **Phase F (specs + bin/check)** — ✅ shipped. 336 examples
  pass, including the three star-specific files.
- **Phase G (docs)** — ✅ shipped in `CHANGELOG.md` 0.14.0 +
  0.15.0 entries; `README.md` "RDF-star (statement metadata)"
  section; `CONSUMER_REQUIREMENT_MM.md` §7 surface block;
  `Vv::Graph.rdf_star_writes_enabled?` returns `true` against
  the current release (verified via live probe). The rename to
  `vv-graph` / `Vv::Graph::*` at v0.15.0 preserves every Phase B/C
  surface verbatim — only namespace names move.

`sqlite-sparql` 0.7.0 landed the full RDF-star round-trip
(quoted-triple terms across every read and write path, plus three
new extractor scalars); engine pin at `>= 0.7.0` is implicit
through the `vv-graph` gemspec's engine pin (currently 0.8.0).
MM's Conformer plan can consume the surface today.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `docs/research/TripesQuadsEtc.md` | this repo | The motivating sketch: triples → quads → RDF-star → OWL. Frames v0.8.0 as the RDF-star rung; OWL is the next one. |
| `magentic-market-ai/docs/research/StarExts.md` | MM repo | Substrate-side primer on the W3C-CG 2021-12-17 RDF-star / SPARQL-star spec. Pins the exact concrete syntax (`<< s p o >>`, `{\| p o \|}`), the quoted-vs-asserted distinction, the SPARQL-star built-ins (`TRIPLE`, `SUBJECT`, `PREDICATE`, `OBJECT`, `isTRIPLE`), and the occurrence-vs-reference modeling decision. v0.8.0's DSL keyword names + gotcha callouts trace back to this primer. |
| `PLAN_0.5.0.md` | this dir | Named-graph surface (`graph:` kwarg, `graph "…"` DSL). v0.8.0 layers quoted-triple terms onto the same emission paths. |
| `PLAN_0.4.0.md` | this dir | `bulk_insert(raw: true)` is the fast emission path. v0.8.0 extends row shape to allow a quoted triple as subject or object. |
| `PLAN_0.3.0.md` | this dir | `sparql_update` arbitrary-UPDATE fallback. SPARQL-star UPDATE forms (`INSERT DATA { << ... >> ... }`) ride this path with no gem-side parsing. |
| `PLAN_0.7.0.md` | this dir | EtherealGraph composition. RDF-star statements emit into the scoped named graph just like ordinary triples. |
| `sqlite-sparql` engine ≥ 0.7.0 | sibling repo | RDF-star prerequisite — **landed** in `sqlite-sparql 0.7.0` (see its CHANGELOG: quoted-triple terms now round-trip across `rdf_insert*` / `rdf_delete*` / `rdf_triples` vtab / `sparql_query` JSON / `sparql_construct` / `rdf_dump_ntriples`; three new scalars `rdf_triple_subject` / `rdf_triple_predicate` / `rdf_triple_object`; `rdf_term_type` now returns `"triple"`). Both that repo's `CONSUMER_REQUIREMENT_RS.md` and `CONSUMER_REQUIREMENT_MM.md` list the surface as "Available upstream but not exercised" — v0.8.0 is the gem-side promotion. |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Drift target. MM's `docs/research/Semantica.md` listed RDF-star as a "post-v0.7.0 if signal" item; v0.8.0 promotes it. |

## Engine prerequisites (sqlite-sparql ≥ 0.7.0) — **all landed**

All six surfaces v0.8.0 depends on shipped in `sqlite-sparql 0.7.0`.
The spec they target is the W3C-CG RDF-star / SPARQL-star Final
Community Group Report (2021-12-17) — see
`magentic-market-ai/docs/research/StarExts.md` §2 for the concrete
syntax (`<< s p o >>` quoted-triple terms; `{| p o ; p o |}`
annotation shorthand) and §5 for the implementation landscape
(Oxigraph 0.4 ships full RDF-star + SPARQL-star support; the engine
0.7.0 work was unblocking what Oxigraph already does).

1. **SPARQL-star pass-through.** ✅ Landed. `sparql_query`,
   `sparql_ask`, `sparql_construct` accept SPARQL 1.1 queries
   containing `<< s p o >>` quoted-triple patterns and the
   SPARQL-star built-ins (`TRIPLE`, `SUBJECT`, `PREDICATE`,
   `OBJECT`, `isTRIPLE`). Engine 0.7.0 CHANGELOG: *"SPARQL-star
   flows straight through to Oxigraph — annotation shorthand
   `{| |}`, explicit `<<>>` patterns, and the … built-ins all
   work without SQL-side wrapping."*
2. **SPARQL-star UPDATE pass-through.** ✅ Landed via the same
   pass-through. `INSERT DATA { << :s :p :o >> :reportedBy :Watson . }`
   and `DELETE WHERE { << ?s ?p ?o >> :date ?d . }` route verbatim.
3. **Quoted-triple terms in N-Triples-star + `rdf_insert*`.** ✅
   Landed. 3- and 4-arg `rdf_insert` / `rdf_delete` plus
   `rdf_insert_many` / `rdf_delete_many` accept `<< <s> <p> <o> >>`
   in subject and object position. Predicate position stays
   IRI-only (RDF doesn't extend star to predicates).
4. **`rdf_load_ntriples` accepts N-Triples-star.** ✅ Landed
   (Oxigraph parses the grammar; engine 0.7.0 stopped rejecting
   it at the SQL boundary).
5. **`rdf_triples` virtual table — quoted-triple visibility.** ✅
   Landed. Subject and object columns now emit `<< s p o >>` for
   quoted-triple terms; nesting (`<< << s p o >> p o >>`)
   round-trips.
6. **`isTRIPLE(?x)` filter in select payloads.** ✅ Landed. JSON
   bindings emit the SPARQL-Results-for-RDF-star encoding for
   triple-typed bindings. The gem's `Sparql.select` returns the
   payload verbatim.

Plus three additive scalars v0.8.0 doesn't strictly need but
should expose downstream of `Sparql.select` for operators
destructuring triple-typed bindings without re-parsing the
`<< … >>` string:

- `rdf_triple_subject(term)` — extract subject of a quoted triple.
- `rdf_triple_predicate(term)` — extract predicate.
- `rdf_triple_object(term)` — extract object.

Engine 0.7.0 also changed two `rdf_term_*` behaviours v0.8.0
should track in its Loader probes / error-classification:

- `rdf_term_type("<< … >>")` now returns `"triple"` (previously
  `"unknown"`).
- `rdf_term_value("<< … >>")` now raises with the fixed prefix
  `rdf_term_value: triple terms have no scalar value; …`
  (previously `unrecognised term format: …`).
  `Sparql::classify_statement_error` in `lib/semantica/sparql.rb`
  prefix-matches `"unrecognised term format"` — audit for the
  drift; engine 0.7.0 CHANGELOG flags this as a behaviour change.

If a future engine regression breaks any of (1)–(6), Phase D
below remains the documented fallback shape.

## Gem-side scope

### Phase A — `Sparql.{select,ask,construct,execute}` pass-through

No code change on the read path: queries containing `<< s p o >>`
ride through `sparql_query` / `sparql_ask` / `sparql_construct`
unchanged. v0.8.0 Phase A is a **spec-only** rung — pin that the
gem's facade does not mangle SPARQL-star syntax, and that the
JSON shape coming back for a triple-typed binding round-trips.

#### Implementation
- No production code.
- Specs in `spec/semantica/sparql_star_spec.rb`:
  - `INSERT DATA { << <:s> <:p> <:o> >> <:reportedBy> <:Watson> . }`
    via `Sparql.execute` → `{ ok: true, count: 1 }`.
  - `SELECT ?case WHERE { << <:SH> <:investigates> ?case >> <:reportedBy> <:Watson> . }`
    via `Sparql.select` → rows present, `?case` bound.
  - `SELECT ?meta WHERE { ?meta <:reportedBy> ?w . FILTER(isTriple(?meta)) }` →
    `?meta` bound as `{ "type" => "triple", "value" => { ... } }`.

#### Exit criteria
- The four facade methods accept SPARQL-star verbatim.
- `Sparql.select` returns triple-typed bindings as JSON-Results-
  for-RDF-star Hashes; no string mangling.
- `graph:` + SPARQL-star compose (`<< s p o >>` inside a
  `GRAPH <g> { … }` block parses and returns).

### Phase B — `Storable` DSL: quoted-triple terms

The minimum DSL change that lets `Storable`-bound AR models emit
RDF-star without dropping to `Sparql.execute`. Two additions:

1. **`quoted_triple(s, p, o)` term constructor.** Returns an opaque
   marker the `Storable` term serializer recognises. Usable
   anywhere a subject IRI or an object value goes:

   ```ruby
   triples do
     subject -> { "urn:mm:listing:#{id}" }

     triple "mm:listedBy", -> { quoted_triple("urn:mm:agent:#{agent_id}",
                                              "schema:knows",
                                              "urn:mm:vendor:#{vendor_id}") }
   end
   ```

2. **`annotate(predicate, object_lambda)` block.** Ruby-side sugar
   for the Turtle-star **annotation shorthand** (`{| p o ; p o |}`)
   documented in `StarExts.md` §2 — i.e., emit the parent triple
   **and** emit each annotation predicate-object against the
   parent triple as a quoted subject. The DSL keyword name is
   deliberately *not* `star {}` or `meta {}` so the spec
   provenance stays obvious in the call site. Resolves to
   `quoted_triple(<the just-emitted subject>, <the just-emitted predicate>, <the just-emitted object>)`
   as the new subject:

   ```ruby
   triples do
     subject -> { "urn:mm:product:#{sku}" }

     triple "schema:gtin", -> { gtin } do
       annotate "mm:reportedBy",   -> { "urn:mm:user:#{updater_id}" }
       annotate "mm:reportedAt",   -> { updated_at.iso8601 }
       annotate "mm:confidence",   -> { confidence_score }
     end
   end
   ```

   Composes with `if:` gating on the parent triple — if the parent
   triple's `if:` is false, none of the annotations emit either.

#### Implementation
- New term marker class `Semantica::Storable::TermSerializer::QuotedTriple`,
  carries `[s, p, o]` lambdas (or already-resolved strings).
- `TermSerializer.object` / `.iri` recognise the marker + emit
  the `<< … >>` N-Triples-star encoding.
- `Storable::DSL::Recorder` grows an `annotate` keyword. The
  enclosing `triple` block resolves its `(subject, predicate, object)`
  at emission time, then iterates its annotations, emitting one
  triple per `annotate` with `quoted_triple(...)` as subject.
- Annotations route through whatever `dispatch_mode` the parent
  emission used (`:sparql_update` / `:bulk` / `:per_call`).
- `after_destroy` retracts annotations as well as the parent
  triple — the retraction phase walks the same DSL tree.
- Read-replace idempotency: re-emitting the same parent triple
  re-emits the annotations; if the parent triple's object
  changes, the annotations' subject (the quoted triple) changes
  with it, and the old annotations stop being reachable. This is
  the SPARQL-star semantics, not a gem bug — operators wanting
  strict cleanup pair with `Sparql.execute("DELETE WHERE { << <s> <p> ?o >> ?ap ?ao }")`.

#### Exit criteria
- Spec: a `Product` with one `triple "schema:gtin", … do; annotate … end`
  block round-trips: after `Product.create!`, a SPARQL-star query
  for `<< <urn:mm:product:…> <schema:gtin> ?gtin >> <mm:reportedBy> ?u .`
  returns the bound `?u`.
- Spec: parent `if:` false ⇒ neither parent triple nor
  annotations emit.
- Spec: `update!` that changes the parent object emits a fresh
  parent triple + fresh annotations on the new quoted-triple
  subject; the old quoted-triple subject becomes orphaned (no
  `?p ?o` matches reach it).
- Spec: `destroy` retracts the parent triple **and** every
  annotation predicate on its quoted-triple subject.
- Spec: dispatch-mode equivalence (`:sparql_update` / `:bulk` /
  `:per_call`) — same SPARQL-visible outcome across modes.

### Phase C — `bulk_insert` row shape: quoted-triple terms

Surface the same capability on the bulk path so MM (and other
operators) can stream RDF-star without going through `Storable`.

#### Implementation
- `Sparql.bulk_insert` accepts a quoted-triple sentinel in `:s`
  or `:o`. Two equivalent shapes:

  ```ruby
  Semantica::Sparql.bulk_insert([
    # Hash form with a nested 3-element Array as the quoted triple:
    { s: ["urn:mm:p:1", "schema:gtin", "1234567890"],
      p: "mm:reportedBy",
      o: "urn:mm:user:42" },

    # Or with the explicit marker:
    { s: Semantica::Sparql.quoted_triple("urn:mm:p:1", "schema:gtin", "1234567890"),
      p: "mm:reportedAt",
      o: "2026-05-23T00:00:00Z" },
  ])
  # => { ok: true, inserted: 2 }
  ```

- `Sparql.quoted_triple(s, p, o)` module method returns the same
  marker the Storable DSL uses; pinned at the public surface so
  operators don't need to reach into `Storable::TermSerializer`.
- `bulk_delete` accepts the same shape symmetrically.
- `raw: true` rows still bypass normalization — operators using
  the raw path pass already-serialised `<< … >>` strings.

#### Exit criteria
- Spec: a Hash-form row with a nested Array subject round-trips.
- Spec: a `Sparql.quoted_triple` marker in `:o` round-trips.
- Spec: invalid quoted-triple shape (e.g. 2-element array)
  refuses with `:invalid_dsl` + verbatim because-clause.
- Spec: empty quoted-triple terms in `raw: true` rows pass
  through verbatim — `bulk_insert` does not parse them.

### Phase D — Degraded shape (fallback; not on critical path)

Engine 0.7.0 ships all six prereqs, so v0.8.0's default release
shape is **full RDF-star** — Phases A/B/C all land. Phase D
documents the fallback in case a future engine regression breaks
one of the surfaces v0.8.0 depends on (e.g., an Oxigraph bump
that loses the JSON-Results-star encoding):

- Ship Phase A unchanged (read-side pass-through specs).
- Gate Phases B + C behind a `Semantica.rdf_star_writes_enabled?`
  predicate consulting the engine version probe
  (`Loader.engine_version`, PLAN_0.6.0). Default `true` against
  engine ≥ 0.7.0; `false` otherwise.
- DSL + facade methods still load — they refuse with
  `{ ok: false, reason: :rdf_star_unsupported, because: "engine X reports RDF-star writes unsupported (need ≥ 0.7.0)" }`
  when called against a degraded engine.

This preserves the v0.8.0 contract additions (Phase E) under any
engine state — operators get a clear refusal envelope rather than
a silent engine error if the prereqs ever drift.

### Phase E — Contract additions

Frozen at v0.8.0 release:

| Surface | Shape | Mutability |
|---|---|---|
| `Sparql.quoted_triple(s, p, o)` | module method → opaque marker | **Pinned.** |
| `Storable::DSL` `annotate(predicate, object_lambda)` inside a `triple` block | DSL keyword | **Pinned.** |
| `Storable::TermSerializer::QuotedTriple` marker class | internal, do not introspect | **Internal.** |
| `bulk_insert` / `bulk_delete` rows accept a 3-element Array or a `QuotedTriple` marker in `:s` / `:o` | shape extension | **Pinned.** |
| `Sparql.select` JSON-Results triple-typed binding shape (`{ "type" => "triple", "value" => { ... } }`) | passes engine output verbatim | **Pinned upstream of engine.** |
| `:rdf_star_unsupported` reason symbol | refusal envelope (Phase D fallback) | **Pinned.** |
| `Semantica.rdf_star_writes_enabled?` predicate | gate against engine version probe | **Pinned.** Returns `true` against engine ≥ 0.7.0. |

### Phase F — Specs + bin/check

- New file `spec/semantica/sparql_star_spec.rb` covering Phase A.
- New file `spec/semantica/storable_annotate_spec.rb` covering
  Phase B (one example per dispatch mode).
- Extend `spec/semantica/sparql_bulk_spec.rb` with quoted-triple
  rows (Phase C).
- `bin/check` green against engine ≥ 0.7.0 (default shape). The
  degraded-shape specs ride a stubbed `Loader.engine_version`
  returning `"0.6.0"` to exercise the refusal-envelope path.

### Phase G — Docs

- `CHANGELOG.md` — `0.8.0` heading with per-phase entries.
- `README.md` — new "RDF-star (statement metadata)" section after
  the named-graph section, with the `annotate` block example +
  the gotchas list cribbed from `StarExts.md` §7 (which gem
  consumers actually hit):
  - **Quoted ≠ asserted.** A bare `quoted_triple(...)` term in
    subject position does not assert the inner triple. The
    `annotate` block always does both (it's annotation-shorthand
    semantics, not bare-quoted-triple semantics). Operators
    reaching for `Sparql.quoted_triple` directly need to emit
    the inner assertion separately.
  - **Quoted-triple subject identity.** Every occurrence of
    `<< s p o >>` denotes the *same* abstract triple term
    (referential opacity per `StarExts.md` §3). Re-emitting a
    parent triple with a changed object orphans prior
    annotations — the old quoted-triple subject becomes
    unreachable.
  - **No quoting of quads.** Quoted triples carry no graph
    label. Annotations emit into the parent triple's graph;
    cross-graph provenance needs an explicit `:assertedIn`
    predicate (per `StarExts.md` §7.6).
  - **Spec status.** The CG report is not yet a W3C
    Recommendation; RDF 1.2 will likely tighten wording. v0.8.0
    pins the 2021-12-17 spec date in code comments touching
    subtle semantics.
- `CONSUMER_REQUIREMENT_MM.md` — promote the post-v0.7.0
  RDF-star note to a §6 surface block; document MM's expected
  consumption shape (provenance triples on `Product` projections).
- `docs/plans/PLAN_0.8.0.md` — this file. Update "Current state"
  as phases land.
- `VERSION` → `0.8.0`.

## Out of scope for v0.8.0

- **OWL reasoning / DL queries / entailment regimes.** OWL is the
  *next* rung (PLAN_0.9.0 candidate). Oxigraph does not ship a
  DL reasoner; integrating one (HermiT/Pellet/FaCT++ via JNI,
  or a pure-Ruby reasoner) is a substantial dependency decision
  the gem should not make unilaterally. v0.8.0 stays on the
  data-shape rung; reasoning waits for an explicit MM ask.
- **SHACL / SHACL-SPARQL constraint validation.** Adjacent to
  OWL; same deferral.
- **RDF-star → RDF-1.1 reification rewriting.** Some operators
  may want to ship RDF-star data into a 1.1-only consumer.
  Out of scope here — operators do the rewrite at their
  consumer boundary, not in this gem.
- **Quoted-predicate terms.** SPARQL-star reserves the predicate
  slot for IRIs; v0.8.0 honors that and refuses `quoted_triple`
  in predicate position with `:invalid_dsl`.
- **Nested quoted triples (`<< << s p o >> p2 o2 >>`).** Parses
  fine through to Oxigraph; v0.8.0 specs cover a single nesting
  level only. Deeper nesting works incidentally but is not
  guaranteed by the contract.
- **Occurrence nodes for distinct extractions.** `StarExts.md`
  §3 flags the occurrence-of-vs-reference-to modeling problem:
  if a consumer needs to track *distinct occurrences* of the
  same proposition (e.g., extracted from two different episodes
  with different confidences), the right shape is a freshly
  minted occurrence node pointing at the quoted triple, not
  multiple annotations on the same quoted-triple subject. v0.8.0
  does **not** add DSL sugar for occurrence nodes — operators
  who need them emit them manually via `quoted_triple` + a
  per-occurrence primary subject. Documenting the pattern in
  the README is enough at this rung.
- **Annotated property paths (`?s :p/:q ?o {| ... |}`).** Invalid
  per the SPARQL-star grammar (`StarExts.md` §7.4). The gem
  passes such queries through to the engine; the engine returns
  a parse error.
- **`Sparql.construct` triple-typed-binding shape.** When a
  CONSTRUCT template emits a quoted-triple subject, the
  N-Triples-star result lands in `:ntriples` verbatim. The gem
  does not transform it into JSON-Results-shape — that's a
  `select`-side affordance.
- **Schema migrations.** No new AR-level migrations; RDF-star
  rides on the same `rdf_triples` virtual table the engine
  already exposes.

## Risks

| Risk | Mitigation |
|---|---|
| Engine 0.7.0 surface drifts under a future Oxigraph bump. | Phase D's degraded read-only shape + `:rdf_star_unsupported` refusal envelope; gem-side specs pin the JSON-Results-star shape and the `<< … >>` round-trip so drift is caught at `bin/check`. |
| Engine 0.7.0 changed `rdf_term_value` error prefix from `"unrecognised term format: …"` to `"rdf_term_value: triple terms have no scalar value; …"`. | `Sparql::classify_statement_error` prefix-matches the old string in a few branches; audit + update lockstep with the engine-version bump. Spec the new prefix. |
| Annotation re-emission semantics are subtle (object change orphans annotations). | Document loudly in the README "what's the quoted-triple subject" callout + pin with a spec asserting the orphan-on-object-change behavior. |
| Operators expect OWL inference on the annotations and don't get it. | The research doc (`TripesQuadsEtc.md`) already calls this out — "OWL doesn't reason over RDF-star metadata." The README copies the warning. |
| Quoted-triple JSON shape from Oxigraph drifts under an Oxigraph bump. | Engine's `CONSUMER_REQUIREMENT_MM.md` pins the SPARQL-Results-star JSON shape as part of the engine's contract. Gem-side spec asserts the shape; engine bump that drifts it is caught at this gem's `bin/check`. |
| `annotate` block adds runtime overhead even for models that don't use it. | The DSL keyword only registers a recorder when present in a `triples do` block. Models without `annotate` see zero overhead. |
| `bulk_insert` row shape extension breaks operators currently passing 3-element Arrays as a flat triple row in `:s` position. | The 3-element Array was never a valid `:s` value at any prior version (the existing Hash form expects scalars in `:s`); the extension is additive. Spec pins the legacy scalar form still works. |
| Storable composition + EtherealGraph: annotations emit into the scoped named graph. | Falls out of the `graph:` thread-through — annotations route through the same dispatch path as their parent triple, which already honors `graph:`. Spec asserts a `Storable + EtherealGraph + annotate` triple round-trips through hydrate / checkpoint / re-hydrate. |

## Acceptance signal

1. Engine pinned at ≥ 0.7.0 (prereqs (1)–(6) all landed in that
   release). `bin/check` green against the pin; Phase D's
   degraded shape exercised via a stubbed `engine_version`.
2. Phases A/B/C land with passing specs.
3. `bin/check` green against the pinned engine.
4. CHANGELOG `0.8.0` heading drops `(unreleased)`.
5. `VERSION` → `0.8.0`.
6. README documents the `annotate` block + the quoted-triple
   subject gotcha.
7. CONSUMER_REQUIREMENT_MM.md §6 notes the new optional surface.

## Cross-references

- `./PLAN_0.3.0.md` — `sparql_update` arbitrary-UPDATE path that
  SPARQL-star UPDATE forms ride through with no gem parsing.
- `./PLAN_0.4.0.md` — `bulk_insert(raw: true)` row shape v0.8.0
  extends with quoted-triple terms.
- `./PLAN_0.5.0.md` — named-graph kwarg / DSL; v0.8.0 composes
  with this (annotations emit into the scoped graph).
- `./PLAN_0.6.0.md` — shared-store posture; `engine_version`
  probe (returning `"0.7.0"` against the pinned engine) drives
  the Phase D feature gate.
- `sqlite-sparql/CHANGELOG.md` § `0.7.0` — *the* engine release
  v0.8.0 pins. MM's Conformer plan can pin `sqlite-sparql` at
  0.7.0 today; this gem follows at v0.8.0 release.
- `./PLAN_0.7.0.md` — EtherealGraph; composition spec covers
  hydrate-checkpoint of graphs containing RDF-star statements.
- `../research/TripesQuadsEtc.md` — the motivating sketch
  (triples → quads → RDF-star → OWL) v0.8.0 implements the
  third rung of.
- `magentic-market-ai/docs/research/StarExts.md` — substrate-side
  primer on the W3C-CG 2021-12-17 RDF-star / SPARQL-star spec.
  Source for v0.8.0's syntax pins, the quoted-vs-asserted
  semantics, the gotchas the README mirrors, and the
  occurrence-vs-reference modeling decision that lands on
  consumers, not the gem.
- SPARQL 1.1 + SPARQL-star community group spec
  (<https://w3c-cg.github.io/rdf-star/cg-spec/2021-12-17.html>)
  — the wire syntax v0.8.0 surfaces. Pin the spec date in any
  code comment that depends on subtle semantics; RDF 1.2 may
  tighten wording but not the core syntax.
