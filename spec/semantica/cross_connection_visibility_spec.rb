# frozen_string_literal: true

require "spec_helper"

# PLAN_0.6.0 Phase B — pin the shared-store cross-connection
# visibility contract. Engine ≥ 0.2.0 ships an OnceLock-backed
# process-wide Oxigraph store; writes from one AR connection are
# visible from any other connection in the same process.
#
# A regression in the engine that reverted to thread-local storage
# would break the gem's contract; this spec catches it first.
RSpec.describe "shared-store cross-connection visibility", :requires_extension do
  before { Semantica::Sparql.execute("CLEAR ALL") }

  it "a write on one connection is visible from a second connection on the same thread" do
    pool = ::ActiveRecord::Base.connection_pool

    pool.with_connection do |_first|
      Semantica::Sparql.execute(
        %(INSERT DATA { <urn:mm:xconn:1> <schema:name> "First" . }),
      )
    end

    pool.with_connection do |_second|
      Semantica::Loader.ensure_extension_loaded!
      result = Semantica::Sparql.ask(
        %(ASK { <urn:mm:xconn:1> <schema:name> "First" }),
      )
      expect(result).to eq(ok: true, value: true)
    end
  end

  it "a write on the main thread is visible from a second Ruby thread" do
    Semantica::Sparql.execute(
      %(INSERT DATA { <urn:mm:xthread:1> <schema:name> "MainWrote" . }),
    )

    other_thread_value = nil
    t = Thread.new do
      ::ActiveRecord::Base.connection_pool.with_connection do
        Semantica::Loader.ensure_extension_loaded!
        result = Semantica::Sparql.ask(
          %(ASK { <urn:mm:xthread:1> <schema:name> "MainWrote" }),
        )
        other_thread_value = result[:value]
      end
    end
    t.join

    expect(other_thread_value).to be(true)
  end

  it "a write to a named graph from connection A is visible via graph: from connection B" do
    pool = ::ActiveRecord::Base.connection_pool

    pool.with_connection do |_first|
      Semantica::Sparql.execute(
        %(INSERT DATA { <urn:mm:xg:1> <schema:name> "InGraph" . }),
        graph: "urn:mm:graph:xtest",
      )
    end

    pool.with_connection do |_second|
      Semantica::Loader.ensure_extension_loaded!
      result = Semantica::Sparql.ask(
        %(ASK { <urn:mm:xg:1> <schema:name> "InGraph" }),
        graph: "urn:mm:graph:xtest",
      )
      expect(result).to eq(ok: true, value: true)

      default = Semantica::Sparql.ask(
        %(ASK { <urn:mm:xg:1> <schema:name> "InGraph" }),
      )
      expect(default).to eq(ok: true, value: false), "named-graph write must not leak into default graph"
    end
  end
end
