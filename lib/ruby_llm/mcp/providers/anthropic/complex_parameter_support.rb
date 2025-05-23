# frozen_string_literal: true

module RubyLLM
  module MCP
    module Providers
      module Anthropic
        module ComplexParameterSupport
          def clean_parameters(parameters)
            parameters.transform_values do |param|
              format = {
                type: param.type,
                description: param.description
              }.compact

              if param.type == "array"
                format[:items] = param.items
              elsif param.type == "object"
                format[:properties] = clean_parameters(param.properties)
              end

              format
            end
          end
        end
      end
    end
  end
end

RubyLLM::Providers::Anthropic.extend(RubyLLM::MCP::Providers::Anthropic::ComplexParameterSupport)
