# Consumer requirements — `vv-visualize` substrate

This file records the surface
[`vv-visualize`](https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-visualize)
("VVZ" hereafter) consumes from `vv-graph`. Mirrors the pattern
in `CONSUMER_REQUIREMENT_MM.md` and `CONSUMER_REQUIREMENT_VV.md`:
upstream changes can be checked against a written consumer
expectation — **drift** between this file and the gem's actual
behaviour signals work that needs to land in both repos lockstep.

This is VVZ's perspective, not the upstream spec. MM (the
substrate) and VV (vv-memory) keep their own
`CONSUMER_REQUIREMENT_{MM,VV}.md`; the three are intentionally
separate because the consumption shapes differ:

- MM uses `Storable` + `Sparql.execute` directly.
- VV uses `EtherealGraph` + `Sparql.execute` through
  `Vv::Memory::Scoped`.
- VVZ uses **`Sparql.{select,ask,construct}`** through `Vv::Graph::Scope`
  with the data graph role. It is the substrate's first **read-only**
  consumer; the load shape is dominated by bounded-BFS SELECT
  rather than UPDATE.

- VVZ repo: <https://github.com/laquereric/magentic-market-ai/tree/main/vendor/vv-visualize>
- VVZ plan that introduced the dependency:
  `docs/plans/PLAN_0_1_0.md` (Phase B Explorer ego/heatmap;
  Phase C Path inspector).
- VVZ plan covering the extension-build wiring this CC's central
  topic: `docs/plans/PLAN_0_1_9.md`.

## How VVZ pins this gem

```ruby
# vv-visualize/vv-visualize.gemspec
spec.add_dependency "vv-graph", "~> 0.15"
```

The pin is **looser** than VV's because VVZ does not exercise the
RDF-star write path. Any 0.15.x / 0.16.x / 0.17.x release that
preserves the four-method facade signatures + Scope value object
shape works for VVZ. The pin moves to `>= 0.18` lockstep with
**B1** below (the path-resolution fix that lets nested Combustion
specs find the extension).

## The layering rule — load-bearing

> **VVZ consumes `vv-graph` directly.**
> **VVZ does NOT consume `sqlite-sparql` directly.**
> **VVZ does NOT consume `Vv::Graph::Storable`, `EtherealGraph`,
>  or any update-side surface.**

Concretely:

1. VVZ's gemspec declares `vv-graph`. It declares neither
   `sqlite-sparql` nor any RDF/SHACL gem in its own right. SHACL
   evaluation, if VVZ surfaces it (PLAN_0_1_0 phase F.1), goes
   through `vv-graph`'s SHACL facade — VVZ does not embed a
   parallel engine.
2. VVZ's `lib/` and `app/` reference **only** these `Vv::Graph::*`
   constants:
   - `Vv::Graph::Scope` (value object — constructed with `data:`,
     optionally `schema:`, `shapes:`, `inferred:`, `report:`)
   - `Vv::Graph::Sparql` (the four-method facade; VVZ today uses
     `select` exclusively)
   - `Vv::Graph::Loader` (referenced **only** from
     `spec/support/extension_path.rb`, the spec-side resolver —
     never from `lib/` or `app/`)
3. VVZ does **not** introspect `Sqlite::Sparql::*`, `rdf_*`
   scalar names, or any engine-version probe. Capability questions
   go through the predicates from
   `Vv::Graph::Capabilities`.
4. Writes are out of layer. VVZ's only write seam is staging Bronze
   episodes via `Vv::Memory::Scoped#record_episode` (see VV's
   `CONSUMER_REQUIREMENT_VV.md`). VVZ never calls
   `Vv::Graph::Sparql.execute` directly.

**Why this rule.** Same two reasons as VV's CC, with one
VVZ-specific addition:

- **Engine substitutability.** Same as VV.
- **Surface drift containment.** Same as VV.
- **Read/write isolation.** VVZ is the substrate's read-only
  surface. Restricting it to the read-side facade is what lets
  vv-visualize-mcp (PLAN_0_1_5) safely expose VVZ's surfaces to
  external agents — the worst a bug can do is leak a triple
  publicly, not mutate one.

## Surfaces VVZ consumes

### `Vv::Graph::Scope` value object

Every VVZ entry point takes a Scope. Only the `data` role is
strictly required; `schema` and `shapes` become required when
VVZ's SHACL surface (PLAN_0_1_0 phase F.1) wires up.

What VVZ depends on:

- `Vv::Graph::Scope.new(data: iri[, schema:, shapes:, inferred:, report:])`
  — pinned constructor kwargs.
- `scope.data` — pinned reader; returns the data-graph IRI string.
- Value equality + frozen semantics — pinned (two Scopes with the
  same role IRIs are the same Scope).

What VVZ does NOT introspect:

- The `additional:` Hash escape hatch (`PLAN_0.13.0` Phase A) —
  VVZ has no use case for it.
- The per-facade required-role checking happens inside vv-graph;
  VVZ does not pre-check.

