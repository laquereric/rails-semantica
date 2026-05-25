# Consumer requirements — `vv-memory` substrate

This file records the surface
[`vv-memory`](https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-memory)
("VV" hereafter) consumes from `vv-graph`. Mirrors the pattern
in `CONSUMER_REQUIREMENT_MM.md`: upstream changes can be checked
against a written consumer expectation — **drift** between this file
and the gem's actual behaviour signals work that needs to land in
both repos lockstep.

This is VV's perspective, not the upstream spec. MM (the substrate)
keeps its own `CONSUMER_REQUIREMENT_MM.md`; the two are intentionally
separate because the consumption shapes differ. MM uses `Storable` +
`Sparql.execute` directly; VV uses `EtherealGraph` + `Sparql.execute`
through its own `Vv::Memory::Scoped` concern. Both can evolve at
different speeds.

- VV repo: <https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-memory>
- VV plan that introduced the dependency: `docs/plans/PLAN_0.1.0.md`
  (substrate Bronze + Silver — Silver is `Vv::Graph::EtherealGraph`).
- VV plan that deepens the dependency: `docs/plans/PLAN_0.2.0.md`
  (Conformer → SPARQL-star writes through `Sparql.execute`).

## How VV pins this gem

```ruby
# vv-memory/vv-memory.gemspec
spec.add_dependency "rails-semantica", "~> 0.7"
```

