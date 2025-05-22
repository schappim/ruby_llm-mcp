# RubyLLM::MCP

Aiming to make using MCP with RubyLLM as easy as possible.

This project is a Ruby client for the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/), designed to work seamlessly with [RubyLLM](https://github.com/patvice/ruby_llm). This gem enables Ruby applications to connect to MCP servers and use their tools as part of LLM conversations.

**Note:** This project is still under development and the API is subject to change. Currently supports the connecting workflow, tool lists and tool execution.

## Features

- 🔌 **Multiple Transport Types**: Support for SSE (Server-Sent Events) and stdio transports
- 🛠️ **Tool Integration**: Automatically converts MCP tools into RubyLLM-compatible tools
- 🔄 **Real-time Communication**: Efficient bidirectional communication with MCP servers
- 🎯 **Simple API**: Easy-to-use interface that integrates seamlessly with RubyLLM

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruby_llm-mcp'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install ruby_llm-mcp
```

## Usage

### Basic Setup

First, configure your RubyLLM client and create an MCP connection:

```ruby
require 'ruby_llm/mcp'

# Configure RubyLLM
RubyLLM.configure do |config|
  config.openai_api_key = "your-api-key"
end

# Connect to an MCP server via SSE
client = RubyLLM::MCP.client(
  name: "my-mcp-server",
  transport_type: "sse",
  config: {
    url: "http://localhost:9292/mcp/sse"
  }
)

# Or connect via stdio
client = RubyLLM::MCP.client(
  name: "my-mcp-server",
  transport_type: "stdio",
  config: {
    command: "node",
    args: ["path/to/mcp-server.js"],
    env: { "NODE_ENV" => "production" }
  }
)
```

### Using MCP Tools with RubyLLM

```ruby
# Get available tools from the MCP server
tools = client.tools
puts "Available tools:"
tools.each do |tool|
  puts "- #{tool.name}: #{tool.description}"
end

# Create a chat session with MCP tools
chat = RubyLLM.chat(model: "gpt-4")
chat.with_tools(*client.tools)

# Ask a question that will use the MCP tools
response = chat.ask("Can you help me search for recent files in my project?")
puts response
```

### Streaming Responses with Tool Calls

```ruby
chat = RubyLLM.chat(model: "gpt-4")
chat.with_tools(*client.tools)

chat.ask("Analyze my project structure") do |chunk|
  if chunk.tool_call?
    chunk.tool_calls.each do |key, tool_call|
      puts "\n🔧 Using tool: #{tool_call.name}"
    end
  else
    print chunk.content
  end
end
```

### Manual Tool Execution

You can also execute MCP tools directly:

```ruby
# Execute a specific tool
result = client.execute_tool(
  name: "search_files",
  parameters: {
    query: "*.rb",
    directory: "/path/to/search"
  }
)

puts result
```

## Transport Types

### SSE (Server-Sent Events)

Best for web-based MCP servers or when you need HTTP-based communication:

```ruby
client = RubyLLM::MCP.client(
  name: "web-mcp-server",
  transport_type: "sse",
  config: {
    url: "https://your-mcp-server.com/mcp/sse"
  }
)
```

### Stdio

Best for local MCP servers or command-line tools:

```ruby
client = RubyLLM::MCP.client(
  name: "local-mcp-server",
  transport_type: "stdio",
  config: {
    command: "python",
    args: ["-m", "my_mcp_server"],
    env: { "DEBUG" => "1" }
  }
)
```

## Configuration Options

- `name`: A unique identifier for your MCP client
- `transport_type`: Either `:sse` or `:stdio`
- `request_timeout`: Timeout for requests in milliseconds (default: 8000)
- `config`: Transport-specific configuration
  - For SSE: `{ url: "http://..." }`
  - For stdio: `{ command: "...", args: [...], env: {...} }`

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Examples

Check out the `examples/` directory for more detailed usage examples:

- `examples/test_local_mcp.rb` - Complete example with SSE transport

## Contributing

We welcome contributions! Bug reports and pull requests are welcome on GitHub at https://github.com/patvice/ruby_llm-mcp.

## License

Released under the MIT License.
