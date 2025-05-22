# frozen_string_literal: true

module RubyLLM
  module MCP
    module Errors
      class TimeoutError < StandardError
        attr_reader :message

        def initialize(message:)
          @message = message
          super(message)
        end
      end
    end
  end
end
