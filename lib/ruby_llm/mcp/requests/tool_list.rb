# frozen_string_literal: true

class RubyLLM::MCP::Requests::ToolList < RubyLLM::MCP::Requests::Base
  def call
    client.request(tool_list_body)
  end

  private

  def tool_list_body
    {
      jsonrpc: "2.0",
      method: "tools/list",
      params: {}
    }
  end
end