### `Vv::Graph::Sparql.select(query, graph:)`

The **only** vv-graph entry VVZ calls in `lib/`. Every
Explorer-side BFS hop, every Path inspector frontier expansion,
every saved-query resolution funnels through this one method.

VVZ's expectations:

- Envelope: `{ ok: true, results: [{ "var" => value, ... }, ...] }`
  or `{ ok: false, reason: <symbol>, because: <verbatim engine message> }`.
- The `graph:` kwarg accepts the scope's `data` IRI. Default-graph
  fallback (`graph: nil`) is not used by VVZ.
- **VVZ never raises on `ok: false`.** Refusal envelopes degrade
  to "empty BFS frontier" — the operator sees an Explorer that
  shows the focal node alone, not an error page. The Explorer
  controller may surface the `because:` in a developer tools
  panel; this is not a contract on vv-graph.
- The `:reason:` symbol vocabulary VVZ consumes:
  `:sparql_parse_error`, `:sparql_eval_error`, `:invalid_graph`,
  `:extension_not_loaded`, `:ar_connection_error`,
  `:unexpected_error`. Additions are safe; removals are breaking.

### `Vv::Graph::Sparql.ask(query, graph:)`

VVZ uses for SHACL studio's "is this graph empty?" pre-flight in
PLAN_0_1_0 phase F.1. Envelope: `{ ok: true, value: true|false }`.

### `Vv::Graph::Sparql.construct(query, graph:)`

VVZ uses for snapshot export in PLAN_0_1_6 phase A — the Silver
N-Quads dump that lands in the `.vv-snapshot` archive's
`triples/silver.nq`. Envelope: `{ ok: true, ntriples: "..." }`.

### `Vv::Graph::Sparql.execute(update, graph:)`

**VVZ does not call this directly.** Listed for completeness and
to make the layering rule above checkable by grep.

## The extension-loading contract — the load-bearing topic

VVZ's specs run under **Combustion**, which mounts the engine in
a dummy Rails app under `spec/internal`. This breaks vv-graph's
`Loader.extension_path` resolver, which assumes
`Rails.root.parent` is the substrate root. Under Combustion,
`Rails.root` is `vendor/vv-visualize/spec/internal` and the
resolver looks for the binary at `vendor/vv-visualize/spec/vendor/sqlite-sparql/...`
— which doesn't exist.

VVZ's workaround (PLAN_0_1_9 Phase A) is to compute the binary
path in `spec/support/extension_path.rb` and set
`VV_GRAPH_SQLITE_SPARQL_PATH` before requiring the gem. This
keeps VVZ green on a fresh clone but is **not** the right
long-term layering — VVZ should not need to know how vv-graph
finds its binary. The right fix is upstream and is filed as
boundary item B1 below.

What VVZ depends on **today** from the loader contract:

- `Vv::Graph::Loader.extension_path` returns a string path or
  `nil`. Pinned shape — VVZ's resolver overrides what `path` is
  but doesn't introspect what the loader does with it.
- The `VV_GRAPH_SQLITE_SPARQL_PATH` env var takes precedence over
  the default search paths. Pinned by VVZ's workaround.
- `MM_SEMANTICA_SOFT_FAIL=1` converts boot-time raises into
  warnings. VVZ sets this only when the resolver came back
  empty — i.e., when the extension genuinely isn't built. Pinned
  by VVZ's spec-helper logic.

What VVZ does NOT depend on:

- The exact format of the `ExtensionMissing` message body. VVZ's
  `ExtensionPath.skip_reason` ships its own verbatim build-hint
  text; it does not import vv-graph's.

## Predicate-shaped capability advertisements

VVZ uses fewer than VV does. The ones it relies on:

- **`Vv::Graph.facade_version → String`** — VVZ's
  saved-query and snapshot surfaces include this in their
  output payloads as a producer-fingerprint. Pinned shape.
- **`Vv::Graph.sparql_method_available?(name)`** — predicate-shaped
  advertisement over the SPARQL facade methods (shipped vv-graph
  v0.19.0 per B2 below). VVZ does not branch on this today
  (`select` has been pinned since PLAN_0.1.0 phase C); the
  introspection seam exists for future use if vv-graph ever
  splits the facade.

VVZ does **not** consume:

