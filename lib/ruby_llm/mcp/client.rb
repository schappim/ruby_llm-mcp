# frozen_string_literal: true

module RubyLLM
  module MCP
    class Client
      PROTOCOL_VERSION = "2025-03-26"
      attr_reader :name, :config, :transport_type, :transport, :request_timeout, :reverse_proxy_url

      def initialize(name:, transport_type:, request_timeout: 8000, reverse_proxy_url: nil, config: {})
        @name = name
        @config = config
        @transport_type = transport_type.to_sym

        # TODO: Add streamable HTTP
        case @transport_type
        when :sse
          @transport = RubyLLM::MCP::Transport::SSE.new(@config[:url])
        when :ninja_sse
          @transport = RubyLLM::MCP::Transport::NinjaSSE.new(@config[:url])
        when :stdio
          @transport = RubyLLM::MCP::Transport::Stdio.new(@config[:command], args: @config[:args], env: @config[:env])
        else
          raise "Invalid transport type: #{transport_type}"
        end

        @request_timeout = request_timeout
        @reverse_proxy_url = reverse_proxy_url

        initialize_request
        notification_request
      end

      def request(body, wait_for_response: true)
        @transport.request(body, wait_for_response: wait_for_response)
      end

      def tools(refresh: false)
        @tools = nil if refresh
        @tools ||= fetch_and_create_tools
      end

      def execute_tool(name:, parameters:)
        response = execute_tool_request(name: name, parameters: parameters)
        result = response["result"]
        # TODO: handle tool error when "isError" is true in result
        #
        # TODO: Implement "type": "image" and "type": "resource"
        result["content"].map { |content| content["text"] }.join("\n")
      end

      private

      def initialize_request
        @initialize_response = RubyLLM::MCP::Requests::Initialization.new(self).call
      end

      def notification_request
        @notification_response = RubyLLM::MCP::Requests::Notification.new(self).call
      end

      def tool_list_request
        @tool_request = RubyLLM::MCP::Requests::ToolList.new(self).call
        @tool_request
      end

      def execute_tool_request(name:, parameters:)
        @execute_tool_response = RubyLLM::MCP::Requests::ToolCall.new(self, name: name, parameters: parameters).call
      end

      def fetch_and_create_tools
        tools_response = tool_list_request
        tools_response = tools_response["result"]["tools"]

        @tools = tools_response.map do |tool|
          RubyLLM::MCP::Tool.new(self, tool)
        end
      end
    end
  end
end
