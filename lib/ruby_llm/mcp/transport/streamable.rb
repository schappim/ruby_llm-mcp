# frozen_string_literal: true

module RubyLLM
  module MCP
    module Transport
      class Streamable
        def initialize(url, headers: {})
          @url = url
          @headers = headers
        end

        def request(messages)
          # TODO: Implement streaming
        end

        def close
          # TODO: Implement closing
        end
      end
    end
  end
end
