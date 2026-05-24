# PLAN_0.13.0 — `rails-semantica` VV-driven consumer alignment + Scope

> *Substrate-driven. `CONSUMER_REQUIREMENT_VV.md` arrived from
> vv-memory after PLAN_0.7.0 (`EtherealGraph`) shipped and VV
> adopted Silver-tier scoping. The file enumerates the surface VV
> consumes, the layering rule it holds itself to ("VV consumes
> `rails-semantica` directly; VV does NOT consume `sqlite-sparql`
> directly"), and three open items numbered B1 / B2 / B3. v0.13.0
> closes B1 + B3 and lands the predicate-shaped capability
> advertisements VV needs to honor the layering rule without
> falling back to version sniffing. B2 (`annotate` DSL +
> `Sparql.quoted_triple`) stays scoped to PLAN_0.8.0 Phase B.*

## Current state

**Draft (one Phase already partially shipped).** The `Semantica::Scope`
value object that originally sat as v0.13.0 Phase A landed in commit
`2e44f35` (alongside the Phase-A batch for v0.8.0–v0.12.0). This plan
re-anchors v0.13.0 on the VV consumer signal, formalises the Scope
contract, lights up the B1 hydrate fix, and ships the capability
predicates.

The remaining work is purely additive on top of what the prior
phase-A commits already established — no breaking changes to the
v0.7.0 surfaces VV pins.

## Anchors

| Anchor | Where | Role |
|---|---|---|
| `CONSUMER_REQUIREMENT_VV.md` | this repo | **The driver.** VV's perspective on what rails-semantica must keep stable + what surfaces VV wants added. Every Phase below maps to a section of this file. |
| `PLAN_0.7.0.md` | this dir | EtherealGraph — VV's load-bearing surface. v0.13.0 Phase B fixes the N-Triples-star hydrate gap surfaced as VV B1. |
| `PLAN_0.8.0.md` | this dir | RDF-star pass-through. v0.13.0 Phase A introduces `Semantica.rdf_star_writes_enabled?` — the predicate version of PLAN_0.8.0's Phase E feature-gate. |
| `PLAN_0.11.0.md` | this dir | `Semantica::ChangeSet` + `capture(scope:)` — the first facade to accept a Scope. Already pinned; v0.13.0 layers the same kwarg on the Reasoner / Shacl / Rules facades. |
| `CONSUMER_REQUIREMENT_MM.md` | this repo | Sibling consumer requirement file. MM consumes `Storable + Sparql.execute`; VV consumes `EtherealGraph + Sparql.execute`. The two intentionally evolve separately. |
| W3C SPARQL 1.1 §13 (RDF Dataset) | spec | The dataset model the Scope value object names. v0.13.0 doesn't introduce new semantics — it ergonomically wraps what SPARQL already supports. |

## Engine prerequisites (sqlite-sparql ≥ 0.8.0) — **already satisfied**

**No new engine surface.** B1's hydrate fix routes through
`rdf_load_ntriples` (engine 0.7.0, with N-Triples-star support) or
through `bulk_insert(raw: true)` → `rdf_insert_many` (engine 0.4.0,
extended for quoted-triple terms in 0.7.0). Both paths are live.

The capability predicates (Phase A) introspect Ruby-side state
only — no engine probe. The Scope value object (Phase C) is pure
Ruby. The `scope:` kwarg integration (Phase D) builds on the same
named-graph SPARQL routing the rest of the gem already uses.

## Gem-side scope

### Phase A — Predicate-shaped capability advertisements

The single most-requested item in VV's CONSUMER_REQUIREMENT_VV.md's
"Predicate-shaped capability advertisements (encouraged)" section:
let consumers ask "can this gem do X" via a predicate rather than
parse the `VERSION` string.

```ruby
Semantica.rdf_star_writes_enabled?         # => true once 0.8.0 Phase A+B land
Semantica.facade_version                   # => "0.13.0" — capability epoch
Semantica.checkpoint_can_round_trip?(content_kind: :ntriples_star)
                                           # => true once Phase B (B1 fix) lands
Semantica.checkpoint_can_round_trip?(content_kind: :plain_ntriples)
                                           # => true (since 0.7.0)
```

#### Why predicates, not version strings

VV's CONSUMER_REQUIREMENT_VV.md is explicit:

> **VV would rather call a predicate than introspect a version.**
> Predicates are testable, version strings are not.

This is the same posture the gem itself takes against the engine
(`Semantica::Loader.engine_version` is documented as the version
probe but `Sparql.classify_statement_error` actually branches on
behaviour, not version). Pushing that posture outward to consumers
is what Phase A is.

#### Implementation
- New module-level methods on `Semantica`:
  - `rdf_star_writes_enabled?` — `true` once `Sparql.quoted_triple`
    + `Storable::DSL annotate` ship (PLAN_0.8.0 Phase B). Returns
    `false` against rails-semantica 0.13.0; updates lockstep with
    PLAN_0.8.0 Phase B.
  - `facade_version` — returns the version string of the
    capability epoch. `VERSION` is the gem's release version;
    `facade_version` is the highest version whose facade
    additions all ship. v0.13.0 ships `facade_version = "0.13.0"`.
    Consumers compare via Gem::Version.
  - `checkpoint_can_round_trip?(content_kind:)` — takes a symbol
    (`:plain_ntriples` / `:ntriples_star`). Returns true iff a
    blob containing that content kind round-trips through
    EtherealGraph's checkpoint → evict → hydrate cycle.
- All three methods live on the `Semantica` module top-level
  (not `Semantica::Sparql` / `Semantica::EtherealGraph`) — the
  capability question is gem-wide, not per-facade.
- VV's `Vv::Memory.rdf_star_writes_enabled?` (already in VV's
  `lib/vv/memory.rb`) delegates to `Semantica.rdf_star_writes_enabled?`
  when defined; this plan introduces the upstream definition VV
  has been waiting for.

