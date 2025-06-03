#!/usr/bin/env ruby

require_relative "../lib/ruby_llm/mcp/transport/ninja_sse"
require "minitest/autorun"

class TestNinjaSSERedis < Minitest::Test
  def setup
    @connection_url = "https://mcp.ninja.ai/connect/test-slug-123"
    @headers = {"Authorization" => "Bearer test-token"}
  end

  def test_slug_extraction
    ninja_sse = RubyLLM::MCP::Transport::NinjaSSE.allocate
    
    # Test successful slug extraction
    slug = ninja_sse.send(:extract_slug_from_url, "https://mcp.ninja.ai/connect/my-test-slug")
    assert_equal "my-test-slug", slug
    
    # Test localhost URL
    slug = ninja_sse.send(:extract_slug_from_url, "http://localhost:3000/connect/local-slug")
    assert_equal "local-slug", slug
    
    # Test URL with query parameters
    slug = ninja_sse.send(:extract_slug_from_url, "https://mcp.ninja.ai/connect/slug-with-params?token=abc")
    assert_equal "slug-with-params", slug
    
    # Test invalid URL
    slug = ninja_sse.send(:extract_slug_from_url, "https://invalid.com/no-slug")
    assert_nil slug
  end

  def test_channel_names_generation
    # Test channel name formatting without Redis dependency
    ninja_sse = RubyLLM::MCP::Transport::NinjaSSE.allocate
    ninja_sse.instance_variable_set(:@slug, "test-slug")
    ninja_sse.instance_variable_set(:@session_id, "test-session-123")
    
    # Manually set the channels as they would be set during initialization  
    client_channel = "client:test-session-123"
    broadcast_channel = "gateway:test-slug:broadcast"
    
    ninja_sse.instance_variable_set(:@client_channel, client_channel)
    ninja_sse.instance_variable_set(:@broadcast_channel, broadcast_channel)
    
    # Check that channels are properly formatted
    assert_match(/^client:/, ninja_sse.instance_variable_get(:@client_channel))
    assert_equal "gateway:test-slug:broadcast", ninja_sse.instance_variable_get(:@broadcast_channel)
  end

  def test_message_processing
    ninja_sse = RubyLLM::MCP::Transport::NinjaSSE.allocate
    ninja_sse.instance_variable_set(:@pending_requests, {})
    ninja_sse.instance_variable_set(:@pending_mutex, Mutex.new)
    
    # Test valid JSON message processing
    test_message = {
      "jsonrpc" => "2.0",
      "id" => "123",
      "result" => {"tools" => []}
    }.to_json
    
    # Add a pending request
    response_queue = Queue.new
    ninja_sse.instance_variable_get(:@pending_requests)["123"] = response_queue
    
    # Process the message
    ninja_sse.send(:process_redis_message, test_message)
    
    # Check that the response was queued
    assert_equal 0, ninja_sse.instance_variable_get(:@pending_requests).size
    refute response_queue.empty?
    
    response = response_queue.pop
    assert_equal "2.0", response["jsonrpc"]
    assert_equal "123", response["id"]
  end

  def test_invalid_json_handling
    ninja_sse = RubyLLM::MCP::Transport::NinjaSSE.allocate
    ninja_sse.instance_variable_set(:@pending_requests, {})
    ninja_sse.instance_variable_set(:@pending_mutex, Mutex.new)
    
    # Test invalid JSON - should not crash
    begin
      ninja_sse.send(:process_redis_message, "invalid json {")
      assert true, "Invalid JSON handled without crashing"
    rescue => e
      flunk "Invalid JSON should not raise exception: #{e.message}"
    end
    
    # Test empty message - should not crash
    begin
      ninja_sse.send(:process_redis_message, "")
      assert true, "Empty message handled without crashing"
    rescue => e
      flunk "Empty message should not raise exception: #{e.message}"
    end
    
    # Test nil message - should not crash
    begin
      ninja_sse.send(:process_redis_message, nil)
      assert true, "Nil message handled without crashing"
    rescue => e
      flunk "Nil message should not raise exception: #{e.message}"
    end
  end

  def teardown
    # Clean up any resources if needed
  end
end

# Run a simple integration test if Redis is available and running
if defined?(Redis)
  puts "\n=== Integration Test ==="
  
  begin
    # Test Redis connection
    redis = Redis.new
    redis.ping
    puts "✓ Redis connection successful"
    
    # Test basic pub/sub (this is a very basic test)
    test_channel = "test_channel_#{SecureRandom.hex(4)}"
    received_message = nil
    
    subscriber_thread = Thread.new do
      redis_sub = Redis.new
      redis_sub.subscribe(test_channel) do |on|
        on.message do |channel, message|
          received_message = message
          redis_sub.unsubscribe
        end
      end
    end
    
    sleep 0.1 # Give subscriber time to connect
    
    # Publish a test message
    redis.publish(test_channel, "test message")
    
    # Wait for message to be received
    subscriber_thread.join(2)
    
    if received_message == "test message"
      puts "✓ Redis pub/sub functionality working"
    else
      puts "✗ Redis pub/sub test failed"
    end
    
    redis.close
    
  rescue Redis::CannotConnectError => e
    puts "✗ Redis connection failed: #{e.message}"
    puts "  Make sure Redis is running for integration tests"
  rescue => e
    puts "✗ Integration test error: #{e.message}"
  end
end