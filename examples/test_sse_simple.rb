#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "ruby_llm/mcp"

client = RubyLLM::MCP.client(
  name: "local_mcp",
  transport_type: "sse",
  config: {
    url: "https://mcp.ninja.ai/connect/4SEwn_CrxnD3cPQb4w38nhXxSnJpDQux0g_yMczU2Ccur60OuUC3Ibmr"
  }
)

puts "🎉 SSE transport connected successfully!"
puts "Session ID: #{client.transport.session_id}"
puts "Messages URL: #{client.transport.messages_url}"
puts "=" * 50

tools = client.tools
puts "Found #{tools.length} tools:"
puts "=" * 50

tools.each_with_index do |tool, index|
  puts "#{index + 1}. #{tool.name}"
  puts "   Description: #{tool.description}"
  puts "   Parameters: #{tool.parameters.keys.join(', ')}"
  puts
end

puts "✅ Test completed successfully!"
client.transport.close