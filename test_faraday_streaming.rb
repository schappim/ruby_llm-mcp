require "faraday"
require "faraday/net_http"
require "timeout"

url = ENV.fetch("NINJA_GATEWAY", nil)

puts "Testing new Faraday streaming approach to: #{url}"

chunks_received = 0
buffer = ""

begin
  Timeout.timeout(15) do
    # Create Faraday connection with net_http adapter
    client = Faraday.new do |f|
      f.options.timeout = 30
      f.options.open_timeout = 10
      f.options.read_timeout = 30
      f.adapter :net_http
    end

    puts "Making streaming request..."
    response = client.get(url) do |req|
      # Set SSE headers
      req.headers["Accept"] = "text/event-stream"
      req.headers["Accept-Encoding"] = "identity"
      req.headers["Cache-Control"] = "no-cache"
      req.headers["Connection"] = "keep-alive"
      req.headers["X-CLIENT-ID"] = "test-streaming-#{Time.now.to_i}"

      # Set up streaming callback with status checking
      req.options.on_data = proc do |chunk, size, env|
        if env.status < 300
          chunks_received += 1
          puts "=== CHUNK #{chunks_received} (Status: #{env.status}) ==="
          puts "Size: #{size}"
          puts "Content: #{chunk.inspect}"
          puts "String: #{chunk}"
          puts "========================"

          buffer << chunk

          # Process complete events
          while buffer.include?("\n\n")
            event_text, buffer = buffer.split("\n\n", 2)
            puts "Complete event: #{event_text.inspect}"
          end

          # Exit after receiving enough chunks
          if chunks_received >= 5
            puts "Received #{chunks_received} chunks, exiting..."
            exit 0
          end
        else
          puts "Non-success status: #{env.status}"
        end
      end
    end

    puts "Response completed with status: #{response.status}"
  end
rescue Timeout::Error
  puts "Timeout - received #{chunks_received} chunks in 15 seconds"
rescue StandardError => e
  puts "Error: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end
