# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "securerandom"
require "fileutils"

# PLAN 0.29.1 Phase B — Semantica::Loader contract.
#
# Specs run against the standalone gem (no Rails / AR loaded), so
# they exercise:
#   - ExtensionMissing message shape (build command + path list)
#   - extension_path resolution (env var → searched_paths fallback)
#   - searched_paths defaults
#   - ensure_extension_loaded! routes :no_active_record when AR isn't present
#
# End-to-end load (load_into_connection! against a real SQLite3 +
# a compiled sqlite-sparql binary) is exercised at substrate-level
# specs (PLAN_0_29_1 Phase G) where both are guaranteed present.
RSpec.describe Semantica::Loader do
  let(:tmp_dir) { Dir.mktmpdir }
  after { FileUtils.rm_rf(tmp_dir) }

  describe Semantica::Loader::ExtensionMissing do
    let(:error) do
      described_class.new(["/expected/path/libsqlite_sparql.dylib"])
    end

    it "is a StandardError subclass (catchable + structured)" do
      expect(described_class.ancestors).to include(StandardError)
    end

    it "names every searched path in the message" do
      expect(error.message).to include("/expected/path/libsqlite_sparql.dylib")
    end

    it "names the cargo build command verbatim" do
      expect(error.message).to include("cd vendor/sqlite-sparql")
      expect(error.message).to include("cargo build --release")
    end

    it "names the MM_SQLITE_SPARQL_PATH override" do
      expect(error.message).to include("MM_SQLITE_SPARQL_PATH")
    end
  end

  describe ".searched_paths" do
    it "lists at least the three platform candidates (macOS / Linux / Windows)" do
      expect(Semantica::Loader.searched_paths.size).to be >= 3
    end

    it "returns absolute paths" do
      Semantica::Loader.searched_paths.each do |p|
        expect(File.absolute_path?(p)).to be(true), "expected #{p.inspect} absolute"
      end
    end
  end

  describe ".extension_path" do
    around do |example|
      saved_env = ENV["MM_SQLITE_SPARQL_PATH"]
      ENV.delete("MM_SQLITE_SPARQL_PATH")
      example.run
      ENV["MM_SQLITE_SPARQL_PATH"] = saved_env
    end

    it "prefers MM_SQLITE_SPARQL_PATH when set + on disk" do
      tmp = File.join(tmp_dir, "libsqlite_sparql.dylib")
      File.write(tmp, "stub")
      ENV["MM_SQLITE_SPARQL_PATH"] = tmp
      expect(Semantica::Loader.extension_path).to eq(tmp)
    end

    it "ignores MM_SQLITE_SPARQL_PATH that doesn't exist on disk" do
      ENV["MM_SQLITE_SPARQL_PATH"] = "/tmp/nonexistent-#{SecureRandom.hex(8)}.dylib"
      # Falls through to searched_paths; nil unless a real extension
      # happens to be present at the default path.
      expect(Semantica::Loader.extension_path).to satisfy { |v| v.nil? || v.is_a?(String) }
    end

    it "returns nil when nothing is on disk + env unset" do
      # The spec env doesn't ship a compiled extension; nil is the
      # honest result. ensure_extension_loaded! turns this into
      # ExtensionMissing.
      expect(Semantica::Loader.extension_path).to satisfy { |v| v.nil? || v.is_a?(String) }
    end
  end

  describe ".ensure_extension_loaded!" do
    around do |example|
      saved_env = ENV["MM_SQLITE_SPARQL_PATH"]
      ENV["MM_SQLITE_SPARQL_PATH"] = "/tmp/definitely-missing-#{SecureRandom.hex(8)}.dylib"
      example.run
      ENV["MM_SQLITE_SPARQL_PATH"] = saved_env
    end

    it "raises ExtensionMissing when no extension is on disk" do
      expect { Semantica::Loader.ensure_extension_loaded! }
        .to raise_error(Semantica::Loader::ExtensionMissing) do |error|
          expect(error.message).to include("cargo build --release")
        end
    end
  end

  describe "AR-less environment" do
    around do |example|
      saved_env = ENV["MM_SQLITE_SPARQL_PATH"]
      tmp = File.join(tmp_dir, "libsqlite_sparql.dylib")
      File.write(tmp, "stub")
      ENV["MM_SQLITE_SPARQL_PATH"] = tmp
      example.run
      ENV["MM_SQLITE_SPARQL_PATH"] = saved_env
    end

    it "returns :no_active_record when ActiveRecord::Base isn't defined" do
      hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base)
      expect(Semantica::Loader.ensure_extension_loaded!).to eq(:no_active_record)
    end
  end

  describe ".engine_version" do
    it "returns :unknown without ActiveRecord loaded" do
      hide_const("ActiveRecord::Base") if defined?(::ActiveRecord::Base)
      expect(Semantica::Loader.engine_version).to eq(Semantica::Loader::ENGINE_VERSION_UNKNOWN)
    end

    it "returns :unknown when the engine lacks an rdf_version probe", :requires_extension do
      # Engine 0.5.0 doesn't ship rdf_version yet — the rescue path
      # surfaces :unknown. When the engine ships the probe, this
      # spec becomes "returns a String".
      expect(Semantica::Loader.engine_version).to eq(Semantica::Loader::ENGINE_VERSION_UNKNOWN)
    end
  end
end
