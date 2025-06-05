# frozen_string_literal: true

RSpec.describe RubyLLM::MCP do
  it "has a version number" do
    expect(RubyLLM::MCP::VERSION).not_to be_nil
  end

  describe "#client" do
    it "calls RubyLLM::MCP::Client" do
      client = instance_double(RubyLLM::MCP::Client)
      allow(RubyLLM::MCP::Client).to receive(:new).and_return client

      RubyLLM::MCP.client(name: "test", transport_type: "stdio")

      expect(RubyLLM::MCP::Client).to have_received(:new).with(name: "test", transport_type: "stdio")
    end
  end
end
