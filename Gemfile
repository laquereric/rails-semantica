# frozen_string_literal: true

source "https://rubygems.org"

# ── Parallel-developed prerequisite ────────────────────────────
#
# `../sqlite-sparql/` is the Rust SQLite loadable extension this gem
# wraps. It is **not a Ruby gem** — it compiles to a native
# `.dylib`/`.so`/`.dll` that `Vv::Graph::Loader` loads at boot via
# `raw_connection.load_extension`. There is no Gemfile dependency
# line for it (Bundler can't manage a Rust crate); instead the gem's
# runtime probes for the artifact under
# `../sqlite-sparql/target/release/` and `Vv::Graph::Loader::ExtensionMissing`
# tells operators exactly how to build it.
#
# Build before running specs:
#
#   cd ../sqlite-sparql && cargo build --release
#
# The engine repo (laquereric/sqlite-sparql) owns its own surface
# documentation. Surface changes there land in that repo; coordinated
# bumps land here.
# ────────────────────────────────────────────────────────────────

# Specify dependencies in vv-graph.gemspec.
gemspec