#### Exit criteria
- Spec: `Semantica.rdf_star_writes_enabled?` returns a Boolean.
- Spec: `Semantica.facade_version` returns a String parseable by
  `Gem::Version`.
- Spec: `Semantica.checkpoint_can_round_trip?(content_kind: :plain_ntriples)`
  returns true.
- Spec: `Semantica.checkpoint_can_round_trip?(content_kind: :ntriples_star)`
  returns false against the current `parse_ntriples`; flips to
  true after Phase B lands.
- Spec: `Semantica.checkpoint_can_round_trip?(content_kind: :nope)`
  raises `ArgumentError` (operators see the typo, not a silent
  `false`).

### Phase B — B1 fix: `EtherealGraph.parse_ntriples` N-Triples-star round-trip

VV's CONSUMER_REQUIREMENT_VV.md flags this as **load-bearing**:

> **Net P1 envelope under rails-semantica 0.7.0:** scopes carrying
> Conformer-produced annotations cannot survive an evict +
> re-hydrate cycle.

The bug:
`lib/semantica/ethereal_graph.rb:235`'s `parse_ntriples` per-lines
through `Sparql.split_ntriple`, a whitespace-tokenizing parser
that sees `<<` as two separate `<` tokens. Every line containing a
quoted-triple term is silently dropped.

#### Fix path

VV's `B1` section names two acceptable routes. Phase B takes the
**second** (the engine-delegated route was the first), because it
preserves the existing per-line batching + lets `bulk_insert(raw: true)`
handle the engine FFI in one chunk per `HYDRATION_BATCH_SIZE`:

> 2. Teach the existing per-line parser to recognize `<<...>>`
>    grouping and emit the line verbatim to
>    `bulk_insert(raw: true)`, which then dispatches
>    `rdf_insert_many` — `sqlite-sparql` 0.7.0 accepts
>    quoted-triple terms in the `_many` form.

#### Implementation
- Extend `Sparql.split_ntriple` (used by `EtherealGraph.parse_ntriples`)
  to recognize `<< s p o >>` as a single token when encountered in
  subject or object position. The tokenizer becomes balanced-bracket-
  aware on `<<` / `>>` pairs only — IRIs (`<`/`>`) keep their
  per-character semantics.
- Single-line N-Triples-star statements (one quoted-triple subject
  or object per line) round-trip; nesting (`<< << s p o >> p o >>`)
  works since the bracket counter is positional, not pattern-matching.
