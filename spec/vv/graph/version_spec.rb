# frozen_string_literal: true

require "spec_helper"

RSpec.describe Vv::Graph do
  it "ships a VERSION constant" do
    expect(Vv::Graph::VERSION).to be_a(String).and(be_present)
  end

  it "is at v0.x.x (substrate-mutual evolution; v1.0 is the publication milestone)" do
    expect(Vv::Graph::VERSION).to start_with("0.")
  end
end
