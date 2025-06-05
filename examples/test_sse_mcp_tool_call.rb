# frozen_string_literal: true

require "bundler/setup"
require "ruby_llm/mcp"
require "debug"
require "dotenv"

Dotenv.load

RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
end

puts "client"
client = RubyLLM::MCP.client(
  name: "local_mcp",
  transport_type: "sse",
  config: {
    url: ENV.fetch("NINJA_GATEWAY", nil)
  }
)
puts "after client"

puts "before tools"
tools = client.tools
puts "Tools:\n"
puts tools.map { |tool| "  #{tool.name}: #{tool.description}" }.join("\n")
puts "\nTotal tools: #{tools.size}"
puts "-" * 50

chat = RubyLLM.chat(model: "gpt-4.1")
chat.with_tools(*client.tools)

message = "Please send an email to marcus@schappi.com with the subject 'You are awesome!' and tell him that he is awesome in the message body."
puts "Asking: #{message}"
puts "-" * 50

chat.ask(message) do |chunk|
  if chunk.tool_call?
    chunk.tool_calls.each do |key, tool_call|
      next if tool_call.name.nil?

      puts "\n🔧 Tool call(#{key}) - name: #{tool_call.name}\n"
    end
  else
    print chunk.content
  end
end
puts "\n"