- `EtherealGraph.parse_ntriples` itself doesn't change shape — the
  per-line dispatch to `bulk_insert(raw: true)` already handles
  the rows. The fix is purely in `split_ntriple`.
- VV's `silver_star_passthrough_spec.rb`'s pending example
  un-pends automatically once Phase B lands (per
  CONSUMER_REQUIREMENT_VV.md's B1 acceptance signal).

#### Exit criteria
- Spec: `Sparql.split_ntriple("<< <:s> <:p> <:o> >> <:reportedBy> <:Watson> .")`
  returns the 3-tuple `["<< <:s> <:p> <:o> >>", "<:reportedBy>", "<:Watson>"]`.
- Spec: `EtherealGraph#hydrate_ethereal_graph!` round-trips a blob
  containing quoted-triple subjects through checkpoint → evict →
  hydrate without dropping any triples.
- Spec: `Semantica.checkpoint_can_round_trip?(content_kind: :ntriples_star)`
  flips to `true` after the fix.
- Spec: pre-existing `EtherealGraph` round-trip specs (Phase A/B
  from PLAN_0.7.0) continue to pass — the tokenizer change is
  additive.

### Phase C — `Semantica::Scope` contract formalisation (B3)

VV's CONSUMER_REQUIREMENT_VV.md flags Scope as **forward-compat**:

> The eventual v0.3.0+ `Vv::Memory.recall(scope:, query:)` facade
> in VV will want to ride this rather than re-invent cross-graph
> semantics. No action required while PLAN_0.13.0 is plan-only /
> Phase A facade-only.

The Scope value object already shipped in commit `2e44f35`. Phase
C formalises the contract VV's `recall` facade will pin against:

- Five roles (`data` / `schema` / `shapes` / `inferred` / `report`)
  pinned at v0.13.0 release.
- The `additional:` Hash escape hatch pinned as the operator
  extension surface — future first-class roles graduate by
  promoting an `additional:` key.
- `read_graphs` / `write_graphs` / `read_write_overlap?` /
  `==` / `hash` pinned as the introspection API.
- `Semantica::Scope.registry` pinned as the process-wide Set;
  test-isolation guidance (`registry.clear` in `before(:each)`)
  documented in README.
- **Refusal envelope shapes** (`:scope_role_missing`,
  `:scope_kwarg_conflict`, `:scope_read_write_overlap`) pinned;
  not yet surfaced by any facade — Phase D adds them on the
  Reasoner / Shacl / Shacl::Rules entry points.

#### Implementation
- The Scope value object code from commit `2e44f35` stays as-is.
- A new module-level `Semantica::Scope.from_(graph_iri)` factory:
  given a single IRI, returns a degenerate Scope with that IRI
  as `data:` and everything else `nil`. Convenience for consumers
  porting per-kwarg call sites incrementally.
- README adds a "Cross-graph scopes" section pinning the
  contract (anchored at this Phase).

#### Exit criteria
- Spec: contract pin — the Scope value object's public surface
  matches the shape pinned in this Phase (read via reflection).
- Spec: `Scope.from_("urn:foo")` returns a Scope with `data: "urn:foo"`
  and every other role `nil`.
- Spec: degenerate Scope's `read_graphs` returns `{ "urn:foo" }`
  and `write_graphs` returns `Set.new`.

### Phase D — `scope:` kwarg on Reasoner / Shacl / Shacl::Rules

The four facade families (`Sparql`, `Reasoner`, `Shacl`,
`Shacl::Rules`) currently accept per-graph kwargs. Phase D adds
`scope:` as a parallel option. The semantics: if `scope:` is
passed, derive the per-graph kwargs from the Scope's roles. If
the caller passes both `scope:` and an overlapping kwarg, refuse
with `:scope_kwarg_conflict` (the symbol pinned in Phase C).

```ruby
# Per-kwarg shape — current; stays supported indefinitely
Semantica::Reasoner.materialise!(
  asserted: "urn:mm:graph:catalogue",
  inferred: "urn:mm:graph:catalogue:inferred",
  rules:    :owl_2_rl,
)

# Scope shape — equivalent, more ergonomic for the multi-call case
scope = Semantica::Scope.new(
  data:     "urn:mm:graph:catalogue",
  inferred: "urn:mm:graph:catalogue:inferred",
)
Semantica::Reasoner.materialise!(scope: scope, rules: :owl_2_rl)

# Conflict — refuses with :scope_kwarg_conflict
Semantica::Reasoner.materialise!(
  scope:    scope,
  asserted: "urn:somewhere-else",   # overlaps scope.data
  inferred: "urn:other",
)
```

#### Role mapping per facade

| Facade method                       | Scope role(s) required        |
|---|---|
| `Sparql.{select,ask,construct,execute}` | `data` → `graph:` |
| `Reasoner.materialise!`             | `data` → `asserted:`, `inferred` → `inferred:` |
| `Shacl.validate`                    | `data` → `data_graph:`, `shapes` → `shapes_graph:`, `report` → `report_graph:` |
| `Shacl::Rules.materialise!`         | `data` → `data_graph:`, `shapes` → `shapes_graph:`, `inferred` → `inferred:` |
| `ChangeSet.capture` (PLAN_0.11.0)   | Already accepts `scope:` directly. |

Each facade checks `scope.read_write_overlap?` up front and refuses
with `:scope_read_write_overlap` when present.

#### Implementation
- Each facade gets a `scope:` kwarg with the existing per-graph
  kwargs as alternative paths. The internal logic stays unchanged
  — the kwargs are translated to the existing per-graph form
  before reaching the implementation.
- Translation lives in a shared `Semantica::Scope::FacadeAdapter`
  helper (one method) — DRY across the four facades.
- `:scope_kwarg_conflict` / `:scope_role_missing` /
  `:scope_read_write_overlap` refusal envelopes pinned.

#### Exit criteria
- Spec per facade: passing a fully-populated Scope produces
  identical output to passing the equivalent per-kwarg call.
- Spec per facade: passing `scope:` + an overlapping kwarg
  refuses with `:scope_kwarg_conflict`.
- Spec per facade: passing a Scope missing a required role
  refuses with `:scope_role_missing` naming the missing role.
- Spec: passing a Scope with read/write overlap refuses with
  `:scope_read_write_overlap`.

### Phase E — Specs + bin/check

- Phase A: `spec/semantica/capability_predicates_spec.rb`.
- Phase B: extend `spec/semantica/ethereal_graph_spec.rb` with the
  N-Triples-star round-trip example; extend
  `spec/semantica/sparql_spec.rb` with `split_ntriple` tokenizer
  tests for the `<< … >>` form.
- Phase C: extend `spec/semantica/scope_spec.rb` with the
  contract-pin and `Scope.from_` examples.
- Phase D: `spec/semantica/scope_kwarg_facade_spec.rb` covers
  all four facades' `scope:` acceptance + refusals.
- `bin/check` green against engine ≥ 0.8.0.

### Phase F — Docs + cross-references

- `CHANGELOG.md` — `0.13.0` heading with per-phase entries; cite
  CONSUMER_REQUIREMENT_VV.md as the driver.
- `README.md` — new "Cross-graph scopes" section after the
  EtherealGraph section, with the Scope contract + the
  `scope:` kwarg shape.
- `README.md` — new "Capability predicates" subsection under
  "Versioning" pinning the three Phase-A methods.
- `CONSUMER_REQUIREMENT_VV.md` — graduate B1 and B3 from "open"
  to "landed"; B2 stays open for PLAN_0.8.0 Phase B.
- `CONSUMER_REQUIREMENT_MM.md` — note that the `scope:` kwarg is
  available, but MM's `Storable + Sparql.execute` shape doesn't
  exercise it. The Scope surface is documented as VV-facing
  primarily.
- `docs/plans/PLAN_0.13.0.md` — this file. Update "Current
  state" as phases land.
- `VERSION` → `0.13.0`.

## Out of scope for v0.13.0

- **B2 — `annotate` DSL + `Sparql.quoted_triple` marker.** Stays
  scoped to PLAN_0.8.0 Phase B per VV's own framing ("ergonomics
  … welcome, not blocking"). v0.13.0 introducing `annotate`
  alongside B1 + B3 would conflate three independent surface
  changes; cleaner to land each in its own version.
- **Cross-graph DRed (graph-aware provenance traversal).**
  PLAN_0.11.0 deferred this to v0.13.0+ candidate territory. VV
  doesn't need it — VV writes Conformer annotations through
  `Sparql.execute` directly and persists via EtherealGraph blobs;
  the incremental DRed surface is MM's territory once MM adopts
  PLAN_0.11.0. Revisit cross-graph DRed in a future plan if MM
  signals a multi-scope DRed workload.
- **Multi-graph rule rewriter for OWL 2 RL / SHACL Rules.** The
  earlier draft of PLAN_0.13.0 proposed mechanically rewriting
  every Rules::OwlRl rule with the `USING <data> USING <schema>`
  union to span multiple read graphs. VV doesn't need this — VV's
  per-scope Silver graphs each carry their own asserted +
  inferred contents; cross-scope reasoning isn't on VV's roadmap.
  Defer to a future plan if/when MM or another consumer signals
  demand.
- **`semantica:derivedFromGraph` provenance annotation.** Sibling
  to the multi-graph rule rewriter above — only useful if
  cross-graph derivations land. Defer.
- **`scope:` kwarg on the `Storable` DSL.** MM's `Storable`
  declares `graph "…"` per model; layering `scope:` on top would
  require MM to teach `Storable` what scope a model belongs to,
  which it doesn't natively know (the model is the source of
  truth, not the scope). MM hasn't asked.
