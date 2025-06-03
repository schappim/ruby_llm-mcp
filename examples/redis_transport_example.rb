#!/usr/bin/env ruby

require_relative "../lib/ruby_llm/mcp/transport/ninja_sse"
require "json"

# Example usage of Redis-based NinjaSSE transport
class RedisTransportExample
  def initialize(gateway_slug, auth_token = nil)
    @gateway_slug = gateway_slug
    @auth_token = auth_token
    @connection_url = "https://mcp.ninja.ai/connect/#{gateway_slug}"
    
    # Set up headers
    headers = {}
    headers["Authorization"] = "Bearer #{auth_token}" if auth_token
    
    puts "🚀 Initializing Redis-based NinjaSSE transport..."
    puts "   Gateway: #{gateway_slug}"
    puts "   Auth: #{auth_token ? 'Yes' : 'No'}"
    
    @transport = RubyLLM::MCP::Transport::NinjaSSE.new(@connection_url, headers: headers)
    puts "✅ Transport initialized successfully!"
  end

  def initialize_connection
    puts "\n📡 Initializing MCP connection..."
    
    response = @transport.request({
      "method" => "initialize",
      "params" => {
        "protocolVersion" => "2024-11-05",
        "capabilities" => {
          "tools" => {"listChanged" => true},
          "prompts" => {"listChanged" => true},
          "resources" => {"listChanged" => true}
        },
        "clientInfo" => {
          "name" => "Redis Transport Example",
          "version" => "1.0.0"
        }
      }
    })
    
    puts "✅ Connection initialized:"
    puts "   Protocol: #{response.dig('result', 'protocolVersion')}"
    puts "   Server: #{response.dig('result', 'serverInfo', 'name')}"
    
    # Send initialized notification
    @transport.request({
      "method" => "notifications/initialized",
      "params" => {}
    }, wait_for_response: false)
    
    puts "✅ Initialized notification sent"
  end

  def list_tools
    puts "\n🔧 Listing available tools..."
    
    response = @transport.request({
      "method" => "tools/list",
      "params" => {}
    })
    
    tools = response.dig("result", "tools") || []
    puts "✅ Found #{tools.length} tools:"
    
    tools.each_with_index do |tool, index|
      puts "   #{index + 1}. #{tool['name']}"
      puts "      #{tool['description']}" if tool['description']
    end
    
    tools
  end

  def list_prompts
    puts "\n💭 Listing available prompts..."
    
    response = @transport.request({
      "method" => "prompts/list",
      "params" => {}
    })
    
    prompts = response.dig("result", "prompts") || []
    puts "✅ Found #{prompts.length} prompts:"
    
    prompts.each_with_index do |prompt, index|
      puts "   #{index + 1}. #{prompt['name']}"
      puts "      #{prompt['description']}" if prompt['description']
    end
    
    prompts
  end

  def list_resources
    puts "\n📄 Listing available resources..."
    
    response = @transport.request({
      "method" => "resources/list",
      "params" => {}
    })
    
    resources = response.dig("result", "resources") || []
    puts "✅ Found #{resources.length} resources:"
    
    resources.each_with_index do |resource, index|
      puts "   #{index + 1}. #{resource['name'] || resource['uri']}"
      puts "      Type: #{resource['mimeType']}" if resource['mimeType']
      puts "      Size: #{resource['size']} bytes" if resource['size']
    end
    
    resources
  end

  def call_tool(tool_name, arguments = {})
    puts "\n⚡ Calling tool: #{tool_name}"
    puts "   Arguments: #{arguments.inspect}"
    
    response = @transport.request({
      "method" => "tools/call",
      "params" => {
        "name" => tool_name,
        "arguments" => arguments
      }
    })
    
    if response.dig("result", "isError")
      puts "❌ Tool execution failed:"
      content = response.dig("result", "content", 0, "text") || "Unknown error"
      puts "   #{content}"
    else
      puts "✅ Tool executed successfully:"
      content = response.dig("result", "content", 0, "text") || "No output"
      puts "   #{content[0..200]}#{content.length > 200 ? '...' : ''}"
    end
    
    response
  end

  def get_prompt(prompt_name, arguments = {})
    puts "\n💬 Getting prompt: #{prompt_name}"
    puts "   Arguments: #{arguments.inspect}"
    
    response = @transport.request({
      "method" => "prompts/get",
      "params" => {
        "name" => prompt_name,
        "arguments" => arguments
      }
    })
    
    messages = response.dig("result", "messages") || []
    puts "✅ Retrieved prompt with #{messages.length} messages:"
    
    messages.each_with_index do |message, index|
      puts "   #{index + 1}. [#{message['role']}] #{message.dig('content', 'text')[0..100]}..."
    end
    
    response
  end

  def read_resource(resource_uri)
    puts "\n📖 Reading resource: #{resource_uri}"
    
    response = @transport.request({
      "method" => "resources/read",
      "params" => {
        "uri" => resource_uri
      }
    })
    
    contents = response.dig("result", "contents") || []
    puts "✅ Retrieved resource with #{contents.length} content items:"
    
    contents.each_with_index do |content, index|
      puts "   #{index + 1}. Type: #{content['mimeType']}"
      if content['text']
        preview = content['text'][0..100]
        puts "      Text: #{preview}#{content['text'].length > 100 ? '...' : ''}"
      elsif content['blob']
        puts "      Binary data: #{content['blob'].length} bytes"
      end
    end
    
    response
  end

  def cleanup
    puts "\n🧹 Cleaning up..."
    @transport&.close
    puts "✅ Transport closed"
  end

  def run_interactive_demo
    puts "\n🎮 Starting interactive demo..."
    
    loop do
      puts "\nChoose an action:"
      puts "1. List tools"
      puts "2. List prompts" 
      puts "3. List resources"
      puts "4. Call a tool"
      puts "5. Get a prompt"
      puts "6. Read a resource"
      puts "7. Exit"
      
      print "> "
      choice = gets.chomp
      
      case choice
      when "1"
        list_tools
      when "2" 
        list_prompts
      when "3"
        list_resources
      when "4"
        tools = list_tools
        if tools.any?
          puts "\nEnter tool name:"
          print "> "
          tool_name = gets.chomp
          puts "Enter arguments as JSON (or press Enter for none):"
          print "> "
          args_input = gets.chomp
          args = args_input.empty? ? {} : JSON.parse(args_input) rescue {}
          call_tool(tool_name, args)
        end
      when "5"
        prompts = list_prompts
        if prompts.any?
          puts "\nEnter prompt name:"
          print "> "
          prompt_name = gets.chomp
          puts "Enter arguments as JSON (or press Enter for none):"
          print "> "
          args_input = gets.chomp
          args = args_input.empty? ? {} : JSON.parse(args_input) rescue {}
          get_prompt(prompt_name, args)
        end
      when "6"
        resources = list_resources
        if resources.any?
          puts "\nEnter resource URI:"
          print "> "
          uri = gets.chomp
          read_resource(uri)
        end
      when "7"
        break
      else
        puts "Invalid choice"
      end
    end
  end
end

# Main execution
if __FILE__ == $0
  puts "🔧 Redis Transport Example"
  puts "========================="
  
  # Check for required arguments
  if ARGV.length < 1
    puts "Usage: ruby redis_transport_example.rb <gateway_slug> [auth_token]"
    puts "Example: ruby redis_transport_example.rb my-gateway-slug"
    puts "Example: ruby redis_transport_example.rb my-gateway-slug my-auth-token"
    exit 1
  end
  
  gateway_slug = ARGV[0]
  auth_token = ARGV[1]
  
  begin
    # Create and initialize transport
    example = RedisTransportExample.new(gateway_slug, auth_token)
    
    # Initialize MCP connection
    example.initialize_connection
    
    # Run basic operations
    example.list_tools
    example.list_prompts
    example.list_resources
    
    # Interactive demo
    if ARGV.include?('--interactive')
      example.run_interactive_demo
    else
      puts "\n💡 Add --interactive flag for interactive demo"
    end
    
  rescue => e
    puts "\n❌ Error: #{e.message}"
    puts "   #{e.backtrace.first}"
  ensure
    example&.cleanup
  end
  
  puts "\n👋 Example completed!"
end