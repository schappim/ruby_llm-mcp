# frozen_string_literal: true

require "json"
require "uri"
require "faraday"
require "timeout"
require "securerandom"

module RubyLLM
  module MCP
    module Transport
      class NinjaSSE
        attr_reader :headers, :id, :session_id, :messages_url

        def initialize(connection_url, headers: {})
          @connection_url = connection_url
          @session_id = nil
          @messages_url = nil
          @client_id = SecureRandom.uuid
          @headers = headers.merge({
                                     "Accept" => "text/event-stream",
                                     "Cache-Control" => "no-cache",
                                     "Connection" => "keep-alive",
                                     "X-CLIENT-ID" => @client_id
                                   })

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

          # Start the SSE listener thread and wait for endpoints
          start_sse_listener
          wait_for_endpoints
        end

        def request(body, wait_for_response: true)
          raise "Messages URL not available" unless @messages_url

          # Generate a unique request ID
          @id_mutex.synchronize { @id_counter += 1 }
          request_id = @id_counter
          body["id"] = request_id

          # Create a queue for this request's response
          response_queue = Queue.new
          if wait_for_response
            @pending_mutex.synchronize do
              @pending_requests[request_id.to_s] = response_queue
            end
          end

          # Send the request using Faraday
          begin
            conn = Faraday.new do |f|
              f.options.timeout = 30
              f.options.open_timeout = 5
            end

            response = conn.post(@messages_url) do |req|
              @headers.each do |key, value|
                req.headers[key] = value
              end
              req.headers["Content-Type"] = "application/json"
              req.body = JSON.generate(body)
            end

            unless response.status == 200
              @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
              raise "Failed to request #{@messages_url}: #{response.status} - #{response.body}"
            end
          rescue StandardError => e
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            raise e
          end
          return unless wait_for_response

          begin
            Timeout.timeout(30) do
              response_queue.pop
            end
          rescue Timeout::Error
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            raise RubyLLM::MCP::Errors::TimeoutError.new(message: "Request timed out after 30 seconds")
          end
        end

        def close
          @running = false
          @sse_thread&.join(1) # Give the thread a second to clean up
          @sse_thread = nil
        end

        private

        def wait_for_endpoints
          @endpoints_mutex.synchronize do
            @endpoints_condition.wait(@endpoints_mutex) until @endpoints_ready
          end
        end

        def start_sse_listener
          @connection_mutex.synchronize do
            return if sse_thread_running?

            @sse_thread = Thread.new do
              listen_for_events while @running
            end

            @sse_thread.abort_on_exception = true
          end
        end

        def sse_thread_running?
          @sse_thread && @sse_thread.alive?
        end

        def listen_for_events
          stream_events_from_server
        rescue Faraday::Error => e
          handle_connection_error("SSE connection failed", e)
        rescue StandardError => e
          handle_connection_error("SSE connection error", e)
        end

        def stream_events_from_server
          buffer = +""
          create_sse_connection.get(@connection_url) do |req|
            setup_request_headers(req)
            setup_streaming_callback(req, buffer)
          end
        end

        def create_sse_connection
          Faraday.new do |f|
            f.options.timeout = 300 # 5 minutes
            f.response :raise_error # raise errors on non-200 responses
          end
        end

        def setup_request_headers(request)
          @headers.each do |key, value|
            request.headers[key] = value
          end
        end

        def setup_streaming_callback(request, buffer)
          request.options.on_data = proc do |chunk, _size, _env|
            buffer << chunk
            process_buffer_events(buffer)
          end
        end

        def process_buffer_events(buffer)
          while (event = extract_event(buffer))
            event_data, buffer = event
            process_event(event_data) if event_data
          end
        end

        def handle_connection_error(message, error)
          puts "#{message}: #{error.message}. Reconnecting in 3 seconds..."
          sleep 3
        end

        def process_event(raw_event)
          return if raw_event[:data].nil?

          case raw_event[:event]
          when "session"
            @session_id = raw_event[:data].strip
            puts "Ninja.ai session established: #{@session_id}"
          when "endpoint"
            @messages_url = raw_event[:data].strip
            puts "Ninja.ai endpoint received: #{@messages_url}"
            @endpoints_mutex.synchronize do
              @endpoints_ready = true
              @endpoints_condition.broadcast
            end
          else
            # Handle MCP response messages
            begin
              event = JSON.parse(raw_event[:data])
              request_id = event["id"]&.to_s

              @pending_mutex.synchronize do
                if request_id && @pending_requests.key?(request_id)
                  response_queue = @pending_requests.delete(request_id)
                  response_queue&.push(event)
                end
              end
            rescue JSON::ParserError => e
              puts "Error parsing event data: #{e.message}"
            end
          end
        end

        def extract_event(buffer)
          return nil unless buffer.include?("\n\n")

          raw, rest = buffer.split("\n\n", 2)
          [parse_event(raw), rest]
        end

        def parse_event(raw)
          event = {}
          raw.each_line do |line|
            case line
            when /^data:\s*(.*)/
              (event[:data] ||= []) << ::Regexp.last_match(1)
            when /^event:\s*(.*)/
              event[:event] = ::Regexp.last_match(1)
            when /^id:\s*(.*)/
              event[:id] = ::Regexp.last_match(1)
            end
          end
          event[:data] = event[:data]&.join("\n")
          event
        end
      end
    end
  end
end