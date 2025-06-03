# Redis-based NinjaSSE Transport

This document describes the Redis-based implementation of the NinjaSSE transport for the Ruby LLM MCP client.

## Overview

The NinjaSSE transport has been modified to use Redis pub/sub instead of HTTP Server-Sent Events (SSE). This allows the transport to work directly with the MCP server's Redis-based architecture, eliminating the need for HTTP connections and improving performance.

## Key Changes from HTTP SSE

### Before (HTTP SSE)
- Connected to HTTP endpoint with SSE streaming
- Parsed SSE event format (`data:`, `event:`, `id:` fields)
- Maintained persistent HTTP connection
- Required network connectivity to SSE endpoint

### After (Redis)
- Connects directly to Redis server
- Uses Redis pub/sub for real-time communication
- No HTTP overhead or connection management
- Works with both development (redis gem) and production (async-redis) setups

## Architecture

### Channel Structure
The transport uses three main Redis channels:

1. **Request Channel**: `tool_requests`
   - All client requests are published here
   - Consumed by the Tool Dispatcher

2. **Client Channel**: `client:{session_id}`
   - Responses specific to this client session
   - Includes tool results and progress notifications

3. **Broadcast Channel**: `gateway:{slug}:broadcast`
   - Gateway-wide notifications (e.g., tools/list_changed)
   - Shared across all clients for the same gateway

### Session Management
- Session ID is auto-generated using `SecureRandom.uuid`
- Slug is extracted from the connection URL
- No need to wait for server-provided session/endpoint information

## Usage

### Basic Initialization
```ruby
require "ruby_llm/mcp/transport/ninja_sse"

# Initialize with connection URL containing slug
transport = RubyLLM::MCP::Transport::NinjaSSE.new(
  "https://mcp.ninja.ai/connect/your-gateway-slug",
  headers: {"Authorization" => "Bearer your-token"}
)
```

### Making Requests
```ruby
# Synchronous request (waits for response)
response = transport.request({
  "method" => "tools/list",
  "params" => {}
}, wait_for_response: true)

# Asynchronous request (fire-and-forget)
transport.request({
  "method" => "notifications/initialized",
  "params" => {}
}, wait_for_response: false)
```

## Configuration

### Development Environment
Uses the standard `redis` gem with default connection settings:
```ruby
Redis.new  # Connects to localhost:6379
```

### Production Environment
Uses `async-redis` with URL from environment:
```ruby
redis_url = ENV.fetch("REDIS_URL")
endpoint = Async::Redis::Endpoint.parse(redis_url)
client = Async::Redis::Client.new(endpoint)
```

## URL Format and Slug Extraction

The transport expects connection URLs in this format:
- `https://mcp.ninja.ai/connect/SLUG`
- `http://localhost:3000/connect/SLUG`
- `https://domain.com/connect/SLUG?additional=params`

The slug is extracted using regex: `/\/connect\/([^/?]+)/`

## Request Flow

1. **Client Request**:
   - Generate unique request ID
   - Add session metadata (client_channel, session_id, slug)
   - Publish to `tool_requests` channel

2. **Server Processing**:
   - Tool Dispatcher receives request
   - Processes tool/prompt/resource request
   - Publishes response to client's channel

3. **Client Response**:
   - Redis listener receives response on client channel
   - Matches response ID to pending request
   - Returns response to caller

## Error Handling

### Connection Errors
- Redis connection failures raise descriptive errors
- Automatic retry logic for transient connection issues
- Graceful degradation when Redis is unavailable

### Message Processing
- Invalid JSON messages are logged but don't crash the transport
- Missing request IDs are handled gracefully
- Timeout protection for long-running requests (30 seconds)

## Dependencies

### Required Gems
```ruby
# Development
gem 'redis'

# Production  
gem 'async-redis'

# Always required
gem 'json'
gem 'securerandom'
```

### Environment Variables
```bash
# Production only
REDIS_URL=redis://default:password@host:port/database

# Environment detection
RAILS_ENV=production  # or RACK_ENV=production
```

## Testing

Run the test suite:
```bash
ruby test/test_ninja_sse_redis.rb
```

### Test Coverage
- Slug extraction from various URL formats
- Channel name generation
- Request payload formatting
- Message processing and queuing
- Error handling for invalid JSON
- Integration test with live Redis (if available)

## Debugging

Enable debug output by monitoring the console. The transport provides detailed logging:

```
[NinjaSSE] Initializing with Redis-based transport
[NinjaSSE] Generated session ID: abc123-def456
[NinjaSSE] Extracted slug: my-gateway
[NinjaSSE] Redis connection established
[NinjaSSE] Request published successfully (1 subscribers)
[NinjaSSE] [Thread] Received client message: {"jsonrpc":"2.0",...}
```

## Migration from HTTP SSE

To migrate existing code:

1. **Update Dependencies**: Ensure Redis gems are available
2. **Environment Setup**: Configure REDIS_URL for production
3. **No Code Changes**: The public API remains identical
4. **Test Connectivity**: Verify Redis server is accessible

The transport maintains full backward compatibility with the existing NinjaSSE interface while providing improved performance and reliability through Redis.