# frozen_string_literal: true

require 'spec_helper'
require 'support/test_streaming_service'

RSpec.describe 'Server-side streaming', type: :feature do
  let(:service) { TestStreamingService.new }
  
  describe 'streaming response processing' do
    let(:request) do
      double(
        'StreamRequest',
        name: 'Alice',
        count: 3,
        respond_to?: true
      )
    end
    
    it 'returns an enumerator that yields multiple messages' do
      stream = service.say_hello_stream(request)
      
      expect(stream).to respond_to(:each)
      
      messages = stream.to_a
      expect(messages.length).to eq(3)
      
      messages.each_with_index do |message, index|
        expect(message.message).to eq("Hello Alice - Message #{index + 1}")
        expect(message.index).to eq(index + 1)
      end
    end
    
    it 'works with default parameters' do
      default_request = double('StreamRequest', respond_to?: false)
      stream = service.say_hello_stream(default_request)
      
      messages = stream.to_a
      expect(messages.length).to eq(3)
      expect(messages.first.message).to include('Hello World')
    end
  end
  
  describe 'RPC type detection' do
    # Mock classes that match the actual gRPC structure
    class MockStreamOutput
      def is_a?(klass)
        klass == GRPC::RpcDesc::Stream
      end
    end
    
    class MockUnaryOutput
      def is_a?(klass)
        false
      end
    end
    
    class MockRpcDesc
      attr_reader :output
      
      def initialize(is_streaming)
        @output = is_streaming ? MockStreamOutput.new : MockUnaryOutput.new
      end
    end
    
    let(:mock_service_class) do
      Class.new do
        def self.rpc_descs
          {
            SayHelloStream: MockRpcDesc.new(true),
            SayHello: MockRpcDesc.new(false)
          }
        end
      end
    end
    
    it 'detects streaming methods correctly' do
      expect(
        GRPCWeb::RpcTypeDetector.server_streaming?(mock_service_class, :SayHelloStream)
      ).to be true
      
      expect(
        GRPCWeb::RpcTypeDetector.server_streaming?(mock_service_class, :SayHello)
      ).to be false
    end
    
    it 'handles missing methods gracefully' do
      expect(
        GRPCWeb::RpcTypeDetector.server_streaming?(mock_service_class, :NonExistentMethod)
      ).to be false
    end
  end
  
  describe 'streaming message serialization' do
    let(:streaming_response) do
      stream_enumerator = [
        TestStreamingService::MockStreamResponse.new(message: 'Test 1', index: 1),
        TestStreamingService::MockStreamResponse.new(message: 'Test 2', index: 2)
      ]
      
      GRPCWeb::StreamingResponseProcessor::StreamingResponse.new(
        GRPCWeb::ContentTypes::PROTO_CONTENT_TYPE,
        stream_enumerator
      )
    end
    
    it 'creates frame enumerator for streaming responses' do
      frame_enumerator = GRPCWeb::StreamingMessageSerialization
        .serialize_streaming_response(streaming_response)
      
      frames = frame_enumerator.to_a
      
      # Should have 2 payload frames + 1 trailer frame
      expect(frames.length).to eq(3)
      
      # First two should be payload frames
      expect(frames[0]).to be_payload
      expect(frames[1]).to be_payload
      
      # Last should be header (trailer) frame
      expect(frames[2]).to be_header
    end
  end
end 