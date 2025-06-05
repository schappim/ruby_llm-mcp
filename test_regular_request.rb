require "faraday"
require "faraday/net_http"

url = ENV.fetch("NINJA_GATEWAY", nil)

puts "Testing regular request to: #{url}"

begin
  # Create Faraday connection with net_http adapter
  client = Faraday.new do |f|
    f.options.timeout = 10
    f.options.open_timeout = 5
    f.adapter :net_http
  end

  puts "Making regular GET request..."
  response = client.get(url) do |req|
    req.headers["Accept"] = "text/event-stream"
    req.headers["Accept-Encoding"] = "identity"
    req.headers["Cache-Control"] = "no-cache"
    req.headers["Connection"] = "keep-alive"
    req.headers["X-CLIENT-ID"] = "test-regular-#{Time.now.to_i}"
  end

  puts "Response status: #{response.status}"
  puts "Response headers:"
  response.headers.each { |k, v| puts "  #{k}: #{v}" }
  puts "Response body length: #{response.body.length}"
  puts "Response body preview: #{response.body[0, 200].inspect}"

  if response.body.include?("event:")
    puts "Body contains SSE events!"
    events = response.body.split("\n\n").select { |e| !e.strip.empty? }
    puts "Found #{events.length} events:"
    events.each_with_index { |event, i| puts "Event #{i + 1}: #{event.inspect}" }
  end
rescue StandardError => e
  puts "Error: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end
