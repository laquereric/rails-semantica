# frozen_string_literal: true

source "https://rubygems.org"

# ── Parallel-developed prerequisite ────────────────────────────
#
# `../sqlite-sparql/` is the Rust SQLite loadable extension this gem
# wraps. It is **not a Ruby gem** — it compiles to a native
# `.dylib`/`.so`/`.dll` that `Semantica::Loader` loads at boot via
# `raw_connection.load_extension`. There is no Gemfile dependency
# line for it (Bundler can't manage a Rust crate); instead the gem's
# runtime probes for the artifact under
# `../sqlite-sparql/target/release/` and `Semantica::Loader::ExtensionMissing`
# tells operators exactly how to build it.
#
# Build before running specs:
#
#   cd ../sqlite-sparql && cargo build --release
#
# Consumer-side requirements that sqlite-sparql commits to honour
# are documented in `../sqlite-sparql/CONSUMER_REQUIREMENT_RAILS_SEMANTICA.md`.
# Renames / removals listed there require a coordinated bump in
# this gem.
# ────────────────────────────────────────────────────────────────

# Specify dependencies in rails-semantica.gemspec.
gemspec
