# frozen_string_literal: true

require 'spec_helper'
require 'net/http'
require 'json'
require 'rack/test'
require 'base64'
require_relative '../pb-ruby/hello_pb'
require_relative '../pb-ruby/hello_services_pb'
require 'grpc_web/message_frame'
require 'grpc_web/message_framing'

RSpec.describe 'Streaming HTTP Integration' do
  include Rack::Test::Methods

  # Implementation of the streaming service
  class TestHelloService < HelloService::Service
    def say_hello_stream(request, _call = nil)
      count = request.count.positive? ? request.count : 3
      
      Enumerator.new do |yielder|
        count.times do |i|
          response = StreamResponse.new(
            message: "Hello #{request.name} - Message #{i + 1}",
            index: i + 1
          )
          yielder << response
        end
      end
    end

    def say_hello(request, _call = nil)
      HelloResponse.new(message: "Hello #{request.name}")
    end

    def say_nothing(_request, _call = nil)
      EmptyResponse.new
    end
  end

  let(:service) { TestHelloService }
  let(:app) do
    grpc_app = GRPCWeb::RackApp.new
    grpc_app.handle(service)
    grpc_app
  end
  let(:headers) do
    {
      'CONTENT_TYPE' => 'application/grpc-web-text',
      'HTTP_ACCEPT' => 'application/grpc-web-text',
    }
  end

  # Helper method to create properly framed and encoded gRPC-Web requests
  def create_grpc_web_request(proto_message)
    serialized_request = proto_message.to_proto
    payload_frame = GRPCWeb::MessageFrame.payload_frame(serialized_request)
    packed_frame = GRPCWeb::MessageFraming.pack_frame(payload_frame)
    Base64.strict_encode64(packed_frame)
  end

  describe 'Streaming endpoint HTTP behavior' do
    it 'returns 200 (not 500) for valid streaming requests' do
      # Create a valid streaming request
      request = StreamRequest.new(name: 'Test', count: 2)
      encoded_frame = create_grpc_web_request(request)
      
      # Make the request using application/grpc-web-text
      post '/HelloService/SayHelloStream', encoded_frame, headers
      
      expect(last_response.status).to eq(200), 
        "Expected 200 but got #{last_response.status}. Body: #{last_response.body}"
      expect(last_response.headers['Content-Type']).to include('application/grpc-web-text')
    end

    it 'returns proper streaming response format' do
      request = StreamRequest.new(name: 'StreamTest', count: 3)
      encoded_frame = create_grpc_web_request(request)
      
      post '/HelloService/SayHelloStream', encoded_frame, headers
      
      expect(last_response.status).to eq(200)
      
      # Parse the response frames (decode from base64 first for grpc-web-text)
      response_body = last_response.body
      binary_response = Base64.decode64(response_body)
      frames = []
      offset = 0
      
      while offset < binary_response.length
        # Read frame header (5 bytes: 1 byte type + 4 bytes length)
        frame_type = binary_response[offset].unpack1('C')
        frame_length = binary_response[offset + 1, 4].unpack1('N')
        frame_data = binary_response[offset + 5, frame_length]
        
        frames << {
          type: frame_type,
          length: frame_length,
          data: frame_data
        }
        
        offset += 5 + frame_length
      end
      
      # Should have 3 payload frames + 1 header frame
      expect(frames.length).to eq(4)
      
      # First 3 frames should be payload frames (type 0)
      frames[0..2].each do |frame|
        expect(frame[:type]).to eq(0) # PAYLOAD_FRAME_TYPE
        
        # Parse the protobuf response
        response = StreamResponse.decode(frame[:data])
        expect(response.message).to include('StreamTest')
      end
      
      # Last frame should be header frame (type 128)
      expect(frames[3][:type]).to eq(128) # HEADER_FRAME_TYPE
      
      # Header frame should contain grpc-status: 0
      header_data = frames[3][:data]
      expect(header_data).to include('grpc-status: 0')
    end

    it 'handles empty stream correctly' do
      request = StreamRequest.new(name: 'Empty', count: 0)
      encoded_frame = create_grpc_web_request(request)
      
      post '/HelloService/SayHelloStream', encoded_frame, headers
      
      expect(last_response.status).to eq(200)
      
      # Should still have a header frame even for empty streams
      response_body = last_response.body
      expect(response_body.length).to be > 0
      
      # Should have at least one frame (the header frame)
      frame_type = response_body[0].unpack1('C')
      expect(frame_type).to eq(128) # HEADER_FRAME_TYPE for empty stream
    end

    it 'returns 500 for service errors' do
      # Stub the service to raise an error
      allow_any_instance_of(TestHelloService).to receive(:say_hello_stream).and_raise(StandardError.new('Test error'))
      
      request = StreamRequest.new(name: 'Error', count: 1)
      encoded_frame = create_grpc_web_request(request)
      
      post '/HelloService/SayHelloStream', encoded_frame, headers
      
      expect(last_response.status).to eq(500)
    end

    it 'returns 404 for non-existent methods' do
      request = StreamRequest.new(name: 'Test', count: 1)
      encoded_frame = create_grpc_web_request(request)
      
      post '/HelloService/NonExistentMethod', encoded_frame, headers
      
      expect(last_response.status).to eq(404)
    end

    it 'compares streaming vs unary response formats' do
      # Test unary response format
      request = HelloRequest.new(name: 'UnaryTest')
      encoded_unary_frame = create_grpc_web_request(request)
      
      post '/HelloService/SayHello', encoded_unary_frame, headers
      
      expect(last_response.status).to eq(200)
      unary_body = last_response.body
      
      # Test streaming response format  
      stream_request = StreamRequest.new(name: 'StreamTest', count: 1)
      encoded_stream_frame = create_grpc_web_request(stream_request)
      
      post '/HelloService/SayHelloStream', encoded_stream_frame, headers
      
      expect(last_response.status).to eq(200)
      streaming_body = last_response.body
      
      # Streaming response should be different from unary
      expect(streaming_body).not_to eq(unary_body)
      expect(streaming_body.length).to be > unary_body.length
    end
  end

  describe 'Error debugging' do
    it 'provides detailed error information for 500 responses' do
      # Create a service that will fail in a specific way
      allow_any_instance_of(TestHelloService).to receive(:say_hello_stream).and_raise(GRPC::Internal.new('Streaming service failed'))

      request = StreamRequest.new(name: 'Test', count: 1)
      encoded_frame = create_grpc_web_request(request)

      post '/HelloService/SayHelloStream', encoded_frame, headers

      expect(last_response.status).to eq(500)

      # Response should contain error information
      response_body = last_response.body
      expect(response_body).to include('grpc-status')
      expect(response_body).to include('grpc-message')
    end

    it 'handles enumerator errors gracefully' do
      # Service that returns an enumerator that fails during iteration
      allow_any_instance_of(TestHelloService).to receive(:say_hello_stream).and_return(
        Enumerator.new do |yielder|
          yielder << StreamResponse.new(message: 'First message', index: 1)
          raise StandardError.new('Enumerator failed')
        end
      )

      request = StreamRequest.new(name: 'Test', count: 2)
      encoded_frame = create_grpc_web_request(request)

      post '/HelloService/SayHelloStream', encoded_frame, headers

      # Should handle the error gracefully
      expect([200, 500]).to include(last_response.status)

      # The body should contain the first message and then the error trailer
      response_body = last_response.body
      expect(response_body).to include('First message')
      expect(response_body).to include('grpc-status')
      expect(response_body).to include('grpc-message')
    end
  end
end 