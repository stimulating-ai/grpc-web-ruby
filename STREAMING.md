# Server-Side Streaming Support

This document describes the server-side streaming functionality added to grpc-web-ruby.

## Overview

Server-side streaming allows a gRPC service to send multiple response messages for a single request. This is useful for scenarios like:

- Streaming large datasets
- Real-time updates
- Progress reporting
- Live data feeds

## Protocol Implementation

The implementation follows the [gRPC-Web protocol specification](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md) for streaming responses:

1. **Multiple Payload Frames**: Each response message is sent as a separate payload frame (frame type 0)
2. **Trailer Frame**: A final header frame (frame type 128) contains the gRPC status and metadata
3. **Trailer-Delimited Encoding**: The MSB of the frame type indicates data (0) vs trailers (1)

## Server Implementation

### 1. Define Streaming Proto

```protobuf
syntax = "proto3";

message StreamRequest {
  string name = 1;
  int32 count = 2;
}

message StreamResponse {
  string message = 1;
  int32 index = 2;
}

service StreamingService {
  rpc GetStream(StreamRequest) returns (stream StreamResponse);
}
```

### 2. Implement Streaming Service

```ruby
class MyStreamingService < StreamingService::Service
  def get_stream(request, _call = nil)
    # Return an Enumerator that yields multiple responses
    Enumerator.new do |yielder|
      request.count.times do |i|
        response = StreamResponse.new(
          message: "Hello #{request.name} - #{i + 1}",
          index: i + 1
        )
        yielder << response

        # Optional: add delays, database queries, etc.
        sleep(0.1)
      end
    end
  end
end
```

### 3. Configure gRPC-Web Server

```ruby
require 'grpc_web'

# Register the streaming service
GRPCWeb.handle(MyStreamingService)

# Start the server (same as before)
Rack::Handler::WEBrick.run GRPCWeb.rack_app
```

## Client Implementation

### Ruby Client

```ruby
require 'grpc_web/client'

client = GRPCWeb::Client.new("http://localhost:3000/grpc", StreamingService::Service)

# Call streaming method - returns an Enumerator
stream = client.get_stream(name: 'Alice', count: 5)

# Iterate over streaming responses
stream.each do |response|
  puts "#{response.index}: #{response.message}"
end

# Or collect all responses
responses = stream.to_a
```

### JavaScript Client

```javascript
const client = new StreamingServiceClient('http://localhost:3000/grpc');

const request = new StreamRequest();
request.setName('Alice');
request.setCount(5);

const stream = client.getStream(request, {});

stream.on('data', (response) => {
  console.log(`${response.getIndex()}: ${response.getMessage()}`);
});

stream.on('end', () => {
  console.log('Stream ended');
});

stream.on('error', (err) => {
  console.error('Stream error:', err);
});
```

## Key Components

### 1. Streaming Response Processor (`StreamingResponseProcessor`)

Handles the execution of streaming RPC methods and creates `StreamingResponse` objects.

### 2. Streaming Message Serialization (`StreamingMessageSerialization`)

Converts streaming responses into properly framed gRPC-Web format with:

- Individual payload frames for each message
- Final trailer frame with status information

### 3. Streaming Response Encoder (`StreamingResponseEncoder`)

Creates Rack-compatible streaming responses that yield frames as they're generated.

### 4. RPC Type Detector (`RpcTypeDetector`)

Automatically detects whether an RPC method is streaming based on:

- Service descriptors (`output_streaming?` method)
- Response type heuristics (implements `each` but not protobuf message)

### 5. Streaming Client Executor (`StreamingClientExecutor`)

Handles client-side parsing of streaming responses:

- Separates payload frames from trailer frames
- Yields individual messages through an Enumerator
- Handles gRPC errors from trailer frames

## Error Handling

### Server-Side Errors

If an error occurs during streaming, an error trailer frame is sent:

```ruby
def get_stream(request, _call = nil)
  Enumerator.new do |yielder|
    begin
      # ... yield responses ...
      raise GRPC::InvalidArgument, "Something went wrong"
    rescue => e
      # Error will be sent as trailer frame automatically
      raise e
    end
  end
end
```

### Client-Side Error Handling

```ruby
begin
  stream = client.get_stream(name: 'Alice', count: 5)
  stream.each { |response| puts response.message }
rescue GRPC::InvalidArgument => e
  puts "Server error: #{e.message}"
rescue GRPC::Unavailable => e
  puts "Service unavailable: #{e.message}"
end
```

## Compatibility

### Backward Compatibility

- All existing unary RPC methods continue to work unchanged
- No breaking changes to existing APIs
- Automatic detection between unary and streaming methods

### Browser Support

- Works with all browsers that support gRPC-Web
- Uses standard HTTP/1.1 chunked transfer encoding
- Compatible with existing gRPC-Web proxies (Envoy, etc.)

### Text Encoding

Streaming responses support both binary and text-encoded formats:

- `application/grpc-web+proto` - Binary protobuf
- `application/grpc-web-text+proto` - Base64-encoded

## Performance Considerations

### Memory Usage

- Streaming responses are processed incrementally
- No need to buffer entire response in memory
- Each frame is sent as soon as it's available

### Network Efficiency

- Individual messages are sent immediately
- Reduces time-to-first-byte for large datasets
- HTTP/1.1 chunked encoding for optimal network usage

## Testing

### Unit Tests

```ruby
RSpec.describe MyStreamingService do
  it 'streams multiple responses' do
    service = MyStreamingService.new
    request = StreamRequest.new(name: 'Test', count: 3)

    stream = service.get_stream(request)
    responses = stream.to_a

    expect(responses.length).to eq(3)
    expect(responses.first.message).to include('Test')
  end
end
```

### Integration Tests

```ruby
RSpec.describe 'Streaming integration' do
  it 'handles streaming via HTTP' do
    # Start test server with streaming service
    # Make streaming request
    # Verify multiple responses received
  end
end
```

## Migration Guide

### From Unary to Streaming

1. **Update Proto Definition**: Add `stream` keyword to response
2. **Modify Service Method**: Return `Enumerator` instead of single response
3. **Update Client Code**: Handle `Enumerator` instead of single object

### Example Migration

**Before (Unary):**

```ruby
def get_data(request, _call = nil)
  DataResponse.new(items: fetch_all_items(request.query))
end
```

**After (Streaming):**

```ruby
def get_data(request, _call = nil)
  Enumerator.new do |yielder|
    fetch_items_streaming(request.query) do |item|
      yielder << DataResponse.new(items: [item])
    end
  end
end
```

## Limitations

### Current Limitations

1. **Server-side streaming only** - Client-side and bidirectional streaming not yet supported
2. **HTTP/1.1 only** - Optimized for HTTP/1.1, HTTP/2 support could be enhanced
3. **No flow control** - Basic streaming without backpressure mechanisms

### Future Enhancements

- Client-side streaming support
- Bidirectional streaming support
- Enhanced error recovery
- Flow control and backpressure
- WebSocket transport option

## Troubleshooting

### Common Issues

1. **"Method not streaming"**: Ensure proto uses `stream` keyword and service returns `Enumerator`
2. **"Connection timeout"**: Check that streaming method doesn't block indefinitely
3. **"Invalid frames"**: Verify protobuf serialization in streaming responses

### Debug Mode

Enable debug logging to see frame-level details:

```ruby
ENV['GRPC_WEB_DEBUG'] = 'true'
```

This will log:

- Frame types and sizes
- Trailer content
- Streaming detection results
