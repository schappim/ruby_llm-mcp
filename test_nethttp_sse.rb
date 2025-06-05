require "net/http"
require "uri"
require "timeout"

url = ENV.fetch("NINJA_GATEWAY", nil)

puts "Testing Net::HTTP SSE connection to: #{url}"

begin
  Timeout.timeout(15) do
    uri = URI(url)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      request = Net::HTTP::Get.new(uri)

      request["Accept"] = "text/event-stream"
      request["Accept-Encoding"] = "identity"
      request["Cache-Control"] = "no-cache"
      request["Connection"] = "keep-alive"
      request["X-CLIENT-ID"] = "test-client-12345"

      chunks_received = 0

      puts "Sending request..."
      http.request(request) do |response|
        puts "Response status: #{response.code}"
        puts "Response headers: #{response.to_hash}"

        response.read_body do |chunk|
          chunks_received += 1
          puts "=== CHUNK #{chunks_received} ==="
          puts "Size: #{chunk.length}"
          puts "Content: #{chunk.inspect}"
          puts "String: #{chunk}"
          puts "========================"

          # Exit after receiving a few chunks
          if chunks_received >= 3
            puts "Received #{chunks_received} chunks, exiting..."
            exit 0
          end
        end
      end
    end
  end
rescue Timeout::Error
  puts "Timeout - no data received within 15 seconds"
rescue StandardError => e
  puts "Error: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end
