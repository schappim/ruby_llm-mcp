#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "async"
require "async/http"
require "async/io/stream"

url = ENV.fetch("NINJA_GATEWAY", nil)

Async do
  puts "Testing raw async-http SSE connection..."

  endpoint = Async::HTTP::Endpoint.parse(url)
  client = Async::HTTP::Client.new(endpoint)

  headers = [
    ["accept", "text/event-stream"],
    ["accept-encoding", "identity"],
    ["cache-control", "no-cache"],
    ["connection", "keep-alive"],
    ["x-client-id", "test-client"]
  ]

  uri = URI.parse(url)
  path = uri.path || "/"
  path += "?#{uri.query}" if uri.query

  puts "Requesting: #{path}"
  response = client.get(path, headers)

  puts "Status: #{response.status}"
  puts "Headers: #{response.headers.to_h}"

  if response.status == 200
    puts "Reading body..."
    buffer = ""

    # Read the body in chunks
    body = response.body

    # Try different ways to read the streaming body
    if body.respond_to?(:each)
      puts "Body responds to each, reading chunks..."
      body.each do |chunk|
        puts "Chunk received: #{chunk.bytesize} bytes"
        puts "Content: #{chunk[0..100]}..."
        buffer << chunk

        # Process SSE events
        while buffer.include?("\n\n")
          event, buffer = buffer.split("\n\n", 2)
          puts "Event: #{event}"
        end
      end
    elsif body.respond_to?(:read)
      puts "Body responds to read..."
      while chunk = body.read
        puts "Read chunk: #{chunk.bytesize} bytes"
        buffer << chunk
      end
    else
      puts "Body class: #{body.class}"
      puts "Body methods: #{body.methods.sort}"
    end
  else
    puts "Request failed with status: #{response.status}"
  end

  client.close
end
