# frozen_string_literal: true

require "json"
require "uri"
require "net/http"
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
          @http_connection = nil

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

          # Send the request using Net::HTTP
          begin
            uri = URI(@messages_url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true if uri.scheme == 'https'
            http.open_timeout = 5
            http.read_timeout = 30

            request = Net::HTTP::Post.new(uri)
            @headers.each do |key, value|
              request[key] = value
            end
            request['Content-Type'] = 'application/json'
            request.body = JSON.generate(body)

            response = http.request(request)

            unless response.code == '200'
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
              response_queue.pop
            end
          rescue Timeout::Error
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            raise RubyLLM::MCP::Errors::TimeoutError.new(message: "Request timed out after 30 seconds")
          end
        end

        def close
          @running = false
          @http_connection&.finish if @http_connection&.started?
          @sse_thread&.join(1)
          @sse_thread = nil
        end

        private

        def wait_for_endpoints
          @endpoints_mutex.synchronize do
            @endpoints_condition.wait(@endpoints_mutex, 15) until @endpoints_ready || !@running
          end
          raise "Failed to get endpoints from ninja.ai" unless @endpoints_ready
        end

        def start_sse_listener
          @connection_mutex.synchronize do
            return if sse_thread_running?

            @sse_thread = Thread.new do
              begin
                establish_persistent_connection
              rescue => e
                puts "SSE connection error: #{e.message}"
                puts e.backtrace.first(3) if e.backtrace
              ensure
                @http_connection&.finish if @http_connection&.started?
              end
            end

            @sse_thread.abort_on_exception = false
          end
        end

        def sse_thread_running?
          @sse_thread && @sse_thread.alive?
        end

        def establish_persistent_connection
          uri = URI(@connection_url)
          
          @http_connection = Net::HTTP.new(uri.host, uri.port)
          @http_connection.use_ssl = true if uri.scheme == 'https'
          @http_connection.open_timeout = 10
          @http_connection.read_timeout = 300
          @http_connection.keep_alive_timeout = 300
          
          @http_connection.start

          request = Net::HTTP::Get.new(uri.path + (uri.query ? "?#{uri.query}" : ""))
          @headers.each do |key, value|
            request[key] = value
          end

          @http_connection.request(request) do |response|
            unless response.code == '200'
              raise "SSE connection failed: #{response.code} - #{response.message}"
            end

            buffer = ""
            response.read_body do |chunk|
              break unless @running
              
              buffer << chunk
              
              # Process complete events
              while buffer.include?("\n\n")
                event_data, buffer = buffer.split("\n\n", 2)
                event = parse_sse_event(event_data)
                process_event(event) if event && !event.empty?
              end
            end
          end
        rescue => e
          if @running
            puts "Connection lost: #{e.message}. Reconnecting in 3 seconds..."
            sleep 3
            retry
          end
        end

        def process_event(event)
          case event[:event]
          when "session"
            @session_id = event[:data]&.strip
            puts "Ninja.ai session established: #{@session_id}"
          when "endpoint"
            @messages_url = event[:data]&.strip
            puts "Ninja.ai endpoint received: #{@messages_url}"
            @endpoints_mutex.synchronize do
              @endpoints_ready = true
              @endpoints_condition.broadcast
            end
          else
            # Handle MCP response messages (JSON-RPC responses)
            return unless event[:data]
            
            begin
              event_data = JSON.parse(event[:data])
              request_id = event_data["id"]&.to_s

              @pending_mutex.synchronize do
                if request_id && @pending_requests.key?(request_id)
                  response_queue = @pending_requests.delete(request_id)
                  response_queue&.push(event_data)
                end
              end
            rescue JSON::ParserError
              # Not JSON, might be plain text response - ignore
            end
          end
        end

        def parse_sse_event(event_data)
          event = {}
          
          event_data.each_line do |line|
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