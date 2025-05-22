# frozen_string_literal: true

require "open3"
require "json"
require "timeout"
require "securerandom"

module RubyLLM
  module MCP
    module Transport
      class Stdio
        attr_reader :command, :stdin, :stdout, :stderr, :id

        def initialize(command, args: [], env: {})
          @command = command
          @args = args
          @env = env
          @client_id = SecureRandom.uuid

          # Initialize state variables
          @id_counter = 0
          @id_mutex = Mutex.new
          @pending_requests = {}
          @pending_mutex = Mutex.new
          @running = true
          @reader_thread = nil

          # Start the process
          start_process
        end

        def request(body, wait_for_response: true)
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

          # Send the request to the process
          begin
            @stdin.puts(JSON.generate(body))
            @stdin.flush
          rescue IOError, Errno::EPIPE => e
            @pending_mutex.synchronize { @pending_requests.delete(request_id.to_s) }
            restart_process
            raise "Failed to send request: #{e.message}"
          end

          return unless wait_for_response

          # Wait for the response with matching ID using a timeout
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

          # Close stdin to signal the process to exit
          begin
            @stdin&.close
          rescue StandardError
            nil
          end

          # Wait for process to exit
          begin
            @wait_thread&.join(1)
          rescue StandardError
            nil
          end

          # Close remaining IO streams
          begin
            @stdout&.close
          rescue StandardError
            nil
          end
          begin
            @stderr&.close
          rescue StandardError
            nil
          end

          # Wait for reader thread to finish
          begin
            @reader_thread&.join(1)
          rescue StandardError
            nil
          end

          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thread = nil
          @reader_thread = nil
        end

        private

        def start_process
          # Close any existing process
          close if @stdin || @stdout || @stderr || @wait_thread

          # Start a new process
          @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env, @command, *@args)

          # Start a thread to read responses
          start_reader_thread
        end

        def restart_process
          puts "Process connection lost. Restarting..."
          start_process
        end

        def start_reader_thread
          @reader_thread = Thread.new do
            while @running
              begin
                if @stdout.closed? || @wait_thread.nil? || !@wait_thread.alive?
                  sleep 1
                  restart_process if @running
                  next
                end

                # Read a line from the process
                line = @stdout.gets

                # Skip empty lines
                next unless line && !line.strip.empty?

                # Process the response
                process_response(line.strip)
              rescue IOError, Errno::EPIPE => e
                puts "Reader error: #{e.message}. Restarting in 1 second..."
                sleep 1
                restart_process if @running
              rescue StandardError => e
                puts "Error in reader thread: #{e.message}, #{e.backtrace.join("\n")}"
                sleep 1
              end
            end
          end

          @reader_thread.abort_on_exception = true
        end

        def process_response(line)
          # Try to parse the response as JSON
          response = begin
            JSON.parse(line)
          rescue JSON::ParserError => e
            puts "Error parsing response as JSON: #{e.message}"
            puts "Raw response: #{line}"
            return
          end

          # Extract the request ID
          request_id = response["id"]&.to_s

          # Find and fulfill the matching request
          @pending_mutex.synchronize do
            if request_id && @pending_requests.key?(request_id)
              response_queue = @pending_requests.delete(request_id)
              response_queue&.push(response)
            end
          end
        end
      end
    end
  end
end
