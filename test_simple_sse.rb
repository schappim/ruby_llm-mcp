require "faraday"
require "timeout"

url = ENV.fetch("NINJA_GATEWAY", nil)

puts "Testing simple SSE connection to: #{url}"

begin
  Timeout.timeout(10) do
    conn = Faraday.new do |f|
      f.options.timeout = 30
      f.options.open_timeout = 5
      f.adapter Faraday.default_adapter
    end

    chunks_received = 0

    response = conn.get(url) do |req|
      req.headers["Accept"] = "text/event-stream"
      req.headers["Accept-Encoding"] = "identity"
      req.headers["Cache-Control"] = "no-cache"
      req.headers["Connection"] = "keep-alive"

      req.options.on_data = proc do |chunk, size, env|
        chunks_received += 1
        puts "=== CHUNK #{chunks_received} ==="
        puts "Size: #{size}"
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

    puts "Response status: #{response.status}"
    puts "Response headers: #{response.headers}"
  end
rescue Timeout::Error
  puts "Timeout - no data received within 10 seconds"
rescue StandardError => e
  puts "Error: #{e.class}: #{e.message}"
  puts e.backtrace.first(3)
end
