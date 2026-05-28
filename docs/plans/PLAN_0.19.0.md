# PLAN_0.19.0 — vv-graph: Capabilities predicate for SPARQL facade methods (CR-VVZ B2)

**Status.** Shipped (vv-graph v0.19.0; see `CHANGELOG.md` § 0.19.0).
**Target gem version.** `vv-graph` v0.19.0.
**Driving CR.** `CONSUMER_REQUIREMENT_VVZ.md` § B2.
**Sibling shipped.** `PLAN_0.18.0.md` (CR-VVZ B1, walk-up resolver).

## Intent

VVZ exposes a tool catalogue (`Vv::Visualize::Tools.catalogue`, see
VVZ's PLAN_0_1_7) to in-page WebMCP and a future server-side MCP
server. Each catalogue entry declares which SPARQL facade methods
it touches — today VVZ uses `select` exclusively, but the
catalogue model is forward-looking and will declare `ask`,
`construct`, etc. when VVZ adds tools that use them.

VVZ wants to filter the catalogue at runtime down to "tools whose
backing surfaces vv-graph currently advertises," **without
introspecting `Vv::Graph::Sparql.respond_to?(:select)` from
consumer code.** Reaching into the facade's method table couples
VVZ to the facade's internal layout; a Capabilities-side predicate
keeps the consumer on the public Capabilities surface, where the
other forward-compat predicates already live
(`rdf_star_writes_enabled?`, `checkpoint_can_round_trip?`,
`schema_normalized?`).

This is pure ergonomics. The CR explicitly tags it
"not pressing": VVZ's catalogue today hard-codes the
known-available set. The predicate exists to let the catalogue
filter cleanly once the facade ever splits — e.g., if a future
build of vv-graph ships read-only without `execute`, or if the
substrate gains an opt-in `construct` flag.

## Scope

In:
- Add `Vv::Graph.sparql_method_available?(name)` to
  `lib/vv/graph/capabilities.rb`. Module function on `Vv::Graph`
  (matching the existing predicate siblings — the CR's
  `Vv::Graph::Capabilities` namespace doesn't actually exist; the
  predicates live directly on the top-level module). Accepts a
  Symbol or String, returns boolean.
- Implementation: `::Vv::Graph::Sparql.respond_to?(name.to_sym)`,
  with the call kept inside the predicate so the consumer doesn't
  reach into the facade itself.
- Spec coverage in `spec/vv/graph/capabilities_spec.rb`: each of
  `:select`, `:ask`, `:construct`, `:execute` returns `true` on
  the current facade; `:bogus_unknown` returns `false`.
- CHANGELOG bullet under `## 0.19.0`. No VERSION bump until the
  release cuts.
- README capability-table extension if/when one exists.

Out (non-goals):
- A more general `Capabilities.facade_methods` enumerator. The
  predicate shape is what the CR asked for; a list shape adds
  surface without an asked use case.
- Splitting `Vv::Graph::Sparql` into read / write facades. Out of
  scope; tracked separately if/when a consumer needs it.
- Touching the SPARQL facade itself. The predicate is read-only
  reflection — no method renames, no signature changes.

## Naming choice

The CR uses the phrasing `Capabilities.respond_to?(:select)` to
sketch the intent, which would mean defining a `select` method on
the Capabilities module — an odd shape. The predicate-style
name aligns with the existing sibling predicates:

- `rdf_star_writes_enabled?`
- `checkpoint_can_round_trip?(content_kind:)`
- `schema_normalized?`
- **new:** `sparql_method_available?(name)`

`sparql_method_available?` is preferred over a one-off
`select_available?` because:

1. VVZ's tool catalogue will eventually declare `ask` /
   `construct` / `execute` touches. A parameterized predicate
   handles all four (plus future additions) without four
   one-off predicates.
2. Symmetric with how `checkpoint_can_round_trip?` takes a
   `content_kind:` parameter — predicates that span a finite
   enum should parameterise rather than fan out.

## Surface (additive, behind no flag)

```ruby
module Vv::Graph
  module_function

  # Pinned true for the four-method facade as of v0.19.0.
  # The predicate exists so consumers can branch on a future
  # facade split without introspecting Sparql.respond_to?.
  def sparql_method_available?(name)
    ::Vv::Graph::Sparql.respond_to?(name.to_sym)
  end
end
```

Returned value: `true` / `false`. No envelope. Errors on a non-
String/Symbol input propagate the standard `NoMethodError` from
`to_sym` — input validation is the caller's responsibility, same
as every other Capabilities predicate.

## Acceptance

- `bundle exec rspec spec/vv/graph/capabilities_spec.rb` — green
  with the new examples added.
- `bundle exec rspec` — green (full suite still 495+ examples).
- VVZ-side: `Vv::Visualize::Tools.catalogue` can filter on
  `Vv::Graph.sparql_method_available?(tool.backing_method)`
  without touching `Vv::Graph::Sparql.respond_to?` directly.
- VVZ CR B2 status flips from "nice-to-have" to shipped.

## Compatibility

- Pure additive surface. No existing caller breaks.
- Consumers can keep using `Vv::Graph::Sparql.respond_to?(:select)`
  directly if they want; the new predicate exists for layering
  discipline, not because the introspection itself is
  load-bearing.

## Release cut considerations

- This is small enough to ride along with the next non-trivial
  vv-graph release rather than cut a v0.19.0 on its own.
- If a 0.19.0 cut becomes warranted by other work, fold this in
  as one of its phases ("Phase A — `sparql_method_available?`
  predicate"). Otherwise, leave deferred and re-evaluate when
  VVZ's catalogue actually needs runtime filtering.

## Reference

- Driving CR: `CONSUMER_REQUIREMENT_VVZ.md` § B2.
- Related shipped surface: existing predicates in
  `lib/vv/graph/capabilities.rb` (`rdf_star_writes_enabled?` etc.).
- VVZ-side consumer: `Vv::Visualize::Tools.catalogue`
  (VVZ PLAN_0_1_7).
