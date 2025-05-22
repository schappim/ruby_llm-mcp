# frozen_string_literal: true

module RubyLLM
  module MCP
    class Tool < RubyLLM::Tool
      attr_reader :name, :description, :parameters, :mcp_client, :tool_response

      # @tool_response = {
      #   name: string;          // Unique identifier for the tool
      #   description?: string;  // Human-readable description
      #   inputSchema: {         // JSON Schema for the tool's parameters
      #     type: "object",
      #     properties: { ... }  // Tool-specific parameters
      #   },
      #   annotations?: {        // Optional hints about tool behavior
      #     title?: string;      // Human-readable title for the tool
      #     readOnlyHint?: boolean;    // If true, the tool does not modify its environment
      #     destructiveHint?: boolean; // If true, the tool may perform destructive updates
      #     idempotentHint?: boolean;  // If true, repeated calls with same args have no additional effect
      #     openWorldHint?: boolean;   // If true, tool interacts with external entities
      #   }
      # }
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
          param = RubyLLM::Parameter.new(
            key,
            type: input_schema["properties"][key]["type"],
            desc: input_schema["properties"][key]["description"],
            required: input_schema["properties"][key]["required"]
          )

          params[key] = param
        end

        params
      end
    end
  end
end
