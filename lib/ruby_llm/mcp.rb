# frozen_string_literal: true

require "ruby_llm"
require "zeitwerk"

loader = Zeitwerk::Loader.for_gem_extension(RubyLLM)
loader.inflector.inflect("mcp" => "MCP")
loader.inflector.inflect("sse" => "SSE")
loader.setup

module RubyLLM
  module MCP
    module_function

    def client(*args, **kwargs)
      @client ||= Client.new(*args, **kwargs)
    end

    def support_complex_parameters!
      require_relative "providers/open_ai/complex_parameter_support"
      require_relative "providers/anthropic/complex_parameter_support"
    end
  end
end
