# frozen_string_literal: true

module RubyLLM
  module ToolsComplexParametersSupport
    def param_schema(param)
      format = {
        type: param.type,
        description: param.description
      }.compact

      if param.type == "array"
        format[:items] = param.items
      elsif param.type == "object"
        format[:properties] = param.properties
      end
      format
    end
  end
end

RubyLLM::Providers::OpenAI.extend(RubyLLM::ToolsComplexParametersSupport)
