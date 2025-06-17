# frozen_string_literal: true

# Test service that implements server-side streaming
class TestStreamingService
  # Simulate a streaming method that yields multiple responses
  def say_hello_stream(request, _call = nil)
    count = request.respond_to?(:count) ? request.count : 3
    name = request.respond_to?(:name) ? request.name : 'World'
    
    # Return an enumerator that yields multiple StreamResponse messages
    Enumerator.new do |yielder|
      count.times do |i|
        # Create a mock StreamResponse object
        response = MockStreamResponse.new(
          message: "Hello #{name} - Message #{i + 1}",
          index: i + 1
        )
        yielder << response
        
        # Add a small delay to simulate real streaming
        sleep(0.1) if ENV['SIMULATE_STREAMING_DELAY']
      end
    end
  end
  
  # Mock StreamResponse class for testing
  class MockStreamResponse
    attr_accessor :message, :index
    
    def initialize(message:, index:)
      @message = message
      @index = index
    end
    
    def to_proto
      # Simulate protobuf encoding
      # In real implementation, this would be the actual protobuf serialization
      "\x0A#{message.length}#{message}\x10#{index}"
    end
    
    def to_json
      {
        message: @message,
        index: @index
      }.to_json
    end
  end
end 