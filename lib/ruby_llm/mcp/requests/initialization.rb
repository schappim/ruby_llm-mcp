# frozen_string_literal: true

class RubyLLM::MCP::Requests::Initialization < RubyLLM::MCP::Requests::Base
  def call
    client.request(initialize_body)
  end

  private

  def initialize_body
    {
      jsonrpc: "2.0",
      method: "initialize",
      params: {
        protocolVersion: RubyLLM::MCP::Client::PROTOCOL_VERSION,
        capabilities: {
          tools: {
            listChanged: true
          }
        },
        clientInfo: {
          name: "RubyLLM MCP Client",
          version: RubyLLM::MCP::VERSION
        }
      }
    }
  end
end