- `Vv::Graph.rdf_star_writes_enabled?` (VVZ doesn't write).
- `Vv::Graph.checkpoint_can_round_trip?` (VVZ doesn't checkpoint
  EtherealGraphs).

## Boundary items — open requests back to `vv-graph`

### B1 — `Loader.extension_path` must resolve under Combustion

**Severity: load-bearing for VVZ's spec suite. Status: ✅ shipped
(vv-graph v0.18.0, PLAN_0.18.0).**

**Framing.** `Vv::Graph::Loader#absolute_for(relative)` resolved
the binary's expected location via `Rails.root.parent`. Under
Combustion (a community-standard Rails-engine test harness),
`Rails.root` is a deep subdirectory of the gem under test, and
`parent` is one level short of where `vendor/sqlite-sparql/`
actually lives.

**Resolution (vv-graph v0.18.0).** Replaced the single-level `parent`
walk with a multi-level **walk-up-to-first-match** algorithm:

```ruby
def absolute_for(relative)
  start = if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
    ::Rails.root.to_s
  else
    Dir.pwd
  end
  walk_up_for(relative, start)
end

def walk_up_for(relative, start)
  dir = start
  loop do
    candidate = File.expand_path(relative, dir)
    return candidate if File.exist?(candidate)
    parent = File.expand_path("..", dir)
    return File.expand_path(relative, start) if parent == dir
    dir = parent
  end
end
```

The shape returned when nothing matches stays the same as today —
an absolute path computed from the start dir — so the existing
`ExtensionMissing` message reports a concrete location.

Implementation lives in `lib/vv/graph/loader.rb`'s `absolute_for`
+ `walk_up_for` (the loop factored out for direct unit testing).
The pin on vv-graph moves to `~> 0.18` (or `>= 0.18`) for VVZ.

**VVZ-side follow-up (now actionable).** VVZ's `spec/spec_helper.rb`
can drop the explicit `ExtensionPath.resolve_and_export!` call —
the upstream resolver now does the right thing on its own. The
`:requires_extension` skip-gate stays — that's the right
discipline regardless of who does the resolving.

### B2 — `Vv::Graph.sparql_method_available?` predicate

**Severity: ergonomics. Status: ✅ shipped (vv-graph v0.19.0,
PLAN_0.19.0).**

VVZ's PLAN_0_1_7 fragment surface exposes
`Vv::Visualize::Tools.catalogue` to in-page WebMCP and the future
server-side MCP server. Each tool spec declares what facets of
the SPARQL surface it touches. A predicate-shaped advertisement
on `Vv::Graph` lets VVZ filter the catalogue to "tools whose
backing surfaces vv-graph currently advertises," without VVZ
introspecting `Vv::Graph::Sparql.respond_to?` from consumer code.

**Resolution (vv-graph v0.19.0).**

```ruby
Vv::Graph.sparql_method_available?(:select)    # => true
Vv::Graph.sparql_method_available?(:ask)       # => true
Vv::Graph.sparql_method_available?(:construct) # => true
Vv::Graph.sparql_method_available?(:execute)   # => true
Vv::Graph.sparql_method_available?(:bogus)     # => false
```

Pinned `true` for the four-method facade at v0.19.0. The
predicate lives on `Vv::Graph` directly (not a separate
`Capabilities` namespace — the original CR phrasing was slightly
off, but the *shape* matches the existing sibling predicates
`rdf_star_writes_enabled?`, `checkpoint_can_round_trip?`,
`schema_normalized?`).

The VVZ-side filter, when wired up:

```ruby
tools.catalogue.select do |tool|
  Vv::Graph.sparql_method_available?(tool.backing_sparql_method)
end
```

## Drift signals — what changes break VVZ

Three things in vv-graph, if they move, break VVZ in ways
that need lockstep PRs:

1. **`Vv::Graph::Sparql.select` envelope keys.** A rename from
   `:ok` / `:results` / `:reason` / `:because` to anything else
   silently de-grafts VVZ's BFS — every query starts returning
   "no results" instead of "no neighbours." VVZ's specs would
   stay green (the mock-based unit tests don't notice); the
   `:requires_extension` integration tests would catch this on
   CI but only if they're tagged correctly. Worth a
   `silver_envelope_shape_spec.rb`-style invariant test upstream.
2. **`Vv::Graph::Scope.new` kwargs.** A rename of `data:` to
   anything else cascades through every VVZ controller +
   service. Same lockstep PR posture as MM and VV.
3. **`VV_GRAPH_SQLITE_SPARQL_PATH` env-var name.** VVZ writes this
   from its resolver. If the upstream name changes (e.g., a
   namespace migration tracking the gem rename), VVZ's workaround
   silently stops working — the resolver sets the old var, the
   loader reads the new one. Pin the var name in the upstream
   CHANGELOG when it moves.

## Capability inheritance from VV

VVZ depends on VV (vv-memory), which depends on vv-graph. Any
breaking change vv-graph ships that flows through VV — e.g., the
Storable DSL changes referenced in VV's CC B2 — reaches VVZ
indirectly via VV's `Vv::Memory::Scoped` surface. VVZ does **not**
re-validate those contracts here; if VV stays green against a
vv-graph release, VVZ inherits that confidence.

The single contract VVZ exercises directly that VV does not is
`Vv::Graph::Sparql.select` against arbitrary scope IRIs (VV's
test scopes are AR-record-driven; VVZ's tests construct Scope
values directly). The integration specs from PLAN_0_1_9 phase C
are the inoculation.

## License

This CC is part of `vv-graph`'s repo and follows the gem's MIT
license. VVZ's own license is MIT; cross-repo consumption is
intended.
