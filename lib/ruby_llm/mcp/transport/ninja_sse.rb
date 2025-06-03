# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
require "timeout"
require "securerandom"
require "zlib"

module RubyLLM
  module MCP
    module Transport
      class NinjaSSE
        attr_reader :headers, :id, :session_id, :messages_url

        def initialize(connection_url, headers: {})
          puts "[NinjaSSE] Initializing with URL: #{connection_url}"
          puts "[NinjaSSE] Headers: #{headers.inspect}"
          
          @connection_url = connection_url
          @session_id = nil
          @messages_url = nil
          @client_id = SecureRandom.uuid
          @headers = headers.merge({
                                     "Accept" => "text/event-stream",
                                     "Cache-Control" => "no-cache",
                                     "Connection" => "keep-alive",
                                     "Accept-Encoding" => "identity",
                                     "X-CLIENT-ID" => @client_id
                                   })

          puts "[NinjaSSE] Final headers: #{@headers.inspect}"
          puts "[NinjaSSE] Client ID: #{@client_id}"

          @id_counter = 0
          @id_mutex = Mutex.new
          @pending_requests = {}
          @pending_mutex = Mutex.new
          @connection_mutex = Mutex.new
          @running = true
          @sse_thread = nil
          @endpoints_ready = false
          @endpoints_condition = ConditionVariable.new
          @endpoints_mutex = Mutex.new
          @http_connection = nil

          puts "[NinjaSSE] Starting SSE listener thread..."
          # Start the SSE listener thread and wait for endpoints
          start_sse_listener
          puts "[NinjaSSE] Waiting for endpoints..."
          wait_for_endpoints
          puts "[NinjaSSE] Initialization complete!"
        end

        def request(body, wait_for_response: true)
          puts "[NinjaSSE] Making request with body: #{body.inspect}"
          puts "[NinjaSSE] Messages URL: #{@messages_url}"
          
          raise "Messages URL not available" unless @messages_url

          # Generate a unique request ID
          @id_mutex.synchronize { @id_counter += 1 }
          request_id = @id_counter
          body["id"] = request_id

          puts "[NinjaSSE] Request ID: #{request_id}"
          puts "[NinjaSSE] Wait for response: #{wait_for_response}"

          # Create a queue for this request's response
          response_queue = Queue.new
          if wait_for_response
            @pending_mutex.synchronize do
              @pending_requests[request_id.to_s] = response_queue
            end
            puts "[NinjaSSE] Added request #{request_id} to pending requests"
          end

          # Send the request using Net::HTTP
          begin
            uri = URI(@messages_url)
            puts "[NinjaSSE] Parsed URI: #{uri.inspect}"
            
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true if uri.scheme == 'https'
            http.open_timeout = 5
            http.read_timeout = 30

            puts "[NinjaSSE] Created HTTP client for #{uri.host}:#{uri.port}, SSL: #{uri.scheme == 'https'}"

            request = Net::HTTP::Post.new(uri)
            @headers.each do |key, value|
              request[key] = value
            end
            request['Content-Type'] = 'application/json'
            request.body = JSON.generate(body)

            puts "[NinjaSSE] POST request headers: #{request.to_hash.inspect}"
            puts "[NinjaSSE] POST request body: #{request.body}"

            puts "[NinjaSSE] Sending POST request..."
            response = http.request(request)

            puts "[NinjaSSE] POST response code: #{response.code}"
            puts "[NinjaSSE] POST response headers: #{response.to_hash.inspect}"
            puts "[NinjaSSE] POST response body: #{response.body}"

            unless response.code == '200'
              @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
              error_msg = "Failed to request #{@messages_url}: #{response.code} - #{response.body}"
              puts "[NinjaSSE] ERROR: #{error_msg}"
              raise error_msg
            end

            puts "[NinjaSSE] POST request successful"
          rescue StandardError => e
            puts "[NinjaSSE] POST request failed: #{e.message}"
            puts "[NinjaSSE] Backtrace: #{e.backtrace.first(5).join("\n")}"
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            raise e
          end
          
          return unless wait_for_response

          puts "[NinjaSSE] Waiting for response to request #{request_id}..."
          begin
            Timeout.timeout(30) do
              response = response_queue.pop
              puts "[NinjaSSE] Received response for request #{request_id}: #{response.inspect}"
              response
            end
          rescue Timeout::Error
            puts "[NinjaSSE] Request #{request_id} timed out after 30 seconds"
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            raise RubyLLM::MCP::Errors::TimeoutError.new(message: "Request timed out after 30 seconds")
          end
        end

        def close
          puts "[NinjaSSE] Closing connection..."
          @running = false
          @http_connection&.finish if @http_connection&.started?
          @sse_thread&.join(1)
          @sse_thread = nil
          puts "[NinjaSSE] Connection closed"
        end

        private

        def wait_for_endpoints
          puts "[NinjaSSE] Waiting for endpoints to be ready..."
          @endpoints_mutex.synchronize do
            @endpoints_condition.wait(@endpoints_mutex, 15) until @endpoints_ready || !@running
          end
          unless @endpoints_ready
            puts "[NinjaSSE] ERROR: Failed to get endpoints from ninja.ai within 15 seconds"
            raise "Failed to get endpoints from ninja.ai"
          end
          puts "[NinjaSSE] Endpoints are ready!"
        end

        def start_sse_listener
          @connection_mutex.synchronize do
            return if sse_thread_running?

            puts "[NinjaSSE] Creating SSE listener thread..."
            @sse_thread = Thread.new do
              puts "[NinjaSSE] [Thread] SSE listener thread started"
              begin
                establish_persistent_connection
              rescue => e
                puts "[NinjaSSE] [Thread] SSE connection error: #{e.message}"
                puts "[NinjaSSE] [Thread] Backtrace: #{e.backtrace.first(5).join("\n")}" if e.backtrace
              ensure
                puts "[NinjaSSE] [Thread] Cleaning up HTTP connection..."
                @http_connection&.finish if @http_connection&.started?
                puts "[NinjaSSE] [Thread] SSE listener thread ending"
              end
            end

            @sse_thread.abort_on_exception = false
            puts "[NinjaSSE] SSE listener thread created"
          end
        end

        def sse_thread_running?
          result = @sse_thread && @sse_thread.alive?
          puts "[NinjaSSE] SSE thread running: #{result}"
          result
        end

        def establish_persistent_connection
          uri = URI(@connection_url)
          puts "[NinjaSSE] [Thread] Establishing persistent connection to: #{uri}"
          
          @http_connection = Net::HTTP.new(uri.host, uri.port)
          @http_connection.use_ssl = true if uri.scheme == 'https'
          @http_connection.open_timeout = 10
          @http_connection.read_timeout = 300
          @http_connection.keep_alive_timeout = 300
          
          puts "[NinjaSSE] [Thread] HTTP connection settings - SSL: #{uri.scheme == 'https'}, open_timeout: 10, read_timeout: 300"
          
          puts "[NinjaSSE] [Thread] Starting HTTP connection..."
          @http_connection.start

          request_path = uri.path + (uri.query ? "?#{uri.query}" : "")
          puts "[NinjaSSE] [Thread] Request path: #{request_path}"
          
          request = Net::HTTP::Get.new(request_path)
          @headers.each do |key, value|
            request[key] = value
          end

          puts "[NinjaSSE] [Thread] GET request headers: #{request.to_hash.inspect}"
          puts "[NinjaSSE] [Thread] Sending GET request for SSE stream..."

          @http_connection.request(request) do |response|
            puts "[NinjaSSE] [Thread] SSE response code: #{response.code}"
            puts "[NinjaSSE] [Thread] SSE response headers: #{response.to_hash.inspect}"
            
            unless response.code == '200'
              error_msg = "SSE connection failed: #{response.code} - #{response.message}"
              puts "[NinjaSSE] [Thread] ERROR: #{error_msg}"
              raise error_msg
            end

            puts "[NinjaSSE] [Thread] SSE stream established, reading body..."
            puts "[NinjaSSE] [Thread] Content-Encoding: #{response['content-encoding']}"
            
            buffer = ""
            chunk_count = 0
            
            response.read_body do |chunk|
              chunk_count += 1
              puts "[NinjaSSE] [Thread] Received chunk #{chunk_count} (#{chunk.bytesize} bytes): #{chunk.inspect}"
              
              break unless @running
              
              buffer << chunk
              puts "[NinjaSSE] [Thread] Buffer now contains: #{buffer.inspect}"
              
              # Process complete events
              while buffer.include?("\n\n")
                puts "[NinjaSSE] [Thread] Found complete event in buffer"
                event_data, buffer = buffer.split("\n\n", 2)
                puts "[NinjaSSE] [Thread] Raw event data: #{event_data.inspect}"
                puts "[NinjaSSE] [Thread] Remaining buffer: #{buffer.inspect}"
                
                event = parse_sse_event(event_data)
                puts "[NinjaSSE] [Thread] Parsed event: #{event.inspect}"
                
                if event && !event.empty?
                  process_event(event)
                else
                  puts "[NinjaSSE] [Thread] Skipping empty or invalid event"
                end
              end
            end
            
            puts "[NinjaSSE] [Thread] SSE stream ended (read #{chunk_count} chunks total)"
          end
        rescue => e
          puts "[NinjaSSE] [Thread] Connection error: #{e.message}"
          puts "[NinjaSSE] [Thread] Backtrace: #{e.backtrace.first(5).join("\n")}" if e.backtrace
          
          if @running
            puts "[NinjaSSE] [Thread] Connection lost. Reconnecting in 3 seconds..."
            sleep 3
            retry
          else
            puts "[NinjaSSE] [Thread] Not reconnecting (running=false)"
          end
        end

        def process_event(event)
          puts "[NinjaSSE] [Thread] Processing event: #{event.inspect}"
          
          case event[:event]
          when "session"
            @session_id = event[:data]&.strip
            puts "[NinjaSSE] [Thread] ✓ Session established: #{@session_id}"
          when "endpoint"
            @messages_url = event[:data]&.strip
            puts "[NinjaSSE] [Thread] ✓ Endpoint received: #{@messages_url}"
            @endpoints_mutex.synchronize do
              @endpoints_ready = true
              puts "[NinjaSSE] [Thread] Signaling that endpoints are ready"
              @endpoints_condition.broadcast
            end
          else
            puts "[NinjaSSE] [Thread] Processing MCP response event (event type: #{event[:event] || 'nil'})"
            # Handle MCP response messages (JSON-RPC responses)
            return unless event[:data]
            
            begin
              event_data = JSON.parse(event[:data])
              puts "[NinjaSSE] [Thread] Parsed JSON event data: #{event_data.inspect}"
              
              request_id = event_data["id"]&.to_s
              puts "[NinjaSSE] [Thread] Looking for pending request with ID: #{request_id}"

              @pending_mutex.synchronize do
                puts "[NinjaSSE] [Thread] Current pending requests: #{@pending_requests.keys.inspect}"
                if request_id && @pending_requests.key?(request_id)
                  response_queue = @pending_requests.delete(request_id)
                  puts "[NinjaSSE] [Thread] Found matching request, pushing response to queue"
                  response_queue&.push(event_data)
                else
                  puts "[NinjaSSE] [Thread] No matching pending request found"
                end
              end
            rescue JSON::ParserError => e
              puts "[NinjaSSE] [Thread] Failed to parse JSON: #{e.message}"
              puts "[NinjaSSE] [Thread] Raw data was: #{event[:data].inspect}"
            end
          end
        end

        def parse_sse_event(event_data)
          puts "[NinjaSSE] [Thread] Parsing SSE event from: #{event_data.inspect}"
          event = {}
          
          event_data.each_line do |line|
            line = line.strip
            next if line.empty?
            
            puts "[NinjaSSE] [Thread] Processing line: #{line.inspect}"
            
            case line
            when /^data:\s*(.*)$/
              (event[:data] ||= []) << $1
              puts "[NinjaSSE] [Thread] Found data: #{$1}"
            when /^event:\s*(.*)$/
              event[:event] = $1
              puts "[NinjaSSE] [Thread] Found event type: #{$1}"
            when /^id:\s*(.*)$/
              event[:id] = $1
              puts "[NinjaSSE] [Thread] Found event ID: #{$1}"
            when /^retry:\s*(.*)$/
              event[:retry] = $1.to_i
              puts "[NinjaSSE] [Thread] Found retry: #{$1}"
            else
              puts "[NinjaSSE] [Thread] Unrecognized line format: #{line}"
            end
          end
          
          event[:data] = event[:data]&.join("\n") if event[:data]
          puts "[NinjaSSE] [Thread] Final parsed event: #{event.inspect}"
          event
        end
      end
    end
  end
end