# frozen_string_literal: true

require 'grpc_web/server/message_serialization'
require 'grpc_web/server/streaming_message_serialization'
require 'grpc_web/server/text_coder'
require 'grpc_web/message_framing'

# Module for encoding responses into gRPC-Web frames
module GRPCWeb
  class GRPCResponseEncoder
    def self.encode(response)
      new(response).encode
    end

    def initialize(response)
      @response = response
    end

    def encode
      if @response.streaming?
        StreamingRackResponse.new(@response)
      else
        # Unary response
        packed_frames = GRPCWeb::MessageFraming.pack_frames(@response.frames)
        apply_text_encoding(packed_frames)
      end
    end

    private

    def apply_text_encoding(data)
      if text_content_type?
        require 'base64'
        Base64.strict_encode64(data)
      else
        data
      end
    end

    def text_content_type?
      @response.content_type.include?('grpc-web-text')
    end

    # Rack-compatible streaming response that yields frames as they're generated
    class StreamingRackResponse
      def initialize(streaming_response)
        @streaming_response = streaming_response
        @trailers = {}
      end

      # This method will be called by Rack to get the response body
      def each
        return to_enum(__method__) unless block_given?

        begin
          # Yield all the data frames
          @streaming_response.stream_enumerator.each do |response_proto|
            yield serialize_and_pack_data_frame(response_proto)
          end
        rescue ::GRPC::BadStatus => e
          # Capture gRPC status errors to be sent as trailers
          @trailers = e.metadata.merge('grpc-status' => e.code, 'grpc-message' => e.details)
        rescue StandardError => e
          # Capture other errors
          @trailers = {
            'grpc-status' => ::GRPC::Core::StatusCodes::UNKNOWN,
            'grpc-message' => "#{e.class}: #{e.message}",
          }
        end

        # Finally, yield the trailer frame
        yield pack_trailer_frame
      end

      private

      def serialize_and_pack_data_frame(response_proto)
        serialized_response =
          GRPCWeb::StreamingMessageSerialization.serialize_response_proto(response_proto)
        data_frame = GRPCWeb::MessageFrame.payload_frame(serialized_response)
        packed_frame = GRPCWeb::MessageFraming.pack_frame(data_frame)
        apply_text_encoding(packed_frame)
      end

      def pack_trailer_frame
        @trailers['x-grpc-web'] ||= '1'
        trailer_str = @trailers.map { |k, v| "#{k}:#{v}" }.join("\r\n")
        trailer_frame = GRPCWeb::MessageFrame.header_frame(trailer_str)
        packed_trailer = GRPCWeb::MessageFraming.pack_frame(trailer_frame)
        apply_text_encoding(packed_trailer)
      end

      def apply_text_encoding(data)
        if text_content_type?
          require 'base64'
          Base64.strict_encode64(data)
        else
          data
        end
      end

      def text_content_type?
        @streaming_response.content_type.include?('grpc-web-text')
      end
    end
  end
end