- **`Scope.registry` auto-population from `Storable` / `EtherealGraph`
  declarations.** Documented as operator-populated. v0.13.0 ships
  registry as a Set with `<<` / `find_by_data`; auto-population
  is a v0.14.0+ candidate if substrate-side telemetry shows the
  boilerplate is enough cost.
- **Cross-scope cascade.** A change in scope A's shared schema
  graph automatically triggering re-materialisation in every
  scope B that consumes A's schema. Out of scope; substrate
  orchestration responsibility.

## Risks

| Risk | Mitigation |
|---|---|
| `split_ntriple` bracket-balanced tokenizer regression on non-star inputs. | New tokenizer is additive — the per-character `<` / `>` semantics for IRIs stay unchanged; only `<<` / `>>` get balanced-pair handling. Pre-existing N-Triples specs continue to run. |
| `Semantica.checkpoint_can_round_trip?` returning `true` for a content kind that the implementation later regresses. | Tied to the same spec harness that exercises B1's round-trip; if the round-trip breaks, the predicate flips to `false` automatically (the implementation reads from a live capability check, not a static flag). |
| `Scope.from_(graph_iri)` ergonomics encourage consumers to skip declaring `schema` / `shapes` / `inferred` / `report` — they end up with `:scope_role_missing` refusals at facade-call time. | Documentation pins the per-role requirements; refusal `because:` clauses name the missing role explicitly so the error is actionable. |
| `scope:` kwarg adds a parallel path that diverges from the per-kwarg path. | Phase D's per-facade equivalence spec pins identical output across the two shapes (same input data, two calling conventions, same envelope). Drift is a spec failure. |
| VV's `~> 0.7` pin allows 0.13.0 transparently (since `~> 0.7` is `>= 0.7, < 1.0`). | The pin already accommodates v0.13.0. VV's pin moves to `>= 0.8.0` lockstep with PLAN_0.8.0 Phase B; v0.13.0 is in the absorbed range. |
| `facade_version` and `VERSION` drift confuses operators. | README documents the distinction: `VERSION` is the release tag; `facade_version` is the capability epoch — both equal at v0.13.0 release. They diverge only when a release ships pure bugfixes that don't add capabilities. |
| VV's B1 spec un-pends but the round-trip is partial — some star content survives, some doesn't. | Phase B's exit criterion is "all triples round-trip" via an exhaustive fixture (subject-position quoted triples, object-position quoted triples, nested quoted triples, mixed in a single blob). Partial survival fails the spec. |

