# frozen_string_literal: true

require "spec_helper"

# PLAN 0.29.1 Phase A — stub spec. Phase D fills in the per-model
# `triples do ... end` DSL + after_save / after_destroy lifecycle.
RSpec.describe Semantica::Storable do
  it "is a module operators include" do
    expect(Semantica::Storable).to be_a(Module)
  end
end
