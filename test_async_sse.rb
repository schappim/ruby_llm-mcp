#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "faraday"
require "async"
require "async/http/faraday"

url = ENV.fetch("NINJA_GATEWAY", nil)

Async do
  puts "Testing async-http-faraday SSE connection..."

  conn = Faraday.new do |f|
    f.adapter :async_http
  end

  headers = {
    "Accept" => "text/event-stream",
    "Accept-Encoding" => "identity",
    "Cache-Control" => "no-cache",
    "Connection" => "keep-alive",
    "X-CLIENT-ID" => "test-client"
  }

  buffer = ""
  chunks_received = 0

  begin
    response = conn.get(url) do |req|
      headers.each { |k, v| req.headers[k] = v }

      req.options.on_data = proc do |chunk, overall_received_bytes|
        chunks_received += 1
        puts "Chunk #{chunks_received}: #{chunk.length} bytes (total: #{overall_received_bytes})"
        puts "Content: #{chunk[0..100]}..." if chunk.length > 0
        buffer << chunk

        # Process SSE events
        while buffer.include?("\n\n")
          event_text, buffer = buffer.split("\n\n", 2)
          puts "Event: #{event_text}"
        end
      end
    end

    puts "Response status: #{response.status}"
    puts "Response headers: #{response.headers}"
    puts "Body length: #{response.body&.length || 0}"
  rescue StandardError => e
    puts "Error: #{e.class} - #{e.message}"
    puts e.backtrace.first(5)
  end
end