## Acceptance signal

1. Phases A/B/C/D land with passing specs.
2. `bin/check` green against engine ≥ 0.8.0.
3. CONSUMER_REQUIREMENT_VV.md B1 graduates from "Severity:
   load-bearing" to "Landed in 0.13.0".
4. CONSUMER_REQUIREMENT_VV.md B3 graduates from "Severity:
   forward-compat" to "Landed in 0.13.0".
5. VV's `silver_star_passthrough_spec.rb`'s pending example
   transitions to passing (cross-verified via VV's `bin/check`
   against a `path:`-pinned `rails-semantica` rev = v0.13.0).
6. CHANGELOG `0.13.0` heading drops `(unreleased)`.
7. `VERSION` → `0.13.0`.
8. README documents Cross-graph scopes + Capability predicates.

## v0.13.0 contract additions (frozen at release)

| Surface | Shape | Mutability |
|---|---|---|
| `Semantica.rdf_star_writes_enabled?` | module predicate → Boolean | **Pinned.** Tracks PLAN_0.8.0 Phase B; returns true once that ships. |
| `Semantica.facade_version` | module method → String | **Pinned.** Compare via `Gem::Version`. |
| `Semantica.checkpoint_can_round_trip?(content_kind:)` | module predicate → Boolean | **Pinned.** `content_kind:` values: `:plain_ntriples`, `:ntriples_star`. Unknown kinds raise `ArgumentError`. |
| `Sparql.split_ntriple` accepts `<< s p o >>` tokens | internal helper extension | **Internal — pinned behaviour.** Operators don't call this directly; the contract is the round-trip property pinned by `checkpoint_can_round_trip?`. |
| `Semantica::Scope` five-role shape (`data` / `schema` / `shapes` / `inferred` / `report`) | value object | **Pinned.** Roles additive in future minor versions. |
| `Semantica::Scope.from_(graph_iri)` | factory method | **Pinned.** Returns degenerate Scope with that IRI as `data:`. |
| `scope:` kwarg on `Sparql.{select,ask,construct,execute}` | kwarg | **Pinned.** Alternative to `graph:`. |
| `scope:` kwarg on `Reasoner.materialise!` | kwarg | **Pinned.** Alternative to `asserted:` / `inferred:`. |
| `scope:` kwarg on `Shacl.validate` | kwarg | **Pinned.** Alternative to `data_graph:` / `shapes_graph:` / `report_graph:`. |
| `scope:` kwarg on `Shacl::Rules.materialise!` | kwarg | **Pinned.** Alternative to `data_graph:` / `shapes_graph:` / `inferred:`. |
| `:scope_kwarg_conflict` reason symbol | refusal envelope | **Pinned.** |
| `:scope_role_missing` reason symbol | refusal envelope (includes role name in `because:`) | **Pinned.** |
| `:scope_read_write_overlap` reason symbol | refusal envelope | **Pinned.** |
| `Semantica::Scope::FacadeAdapter` | internal helper | **Internal.** Operators consume via the facade kwargs, not this class. |

