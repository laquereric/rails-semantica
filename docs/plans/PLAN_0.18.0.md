# PLAN_0.18.0 — vv-graph: Loader walk-up resolver (CR-VVZ B1)

**Status.** Shipped (see `CHANGELOG.md` § 0.18.0).
**Target gem version.** `vv-graph` v0.18.0.
**Date.** 2026-05-27.
**Driving CR.** `CONSUMER_REQUIREMENT_VVZ.md` § B1.
**Sibling work — deferred.** `PLAN_0.19.0.md` (CR-VVZ B2:
`Capabilities.select_available?` predicate).

## Intent

`vv-visualize` (VVZ) runs its specs under Combustion, which mounts
the engine in a dummy Rails app at `vendor/vv-visualize/spec/internal`.
The pre-0.18.0 `Vv::Graph::Loader.absolute_for` resolved the
extension binary's expected location via a single-level
`Rails.root.parent` walk. Under Combustion that lands at
`vendor/vv-visualize/spec/`, one directory short of where the
substrate keeps `vendor/sqlite-sparql/target/release/libsqlite_sparql.*`.

VVZ worked around the gap by computing the path in
`spec/support/extension_path.rb` and exporting
`VV_GRAPH_SQLITE_SPARQL_PATH` before requiring the gem. That keeps
specs green on a fresh clone but is the wrong layering — VVZ should
not need to know how vv-graph finds its binary. v0.18.0 lifts the
fix upstream so consumer repos can drop their workarounds.

This is a one-method behaviour change. No new surfaces, no new env
vars, no API rename.

## Scope

In:
- Replace the `Rails.root.parent` shim in
  `Vv::Graph::Loader.absolute_for`
  (`lib/vv/graph/loader.rb`) with a walk-up-to-first-match.
- Factor the walk into a directly-testable
  `Vv::Graph::Loader.walk_up_for(relative, start)` helper.
- Spec coverage for: nested-fixture resolution, start-dir match,
  and the no-match fallback (still returns a start-dir-relative
  absolute path so `ExtensionMissing` keeps a concrete location).

Out (deferred / non-goals):
- `Vv::Graph::Capabilities.select_available?` predicate — see
  `PLAN_0.19.0.md`.
- Any change to `VV_GRAPH_SQLITE_SPARQL_PATH` semantics. Env-var
  precedence over the default search paths is preserved.
- Any change to `ExtensionMissing` message body. The build-hint
  text, the cargo command, and the env-var override hint stay
  byte-for-byte identical.

## Surface change

### `Vv::Graph::Loader.absolute_for(relative)` — behaviour change

Before (0.17.0):

```ruby
def absolute_for(relative)
  base = if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
    ::Rails.root.parent.to_s
  else
    Dir.pwd
  end
  File.expand_path(relative, base)
end
```

After (0.18.0):

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

The signature is unchanged. The return type is unchanged (absolute
path string). The behaviour difference: when the candidate isn't
at the original parent level, walk upward and return the first hit.

## Compatibility notes

- **Caller-visible.** `Loader.searched_paths` and `Loader.extension_path`
  consume `absolute_for`; their shapes don't change but the strings
  they return may now point to higher ancestors. Operators who
  hard-pinned a particular absolute path via `VV_GRAPH_SQLITE_SPARQL_PATH`
  are unaffected (env-var precedence preserved).
- **Failure path.** When the binary truly isn't built anywhere on
  the walk-up path, `extension_path` returns `nil` and
  `ensure_extension_loaded!` raises `ExtensionMissing` with the
  same message body as 0.17.0.
- **Spec hygiene.** Loader specs that previously assumed "nothing
  on disk" via the cwd-relative single-level walk had an implicit
  dependency on the binary *not* being at `pwd/vendor/sqlite-sparql/`.
  Under the walk-up that assumption becomes "not anywhere upward
  from pwd," which fails on substrate clones that have a built
  binary one or two levels up. The 0.18.0 spec wraps the
  `ensure_extension_loaded!` "raises" example in `Dir.chdir(tmpdir)`
  so the walk-up has nowhere real to land.

## Acceptance

- `bundle exec rspec spec/vv/graph/loader_spec.rb` — green
  (16 examples, including 3 new `.walk_up_for` cases).
- `bundle exec rspec` — green (495 examples, 0 failures).
- VVZ-side: after pinning to `vv-graph >= 0.18`, the
  `spec/support/extension_path.rb` resolve-and-export workaround can
  be dropped. The `:requires_extension` skip-gate stays — that's the
  right discipline regardless of who does the resolving.

## Consumer follow-ups

- **VVZ.** Move `vv-visualize.gemspec`'s pin to `~> 0.18` (or
  `>= 0.18`). Retire `spec/support/extension_path.rb`'s
  resolve-and-export call from `spec/spec_helper.rb`. Update
  `CONSUMER_REQUIREMENT_VVZ.md` B1 status to shipped.
- **MM / VV / GM.** No changes required. These consumers already
  load through the substrate's normal `Rails.root.parent` shape
  and continue to resolve via the pre-fix path at the first level
  of the walk-up.

## Reference

- Driving CR: `CONSUMER_REQUIREMENT_VVZ.md` § B1.
- VVZ plan referencing this fix: VVZ's `docs/plans/PLAN_0_1_9.md`
  Phase D.
- Touched files: `lib/vv/graph/loader.rb`,
  `spec/vv/graph/loader_spec.rb`, `CHANGELOG.md`, `VERSION`.
