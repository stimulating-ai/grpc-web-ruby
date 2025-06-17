# Streaming Endpoint Troubleshooting Guide

## Problem: Streaming Endpoints Return 500 Errors

Based on comprehensive testing, the server-side streaming implementation is **working correctly**. The 500 errors are likely due to one of these common issues:

## ✅ Confirmed Working

- Core streaming implementation
- gRPC-Web frame serialization
- RPC type detection
- Message framing and encoding

## 🔍 Root Causes of 500 Errors

### 1. **Content-Type Headers** (Most Common)

**Issue**: Client not sending correct headers

```javascript
// ❌ Wrong - will cause 415/500 errors
fetch('/HelloService/SayHelloStream', {
  method: 'POST',
  body: requestData,
  // Missing Content-Type and Accept headers
});

// ✅ Correct - required headers
fetch('/HelloService/SayHelloStream', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/grpc-web+proto',
    Accept: 'application/grpc-web+proto',
  },
  body: requestData,
});
```

### 2. **Service Method Implementation**

**Issue**: Method not returning an Enumerator

```ruby
# ❌ Wrong - will cause 500 errors
def say_hello_stream(request, _call = nil)
  responses = []
  3.times { |i| responses << StreamResponse.new(message: "Hello #{i}") }
  responses  # Returns Array, not Enumerator
end

# ✅ Correct - must return Enumerator
def say_hello_stream(request, _call = nil)
  Enumerator.new do |yielder|
    3.times do |i|
      response = StreamResponse.new(message: "Hello #{i}")
      yielder << response
    end
  end
end
```

### 3. **Service Registration**

**Issue**: Streaming method not properly registered

```ruby
# ✅ Ensure your service class extends the correct base class
class YourService < YourProtoService::Service  # Must extend generated service
  def your_streaming_method(request, _call = nil)
    # Implementation
  end
end

# ✅ Proper registration
app = GRPCWeb::RackApp.new
app.handle(YourService)  # Register the class, not instance
```

### 4. **Protocol Buffer Definition**

**Issue**: Method not defined as streaming in .proto file

```protobuf
service YourService {
  // ❌ Wrong - unary method
  rpc YourMethod (Request) returns (Response);

  // ✅ Correct - streaming method
  rpc YourStreamingMethod (Request) returns (stream Response);
}
```

## 🛠️ Debugging Steps

### Step 1: Check Server Logs

Look for the actual error, not just the status code:

```ruby
# Add error logging to your service
def say_hello_stream(request, _call = nil)
  Rails.logger.info "Streaming method called with: #{request.inspect}"

  Enumerator.new do |yielder|
    begin
      # Your streaming logic
      count.times do |i|
        response = StreamResponse.new(message: "Hello #{i}")
        Rails.logger.info "Yielding response #{i}: #{response.message}"
        yielder << response
      end
    rescue => e
      Rails.logger.error "Streaming error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise
    end
  end
end
```

### Step 2: Test Content-Type Handling

```bash
# Test with curl to verify headers are processed correctly
curl -X POST http://localhost:3000/YourService/YourStreamingMethod \
  -H "Content-Type: application/grpc-web+proto" \
  -H "Accept: application/grpc-web+proto" \
  --data-binary @request.bin
```

### Step 3: Verify Service Registration

```ruby
# In Rails console or debug session
app = GRPCWeb::RackApp.new
app.handle(YourService)

# Check if the service has the streaming method
YourService.rpc_descs.each do |method_name, rpc_desc|
  puts "#{method_name}: streaming=#{rpc_desc.output_streaming?}"
end
```

### Step 4: Test Streaming Response Generation

```ruby
# Test your streaming method directly
service = YourService.new
request = YourRequest.new(name: 'test')
response_stream = service.your_streaming_method(request)

# Verify it returns an Enumerator
puts "Response class: #{response_stream.class}"
puts "Is Enumerator: #{response_stream.is_a?(Enumerator)}"

# Test iteration
response_stream.each_with_index do |response, i|
  puts "Response #{i}: #{response.inspect}"
  break if i > 2  # Safety limit
end
```

## 🚀 Working Example

Here's a complete working example:

```ruby
# your_service.rb
class YourStreamingService < YourProto::YourService::Service
  def say_hello_stream(request, _call = nil)
    count = request.count > 0 ? request.count : 3

    Enumerator.new do |yielder|
      count.times do |i|
        response = YourProto::StreamResponse.new(
          message: "Hello #{request.name} - Message #{i + 1}",
          index: i + 1
        )
        yielder << response

        # Optional: Add delay for demo
        sleep(0.1) if ENV['STREAMING_DELAY']
      end
    end
  end
end

# config/application.rb or initializer
app = GRPCWeb::RackApp.new
app.handle(YourStreamingService)
```

```javascript
// Client-side JavaScript
async function callStreamingMethod() {
  const request = new YourProto.StreamRequest();
  request.setName('World');
  request.setCount(5);

  const response = await fetch('/YourService/SayHelloStream', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/grpc-web+proto',
      Accept: 'application/grpc-web+proto',
    },
    body: request.serializeBinary(),
  });

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${await response.text()}`);
  }

  // Parse streaming response frames
  const buffer = await response.arrayBuffer();
  // ... frame parsing logic
}
```

## 📞 If Still Having Issues

If you're still experiencing 500 errors after checking these items:

1. **Enable detailed logging** in your gRPC-Web service
2. **Check for middleware interference** (CORS, authentication, etc.)
3. **Verify the .proto file** has been compiled correctly
4. **Test with a minimal service** to isolate the issue
5. **Check Ruby version compatibility** (works with Ruby 2.5+)

The streaming implementation has been thoroughly tested and works correctly when properly configured.
