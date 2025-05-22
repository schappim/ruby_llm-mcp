# frozen_string_literal: true

require "ruby_llm"
require "zeitwerk"

loader = Zeitwerk::Loader.for_gem_extension(RubyLLM)
loader.inflector.inflect("mcp" => "MCP")
loader.inflector.inflect("sse" => "SSE")
loader.setup

module RubyLLM
  module MCP
    def self.client(*args, **kwargs)
      @client ||= Client.new(*args, **kwargs)
    end
  end
end
