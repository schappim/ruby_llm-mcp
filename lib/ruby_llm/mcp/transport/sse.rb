# frozen_string_literal: true

require "json"
require "uri"
require "faraday"
require "faraday/net_http"
require "typhoeus"
require "timeout"
require "securerandom"
require "time"

module RubyLLM
  module MCP
    module Transport
      class SSE
        attr_reader :headers, :id

        def initialize(url, headers: {})
          log "Initializing connection to #{url}"
          @event_url = url
          @messages_url = nil

          uri = URI.parse(url)
          @root_url = "#{uri.scheme}://#{uri.host}"
          @root_url += ":#{uri.port}" if uri.port != uri.default_port

          @client_id = SecureRandom.uuid
          @headers = headers.merge({
                                     "Accept" => "text/event-stream",
                                     "Cache-Control" => "no-cache",
                                     "Connection" => "keep-alive",
                                     "X-CLIENT-ID" => @client_id,
                                     "User-Agent" => "Ruby-MCP-Client/1.0"
                                   })

          @id_counter = 0
          @id_mutex = Mutex.new
          @pending_requests = {}
          @pending_mutex = Mutex.new
          @connection_mutex = Mutex.new
          @running = true
          @sse_thread = nil

          # Start the SSE listener thread
          start_sse_listener
        end

        # rubocop:disable Metrics/MethodLength
        def request(body, wait_for_response: true)
          log "Sending request #{body['method']}"
          # Generate a unique request ID
          @id_mutex.synchronize { @id_counter += 1 }
          request_id = @id_counter
          body["id"] = request_id

          # Create a queue for this request's response
          response_queue = Queue.new
          if wait_for_response
            @pending_mutex.synchronize do
              @pending_requests[request_id.to_s] = response_queue
              log "Added request #{request_id} to pending queue (#{@pending_requests.size} total)"
            end
          end

          # Send the request using Typhoeus
          begin
            request_headers = @headers.merge("Content-Type" => "application/json")
            
            response = Typhoeus.post(@messages_url,
              headers: request_headers,
              body: JSON.generate(body),
              timeout: 30,
              connecttimeout: 10
            )

            log "Request response status: #{response.code}"

            unless [200, 202].include?(response.code)
              @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
              raise "Failed to request #{@messages_url}: #{response.code} - #{response.body}"
            end
          rescue StandardError => e
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            raise e
          end
          return unless wait_for_response

          begin
            Timeout.timeout(30) do
              result = response_queue.pop
              log "Received response for request #{request_id}"
              result
            end
          rescue Timeout::Error
            @pending_mutex.synchronize { 
              @pending_requests.delete(request_id.to_s) 
              log "Request #{request_id} timed out. Pending requests: #{@pending_requests.keys}"
            }
            raise RubyLLM::MCP::Errors::TimeoutError.new(message: "Request timed out after 30 seconds")
          end
        end
        # rubocop:enable Metrics/MethodLength

        def close
          @running = false
          @sse_thread&.join(1) # Give the thread a second to clean up
          @sse_thread = nil
        end

        private

        def log(message)
          puts "[#{Time.now.strftime('%H:%M:%S.%L')}] SSE: #{message}"
        end

        def start_sse_listener
          log "Starting event listener"
          @connection_mutex.synchronize do
            return if sse_thread_running?

            @endpoint_received = Queue.new
            @pending_mutex.synchronize do
              @pending_requests["endpoint"] = @endpoint_received
            end

            @sse_thread = Thread.new do
              listen_for_events while @running
            end
            @sse_thread.abort_on_exception = true

            # Wait for endpoint with timeout
            endpoint = begin
              Timeout.timeout(30) do
                @endpoint_received.pop
              end
            rescue Timeout::Error
              raise "Timeout waiting for endpoint from SSE connection"
            end
            
            set_message_endpoint(endpoint)
            @pending_mutex.synchronize { @pending_requests.delete("endpoint") }
          end
        end

        def set_message_endpoint(endpoint)
          uri = URI.parse(endpoint)

          @messages_url = if uri.host.nil?
                            "#{@root_url}#{endpoint}"
                          else
                            endpoint
                          end
          log "Message endpoint set to: #{@messages_url}"
        end

        def sse_thread_running?
          @sse_thread&.alive?
        end

        def listen_for_events
          log "listen_for_events starting - @running = #{@running}"
          log "Connecting to event stream"
          stream_events_from_server
          log "stream_events_from_server completed"
        rescue StandardError => e
          log "Standard error caught: #{e.class}: #{e.message}"
          log "Error backtrace: #{e.backtrace.first(5)}"
          handle_connection_error("SSE connection error", e)
          retry if @running
        end

        def stream_events_from_server
          log "Starting stream_events_from_server to #{@event_url}"
          buffer = +""
          
          log "Using Typhoeus for SSE streaming..."
          typhoeus_sse_request(@event_url, buffer)
        rescue => e
          log "Error in stream - #{e.class}: #{e.message}"
          log "Error backtrace: #{e.backtrace.first(3)}"
          raise
        end

        def typhoeus_sse_request(url, buffer)
          log "Creating Typhoeus streaming request to #{url}"
          start_time = Time.now
          chunk_count = 0
          
          request = Typhoeus::Request.new(url,
            method: :get,
            headers: @headers,
            timeout: 0,  # No timeout for SSE
            connecttimeout: 10,
            ssl_verifypeer: false  # Disable SSL verification for now
          )
          
          # Set up streaming callback
          request.on_body do |chunk|
            chunk_count += 1
            current_time = Time.now
            elapsed = (current_time - start_time).round(3)
            
            log "Typhoeus chunk #{chunk_count} (#{chunk.bytesize}b, #{elapsed}s): #{chunk[0..50].inspect}..."
            
            buffer << chunk
            process_sse_buffer(buffer)
            
            # Continue processing
            :continue
          end
          
          # Set up completion callback
          request.on_complete do |response|
            log "Typhoeus request completed with status: #{response.code}"
          end
          
          log "Starting Typhoeus request..."
          request.run
        end

        def process_sse_buffer(buffer)
          # Process complete SSE events (terminated by double newlines)
          while buffer.include?("\n\n")
            # Extract one complete event
            event_text, remaining = buffer.split("\n\n", 2)
            
            # Parse the SSE event
            event_data = parse_sse_event(event_text)
            
            if event_data && (event_data[:event] || event_data[:data])
              log "Processing event: #{event_data[:event]} - #{event_data[:data]&.slice(0, 50)}..."
              process_event(event_data)
            end
            
            # Update buffer with remaining data
            buffer.replace(remaining || "")
          end
        end

        def parse_sse_event(event_text)
          event = {}
          event_text.each_line do |line|
            line = line.strip
            case line
            when /^data:\s*(.*)/
              data_content = ::Regexp.last_match(1)
              (event[:data] ||= []) << data_content
            when /^event:\s*(.*)/
              event[:event] = ::Regexp.last_match(1)
            when /^id:\s*(.*)/
              event[:id] = ::Regexp.last_match(1)
            when /^retry:\s*(.*)/
              event[:retry] = ::Regexp.last_match(1).to_i
            when /^:(.*)/
              # Comment line, ignore
            end
          end
          
          # Join multiple data lines with newlines
          event[:data] = event[:data]&.join("\n")
          event
        end

        def process_buffer_events(buffer)
          # Fallback method for compatibility - delegates to new method
          process_sse_buffer(buffer)
        end

        def handle_connection_error(message, error)
          log "#{message}: #{error.class}: #{error.message}"
          log "Backtrace: #{error.backtrace.first(3)}"
          log "Reconnecting in 1 second..."
          sleep 1
        end

        def process_event(raw_event)
          # Handle ping/keepalive events (comments that start with :)
          return if raw_event[:data].nil? && raw_event[:event].nil?

          if raw_event[:event] == "endpoint"
            request_id = "endpoint"
            event = raw_event[:data]
          else
            # Skip empty or comment-only events
            return if raw_event[:data].nil? || raw_event[:data].strip.empty?
            
            event = begin
              JSON.parse(raw_event[:data])
            rescue StandardError => e
              log "JSON parse error: #{e.message} for data: #{raw_event[:data]&.slice(0, 100)}"
              nil
            end
            return if event.nil?

            request_id = event["id"]&.to_s
            log "Received event for request ID: #{request_id}"
          end

          @pending_mutex.synchronize do
            if request_id && @pending_requests.key?(request_id)
              response_queue = @pending_requests.delete(request_id)
              log "Matched response to pending request #{request_id}"
              response_queue&.push(event)
            else
              log "No pending request found for ID #{request_id}. Pending: #{@pending_requests.keys}"
            end
          end
        rescue JSON::ParserError => e
          log "Error parsing event data: #{e.message}"
        end

        def extract_event(buffer)
          # Legacy method for compatibility - delegates to new parsing
          return nil unless buffer.include?("\n\n")
          
          event_text, rest = buffer.split("\n\n", 2)
          return [nil, rest || ""] if event_text.strip.empty?
          
          parsed = parse_sse_event(event_text)
          [parsed, rest || ""]
        end

        def parse_event(raw)
          # Legacy method for compatibility - delegates to new parsing
          parse_sse_event(raw)
        end
      end
    end
  end
end