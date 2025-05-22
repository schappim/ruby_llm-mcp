# frozen_string_literal: true

module RubyLLM
  module MCP
    module Requests
      class ToolCall
        def initialize(client, name:, parameters: {})
          @client = client
          @name = name
          @parameters = parameters
        end

        def call
          @client.request(request_body)
        end

        private

        def request_body
          {
            jsonrpc: "2.0",
            method: "tools/call",
            params: {
              name: @name,
              arguments: @parameters
            }
          }
        end
      end
    end
  end
end
