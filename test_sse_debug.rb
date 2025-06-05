#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "uri"

url = ENV.fetch("NINJA_GATEWAY", nil)
uri = URI(url)

puts "Testing SSE connection to: #{url}"
puts "Time: #{Time.now}"

Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
  http.read_timeout = 5 # Short timeout to see what happens

  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "text/event-stream"
  request["Accept-Encoding"] = "identity"
  request["Cache-Control"] = "no-cache"
  request["Connection"] = "keep-alive"

  puts "\nMaking request..."

  begin
    http.request(request) do |response|
      puts "Response code: #{response.code}"
      puts "Content-Type: #{response['content-type']}"
      puts "Transfer-Encoding: #{response['transfer-encoding']}"

      if response.code == "200"
        puts "\nReading body with timeout..."
        buffer = ""

        begin
          Timeout.timeout(3) do
            response.read_body do |chunk|
              puts "Chunk received: #{chunk.bytesize} bytes"
              puts "Content: #{chunk.inspect}"
              buffer << chunk
            end
          end
        rescue Timeout::Error
          puts "Timeout after 3 seconds"
          puts "Buffer contents: #{buffer.inspect}"
        end
      end
    end
  rescue StandardError => e
    puts "Error: #{e.class} - #{e.message}"
  end
end
