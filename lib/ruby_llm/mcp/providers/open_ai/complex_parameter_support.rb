# frozen_string_literal: true

module RubyLLM
  module MCP
    module Providers
      module OpenAI
        module ComplexParameterSupport
          def param_schema(param)
            format = {
              type: param.type,
              description: param.description
            }.compact

            if param.type == "array"
              format[:items] = param.items
            elsif param.type == "object"
              format[:properties] = param.properties.transform_values { |value| param_schema(value) }
            end
            format
          end
        end
      end
    end
  end
end

RubyLLM::Providers::OpenAI.extend(RubyLLM::MCP::Providers::OpenAI::ComplexParameterSupport)
