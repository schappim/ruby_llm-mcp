# frozen_string_literal: true

class RubyLLM::MCP::Requests::Initialization < RubyLLM::MCP::Requests::Base
  def call
    puts "🌟 init"
    client.request(initialize_body)
    puts "🌟 init"
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