## Cross-references

- `./PLAN_0.7.0.md` — EtherealGraph; v0.13.0 Phase B patches the
  N-Triples-star hydrate gap that VV B1 surfaced.
- `./PLAN_0.8.0.md` — RDF-star pass-through; v0.13.0 Phase A's
  `Semantica.rdf_star_writes_enabled?` predicate-flag is the
  consumer surface for PLAN_0.8.0 Phase E's feature gate.
- `./PLAN_0.11.0.md` — `Semantica::ChangeSet.capture(scope:)` —
  the first facade to accept a Scope. v0.13.0 Phase D mirrors
  the shape on Reasoner / Shacl / Shacl::Rules.
- `./PLAN_0.5.0.md` — named-graph DSL; the `graph:` kwarg the
  `scope:` kwarg layers on top of.
- `../research/TripesQuadsEtc.md` — the original "named graphs
  are how scope is named" framing.
- `magentic-market-ai/docs/research/StarExts.md` — the W3C-CG
  spec the B1 fix is necessary to fully consume.
- `CONSUMER_REQUIREMENT_VV.md` — **the driver document.** Every
  Phase here maps to a section there.
- `CONSUMER_REQUIREMENT_MM.md` — sibling consumer signal; MM
  doesn't yet ask for Scope, but the surface is available if MM
  ever signals demand.
- `sqlite-sparql/CHANGELOG.md` § `0.7.0` — engine prereq for
  Phase B's bulk-insert path (already shipped). Engine pin
  inherits from v0.8.0.