The pin is intentionally **tight** at the major-zero level. VV is
willing to absorb any 0.7.x patch transparently; pre-release 0.x
freedom is what makes the two-repo coupling tolerable. The pin
moves to `>= 0.8.0` lockstep with the Writer migration from raw
SPARQL-star UPDATE strings to the `annotate` DSL (see "P2 pin
migration trigger" below).

## The layering rule — load-bearing

> **VV consumes `vv-graph` directly.**
> **VV does NOT consume `sqlite-sparql` directly.**

Concretely:

1. VV's gemspec **declares** `vv-graph`. It **does not declare**
   `sqlite-sparql`. The engine is `vv-graph`'s private
   dependency from VV's POV.
2. VV's `lib/`, `app/`, and `spec/` directories may reference
   `Vv::Graph::*` constants freely. They may **not** reference
   `Sqlite::Sparql::*`, `Vv::Graph::Loader`, or any `rdf_*` / `sparql_*`
   scalar by name. The engine is opaque to VV.
3. VV's spec harness loads the engine via
   `Vv::Graph::Loader.ensure_extension_loaded!` (the single permitted
   reference to the Loader) but never branches on engine version or
   scalar availability. Capability questions are answered by
   `vv-graph`-side predicates (see "Predicate-shaped capability
   advertisements" below), not by VV-side engine introspection.
4. Routing inside VV's Conformer Writer expresses *what to write*
   (a parent triple + N RDF-star annotations) and lets
   `Sparql.execute` decide *how to get it into the engine*. If a
   future `vv-graph` release changes the dispatch_update
   regex table, the Writer should not need to update — the
   semantics it cares about (graph-scoped INSERT of an annotated
   triple) are what's pinned, not the SPARQL form that achieves them.

**Why this rule.** Two reasons:

- **Engine substitutability.** If `vv-graph` ever swaps
  `sqlite-sparql` for Oxigraph-embedded, Apache Jena-via-JNI, or a
  cloud Stardog, VV should not need a single line of change. The
  whole point of `vv-graph` is to be that abstraction
  boundary; VV would erase its value by reaching through it.
- **Surface drift containment.** When the engine bumps a scalar
  signature (e.g., `sqlite-sparql` 0.7.0's `rdf_term_value` prefix
  change), the audit + adaptation lives in *one* place (the
  `Sparql::classify_statement_error` codepath). VV inherits the
  fix for free instead of carrying a parallel audit.

The corollary: **VV is encouraged to lean harder on `vv-graph`
surfaces over time.** When VV finds itself wanting to escape the
facade (e.g., to construct a quoted-triple term in Ruby), the
correct move is to file an upstream request adding the surface to
`vv-graph`, not to reach past it.

## Surfaces VV consumes

### `Vv::Graph::EtherealGraph` concern — the load-bearing dependency

VV's entire reason to exist is to wrap this concern. `Vv::Memory::Scoped`
transparently `include`s `Vv::Graph::EtherealGraph` on the host AR
record and forwards its `silver_iri` lambda into the `ethereal_graph
do; iri ...; end` block.

What VV depends on:

- `include Vv::Graph::EtherealGraph` — pinned concern name.
- `ethereal_graph do; iri -> {...}; checkpoint_on :explicit|:save; end` — pinned DSL.
- `#hydrate_ethereal_graph!` — idempotent first-touch hydrate from blob → engine.
- `#checkpoint_ethereal_graph!` — flush engine → blob.
- `#retract_ethereal_graph!` — registered as `before_destroy`; clears the named graph + purges the blob.
- The `:vv_graph_blob` Active Storage attachment name (pinned upstream).
- `Vv::Graph::EtherealGraph.evict!(iri)` — clears the per-process hydrated-cache marker so the next call re-hydrates from blob.
- The `:reason:` symbol vocabulary returned by the three lifecycle methods (`:already_hydrated`, `:no_blob`, `:empty_blob`, `:ethereal_graph_undeclared`, `:reentrant_checkpoint`). VV propagates these into its own `#memory_silver` return shapes; rename or removal is breaking.

What VV explicitly does NOT introspect:

- The thread-local re-entrancy guard in `checkpoint_ethereal_graph!`.
- The `HYDRATED_IRIS` process-wide Set or its mutex.
- The N-Triples / N-Triples-star wire format of the blob's contents.
  (See the `parse_ntriples` open item under "Boundary items" — VV
  has an opinion on the *behaviour* of hydrate over RDF-star content,
  not the byte-level shape.)

### `Vv::Graph::Sparql` four-method facade

VV calls all four. Envelope discipline matters — VV's user-facing
methods (`#record_episode` aside, which is AR-shaped) compose
`vv-graph` envelopes verbatim into their own returns. Drift
in envelope keys ripples one layer up.

```ruby
Vv::Graph::Sparql.select(query,  graph: iri)
Vv::Graph::Sparql.ask(query,     graph: iri)
Vv::Graph::Sparql.construct(query, graph: iri)
Vv::Graph::Sparql.execute(update, graph: iri)
```

VV's expectations on each:

- **All four pass SPARQL-star syntax through verbatim.** Quoted-triple
  patterns (`<< s p o >>`), annotation shorthand (`{| p o |}` in
  Turtle-star inputs), and the SPARQL-star built-ins (`isTRIPLE`,
  `SUBJECT`, `PREDICATE`, `OBJECT`, `TRIPLE`) all reach the engine
  unmangled. The Conformer Writer in VV's PLAN_0.2.0 depends on this.
  Pinned by `spec/semantica/sparql_star_spec.rb` (upstream) and
  cross-pinned by `spec/vv/memory/silver_star_passthrough_spec.rb`
  (VV-side, exercising the gem's facade rather than the engine).
- **`graph:` composes with all four.** Per-scope named graphs are the
  whole reason VV exists; every Silver-side call goes through `graph:`.
- **Envelopes are stable in shape across versions.** Additive new keys
  are fine; renames or removals require a coordinated bump. VV's
  consumers (mostly its own `#memory_silver` proxy hash plus the
  forthcoming Conformer Writer) destructure `:ok`, the payload key
  (`:results` / `:value` / `:ntriples` / `:count`), `:reason`, and
  `:because` only.
- **`:reason:` symbol vocabulary is pinned at the rails-semantica
  contract level.** VV consumes `:sparql_parse_error`,
  `:sparql_eval_error`, `:invalid_graph`, `:invalid_dsl`,
  `:extension_not_loaded`, `:ar_connection_error`, `:unexpected_error`.
  Additions are safe; removals are breaking. VV's
  `spec/vv/memory/silver_star_error_classification_spec.rb` is the
  inoculation against a regression in the classification of
  malformed quoted-triple inserts (currently green).

### `Vv::Graph::Sparql.store_size(graph: iri)`

Used in VV's hydrate-side assertions to confirm content survived a
checkpoint / evict / re-hydrate cycle. Envelope: `{ ok: true, count: <integer> }`.

### `Vv::Graph::Sparql.bulk_insert(rows, raw: true)`

VV does **not** call this directly — but `Vv::Graph::EtherealGraph#hydrate_ethereal_graph!`
does, on the rows produced by its internal `parse_ntriples`. The
indirect dependency matters because the bulk_insert raw-mode contract
gates whether N-Triples-star content survives the round-trip (see
boundary item B1 below).

## Predicate-shaped capability advertisements (encouraged)

VV would benefit from `vv-graph` exposing more capability
predicates. The existing one VV needs:

- **`Vv::Graph.rdf_star_writes_enabled? → Boolean`** — pinned in
  PLAN_0.8.0 Phase E. Not yet implemented at the time of writing
  (rails-semantica 0.7.0). VV's `Vv::Memory.rdf_star_writes_enabled?`
  delegates if defined, otherwise falls back to
  `defined?(::Vv::Graph::EtherealGraph)` — adequate under the P1
  pin posture, but the upstream predicate is the source of truth
  once 0.8.0 ships.

Predicates VV would consume if they existed:

- `Vv::Graph.checkpoint_can_round_trip?(content_kind:)` —
  `:plain_ntriples` / `:ntriples_star`. The honest answer for
  `vv-graph` 0.7.0 is `true` / `false` respectively (see
  boundary item B1). Letting VV ask the question rather than infer
  from gem version would mean VV's hydrate-blocking spec can
  un-pend automatically when upstream answers `true`.
- `Vv::Graph.facade_version → String` — capability epoch independent
  of `VERSION`. Lets VV reason about "is the `annotate` DSL
  reachable" without parsing the gem's gemspec.

The general principle: **VV would rather call a predicate than
introspect a version.** Predicates are testable, version strings
are not.

## Boundary items — open requests back to `vv-graph`

These are concrete asks VV has on `vv-graph`'s roadmap. They
are recorded here so the next operator working either repo sees the
two-sided commitment.

### B1 — `EtherealGraph.parse_ntriples` must round-trip N-Triples-star

**Severity: load-bearing. Status: scoped upstream 2026-05-24, implementation pending.**

**Problem (original framing).** The Conformer in VV's PLAN_0.2.0
writes RDF-star annotations into per-scope named graphs through
`Sparql.execute`. Writes ✓, reads ✓, checkpoint-to-blob ✓.
**Re-hydrate ✗** — the blob round-trip drops every line
containing `<<>>`, because `parse_ntriples`
(`lib/semantica/ethereal_graph.rb:235`) per-lines through
`Sparql.split_ntriple` (whitespace-tokenizing), which sees `<<`
as two separate `<` tokens.

**Net P1 envelope under rails-semantica 0.7.0:** scopes carrying
Conformer-produced annotations cannot survive an evict +
re-hydrate cycle. VV documents this as an operator-facing
constraint in v0.2.0's README, but the constraint is awkward; it
makes Silver effectively non-portable across process restarts
when star content is present.

**Upstream response (2026-05-24).** `vv-graph` rewrote
PLAN_0.13.0 same-day to scope the fix as part of its expanded
"VV-driven consumer alignment + Scope" framing. Implementation
is pending in that plan. VV's regression spec
(`vendor/vv-memory/spec/vv/memory/silver_star_passthrough_spec.rb`'s
hydrate / checkpoint / evict / re-hydrate example) is marked
`pending` with a verbatim upstream pointer and **un-pends
automatically when the fix lands**. No further upstream push
required from VV's side; the next move belongs to the
PLAN_0.13.0 implementation.

**Suggested-fix routes that informed the upstream scoping:**

1. Delegate `parse_ntriples` to the engine's `rdf_load_ntriples`
   scalar — `sqlite-sparql` 0.7.0 added N-Triples-star support
   there. This trades a Ruby-side parser for an FFI roundtrip per
   blob, which is a wash given hydrate already pays an
   `each_slice(HYDRATION_BATCH_SIZE).bulk_insert` cost.
2. Teach the existing per-line parser to recognize `<<...>>`
   grouping and emit the line verbatim to `bulk_insert(raw: true)`,
   which then dispatches `rdf_insert_many` — `sqlite-sparql` 0.7.0
   accepts quoted-triple terms in the `_many` form.

Either route satisfies VV's regression. Choice is upstream's
to make; VV's contract is on the *behaviour* (hydrate round-trip
of N-Triples-star content), not the implementation.

**Downstream implication.** VV's `docs/plans/PLAN_0.3.0.md`
(Gold tier + Curator) lists this fix as a **hard prerequisite**.
The Gold `gold:facts` graph is annotation-heavy and cannot
survive evict without the fix. The dependency chain is:
`vv-graph` PLAN_0.13.0 (B1 fix) → `vv-memory` PLAN_0.2.0
Phase D integration spec (un-pends) → `vv-memory` PLAN_0.3.0
implementation start.

### B2 — `annotate` DSL and `Sparql.quoted_triple` marker (PLAN_0.8.0 Phase B)

**Severity: ergonomics. Status: scoped upstream (PLAN_0.8.0 Phase B), implementation pending.**

VV's Conformer Writer under P1 interpolates raw SPARQL-star UPDATE
strings into a heredoc and dispatches via `Sparql.execute`. This
works and is currently the canonical shape inside `vv-graph`
itself (PLAN_0.9.0 / 0.10.0 / 0.12.0 Phase B implementations all
emit RDF-star provenance the same way). Landing PLAN_0.8.0 Phase B
turns the Writer's one method into a DSL block and lifts
`after_destroy` annotation retraction into the framework. Welcome,
not blocking. When it lands, VV's gemspec moves to `>= 0.8.0`
lockstep with the Writer migration, gated behind
`Vv::Memory.rdf_star_writes_enabled?`.

The validation by sibling-gem example (PLAN_0.9.0 / 0.10.0 / 0.12.0
Phase B all shipping raw `Sparql.execute` without waiting on this
DSL) lowers the urgency: this is a Writer-internal ergonomics
improvement when it arrives, not a semantic correction.

### B3 — `Vv::Graph::Scope` value object (PLAN_0.13.0)

**Severity: forward-compat. Status: ✅ closed 2026-05-24.**

PLAN_0.13.0 introduces a value-object generalisation of "this set
of named graphs forms one reasoning scope." The Scope value object
landed in commit `2e44f35` alongside the Phase-A batch for v0.8.0
through v0.12.0. PLAN_0.13.0 was rewritten same-day to anchor on
the VV consumer signal, formalise the Scope contract, and ship
the predicate-shaped capability advertisements
(`Vv::Graph.rdf_star_writes_enabled?` etc.) that VV's layering
rule needs.

The eventual VV v0.3.0+ `Curator` (`vendor/vv-memory/docs/plans/PLAN_0.3.0.md`)
and v0.4.0+ recall facade (`vendor/vv-memory/docs/plans/PLAN_0.4.0.md`
sketch) both anchor their cross-graph operations on `Vv::Graph::Scope`
rather than re-inventing scope semantics — the original ask of
this boundary item.

### B4 — PLAN_0.14.0 Path A (`Vv::Graph::Decision`) is in the wrong layer

**Severity: layering correction. Status: filed 2026-05-25, awaiting upstream re-frame.**

`vv-graph`'s draft PLAN_0.14.0 surveys the upstream Python
project [`semantica-agi/semantica`][upstream-decisions] and
recommends **Path A** — a `Vv::Graph::Decision` concern with
verb-shaped methods (`record_decision`, `trace_decision_chain`,
`find_similar_decisions`, `analyze_decision_impact`,
`check_decision_rules`) implemented as a Storable extension. The
implementation draft PLAN_0.14.1 builds on it.

[upstream-decisions]: https://github.com/semantica-agi/semantica

**VV's response: Path A does not belong in `vv-graph`.**

The architectural reason — articulated in
`vendor/../docs/research/DecisionLayer.md` in the substrate
parent repo — is that decisions are not triple-shaped. They are a
**flow**: context → query → reasoning → decision → action →
impact. Each step carries provenance distinct from the others. A
Storable concern emitting triples about a decision's *outcome*
discards the structure of the *flow*.

The substrate stack has three concerns, not two:

| Layer | Concern | Home |
|---|---|---|
| Graph | Triple storage + reasoning | `vv-graph` |
| Memory | Bronze/Silver/Gold lifecycle | `vv-memory` |
| Decision flow | context → query → decide → act lifecycle | **A new gem (working title `vv-decisions`)** — not yet drafted |

Path A's responsibility belongs in that third layer. Routing it
into `vv-graph` widens the graph gem's lane past "I store
and reason over triples" into "I own how an agent makes a
decision." That's a different invariant.

**Recommended re-frame for PLAN_0.14.0.**

- **Path A — drop from `vv-graph`'s direction-set.** The
  spirit lives in a future `vv-decisions` gem above
  `vv-memory`. The decision-flow lifecycle, the aggregate root,
  the `deliberate(...)` entrypoint, the `trace_back` /
  `alternatives_considered` / `impact` read surface all live
  there. See `DecisionLayer.md` for the sketch.
- **Path B — MCP server + Claude Code plugin bundle.** Stays
  in lane. Exposes the existing `Vv::Graph::*` facades as MCP
  tools. No new conceptual responsibility on the gem. **VV
  endorses Path B.**
- **Path C — Knowledge Explorer Rails engine.** Stays in lane.
  Visualisation of existing graph state. **VV endorses Path C
  as acceptable** (larger scope; lower per-LOC ROI than B).

What VV would consume from Path B specifically: an MCP tool
surface that exposes `Sparql.{select,construct,execute}` +
`Reasoner.materialise!` + `Shacl.validate` + `EtherealGraph`
lifecycle, all `scope:`-aware. The future `vv-decisions` gem's
`deliberate(...)` block would compose with those MCP tools when
the agent under deliberation is itself an MCP-aware coding
agent, but the gem-side primitives stay graph-shaped, not
decision-shaped.

**Two misfiled PLAN drafts.** PLAN_0.14.0 and PLAN_0.14.1 landed
as `vendor/vv-memory/docs/plans/PLAN_0.5.0.md` and
`PLAN_0.5.1.md`. VV `git rm`'d those (commit on the parent repo
side); they should not be moved into `vv-graph`'s plans
directory in their current form because their content commits
to Path A. If/when the maintainer re-frames PLAN_0.14.0 to
endorse Path B or Path C without Path A, the re-framed plan
belongs in `rails-semantica/docs/plans/PLAN_0.14.0.md` and is
welcome.

**Downstream implication.** vv-memory's PLAN_0.2.0 Conformer
ships its own `vvmem:` provenance vocabulary on Silver
annotations as drafted; nothing in this boundary item changes
the v0.2.0 contract. When `vv-decisions` ships, it adds a
sibling `vvdec:` namespace for decision-flow-specific
predicates and likely a Conformer `DecisionExtractor`
subclass — extending vv-memory's existing surface, not
replacing it.

## Behaviours VV does NOT depend on

Upstream is free to change these without notifying VV:

- The exact contents of the `:vv_graph_blob` Active Storage
  attachment's filename (sanitised slug; VV never inspects it).
- The internal ordering of dispatch_update's regex-fast-path table —
  VV cares that the *semantics* of "graph-scoped INSERT of an
  annotated triple" works, not which branch handles it. The current
  P1 Writer happens to route through the `else` branch (engine
  `sparql_update`); if a future release teaches the fast paths to
  honor `<<>>`, the Writer can simplify to `INSERT DATA` without
  any envelope change.
- The exact `HYDRATION_BATCH_SIZE` constant in `EtherealGraph`.
- The presence or absence of `Storable` in VV's host process. VV
  does not include `Storable` and does not interact with its DSL.
  (MM does; the two consumers compose cleanly in the same Rails
  app per PLAN_0.7.0 Phase D.)
- The specific Oxigraph version under the engine. (Engine version
  itself is not VV's business — see the layering rule above.)

## Engine — explicitly not VV's concern

VV's gemspec **does not** add `sqlite-sparql` as a dependency. VV's
`Gemfile.lock` happens to contain it transitively via `vv-graph`,
which is the desired posture: VV is unaware of the engine's name,
version, or build artefact, except for the single permitted
`Vv::Graph::Loader.ensure_extension_loaded!` call in the spec harness.

Concretely, if a maintainer is tempted to:

- `require "sqlite_sparql"` somewhere in VV's `lib/` — **don't.**
  File a request against `vv-graph` to expose the surface
  you wanted to reach.
- Branch on the engine's CHANGELOG entries — **don't.** Branch on
  a `vv-graph` predicate (existing or proposed in
  "Predicate-shaped capability advertisements" above).
- Add a VV-side scalar like `rdf_*` or `sparql_*` reference for
  performance — **don't.** The performance question belongs in
  `vv-graph`'s bulk-write facade or a new one; the consumer
  is the wrong layer to optimise it.

This is not a hostile boundary — it's a deliberate one. VV exists
*so that* consumers (MM, future Rails apps) get a one-line `include`
shape on top of a complex Silver-tier substrate. The layering only
holds if VV maintains the same discipline relative to *its*
substrate (`vv-graph`) that it offers its own consumers.

## Versioning expectation

While `vv-graph` is v0.x.x, VV tracks the path-sourced rev
directly via the `~> 0.7` pin. At rails-semantica v1.0 the surfaces
above are pinned by semver. VV will move from `~> 0.7` / `>= 0.8`
era pins to the standard `~> 1.x` pattern at that point.

## Drift signals

A drift between this file and `vv-graph`'s behaviour is
detectable in:

- `vendor/vv-memory/spec/vv/memory/scoped_integration_spec.rb` —
  PLAN_0.1.0 Phase D acceptance signal: include the concern on a
  fixture AR record, record episodes, emit triples, checkpoint,
  evict, re-hydrate, assert both tiers survived. Plain (non-star)
  content; currently green.
- `vendor/vv-memory/spec/vv/memory/silver_star_passthrough_spec.rb` —
  PLAN_0.2.0 Phase A.2 acceptance signal: same scope, exercises
  the SPARQL-star path the Conformer Writer will use. Currently
  27 passing, 1 pending (B1 above).
- `vendor/vv-memory/spec/vv/memory/silver_star_error_classification_spec.rb` —
  PLAN_0.2.0 Phase A.3 inoculation: malformed quoted-triple INSERT
  must come back classified actionably, not as `:unexpected_error`.
  Currently green; the pending branch activates only on regression.
- `vendor/vv-memory/bin/check` — wraps the three above + the Bronze
  AR specs.

When `vv-graph` ships a release that changes one of the
surfaces enumerated above, the upstream PR description should
reference this file. The VV-side adaptation lands in a follow-up
commit that updates this file's relevant section in the same patch.

## Contact

VV maintainers — file an issue in the MM parent repo with the
`vv-memory` label, or open the PR directly against
`vendor/vv-memory/` in the substrate monorepo.
