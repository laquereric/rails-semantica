# frozen_string_literal: true

require "spec_helper"

# PLAN 0.29.1 Phase A — stub spec. Phase C fills in select / ask /
# construct against a fixture triple set.
RSpec.describe Semantica::Sparql do
  it "exposes the three documented class methods" do
    expect(Semantica::Sparql).to respond_to(:select, :ask, :construct)
  end
end
