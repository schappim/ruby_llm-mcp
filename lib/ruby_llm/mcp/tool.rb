# frozen_string_literal: true

module RubyLLM
  module MCP
    class Tool < RubyLLM::Tool
      attr_reader :name, :description, :parameters, :mcp_client, :tool_response

      def initialize(mcp_client, tool_response)
        super()
        @mcp_client = mcp_client

        @name = tool_response["name"]
        @description = tool_response["description"]
        @parameters = create_parameters(tool_response["inputSchema"])
      end

      def execute(**params)
        @mcp_client.execute_tool(
          name: @name,
          parameters: params
        )
      end

      private

      def create_parameters(input_schema)
        params = {}
        input_schema["properties"].each_key do |key|
          param = RubyLLM::MCP::Parameter.new(
            key,
            type: input_schema["properties"][key]["type"],
            desc: input_schema["properties"][key]["description"],
            required: input_schema["properties"][key]["required"]
          )

          if param.type == "array"
            param.items = input_schema["properties"][key]["items"]
          elsif param.type == "object"
            properties = create_parameters(input_schema["properties"][key]["properties"])
            param.properties = properties
          end

          params[key] = param
        end

        params
      end
    end
  end
end
