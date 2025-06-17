# frozen_string_literal: true

require 'grpc/core/status_codes'
require 'grpc/errors'
require 'grpc_web/content_types'
require 'grpc_web/grpc_web_response'
require 'grpc_web/message_frame'

# Message serialization for streaming responses
module GRPCWeb::StreamingMessageSerialization
  class << self
    include ::GRPCWeb::ContentTypes

    def serialize_streaming_response(streaming_response)
      if streaming_response.content_type == JSON_CONTENT_TYPE
        serialize_json_streaming_response(streaming_response)
      else
        serialize_proto_streaming_response(streaming_response)
      end
    end

    def serialize_response_proto(response_proto)
      response_proto.to_proto
    end

    private

    def serialize_json_streaming_response(streaming_response)
      StreamingFrameEnumerator.new(streaming_response) do |message|
        ::GRPCWeb::MessageFrame.payload_frame(message.to_json)
      end
    end

    def serialize_proto_streaming_response(streaming_response)
      StreamingFrameEnumerator.new(streaming_response) do |message|
        ::GRPCWeb::MessageFrame.payload_frame(message.to_proto)
      end
    end

    def generate_success_trailer
      header_str = generate_headers(::GRPC::Core::StatusCodes::OK, 'OK')
      ::GRPCWeb::MessageFrame.header_frame(header_str)
    end

    def generate_error_trailer(ex)
      if ex.is_a?(::GRPC::BadStatus)
        header_str = generate_headers(ex.code, ex.details, ex.metadata)
      else
        header_str = generate_headers(
          ::GRPC::Core::StatusCodes::UNKNOWN,
          "#{ex.class}: #{ex.message}",
        )
      end
      ::GRPCWeb::MessageFrame.header_frame(header_str)
    end

    def generate_headers(status, message, metadata = {})
      headers = [
        "grpc-status:#{status}",
        "grpc-message:#{message}",
        'x-grpc-web:1',
      ]
      metadata.each do |name, value|
        next if %w[grpc-status grpc-message x-grpc-web].include?(name)

        headers << "#{name}:#{value}"
      end
      headers << nil # for trailing newline
      headers.join("\r\n")
    end
  end

  # Enumerator that yields frames for each message in the stream plus trailer
  class StreamingFrameEnumerator
    include Enumerable

    def initialize(streaming_response, &frame_creator)
      @streaming_response = streaming_response
      @frame_creator = frame_creator
    end

    def each
      return to_enum(__method__) unless block_given?

      begin
        # Yield payload frames for each message in the stream
        @streaming_response.stream_enumerator.each do |message|
          frame = @frame_creator.call(message)
          yield frame
        end
        
        # Yield success trailer frame
        trailer_frame = GRPCWeb::StreamingMessageSerialization.send(:generate_success_trailer)
        yield trailer_frame
      rescue StandardError => e
        # Yield error trailer frame if something goes wrong
        error_trailer_frame = GRPCWeb::StreamingMessageSerialization.send(:generate_error_trailer, e)
        yield error_trailer_frame
      end
    end
  end
end 