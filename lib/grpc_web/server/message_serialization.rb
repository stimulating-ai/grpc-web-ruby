# frozen_string_literal: true

require 'grpc/core/status_codes'
require 'grpc/errors'
require 'grpc_web/content_types'
require 'grpc_web/grpc_web_response'
require 'grpc_web/grpc_web_request'
require 'grpc_web/message_frame'

# Placeholder
module GRPCWeb::MessageSerialization
  class << self
    include ::GRPCWeb::ContentTypes

    def deserialize_request(request)
      service_class = request.service.is_a?(Class) ? request.service : request.service.class
      
      # Convert snake_case method name back to PascalCase for RPC descriptor lookup
      # This handles the case where the method name was converted during routing
      method_symbol = if service_class.rpc_descs.key?(request.service_method.to_sym)
        request.service_method.to_sym
      else
        # Try to find the PascalCase version
        pascal_case_method = request.service_method.to_s.split('_').map(&:capitalize).join
        pascal_case_method.to_sym
      end
      
      request_proto_class = service_class.rpc_descs[method_symbol].input
      payload_frame = request.body.find(&:payload?)

      if request.content_type == JSON_CONTENT_TYPE
        request_proto = request_proto_class.decode_json(payload_frame.body)
      else
        request_proto = request_proto_class.decode(payload_frame.body)
      end

      ::GRPCWeb::GRPCWebRequest.new(
        request.service,
        request.service_method,
        request.content_type,
        request.accept,
        request_proto,
      )
    end

    def serialize_response(response)
      if response.body.is_a?(Exception)
        serialize_error_response(response)
      else
        serialize_success_response(response)
      end
    end

    private

    def serialize_success_response(response)
      if response.content_type == JSON_CONTENT_TYPE
        payload = response.body.to_json
      else
        payload = response.body.to_proto
      end

      header_str = generate_headers(::GRPC::Core::StatusCodes::OK, 'OK')
      payload_frame = ::GRPCWeb::MessageFrame.payload_frame(payload)
      header_frame = ::GRPCWeb::MessageFrame.header_frame(header_str)

      ::GRPCWeb::GRPCWebResponse.new(response.content_type, '', [payload_frame, header_frame])
    end

    def serialize_error_response(response)
      ex = response.body
      if ex.is_a?(::GRPC::BadStatus)
        header_str = generate_headers(ex.code, ex.details, ex.metadata)
      else
        header_str = generate_headers(
          ::GRPC::Core::StatusCodes::UNKNOWN,
          "#{ex.class}: #{ex.message}",
        )
      end
      header_frame = ::GRPCWeb::MessageFrame.header_frame(header_str)
      ::GRPCWeb::GRPCWebResponse.new(response.content_type, '', [header_frame])
    end

    # If needed, trailers can be appended to the response as a 2nd
    # base64 encoded string with independent framing.
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
end
