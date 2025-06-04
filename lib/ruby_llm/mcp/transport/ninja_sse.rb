# frozen_string_literal: true

require "json"
require "securerandom"
require "timeout"

begin
  require "redis"
rescue LoadError
  # Redis gem not available in development
end

begin
  require "async/redis"
rescue LoadError
  # Async-redis not available
end

module RubyLLM
  module MCP
    module Transport
      class NinjaSSE
        attr_reader :headers, :id, :session_id, :messages_url

        def initialize(connection_url, headers: {})
          puts "[NinjaSSE] Initializing with Redis-based transport"
          puts "[NinjaSSE] Connection URL: #{connection_url} (will extract slug)"
          puts "[NinjaSSE] Headers: #{headers.inspect}"

          # Extract slug from connection_url
          # Expected format: https://mcp.ninja.ai/connect/SLUG
          @slug = extract_slug_from_url(connection_url)
          raise "Could not extract slug from URL: #{connection_url}" unless @slug

          @client_id = SecureRandom.uuid
          @session_id = SecureRandom.uuid
          @headers = headers.merge({
                                     "Accept" => "text/event-stream",
                                     "Cache-Control" => "no-cache",
                                     "Connection" => "keep-alive",
                                     "Accept-Encoding" => "identity",
                                     "X-CLIENT-ID" => @client_id
                                   })

          puts "[NinjaSSE] Generated session ID: #{@session_id}"
          puts "[NinjaSSE] Extracted slug: #{@slug}"
          puts "[NinjaSSE] Client ID: #{@client_id}"

          # Initialize Redis connection
          initialize_redis_connection

          @id_counter = 0
          @id_mutex = Mutex.new
          @pending_requests = {}
          @pending_mutex = Mutex.new
          @running = true

          # Define Redis channels
          @request_channel = "tool_requests"
          @client_channel = "client:#{@session_id}"
          @broadcast_channel = "gateway:#{@slug}:broadcast"

          # Set messages_url (for compatibility with existing interface)
          @messages_url = "redis://internal/message?session_id=#{@session_id}&slug=#{@slug}"

          puts "[NinjaSSE] Starting Redis listener thread..."
          start_redis_listener
          puts "[NinjaSSE] Initialization complete!"
        end

        def request(body, wait_for_response: true)
          puts "[NinjaSSE] Making request with body: #{body.inspect}"
          puts "[NinjaSSE] Wait for response: #{wait_for_response}"

          # Generate a unique request ID
          @id_mutex.synchronize { @id_counter += 1 }
          request_id = @id_counter
          body["id"] = request_id

          puts "[NinjaSSE] Request ID: #{request_id}"

          # Create a queue for this request's response
          response_queue = Queue.new
          if wait_for_response
            @pending_mutex.synchronize do
              @pending_requests[request_id.to_s] = response_queue
            end
            puts "[NinjaSSE] Added request #{request_id} to pending requests"
          end

          # Prepare request payload for Redis
          begin
            request_payload = body.merge(
              "client_channel" => @client_channel,
              "session_id" => @session_id,
              "slug" => @slug
            )

            # For synchronous requests that need immediate response, add response channel
            if wait_for_response && ["tools/list", "prompts/list", "prompts/get"].include?(body["method"])
              response_channel = "response:#{SecureRandom.uuid}"
              request_payload["response_channel"] = response_channel
            end

            puts "[NinjaSSE] Publishing request to Redis channel: #{@request_channel}"
            puts "[NinjaSSE] Request payload: #{request_payload.inspect}"

            # Publish request to Redis
            result = @redis.publish(@request_channel, JSON.generate(request_payload))
            puts "[NinjaSSE] Request published successfully (#{result} subscribers)"
          rescue StandardError => e
            puts "[NinjaSSE] Redis publish failed: #{e.message}"
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
          puts "[NinjaSSE] Closing Redis connection..."
          @running = false

          # Stop the Redis thread
          if @redis_thread&.alive?
            @redis_thread.join(2) # Wait up to 2 seconds
            if @redis_thread.alive?
              puts "[NinjaSSE] Force terminating Redis thread..."
              @redis_thread.kill
            end
          end
          @redis_thread = nil

          # Close Redis connection
          begin
            @redis&.close
          rescue StandardError => e
            puts "[NinjaSSE] Error closing Redis connection: #{e.message}"
          end

          puts "[NinjaSSE] Connection closed"
        end

        private

        def extract_slug_from_url(url)
          # Extract slug from URLs like:
          # https://mcp.ninja.ai/connect/SLUG
          # http://localhost:3000/connect/SLUG
          match = url.match(%r{/connect/([^/?]+)})
          match ? match[1] : nil
        end

        def initialize_redis_connection
          puts "[NinjaSSE] Initializing Redis connection..."

          begin
            if ENV["RACK_ENV"] == "production" || ENV["RAILS_ENV"] == "production"
              puts "[NinjaSSE] Using production Redis configuration"
              raise "async-redis gem not available" unless defined?(Async::Redis)

              redis_url = ENV.fetch("REDIS_URL") { raise "REDIS_URL environment variable not set" }
              endpoint = Async::Redis::Endpoint.parse(redis_url)
              @redis = Async::Redis::Client.new(endpoint)
            else
              puts "[NinjaSSE] Using development Redis configuration"
              raise "redis gem not available" unless defined?(Redis)

              @redis = Redis.new
            end

            puts "[NinjaSSE] Redis connection established"
          rescue StandardError => e
            puts "[NinjaSSE] ERROR: Failed to initialize Redis connection: #{e.message}"
            raise "Redis connection failed: #{e.message}"
          end
        end

        def start_redis_listener
          return if @redis_thread&.alive?

          puts "[NinjaSSE] Creating Redis listener thread..."
          @redis_thread = Thread.new do
            puts "[NinjaSSE] [Thread] Redis listener thread started"
            begin
              establish_redis_subscriptions
            rescue StandardError => e
              puts "[NinjaSSE] [Thread] Redis subscription error: #{e.message}"
              puts "[NinjaSSE] [Thread] Backtrace: #{e.backtrace.first(5).join("\n")}" if e.backtrace
            ensure
              puts "[NinjaSSE] [Thread] Redis listener thread ending"
            end
          end

          @redis_thread.abort_on_exception = false
          puts "[NinjaSSE] Redis listener thread created"
        end

        def establish_redis_subscriptions
          puts "[NinjaSSE] [Thread] Establishing Redis subscriptions..."
          puts "[NinjaSSE] [Thread] Client channel: #{@client_channel}"
          puts "[NinjaSSE] [Thread] Broadcast channel: #{@broadcast_channel}"

          begin
            # Check if we're using async-redis or regular redis gem
            if defined?(Async::Redis) && @redis.is_a?(Async::Redis::Client)
              # Using async-redis (production)
              puts "[NinjaSSE] [Thread] Using async-redis subscription method"
              subscribe_async_redis
            elsif defined?(Redis) && @redis.is_a?(Redis)
              # Using redis gem (development)
              puts "[NinjaSSE] [Thread] Using redis gem subscription method"
              subscribe_redis_gem
            else
              raise "Unknown Redis client type: #{@redis.class}"
            end
          rescue StandardError => e
            puts "[NinjaSSE] [Thread] ERROR: Failed to establish subscriptions: #{e.message}"
            puts "[NinjaSSE] [Thread] Backtrace: #{e.backtrace.first(5).join("\n")}"
            raise e
          end
        end

        def subscribe_async_redis
          puts "[NinjaSSE] [Thread] Using async-redis subscription"

          # For async-redis, we need to use the reactor pattern
          require "async/reactor"

          Async::Reactor.run do |task|
            # Subscribe to both channels in parallel
            client_task = task.async do
              puts "[NinjaSSE] [Thread] Starting client channel subscription"
              @redis.subscribe(@client_channel) do |context|
                context.each do |_type, _name, message|
                  break unless @running

                  puts "[NinjaSSE] [Thread] Received client message: #{message}"
                  process_redis_message(message)
                end
              end
            rescue StandardError => e
              puts "[NinjaSSE] [Thread] Client subscription error: #{e.message}"
            end

            broadcast_task = task.async do
              puts "[NinjaSSE] [Thread] Starting broadcast channel subscription"
              @redis.subscribe(@broadcast_channel) do |context|
                context.each do |_type, _name, message|
                  break unless @running

                  puts "[NinjaSSE] [Thread] Received broadcast message: #{message}"
                  process_redis_message(message)
                end
              end
            rescue StandardError => e
              puts "[NinjaSSE] [Thread] Broadcast subscription error: #{e.message}"
            end

            # Wait for both subscriptions
            client_task.wait
            broadcast_task.wait
          end
        end

        def subscribe_redis_gem
          puts "[NinjaSSE] [Thread] Using redis gem subscription"

          begin
            @redis.subscribe(@client_channel, @broadcast_channel) do |on|
              on.message do |channel, message|
                break unless @running

                puts "[NinjaSSE] [Thread] Received message on #{channel}: #{message}"
                process_redis_message(message)
              end

              on.subscribe do |channel, subscriptions|
                puts "[NinjaSSE] [Thread] Subscribed to #{channel} (#{subscriptions} total subscriptions)"
              end

              on.unsubscribe do |channel, subscriptions|
                puts "[NinjaSSE] [Thread] Unsubscribed from #{channel} (#{subscriptions} total subscriptions)"
              end
            end
          rescue Redis::BaseConnectionError => e
            puts "[NinjaSSE] [Thread] Redis connection error: #{e.message}"
            if @running
              puts "[NinjaSSE] [Thread] Attempting to reconnect in 3 seconds..."
              sleep 0.1
              retry
            end
          rescue StandardError => e
            puts "[NinjaSSE] [Thread] Unexpected subscription error: #{e.message}"
            puts "[NinjaSSE] [Thread] Backtrace: #{e.backtrace.first(3).join("\n")}"
            raise e
          end
        end

        def process_redis_message(message)
          return unless message && !message.empty?

          puts "[NinjaSSE] [Thread] Processing Redis message: #{message.inspect}"

          begin
            parsed_message = JSON.parse(message)
            puts "[NinjaSSE] [Thread] Parsed message: #{parsed_message.inspect}"

            request_id = parsed_message["id"]&.to_s
            puts "[NinjaSSE] [Thread] Looking for pending request with ID: #{request_id}"

            @pending_mutex.synchronize do
              puts "[NinjaSSE] [Thread] Current pending requests: #{@pending_requests.keys.inspect}"
              if request_id && @pending_requests.key?(request_id)
                response_queue = @pending_requests.delete(request_id)
                puts "[NinjaSSE] [Thread] Found matching request, pushing response to queue"
                response_queue&.push(parsed_message)
              else
                puts "[NinjaSSE] [Thread] No matching pending request found"
              end
            end
          rescue JSON::ParserError => e
            puts "[NinjaSSE] [Thread] Failed to parse JSON: #{e.message}"
            puts "[NinjaSSE] [Thread] Raw message was: #{message.inspect}"
          rescue StandardError => e
            puts "[NinjaSSE] [Thread] Error processing message: #{e.message}"
            puts "[NinjaSSE] [Thread] Backtrace: #{e.backtrace.first(3).join("\n")}"
          end
        end
      end
    end
  end
end
