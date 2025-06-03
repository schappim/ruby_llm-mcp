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
            @endpoints_condition.wait(@endpoints_mutex, 10) until @endpoints_ready || !@running
          end
          raise "Failed to get endpoints from ninja.ai" unless @endpoints_ready
        end

        def start_sse_listener
          @connection_mutex.synchronize do
            return if sse_thread_running?

            @sse_thread = Thread.new do
              begin
                listen_for_events
              rescue => e
                puts "SSE listener error: #{e.message}"
                # Don't exit the thread, keep it alive
                sleep 1
                retry if @running
              end
            end

            @sse_thread.abort_on_exception = false
          end
        end

        def sse_thread_running?
          @sse_thread && @sse_thread.alive?
        end

        def listen_for_events
          while @running
            begin
              stream_events_from_server
            rescue Faraday::Error => e
              handle_connection_error("SSE connection failed", e)
            rescue StandardError => e
              handle_connection_error("SSE connection error", e)
            end
          end
        end

        def stream_events_from_server
          buffer = +""
          
          conn = Faraday.new do |f|
            f.options.timeout = 300 # 5 minutes
            f.options.open_timeout = 10
          end

          conn.get(@connection_url) do |req|
            @headers.each do |key, value|
              req.headers[key] = value
            end
            
            req.options.on_data = proc do |chunk, _size, _env|
              return unless @running
              
              buffer << chunk
              
              while (event_data = extract_complete_event(buffer))
                event, buffer = event_data
                process_event(event) if event && event[:data]
              end
            end
          end
        end

        def handle_connection_error(message, error)
          puts "#{message}: #{error.message}"
          return unless @running
          
          puts "Reconnecting in 3 seconds..."
          sleep 3
        end

        def process_event(raw_event)
          return unless raw_event[:data]

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
            # Handle MCP response messages (JSON-RPC responses)
            begin
              event_data = JSON.parse(raw_event[:data])
              request_id = event_data["id"]&.to_s

              @pending_mutex.synchronize do
                if request_id && @pending_requests.key?(request_id)
                  response_queue = @pending_requests.delete(request_id)
                  response_queue&.push(event_data)
                end
              end
            rescue JSON::ParserError
              # Not JSON, might be plain text response - ignore or log
            end
          end
        end

        def extract_complete_event(buffer)
          return nil unless buffer.include?("\n\n")

          event_raw, remaining = buffer.split("\n\n", 2)
          event = parse_sse_event(event_raw)
          
          [event, remaining]
        end

        def parse_sse_event(raw)
          event = {}
          
          raw.each_line do |line|
            line = line.strip
            next if line.empty?
            
            case line
            when /^data:\s*(.*)$/
              (event[:data] ||= []) << $1
            when /^event:\s*(.*)$/
              event[:event] = $1
            when /^id:\s*(.*)$/
              event[:id] = $1
            when /^retry:\s*(.*)$/
              event[:retry] = $1.to_i
            end
          end
          
          event[:data] = event[:data]&.join("\n") if event[:data]
          event
        end
      end
    end
  end
end