#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

url = "https://mcp.ninja.ai/connect/4SEwn_CrxnD3cPQb4w38nhXxSnJpDQux0g_yMczU2Ccur60OuUC3Ibmr"

puts "Testing SSE connection to: #{url}"
puts "-" * 50

uri = URI(url)
buffer = +""
session_id = nil
endpoint_url = nil

begin
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    request = Net::HTTP::Get.new(uri)
    request['Accept'] = 'text/event-stream'
    request['Cache-Control'] = 'no-cache'
    request['Connection'] = 'keep-alive'
    request['Accept-Encoding'] = 'identity'
    
    puts "Making request with headers:"
    request.each_header { |key, value| puts "  #{key}: #{value}" }
    puts "-" * 30
    
    http.request(request) do |response|
      puts "Response status: #{response.code}"
      puts "Response headers:"
      response.each_header { |key, value| puts "  #{key}: #{value}" }
      puts "-" * 30
      
      if response.code != '200'
        puts "Error: #{response.code} - #{response.body}"
        exit 1
      end
      
      response.read_body do |chunk|
        puts "Received chunk (#{chunk.bytesize} bytes): #{chunk.inspect}"
        buffer << chunk
        
        # Process complete events
        while buffer.include?("\n\n")
          raw_event, buffer = buffer.split("\n\n", 2)
          puts "Processing raw event: #{raw_event.inspect}"
          
          # Parse the event
          event = {}
          raw_event.each_line do |line|
            line = line.strip
            case line
            when /^event:\s*(.+)/
              event[:event] = $1
            when /^data:\s*(.+)/
              event[:data] = $1
            when /^id:\s*(.+)/
              event[:id] = $1
            when /^:\s*(.+)/
              # Comment line (like ping)
              puts "Received comment: #{$1}"
            end
          end
          
          puts "Parsed event: #{event.inspect}"
          
          if event[:event] == "session"
            session_id = event[:data]
            puts "✅ Got session ID: #{session_id}"
          elsif event[:event] == "endpoint"
            endpoint_url = event[:data]
            puts "✅ Got endpoint URL: #{endpoint_url}"
            puts "🎉 Ready to make requests!"
            
            # Test the endpoint URL
            puts "\nTesting endpoint URL..."
            endpoint_uri = URI(endpoint_url)
            test_body = {
              jsonrpc: "2.0",
              id: 1,
              method: "initialize",
              params: {
                protocolVersion: "2024-11-05",
                capabilities: {},
                clientInfo: { name: "test-client", version: "1.0.0" }
              }
            }
            
            Net::HTTP.start(endpoint_uri.host, endpoint_uri.port, use_ssl: endpoint_uri.scheme == 'https') do |test_http|
              test_request = Net::HTTP::Post.new(endpoint_uri)
              test_request['Content-Type'] = 'application/json'
              test_request.body = test_body.to_json
              
              test_response = test_http.request(test_request)
              puts "Test response status: #{test_response.code}"
              puts "Test response body: #{test_response.body}"
            end
            
            exit 0
          end
        end
      end
    end
  end
  
rescue => e
  puts "Error: #{e.class} - #{e.message}"
  puts "Backtrace:"
  puts e.backtrace.first(10)
end