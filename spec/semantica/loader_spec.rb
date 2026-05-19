# frozen_string_literal: true

require "spec_helper"

# PLAN 0.29.1 Phase A — stub spec. Phase B fills in the real
# behaviour (idempotent extension load; missing-extension structured
# refusal).
RSpec.describe Semantica::Loader do
  it "exposes ExtensionMissing as the documented refusal class" do
    expect(Semantica::Loader::ExtensionMissing).to be < StandardError
  end

  it "ensure_extension_loaded! is declared (Phase B ships behavior)" do
    expect(Semantica::Loader).to respond_to(:ensure_extension_loaded!)
  end
end
